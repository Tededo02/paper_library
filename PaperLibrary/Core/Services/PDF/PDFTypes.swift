import CryptoKit
import Foundation
import PaperLibrarySupport

public enum PDFLibraryError: LocalizedError, Equatable {
    case invalidSource, invalidFile, tooLarge, diskSpace, unsafePath, checksum, missing, extractionLimit
    case http(Int)
    public var errorDescription: String? {
        switch self {
        case .http(let code): "\(Strings.text("pdf.error.http")) \(code)"
        default: Strings.text("pdf.error.\(key)")
        }
    }
    private var key: String {
        switch self {
        case .invalidSource: "invalidSource"
        case .invalidFile: "invalidFile"
        case .tooLarge: "tooLarge"
        case .diskSpace: "diskSpace"
        case .unsafePath: "unsafePath"
        case .checksum: "checksum"
        case .missing: "missing"
        case .extractionLimit: "extractionLimit"
        case .http: "http"
        }
    }
}

public struct PDFLimits: Sendable {
    public let maximumBytes: Int64
    public let reserveBytes: Int64
    public let maximumPages: Int
    public let maximumCharacters: Int
    public init(maximumBytes: Int64 = 100 * 1_048_576, reserveBytes: Int64 = 64 * 1_048_576, maximumPages: Int = 2000, maximumCharacters: Int = 8_000_000) {
        self.maximumBytes = max(1, min(maximumBytes, 1_073_741_824))
        self.reserveBytes = max(0, reserveBytes)
        self.maximumPages = max(1, min(maximumPages, 10_000))
        self.maximumCharacters = max(1, min(maximumCharacters, 32_000_000))
    }
}

public struct PDFFileReference: Sendable, Equatable {
    public let relativePath: String
    public let size: Int64
    public let checksum: String
    public let pageCount: Int
    public init(relativePath: String, size: Int64, checksum: String, pageCount: Int = 0) {
        self.relativePath = relativePath; self.size = size; self.checksum = checksum; self.pageCount = pageCount
    }
}

public enum PDFSourcePolicy {
    public static func validate(_ url: URL) throws -> ArxivIdentifier {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false), parts.scheme == "https",
              parts.host == "arxiv.org", parts.port == nil, parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil, parts.percentEncodedPath.hasPrefix("/pdf/") else { throw PDFLibraryError.invalidSource }
        let id = try ArxivIdentifier(url.absoluteString)
        guard id.version != nil, id.pdfURL == url else { throw PDFLibraryError.invalidSource }
        return id
    }
}

public enum PDFHash {
    public static func text(_ value: String) -> String { SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined() }
    public static func uuid(_ value: String) -> UUID {
        let h = Array(text(value).prefix(32))
        let parts = [0..<8, 8..<12, 12..<16, 16..<20, 20..<32].map { String(h[$0]) }
        return UUID(uuidString: parts.joined(separator: "-"))!
    }
}
