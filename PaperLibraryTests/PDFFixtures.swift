import CoreGraphics
import CoreText
import Foundation
@testable import PaperLibraryCore

enum PDFFixtures {
    static func document(pages: [String] = ["First page scientific method alpha", "Second page experimental evidence beta"]) -> Data {
        let buffer = CFDataCreateMutable(nil, 0)!
        let consumer = CGDataConsumer(data: buffer)!
        var rect = CGRect(x: 0, y: 0, width: 612, height: 792)
        let context = CGContext(consumer: consumer, mediaBox: &rect, nil)!
        for text in pages {
            context.beginPDFPage(nil)
            let attributes = [NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, 12, nil)]
            for (index, line) in text.components(separatedBy: .newlines).enumerated() {
                context.textPosition = CGPoint(x: 40, y: 700 - index * 18)
                CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: line, attributes: attributes)), context)
            }
            context.endPDFPage()
        }
        context.closePDF()
        return buffer as Data
    }
}

actor FixturePDFTransport: PDFTransport {
    var body: Data
    var delay = false
    var failure: URLError?
    var calls = 0
    init(body: Data = PDFFixtures.document()) { self.body = body }
    func configure(delay: Bool = false, failure: URLError? = nil, body: Data? = nil) {
        self.delay = delay; self.failure = failure; if let body { self.body = body }
    }
    func transfer(url: URL, staged: URL, limits: PDFLimits, fileStore: PDFFileStore, progress: @escaping @Sendable (Int64, Int64?) async -> Void) async throws -> PDFTransferReply {
        calls += 1
        try body.prefix(20).write(to: staged)
        await progress(20, Int64(body.count))
        if delay { try await Task.sleep(for: .seconds(60)) }
        if let failure { throw failure }
        try body.write(to: staged)
        await progress(Int64(body.count), Int64(body.count))
        return PDFTransferReply()
    }
}

actor FailingPDFExtractor: PDFExtracting {
    func extract(url: URL, limits: PDFLimits) throws -> ExtractedPDF { throw PDFLibraryError.extractionLimit }
}

actor FixturePDFMetadataExtractor: PDFMetadataExtracting {
    var calls: [(title: Bool, authors: Bool, abstract: Bool, text: String)] = []
    let result: RecoveredPDFMetadata
    let failure: AnalysisError?
    init(result: RecoveredPDFMetadata, failure: AnalysisError? = nil) { self.result = result; self.failure = failure }
    func extract(from text: String, needsTitle: Bool, needsAuthors: Bool, needsAbstract: Bool) throws -> RecoveredPDFMetadata {
        calls.append((needsTitle, needsAuthors, needsAbstract, text))
        if let failure { throw failure }
        return result
    }
}
