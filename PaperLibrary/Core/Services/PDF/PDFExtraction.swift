import Foundation
import PDFKit

public struct ExtractedPDFPage: Sendable, Equatable {
    public let number: Int
    public let text: String
    public init(number: Int, text: String) { self.number = number; self.text = text }
}
public struct ExtractedPDF: Sendable {
    public let pages: [ExtractedPDFPage]
    public let totalPages: Int
    public let incomplete: Bool
}
public struct PDFChunk: Sendable, Equatable {
    public let index: Int
    public let text: String
    public let page: Int
    public var hash: String { PDFHash.text(text) }
    public func id(recordID: UUID) -> UUID { PDFHash.uuid("\(recordID):1:\(index):\(hash)") }
}

public protocol PDFExtracting: Sendable {
    func extract(url: URL, limits: PDFLimits) async throws -> ExtractedPDF
}

public actor PDFTextExtractor: PDFExtracting {
    public init() {}
    public func extract(url: URL, limits: PDFLimits) async throws -> ExtractedPDF {
        guard let document = PDFDocument(url: url), !document.isLocked, document.pageCount > 0 else { throw PDFLibraryError.invalidFile }
        var pages: [ExtractedPDFPage] = []
        var remaining = limits.maximumCharacters
        var incomplete = document.pageCount > limits.maximumPages
        for index in 0..<min(document.pageCount, limits.maximumPages) {
            try Task.checkCancellation()
            if remaining <= 0 { incomplete = true; break }
            let page = autoreleasepool { document.page(at: index)?.string ?? "" }
            let limit = min(remaining, 200_000)
            let text = String(page.prefix(limit)).replacingOccurrences(of: "\r\n", with: "\n")
            if page.count > limit || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { incomplete = true }
            pages.append(ExtractedPDFPage(number: index + 1, text: text))
            remaining -= text.count
        }
        let normalized = PDFTextNormalizer.normalize(pages)
        return ExtractedPDF(pages: normalized, totalPages: document.pageCount, incomplete: incomplete || normalized.contains { $0.text.isEmpty })
    }
}

public enum PDFTextNormalizer {
    public static func normalize(_ pages: [ExtractedPDFPage]) -> [ExtractedPDFPage] {
        let lines = pages.map { $0.text.components(separatedBy: .newlines).map { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") }.filter { !$0.isEmpty } }
        var edges: [String: Int] = [:]
        for page in lines where page.count >= 3 {
            for edge in Set([page.first, page.last].compactMap { $0 }) where (5...160).contains(edge.count) { edges[edge, default: 0] += 1 }
        }
        let repeated = Set(edges.filter { $0.value >= max(3, (pages.count + 1) / 2) }.map(\.key))
        return zip(pages, lines).map { page, original in
            var cleaned = original
            if cleaned.count >= 3 {
                if let first = cleaned.first, repeated.contains(first) { cleaned.removeFirst() }
                if let last = cleaned.last, repeated.contains(last) { cleaned.removeLast() }
            }
            return ExtractedPDFPage(number: page.number, text: cleaned.joined(separator: "\n"))
        }
    }
}

public enum PDFChunker {
    public static func chunks(pages: [ExtractedPDFPage], maximumCharacters: Int = 3000, overlap: Int = 300) throws -> [PDFChunk] {
        let size = max(100, maximumCharacters)
        let overlap = max(0, min(overlap, size / 2))
        var result: [PDFChunk] = []
        for page in pages {
            let characters = Array(page.text)
            var start = 0
            while start < characters.count {
                try Task.checkCancellation()
                var end = min(start + size, characters.count)
                if end < characters.count, let split = (max(start + size * 3 / 4, start + 1)..<end).last(where: { characters[$0].isWhitespace }) { end = split }
                let text = String(characters[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { result.append(PDFChunk(index: result.count, text: text, page: page.number)) }
                if end == characters.count { break }
                start = max(start + 1, end - overlap)
            }
        }
        return result
    }
}

public actor PDFChunkingService {
    public init() {}
    public func chunks(pages: [ExtractedPDFPage]) throws -> [PDFChunk] { try PDFChunker.chunks(pages: pages) }
}
