import Foundation

public struct DOIMetadata: Sendable, Equatable {
    public let identifier: DOIIdentifier
    public let title: String
    public let authors: [String]
    public let abstract: String
    public let publishedAt: Date?
    public let journalReference: String?
    public let categories: [String]

    public init(identifier: DOIIdentifier, title: String, authors: [String] = [], abstract: String = "", publishedAt: Date? = nil, journalReference: String? = nil, categories: [String] = []) throws {
        let title = DOIText.plain(title)
        guard !title.isEmpty else { throw DOIError.invalidResponse }
        self.identifier = identifier; self.title = title
        self.authors = authors.map(DOIText.plain).filter { !$0.isEmpty }
        self.abstract = DOIText.plain(abstract); self.publishedAt = publishedAt
        self.journalReference = journalReference.map(DOIText.plain).flatMap { $0.isEmpty ? nil : $0 }
        self.categories = categories.map(DOIText.plain).filter { !$0.isEmpty }
    }
}

public enum DOIMetadataParser {
    public static func crossref(_ data: Data, requested: DOIIdentifier) throws -> DOIMetadata {
        let envelope: CrossrefEnvelope = try decode(data)
        let work = envelope.message
        guard envelope.status == "ok", try DOIIdentifier(work.doi) == requested else { throw DOIError.invalidResponse }
        let journal = work.containerTitle?.first
        let reference = [journal, work.volume, work.issue.map { "(\($0))" }, work.page ?? work.articleNumber].compactMap { $0 }.joined(separator: ", ")
        return try DOIMetadata(identifier: requested, title: work.title?.first ?? "", authors: (work.author ?? []).map(\.displayName),
            abstract: work.abstract ?? "", publishedAt: date(work.published ?? work.publishedOnline ?? work.publishedPrint ?? work.issued),
            journalReference: reference, categories: work.subject ?? [])
    }

    public static func datacite(_ data: Data, requested: DOIIdentifier) throws -> DOIMetadata {
        let envelope: DataCiteEnvelope = try decode(data)
        let work = envelope.data.attributes
        guard try DOIIdentifier(work.doi) == requested else { throw DOIError.invalidResponse }
        let abstract = work.descriptions?.first { $0.descriptionType?.lowercased() == "abstract" }?.description ?? ""
        let published = work.dates?.first { $0.dateType?.lowercased() == "issued" }?.date
        let components = published.flatMap { value -> [Int]? in
            let parts = value.split(separator: "-")
            let numbers = parts.compactMap { Int($0) }
            return numbers.count == parts.count ? numbers : nil
        } ?? work.publicationYear.map { [$0] }
        return try DOIMetadata(identifier: requested, title: work.titles.first?.title ?? "", authors: work.creators.map(\.displayName),
            abstract: abstract, publishedAt: components.flatMap(makeDate), journalReference: work.container?.title,
            categories: work.subjects?.map(\.subject) ?? [])
    }

    private static func decode<T: Decodable>(_ data: Data) throws -> T {
        guard data.count <= DOINetworkPolicy.maximumResponseBytes else { throw DOIError.responseTooLarge }
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw DOIError.invalidResponse }
    }
    private static func date(_ value: CrossrefDate?) -> Date? { value?.parts.first.flatMap(makeDate) }
    private static func makeDate(_ parts: [Int]) -> Date? {
        guard let year = parts.first, (1000...9999).contains(year), (1...3).contains(parts.count) else { return nil }
        let month = parts.count > 1 ? parts[1] : 1
        let day = parts.count > 2 ? parts[2] : 1
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let date = calendar.date(from: DateComponents(year: year, month: month, day: day)),
              calendar.component(.year, from: date) == year, calendar.component(.month, from: date) == month,
              calendar.component(.day, from: date) == day else { return nil }
        return date
    }
}

private struct CrossrefEnvelope: Decodable { let status: String; let message: CrossrefWork }
private struct CrossrefDate: Decodable {
    let parts: [[Int]]
    enum CodingKeys: String, CodingKey { case parts = "date-parts" }
}
private struct CrossrefAuthor: Decodable {
    let given: String?
    let family: String?
    let name: String?
    var displayName: String { name ?? [given, family].compactMap { $0 }.joined(separator: " ") }
}
private struct CrossrefWork: Decodable {
    let doi: String
    let title: [String]?
    let author: [CrossrefAuthor]?
    let abstract: String?
    let published: CrossrefDate?
    let publishedOnline: CrossrefDate?
    let publishedPrint: CrossrefDate?
    let issued: CrossrefDate?
    let containerTitle: [String]?
    let volume: String?
    let issue: String?
    let page: String?
    let articleNumber: String?
    let subject: [String]?
    enum CodingKeys: String, CodingKey {
        case doi = "DOI", title, author, abstract, published, issued, volume, issue, page, subject
        case publishedOnline = "published-online", publishedPrint = "published-print", containerTitle = "container-title", articleNumber = "article-number"
    }
}
private struct DataCiteEnvelope: Decodable {
    let data: Record
    struct Record: Decodable { let attributes: DataCiteWork }
}
private struct DataCiteWork: Decodable {
    let doi: String
    let titles: [Title]
    let creators: [Creator]
    let descriptions: [Description]?
    let publicationYear: Int?
    let dates: [WorkDate]?
    let container: Container?
    let subjects: [Subject]?
    struct Title: Decodable { let title: String }
    struct Container: Decodable { let title: String? }
    struct Creator: Decodable {
        let name: String?
        let givenName: String?
        let familyName: String?
        var displayName: String { [givenName, familyName].compactMap { $0 }.joined(separator: " ").nonEmpty ?? name ?? "" }
    }
    struct Description: Decodable { let description: String; let descriptionType: String? }
    struct WorkDate: Decodable { let date: String; let dateType: String? }
    struct Subject: Decodable { let subject: String }
}

private extension String { var nonEmpty: String? { isEmpty ? nil : self } }

private enum DOIText {
    static func plain(_ text: String) -> String {
        var result = text.replacingOccurrences(of: #"</?(?:[a-zA-Z0-9_-]+:)?(?:p|div|br|sec|title|list-item)(?:\s[^>]*)?/?>"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        let numeric = try! NSRegularExpression(pattern: #"&#(x[0-9a-fA-F]+|[0-9]+);"#)
        for match in numeric.matches(in: result, range: NSRange(result.startIndex..., in: result)).reversed() {
            guard let valueRange = Range(match.range(at: 1), in: result), let range = Range(match.range, in: result) else { continue }
            let value = String(result[valueRange])
            let number = value.hasPrefix("x") ? UInt32(value.dropFirst(), radix: 16) : UInt32(value)
            if let number, let scalar = UnicodeScalar(number) { result.replaceSubrange(range, with: String(scalar)) }
        }
        for (entity, value) in [("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&apos;", "'"), ("&nbsp;", " "), ("&amp;", "&")] {
            result = result.replacingOccurrences(of: entity, with: value)
        }
        return result.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
