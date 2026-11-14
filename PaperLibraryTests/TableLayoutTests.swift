import AppKit
import Foundation
import Observation
import PaperLibraryCore
import PaperLibraryUI
import PaperLibrarySupport
import SwiftUI
import Testing

@MainActor
@Observable
private final class TableSelection {
    var ids: Set<UUID> = []
    var sortOrder = [KeyPathComparator(\Paper.title)]
}

private struct TableFixtureView: View {
    let repository: LibraryRepository
    @Bindable var selection: TableSelection
    var body: some View {
        LibraryPaperTable(papers: repository.papers.sorted(using: selection.sortOrder), pdfRecordIDs: [:], selection: $selection.ids, sortOrder: $selection.sortOrder, openPDF: { _ in })
    }
}

private actor TableImportProvider: ArxivMetadataProviding {
    func fetch(_ identifiers: [ArxivIdentifier]) throws -> [ArxivMetadata] {
        try identifiers.enumerated().map { index, id in
            let title = index == 0 ? "A short imported title" : "A very long scientific title about iterative geometric primitive reconstruction, observation constraints and multi-view object representations that must wrap safely across two lines"
            return try ArxivMetadata(identifier: ArxivIdentifier(id.canonical + "v1"), title: title, authors: ["First Researcher", "Second Researcher"], abstract: "Source abstract.", publishedAt: Date(), updatedAt: Date(), categories: [], doi: nil, journalReference: nil)
        }
    }
}

@Suite(.serialized)
@MainActor
struct TableLayoutTests {
    private func nativeTable(in view: NSView) -> NSTableView? {
        if let table = view as? NSTableView { return table }
        for child in view.subviews { if let table = nativeTable(in: child) { return table } }
        return nil
    }
    private func settle(_ host: NSView, rows: Int) async throws -> NSTableView {
        for _ in 0..<100 {
            host.layoutSubtreeIfNeeded()
            if let table = nativeTable(in: host), table.numberOfRows == rows {
                try await Task.sleep(for: .milliseconds(50)); host.layoutSubtreeIfNeeded(); return table
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw AnalysisError.failed
    }
    private func checkRows(_ table: NSTableView) {
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let twoLines = ceil((font.ascender - font.descender + font.leading) * 2)
        var heights: [CGFloat] = []
        for row in 0..<table.numberOfRows {
            let rect = table.rect(ofRow: row)
            heights.append(rect.height)
            #expect(rect.height >= twoLines, "A table row must contain a two-line title immediately, including after insertion")
            if row > 0 { #expect(table.rect(ofRow: row - 1).maxY <= rect.minY + 0.5) }
            for column in 0..<table.numberOfColumns {
                if let cell = table.view(atColumn: column, row: row, makeIfNecessary: false) {
                    let bounds = cell.convert(cell.bounds, to: table)
                    #expect(bounds.minY >= rect.minY - 0.5 && bounds.maxY <= rect.maxY + 0.5)
                }
            }
        }
        if let min = heights.min(), let max = heights.max() { #expect(max - min < 0.5, "Short and wrapped titles must not change row geometry") }
        print("Native table row heights: \(heights)")
    }

    @Test func importingPapersKeepsNativeRowsAlignedWithoutRecreatingTable() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PaperLibraryTable-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try LibraryRepository(store: LibraryStore.open(configuration: .testing(at: root)))
        let selection = TableSelection()
        let host = NSHostingView(rootView: TableFixtureView(repository: repository, selection: selection))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 600), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { window.contentView = nil; window.close() }
        let table = try await settle(host, rows: 0)
        let original = try repository.addPaper(PaperDraft(title: "Existing short title", authors: ["Existing Author"]))
        _ = try await settle(host, rows: 1); checkRows(table)
        selection.ids = [original.id]
        table.tableColumns[0].width = 220
        let width = table.tableColumns[0].width
        let imports = ImportCoordinator(repository: repository, provider: TableImportProvider())
        try imports.enqueue(text: "1706.03762 2401.00001", destinationCourseID: nil, assignExisting: true, refreshMetadata: false)
        await imports.waitUntilIdle()
        let updated = try await settle(host, rows: 3)
        #expect(updated === table)
        checkRows(table)
        #expect(selection.ids == [original.id])
        #expect(abs(table.tableColumns[0].width - width) < 1)
        try repository.updateMetadata(paperID: original.id, draft: PaperDraft(title: String(repeating: "Updated multi-line research title ", count: 6), authors: ["Existing Author"]))
        _ = try await settle(host, rows: 3); checkRows(table)
        window.setContentSize(NSSize(width: 950, height: 600))
        _ = try await settle(host, rows: 3); checkRows(table)
        try repository.deletePapers(ids: [original.id])
        _ = try await settle(host, rows: 2); checkRows(table)
    }
}
