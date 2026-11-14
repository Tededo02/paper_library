import Foundation

public struct StoreStartupFailure: LocalizedError {
    public let storeURL: URL
    public let backupURL: URL?
    public let reason: String

    public init(storeURL: URL, backupURL: URL?, reason: String) {
        self.storeURL = storeURL
        self.backupURL = backupURL
        self.reason = reason
    }

    public var errorDescription: String? {
        "\(Strings.text("error.startup"))\n\(reason)\n\(storeURL.path)"
    }
}

public struct StoreSnapshot: Codable, Sendable {
    public let formatVersion: Int
    public let createdAt: Date
    public let applicationSchema: String
    public let reason: String
}

public final class StoreFileAccess: Sendable {
    public let startupBackup: URL?
    private let lease: StoreLock

    public init(configuration: StorageConfiguration, applicationSchema: String) throws {
        let manager = FileManager.default
        try Self.prepareDirectory(configuration.root)
        lease = try StoreLock(root: configuration.root)
        try Self.prepareDirectory(configuration.storeDirectory)
        try Self.prepareDirectory(configuration.backupDirectory)
        try Self.prepareDirectory(configuration.pdfDirectory)
        let files = try manager.contentsOfDirectory(at: configuration.storeDirectory, includingPropertiesForKeys: [.isSymbolicLinkKey])
        guard try !files.contains(where: { try $0.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true }) else {
            throw LibraryError.unsafeStorage
        }
        let hasStore = manager.fileExists(atPath: configuration.storeURL.path)
        if !hasStore && !files.isEmpty { throw LibraryError.inconsistentStore }
        startupBackup = hasStore ? try Self.snapshot(configuration: configuration, applicationSchema: applicationSchema) : nil
    }

    private static func prepareDirectory(_ url: URL) throws {
        let manager = FileManager.default
        if manager.fileExists(atPath: url.path) {
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else { throw LibraryError.unsafeStorage }
        } else {
            try manager.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
    }

    private static func snapshot(configuration: StorageConfiguration, applicationSchema: String) throws -> URL {
        let manager = FileManager.default
        let id = UUID().uuidString
        let pending = configuration.backupDirectory.appendingPathComponent(".pending-\(id)", isDirectory: true)
        let destination = configuration.backupDirectory.appendingPathComponent("preflight-\(id)", isDirectory: true)
        try manager.createDirectory(at: pending, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            try manager.copyItem(at: configuration.storeDirectory, to: pending.appendingPathComponent("Store", isDirectory: true))
            let manifest = StoreSnapshot(formatVersion: 1, createdAt: Date(), applicationSchema: applicationSchema, reason: "Closed-store snapshot before opening or migration; source schema may be older.")
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(manifest).write(to: pending.appendingPathComponent("snapshot.json"), options: .atomic)
            try manager.moveItem(at: pending, to: destination)
            return destination
        } catch {
            try? manager.removeItem(at: pending)
            throw error
        }
    }
}
