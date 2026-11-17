import Foundation
import Testing
import PaperLibrarySupport
@testable import PaperLibraryCore

private struct PDFHTTPReply: Sendable {
    var status = 200
    var headers: [String: String] = [:]
    var body = PDFFixtures.document()
}
private final class PDFHTTPState: @unchecked Sendable {
    private let lock = NSLock()
    private var reply = PDFHTTPReply()
    private var count = 0
    func reset(_ reply: PDFHTTPReply) { lock.withLock { self.reply = reply; count = 0 } }
    func next() -> PDFHTTPReply { lock.withLock { count += 1; return reply } }
    var calls: Int { lock.withLock { count } }
}
private final class PDFStubProtocol: URLProtocol, @unchecked Sendable {
    static let state = PDFHTTPState()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let reply = Self.state.next()
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
private actor PDFProgressProbe {
    var received: Int64 = 0
    func update(_ bytes: Int64) { received = bytes }
}

@Suite(.serialized)
struct PDFTransportTests {
    private func setup() throws -> (StorageConfiguration, PDFFileStore, PDFURLSessionTransport) {
        let config = try StorageConfiguration.testing(at: FileManager.default.temporaryDirectory.appendingPathComponent("PaperLibraryPDFHTTP-\(UUID().uuidString)"))
        let options = URLSessionConfiguration.ephemeral; options.protocolClasses = [PDFStubProtocol.self]
        return (config, PDFFileStore(configuration: config), PDFURLSessionTransport(configuration: options))
    }
    private let url = URL(string: "https://arxiv.org/pdf/1706.03762v1")!

    @Test(arguments: ["https://arxiv.org/pdf/1706.03762v1", "https://www.mdpi.com/1424-8220/24/2/436/pdf"])
    func streamsPDFBytesToDiskWithRealProgress(_ source: String) async throws {
        let (c, files, transport) = try setup(); defer { try? FileManager.default.removeItem(at: c.root) }
        let data = PDFFixtures.document()
        PDFStubProtocol.state.reset(PDFHTTPReply(headers: ["Content-Length": String(data.count)], body: data))
        let stage = try await files.stagingURL(jobID: UUID())
        let probe = PDFProgressProbe()
        let reply = try await transport.transfer(url: URL(string: source)!, staged: stage, limits: PDFLimits(), fileStore: files) { bytes, _ in await probe.update(bytes) }
        let received = await probe.received
        #expect(reply.status == 200 && received == data.count)
        #expect(try Data(contentsOf: stage) == data)
    }

    @Test func rejectsUnsafeSourcesRedirectsAndSizeLimits() async throws {
        let (c, files, transport) = try setup(); defer { try? FileManager.default.removeItem(at: c.root) }
        let stage = try await files.stagingURL(jobID: UUID())
        PDFStubProtocol.state.reset(PDFHTTPReply())
        await #expect(throws: (any Error).self) { try await transport.transfer(url: URL(string: "https://evil.test/a.pdf")!, staged: stage, limits: PDFLimits(), fileStore: files) { _, _ in } }
        #expect(PDFStubProtocol.state.calls == 0)
        PDFStubProtocol.state.reset(PDFHTTPReply(status: 302, headers: ["Location": "https://evil.test/a.pdf"]))
        await #expect(throws: PDFLibraryError.invalidSource) { try await transport.transfer(url: url, staged: stage, limits: PDFLimits(), fileStore: files) { _, _ in } }
        PDFStubProtocol.state.reset(PDFHTTPReply(headers: ["Content-Length": "10000"]))
        await #expect(throws: PDFLibraryError.tooLarge) { try await transport.transfer(url: url, staged: stage, limits: PDFLimits(maximumBytes: 100), fileStore: files) { _, _ in } }
        PDFStubProtocol.state.reset(PDFHTTPReply(body: Data(repeating: 65, count: 101)))
        await #expect(throws: PDFLibraryError.tooLarge) { try await transport.transfer(url: url, staged: stage, limits: PDFLimits(maximumBytes: 100), fileStore: files) { _, _ in } }
    }

    @Test func diskReserveAndStagingSymlinksFailSafely() async throws {
        let (c, files, transport) = try setup(); defer { try? FileManager.default.removeItem(at: c.root) }
        let stage = try await files.stagingURL(jobID: UUID())
        PDFStubProtocol.state.reset(PDFHTTPReply())
        await #expect(throws: PDFLibraryError.diskSpace) { try await transport.transfer(url: url, staged: stage, limits: PDFLimits(reserveBytes: .max), fileStore: files) { _, _ in } }
        #expect(!FileManager.default.fileExists(atPath: stage.path))
        let target = c.root.appendingPathComponent("keep.txt")
        try Data("Keep this file".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: stage, withDestinationURL: target)
        await #expect(throws: PDFLibraryError.unsafePath) { try await files.install(staged: stage, paperID: UUID(), version: 1, limits: PDFLimits()) }
        #expect(try String(contentsOf: target, encoding: .utf8) == "Keep this file")
    }

    @Test func HTTPFailuresAndRetryAfterReturnWithoutPublishingAFile() async throws {
        let (c, files, transport) = try setup(); defer { try? FileManager.default.removeItem(at: c.root) }
        let stage = try await files.stagingURL(jobID: UUID())
        PDFStubProtocol.state.reset(PDFHTTPReply(status: 429, headers: ["Retry-After": "90"]))
        let reply = try await transport.transfer(url: url, staged: stage, limits: PDFLimits(), fileStore: files) { _, _ in }
        #expect(reply.status == 429 && reply.retryAfter == 90)
        #expect(!FileManager.default.fileExists(atPath: stage.path))
    }
}
