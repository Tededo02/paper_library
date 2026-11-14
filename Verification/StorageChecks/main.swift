import Foundation
import PaperLibrarySupport
import SQLite3

func runChild(_ arguments: [String]) throws -> Int32 {
    let child = Process()
    child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
    child.arguments = arguments
    try child.run()
    child.waitUntilExit()
    return child.terminationStatus
}

if CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--hold-wal-fixture" {
    let config = try StorageConfiguration.testing(at: URL(fileURLWithPath: CommandLine.arguments[2]))
    try FileManager.default.createDirectory(at: config.storeDirectory, withIntermediateDirectories: true)
    var database: OpaquePointer?
    guard sqlite3_open(config.storeURL.path, &database) == SQLITE_OK else { exit(1) }
    guard sqlite3_exec(database, "PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0; CREATE TABLE notes(body TEXT); INSERT INTO notes VALUES('Durable annotation');", nil, nil, nil) == SQLITE_OK else { exit(2) }
    _exit(0)
}

if CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--expect-locked" {
    let config = try StorageConfiguration.testing(at: URL(fileURLWithPath: CommandLine.arguments[2]))
    do { _ = try StoreFileAccess(configuration: config, applicationSchema: "2.0.0"); exit(3) }
    catch LibraryError.storeAlreadyOpen { exit(0) }
    catch { exit(4) }
}

enum VerificationFailure: Error { case failed(String) }

func check(_ condition: @autoclosure () throws -> Bool, _ name: String) throws {
    guard try condition() else { throw VerificationFailure.failed(name) }
    print("PASS: \(name)")
}

func expectRejection(_ name: String, _ work: () throws -> Void) throws {
    do { try work() }
    catch { print("PASS: \(name)"); return }
    throw VerificationFailure.failed(name)
}

let manager = FileManager.default
let root = manager.temporaryDirectory.appendingPathComponent("PaperLibrarySafety-\(UUID().uuidString)", isDirectory: true)
let configuration = try StorageConfiguration.testing(at: root)
defer { try? manager.removeItem(at: root) }

try check(StorageConfiguration.production().root != StorageConfiguration.demo().root, "Production and demo have separate stable locations")
try check(StorageConfiguration.production().storeURL == StorageConfiguration.production().storeURL, "Production database path is deterministic")
try check(StorageConfiguration.forLaunch(arguments: ["PaperLibrary", "--demo"]).mode == .demo, "Demo requires an explicit launch argument")
try check(StorageConfiguration.forLaunch(arguments: ["PaperLibrary"]).mode == .production, "Build configuration does not change the default library")
try expectRejection("Tests cannot target production") { _ = try StorageConfiguration.testing(at: StorageConfiguration.production().root) }
try expectRejection("Tests cannot target the temporary-directory root") { _ = try StorageConfiguration.testing(at: manager.temporaryDirectory) }

do {
    let access = try StoreFileAccess(configuration: configuration, applicationSchema: "2.0.0")
    try check(access.startupBackup == nil, "First launch does not pretend a backup exists")
    try expectRejection("Second instance is rejected before copying a live store") {
        _ = try StoreFileAccess(configuration: configuration, applicationSchema: "2.0.0")
    }
    try check(manager.contentsOfDirectory(atPath: configuration.backupDirectory.path).isEmpty, "A rejected instance creates no snapshot")
    try check(runChild(["--expect-locked", configuration.root.path]) == 0, "The store lock also excludes a separate process")
    withExtendedLifetime(access) {}
}

let fixture = ["Library.store": "database fixture", "Library.store-wal": "uncheckpointed fixture", "Library.store-shm": "shared memory fixture"]
for (name, value) in fixture { try Data(value.utf8).write(to: configuration.storeDirectory.appendingPathComponent(name)) }

do {
    let access = try StoreFileAccess(configuration: configuration, applicationSchema: "2.0.0")
    guard let backup = access.startupBackup else { throw VerificationFailure.failed("Snapshot is missing") }
    for (name, value) in fixture {
        try check(Data(contentsOf: backup.appendingPathComponent("Store/\(name)")) == Data(value.utf8), "Closed-store snapshot retains \(name) exactly")
        try check(Data(contentsOf: configuration.storeDirectory.appendingPathComponent(name)) == Data(value.utf8), "Snapshot does not modify \(name)")
    }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let manifest = try decoder.decode(StoreSnapshot.self, from: Data(contentsOf: backup.appendingPathComponent("snapshot.json")))
    try check(manifest.formatVersion == 1 && manifest.applicationSchema == "2.0.0", "Snapshot has a readable versioned manifest")
    try check(!manager.contentsOfDirectory(atPath: configuration.backupDirectory.path).contains(where: { $0.hasPrefix(".pending-") }), "Successful snapshots are atomically published")
    withExtendedLifetime(access) {}
}

let orphan = try StorageConfiguration.testing(at: root.appendingPathComponent("orphan"))
try manager.createDirectory(at: orphan.storeDirectory, withIntermediateDirectories: true)
try Data("orphaned WAL".utf8).write(to: orphan.storeDirectory.appendingPathComponent("Library.store-wal"))
try expectRejection("Orphaned WAL does not become a new empty database") { _ = try StoreFileAccess(configuration: orphan, applicationSchema: "2.0.0") }

let symlink = try StorageConfiguration.testing(at: root.appendingPathComponent("unsafe"))
try manager.createDirectory(at: symlink.root, withIntermediateDirectories: true)
try manager.createSymbolicLink(at: symlink.storeDirectory, withDestinationURL: configuration.storeDirectory)
try expectRejection("A symlinked store directory is rejected") { _ = try StoreFileAccess(configuration: symlink, applicationSchema: "2.0.0") }
try check(Strings.text("sidebar.all") == "All Papers", "English localization resources are loaded")

let walConfiguration = try StorageConfiguration.testing(at: root.appendingPathComponent("real-sqlite"))
try check(runChild(["--hold-wal-fixture", walConfiguration.root.path]) == 0, "An exited writer leaves a real SQLite WAL fixture")
try check(manager.fileExists(atPath: walConfiguration.storeURL.path + "-wal"), "Uncheckpointed SQLite WAL exists before the snapshot")
do {
    let access = try StoreFileAccess(configuration: walConfiguration, applicationSchema: "2.0.0")
    guard let backup = access.startupBackup else { throw VerificationFailure.failed("SQLite snapshot missing") }
    var database: OpaquePointer?
    let path = backup.appendingPathComponent("Store/Library.store").path
    guard sqlite3_open_v2(path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { throw VerificationFailure.failed("SQLite backup is unreadable") }
    defer { sqlite3_close(database) }
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, "SELECT body FROM notes", -1, &statement, nil) == SQLITE_OK else { throw VerificationFailure.failed("SQLite WAL was not recovered") }
    defer { sqlite3_finalize(statement) }
    try check(sqlite3_step(statement) == SQLITE_ROW, "Snapshot recovers a committed row from an uncheckpointed WAL")
    let body = String(cString: sqlite3_column_text(statement, 0))
    try check(body == "Durable annotation", "Restored SQLite row retains its exact content")
    withExtendedLifetime(access) {}
}
print("Storage safety verification completed; no production database was opened.")
