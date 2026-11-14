import Foundation
import PaperLibrarySupport

public enum ArxivError: LocalizedError, Equatable {
    case invalidIdentifier, unsupportedURL, invalidFeed, responseTooLarge, redirectRejected, notFound, wrongVersion
    case http(Int)
    case cooldown

    public var errorDescription: String? {
        switch self {
        case .http(let code): "\(Strings.text("arxiv.http")) \(code)"
        default: Strings.text("arxiv.\(key)")
        }
    }

    private var key: String {
        switch self {
        case .invalidIdentifier: "invalidIdentifier"
        case .unsupportedURL: "unsupportedURL"
        case .invalidFeed: "invalidFeed"
        case .responseTooLarge: "responseTooLarge"
        case .redirectRejected: "redirectRejected"
        case .notFound: "notFound"
        case .wrongVersion: "wrongVersion"
        case .cooldown: "cooldown"
        case .http: "http"
        }
    }
}

public struct ArxivIdentifier: Hashable, Sendable {
    public let canonical: String
    public let version: Int?
    public var queryValue: String { canonical + (version.map { "v\($0)" } ?? "") }
    public var canonicalURL: URL { URL(string: "https://arxiv.org/abs/\(canonical)")! }
    public var versionedURL: URL { URL(string: "https://arxiv.org/abs/\(queryValue)")! }
    public var pdfURL: URL { URL(string: "https://arxiv.org/pdf/\(queryValue)")! }

    public init(_ input: String) throws {
        var candidate = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty, candidate.utf8.count <= 512 else { throw ArxivError.invalidIdentifier }
        if candidate.lowercased().hasPrefix("arxiv:") { candidate = String(candidate.dropFirst(6)) }
        if candidate.contains("://") {
            guard let components = URLComponents(string: candidate),
                  ["https", "http"].contains(components.scheme?.lowercased() ?? ""),
                  ["arxiv.org", "www.arxiv.org", "export.arxiv.org"].contains(components.host?.lowercased() ?? ""),
                  components.user == nil, components.password == nil, components.port == nil,
                  components.query == nil, components.fragment == nil,
                  !components.percentEncodedPath.contains("%") else { throw ArxivError.unsupportedURL }
            let path = components.path
            guard path.hasPrefix("/abs/") || path.hasPrefix("/pdf/") else { throw ArxivError.unsupportedURL }
            candidate = String(path.dropFirst(5))
            if candidate.hasSuffix(".pdf") { candidate.removeLast(4) }
        }
        let pattern = #"^((?:[0-9]{2}(?:0[1-9]|1[0-2])\.[0-9]{4,5})|(?:[a-z][a-z0-9-]*(?:\.[A-Z]{2})?/[0-9]{2}(?:0[1-9]|1[0-2])[0-9]{3}))(?:v([1-9][0-9]{0,5}))?$"#
        let regex = try NSRegularExpression(pattern: pattern)
        let range = NSRange(candidate.startIndex..., in: candidate)
        guard let match = regex.firstMatch(in: candidate, range: range), let canonicalRange = Range(match.range(at: 1), in: candidate) else {
            throw ArxivError.invalidIdentifier
        }
        canonical = String(candidate[canonicalRange])
        if let versionRange = Range(match.range(at: 2), in: candidate) { version = Int(candidate[versionRange]) }
        else { version = nil }
    }
}

public struct ImportInput: Sendable {
    public let raw: String
    public let identifier: ArxivIdentifier?
    public let error: String?

    public static func parse(_ text: String) throws -> [Self] {
        guard text.utf8.count <= 65_536 else { throw ArxivError.responseTooLarge }
        let tokens = text.split { $0.isWhitespace || $0 == "," }.map(String.init)
        guard !tokens.isEmpty else { throw ArxivError.invalidIdentifier }
        guard tokens.count <= 500 else { throw ArxivError.responseTooLarge }
        var seen = Set<String>()
        return tokens.compactMap { token in
            do {
                let identifier = try ArxivIdentifier(token)
                guard seen.insert(identifier.queryValue).inserted else { return nil }
                return Self(raw: token, identifier: identifier, error: nil)
            } catch {
                guard seen.insert("invalid:\(token)").inserted else { return nil }
                return Self(raw: token, identifier: nil, error: error.localizedDescription)
            }
        }
    }
}
