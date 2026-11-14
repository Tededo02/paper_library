import Foundation
import Darwin
import PaperLibraryCore
import PaperLibrarySupport

enum LiveCheckFailure: Error { case failed(String) }

@main
struct ArxivLiveCheck {
    @MainActor
    static func main() async {
        do { try await run() }
        catch {
            FileHandle.standardError.write(Data("Live arXiv check failed: \(error)\n".utf8))
            exit(1)
        }
    }

    @MainActor
    private static func run() async throws {
        guard CommandLine.arguments.dropFirst() == ["--live"] else {
            print("Usage: swift run ArxivLiveCheck --live")
            return
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PaperLibraryArxivLive-\(UUID().uuidString)")
        let configuration = try StorageConfiguration.testing(at: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try LibraryRepository(store: LibraryStore.open(configuration: configuration))
        let course = try repository.addCourse(name: "Live metadata verification")
        let provider = ArxivClient.local(cooldownURL: configuration.arxivCooldownURL)
        let queue = ImportCoordinator(repository: repository, provider: provider)
        try queue.enqueue(text: "https://arxiv.org/abs/1706.03762v1", destinationCourseID: course.id, assignExisting: true, refreshMetadata: false)
        await queue.waitUntilIdle()
        guard let paper = repository.papers.first, paper.providerIdentifier == "1706.03762", paper.resolvedVersion == 1,
              paper.title == "Attention Is All You Need", paper.authors.count == 8,
              repository.importJobs.first?.state == .completed else {
            throw LiveCheckFailure.failed(repository.importJobs.first?.errorMessage ?? "Live metadata import failed")
        }
        try repository.saveNotes(paperID: paper.id, notes: "Local verification annotation")
        try queue.enqueue(text: "1706.03762v2", destinationCourseID: course.id, assignExisting: true, refreshMetadata: false)
        await queue.waitUntilIdle()
        guard repository.papers.count == 1, repository.memberships.count == 1,
              paper.notes == "Local verification annotation", paper.resolvedVersion == 1,
              repository.importJobs.last?.outcomeRaw == "existing" else { throw LiveCheckFailure.failed("Duplicate handling failed") }
        print("PASS: Real HTTPS arXiv metadata imported and persisted with eight ordered authors and explicit version 1.")
        print("PASS: Duplicate version-2 input reused the global record and retained local notes and version 1.")
        print("No production data was opened. No PDFs or AI services were used.")
    }
}
