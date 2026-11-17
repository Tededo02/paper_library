import Darwin
import Foundation
import PaperLibraryCore
import PaperLibrarySupport
import SwiftData

private enum DOILiveFailure: Error { case failed(String) }

@main
struct DOILiveCheck {
    @MainActor
    static func main() async {
        do { try await run() }
        catch {
            FileHandle.standardError.write(Data("Live DOI check failed: \(error)\n".utf8))
            exit(1)
        }
    }

    @MainActor
    private static func run() async throws {
        guard CommandLine.arguments.dropFirst() == ["--live"] else {
            print("Usage: swift run DOILiveCheck --live")
            return
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PaperLibraryDOILive-\(UUID().uuidString)")
        let config = try StorageConfiguration.testing(at: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try LibraryRepository(store: LibraryStore.open(configuration: config))
        let course = try repo.addCourse(name: "DOI live verification")
        let arxiv = ArxivClient.local(cooldownURL: config.arxivCooldownURL)
        let queue = ImportCoordinator(repository: repo, provider: arxiv, doiProvider: DOIClient(enrichmentEnabled: false))
        try queue.enqueue(text: "https\\://doi.org/10.1109/ICARM65671.2025.11293737\u{00a0}https\\://doi.org/10.3390/s24020436", destinationCourseID: course.id, assignExisting: true, refreshMetadata: false)
        await queue.waitUntilIdle()
        guard repo.papers.count == 2, repo.importJobs.allSatisfy({ $0.state == .completed }) else {
            throw DOILiveFailure.failed(repo.importJobs.compactMap(\.errorMessage).joined(separator: "; "))
        }
        guard let ieee = repo.papers.first(where: { $0.doi == "10.1109/icarm65671.2025.11293737" }),
              ieee.title.hasPrefix("Multi-Modal Sensor Fusion for Localization"), ieee.authors == ["Yanxin Zhou", "Shuge Wu", "Chen Lv"],
              let mdpi = repo.papers.first(where: { $0.doi == "10.3390/s24020436" }),
              mdpi.title.hasPrefix("An Adaptive Unscented Kalman Filter"), mdpi.authors.count == 9,
              !mdpi.abstract.isEmpty, !mdpi.abstract.contains("<jats:"), mdpi.publicationDate != nil,
              repo.memberships.count == 2 else { throw DOILiveFailure.failed("Incorrect DOI metadata or memberships") }
        try repo.saveNotes(paperID: ieee.id, notes: "Preserve legacy DOI annotations")
        let ieeeID = ieee.id
        let repair = ImportCoordinator(repository: repo, provider: arxiv)
        try repair.recoverDOIDetails(paperID: ieee.id)
        try repair.recoverDOIDetails(paperID: mdpi.id)
        await repair.waitUntilIdle()
        guard ieee.abstract.hasPrefix("Localization is a critical component"), ieee.abstract.count > 600,
              ieee.id == ieeeID, ieee.notes == "Preserve legacy DOI annotations", ieee.metadataStatusRaw == "doiEnriched",
              ieee.publisherPDFURL != nil, mdpi.pdfSourceURL != nil, mdpi.pdfDownloadURL != nil,
              repo.papers.count == 2, repo.memberships.count == 2 else {
            throw DOILiveFailure.failed("Legacy DOI abstract/PDF enrichment failed")
        }
        try repo.saveNotes(paperID: mdpi.id, notes: "Retain live verification annotation")
        try queue.enqueue(text: "doi:10.3390/S24020436", destinationCourseID: course.id, assignExisting: true, refreshMetadata: false)
        await queue.waitUntilIdle()
        guard repo.papers.count == 2, repo.memberships.count == 2, mdpi.notes == "Retain live verification annotation",
              repo.importJobs.last?.outcomeRaw == "existing" else { throw DOILiveFailure.failed("DOI duplicate handling failed") }
        let saved = try ModelContext(repo.store.container).fetch(FetchDescriptor<Paper>())
        guard saved.count == 2, saved.allSatisfy({ $0.provider == "doi" && $0.canonicalURL?.hasPrefix("https://doi.org/") == true }) else {
            throw DOILiveFailure.failed("DOI persistence failed")
        }
        print("PASS: Both supplied DOI links imported and persisted; the existing IEEE record recovered its full abstract through OpenAlex.")
        print("PASS: IEEE offers publisher access; an open PDF URL was discovered for MDPI. No publisher PDF access was assumed.")
        print("PASS: Reimport reused the stored paper and preserved notes and course assignments.")
        print("No production data was opened. No PDFs or AI services were used.")
    }
}
