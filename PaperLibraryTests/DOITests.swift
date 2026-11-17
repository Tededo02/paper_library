import Foundation
import SwiftData
import Testing
import PaperLibrarySupport
@testable import PaperLibraryCore

enum DOIFixtures {
    static let ieee = "10.1109/icarm65671.2025.11293737"
    static let mdpi = "10.3390/s24020436"
    static func crossref(doi: String = mdpi, title: String = "A vehicle estimation study", abstract: String? = "<jats:p>Velocity &amp; slip <jats:italic>estimation</jats:italic>.</jats:p>") throws -> Data {
        var work: [String: Any] = ["DOI": doi, "title": [title], "author": [["given": "Aymen", "family": "Alshawi"], ["name": "Research Group"]],
            "published": ["date-parts": [[2024, 1, 10]]], "container-title": ["Sensors"], "volume": "24", "issue": "2", "page": "436"]
        if let abstract { work["abstract"] = abstract }
        return try JSONSerialization.data(withJSONObject: ["status": "ok", "message": work])
    }
    static func datacite(doi: String = "10.5281/zenodo.1234") throws -> Data {
        try JSONSerialization.data(withJSONObject: ["data": ["attributes": ["doi": doi, "titles": [["title": "A repository paper"]],
            "creators": [["givenName": "First", "familyName": "Author", "name": "Author, First"]], "publicationYear": 2023,
            "descriptions": [["descriptionType": "Abstract", "description": "A deposited abstract."]]]]])
    }
    static func openalex(doi: String = ieee, index: [String: [Int]] = ["Source": [0], "abstract.": [1]], pdf: String? = nil, isOA: Bool = false) throws -> Data {
        var work: [String: Any] = ["doi": "https://doi.org/\(doi)", "abstract_inverted_index": index]
        if let pdf { work["best_oa_location"] = ["is_oa": isOA, "pdf_url": pdf] }
        return try JSONSerialization.data(withJSONObject: work)
    }
}

actor FixtureDOIProvider: DOIMetadataProviding {
    var calls: [DOIIdentifier] = []
    var failure: URLError?
    var delay = false
    var mismatch = false
    var partial = false
    func configure(failure: URLError? = nil, delay: Bool = false, mismatch: Bool = false, partial: Bool = false) {
        self.failure = failure; self.delay = delay; self.mismatch = mismatch; self.partial = partial
    }
    func fetch(_ identifier: DOIIdentifier) async throws -> DOIMetadata {
        calls.append(identifier)
        if delay { try await Task.sleep(for: .seconds(60)) }
        if let failure { throw failure }
        if partial { return try DOIMetadata(identifier: identifier, title: "Refreshed title") }
        return try DOIMetadata(identifier: mismatch ? DOIIdentifier("10.1234/wrong") : identifier,
            title: "Imported DOI paper", authors: ["First Author", "Second Author"], abstract: "Original DOI abstract.",
            publishedAt: Date(timeIntervalSince1970: 100), journalReference: "Journal, 24, 436")
    }
}

private actor MockDOITransport: DOITransport {
    var replies: [(Int, Data, [String: String])]
    var requests: [URLRequest] = []
    let failure: URLError?
    let responseURL: URL?
    init(_ replies: [(Int, Data, [String: String])], failure: URLError? = nil, responseURL: URL? = nil) {
        self.replies = replies; self.failure = failure; self.responseURL = responseURL
    }
    func send(_ request: URLRequest) throws -> DOIHTTPResponse {
        requests.append(request)
        if let failure { throw failure }
        guard !replies.isEmpty else { throw URLError(.badServerResponse) }
        let reply = replies.removeFirst()
        return DOIHTTPResponse(status: reply.0, headers: reply.2, body: reply.1, url: responseURL ?? request.url!)
    }
}

struct DOITests {
    @Test(arguments: ["10.1109/ICARM65671.2025.11293737", "DOI:10.1109/ICARM65671.2025.11293737", "https://doi.org/10.1109/ICARM65671.2025.11293737", "http://dx.doi.org/10.1109%2FICARM65671.2025.11293737", "https\\://doi.org/10.1109/ICARM65671.2025.11293737"])
    func normalizesDOIForms(_ input: String) throws {
        let identifier = try DOIIdentifier(input)
        #expect(identifier.canonical == DOIFixtures.ieee)
        #expect(identifier.canonicalURL.absoluteString == "https://doi.org/\(DOIFixtures.ieee)")
    }

    @Test(arguments: ["10.1109/ICARM65671.2025.11293737", "doi:10.1109/ICARM65671.2025.11293737", "https://doi.org/10.1109/ICARM65671.2025.11293737", "http://dx.doi.org/10.1109/ICARM65671.2025.11293737", "https\\://doi.org/10.1109/ICARM65671.2025.11293737", "https://doi.org/10.1109%2FICARM65671.2025.11293737"])
    func normalizesDOIs(_ input: String) throws {
        let id = try DOIIdentifier(input)
        #expect(id.canonical == DOIFixtures.ieee)
        #expect(id.canonicalURL.absoluteString == "https://doi.org/\(DOIFixtures.ieee)")
    }

    @Test(arguments: ["https://evil.test/10.3390/s24020436", "https://doi.org.evil.test/10.3390/s24020436", "https://doi.org@evil.test/10.3390/s24020436", "https://user@doi.org/10.3390/s24020436", "https://doi.org:443/10.3390/s24020436", "https://doi.org/10.3390/s24020436?x=1", "https://doi.org/10.3390/s24020436#x", "file:///10.3390/s24020436", "10.123/x", "10.1234/", "10.1234/../test", "10.1234/test\nvalue", "10.1234/test\u{0000}"])
    func rejectsUnsafeOrMalformedDOIs(_ input: String) {
        #expect(throws: DOIError.self) { try DOIIdentifier(input) }
    }

    @Test func mixedBatchNormalizesUserExamplesAndDeduplicatesDOIs() throws {
        let inputs = try ImportInput.parse("https\\://doi.org/10.1109/ICARM65671.2025.11293737\u{00a0}https://doi.org/10.3390/s24020436\nDOI:10.3390/S24020436 1706.03762v1,invalid")
        #expect(inputs.count == 4)
        #expect(inputs.compactMap { $0.identifier?.doiIdentifier }.map(\.canonical) == [DOIFixtures.ieee, DOIFixtures.mdpi])
        #expect(inputs.compactMap { $0.identifier?.arxivIdentifier }.count == 1)
        #expect(inputs.last?.error != nil)
        let legacy = "10.1002/(SICI)1097-0258(19980815/30)17:15/16<1915::AID-SIM953>3.0.CO;2-1,part"
        #expect(try ImportInput.parse(legacy).first?.identifier?.doiIdentifier?.canonical == legacy.lowercased())
        #expect(try DOIIdentifier(DOIIdentifier(legacy).canonicalURL.absoluteString).canonical == legacy.lowercased())
    }

    @Test func crossrefParsesOrderedAuthorsPlainAbstractJournalAndPublicationDate() throws {
        let metadata = try DOIMetadataParser.crossref(DOIFixtures.crossref(), requested: DOIIdentifier(DOIFixtures.mdpi))
        #expect(metadata.authors == ["Aymen Alshawi", "Research Group"])
        #expect(metadata.abstract == "Velocity & slip estimation.")
        #expect(metadata.journalReference == "Sensors, 24, (2), 436")
        #expect(metadata.publishedAt == ISO8601DateFormatter().date(from: "2024-01-10T00:00:00Z"))
        let missingAbstract = try DOIMetadataParser.crossref(DOIFixtures.crossref(doi: DOIFixtures.ieee, abstract: nil), requested: DOIIdentifier(DOIFixtures.ieee))
        #expect(missingAbstract.abstract.isEmpty && !missingAbstract.title.isEmpty)
        let minimal = Data(#"{"status":"ok","message":{"DOI":"10.3390/s24020436","title":["Title only"]}}"#.utf8)
        let partial = try DOIMetadataParser.crossref(minimal, requested: DOIIdentifier(DOIFixtures.mdpi))
        #expect(partial.authors.isEmpty && partial.abstract.isEmpty && partial.publishedAt == nil)
    }

    @Test func metadataRejectsWrongDOIMissingTitleMalformedAndOversizedResponses() throws {
        let id = try DOIIdentifier(DOIFixtures.mdpi)
        #expect(throws: DOIError.invalidResponse) { try DOIMetadataParser.crossref(DOIFixtures.crossref(doi: DOIFixtures.ieee), requested: id) }
        #expect(throws: DOIError.invalidResponse) { try DOIMetadataParser.crossref(DOIFixtures.crossref(title: " "), requested: id) }
        #expect(throws: DOIError.invalidResponse) { try DOIMetadataParser.crossref(Data("<html>Unavailable</html>".utf8), requested: id) }
        #expect(throws: DOIError.responseTooLarge) { try DOIMetadataParser.crossref(Data(repeating: 65, count: 2_097_153), requested: id) }
    }

    @Test func clientRequestsOnlyMetadataAndFallsBackToDataCiteAfterCrossref404() async throws {
        let id = try DOIIdentifier("10.5281/zenodo.1234")
        let transport = MockDOITransport([(404, Data(), [:]), (200, try DOIFixtures.datacite(), [:])])
        let metadata = try await DOIClient(transport: transport, clock: TestArxivClock(), enrichmentEnabled: false).fetch(id)
        #expect(metadata.authors == ["First Author"] && metadata.abstract == "A deposited abstract.")
        #expect(metadata.publishedAt == ISO8601DateFormatter().date(from: "2023-01-01T00:00:00Z"))
        let requests = await transport.requests
        #expect(requests.map { $0.url?.host } == ["api.crossref.org", "api.datacite.org"])
        #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "Accept") == "application/json" })
        for request in requests { try DOINetworkPolicy.validate(#require(request.url)) }
    }

    @Test func clientHonorsRetryAfterBoundsRetriesAndDoesNotRetryMissingOrOfflineRecords() async throws {
        let id = try DOIIdentifier(DOIFixtures.mdpi)
        let clock = TestArxivClock()
        let retry = MockDOITransport([(429, Data(), ["retry-after": "9"]), (200, try DOIFixtures.crossref(), [:])])
        _ = try await DOIClient(transport: retry, clock: clock, enrichmentEnabled: false).fetch(id)
        #expect(await clock.delays == [9])
        let unavailable = MockDOITransport(Array(repeating: (503, Data(), [:]), count: 3))
        await #expect(throws: DOIError.http(503)) { try await DOIClient(transport: unavailable, clock: TestArxivClock()).fetch(id) }
        #expect(await unavailable.requests.count == 3)
        let missing = MockDOITransport([(404, Data(), [:]), (404, Data(), [:])])
        await #expect(throws: DOIError.notFound) { try await DOIClient(transport: missing, clock: TestArxivClock()).fetch(id) }
        #expect(await missing.requests.count == 2)
        let offline = MockDOITransport([], failure: URLError(.notConnectedToInternet))
        await #expect(throws: URLError.self) { try await DOIClient(transport: offline, clock: TestArxivClock()).fetch(id) }
        #expect(await offline.requests.count == 1)
        let wrong = MockDOITransport([(200, try DOIFixtures.crossref(doi: DOIFixtures.ieee), [:])])
        await #expect(throws: DOIError.invalidResponse) { try await DOIClient(transport: wrong, clock: TestArxivClock()).fetch(id) }
        let redirect = MockDOITransport([(200, try DOIFixtures.crossref(), [:])], responseURL: URL(string: "https://evil.test")!)
        await #expect(throws: DOIError.redirectRejected) { try await DOIClient(transport: redirect, clock: TestArxivClock()).fetch(id) }
    }
}

extension DOITests {
    @Test func missingCrossrefAbstractIsRecoveredByDOIWithoutInventingAPublicPDF() async throws {
        let transport = MockDOITransport([(200, try DOIFixtures.crossref(doi: DOIFixtures.ieee, abstract: nil), [:]),
            (200, try DOIFixtures.openalex(pdf: "https://www.mdpi.com/1424-8220/24/2/436/pdf", isOA: false), [:])])
        let record = try await DOIClient(transport: transport, clock: TestArxivClock()).fetch(DOIIdentifier(DOIFixtures.ieee))
        #expect(record.abstract == "Source abstract." && record.enrichmentComplete)
        #expect(record.pdfURL == nil && record.title == "A vehicle estimation study")
        let requests = await transport.requests
        #expect(requests.map { $0.url?.host } == ["api.crossref.org", "api.openalex.org"])
        for request in requests { try DOINetworkPolicy.validate(#require(request.url)) }
    }

    @Test func enrichmentKeepsPublisherAbstractAndFindsVerifiedOpenPDF() async throws {
        let pdf = "https://www.mdpi.com/1424-8220/24/2/436/pdf?version=1704898430"
        let transport = MockDOITransport([(200, try DOIFixtures.crossref(), [:]),
            (200, try DOIFixtures.openalex(doi: DOIFixtures.mdpi, pdf: pdf, isOA: true), [:])])
        let record = try await DOIClient(transport: transport, clock: TestArxivClock()).fetch(DOIIdentifier(DOIFixtures.mdpi))
        #expect(record.abstract == "Velocity & slip estimation." && record.pdfURL?.absoluteString == pdf)
        #expect(record.enrichmentComplete)
    }

    @Test func optionalEnrichmentFailureOrWrongDOIPreservesBaseImport() async throws {
        let cases: [(Int, Data)] = [(503, Data()), (404, Data()), (200, Data("malformed".utf8)),
            (200, try DOIFixtures.openalex(doi: DOIFixtures.mdpi)), (200, try DOIFixtures.openalex(index: ["word": [-1]]))]
        for (status, body) in cases {
            let transport = MockDOITransport([(200, try DOIFixtures.crossref(doi: DOIFixtures.ieee, abstract: nil), [:]),
                (status, body, [:]), (status, body, [:]), (status, body, [:])])
            let record = try await DOIClient(transport: transport, clock: TestArxivClock()).fetch(DOIIdentifier(DOIFixtures.ieee))
            #expect(record.title == "A vehicle estimation study" && record.abstract.isEmpty && !record.enrichmentComplete)
        }
    }

    @Test func invertedIndexRejectsGapsCollisionsAndUnboundedPositions() throws {
        for index in [["word": [1]], ["first": [0], "second": [0]], ["word": [32_000]], ["": [0]], ["word": []]] {
            #expect(throws: DOIError.invalidResponse) { try OpenAlexParser.parse(DOIFixtures.openalex(index: index), requested: DOIIdentifier(DOIFixtures.ieee)) }
        }
        let record = try OpenAlexParser.parse(DOIFixtures.openalex(index: ["one": [0, 2], "two": [1]]), requested: DOIIdentifier(DOIFixtures.ieee))
        #expect(record.abstract == "one two one")
    }

    @Test func publicPDFReferencesRejectPrivateAndCredentialedURLs() throws {
        for url in ["http://www.mdpi.com/paper.pdf", "https://127.0.0.1/paper.pdf", "https://[::1]/paper.pdf", "https://library.local/paper.pdf", "https://localhost/paper.pdf", "https://user:password@www.mdpi.com/paper.pdf", "https://www.mdpi.com:443/paper.pdf"] {
            let result = try OpenAlexParser.parse(DOIFixtures.openalex(pdf: url, isOA: true), requested: DOIIdentifier(DOIFixtures.ieee))
            #expect(result.pdfURL == nil)
        }
        #expect(throws: DOIError.self) { try DOINetworkPolicy.validate(URL(string: "https://api.openalex.org/works?search=private")!) }
        #expect(throws: DOIError.self) { try DOINetworkPolicy.validate(URL(string: "http://api.openalex.org/works/https://doi.org/10.3390%2Fs24020436")!) }
    }
}

@Suite(.serialized)
@MainActor
struct DOIImportTests {
    private func configuration() throws -> StorageConfiguration {
        try .testing(at: FileManager.default.temporaryDirectory.appendingPathComponent("PaperLibraryDOITests-\(UUID().uuidString)"))
    }

    @Test func mixedImportPersistsDOIsAndReusesDuplicatesWhilePreservingAnnotations() async throws {
        let config = try configuration()
        defer { try? FileManager.default.removeItem(at: config.root) }
        let repo = try LibraryRepository(store: LibraryStore.open(configuration: config))
        let first = try repo.addCourse(name: "First")
        let second = try repo.addCourse(name: "Second")
        let arxiv = FixtureArxivProvider(); let doi = FixtureDOIProvider()
        let queue = ImportCoordinator(repository: repo, provider: arxiv, doiProvider: doi)
        try queue.enqueue(text: "https://doi.org/\(DOIFixtures.ieee) https://doi.org/\(DOIFixtures.mdpi) 1706.03762v1", destinationCourseID: first.id, assignExisting: true, refreshMetadata: false)
        await queue.waitUntilIdle()
        #expect(repo.papers.count == 3 && repo.importJobs.allSatisfy { $0.state == .completed })
        #expect(await arxiv.calls.count == 1)
        #expect(await doi.calls.count == 2)
        let paper = try #require(repo.papers.first { $0.doi == DOIFixtures.mdpi })
        #expect(paper.provider == "doi" && paper.identityKey == "doi:\(DOIFixtures.mdpi)")
        #expect(paper.resolvedVersion == nil && paper.pdfSourceURL == nil && paper.aiStatusRaw == "notRequested")
        try repo.saveNotes(paperID: paper.id, notes: "Keep notes")
        try repo.setFavorite(true, paperIDs: [paper.id])
        try queue.enqueue(text: "DOI:10.3390/S24020436", destinationCourseID: second.id, assignExisting: true, refreshMetadata: false)
        await queue.waitUntilIdle()
        #expect(await doi.calls.count == 2)
        #expect(repo.papers.count == 3 && paper.notes == "Keep notes" && paper.isFavorite)
        #expect(repo.courseIDs(paperID: paper.id) == [first.id, second.id])
        #expect(repo.importJobs.last?.outcomeRaw == "existing")
        let context = ModelContext(repo.store.container)
        #expect(try context.fetchCount(FetchDescriptor<Paper>()) == 3)
        #expect(try context.fetch(FetchDescriptor<ImportJob>()).filter { $0.identifier?.doiIdentifier != nil }.count == 3)
    }

    @Test func doiRefreshPreservesManualMetadataAndArxivSourceIdentity() async throws {
        let config = try configuration()
        defer { try? FileManager.default.removeItem(at: config.root) }
        let repo = try LibraryRepository(store: LibraryStore.open(configuration: config))
        let doi = FixtureDOIProvider()
        let queue = ImportCoordinator(repository: repo, provider: FixtureArxivProvider(), doiProvider: doi)
        try queue.enqueue(text: "1706.03762v1", destinationCourseID: nil, assignExisting: true, refreshMetadata: false)
        await queue.waitUntilIdle()
        let paper = try #require(repo.papers.first)
        try repo.updateMetadata(paperID: paper.id, draft: PaperDraft(title: "Manual title", authors: ["Manual author"], abstract: "Manual abstract", doi: "https://doi.org/10.1234/SOURCE"))
        try repo.saveNotes(paperID: paper.id, notes: "Personal notes")
        try queue.enqueue(text: "10.1234/source", destinationCourseID: nil, assignExisting: true, refreshMetadata: false)
        await queue.waitUntilIdle()
        #expect(await doi.calls.isEmpty)
        try queue.enqueue(text: "10.1234/source", destinationCourseID: nil, assignExisting: true, refreshMetadata: true)
        await queue.waitUntilIdle()
        #expect(repo.papers.count == 1 && paper.title == "Manual title" && paper.abstract == "Manual abstract")
        #expect(paper.provider == "arxiv" && paper.resolvedVersion == 1 && paper.pdfSourceURL != nil)
        #expect(paper.notes == "Personal notes" && repo.importJobs.last?.outcomeRaw == "refreshedProtected")
    }

    @Test func doiFailureIsIsolatedAndCanRetryAndMismatchedResultsAreRejected() async throws {
        let config = try configuration()
        defer { try? FileManager.default.removeItem(at: config.root) }
        let repo = try LibraryRepository(store: LibraryStore.open(configuration: config))
        let doi = FixtureDOIProvider()
        await doi.configure(failure: URLError(.notConnectedToInternet))
        let queue = ImportCoordinator(repository: repo, provider: FixtureArxivProvider(), doiProvider: doi)
        try queue.enqueue(text: "\(DOIFixtures.mdpi) 1706.03762v1", destinationCourseID: nil, assignExisting: true, refreshMetadata: false)
        await queue.waitUntilIdle()
        #expect(repo.papers.count == 1 && repo.importJobs.filter { $0.state == .failed }.count == 1)
        let job = try #require(repo.importJobs.first { $0.identifier?.doiIdentifier != nil })
        await doi.configure(mismatch: true)
        try queue.retry(ids: [job.id], destinationCourseID: nil, assignExisting: true, refreshMetadata: false)
        await queue.waitUntilIdle()
        #expect(job.state == .failed && repo.papers.count == 1)
        await doi.configure()
        try queue.retry(ids: [job.id], destinationCourseID: nil, assignExisting: true, refreshMetadata: false)
        await queue.waitUntilIdle()
        #expect(job.state == .completed && repo.papers.count == 2 && job.attemptCount == 3)
    }

    @Test func partialDOIRefreshKeepsPreviouslyRetrievedOptionalFields() async throws {
        let config = try configuration()
        defer { try? FileManager.default.removeItem(at: config.root) }
        let repo = try LibraryRepository(store: LibraryStore.open(configuration: config))
        let doi = FixtureDOIProvider()
        let queue = ImportCoordinator(repository: repo, provider: FixtureArxivProvider(), doiProvider: doi)
        try queue.enqueue(text: DOIFixtures.mdpi, destinationCourseID: nil, assignExisting: true, refreshMetadata: false)
        await queue.waitUntilIdle()
        let paper = try #require(repo.papers.first)
        await doi.configure(partial: true)
        try queue.enqueue(text: DOIFixtures.mdpi, destinationCourseID: nil, assignExisting: true, refreshMetadata: true)
        await queue.waitUntilIdle()
        #expect(paper.title == "Refreshed title" && paper.authors == ["First Author", "Second Author"])
        #expect(paper.abstract == "Original DOI abstract." && paper.journalReference == "Journal, 24, 436")
        #expect(paper.publicationDate == Date(timeIntervalSince1970: 100))
        #expect(repo.papers.count == 1 && repo.importJobs.last?.outcomeRaw == "refreshed")
    }

    @Test func cancellationPreventsLateDOIMetadataFromCreatingPaper() async throws {
        let config = try configuration()
        defer { try? FileManager.default.removeItem(at: config.root) }
        let repo = try LibraryRepository(store: LibraryStore.open(configuration: config))
        let doi = FixtureDOIProvider(); await doi.configure(delay: true)
        let queue = ImportCoordinator(repository: repo, provider: FixtureArxivProvider(), doiProvider: doi)
        let batch = try queue.enqueue(text: DOIFixtures.mdpi, destinationCourseID: nil, assignExisting: true, refreshMetadata: false)
        while await doi.calls.isEmpty { await Task.yield() }
        try queue.cancel(batchID: batch)
        await queue.waitUntilIdle()
        #expect(repo.papers.isEmpty && repo.importJobs.first?.state == .cancelled)
    }

    @Test func doiJobsSurviveReopenAndExplicitRetryWithoutSchemaChanges() async throws {
        let config = try configuration()
        defer { try? FileManager.default.removeItem(at: config.root) }
        try autoreleasepool {
            let repo = try LibraryRepository(store: LibraryStore.open(configuration: config))
            try repo.enqueueImports(ImportInput.parse(DOIFixtures.mdpi), destinationCourseID: nil, assignExisting: true, refreshMetadata: false)
            try repo.beginImports(ids: repo.importJobs.map(\.id))
        }
        let repo = try LibraryRepository(store: LibraryStore.open(configuration: config))
        let job = try #require(repo.importJobs.first)
        #expect(job.state == .interrupted && job.identifier?.doiIdentifier?.canonical == DOIFixtures.mdpi)
        let queue = ImportCoordinator(repository: repo, provider: FixtureArxivProvider(), doiProvider: FixtureDOIProvider())
        try queue.resume(ids: [job.id], destinationCourseID: nil, assignExisting: true, refreshMetadata: false)
        await queue.waitUntilIdle()
        #expect(job.state == .completed && job.attemptCount == 2 && repo.papers.count == 1)
    }

    @Test func arxivImportReusesExistingDOIRecordAndDeletionCancelsMatchingDOIJobs() async throws {
        let config = try configuration()
        defer { try? FileManager.default.removeItem(at: config.root) }
        let repo = try LibraryRepository(store: LibraryStore.open(configuration: config))
        let queue = ImportCoordinator(repository: repo, provider: FixtureArxivProvider(), doiProvider: FixtureDOIProvider())
        try queue.enqueue(text: "10.1234/source", destinationCourseID: nil, assignExisting: true, refreshMetadata: false)
        await queue.waitUntilIdle()
        let paper = try #require(repo.papers.first)
        try repo.saveNotes(paperID: paper.id, notes: "Keep DOI annotations")
        try queue.enqueue(text: "1706.03762v1", destinationCourseID: nil, assignExisting: true, refreshMetadata: false)
        await queue.waitUntilIdle()
        #expect(repo.papers.count == 1 && paper.notes == "Keep DOI annotations")
        try repo.enqueueImports(ImportInput.parse("10.1234/source"), destinationCourseID: nil, assignExisting: true, refreshMetadata: true)
        try repo.deletePapers(ids: [paper.id])
        #expect(repo.importJobs.last?.state == .cancelled)
    }
}

extension DOIImportTests {
    @Test func existingDOIPaperIsRepairedOnceAndManualTitleNotesAndCoursesSurvive() async throws {
        let config = try configuration()
        defer { try? FileManager.default.removeItem(at: config.root) }
        let repo = try LibraryRepository(store: LibraryStore.open(configuration: config))
        let course = try repo.addCourse(name: "Vehicle estimation")
        let original = ImportCoordinator(repository: repo, provider: FixtureArxivProvider(), doiProvider: FixtureDOIProvider())
        try original.enqueue(text: DOIFixtures.ieee, destinationCourseID: course.id, assignExisting: true, refreshMetadata: false)
        await original.waitUntilIdle()
        let paper = try #require(repo.papers.first)
        try repo.updateMetadata(paperID: paper.id, draft: PaperDraft(title: "My title", authors: paper.authors, abstract: "", doi: paper.doi))
        try repo.saveNotes(paperID: paper.id, notes: "My notes")
        let transport = MockDOITransport([(200, try DOIFixtures.crossref(doi: DOIFixtures.ieee, abstract: nil), [:]),
            (200, try DOIFixtures.openalex(), [:])])
        let repair = ImportCoordinator(repository: repo, provider: FixtureArxivProvider(), doiProvider: DOIClient(transport: transport, clock: TestArxivClock()))
        try repair.recoverDOIDetails(paperID: paper.id)
        await repair.waitUntilIdle()
        #expect(paper.title == "My title" && paper.abstract == "Source abstract." && paper.notes == "My notes")
        #expect(paper.metadataStatusRaw == "doiEnriched" && repo.papers.count == 1 && repo.courseIDs(paperID: paper.id) == [course.id])
        #expect(paper.pdfDownloadURL == nil && paper.publisherPDFURL?.host == "doi.org")
        try repair.recoverDOIDetails(paperID: paper.id)
        await repair.waitUntilIdle()
        #expect(await transport.requests.count == 2)
    }
}

private struct DOIStubReply: Sendable {
    var status = 200
    var headers: [String: String] = [:]
    var body = Data()
}
private final class DOIStubState: @unchecked Sendable {
    private let lock = NSLock()
    private var reply = DOIStubReply()
    private var recorded: [URLRequest] = []
    func reset(_ reply: DOIStubReply) { lock.withLock { self.reply = reply; recorded = [] } }
    func response(for request: URLRequest) -> DOIStubReply { lock.withLock { recorded.append(request); return reply } }
    var requests: [URLRequest] { lock.withLock { recorded } }
}
private final class StubDOIURLProtocol: URLProtocol, @unchecked Sendable {
    static let state = DOIStubState()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let reply = Self.state.response(for: request)
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite(.serialized)
struct DOITransportTests {
    private func transport() -> DOIURLSessionTransport {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubDOIURLProtocol.self]
        return DOIURLSessionTransport(configuration: config)
    }
    private var url: URL { get throws { DOINetworkPolicy.endpoint(for: try DOIIdentifier(DOIFixtures.mdpi)) } }

    @Test func actualSessionReceivesMetadataAtEncodedFixedEndpoint() async throws {
        StubDOIURLProtocol.state.reset(DOIStubReply(body: try DOIFixtures.crossref()))
        let response = try await transport().send(URLRequest(url: url))
        #expect(try DOIMetadataParser.crossref(response.body, requested: DOIIdentifier(DOIFixtures.mdpi)).authors.count == 2)
        #expect(StubDOIURLProtocol.state.requests.count == 1)
    }

    @Test func unsupportedHostsAndRequestsAreRejectedBeforeSending() async throws {
        StubDOIURLProtocol.state.reset(DOIStubReply())
        for input in ["https://doi.org/10.3390/s24020436", "http://api.crossref.org/works/10.3390%2Fs24020436", "https://api.crossref.org.evil.test/works/test", "https://api.crossref.org:443/works/test", "https://api.crossref.org/works?query=notes", "https://api.datacite.org/dois?query=notes"] {
            await #expect(throws: DOIError.self) { try await transport().send(URLRequest(url: URL(string: input)!)) }
        }
        #expect(StubDOIURLProtocol.state.requests.isEmpty)
    }

    @Test func redirectsAndAdvertisedOrStreamedOversizeAreRejected() async throws {
        StubDOIURLProtocol.state.reset(DOIStubReply(status: 302, headers: ["Location": "https://evil.test/"]))
        await #expect(throws: DOIError.redirectRejected) { try await transport().send(URLRequest(url: url)) }
        StubDOIURLProtocol.state.reset(DOIStubReply(headers: ["Content-Length": "2097153"]))
        await #expect(throws: DOIError.responseTooLarge) { try await transport().send(URLRequest(url: url)) }
        StubDOIURLProtocol.state.reset(DOIStubReply(body: Data(repeating: 65, count: 2_097_153)))
        await #expect(throws: DOIError.responseTooLarge) { try await transport().send(URLRequest(url: url)) }
    }
}
