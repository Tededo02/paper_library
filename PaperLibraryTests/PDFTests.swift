import Foundation
import PDFKit
import SwiftData
import Testing
import PaperLibrarySupport
@testable import PaperLibraryCore

@Suite(.serialized)
@MainActor
struct PDFTests {
    private func config() throws -> StorageConfiguration {
        try .testing(at: FileManager.default.temporaryDirectory.appendingPathComponent("PaperLibraryPDFTests-\(UUID().uuidString)"))
    }
    private func imported(_ repo: LibraryRepository) async throws -> Paper {
        let queue = ImportCoordinator(repository: repo, provider: FixtureArxivProvider())
        try queue.enqueue(text: "1706.03762v1", destinationCourseID: nil, assignExisting: true, refreshMetadata: false)
        await queue.waitUntilIdle()
        return try #require(repo.papers.first)
    }
    private func coordinator(_ repo: LibraryRepository, transport: FixturePDFTransport, metadataExtractor: any PDFMetadataExtracting = ApplePDFMetadataExtractor()) -> PDFCoordinator {
        let files = PDFFileStore(configuration: repo.store.configuration)
        let scheduler = ArxivRequestScheduler(transport: MockArxivTransport(clock: TestArxivClock(), responses: []), clock: TestArxivClock())
        return PDFCoordinator(repository: repo, files: files, downloader: PDFDownloader(files: files, scheduler: scheduler, transport: transport), metadataExtractor: metadataExtractor)
    }

    @Test func missingPDFMetadataIsRecoveredGroundedAndSaved() async throws {
        let c = try config(); defer { try? FileManager.default.removeItem(at: c.root) }
        try FileManager.default.createDirectory(at: c.root, withIntermediateDirectories: true)
        let abstract = "We introduce a geometric method for reconstructing scientific observations. The method preserves explicit constraints from the supplied measurements."
        let source = c.root.appendingPathComponent("paper.pdf")
        try PDFFixtures.document(pages: ["An Offline Paper\nAlice Example; Bob Researcher\nAbstract\nWe introduce a geometric method for reconstructing scientific observations.\nThe method preserves explicit constraints from the supplied measurements.\n1. Introduction\nThis body paragraph must not be sent to the metadata model."]).write(to: source)
        let model = FixturePDFMetadataExtractor(result: RecoveredPDFMetadata(title: "An Offline Paper", authors: ["Alice Example", "Invented Person", "Bob Researcher"], abstract: abstract))
        let repo = try LibraryRepository(store: LibraryStore.open(configuration: c))
        let pdfs = coordinator(repo, transport: FixturePDFTransport(), metadataExtractor: model)
        let metadata = try await pdfs.files.inspectLocal(source, limits: pdfs.limits)
        let recovered = try await pdfs.recoverLocalMetadata(metadata)
        #expect(recovered.authors == ["Alice Example", "Bob Researcher"]); #expect(recovered.abstract == abstract)
        let requests = await model.calls
        #expect(requests.count == 1); #expect(requests[0].title && requests[0].authors && requests[0].abstract)
        #expect(!requests[0].text.contains("must not be sent"))
        let draft = recovered.fillingMissing(in: PaperDraft(title: "", authors: metadata.authors, abstract: metadata.abstract), fallbackTitle: metadata.filenameTitle)
        let id = try await pdfs.importLocalPDF(from: source, draft: draft)
        await pdfs.waitUntilIdle()
        #expect(repo.paper(id: id)?.authors == recovered.authors)
        #expect(repo.paper(id: id)?.abstract == abstract)
        #expect(repo.paper(id: id)?.title == "An Offline Paper")
    }

    @Test func titleIsRequestedEvenWhenAuthorsAndAbstractArePresent() async throws {
        let c = try config(); defer { try? FileManager.default.removeItem(at: c.root) }
        try FileManager.default.createDirectory(at: c.root, withIntermediateDirectories: true)
        let abstract = "The paper introduces an explicit geometric method. It evaluates the resulting reconstruction using scientific observations."
        let data = PDFFixtures.document(pages: ["Embedded Author\nAbstract\n\(abstract.replacingOccurrences(of: ". It", with: ".\nIt"))"])
        let model = FixturePDFMetadataExtractor(result: RecoveredPDFMetadata(authors: ["Embedded Author"], abstract: abstract))
        let repo = try LibraryRepository(store: LibraryStore.open(configuration: c))
        let pdfs = coordinator(repo, transport: FixturePDFTransport(), metadataExtractor: model)
        for (index, includeAuthors, includeAbstract) in [(0, true, true), (1, true, false), (2, false, true)] {
            let document = try #require(PDFDocument(data: data))
            var attributes: [AnyHashable: Any] = [:]
            if includeAuthors { attributes[PDFDocumentAttribute.authorAttribute] = "Embedded Author" }
            if includeAbstract { attributes[PDFDocumentAttribute.subjectAttribute] = "Abstract:\n\(abstract)" }
            document.documentAttributes = attributes
            let source = c.root.appendingPathComponent("paper-\(index).pdf")
            try #require(document.dataRepresentation()).write(to: source)
            let metadata = try await pdfs.files.inspectLocal(source, limits: pdfs.limits)
            let recovered = try await pdfs.recoverLocalMetadata(metadata)
            if includeAuthors && includeAbstract { #expect(recovered.authors.isEmpty && recovered.abstract.isEmpty) }
            else if includeAuthors { #expect(recovered.authors.isEmpty); #expect(recovered.abstract == abstract) }
            else { #expect(recovered.authors == ["Embedded Author"]); #expect(recovered.abstract.isEmpty) }
        }
        let requests = await model.calls
        #expect(requests.count == 3); #expect(requests.allSatisfy { $0.title })
        #expect(!requests[0].authors && !requests[0].abstract)
        #expect(!requests[1].authors && requests[1].abstract); #expect(requests[2].authors && !requests[2].abstract)
    }

    @Test func modelTitleIsPreferredAndFilenameIsOnlyAFallback() throws {
        let source = "A Geometric Method:\nScientific Reconstruction\nAlice Example\nAbstract\nA long original abstract describes the method and its scientific motivation."
        let result = PDFMetadataValidation.grounded(RecoveredPDFMetadata(title: "A Geometric Method: Scientific Reconstruction"), source: source, needsAuthors: false, needsAbstract: false)
        let draft = result.fillingMissing(in: PaperDraft(title: ""), fallbackTitle: "download-123")
        #expect(draft.title == "A Geometric Method: Scientific Reconstruction")
        let failed = PDFMetadataValidation.grounded(RecoveredPDFMetadata(title: "An invented unrelated title"), source: source, needsAuthors: false, needsAbstract: false)
        #expect(failed.title.isEmpty)
        #expect(failed.fillingMissing(in: PaperDraft(title: ""), fallbackTitle: "download-123").title == "download-123")
        let identifier = PDFMetadataValidation.grounded(RecoveredPDFMetadata(title: "arXiv:2307.05473v2"), source: "arXiv:2307.05473v2\n" + source, needsAuthors: false, needsAbstract: false)
        #expect(identifier.title.isEmpty)
    }

    @Test func manualTitleEditsArePreservedDuringModelRecovery() {
        let recovered = RecoveredPDFMetadata(title: "Model title")
        #expect(recovered.fillingMissing(in: PaperDraft(title: "My title"), fallbackTitle: "filename").title == "My title")
        #expect(recovered.fillingMissing(in: PaperDraft(title: ""), fallbackTitle: "filename", protectTitle: true).title.isEmpty)
        #expect(RecoveredPDFMetadata().fillingMissing(in: PaperDraft(title: ""), fallbackTitle: "filename").title == "filename")
    }

    @Test func nearExactAbstractTranscriptionResolvesToTheOriginalSource() {
        let original = "Given calibrated images of a scientific scene, we present a compact geometric representation using textured primitives. The method preserves the observed surface structure and supports physical simulation without adding unsupported assumptions. We also show how these results can be used to edit scenes and perform physical simulations."
        let candidate = original.replacingOccurrences(of: "can be used to edit", with: "can edit")
        let source = "A Scientific Paper\nAlice Example\nAbstract\n" + original + "\n1. Introduction\nAn unrelated body paragraph."
        let result = PDFMetadataValidation.grounded(RecoveredPDFMetadata(abstract: candidate), source: source, needsAuthors: false, needsAbstract: true)
        #expect(result.abstract == original)
        #expect(result.abstract != candidate)
    }

    @Test func modelReadsTitleInsteadOfTrustingEmbeddedOrFilenameTitle() async throws {
        let c = try config(); defer { try? FileManager.default.removeItem(at: c.root) }
        try FileManager.default.createDirectory(at: c.root, withIntermediateDirectories: true)
        let document = try #require(PDFDocument(data: PDFFixtures.document(pages: ["The Printed Article Title\nAlice Example\nAbstract\nThe paper describes a scientific geometric reconstruction method."])))
        document.documentAttributes = [PDFDocumentAttribute.titleAttribute: "Generic publisher export"]
        let source = c.root.appendingPathComponent("download-123.pdf")
        try #require(document.dataRepresentation()).write(to: source)
        let repo = try LibraryRepository(store: LibraryStore.open(configuration: c))
        let model = FixturePDFMetadataExtractor(result: RecoveredPDFMetadata(title: "The Printed Article Title"))
        let pdfs = coordinator(repo, transport: FixturePDFTransport(), metadataExtractor: model)
        let metadata = try await pdfs.files.inspectLocal(source, limits: pdfs.limits)
        let result = try await pdfs.recoverLocalMetadata(metadata)
        let draft = result.fillingMissing(in: PaperDraft(title: ""), fallbackTitle: metadata.filenameTitle)
        #expect(metadata.title == "Generic publisher export"); #expect(metadata.filenameTitle == "download-123")
        #expect(draft.title == "The Printed Article Title"); #expect(await model.calls.first?.title == true)
    }

    @Test func reimportCanReplaceFilenameTitleButPreservesCustomTitlesAndFallbacks() async throws {
        let c = try config(); defer { try? FileManager.default.removeItem(at: c.root) }
        try FileManager.default.createDirectory(at: c.root, withIntermediateDirectories: true)
        let source = c.root.appendingPathComponent("download-123.pdf")
        try PDFFixtures.document().write(to: source)
        let repo = try LibraryRepository(store: LibraryStore.open(configuration: c))
        let pdfs = coordinator(repo, transport: FixturePDFTransport())
        let id = try await pdfs.importLocalPDF(from: source, draft: PaperDraft(title: "download-123"))
        await pdfs.waitUntilIdle()
        let renamed = c.root.appendingPathComponent("managed-copy.pdf")
        try FileManager.default.copyItem(at: source, to: renamed)
        _ = try await pdfs.importLocalPDF(from: renamed, draft: PaperDraft(title: "managed-copy"))
        #expect(repo.paper(id: id)?.title == "download-123")
        _ = try await pdfs.importLocalPDF(from: renamed, draft: PaperDraft(title: "The Actual Printed Title"))
        #expect(repo.paper(id: id)?.title == "The Actual Printed Title")
        try repo.updateMetadata(paperID: id, draft: PaperDraft(title: "My Custom Title"))
        _ = try await pdfs.importLocalPDF(from: source, draft: PaperDraft(title: "Another Model Title"))
        #expect(repo.papers.count == 1); #expect(repo.paper(id: id)?.title == "My Custom Title")
    }

    @Test func recoveredMetadataCannotInventTextOrOverwriteManualEdits() throws {
        let source = "Alice Example\nAbstract\nWe introduce a geomet-\nric reconstruction method with explicit scientific constraints."
        let valid = RecoveredPDFMetadata(authors: ["Alice Example"], abstract: "We introduce a geometric reconstruction method with explicit scientific constraints.")
        let grounded = PDFMetadataValidation.grounded(valid, source: source, needsAuthors: true, needsAbstract: true)
        #expect(grounded.authors == valid.authors); #expect(grounded.abstract == valid.abstract)
        let titledSource = "Abstract Interpretation for Scientific Models\n" + source
        #expect(PDFMetadataValidation.grounded(valid, source: titledSource, needsAuthors: true, needsAbstract: true).authors == valid.authors)
        let invented = PDFMetadataValidation.grounded(RecoveredPDFMetadata(authors: ["Unknown Person"], abstract: "This paper achieves impressive accuracy on many previously unmentioned datasets."), source: source, needsAuthors: true, needsAbstract: true)
        #expect(invented.authors.isEmpty); #expect(invented.abstract.isEmpty)
        let manual = PaperDraft(title: "My title", authors: ["My author"], abstract: "My abstract")
        let retained = grounded.fillingMissing(in: manual)
        #expect(retained.title == manual.title); #expect(retained.authors == manual.authors); #expect(retained.abstract == manual.abstract)
        let deliberatelyCleared = grounded.fillingMissing(in: PaperDraft(title: "Keep empty"), protectAuthors: true, protectAbstract: true)
        #expect(deliberatelyCleared.authors.isEmpty); #expect(deliberatelyCleared.abstract.isEmpty)
    }

    @Test func duplicateLocalImportFillsOnlyMissingAuthorsAndAbstract() async throws {
        let c = try config(); defer { try? FileManager.default.removeItem(at: c.root) }
        try FileManager.default.createDirectory(at: c.root, withIntermediateDirectories: true)
        let source = c.root.appendingPathComponent("paper.pdf")
        try PDFFixtures.document().write(to: source)
        let repo = try LibraryRepository(store: LibraryStore.open(configuration: c))
        let pdfs = coordinator(repo, transport: FixturePDFTransport())
        let id = try await pdfs.importLocalPDF(from: source, draft: PaperDraft(title: "Keep my title"))
        await pdfs.waitUntilIdle()
        let recoveredDraft = PaperDraft(title: "Do not replace title", authors: ["Recovered Author"], abstract: "Recovered original abstract.")
        #expect(try await pdfs.importLocalPDF(from: source, draft: recoveredDraft) == id)
        #expect(repo.paper(id: id)?.title == "Keep my title"); #expect(repo.paper(id: id)?.authors == recoveredDraft.authors)
        #expect(repo.paper(id: id)?.abstract == recoveredDraft.abstract)
        try repo.updateMetadata(paperID: id, draft: PaperDraft(title: "Edited title", authors: ["Edited Author"], abstract: "Edited abstract."))
        _ = try await pdfs.importLocalPDF(from: source, draft: recoveredDraft)
        #expect(repo.paper(id: id)?.authors == ["Edited Author"]); #expect(repo.paper(id: id)?.abstract == "Edited abstract.")
    }

    @Test func unavailableMetadataModelStillAllowsLocalImport() async throws {
        let c = try config(); defer { try? FileManager.default.removeItem(at: c.root) }
        try FileManager.default.createDirectory(at: c.root, withIntermediateDirectories: true)
        let source = c.root.appendingPathComponent("paper.pdf")
        try PDFFixtures.document().write(to: source)
        let model = FixturePDFMetadataExtractor(result: RecoveredPDFMetadata(), failure: .unavailable(.modelNotReady))
        let repo = try LibraryRepository(store: LibraryStore.open(configuration: c))
        let pdfs = coordinator(repo, transport: FixturePDFTransport(), metadataExtractor: model)
        let metadata = try await pdfs.files.inspectLocal(source, limits: pdfs.limits)
        await #expect(throws: AnalysisError.unavailable(.modelNotReady)) { try await pdfs.recoverLocalMetadata(metadata) }
        let id = try await pdfs.importLocalPDF(from: source, draft: PaperDraft(title: metadata.title))
        await pdfs.waitUntilIdle()
        #expect(repo.pdfRecords(paperID: id).first?.indexStatus == "chunksReady")
    }

    @Test func localImportCopiesExtractsAndDeduplicatesWithoutNetworkOrMetadataLoss() async throws {
        let c = try config(); defer { try? FileManager.default.removeItem(at: c.root) }
        try FileManager.default.createDirectory(at: c.root, withIntermediateDirectories: true)
        let source = c.root.appendingPathComponent("original-paper.pdf")
        let document = try #require(PDFDocument(data: PDFFixtures.document()))
        document.documentAttributes = [PDFDocumentAttribute.titleAttribute: "An Offline Paper", PDFDocumentAttribute.authorAttribute: "Alice; Bob"]
        let original = try #require(document.dataRepresentation())
        try original.write(to: source)
        let repo = try LibraryRepository(store: LibraryStore.open(configuration: c))
        let firstCourse = try repo.addCourse(name: "First course")
        let secondCourse = try repo.addCourse(name: "Second course")
        let transport = FixturePDFTransport()
        let pdfs = coordinator(repo, transport: transport)
        let metadata = try await pdfs.files.inspectLocal(source, limits: pdfs.limits)
        #expect(metadata.title == "An Offline Paper"); #expect(metadata.authors == ["Alice", "Bob"])
        #expect(metadata.pageCount == 2); #expect(metadata.size == Int64(original.count))
        let id = try await pdfs.importLocalPDF(from: source, draft: PaperDraft(title: metadata.title, authors: metadata.authors), courseIDs: [firstCourse.id])
        await pdfs.waitUntilIdle()
        let paper = try #require(repo.paper(id: id))
        let record = try #require(repo.pdfRecords(paperID: id).first)
        #expect(paper.provider == "localPDF"); #expect(paper.providerIdentifier == nil); #expect(paper.resolvedVersion == nil)
        #expect(record.indexStatus == "chunksReady"); #expect(record.pageCount == 2)
        #expect(try repo.pdfPages(recordID: record.id).count == 2)
        #expect(try Data(contentsOf: await pdfs.files.verifiedURL(record.fileReference)) == original)
        #expect(try Data(contentsOf: source) == original)
        try repo.saveNotes(paperID: id, notes: "Preserve my notes")
        try repo.updateMetadata(paperID: id, draft: PaperDraft(title: "My corrected title", authors: ["Corrected author"]))
        let reused = try await pdfs.importLocalPDF(from: source, draft: PaperDraft(title: "Do not overwrite my title"), courseIDs: [secondCourse.id])
        await pdfs.waitUntilIdle()
        #expect(reused == id); #expect(repo.papers.count == 1); #expect(repo.pdfRecords(paperID: id).count == 1)
        #expect(paper.title == "My corrected title"); #expect(paper.notes == "Preserve my notes")
        #expect(repo.courseIDs(paperID: id) == [firstCourse.id, secondCourse.id])
        #expect(repo.importJobs.count == 2); #expect(repo.importJobs.allSatisfy { $0.state == .completed })
        #expect(throws: PDFLibraryError.invalidSource) { try pdfs.enqueue(paperID: id) }
        let ai = AnalysisCoordinator(repository: repo, model: FixtureAnalysisModel())
        try ai.summarize(paperID: id, profileID: BuiltinAnalysisProfiles.quickID, language: "en")
        await ai.waitUntilIdle()
        #expect(try repo.analyses(paperID: id).first?.sourceKind == "pdf")
        #expect(await transport.calls == 0)
        let files = try FileManager.default.subpathsOfDirectory(atPath: c.pdfDirectory.path)
        #expect(files.filter { $0.hasSuffix(".pdf") }.count == 1)
    }

    @Test func invalidOversizeAndCancelledLocalImportsLeaveNoPaperOrPartialFile() async throws {
        let c = try config(); defer { try? FileManager.default.removeItem(at: c.root) }
        try FileManager.default.createDirectory(at: c.root, withIntermediateDirectories: true)
        let source = c.root.appendingPathComponent("invalid.pdf")
        try Data("%PDF-this is not a document".utf8).write(to: source)
        let repo = try LibraryRepository(store: LibraryStore.open(configuration: c))
        let pdfs = coordinator(repo, transport: FixturePDFTransport())
        await #expect(throws: PDFLibraryError.invalidFile) { try await pdfs.importLocalPDF(from: source, draft: PaperDraft(title: "Invalid")) }
        try PDFFixtures.document().write(to: source)
        pdfs.limits = PDFLimits(maximumBytes: 8)
        await #expect(throws: PDFLibraryError.tooLarge) { try await pdfs.importLocalPDF(from: source, draft: PaperDraft(title: "Oversize")) }
        pdfs.limits = PDFLimits()
        let task = Task { try await pdfs.importLocalPDF(from: source, draft: PaperDraft(title: "Cancelled")) }
        task.cancel()
        do { _ = try await task.value; Issue.record("Cancelled import unexpectedly completed") } catch is CancellationError {}
        #expect(repo.papers.isEmpty); #expect(repo.pdfRecords.isEmpty); #expect(repo.importJobs.isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: c.pdfDirectory.appendingPathComponent(".staging").path).isEmpty)
        #expect(FileManager.default.fileExists(atPath: source.path))
    }

    @Test func removedLocalPDFCanBeRestoredWithoutLosingNotes() async throws {
        let c = try config(); defer { try? FileManager.default.removeItem(at: c.root) }
        try FileManager.default.createDirectory(at: c.root, withIntermediateDirectories: true)
        let source = c.root.appendingPathComponent("paper.pdf")
        try PDFFixtures.document().write(to: source)
        let repo = try LibraryRepository(store: LibraryStore.open(configuration: c))
        let pdfs = coordinator(repo, transport: FixturePDFTransport())
        let id = try await pdfs.importLocalPDF(from: source, draft: PaperDraft(title: "Saved PDF"))
        await pdfs.waitUntilIdle()
        let recordID = try #require(repo.pdfRecords(paperID: id).first?.id)
        try repo.saveNotes(paperID: id, notes: "Keep these notes")
        try await pdfs.remove(recordID: recordID)
        let restored = try await pdfs.importLocalPDF(from: source, draft: PaperDraft(title: "A replacement title"))
        await pdfs.waitUntilIdle()
        #expect(restored == id); #expect(repo.papers.count == 1)
        #expect(repo.pdfRecords(paperID: id).first?.id == recordID)
        #expect(repo.paper(id: id)?.notes == "Keep these notes"); #expect(repo.paper(id: id)?.title == "Saved PDF")
        #expect(repo.pdfRecord(id: recordID)?.indexStatus == "chunksReady")
    }

    @Test func localImportPersistsAcrossLibraryReopening() async throws {
        let c = try config(); defer { try? FileManager.default.removeItem(at: c.root) }
        try FileManager.default.createDirectory(at: c.root, withIntermediateDirectories: true)
        let source = c.root.appendingPathComponent("paper.pdf")
        try PDFFixtures.document().write(to: source)
        var repo: LibraryRepository? = try LibraryRepository(store: LibraryStore.open(configuration: c))
        var pdfs: PDFCoordinator? = coordinator(try #require(repo), transport: FixturePDFTransport())
        let id = try await #require(pdfs).importLocalPDF(from: source, draft: PaperDraft(title: "Persistent local PDF"))
        await pdfs?.waitUntilIdle()
        pdfs = nil; repo = nil
        try autoreleasepool {
            let reopened = try LibraryRepository(store: LibraryStore.open(configuration: c))
            #expect(reopened.paper(id: id)?.provider == "localPDF")
            #expect(reopened.pdfRecords(paperID: id).first?.indexStatus == "chunksReady")
            #expect(reopened.importJobs.first?.state == .completed)
        }
    }

    @Test func scannedLocalPDFRemainsReadableWithoutClaimingTextIsReady() async throws {
        let c = try config(); defer { try? FileManager.default.removeItem(at: c.root) }
        try FileManager.default.createDirectory(at: c.root, withIntermediateDirectories: true)
        let source = c.root.appendingPathComponent("scanned.pdf")
        try PDFFixtures.document(pages: [""]).write(to: source)
        let repo = try LibraryRepository(store: LibraryStore.open(configuration: c))
        let pdfs = coordinator(repo, transport: FixturePDFTransport())
        let id = try await pdfs.importLocalPDF(from: source, draft: PaperDraft(title: "Scanned paper"))
        await pdfs.waitUntilIdle()
        let record = try #require(repo.pdfRecords(paperID: id).first)
        #expect(record.indexStatus == "noText"); #expect(record.extractionStatus == "incomplete")
        #expect(try repo.pdfChunks(recordID: record.id).isEmpty)
        #expect(PDFDocument(url: try await pdfs.files.verifiedURL(record.fileReference))?.pageCount == 1)
    }

    @Test func reimportAfterPaperDeletionCreatesFreshIdentity() async throws {
        let c = try config(); defer { try? FileManager.default.removeItem(at: c.root) }
        try FileManager.default.createDirectory(at: c.root, withIntermediateDirectories: true)
        let source = c.root.appendingPathComponent("paper.pdf")
        try PDFFixtures.document().write(to: source)
        let repo = try LibraryRepository(store: LibraryStore.open(configuration: c))
        let pdfs = coordinator(repo, transport: FixturePDFTransport())
        let oldID = try await pdfs.importLocalPDF(from: source, draft: PaperDraft(title: "Deleted paper"))
        await pdfs.waitUntilIdle()
        try await pdfs.deletePapers(ids: [oldID])
        let newID = try await pdfs.importLocalPDF(from: source, draft: PaperDraft(title: "New paper"))
        await pdfs.waitUntilIdle()
        #expect(newID != oldID); #expect(repo.paper(id: oldID) == nil)
        #expect(repo.papers.count == 1); #expect(repo.paper(id: newID)?.title == "New paper")
        #expect(repo.pdfRecords(paperID: newID).count == 1)
    }

    @Test func downloadExtractAndReuseExistingFile() async throws {
        let c = try config(); defer { try? FileManager.default.removeItem(at: c.root) }
        let repo = try LibraryRepository(store: LibraryStore.open(configuration: c))
        let paper = try await imported(repo)
        try repo.saveNotes(paperID: paper.id, notes: "Annotation must survive")
        let transport = FixturePDFTransport()
        let pdfs = coordinator(repo, transport: transport)
        try pdfs.enqueue(paperID: paper.id)
        try pdfs.enqueue(paperID: paper.id)
        await pdfs.waitUntilIdle()
        let record = try #require(repo.pdfRecords(paperID: paper.id).first)
        #expect(record.version == 1 && record.pageCount == 2)
        #expect(record.checksum.count == 64 && record.extractionStatus == "completed")
        #expect(repo.pdfJobs.allSatisfy { $0.state == .completed })
        let chunks = try repo.pdfChunks(recordID: record.id)
        #expect(chunks.count == 2 && chunks.map(\.startPage) == [1, 2])
        #expect(chunks.first?.text.contains("scientific method") == true)
        let previousChunkIDs = chunks.map(\.id)
        try pdfs.enqueue(paperID: paper.id, operation: "extract", version: record.version)
        await pdfs.waitUntilIdle()
        #expect(try repo.pdfChunks(recordID: record.id).map(\.id) == previousChunkIDs)
        try repo.saveReadingPosition(recordID: record.id, page: 2)
        try pdfs.enqueue(paperID: paper.id)
        await pdfs.waitUntilIdle()
        #expect(await transport.calls == 1)
        #expect(record.lastReadPage == 2 && paper.notes == "Annotation must survive")
        let url = try await pdfs.files.verifiedURL(record.fileReference)
        #expect(PDFDocument(url: url)?.pageCount == 2)
        var modified = try Data(contentsOf: url); modified[20] ^= 1; try modified.write(to: url)
        try pdfs.enqueue(paperID: paper.id); await pdfs.waitUntilIdle()
        #expect(await transport.calls == 1)
        #expect(repo.pdfJobs.last?.state == .failed)
        #expect(try Data(contentsOf: url) == modified)
    }

    @Test func cancellationRemovesPartialFileAndKeepsMetadata() async throws {
        let c = try config(); defer { try? FileManager.default.removeItem(at: c.root) }
        let repo = try LibraryRepository(store: LibraryStore.open(configuration: c))
        let paper = try await imported(repo)
        let transport = FixturePDFTransport(); await transport.configure(delay: true)
        let pdfs = coordinator(repo, transport: transport)
        try pdfs.enqueue(paperID: paper.id)
        while await transport.calls == 0 { await Task.yield() }
        let id = try #require(repo.pdfJobs.first?.id)
        try pdfs.cancel(id: id); await pdfs.waitUntilIdle()
        #expect(repo.pdfJobs.first?.state == .cancelled)
        #expect(repo.papers.count == 1 && repo.pdfRecords.isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: c.pdfDirectory.appendingPathComponent(".staging").path).isEmpty)
        await transport.configure()
        try pdfs.retry(id: id); await pdfs.waitUntilIdle()
        #expect(repo.pdfRecords(paperID: paper.id).count == 1)
    }

    @Test func versionsRemainIndependentAndLocalRemovalKeepsPaperNotes() async throws {
        let c = try config(); defer { try? FileManager.default.removeItem(at: c.root) }
        let repo = try LibraryRepository(store: LibraryStore.open(configuration: c))
        let paper = try await imported(repo)
        try repo.saveNotes(paperID: paper.id, notes: "Keep me")
        let pdfs = coordinator(repo, transport: FixturePDFTransport())
        try pdfs.enqueue(paperID: paper.id, version: 1); await pdfs.waitUntilIdle()
        let old = try #require(repo.pdfRecords(paperID: paper.id).first)
        let original = try Data(contentsOf: await pdfs.files.verifiedURL(old.fileReference))
        try pdfs.enqueue(paperID: paper.id, version: 2); await pdfs.waitUntilIdle()
        #expect(repo.pdfRecords(paperID: paper.id).count == 2)
        #expect(try Data(contentsOf: await pdfs.files.verifiedURL(old.fileReference)) == original)
        try await pdfs.remove(recordID: old.id)
        #expect(repo.pdfRecords(paperID: paper.id).count == 1)
        #expect(try repo.pdfChunks(recordID: old.id).isEmpty)
        #expect(repo.paper(id: paper.id)?.notes == "Keep me")
        #expect(!FileManager.default.fileExists(atPath: c.root.appendingPathComponent(old.relativePath).path))
    }

    @Test func invalidDownloadCannotReplaceAnExistingVersion() async throws {
        let c = try config(); defer { try? FileManager.default.removeItem(at: c.root) }
        let files = PDFFileStore(configuration: c)
        let paperID = UUID()
        let stage = try await files.stagingURL(jobID: UUID())
        try PDFFixtures.document().write(to: stage)
        let reference = try await files.install(staged: stage, paperID: paperID, version: 1, limits: PDFLimits())
        let original = try Data(contentsOf: await files.verifiedURL(reference))
        let second = try await files.stagingURL(jobID: UUID())
        try Data("<html>not a PDF</html>".utf8).write(to: second)
        await #expect(throws: PDFLibraryError.self) { try await files.install(staged: second, paperID: paperID, version: 1, limits: PDFLimits()) }
        #expect(try Data(contentsOf: await files.verifiedURL(reference)) == original)
        try await files.discard(staged: second)
    }

    @Test func extractorMarksScansAndLimitsIncomplete() async throws {
        let c = try config(); defer { try? FileManager.default.removeItem(at: c.root) }
        let files = PDFFileStore(configuration: c)
        let stage = try await files.stagingURL(jobID: UUID())
        try PDFFixtures.document(pages: ["", "Some available evidence"]).write(to: stage)
        let extractor = PDFTextExtractor()
        let scanned = try await extractor.extract(url: stage, limits: PDFLimits())
        #expect(scanned.incomplete && scanned.pages.count == 2)
        let limited = try await extractor.extract(url: stage, limits: PDFLimits(maximumPages: 1))
        #expect(limited.incomplete && limited.pages.count == 1 && limited.totalPages == 2)
    }

    @Test func chunkingRetainsBoundsHashesAndTechnicalText() throws {
        let text = String(repeating: "SLAM SE(3) alpha technical evidence. ", count: 100)
        let pages = [ExtractedPDFPage(number: 7, text: text), ExtractedPDFPage(number: 8, text: "Next source page")]
        let chunks = try PDFChunker.chunks(pages: pages, maximumCharacters: 300, overlap: 40)
        #expect(chunks.count > 3 && chunks.allSatisfy { $0.text.count <= 300 })
        #expect(chunks.first?.page == 7 && chunks.last?.page == 8)
        let id = UUID()
        #expect(chunks.first?.id(recordID: id) == chunks.first?.id(recordID: id))
        #expect(Set(chunks.map { $0.id(recordID: id) }).count == chunks.count)
        #expect(chunks.first?.text.contains("SE(3)") == true)
    }

    @Test func unsafePathsSourcesAndChecksumCorruptionAreRejected() async throws {
        for value in ["http://arxiv.org/pdf/1706.03762v1", "https://evil.test/pdf/1706.03762v1", "https://arxiv.org/pdf/1706.03762", "https://arxiv.org/pdf/1706.03762v1?x=1"] {
            #expect(throws: (any Error).self) { try PDFSourcePolicy.validate(URL(string: value)!) }
        }
        let c = try config(); defer { try? FileManager.default.removeItem(at: c.root) }
        let files = PDFFileStore(configuration: c)
        await #expect(throws: PDFLibraryError.unsafePath) { try await files.verifiedURL(PDFFileReference(relativePath: "../../secret", size: 0, checksum: "")) }
        let stage = try await files.stagingURL(jobID: UUID())
        try PDFFixtures.document().write(to: stage)
        let reference = try await files.install(staged: stage, paperID: UUID(), version: 1, limits: PDFLimits())
        let url = try await files.verifiedURL(reference)
        var data = try Data(contentsOf: url); let originalData = data
        data[20] ^= 1; try data.write(to: url)
        await #expect(throws: PDFLibraryError.checksum) { try await files.verifiedURL(reference) }
        let replacement = try await files.stagingURL(jobID: UUID())
        try originalData.write(to: replacement)
        await #expect(throws: PDFLibraryError.checksum) { try await files.install(staged: replacement, paperID: UUID(uuidString: url.deletingLastPathComponent().lastPathComponent)!, version: 1, limits: PDFLimits()) }
        #expect(try Data(contentsOf: await files.existingURL(relativePath: reference.relativePath)) == data)
    }

    @Test func localPDFViewBlocksURLActionsAndAllowsLocalPageNavigation() throws {
        let document = try #require(PDFDocument(data: PDFFixtures.document()))
        let view = LocalPDFView(frame: NSRect(x: 0, y: 0, width: 500, height: 600))
        view.document = document
        let target = try #require(document.page(at: 1))
        view.perform(PDFActionURL(url: URL(string: "https://evil.test")!))
        view.perform(PDFActionGoTo(destination: PDFDestination(page: target, at: .zero)))
        #expect(view.document === document)
        #expect(view.currentPage === target)
    }

    @Test func failedExtractionRetainsReadablePDFAndDeletingPaperCleansFiles() async throws {
        let c = try config(); defer { try? FileManager.default.removeItem(at: c.root) }
        let repo = try LibraryRepository(store: LibraryStore.open(configuration: c))
        let paper = try await imported(repo)
        let files = PDFFileStore(configuration: c)
        let scheduler = ArxivRequestScheduler(transport: MockArxivTransport(clock: TestArxivClock(), responses: []), clock: TestArxivClock())
        let pdfs = PDFCoordinator(repository: repo, files: files, downloader: PDFDownloader(files: files, scheduler: scheduler, transport: FixturePDFTransport()), extractor: FailingPDFExtractor())
        try pdfs.enqueue(paperID: paper.id); await pdfs.waitUntilIdle()
        let record = try #require(repo.pdfRecords(paperID: paper.id).first)
        let url = try await files.verifiedURL(record.fileReference)
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(repo.pdfJobs.last?.state == .failed)
        try await pdfs.deletePapers(ids: [paper.id])
        #expect(repo.papers.isEmpty && !FileManager.default.fileExists(atPath: url.path))
        #expect(try repo.pdfPages(recordID: record.id).isEmpty)
    }

    @Test func interruptedPDFWorkIsRecoveredAndReadingStateSurvivesReopening() async throws {
        let c = try config(); defer { try? FileManager.default.removeItem(at: c.root) }
        let ids: (UUID, UUID) = try autoreleasepool {
            let repo = try LibraryRepository(store: LibraryStore.open(configuration: c))
            try repo.enqueueImports(ImportInput.parse("1706.03762v1"), destinationCourseID: nil, assignExisting: true, refreshMetadata: false)
            let jobID = try #require(repo.importJobs.first?.id)
            try repo.beginImports(ids: [jobID]); try repo.completeImport(id: jobID, metadata: ArxivFixtures.metadata())
            let paper = try #require(repo.papers.first)
            let pdfID = try repo.enqueuePDF(paperID: paper.id, operation: "download")
            try repo.updatePDFJob(id: pdfID, state: .inProgress, received: 50, total: 100)
            return (paper.id, pdfID)
        }
        let files = PDFFileStore(configuration: c)
        let stage = try await files.stagingURL(jobID: ids.1)
        try PDFFixtures.document().write(to: stage)
        let reference = try await files.install(staged: stage, paperID: ids.0, version: 1, limits: PDFLimits())
        let extracted = try await PDFTextExtractor().extract(url: files.verifiedURL(reference), limits: PDFLimits())
        let chunks = try PDFChunker.chunks(pages: extracted.pages)
        let recordID: UUID = try autoreleasepool {
            let repo = try LibraryRepository(store: LibraryStore.open(configuration: c))
            #expect(repo.pdfJobs.first?.state == .interrupted)
            try repo.retryPDFJob(id: ids.1); try repo.updatePDFJob(id: ids.1, state: .inProgress)
            try repo.completePDFDownload(jobID: ids.1, reference: reference)
            let record = try #require(repo.pdfRecords.first)
            let extractID = try #require(repo.pdfJobs.last?.id)
            try repo.updatePDFJob(id: extractID, state: .inProgress)
            try repo.completePDFExtraction(jobID: extractID, recordID: record.id, checksum: reference.checksum, result: extracted, chunks: chunks)
            try repo.saveReadingPosition(recordID: record.id, page: 2)
            return record.id
        }
        try autoreleasepool {
            let repo = try LibraryRepository(store: LibraryStore.open(configuration: c))
            #expect(repo.pdfRecord(id: recordID)?.lastReadPage == 2)
            #expect(try repo.pdfPages(recordID: recordID).count == 2)
            #expect(try repo.pdfChunks(recordID: recordID).map(\.startPage) == [1, 2])
            #expect(repo.pdfJobs.allSatisfy { $0.state == .completed })
        }
    }

    @Test func v3UpgradePreservesLibraryAndImportHistory() throws {
        let c = try config(); defer { try? FileManager.default.removeItem(at: c.root) }
        try FileManager.default.createDirectory(at: c.storeDirectory, withIntermediateDirectories: true)
        let paperID = try autoreleasepool {
            let schema = Schema(versionedSchema: LibrarySchemaV3.self)
            let container = try ModelContainer(for: schema, configurations: [ModelConfiguration("PaperLibrary", schema: schema, url: c.storeURL, cloudKitDatabase: .none)])
            let context = ModelContext(container); context.autosaveEnabled = false
            let paper = LibrarySchemaV3.Paper(title: "Existing research", authors: ["A", "B"])
            paper.notes = "Never lose annotation"; paper.rating = 4; paper.journalReference = "Journal"
            let job = LibrarySchemaV3.ImportJob(batchID: UUID(), input: "1706.03762v1", canonicalIdentifier: "1706.03762", requestedVersion: 1, destinationCourseID: nil, assignExisting: true, refreshMetadata: false)
            job.stateRaw = "completed"; job.paperID = paper.id
            context.insert(paper); context.insert(job); try context.save()
            return paper.id
        }
        try autoreleasepool {
            let store = try LibraryStore.open(configuration: c)
            let repo = try LibraryRepository(store: store)
            #expect(repo.paper(id: paperID)?.notes == "Never lose annotation")
            #expect(repo.paper(id: paperID)?.journalReference == "Journal")
            #expect(repo.importJobs.first?.state == .completed)
            #expect(repo.pdfRecords.isEmpty && repo.pdfJobs.isEmpty && store.startupBackup != nil)
        }
    }

    @Test func repeatedEdgeRemovalRetainsTechnicalBodyAndShortPages() {
        let pages = (1...3).map { ExtractedPDFPage(number: $0, text: "Repeated header\nSE(3) method page \($0)\nRepeated footer") }
        let cleaned = PDFTextNormalizer.normalize(pages)
        #expect(cleaned.map(\.text) == (1...3).map { "SE(3) method page \($0)" })
        let short = (1...3).map { ExtractedPDFPage(number: $0, text: "Repeated scientific statement") }
        #expect(PDFTextNormalizer.normalize(short).map(\.text) == short.map(\.text))
    }
}
