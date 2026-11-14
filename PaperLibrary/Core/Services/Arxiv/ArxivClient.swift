import Foundation
import PaperLibrarySupport

public protocol ArxivMetadataProviding: Sendable {
    func fetch(_ identifiers: [ArxivIdentifier]) async throws -> [ArxivMetadata]
}

public struct ArxivHTTPResponse: Sendable {
    public let status: Int
    public let headers: [String: String]
    public let body: Data
    public let url: URL

    public init(status: Int, headers: [String: String] = [:], body: Data, url: URL) {
        self.status = status; self.headers = headers; self.body = body; self.url = url
    }
}

public protocol ArxivTransport: Sendable {
    func send(_ request: URLRequest) async throws -> ArxivHTTPResponse
}

public enum ArxivNetworkPolicy {
    public static let endpoint = URL(string: "https://export.arxiv.org/api/query")!

    public static func validate(_ url: URL) throws {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme == "https", parts.host == "export.arxiv.org", parts.port == nil,
              parts.user == nil, parts.password == nil, parts.fragment == nil,
              parts.percentEncodedPath == "/api/query" else { throw ArxivError.unsupportedURL }
        let items = parts.queryItems ?? []
        guard Set(items.map(\.name)) == ["id_list", "start", "max_results"], items.count == 3,
              items.first(where: { $0.name == "start" })?.value == "0",
              let maximum = items.first(where: { $0.name == "max_results" })?.value.flatMap(Int.init), (1...20).contains(maximum),
              let ids = items.first(where: { $0.name == "id_list" })?.value else { throw ArxivError.unsupportedURL }
        let values = ids.split(separator: ",", omittingEmptySubsequences: false)
        guard values.count <= 20, values.count == maximum else { throw ArxivError.unsupportedURL }
        for value in values {
            guard try ArxivIdentifier(String(value)).queryValue == value else { throw ArxivError.unsupportedURL }
        }
    }

    public static func retryAfter(_ value: String?, now: Date = Date()) -> TimeInterval? {
        guard let value else { return nil }
        if let seconds = Double(value), seconds.isFinite, seconds >= 0 { return seconds }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        for pattern in ["EEE, dd MMM yyyy HH:mm:ss z", "EEEE, dd-MMM-yy HH:mm:ss z", "EEE MMM d HH:mm:ss yyyy"] {
            formatter.dateFormat = pattern
            if let date = formatter.date(from: value) { return max(0, date.timeIntervalSince(now)) }
        }
        return nil
    }
}

private final class RejectRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

public final class ArxivURLSessionTransport: ArxivTransport {
    private let session: URLSession
    public convenience init() { self.init(configuration: .ephemeral) }
    init(configuration: URLSessionConfiguration) {
        configuration.httpMaximumConnectionsPerHost = 1
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        session = URLSession(configuration: configuration, delegate: RejectRedirects(), delegateQueue: nil)
    }

    deinit { session.invalidateAndCancel() }

    public func send(_ request: URLRequest) async throws -> ArxivHTTPResponse {
        guard let url = request.url else { throw ArxivError.unsupportedURL }
        try ArxivNetworkPolicy.validate(url)
        let (bytes, response) = try await session.bytes(for: request)
        defer { bytes.task.cancel() }
        guard let http = response as? HTTPURLResponse, http.url == url else { throw ArxivError.redirectRejected }
        guard !(300...399).contains(http.statusCode) else { throw ArxivError.redirectRejected }
        guard http.expectedContentLength <= 2_097_152 else { throw ArxivError.responseTooLarge }
        var body = Data()
        for try await byte in bytes {
            guard body.count < 2_097_152 else { throw ArxivError.responseTooLarge }
            body.append(byte)
        }
        let headers = http.allHeaderFields.reduce(into: [String: String]()) { result, pair in
            if let name = pair.key as? String { result[name.lowercased()] = String(describing: pair.value) }
        }
        return ArxivHTTPResponse(status: http.statusCode, headers: headers, body: body, url: url)
    }
}

public protocol ArxivClock: Sendable {
    func now() async -> TimeInterval
    func sleep(seconds: TimeInterval) async throws
}

public struct SystemArxivClock: ArxivClock {
    public init() {}
    public func now() async -> TimeInterval { ProcessInfo.processInfo.systemUptime }
    public func sleep(seconds: TimeInterval) async throws { try await Task.sleep(for: .seconds(seconds)) }
}

private struct ArxivCooldown: Codable {
    let notBefore: Date
}

public actor ArxivRequestScheduler {
    private let transport: any ArxivTransport
    private let clock: any ArxivClock
    private let cooldownURL: URL?
    private var nextRequest: TimeInterval = 0
    private var occupied = false
    private var waiters: [(UUID, CheckedContinuation<Void, any Error>)] = []

    public init(transport: any ArxivTransport, clock: any ArxivClock = SystemArxivClock(), cooldownURL: URL? = nil) {
        self.transport = transport; self.clock = clock; self.cooldownURL = cooldownURL
    }

    public func send(_ request: URLRequest) async throws -> ArxivHTTPResponse {
        let transport = self.transport
        return try await perform {
            let response = try await transport.send(request)
            return (response, ArxivNetworkPolicy.retryAfter(response.headers["retry-after"]))
        }
    }

    public func perform<Value: Sendable>(_ operation: @Sendable () async throws -> (Value, TimeInterval?)) async throws -> Value {
        try await acquire()
        defer { release() }
        let processPermit = try await acquireProcessPermit()
        defer { withExtendedLifetime(processPermit) {} }
        try Task.checkCancellation()
        try await restoreCooldown()
        while nextRequest > (await clock.now()) {
            let remaining = nextRequest - (await clock.now())
            guard remaining <= 60 else { throw ArxivError.cooldown }
            try await clock.sleep(seconds: max(0, remaining))
        }
        try Task.checkCancellation()
        try await postponeLocked(seconds: 3)
        let response: (Value, TimeInterval?)
        do { response = try await operation() }
        catch { try await postponeLocked(seconds: 3); throw error }
        try await postponeLocked(seconds: max(3, response.1 ?? 0))
        return response.0
    }

    public func postpone(seconds: TimeInterval) async throws {
        try await acquire()
        defer { release() }
        let processPermit = try await acquireProcessPermit()
        defer { withExtendedLifetime(processPermit) {} }
        try await restoreCooldown()
        try await postponeLocked(seconds: seconds)
    }

    private func restoreCooldown() async throws {
        guard let url = cooldownURL, FileManager.default.fileExists(atPath: url.path) else { return }
        let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .fileSizeKey])
        guard values.isSymbolicLink != true, (values.fileSize ?? 4097) <= 4096 else { throw LibraryError.unsafeStorage }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count <= 4096 else { throw ArxivError.cooldown }
        let state = try JSONDecoder().decode(ArxivCooldown.self, from: data)
        nextRequest = max(nextRequest, await clock.now() + max(0, state.notBefore.timeIntervalSinceNow))
    }

    private func acquireProcessPermit() async throws -> ArxivProcessPermit? {
        guard let cooldownURL else { return nil }
        let permit = try ArxivProcessPermit(stateURL: cooldownURL)
        while try !permit.tryAcquire() { try Task.checkCancellation(); try await clock.sleep(seconds: 0.1) }
        return permit
    }

    private func postponeLocked(seconds: TimeInterval) async throws {
        let bounded = min(seconds, Date.distantFuture.timeIntervalSinceNow)
        let now = await clock.now()
        nextRequest = max(nextRequest, now + bounded)
        if let url = cooldownURL {
            if FileManager.default.fileExists(atPath: url.path) {
                guard try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw LibraryError.unsafeStorage }
            }
            let state = ArxivCooldown(notBefore: Date().addingTimeInterval(max(0, nextRequest - now)))
            try JSONEncoder().encode(state).write(to: url, options: .atomic)
        }
    }

    private func acquire() async throws {
        try Task.checkCancellation()
        if !occupied { occupied = true; return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in waiters.append((id, continuation)) }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }
    private func cancelWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.0 == id }) else { return }
        waiters.remove(at: index).1.resume(throwing: CancellationError())
    }
    private func release() {
        if waiters.isEmpty { occupied = false }
        else { waiters.removeFirst().1.resume() }
    }
}

public actor ArxivClient: ArxivMetadataProviding {
    private let scheduler: ArxivRequestScheduler
    public init(scheduler: ArxivRequestScheduler) { self.scheduler = scheduler }

    public static func local(cooldownURL: URL) -> ArxivClient {
        ArxivClient(scheduler: ArxivRequestScheduler(transport: ArxivURLSessionTransport(), cooldownURL: cooldownURL))
    }

    public func fetch(_ identifiers: [ArxivIdentifier]) async throws -> [ArxivMetadata] {
        guard !identifiers.isEmpty, identifiers.count <= 20 else { throw ArxivError.invalidIdentifier }
        var components = URLComponents(url: ArxivNetworkPolicy.endpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "id_list", value: identifiers.map(\.queryValue).joined(separator: ",")), URLQueryItem(name: "start", value: "0"), URLQueryItem(name: "max_results", value: String(identifiers.count))]
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 30
        request.setValue("PaperLibrary/0.2 (local.paperlibrary.app; personal macOS research library)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/atom+xml", forHTTPHeaderField: "Accept")
        for attempt in 0..<3 {
            try Task.checkCancellation()
            do {
                let response = try await scheduler.send(request)
                guard response.url == request.url else { throw ArxivError.redirectRejected }
                if [408, 429, 500, 502, 503, 504].contains(response.status), attempt < 2 {
                    try await scheduler.postpone(seconds: pow(2, Double(attempt + 2)))
                    continue
                }
                guard response.status == 200 else { throw ArxivError.http(response.status) }
                let records = try ArxivAtomParser.parse(response.body)
                let requested = Set(identifiers.map(\.canonical))
                guard records.allSatisfy({ requested.contains($0.identifier.canonical) }) else { throw ArxivError.invalidFeed }
                return records
            } catch let error as URLError {
                if error.code == .cancelled { throw CancellationError() }
                guard attempt < 2, [.timedOut, .networkConnectionLost, .cannotConnectToHost, .dnsLookupFailed].contains(error.code) else { throw error }
                try await scheduler.postpone(seconds: pow(2, Double(attempt + 2)))
            }
        }
        throw ArxivError.invalidFeed
    }
}
