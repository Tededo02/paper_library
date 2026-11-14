import Darwin
import Foundation
import PaperLibraryCore
import PaperLibrarySupport

enum PDFLiveFailure: Error { case failed(String) }

@main
struct PDFLiveCheck {
    @MainActor static func main() async {
        guard CommandLine.arguments.dropFirst() == ["--live"] else { print("Usage: swift run PDFLiveCheck --live"); return }
        do { try await run() }
        catch { FileHandle.standardError.write(Data("PDF live check failed: \(error)\n".utf8)); exit(1) }
    }
    @MainActor private static func run() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PaperLibraryPDFLive-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let config = try StorageConfiguration.testing(at: root)
        let repo = try LibraryRepository(store: LibraryStore.open(configuration: config))
        let imports = ImportCoordinator(repository: repo, provider: ArxivClient.local(cooldownURL: config.arxivCooldownURL))
        try imports.enqueue(text: "1706.03762v1", destinationCourseID: nil, assignExisting: true, refreshMetadata: false)
        await imports.waitUntilIdle()
        guard let paper = repo.papers.first else { throw PDFLiveFailure.failed(repo.importJobs.first?.errorMessage ?? "Metadata missing") }
        let pdfs = PDFCoordinator.local(repository: repo)
        try pdfs.enqueue(paperID: paper.id)
        await pdfs.waitUntilIdle()
        guard let record = repo.pdfRecords(paperID: paper.id).first, record.pageCount > 1,
              record.version == 1, record.indexStatus == "chunksReady", try !repo.pdfChunks(recordID: record.id).isEmpty else {
            throw PDFLiveFailure.failed(repo.pdfJobs.last?.errorMessage ?? pdfs.errorMessage ?? "PDF processing failed")
        }
        _ = try await pdfs.files.verifiedURL(record.fileReference)
        print("PASS: Real arXiv PDF downloaded over HTTPS; SHA-256 verified, \(record.fileSize) bytes, version \(record.version).")
        print("PASS: PDFKit extracted \(record.pageCount) source pages and \(try repo.pdfChunks(recordID: record.id).count) page-mapped chunks; extraction status: \(record.extractionStatus).")
        try repo.saveReadingPosition(recordID: record.id, page: 2)
        guard record.lastReadPage == 2 else { throw PDFLiveFailure.failed("Reading position was not saved") }
        print("PASS: Reading position persisted. No production data or AI service was used.")
    }
}
