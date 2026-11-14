import Foundation
import Testing
@testable import PaperLibraryCore

private struct StubHTTPReply: Sendable {
    var status: Int = 200
    var headers: [String: String] = [:]
    var body: Data = ArxivFixtures.feed()
}

private final class HTTPStubState: @unchecked Sendable {
    private let lock = NSLock()
    private var reply = StubHTTPReply()
    private var recorded: [URLRequest] = []
    func reset(_ reply: StubHTTPReply) { lock.withLock { self.reply = reply; recorded = [] } }
    func response(for request: URLRequest) -> StubHTTPReply { lock.withLock { recorded.append(request); return reply } }
    var requests: [URLRequest] { lock.withLock { recorded } }
}

private final class StubArxivURLProtocol: URLProtocol, @unchecked Sendable {
    static let state = HTTPStubState()
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
struct ArxivTransportTests {
    private func transport() -> ArxivURLSessionTransport {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubArxivURLProtocol.self]
        return ArxivURLSessionTransport(configuration: configuration)
    }
    private var url: URL { URL(string: "https://export.arxiv.org/api/query?id_list=1706.03762v1&start=0&max_results=1")! }

    @Test func actualURLSessionTransportReceivesBoundedAtomResponse() async throws {
        StubArxivURLProtocol.state.reset(StubHTTPReply())
        let response = try await transport().send(URLRequest(url: url))
        #expect(response.status == 200)
        #expect(try ArxivAtomParser.parse(response.body).first?.identifier.queryValue == "1706.03762v1")
        #expect(StubArxivURLProtocol.state.requests.count == 1)
    }

    @Test func automaticNetworkPolicyRejectsOtherHostsBeforeSending() async {
        StubArxivURLProtocol.state.reset(StubHTTPReply())
        for input in ["https://evil.test/api/query", "http://export.arxiv.org/api/query", "https://export.arxiv.org:443/api/query", "https://export.arxiv.org/api/query?search_query=all:notes", "https://export.arxiv.org/api/query?id_list=1706.03762&start=0&max_results=2"] {
            await #expect(throws: (any Error).self) { try await transport().send(URLRequest(url: URL(string: input)!)) }
        }
        #expect(StubArxivURLProtocol.state.requests.isEmpty)
    }

    @Test func redirectsAndAdvertisedOversizeAreRejected() async {
        StubArxivURLProtocol.state.reset(StubHTTPReply(status: 302, headers: ["Location": "https://evil.test/notes"]))
        await #expect(throws: ArxivError.redirectRejected) { try await transport().send(URLRequest(url: url)) }
        #expect(StubArxivURLProtocol.state.requests.count == 1)
        StubArxivURLProtocol.state.reset(StubHTTPReply(headers: ["Content-Length": "2097153"]))
        await #expect(throws: ArxivError.responseTooLarge) { try await transport().send(URLRequest(url: url)) }
    }

    @Test func undeclaredOversizeIsStoppedWhileStreaming() async {
        StubArxivURLProtocol.state.reset(StubHTTPReply(body: Data(repeating: 65, count: 2_097_153)))
        await #expect(throws: ArxivError.responseTooLarge) { try await transport().send(URLRequest(url: url)) }
    }
}
