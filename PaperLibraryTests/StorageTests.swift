import Foundation
import SwiftData
import Testing
@testable import PaperLibraryCore
import PaperLibrarySupport

@Suite(.serialized)
@MainActor
struct StorageTests {
    private func temporaryConfiguration() throws -> StorageConfiguration {
        try .testing(at: FileManager.default.temporaryDirectory.appendingPathComponent("PaperLibraryTests-\(UUID().uuidString)", isDirectory: true))
    }

    @Test func librarySurvivesClosingAndReopening() throws {
        let configuration = try temporaryConfiguration()
        defer { try? FileManager.default.removeItem(at: configuration.root) }
        let id: UUID = try autoreleasepool {
            let repository = try LibraryRepository(store: LibraryStore.open(configuration: configuration))
            let course = try repository.addCourse(name: "Robotica")
            let paper = try repository.addPaper(PaperDraft(title: "Persistent paper", authors: ["First Author", "Second Author"]), courseIDs: [course.id])
            try repository.saveNotes(paperID: paper.id, notes: "Private notes αβ")
            try repository.setFavorite(true, paperIDs: [paper.id])
            try repository.setReadingStatus(.reading, paperIDs: [paper.id])
            return paper.id
        }
        try autoreleasepool {
            let store = try LibraryStore.open(configuration: configuration)
            let repository = try LibraryRepository(store: store)
            let paper = try #require(repository.paper(id: id))
            #expect(paper.notes == "Private notes αβ")
            #expect(paper.authors == ["First Author", "Second Author"])
            #expect(paper.readingStatus == .reading)
            #expect(paper.isFavorite)
            #expect(repository.memberships.count == 1)
            let backup = try #require(store.startupBackup)
            #expect(FileManager.default.fileExists(atPath: backup.appendingPathComponent("Store/Library.store").path))
        }
    }

    @Test func migrationPreservesOldSchemaDataAndCreatesBackup() throws {
        let configuration = try temporaryConfiguration()
        defer { try? FileManager.default.removeItem(at: configuration.root) }
        try FileManager.default.createDirectory(at: configuration.storeDirectory, withIntermediateDirectories: true)
        let ids: (UUID, UUID, UUID) = try autoreleasepool {
            let schema = Schema(versionedSchema: LibrarySchemaV1.self)
            let settings = ModelConfiguration("PaperLibrary", schema: schema, url: configuration.storeURL, cloudKitDatabase: .none)
            let container = try ModelContainer(for: schema, configurations: [settings])
            let context = ModelContext(container)
            context.autosaveEnabled = false
            let course = LibrarySchemaV1.Course(name: "Old course", courseDescription: "Keep description", sortOrder: 3)
            let paper = LibrarySchemaV1.Paper(title: "Old paper", authors: ["A", "B"], abstract: "Original abstract")
            paper.notes = "Never lose this annotation"
            paper.readingStatusRaw = "read"
            paper.isFavorite = true
            paper.provider = "arxiv"
            paper.providerIdentifier = "1706.03762"
            paper.identityKey = "arxiv:1706.03762"
            paper.requestedVersion = 2
            let link = LibrarySchemaV1.CoursePaper(courseID: course.id, paperID: paper.id, notes: "Course context", priority: 2)
            context.insert(course)
            context.insert(paper)
            context.insert(link)
            try context.save()
            return (course.id, paper.id, link.id)
        }
        try autoreleasepool {
            let store = try LibraryStore.open(configuration: configuration)
            let repository = try LibraryRepository(store: store)
            let paper = try #require(repository.paper(id: ids.1))
            #expect(paper.notes == "Never lose this annotation")
            #expect(paper.authors == ["A", "B"])
            #expect(paper.abstract == "Original abstract")
            #expect(paper.readingStatus == .read)
            #expect(paper.isFavorite)
            #expect(paper.requestedVersion == 2)
            #expect(paper.identityKey == "arxiv:1706.03762")
            #expect(paper.rating == nil)
            #expect(repository.course(id: ids.0)?.courseDescription == "Keep description")
            #expect(repository.memberships.first?.id == ids.2)
            #expect(repository.memberships.first?.notes == "Course context")
            #expect(repository.memberships.first?.priority == 2)
            #expect(store.startupBackup != nil)
            try repository.updateCourse(id: ids.0, name: "Old course", description: "Keep description", color: "purple")
            #expect(repository.course(id: ids.0)?.color == "purple")
        }
    }

    @Test func corruptStoreIsPreservedAndDoesNotCreateEmptyReplacement() throws {
        let configuration = try temporaryConfiguration()
        defer { try? FileManager.default.removeItem(at: configuration.root) }
        try FileManager.default.createDirectory(at: configuration.storeDirectory, withIntermediateDirectories: true)
        let sentinel = Data("invalid database that must be preserved".utf8)
        try sentinel.write(to: configuration.storeURL)
        do {
            _ = try LibraryStore.open(configuration: configuration)
            Issue.record("Corrupt database unexpectedly opened")
        } catch let failure as StoreStartupFailure {
            let backup = try #require(failure.backupURL)
            #expect(try Data(contentsOf: backup.appendingPathComponent("Store/Library.store")) == sentinel)
            #expect(try Data(contentsOf: configuration.storeURL) == sentinel)
        }
    }

    @Test func concurrentInstanceCannotCopyOrOpenLiveStore() throws {
        let configuration = try temporaryConfiguration()
        defer { try? FileManager.default.removeItem(at: configuration.root) }
        let first = try LibraryStore.open(configuration: configuration)
        defer { withExtendedLifetime(first) {} }
        #expect(throws: StoreStartupFailure.self) { try LibraryStore.open(configuration: configuration) }
        let backups = try FileManager.default.contentsOfDirectory(atPath: configuration.backupDirectory.path)
        #expect(backups.isEmpty)
    }

    @Test func orphanedWALDoesNotBecomeAnEmptyLibrary() throws {
        let configuration = try temporaryConfiguration()
        defer { try? FileManager.default.removeItem(at: configuration.root) }
        try FileManager.default.createDirectory(at: configuration.storeDirectory, withIntermediateDirectories: true)
        try Data("orphaned".utf8).write(to: configuration.storeDirectory.appendingPathComponent("Library.store-wal"))
        #expect(throws: StoreStartupFailure.self) { try LibraryStore.open(configuration: configuration) }
        #expect(!FileManager.default.fileExists(atPath: configuration.storeURL.path))
    }

    @Test func testsCannotSelectProductionOrArbitraryStorage() throws {
        #expect(throws: LibraryError.self) { try StorageConfiguration.testing(at: StorageConfiguration.production().root) }
        #expect(throws: LibraryError.self) { try StorageConfiguration.testing(at: URL(fileURLWithPath: "/Users/Shared/PaperLibrary")) }
        #expect(try StorageConfiguration.production().root != StorageConfiguration.demo().root)
        #expect(try StorageConfiguration.production().arxivCooldownURL == StorageConfiguration.demo().arxivCooldownURL)
        #expect(try StorageConfiguration.forLaunch(arguments: ["PaperLibrary", "--demo"]).mode == .demo)
    }
}
