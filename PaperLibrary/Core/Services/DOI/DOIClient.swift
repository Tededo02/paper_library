import Foundation

public protocol DOIMetadataProviding: Sendable {
    func fetch(_ identifier: DOIIdentifier) async throws -> DOIMetadata
}

public enum DOINetworkPolicy {
    public static let maximumResponseBytes = 2_097_152

    public static func endpoint(for identifier: DOIIdentifier, datacite: Bool = false) -> URL {
        let encoded = identifier.canonical.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
        return URL(string: "https://\(datacite ? "api.datacite.org/dois" : "api.crossref.org/works")/\(encoded)")!
    }

    public static func enrichmentEndpoint(for identifier: DOIIdentifier) -> URL {
        let encoded = identifier.canonical.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
        return URL(string: "https://api.openalex.org/works/https://doi.org/\(encoded)")!
    }

    public static func validate(_ url: URL) throws {
        if let parts = URLComponents(url: url, resolvingAgainstBaseURL: false), parts.host == "api.openalex.org" {
            let prefix = "/works/https://doi.org/"
            guard parts.path.hasPrefix(prefix), let id = try? DOIIdentifier(String(parts.path.dropFirst(prefix.count))),
                  enrichmentEndpoint(for: id) == url else { throw DOIError.invalidIdentifier }
            return
        }
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false), parts.scheme == "https",
              parts.user == nil, parts.password == nil, parts.port == nil, parts.query == nil, parts.fragment == nil,
              let prefix = ["api.crossref.org": "/works/", "api.datacite.org": "/dois/"][parts.host ?? ""],
              parts.path.hasPrefix(prefix), let id = try? DOIIdentifier(String(parts.path.dropFirst(prefix.count))),
              endpoint(for: id, datacite: parts.host == "api.datacite.org") == url else { throw DOIError.invalidIdentifier }
    }
}

public struct DOIHTTPResponse: Sendable {
    public let status: Int
    public let headers: [String: String]
    public let body: Data
    public let url: URL
    public init(status: Int, headers: [String: String] = [:], body: Data, url: URL) {
        self.status = status; self.headers = headers; self.body = body; self.url = url
    }
}

public protocol DOITransport: Sendable { func send(_ request: URLRequest) async throws -> DOIHTTPResponse }

private final class DOIRejectRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

public final class DOIURLSessionTransport: DOITransport {
    private let session: URLSession
    public convenience init() { self.init(configuration: .ephemeral) }
    init(configuration: URLSessionConfiguration) {
        configuration.httpMaximumConnectionsPerHost = 1
        configuration.httpShouldSetCookies = false; configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil; configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30; configuration.timeoutIntervalForResource = 60
        session = URLSession(configuration: configuration, delegate: DOIRejectRedirects(), delegateQueue: nil)
    }
    deinit { session.invalidateAndCancel() }

    public func send(_ request: URLRequest) async throws -> DOIHTTPResponse {
        guard let url = request.url else { throw DOIError.invalidIdentifier }
        try DOINetworkPolicy.validate(url)
        let (bytes, response) = try await session.bytes(for: request)
        defer { bytes.task.cancel() }
        guard let http = response as? HTTPURLResponse, http.url == url, !(300...399).contains(http.statusCode) else { throw DOIError.redirectRejected }
        guard http.expectedContentLength <= DOINetworkPolicy.maximumResponseBytes else { throw DOIError.responseTooLarge }
        var data = Data()
        for try await byte in bytes {
            guard data.count < DOINetworkPolicy.maximumResponseBytes else { throw DOIError.responseTooLarge }
            data.append(byte)
        }
        let headers = http.allHeaderFields.reduce(into: [String: String]()) { result, pair in
            if let name = pair.key as? String { result[name.lowercased()] = String(describing: pair.value) }
        }
        return DOIHTTPResponse(status: http.statusCode, headers: headers, body: data, url: url)
    }
}

public actor DOIClient: DOIMetadataProviding {
    private let transport: any DOITransport
    private let clock: any ArxivClock
    private var nextRequest: TimeInterval = 0
    private let enrichmentEnabled: Bool

    public init(transport: any DOITransport = DOIURLSessionTransport(), clock: any ArxivClock = SystemArxivClock(), enrichmentEnabled: Bool = true) {
        self.transport = transport; self.clock = clock; self.enrichmentEnabled = enrichmentEnabled
    }

    public func fetch(_ identifier: DOIIdentifier) async throws -> DOIMetadata {
        let crossref = try await request(DOINetworkPolicy.endpoint(for: identifier))
        let metadata: DOIMetadata
        if crossref.status == 404 {
            let datacite = try await request(DOINetworkPolicy.endpoint(for: identifier, datacite: true))
            guard datacite.status != 404 else { throw DOIError.notFound }
            guard datacite.status == 200 else { throw DOIError.http(datacite.status) }
            metadata = try DOIMetadataParser.datacite(datacite.body, requested: identifier)
        } else {
            guard crossref.status == 200 else { throw DOIError.http(crossref.status) }
            metadata = try DOIMetadataParser.crossref(crossref.body, requested: identifier)
        }
        guard enrichmentEnabled else { return metadata }
        do {
            let response = try await request(DOINetworkPolicy.enrichmentEndpoint(for: identifier))
            guard response.status == 200 else { return metadata }
            return try metadata.enriched(with: OpenAlexParser.parse(response.body, requested: identifier))
        } catch is CancellationError { throw CancellationError() }
        catch { return metadata }
    }

    private func request(_ url: URL) async throws -> DOIHTTPResponse {
        var request = URLRequest(url: url)
        request.setValue("PaperLibrary/0.4 (local.paperlibrary.app; personal macOS research library)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for attempt in 0..<3 {
            try Task.checkCancellation()
            let delay = nextRequest - (await clock.now())
            guard delay <= 60 else { throw DOIError.cooldown }
            if delay > 0 { try await clock.sleep(seconds: delay) }
            try Task.checkCancellation()
            nextRequest = await clock.now() + 1
            do {
                let response = try await transport.send(request)
                guard response.url == url else { throw DOIError.redirectRejected }
                if let retry = ArxivNetworkPolicy.retryAfter(response.headers["retry-after"]) {
                    nextRequest = max(nextRequest, await clock.now() + min(86_400, max(0, retry)))
                }
                if [408, 429, 500, 502, 503, 504].contains(response.status), attempt < 2 {
                    nextRequest = max(nextRequest, await clock.now() + pow(2, Double(attempt + 1)))
                    continue
                }
                return response
            } catch let error as URLError {
                if error.code == .cancelled { throw CancellationError() }
                guard attempt < 2, [.timedOut, .networkConnectionLost, .cannotConnectToHost, .dnsLookupFailed].contains(error.code) else { throw error }
                nextRequest = max(nextRequest, await clock.now() + pow(2, Double(attempt + 1)))
            }
        }
        throw DOIError.invalidResponse
    }
}
