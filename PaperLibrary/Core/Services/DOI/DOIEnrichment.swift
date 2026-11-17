import Foundation

public enum DOIPublicURL {
    public static func validated(_ url: URL) -> URL? {
        guard url.absoluteString.utf8.count <= 4096,
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false), parts.scheme == "https",
              parts.user == nil, parts.password == nil, parts.port == nil, parts.fragment == nil,
              let host = parts.host?.lowercased(), host.contains("."),
              host.range(of: #"^[a-z0-9.-]+\.[a-z]{2,}$"#, options: .regularExpression) != nil,
              ![".localhost", ".local", ".internal", ".test", ".invalid"].contains(where: host.hasSuffix) else { return nil }
        return url
    }
}

public struct DOIEnrichment: Sendable {
    public let abstract: String
    public let pdfURL: URL?
}

public enum OpenAlexParser {
    public static func parse(_ data: Data, requested: DOIIdentifier) throws -> DOIEnrichment {
        guard data.count <= DOINetworkPolicy.maximumResponseBytes else { throw DOIError.responseTooLarge }
        let work: Work
        do { work = try JSONDecoder().decode(Work.self, from: data) }
        catch { throw DOIError.invalidResponse }
        guard let doi = try? DOIIdentifier(work.doi ?? ""), doi == requested else { throw DOIError.invalidResponse }
        let abstract = try reconstruct(work.abstractIndex)
        let locations = [work.bestOA, work.primary].compactMap { $0 } + (work.locations ?? [])
        let urls = locations.filter { $0.isOA == true }.compactMap { $0.pdfURL }.compactMap(URL.init(string:)).compactMap(DOIPublicURL.validated)
        let direct = urls.first(where: PDFSourcePolicy.canDownload)
        return DOIEnrichment(abstract: abstract, pdfURL: direct ?? urls.first)
    }

    private static func reconstruct(_ index: [String: [Int]]?) throws -> String {
        guard let index, !index.isEmpty else { return "" }
        var words: [Int: String] = [:]
        var characters = 0
        for (word, positions) in index {
            guard !word.isEmpty, !positions.isEmpty, word.count <= 4096 else { throw DOIError.invalidResponse }
            for position in positions {
                guard (0..<32_000).contains(position), words.updateValue(word, forKey: position) == nil else { throw DOIError.invalidResponse }
                characters += word.count + 1
                guard characters <= 192_000 else { throw DOIError.responseTooLarge }
            }
        }
        guard let last = words.keys.max(), last + 1 == words.count else { throw DOIError.invalidResponse }
        return (0...last).compactMap { words[$0] }.joined(separator: " ")
    }

    private struct Work: Decodable {
        let doi: String?
        let abstractIndex: [String: [Int]]?
        let bestOA: Location?
        let primary: Location?
        let locations: [Location]?
        enum CodingKeys: String, CodingKey {
            case doi, locations
            case abstractIndex = "abstract_inverted_index", bestOA = "best_oa_location", primary = "primary_location"
        }
    }
    private struct Location: Decodable {
        let isOA: Bool?
        let pdfURL: String?
        enum CodingKeys: String, CodingKey { case isOA = "is_oa", pdfURL = "pdf_url" }
    }
}
