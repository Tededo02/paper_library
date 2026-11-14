import CoreGraphics
import CoreText
import CryptoKit
import Darwin
import Foundation
import FoundationModels
import PaperLibraryCore
import PaperLibrarySupport
import SwiftData

enum AILiveFailure: Error { case failed(String) }

actor LiveAppleModel: OnDeviceAnalysisModel {
    private let model = AppleAnalysisModel(validationFailure: { message in
        FileHandle.standardError.write(Data("\(message)\n".utf8))
    })
    func availability(language: String) async -> AIAvailability { await model.availability(language: language) }
    func generate(request: AnalysisRequest, material: String, aggregation: Bool) async throws -> AnalysisOutput {
        let output = try await model.generate(request: request, material: material, aggregation: aggregation)
        let json = String(decoding: try JSONEncoder().encode(output), as: UTF8.self)
        FileHandle.standardOutput.write(Data("Synthetic \(aggregation ? "aggregation" : "excerpt") output: \(json)\n".utf8))
        return output
    }
}

actor LivePDFMetadataModel: PDFMetadataExtracting {
    func extract(from text: String, needsTitle: Bool, needsAuthors: Bool, needsAbstract: Bool) async throws -> RecoveredPDFMetadata {
        let result = try await ApplePDFMetadataExtractor().extract(from: text, needsTitle: needsTitle, needsAuthors: needsAuthors, needsAbstract: needsAbstract)
        FileHandle.standardOutput.write(Data("Public PDF raw title: \(result.title)\nRaw authors: \(result.authors.joined(separator: "; "))\nRaw abstract: \(result.abstract)\n".utf8))
        return result
    }
}

@main
struct AILiveCheck {
    @MainActor static func main() async {
        if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--pdf-metadata" {
            do { try await pdfMetadata(at: URL(fileURLWithPath: CommandLine.arguments[2])) }
            catch { FileHandle.standardError.write(Data("PDF metadata check failed: \(error)\n".utf8)); exit(1) }
            return
        }
        if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--pdf-sections" {
            do { try await pdfSections(at: URL(fileURLWithPath: CommandLine.arguments[2])) }
            catch { FileHandle.standardError.write(Data("PDF sections check failed: \(error)\n".utf8)); exit(1) }
            return
        }
        if CommandLine.arguments.count == 3, ["--public-abstracts", "--review-regression"].contains(CommandLine.arguments[1]) {
            do { try await publicAbstracts(at: URL(fileURLWithPath: CommandLine.arguments[2]), reviewOnly: CommandLine.arguments[1] == "--review-regression") }
            catch { FileHandle.standardError.write(Data("Public abstract check failed: \(error)\n".utf8)); exit(1) }
            return
        }
        guard CommandLine.arguments.dropFirst() == ["--live"] else { print("Usage: swift run AILiveCheck --live"); return }
        do { try await run() }
        catch { FileHandle.standardError.write(Data("AI live check failed: \(error)\n".utf8)); exit(1) }
    }
    private struct PublicAbstract: Decodable { let title: String; let abstract: String }
    @MainActor private static func pdfMetadata(at url: URL) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PaperLibraryMetadataLive-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try LibraryRepository(store: LibraryStore.open(configuration: .testing(at: root)))
        let pdfs = PDFCoordinator.local(repository: repo, metadataExtractor: LivePDFMetadataModel())
        let metadata = try await pdfs.files.inspectLocal(url, limits: PDFLimits())
        let recovered = try await pdfs.recoverLocalMetadata(metadata)
        let draft = recovered.fillingMissing(in: PaperDraft(title: "", authors: metadata.authors, abstract: metadata.abstract), fallbackTitle: metadata.filenameTitle)
        print("Validated title: \(recovered.title); authors: \(draft.authors.count); abstract characters: \(draft.abstract.count)")
        guard !recovered.title.isEmpty, !draft.authors.isEmpty, !draft.abstract.isEmpty else { throw AILiveFailure.failed("Missing title, authors or abstract after extraction") }
        print("PASS: PDF metadata recovered locally · \(draft.authors.count) grounded authors · \(draft.abstract.count) abstract characters")
        print("Public PDF title: \(draft.title)")
        print("Public PDF authors: \(draft.authors.joined(separator: "; "))")
        print("Public PDF abstract: \(draft.abstract)")
    }
    private struct PublicPDFPage: Decodable { let number: Int; let text: String }
    @MainActor private static func pdfSections(at url: URL) async throws {
        let pages = try JSONDecoder().decode([PublicPDFPage].self, from: Data(contentsOf: url))
        let all = try PDFAnalysisSource.parts(pages: pages.map { ExtractedPDFPage(number: $0.number, text: $0.text) })
        let selected = PDFAnalysisSource.selectedIndices(sections: all.map(\.section), limit: 64).map { all[$0] }
        let source = AnalysisSourceSnapshot(kind: .pdf, hash: PDFHash.text(selected.map(\.text).joined()), parts: selected, incomplete: all.count > selected.count)
        let pipeline = AnalysisPipeline(model: LiveAppleModel())
        let profile = BuiltinAnalysisProfiles.definitions.first { $0.0 == PDFHash.uuid("profile.review") }!
        print("PDF main text: \(selected.count) parts over \(Set(selected.compactMap(\.page)).count) pages; \(selected.map(\.text).joined().count) characters; context \(SystemLanguageModel.default.contextSize) tokens")
        for language in ["en", "it"] {
            let result = try await pipeline.run(source: source, request: AnalysisRequest(profile: profile.2, language: language, sourceKind: .pdf)) { _ in }
            try AnalysisValidation.language(output: result.output, requested: language)
            guard !result.citations.isEmpty, result.citations.allSatisfy({ $0.page != nil }) else { throw AILiveFailure.failed("Missing PDF page provenance") }
            print("PASS: PDF sections · Research Review · \(language) · \(result.processedParts) processed parts · \(result.citations.count) verified references · partial \(result.incomplete)")
        }
    }
    @MainActor private static func publicAbstracts(at url: URL, reviewOnly: Bool) async throws {
        let fixtures = try JSONDecoder().decode([PublicAbstract].self, from: Data(contentsOf: url))
        let model = LiveAppleModel()
        let pipeline = AnalysisPipeline(model: model)
        print("Installed model context: \(SystemLanguageModel.default.contextSize) tokens")
        var failed = 0
        for fixture in fixtures {
            for (id, name, instructions) in BuiltinAnalysisProfiles.definitions where !reviewOnly || id == PDFHash.uuid("profile.review") {
                for language in ["en", "it"] {
                    let source = AnalysisSourceSnapshot(kind: .abstract, hash: PDFHash.text(fixture.abstract), parts: [AnalysisSourcePart(id: "abstract", text: fixture.abstract)])
                    do {
                        let result = try await pipeline.run(source: source, request: AnalysisRequest(profile: instructions, language: language, sourceKind: .abstract)) { _ in }
                        try AnalysisValidation.language(output: result.output, requested: language)
                        print("PASS: \(fixture.title) · \(name) · \(language) · \(result.citations.count) verified references")
                    } catch { failed += 1; print("FAIL: \(fixture.title) · \(name) · \(language): \(error)") }
                }
            }
        }
        guard failed == 0 else { throw AILiveFailure.failed("\(failed) public abstract analyses failed") }
    }
    @MainActor private static func run() async throws {
        let model = LiveAppleModel()
        let status = await model.availability(language: "it")
        print("On-device availability: \(status.rawValue)")
        guard status == .available else { throw AILiveFailure.failed(status.message) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PaperLibraryAILive-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore.open(configuration: .testing(at: root))
        let repo = try LibraryRepository(store: store)
        let source = "We propose a sparse graph method for robot localization. The method represents observations as nodes and geometric constraints as edges. No experiments, datasets or quantitative results are specified in this abstract."
        let paper = try repo.addPaper(PaperDraft(title: "Synthetic graph method fixture", abstract: source))
        try repo.saveNotes(paperID: paper.id, notes: "Private fixture note, excluded from inference input")
        let ai = AnalysisCoordinator(repository: repo, model: model)
        for language in ["it", "en"] {
            try ai.enqueue(paperID: paper.id, profileID: BuiltinAnalysisProfiles.quickID, kind: .abstract, recordID: nil, language: language)
            await ai.waitUntilIdle()
            guard let result = try repo.analyses(paperID: paper.id).first, result.language == language, repo.aiJobs.last?.state == .completed else {
                throw AILiveFailure.failed(repo.aiJobs.last?.errorMessage ?? "Abstract analysis missing")
            }
            let output = try JSONDecoder().decode(AnalysisOutput.self, from: Data(result.contentJSON.utf8))
            print("PASS: \(language) abstract analysis saved with \(output.points.count) quote-validated points; synthetic output: \(output.plainText)")
        }
        let pages = ["The algorithm builds a sparse graph from geometric observations. Nodes represent observations and edges represent constraints.", "The method assumes geometric observations are available. The document reports no experimental evaluation or numerical results."]
        let url = root.appendingPathComponent("synthetic.pdf")
        try document(pages: pages).write(to: url)
        let extracted = try await PDFTextExtractor().extract(url: url, limits: PDFLimits())
        let chunks = try await PDFChunkingService().chunks(pages: extracted.pages)
        let pdfData = try Data(contentsOf: url)
        let checksum = SHA256.hash(data: pdfData).map { String(format: "%02x", $0) }.joined()
        let record = PDFDocumentRecord(paperID: paper.id, version: 1, relativePath: "synthetic.pdf", fileSize: Int64(pdfData.count), checksum: checksum)
        record.indexStatus = "chunksReady"; record.extractionStatus = extracted.incomplete ? "incomplete" : "completed"; record.pageCount = extracted.totalPages
        let context = store.container.mainContext
        context.insert(record)
        for chunk in chunks { context.insert(TextChunk(id: chunk.id(recordID: record.id), paperID: paper.id, recordID: record.id, chunkIndex: chunk.index, text: chunk.text, startPage: chunk.page, endPage: chunk.page, contentHash: chunk.hash)) }
        try context.save(); try repo.reload()
        let technicalID = PDFHash.uuid("profile.technical")
        try ai.enqueue(paperID: paper.id, profileID: technicalID, kind: .pdf, recordID: record.id, language: "it")
        await ai.waitUntilIdle()
        guard let full = try repo.analyses(paperID: paper.id).first, full.sourceKind == "pdf", full.processedParts == 2, !full.incomplete, repo.aiJobs.last?.state == .completed else {
            throw AILiveFailure.failed(repo.aiJobs.last?.errorMessage ?? "PDF analysis missing")
        }
        let citations = try JSONDecoder().decode([AnalysisCitation].self, from: Data(full.provenanceJSON.utf8))
        guard !citations.isEmpty, citations.allSatisfy({ $0.page == 1 || $0.page == 2 }) else { throw AILiveFailure.failed("Invalid source-page provenance") }
        print("PASS: Real PDFKit extraction and staged on-device synthesis completed with verified source-page provenance.")
        let fullOutput = try JSONDecoder().decode(AnalysisOutput.self, from: Data(full.contentJSON.utf8))
        print("Synthetic PDF output: \(fullOutput.plainText)")
        try repo.editAnalysis(id: full.id, text: "Preserved personal correction")
        do {
            try ai.enqueue(paperID: paper.id, profileID: technicalID, kind: .pdf, recordID: record.id, language: "it")
            throw AILiveFailure.failed("Missing regeneration confirmation")
        } catch AnalysisError.edited {}
        guard full.userContent == "Preserved personal correction", paper.notes == "Private fixture note, excluded from inference input" else { throw AILiveFailure.failed("User content changed") }
        print("PASS: Edited-result confirmation and private-note preservation. No production library, network provider or remote inference was used.")
    }
    private static func document(pages: [String]) throws -> Data {
        guard let buffer = CFDataCreateMutable(nil, 0), let consumer = CGDataConsumer(data: buffer) else { throw AILiveFailure.failed("PDF fixture allocation") }
        var rect = CGRect(x: 0, y: 0, width: 1000, height: 792)
        guard let context = CGContext(consumer: consumer, mediaBox: &rect, nil) else { throw AILiveFailure.failed("PDF fixture context") }
        for text in pages {
            context.beginPDFPage(nil); context.textPosition = CGPoint(x: 30, y: 700)
            let attributes = [NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, 9, nil)]
            CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes)), context)
            context.endPDFPage()
        }
        context.closePDF(); return buffer as Data
    }
}
