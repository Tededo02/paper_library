import Foundation

public struct StorageConfiguration: Sendable {
    public enum Mode: String, Sendable { case production, demo, test }
    public static let bundleIdentifier = "local.paperlibrary.app"
    public let mode: Mode
    public let root: URL
    public var storeDirectory: URL { root.appendingPathComponent("Store", isDirectory: true) }
    public var storeURL: URL { storeDirectory.appendingPathComponent("Library.store") }
    public var pdfDirectory: URL { root.appendingPathComponent("PDFs", isDirectory: true) }
    public var backupDirectory: URL { root.appendingPathComponent("Backups", isDirectory: true) }
    public var arxivCooldownURL: URL {
        if mode == .test { return root.appendingPathComponent("arxiv-cooldown.json") }
        return root.deletingLastPathComponent().appendingPathComponent("\(Self.bundleIdentifier).network", isDirectory: true).appendingPathComponent("arxiv-cooldown.json")
    }

    public static func production() throws -> Self {
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
        return Self(mode: .production, root: support.appendingPathComponent(bundleIdentifier, isDirectory: true))
    }

    public static func demo() throws -> Self {
        let production = try production()
        return Self(mode: .demo, root: production.root.deletingLastPathComponent().appendingPathComponent("\(bundleIdentifier).demo", isDirectory: true))
    }

    public static func testing(at root: URL) throws -> Self {
        let candidate = root.standardizedFileURL.resolvingSymlinksInPath()
        let temporary = FileManager.default.temporaryDirectory.standardizedFileURL.resolvingSymlinksInPath()
        guard candidate.path.hasPrefix(temporary.path + "/"), candidate != temporary else {
            throw LibraryError.unsafeStorage
        }
        return Self(mode: .test, root: candidate)
    }

    private init(mode: Mode, root: URL) {
        self.mode = mode
        self.root = root.standardizedFileURL
    }

    public static func forLaunch(arguments: [String] = ProcessInfo.processInfo.arguments) throws -> Self {
        if arguments.contains("--demo") { return try .demo() }
        return try .production()
    }
}
