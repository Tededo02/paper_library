import Foundation
import PDFKit
import Testing
@testable import PaperLibraryCore

@MainActor
struct PDFReaderTests {
    @Test func readerRestoresPageSearchesAndReleasesDocument() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("PaperLibraryReader-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        try PDFFixtures.document().write(to: url)
        let reader = PDFReaderSession()
        var lastPage = 0
        reader.onPage = { lastPage = $0 }
        try reader.open(url: url, page: 2)
        #expect(reader.pageCount == 2 && reader.view.currentPage === reader.view.document?.page(at: 1))
        reader.go(to: 1)
        #expect(lastPage == 1)
        reader.search = "scientific"; reader.find()
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while reader.matches == 0 && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(reader.matches == 1)
        reader.nextMatch()
        #expect(reader.view.currentSelection?.string?.lowercased() == "scientific")
        reader.close()
        #expect(reader.view.document == nil)
    }
}
