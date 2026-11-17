import Foundation
import Observation
import PaperLibrarySupport

@MainActor
@Observable
public final class PDFCoordinator {
    public let repository: LibraryRepository
    public let files: PDFFileStore
    public private(set) var isRunning = false
    public private(set) var errorMessage: String?
    public private(set) var isImporting = false
    private var localImport: Task<UUID, Error>?
    private let downloader: any PDFDownloading
    private let extractor: any PDFExtracting
    private let metadataExtractor: any PDFMetadataExtracting
    private var worker: Task<Void, Never>?
    private var activeID: UUID?
    private var stopping = false
    private var lastProgress = Date.distantPast
    private let chunker = PDFChunkingService()
    public var limits: PDFLimits

    public init(repository: LibraryRepository, files: PDFFileStore, downloader: any PDFDownloading, extractor: any PDFExtracting = PDFTextExtractor(), limits: PDFLimits = PDFLimits(), metadataExtractor: any PDFMetadataExtracting = ApplePDFMetadataExtractor()) {
        self.repository = repository; self.files = files; self.downloader = downloader; self.extractor = extractor; self.limits = limits; self.metadataExtractor = metadataExtractor
    }
    public static func local(repository: LibraryRepository, metadataExtractor: any PDFMetadataExtracting = ApplePDFMetadataExtractor()) -> PDFCoordinator {
        let files = PDFFileStore(configuration: repository.store.configuration)
        let scheduler = ArxivRequestScheduler(transport: ArxivURLSessionTransport(), cooldownURL: repository.store.configuration.arxivCooldownURL)
        return PDFCoordinator(repository: repository, files: files, downloader: PDFDownloader(files: files, scheduler: scheduler), metadataExtractor: metadataExtractor)
    }
    public func enqueue(paperID: UUID, operation: String = "download", version: Int? = nil) throws {
        _ = try repository.enqueuePDF(paperID: paperID, operation: operation, version: version); start()
    }
    public func recoverLocalMetadata(_ metadata: LocalPDFMetadata) async throws -> RecoveredPDFMetadata {
        let needsAuthors = metadata.authors.isEmpty
        let needsAbstract = metadata.abstract.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard metadata.hasExtractableText else { return RecoveredPDFMetadata() }
        let result = try await metadataExtractor.extract(from: metadata.frontMatter, needsTitle: true, needsAuthors: needsAuthors, needsAbstract: needsAbstract)
        try Task.checkCancellation()
        return PDFMetadataValidation.grounded(result, source: metadata.frontMatter, needsAuthors: needsAuthors, needsAbstract: needsAbstract)
    }
    public func importLocalPDF(from source: URL, draft: PaperDraft, courseIDs: Set<UUID> = [], attachingTo targetPaperID: UUID? = nil) async throws -> UUID {
        guard localImport == nil, !stopping else { throw LibraryError.invalidInput }
        if let targetPaperID, repository.paper(id: targetPaperID) == nil { throw LibraryError.missingRecord }
        try repository.validateLocalPDF(draft: draft, courseIDs: courseIDs)
        let task = Task { @MainActor in
            let staged = try await files.stageLocal(source, limits: limits)
            var installed: PDFFileReference?
            do {
                try Task.checkCancellation()
                let match = repository.pdfRecords.first { $0.checksum == staged.checksum && repository.paper(id: $0.paperID) != nil && (targetPaperID == nil || $0.paperID == targetPaperID) }
                let paperID = targetPaperID ?? match?.paperID ?? UUID()
                let nextVersion = targetPaperID == nil ? 1 : (repository.pdfRecords.filter { $0.paperID == paperID }.map(\.version).max() ?? 0) + 1
                let version = match?.version ?? nextVersion
                let reference = try await files.install(staged: staged.url, paperID: paperID, version: version, limits: limits)
                installed = reference
                try Task.checkCancellation()
                guard !stopping, reference.checksum == staged.checksum else { throw CancellationError() }
                if let targetPaperID, repository.paper(id: targetPaperID) == nil { throw LibraryError.missingRecord }
                let id = try repository.completeLocalPDF(paperID: paperID, version: version, reference: reference, draft: draft, courseIDs: courseIDs, filename: source.lastPathComponent)
                start()
                return id
            } catch {
                try? await files.discard(staged: staged.url)
                if let installed, !repository.pdfRecords.contains(where: { !$0.isRemoved && $0.relativePath == installed.relativePath }) {
                    try? await files.remove(relativePath: installed.relativePath)
                }
                throw error
            }
        }
        localImport = task; isImporting = true
        defer { localImport = nil; isImporting = false }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
    public func retry(id: UUID) throws { try repository.retryPDFJob(id: id); start() }
    public func cancel(id: UUID) throws {
        try repository.updatePDFJob(id: id, state: .cancelled)
        if activeID == id { worker?.cancel() }
    }
    public func remove(recordID: UUID) async throws {
        guard let record = repository.pdfRecord(id: recordID) else { return }
        let path = record.relativePath
        let affectsActive = repository.pdfJobs.contains { $0.id == activeID && $0.paperID == record.paperID && $0.version == record.version }
        try repository.removePDF(recordID: recordID)
        if affectsActive { worker?.cancel() }
        try await files.remove(relativePath: path)
    }
    public func deletePapers(ids: Set<UUID>) async throws {
        let cancelsActive = repository.pdfJobs.contains { $0.id == activeID && ids.contains($0.paperID) }
        try repository.deletePapers(ids: ids)
        if cancelsActive { worker?.cancel() }
        try await cleanupRemovedFiles()
    }
    public func prepareForTermination() throws {
        try repository.interruptPDFJobs(); stopping = true; worker?.cancel(); localImport?.cancel()
    }
    public func waitUntilIdle() async { while let task = worker { await task.value } }
    public func cleanupRemovedFiles() async throws {
        for record in repository.pdfRecords where record.isRemoved { try Task.checkCancellation(); try await files.remove(relativePath: record.relativePath) }
    }
    private func start() {
        guard worker == nil, !stopping else { return }
        errorMessage = nil; isRunning = true
        worker = Task {
            await run()
            worker = nil; isRunning = false; activeID = nil
            if !stopping && errorMessage == nil && repository.pdfJobs.contains(where: { $0.state == .pending }) { start() }
        }
    }
    private func run() async {
        do {
            try await files.prepare()
            try await cleanupRemovedFiles()
            while !Task.isCancelled && !stopping {
                guard let job = repository.pdfJobs.first(where: { $0.state == .pending }) else { return }
                activeID = job.id
                try repository.updatePDFJob(id: job.id, state: .inProgress)
                do {
                    let existing = repository.pdfRecords(paperID: job.paperID).first { $0.version == job.version }
                    if job.operation == "download" {
                        if let existing {
                            do {
                                _ = try await files.verifiedURL(existing.fileReference)
                                try repository.updatePDFJob(id: job.id, state: .completed, received: existing.fileSize, total: existing.fileSize)
                                continue
                            } catch PDFLibraryError.missing {
                            }
                        }
                        guard let source = job.sourceURL.flatMap(URL.init(string:)) else { throw PDFLibraryError.invalidSource }
                        let jobID = job.id
                        let reference = try await downloader.download(url: source, paperID: job.paperID, version: job.version, jobID: jobID, limits: limits) { [weak self] received, total in
                            await self?.progress(id: jobID, received: received, total: total)
                        }
                        if Task.isCancelled || repository.pdfJob(id: jobID)?.state != .inProgress || repository.paper(id: job.paperID) == nil {
                            if !repository.pdfRecords.contains(where: { !$0.isRemoved && $0.relativePath == reference.relativePath }) { try await files.remove(relativePath: reference.relativePath) }
                            throw CancellationError()
                        }
                        try Task.checkCancellation()
                        try repository.completePDFDownload(jobID: jobID, reference: reference)
                    } else {
                        guard let record = existing else { throw PDFLibraryError.missing }
                        let checksum = record.checksum; let id = record.id
                        let url = try await files.verifiedURL(record.fileReference)
                        let result = try await extractor.extract(url: url, limits: limits)
                        let chunks = try await chunker.chunks(pages: result.pages)
                        try Task.checkCancellation()
                        try repository.completePDFExtraction(jobID: job.id, recordID: id, checksum: checksum, result: result, chunks: chunks)
                    }
                } catch {
                    if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
                        if repository.pdfJob(id: job.id)?.state == .inProgress { try repository.updatePDFJob(id: job.id, state: .interrupted, error: Strings.text("pdf.interrupted")) }
                        return
                    }
                    try repository.updatePDFJob(id: job.id, state: .failed, error: error.localizedDescription)
                }
            }
        } catch { errorMessage = error.localizedDescription; try? repository.interruptPDFJobs() }
    }
    private func progress(id: UUID, received: Int64, total: Int64?) {
        guard repository.pdfJob(id: id)?.state == .inProgress else { return }
        guard received == 0 || received == total || Date().timeIntervalSince(lastProgress) >= 0.3 else { return }
        lastProgress = Date()
        do { try repository.updatePDFJob(id: id, state: .inProgress, received: received, total: total) }
        catch { errorMessage = error.localizedDescription; worker?.cancel() }
    }
}
