import Foundation

public struct PDFTransferReply: Sendable {
    public let status: Int
    public let retryAfter: TimeInterval?
    public init(status: Int = 200, retryAfter: TimeInterval? = nil) { self.status = status; self.retryAfter = retryAfter }
}

public protocol PDFTransport: Sendable {
    func transfer(url: URL, staged: URL, limits: PDFLimits, fileStore: PDFFileStore, progress: @escaping @Sendable (Int64, Int64?) async -> Void) async throws -> PDFTransferReply
}

private final class PDFRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var redirects: [Int: Int] = [:]
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        let count = lock.withLock { redirects[task.taskIdentifier, default: 0] += 1; return redirects[task.taskIdentifier, default: 0] }
        guard count <= 4, task.originalRequest?.url?.host != "arxiv.org", let url = request.url,
              url.host != "arxiv.org", PDFSourcePolicy.canDownload(url) else { completionHandler(nil); return }
        completionHandler(request)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        _ = lock.withLock { redirects.removeValue(forKey: task.taskIdentifier) }
    }
}

public final class PDFURLSessionTransport: PDFTransport {
    private let session: URLSession
    public convenience init() { self.init(configuration: .ephemeral) }
    init(configuration: URLSessionConfiguration) {
        configuration.httpMaximumConnectionsPerHost = 1
        configuration.httpShouldSetCookies = false; configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil; configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 30; configuration.timeoutIntervalForResource = 300
        session = URLSession(configuration: configuration, delegate: PDFRedirectGuard(), delegateQueue: nil)
    }
    deinit { session.invalidateAndCancel() }

    public func transfer(url: URL, staged: URL, limits: PDFLimits, fileStore: PDFFileStore, progress: @escaping @Sendable (Int64, Int64?) async -> Void) async throws -> PDFTransferReply {
        try PDFSourcePolicy.validateDownload(url)
        try await fileStore.validateStaged(staged)
        var request = URLRequest(url: url)
        request.setValue("PaperLibrary/0.3 (local.paperlibrary.app; personal PDF reader)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/pdf", forHTTPHeaderField: "Accept")
        let (bytes, response) = try await session.bytes(for: request)
        defer { bytes.task.cancel() }
        guard let http = response as? HTTPURLResponse, let finalURL = http.url, PDFSourcePolicy.canDownload(finalURL),
              (url.host != "arxiv.org" || finalURL == url), !(300...399).contains(http.statusCode) else { throw PDFLibraryError.invalidSource }
        let reply = PDFTransferReply(status: http.statusCode, retryAfter: ArxivNetworkPolicy.retryAfter(http.value(forHTTPHeaderField: "Retry-After")))
        guard http.statusCode == 200 else { return reply }
        let encoding = http.value(forHTTPHeaderField: "Content-Encoding")?.lowercased()
        let total: Int64? = (encoding == nil || encoding == "identity") && http.expectedContentLength > 0 ? http.expectedContentLength : nil
        guard total ?? 0 <= limits.maximumBytes else { throw PDFLibraryError.tooLarge }
        try await fileStore.checkSpace(required: total ?? min(limits.maximumBytes, 2_097_152), reserve: limits.reserveBytes)
        guard FileManager.default.createFile(atPath: staged.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw PDFLibraryError.unsafePath }
        let handle = try FileHandle(forWritingTo: staged)
        defer { try? handle.close() }
        var received: Int64 = 0
        var buffer = Data(); buffer.reserveCapacity(65_536)
        await progress(0, total)
        for try await byte in bytes {
            try Task.checkCancellation()
            guard received < limits.maximumBytes else { throw PDFLibraryError.tooLarge }
            buffer.append(byte); received += 1
            if buffer.count == 65_536 {
                try await fileStore.checkSpace(required: Int64(buffer.count), reserve: limits.reserveBytes)
                try handle.write(contentsOf: buffer); buffer.removeAll(keepingCapacity: true)
                await progress(received, total)
            }
        }
        if !buffer.isEmpty { try handle.write(contentsOf: buffer) }
        try handle.synchronize()
        guard total == nil || total == received else { throw PDFLibraryError.invalidFile }
        await progress(received, total)
        return reply
    }
}

public protocol PDFDownloading: Sendable {
    func download(url: URL, paperID: UUID, version: Int, jobID: UUID, limits: PDFLimits, progress: @escaping @Sendable (Int64, Int64?) async -> Void) async throws -> PDFFileReference
}

public actor PDFDownloader: PDFDownloading {
    private let files: PDFFileStore
    private let scheduler: ArxivRequestScheduler
    private let transport: any PDFTransport
    public init(files: PDFFileStore, scheduler: ArxivRequestScheduler, transport: any PDFTransport = PDFURLSessionTransport()) {
        self.files = files; self.scheduler = scheduler; self.transport = transport
    }
    public func download(url: URL, paperID: UUID, version: Int, jobID: UUID, limits: PDFLimits, progress: @escaping @Sendable (Int64, Int64?) async -> Void) async throws -> PDFFileReference {
        guard version > 0 else { throw PDFLibraryError.invalidSource }
        try PDFSourcePolicy.validateDownload(url, version: version)
        let staged = try await files.stagingURL(jobID: jobID)
        do {
            let transport = self.transport; let files = self.files
            let reply = try await scheduler.perform {
                let reply = try await transport.transfer(url: url, staged: staged, limits: limits, fileStore: files, progress: progress)
                return (reply, reply.retryAfter)
            }
            guard reply.status == 200 else { throw PDFLibraryError.http(reply.status) }
            try Task.checkCancellation()
            return try await files.install(staged: staged, paperID: paperID, version: version, limits: limits)
        } catch {
            try? await files.discard(staged: staged)
            throw error
        }
    }
}
