import Foundation
import PaperLibrarySupport

public typealias Course = LibrarySchemaV5.Course
public typealias Paper = LibrarySchemaV5.Paper
public typealias CoursePaper = LibrarySchemaV5.CoursePaper

public enum ReadingStatus: String, CaseIterable, Codable, Sendable {
    case toRead, reading, read, archived

    public var localizedName: String { Strings.text("status.\(rawValue)") }
}

extension Paper {
    public var readingStatus: ReadingStatus { ReadingStatus(rawValue: readingStatusRaw) ?? .toRead }
    public var pdfDownloadURL: URL? {
        if provider == "arxiv", let raw = providerIdentifier, let version = resolvedVersion {
            return try? ArxivIdentifier(raw + "v\(version)").pdfURL
        }
        guard provider == "doi", let url = pdfSourceURL.flatMap(URL.init(string:)), PDFSourcePolicy.canDownload(url) else { return nil }
        return url
    }
    public var publisherPDFURL: URL? {
        if let url = pdfSourceURL.flatMap(URL.init(string:)).flatMap(DOIPublicURL.validated) { return url }
        return doi.flatMap { try? DOIIdentifier($0).canonicalURL }
    }
}

public typealias ImportJob = LibrarySchemaV5.ImportJob

public enum ImportJobState: String, CaseIterable, Sendable {
    case pending, inProgress, completed, failed, cancelled, interrupted
    public var localizedName: String { Strings.text("job.\(rawValue)") }
    public var canRetry: Bool { self == .failed || self == .cancelled || self == .interrupted }
}

extension ImportJob {
    public var state: ImportJobState { ImportJobState(rawValue: stateRaw) ?? .failed }
    public var identifier: ImportIdentifier? {
        guard let canonicalIdentifier else { return nil }
        return try? ImportIdentifier(canonicalIdentifier + requestedVersion.map { "v\($0)" }.orEmpty)
    }
}

extension Optional where Wrapped == String {
    fileprivate var orEmpty: String { self ?? "" }
}

public typealias PDFDocumentRecord = LibrarySchemaV5.PDFDocumentRecord
public typealias PDFProcessingJob = LibrarySchemaV5.PDFProcessingJob
public typealias PDFPageText = LibrarySchemaV5.PDFPageText
public typealias TextChunk = LibrarySchemaV5.TextChunk

extension PDFProcessingJob {
    public var state: ImportJobState { ImportJobState(rawValue: stateRaw) ?? .failed }
}

public typealias AIAnalysis = LibrarySchemaV5.AIAnalysis
public typealias AIProcessingJob = LibrarySchemaV5.AIProcessingJob
public typealias AnalysisProfile = LibrarySchemaV5.AnalysisProfile
public typealias Topic = LibrarySchemaV5.Topic
public typealias PaperTopic = LibrarySchemaV5.PaperTopic

extension AnalysisProfile {
    public var displayName: String { BuiltinAnalysisProfiles.displayName(id: id, name: name) }
}

extension AIProcessingJob {
    public var state: ImportJobState { ImportJobState(rawValue: stateRaw) ?? .failed }
}
