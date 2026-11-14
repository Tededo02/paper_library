import Foundation
@testable import PaperLibraryCore

enum ArxivFixtures {
    static func entry(id: String = "1706.03762v1", title: String = "A test paper", author: String = "First Author", pdfHost: String = "arxiv.org") -> String {
        """
        <entry><id>http://arxiv.org/abs/\(id)</id><title>\(title)</title>
        <published>2017-06-12T17:57:34Z</published><updated>2017-06-13T18:01:02Z</updated>
        <author><name>\(author)</name><a:affiliation>Example University</a:affiliation></author>
        <author><name>Second Author</name></author><summary>Original abstract &amp; technical evidence.</summary>
        <category term="cs.CL"/><category term="cs.LG"/>
        <link href="https://\(pdfHost)/pdf/\(id)" rel="related" type="application/pdf" title="pdf"/>
        <a:doi>10.1234/test</a:doi><a:journal_ref>Journal reference supplied by authors</a:journal_ref></entry>
        """
    }
    static func feed(_ entries: String? = nil) -> Data {
        Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <feed xmlns="http://www.w3.org/2005/Atom" xmlns:a="http://arxiv.org/schemas/atom">
        <id>https://arxiv.org/api/query</id><title>Feed title, not paper title</title>
        \(entries ?? entry())</feed>
        """.utf8)
    }
    static func metadata(id: String = "1706.03762v1", title: String = "Imported paper") throws -> ArxivMetadata {
        try ArxivMetadata(identifier: ArxivIdentifier(id), title: title, authors: ["First", "Second"], abstract: "Original source", publishedAt: Date(timeIntervalSince1970: 100), updatedAt: Date(timeIntervalSince1970: 200), categories: ["cs.CL"], doi: "10.1234/source", journalReference: "Reported journal")
    }
}

actor TestArxivClock: ArxivClock {
    var instant: TimeInterval = 0
    var delays: [TimeInterval] = []
    func now() -> TimeInterval { instant }
    func sleep(seconds: TimeInterval) throws {
        try Task.checkCancellation()
        delays.append(seconds); instant += seconds
    }
    func advance(_ seconds: TimeInterval) { instant += seconds }
}

actor MockArxivTransport: ArxivTransport {
    let clock: any ArxivClock
    var responses: [ArxivHTTPResponse]
    var requests: [URLRequest] = []
    var times: [TimeInterval] = []
    var activeCalls = 0
    var peakActiveCalls = 0
    let networkError: URLError?
    init(clock: any ArxivClock, responses: [ArxivHTTPResponse], networkError: URLError? = nil) {
        self.clock = clock; self.responses = responses; self.networkError = networkError
    }
    func send(_ request: URLRequest) async throws -> ArxivHTTPResponse {
        activeCalls += 1; peakActiveCalls = max(peakActiveCalls, activeCalls)
        defer { activeCalls -= 1 }
        requests.append(request); times.append(await clock.now())
        if let networkError { throw networkError }
        guard !responses.isEmpty else { throw URLError(.timedOut) }
        let response = responses.removeFirst()
        return ArxivHTTPResponse(status: response.status, headers: response.headers, body: response.body, url: request.url!)
    }
}

actor FixtureArxivProvider: ArxivMetadataProviding {
    var calls: [[ArxivIdentifier]] = []
    var failure: URLError?
    var omitResults = false
    var delay = false
    var delayStartingAt: Int?
    func configure(failure: URLError? = nil, omitResults: Bool = false, delay: Bool = false, delayStartingAt: Int? = nil) {
        self.failure = failure; self.omitResults = omitResults; self.delay = delay; self.delayStartingAt = delayStartingAt
    }
    func fetch(_ identifiers: [ArxivIdentifier]) async throws -> [ArxivMetadata] {
        calls.append(identifiers)
        if delay || delayStartingAt.map({ calls.count >= $0 }) == true { try await Task.sleep(for: .seconds(60)) }
        if let failure { throw failure }
        if omitResults { return [] }
        return try identifiers.map { try ArxivFixtures.metadata(id: $0.canonical + "v\($0.version ?? 3)") }
    }
}
