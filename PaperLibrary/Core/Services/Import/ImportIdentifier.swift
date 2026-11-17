import Foundation
import PaperLibrarySupport

public struct DOIIdentifier: Hashable, Sendable {
    public let canonical: String
    public var canonicalURL: URL {
        var parts = URLComponents()
        parts.scheme = "https"; parts.host = "doi.org"; parts.path = "/" + canonical
        return parts.url!
    }

    public init(_ input: String) throws {
        var value = input.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\\:", with: ":")
        guard value.utf8.count <= 2048 else { throw DOIError.invalidIdentifier }
        if value.lowercased().hasPrefix("doi:") { value = String(value.dropFirst(4)).trimmingCharacters(in: .whitespaces) }
        if value.contains("://") {
            guard let parts = URLComponents(string: value), ["http", "https"].contains(parts.scheme?.lowercased() ?? ""),
                  ["doi.org", "www.doi.org", "dx.doi.org"].contains(parts.host?.lowercased() ?? ""),
                  parts.user == nil, parts.password == nil, parts.port == nil, parts.query == nil, parts.fragment == nil else {
                throw DOIError.invalidIdentifier
            }
            value = String(parts.path.dropFirst())
        }
        guard value.range(of: #"^10\.[0-9]{4,9}/\S+$"#, options: .regularExpression) != nil,
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              !value.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0 == "." || $0 == ".." || $0.isEmpty }) else {
            throw DOIError.invalidIdentifier
        }
        canonical = value.lowercased()
    }
}

public enum ImportIdentifier: Hashable, Sendable {
    case arxiv(ArxivIdentifier)
    case doi(DOIIdentifier)

    public init(_ input: String) throws {
        let value = input.replacingOccurrences(of: "\\:", with: ":")
        if let id = try? ArxivIdentifier(value) { self = .arxiv(id) }
        else { self = .doi(try DOIIdentifier(value)) }
    }

    public var canonical: String {
        switch self { case .arxiv(let id): id.canonical; case .doi(let id): id.canonical }
    }
    public var version: Int? {
        switch self { case .arxiv(let id): id.version; case .doi: nil }
    }
    public var identityKey: String {
        switch self { case .arxiv(let id): "arxiv:\(id.canonical)"; case .doi(let id): "doi:\(id.canonical)" }
    }
    public var queryValue: String { identityKey + (version.map { "v\($0)" } ?? "") }
    public var arxivIdentifier: ArxivIdentifier? { if case .arxiv(let id) = self { id } else { nil } }
    public var doiIdentifier: DOIIdentifier? { if case .doi(let id) = self { id } else { nil } }
}

public enum DOIError: LocalizedError, Equatable {
    case invalidIdentifier, invalidResponse, responseTooLarge, redirectRejected, notFound, cooldown
    case http(Int)

    public var errorDescription: String? {
        switch self {
        case .invalidIdentifier: Strings.text("import.invalidIdentifier")
        case .invalidResponse: Strings.text("doi.invalidResponse")
        case .responseTooLarge: Strings.text("arxiv.responseTooLarge")
        case .redirectRejected: Strings.text("doi.redirectRejected")
        case .notFound: Strings.text("doi.notFound")
        case .cooldown: Strings.text("doi.cooldown")
        case .http(let code): "\(Strings.text("doi.http")) \(code)"
        }
    }
}
