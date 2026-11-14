import Foundation

public struct ArxivMetadata: Sendable, Equatable {
    public let identifier: ArxivIdentifier
    public let title: String
    public let authors: [String]
    public let abstract: String
    public let publishedAt: Date
    public let updatedAt: Date
    public let categories: [String]
    public let doi: String?
    public let journalReference: String?
    public let hasPDF: Bool

    public init(identifier: ArxivIdentifier, title: String, authors: [String], abstract: String, publishedAt: Date, updatedAt: Date, categories: [String] = [], doi: String? = nil, journalReference: String? = nil, hasPDF: Bool = true) throws {
        guard identifier.version != nil, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !abstract.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !authors.isEmpty,
              authors.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else { throw ArxivError.invalidFeed }
        self.identifier = identifier
        self.title = title
        self.authors = authors
        self.abstract = abstract
        self.publishedAt = publishedAt
        self.updatedAt = updatedAt
        self.categories = categories
        self.doi = doi
        self.journalReference = journalReference
        self.hasPDF = hasPDF
    }
}

public enum ArxivAtomParser {
    public static func parse(_ data: Data) throws -> [ArxivMetadata] {
        guard data.count <= 2_097_152 else { throw ArxivError.responseTooLarge }
        guard let xml = String(data: data, encoding: .utf8),
              !xml.localizedCaseInsensitiveContains("<!DOCTYPE"), !xml.localizedCaseInsensitiveContains("<!ENTITY") else { throw ArxivError.invalidFeed }
        let delegate = AtomDelegate()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse(), delegate.error == nil, delegate.sawFeed else { throw delegate.error ?? ArxivError.invalidFeed }
        return delegate.entries
    }
}

private final class AtomDelegate: NSObject, XMLParserDelegate {
    private let atom = "http://www.w3.org/2005/Atom"
    private let arxiv = "http://arxiv.org/schemas/atom"
    private var path: [(String, String)] = []
    private var fields: [String: String] = [:]
    private var authors: [String] = []
    private var categories: [String] = []
    private var pdfLink: String?
    var entries: [ArxivMetadata] = []
    var error: ArxivError?
    var sawFeed = false

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        path.append((namespaceURI ?? "", name))
        if path.count > 16 { fail(parser); return }
        if path.count == 1 {
            sawFeed = name == "feed" && namespaceURI == atom
            if !sawFeed { fail(parser) }
        }
        if isPath(["feed", "entry"], namespace: atom) {
            guard entries.count < 50 else { fail(parser); return }
            fields = [:]; authors = []; categories = []; pdfLink = nil
        }
        if isPath(["feed", "entry", "author", "name"], namespace: atom) { fields["author"] = "" }
        if isPath(["feed", "entry", "category"], namespace: atom), let term = attributes["term"], !categories.contains(term) { categories.append(term) }
        if isPath(["feed", "entry", "link"], namespace: atom), attributes["title"] == "pdf" || attributes["type"] == "application/pdf" {
            pdfLink = attributes["href"]
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard path.count >= 3, path[0].1 == "feed", path[1].1 == "entry", path[0].0 == atom, path[1].0 == atom else { return }
        if path.count == 3, let last = path.last,
           (last.0 == atom && ["id", "title", "summary", "published", "updated"].contains(last.1)) || (last.0 == arxiv && ["doi", "journal_ref"].contains(last.1)) {
            fields[last.1, default: ""] += string
        } else if isPath(["feed", "entry", "author", "name"], namespace: atom) {
            fields["author", default: ""] += string
        }
    }

    func parser(_ parser: XMLParser, foundCDATA data: Data) {
        guard let text = String(data: data, encoding: .utf8) else { fail(parser); return }
        self.parser(parser, foundCharacters: text)
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        defer { path.removeLast() }
        if isPath(["feed", "entry", "author", "name"], namespace: atom) { authors.append(normalized(fields["author"] ?? "")) }
        if isPath(["feed", "entry"], namespace: atom) {
            do {
                let identifier = try ArxivIdentifier(normalized(fields["id"] ?? ""))
                if let pdfLink {
                    let pdfIdentifier = try ArxivIdentifier(pdfLink)
                    guard pdfIdentifier.canonical == identifier.canonical,
                          pdfIdentifier.version == nil || pdfIdentifier.version == identifier.version else { throw ArxivError.invalidFeed }
                }
                guard let published = date(fields["published"]), let updated = date(fields["updated"]) else { throw ArxivError.invalidFeed }
                entries.append(try ArxivMetadata(identifier: identifier, title: normalized(fields["title"] ?? ""), authors: authors,
                    abstract: normalized(fields["summary"] ?? ""), publishedAt: published, updatedAt: updated,
                    categories: categories, doi: optional(fields["doi"]), journalReference: optional(fields["journal_ref"]), hasPDF: pdfLink != nil))
            } catch { fail(parser) }
        }
    }

    private func isPath(_ names: [String], namespace: String) -> Bool {
        path.count == names.count && zip(path, names).allSatisfy { $0.0.0 == namespace && $0.0.1 == $0.1 }
    }
    private func normalized(_ value: String) -> String { value.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
    private func optional(_ value: String?) -> String? { value.map(normalized).flatMap { $0.isEmpty ? nil : $0 } }
    private func date(_ value: String?) -> Date? {
        guard let value else { return nil }
        let formatter = ISO8601DateFormatter()
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let result = formatter.date(from: text) { return result }
        formatter.formatOptions.insert(.withFractionalSeconds)
        return formatter.date(from: text)
    }
    private func fail(_ parser: XMLParser) { error = .invalidFeed; parser.abortParsing() }
}
