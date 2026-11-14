import Foundation
import Observation
import PaperLibrarySupport

@MainActor
@Observable
public final class AnalysisCoordinator {
    public let repository: LibraryRepository
    public private(set) var availability: AIAvailability = .unknown
    public private(set) var isRunning = false
    public private(set) var errorMessage: String?
    private let model: any OnDeviceAnalysisModel
    private let pipeline: AnalysisPipeline
    private var worker: Task<Void, Never>?
    private var activeID: UUID?
    private var stopping = false

    public init(repository: LibraryRepository, model: any OnDeviceAnalysisModel = AppleAnalysisModel()) {
        self.repository = repository; self.model = model; self.pipeline = AnalysisPipeline(model: model)
    }
    public func refreshAvailability(language: String) async { availability = await model.availability(language: language) }
    public func summarize(paperID: UUID, profileID: UUID, language: String, confirmEdited: Bool = false) throws {
        if let record = repository.pdfRecords(paperID: paperID).first(where: { $0.indexStatus == "chunksReady" }),
           let source = try? repository.sourceSnapshot(paperID: paperID, kind: .pdf, recordID: record.id), !source.parts.isEmpty {
            try enqueue(paperID: paperID, profileID: profileID, kind: .pdf, recordID: record.id, language: language, confirmEdited: confirmEdited)
            return
        }
        try enqueue(paperID: paperID, profileID: profileID, kind: .abstract, recordID: nil, language: language, confirmEdited: confirmEdited)
    }
    public func enqueue(paperID: UUID, profileID: UUID, kind: AnalysisSourceKind, recordID: UUID?, language: String, confirmEdited: Bool = false) throws {
        _ = try repository.enqueueAnalysis(paperID: paperID, profileID: profileID, kind: kind, recordID: recordID, language: language, confirmEdited: confirmEdited); start()
    }
    public func retry(id: UUID, confirmEdited: Bool = false) throws { _ = try repository.retryAnalysis(id: id, confirmEdited: confirmEdited); start() }
    public func cancel(id: UUID) throws { try repository.updateAIJob(id: id, state: .cancelled); if activeID == id { worker?.cancel() } }
    public func cancel(paperIDs: Set<UUID>) throws {
        for job in repository.aiJobs where paperIDs.contains(job.paperID) && [.pending, .inProgress].contains(job.state) { try cancel(id: job.id) }
    }
    public func prepareForTermination() throws { try repository.interruptAIJobs(); stopping = true; worker?.cancel() }
    public func waitUntilIdle() async { while let task = worker { await task.value } }
    private func start() {
        guard worker == nil, !stopping else { return }
        errorMessage = nil; isRunning = true
        worker = Task {
            await run(); worker = nil; activeID = nil; isRunning = false
            if !stopping && errorMessage == nil && repository.aiJobs.contains(where: { $0.state == .pending }) { start() }
        }
    }
    private func run() async {
        do {
            while !Task.isCancelled && !stopping, let job = repository.aiJobs.first(where: { $0.state == .pending }) {
                activeID = job.id
                try repository.updateAIJob(id: job.id, state: .inProgress, progress: 0)
                do {
                    availability = await model.availability(language: job.language)
                    guard availability == .available else { throw AnalysisError.unavailable(availability) }
                    guard let kind = AnalysisSourceKind(rawValue: job.sourceKind) else { throw AnalysisError.missingSource }
                    let source = try repository.sourceSnapshot(paperID: job.paperID, kind: kind, recordID: job.recordID)
                    guard source.hash == job.sourceHash else { throw AnalysisError.stale }
                    let request = AnalysisRequest(profile: job.profileInstructions, language: job.language, sourceKind: kind)
                    let jobID = job.id
                    let result = try await pipeline.run(source: source, request: request) { [weak self] value in await self?.progress(id: jobID, value: value) }
                    try Task.checkCancellation()
                    try repository.completeAnalysis(jobID: jobID, result: result)
                } catch {
                    if Task.isCancelled || error is CancellationError {
                        if repository.aiJobs.first(where: { $0.id == job.id })?.state == .inProgress { try repository.updateAIJob(id: job.id, state: .interrupted, error: Strings.text("ai.interrupted")) }
                        return
                    }
                    let message = (error as? AnalysisError)?.localizedDescription ?? Strings.text("ai.error.failed")
                    try repository.updateAIJob(id: job.id, state: .failed, error: message)
                }
            }
        } catch { errorMessage = error.localizedDescription; try? repository.interruptAIJobs() }
    }
    private func progress(id: UUID, value: Double) {
        guard repository.aiJobs.first(where: { $0.id == id })?.state == .inProgress else { worker?.cancel(); return }
        do { try repository.updateAIJob(id: id, state: .inProgress, progress: value) }
        catch { errorMessage = error.localizedDescription; worker?.cancel() }
    }
}
