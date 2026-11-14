import Foundation
import Observation
import PaperLibrarySupport

@MainActor
@Observable
public final class ImportCoordinator {
    public let repository: LibraryRepository
    public private(set) var isRunning = false
    public private(set) var activeBatchID: UUID?
    public private(set) var errorMessage: String?
    private let provider: any ArxivMetadataProviding
    private var worker: Task<Void, Never>?
    private var shuttingDown = false

    public init(repository: LibraryRepository, provider: any ArxivMetadataProviding) {
        self.repository = repository; self.provider = provider
    }

    @discardableResult
    public func enqueue(text: String, destinationCourseID: UUID?, assignExisting: Bool, refreshMetadata: Bool) throws -> UUID {
        let batch = try repository.enqueueImports(ImportInput.parse(text), destinationCourseID: destinationCourseID,
            assignExisting: assignExisting, refreshMetadata: refreshMetadata)
        start()
        return batch
    }

    public func retry(ids: Set<UUID>, destinationCourseID: UUID?, assignExisting: Bool, refreshMetadata: Bool) throws {
        try repository.retryImports(ids: ids, destinationCourseID: destinationCourseID, assignExisting: assignExisting, refreshMetadata: refreshMetadata)
        start()
    }

    public func cancel(batchID: UUID) throws {
        try repository.cancelImports(batchID: batchID)
        if activeBatchID == batchID { worker?.cancel() }
    }

    public func prepareForTermination() throws {
        try repository.interruptImports(includePending: true)
        shuttingDown = true
        worker?.cancel()
    }

    public func waitUntilIdle() async {
        while let task = worker { await task.value }
    }

    public func resume(ids: Set<UUID>, destinationCourseID: UUID?, assignExisting: Bool, refreshMetadata: Bool) throws {
        guard worker == nil else { return }
        try repository.recoverInterruptedImports()
        try retry(ids: ids, destinationCourseID: destinationCourseID, assignExisting: assignExisting, refreshMetadata: refreshMetadata)
    }

    private func start() {
        guard worker == nil, !shuttingDown else { return }
        errorMessage = nil; isRunning = true
        worker = Task {
            await run()
            worker = nil; isRunning = false; activeBatchID = nil
            if !shuttingDown, errorMessage == nil, repository.importJobs.contains(where: { $0.state == .pending }) { start() }
        }
    }

    private func run() async {
        do {
            while !Task.isCancelled && !shuttingDown {
                guard let first = repository.importJobs.first(where: { $0.state == .pending }) else { return }
                activeBatchID = first.batchID
                let ids = repository.importJobs.filter { $0.batchID == first.batchID && $0.state == .pending }.prefix(20).map(\.id)
                try repository.beginImports(ids: ids)
                var networkIDs: [UUID] = []
                for id in ids {
                    do {
                        if try !repository.completeExistingImport(id: id) { networkIDs.append(id) }
                    } catch { try repository.failImport(id: id, error: error) }
                }
                if networkIDs.isEmpty { continue }
                let identifiers = networkIDs.compactMap { repository.importJob(id: $0)?.identifier }
                do {
                    let metadata = try await provider.fetch(identifiers)
                    try Task.checkCancellation()
                    for id in networkIDs {
                        guard let job = repository.importJob(id: id), job.state == .inProgress, let requested = job.identifier else { continue }
                        let matches = metadata.filter { $0.identifier.canonical == requested.canonical }
                        let record = requested.version.map { version in matches.first { $0.identifier.version == version } } ?? matches.max { ($0.identifier.version ?? 0) < ($1.identifier.version ?? 0) }
                        do {
                            guard let record else { throw matches.isEmpty ? ArxivError.notFound : ArxivError.wrongVersion }
                            try repository.completeImport(id: id, metadata: record)
                        } catch { try repository.failImport(id: id, error: error) }
                    }
                } catch is CancellationError {
                    try repository.interruptImports(includePending: false)
                    return
                } catch {
                    for id in networkIDs { try repository.failImport(id: id, error: error) }
                }
            }
        } catch {
            errorMessage = error.localizedDescription
            try? repository.interruptImports(includePending: false)
        }
    }
}
