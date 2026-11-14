import Foundation
import Testing
@testable import PaperLibraryCore

struct ArxivTests {
    @Test(arguments: ["https://arxiv.org/abs/1706.03762v2", "https://arxiv.org/pdf/1706.03762v2.pdf", "http://www.arxiv.org/pdf/1706.03762v2", "1706.03762v2", "arXiv:1706.03762v2"])
    func normalizesIdentifiers(_ input: String) throws {
        let id = try ArxivIdentifier(input)
        #expect(id.canonical == "1706.03762")
        #expect(id.version == 2)
        #expect(id.canonicalURL.absoluteString == "https://arxiv.org/abs/1706.03762")
        #expect(id.pdfURL.absoluteString == "https://arxiv.org/pdf/1706.03762v2")
    }

    @Test(arguments: ["hep-th/9901001v1", "math.GT/0309136", "cond-mat/0207270", "2501.00001"])
    func acceptsLegacyAndModernIDs(_ input: String) throws { _ = try ArxivIdentifier(input) }

    @Test(arguments: ["https://arxiv.org.evil.test/abs/1706.03762", "https://arxiv.org@evil.test/abs/1706.03762", "https://evil.test/abs/1706.03762", "file:///1706.03762", "javascript:1706.03762", "https://arxiv.org:443/abs/1706.03762", "https://arxiv.org/abs/%31%37%30%36.03762", "https://arxiv.org/abs/../1706.03762", "https://arxiv.org/abs/1706.03762?x=1", "1706.03762v0", "1713.03762", "1706.03762v9999999", "1706.03762/../../tmp"])
    func rejectsUnsafeInputs(_ input: String) { #expect(throws: (any Error).self) { try ArxivIdentifier(input) } }

    @Test func batchInputDeduplicatesExactVersionAndKeepsFailures() throws {
        let inputs = try ImportInput.parse("1706.03762v1, https://arxiv.org/pdf/1706.03762v1.pdf\n1706.03762v2 invalid")
        #expect(inputs.count == 3)
        #expect(inputs.compactMap(\.identifier).count == 2)
        #expect(inputs.last?.error != nil)
        #expect(throws: ArxivError.self) { try ImportInput.parse(String(repeating: "x", count: 65_537)) }
    }

    @Test func atomParsesNamespacesAuthorsDatesAndOriginalMetadata() throws {
        let records = try ArxivAtomParser.parse(ArxivFixtures.feed())
        let record = try #require(records.first)
        #expect(record.title == "A test paper")
        #expect(record.authors == ["First Author", "Second Author"])
        #expect(record.abstract == "Original abstract & technical evidence.")
        #expect(record.categories == ["cs.CL", "cs.LG"])
        #expect(record.doi == "10.1234/test")
        #expect(record.journalReference == "Journal reference supplied by authors")
        #expect(record.identifier.version == 1)
        #expect(record.hasPDF)
    }

    @Test func atomRejectsMalformedUnsafeAndIncompleteContent() throws {
        for data in [Data("<feed>broken".utf8), Data("<!DOCTYPE feed [<!ENTITY x SYSTEM 'file:///etc/passwd'>]><feed/>".utf8), ArxivFixtures.feed(ArxivFixtures.entry(pdfHost: "evil.test")), ArxivFixtures.feed(ArxivFixtures.entry().replacingOccurrences(of: "<title>A test paper</title>", with: "")), Data("<feed xmlns='https://evil.test'><entry/></feed>".utf8)] {
            #expect(throws: ArxivError.self) { try ArxivAtomParser.parse(data) }
        }
        #expect(throws: ArxivError.self) { try ArxivAtomParser.parse(Data(repeating: 65, count: 2_097_153)) }
        #expect(try ArxivAtomParser.parse(ArxivFixtures.feed("")).isEmpty)
    }

    @Test func atomRetainsCDATAAndUnicodeWithoutFollowingExternalJournalLinks() throws {
        let entry = ArxivFixtures.entry(author: "Łukasz García").replacingOccurrences(of: "<title>A test paper</title>", with: "<title><![CDATA[An exact <model> title]]></title>")
            .replacingOccurrences(of: "</entry>", with: "<link href='https://publisher.example/journal' rel='related'/></entry>")
        let record = try #require(ArxivAtomParser.parse(ArxivFixtures.feed(entry)).first)
        #expect(record.title == "An exact <model> title")
        #expect(record.authors.first == "Łukasz García")
    }

    @Test func clientBatchesIDsAndHonorsSpacingAndRetryAfter() async throws {
        let clock = TestArxivClock()
        let response = ArxivHTTPResponse(status: 429, headers: ["retry-after": "9"], body: Data(), url: ArxivNetworkPolicy.endpoint)
        let transport = MockArxivTransport(clock: clock, responses: [response, .init(status: 200, body: ArxivFixtures.feed(), url: ArxivNetworkPolicy.endpoint), .init(status: 200, body: ArxivFixtures.feed(), url: ArxivNetworkPolicy.endpoint)])
        let client = ArxivClient(scheduler: ArxivRequestScheduler(transport: transport, clock: clock))
        _ = try await client.fetch([ArxivIdentifier("1706.03762v1")])
        _ = try await client.fetch([ArxivIdentifier("1706.03762v1")])
        let times = await transport.times
        #expect(times == [0, 9, 12])
        let request = try #require(await transport.requests.first)
        #expect(request.value(forHTTPHeaderField: "User-Agent")?.contains("PaperLibrary") == true)
        #expect(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first?.name == "id_list")
    }

    @Test func boundedRetriesAndNonTransientFailures() async throws {
        let clock = TestArxivClock()
        let unavailable = ArxivHTTPResponse(status: 503, body: Data(), url: ArxivNetworkPolicy.endpoint)
        let transport = MockArxivTransport(clock: clock, responses: [unavailable, unavailable, unavailable])
        let client = ArxivClient(scheduler: ArxivRequestScheduler(transport: transport, clock: clock))
        await #expect(throws: ArxivError.http(503)) { try await client.fetch([ArxivIdentifier("1706.03762")]) }
        #expect(await transport.requests.count == 3)
        let other = MockArxivTransport(clock: clock, responses: [.init(status: 404, body: Data(), url: ArxivNetworkPolicy.endpoint)])
        let missing = ArxivClient(scheduler: ArxivRequestScheduler(transport: other, clock: clock))
        await #expect(throws: ArxivError.http(404)) { try await missing.fetch([ArxivIdentifier("1706.03762")]) }
        #expect(await other.requests.count == 1)
    }

    @Test func timeoutsRetryWithinBoundsAndOfflineErrorsStopImmediately() async throws {
        let clock = TestArxivClock()
        let timeout = MockArxivTransport(clock: clock, responses: [], networkError: URLError(.timedOut))
        let timed = ArxivClient(scheduler: ArxivRequestScheduler(transport: timeout, clock: clock))
        await #expect(throws: URLError.self) { try await timed.fetch([ArxivIdentifier("1706.03762")]) }
        #expect(await timeout.requests.count == 3)
        let offline = MockArxivTransport(clock: clock, responses: [], networkError: URLError(.notConnectedToInternet))
        let unavailable = ArxivClient(scheduler: ArxivRequestScheduler(transport: offline, clock: clock))
        await #expect(throws: URLError.self) { try await unavailable.fetch([ArxivIdentifier("1706.03762")]) }
        #expect(await offline.requests.count == 1)
    }

    @Test func concurrentCallsRemainSerializedAndSpaced() async throws {
        let clock = TestArxivClock()
        let ok = ArxivHTTPResponse(status: 200, body: ArxivFixtures.feed(), url: ArxivNetworkPolicy.endpoint)
        let transport = MockArxivTransport(clock: clock, responses: [ok, ok, ok])
        let client = ArxivClient(scheduler: ArxivRequestScheduler(transport: transport, clock: clock))
        let id = try ArxivIdentifier("1706.03762v1")
        async let first = client.fetch([id])
        async let second = client.fetch([id])
        async let third = client.fetch([id])
        _ = try await (first, second, third)
        #expect(await transport.times == [0, 3, 6])
        #expect(await transport.peakActiveCalls == 1)
    }

    @Test func retryAfterHTTPDateAndLongCooldown() async throws {
        let now = Date(timeIntervalSince1970: 0)
        #expect(ArxivNetworkPolicy.retryAfter("Thu, 01 Jan 1970 00:00:12 GMT", now: now) == 12)
        #expect(ArxivNetworkPolicy.retryAfter("nonsense", now: now) == nil)
        let clock = TestArxivClock()
        let transport = MockArxivTransport(clock: clock, responses: [.init(status: 503, headers: ["retry-after": "3600"], body: Data(), url: ArxivNetworkPolicy.endpoint)])
        let client = ArxivClient(scheduler: ArxivRequestScheduler(transport: transport, clock: clock))
        await #expect(throws: ArxivError.cooldown) { try await client.fetch([ArxivIdentifier("1706.03762")]) }
        #expect(await transport.requests.count == 1)
    }

    @Test func persistedServerCooldownSurvivesClientReplacement() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("PaperLibraryThrottle-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("cooldown.json")
        let clock = TestArxivClock()
        let transport = MockArxivTransport(clock: clock, responses: [])
        let scheduler = ArxivRequestScheduler(transport: transport, clock: clock, cooldownURL: file)
        try await scheduler.postpone(seconds: 3600)
        let replacement = ArxivRequestScheduler(transport: transport, clock: clock, cooldownURL: file)
        let client = ArxivClient(scheduler: replacement)
        await #expect(throws: ArxivError.cooldown) { try await client.fetch([ArxivIdentifier("1706.03762")]) }
        #expect(await transport.requests.isEmpty)
    }

    @Test func independentSchedulersShareTheRequestLeaseAndDeadline() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("PaperLibrarySharedThrottle-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("cooldown.json")
        let clock = SystemArxivClock()
        let ok = ArxivHTTPResponse(status: 200, body: ArxivFixtures.feed(), url: ArxivNetworkPolicy.endpoint)
        let transport = MockArxivTransport(clock: clock, responses: [ok, ok])
        let first = ArxivClient(scheduler: ArxivRequestScheduler(transport: transport, clock: clock, cooldownURL: file))
        let second = ArxivClient(scheduler: ArxivRequestScheduler(transport: transport, clock: clock, cooldownURL: file))
        let id = try ArxivIdentifier("1706.03762v1")
        async let a = first.fetch([id])
        async let b = second.fetch([id])
        _ = try await (a, b)
        #expect(await transport.peakActiveCalls == 1)
        let times = await transport.times
        #expect(times.count == 2 && times[1] - times[0] >= 3)
    }
}
