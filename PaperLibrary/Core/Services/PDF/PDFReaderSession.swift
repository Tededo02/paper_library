import AppKit
import Foundation
import Observation
import PDFKit

@MainActor
@Observable
public final class PDFReaderSession {
    public let view = LocalPDFView(frame: .zero)
    public var page = 1
    public var pageCount = 0
    public var search = ""
    public var matches = 0
    public var outline: [(String, Int)] = []
    private var observations: [NSObjectProtocol] = []
    private var selections: [PDFSelection] = []
    private var matchIndex = -1
    private var activeQuery = ""
    private var lastSavedPage = 0
    private var outlineBudget = 500
    public var onPage: ((Int) -> Void)?

    public init() {}

    public func open(url: URL, page: Int) throws {
        guard let document = PDFDocument(url: url), !document.isLocked, document.pageCount > 0 else { throw PDFLibraryError.invalidFile }
        let callback = onPage; close(); onPage = callback; outline = []; outlineBudget = 500; matches = 0; matchIndex = -1; lastSavedPage = 0
        view.document = document; view.autoScales = true; view.displayMode = .singlePageContinuous
        pageCount = document.pageCount
        observations.append(NotificationCenter.default.addObserver(forName: .PDFViewPageChanged, object: view, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.pageChanged() }
        })
        observations.append(NotificationCenter.default.addObserver(forName: .PDFDocumentDidFindMatch, object: document, queue: .main) { [weak self] note in
            nonisolated(unsafe) let mainQueueNotification = note
            MainActor.assumeIsolated {
                guard let self, self.selections.count < 1000, let selection = mainQueueNotification.userInfo?[PDFDocumentFoundSelectionKey] as? PDFSelection,
                      selection.string?.localizedCaseInsensitiveCompare(self.activeQuery) == .orderedSame else { return }
                self.selections.append(selection); self.matches = self.selections.count
            }
        })
        if let root = document.outlineRoot { loadOutline(root, depth: 0) }
        go(to: page)
    }
    private func loadOutline(_ node: PDFOutline, depth: Int) {
        guard depth < 12, outlineBudget > 0 else { return }
        outlineBudget -= 1
        if let label = node.label, let target = node.destination?.page, let doc = view.document {
            outline.append((String(repeating: "  ", count: depth) + String(label.prefix(300)), doc.index(for: target) + 1))
        }
        for index in 0..<min(node.numberOfChildren, 500) {
            if outlineBudget <= 0 { break }
            if let child = node.child(at: index) { loadOutline(child, depth: depth + 1) }
        }
    }
    public func go(to page: Int) {
        if let target = view.document?.page(at: max(0, min(page - 1, pageCount - 1))) { view.go(to: target) }
    }
    private func pageChanged() {
        guard let current = view.currentPage, let doc = view.document else { return }
        page = doc.index(for: current) + 1
        if page != lastSavedPage { lastSavedPage = page; onPage?(page) }
    }
    public func find() {
        view.document?.cancelFindString(); selections = []; matches = 0; matchIndex = -1
        activeQuery = String(search.prefix(500)); search = activeQuery
        if !activeQuery.isEmpty { view.document?.beginFindString(activeQuery, withOptions: .caseInsensitive) }
    }
    public func nextMatch() {
        guard !selections.isEmpty else { return }
        matchIndex = (matchIndex + 1) % selections.count
        view.setCurrentSelection(selections[matchIndex], animate: false); view.go(to: selections[matchIndex])
    }
    public func close() {
        view.document?.cancelFindString()
        observations.forEach(NotificationCenter.default.removeObserver); observations = []
        selections = []; view.document = nil; onPage = nil
    }
}

