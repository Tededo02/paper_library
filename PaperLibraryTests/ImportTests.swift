import Foundation
import SwiftData
import Testing
import PaperLibrarySupport
@testable import PaperLibraryCore

@Suite(.serialized)
@MainActor
struct ImportTests {
    private func configuration() throws -> StorageConfiguration {
        try .testing(at: FileManager.default.temporaryDirectory.appendingPathComponent("PaperLibraryImportTests-\(UUID().uuidString)"))
    }

    @Test func importedMetadataIsSavedAndDuplicateImportDoesNotFetchAgain() async throws {
        let config = try configuration()
        defer { try? FileManager.default.removeItem(at: config.root) }
        let repo = try LibraryRepository(store: LibraryStore.open(configuration: config))
        let first = try repo.addCourse(name: "First")
        let second = try repo.addCourse(name: "Second")
        let provider = FixtureArxivProvider()
        let queue = ImportCoordinator(repository: repo, provider: provider)
        try queue.enqueue(text: "1706.03762v1", destinationCourseID: first.id, assignExisting: true, refreshMetadata: false)
        await queue.waitUntilIdle()
        let paper = try #require(repo.papers.first)
        try repo.saveNotes(paperID: paper.id, notes: "Keep annotations")
        try repo.setFavorite(true, paperIDs: [paper.id])
        try repo.setReadingStatus(.read, paperIDs: [paper.id])
        try queue.enqueue(text: "https://arxiv.org/pdf/1706.03762v2.pdf", destinationCourseID: second.id, assignExisting: true, refreshMetadata: false)
        await queue.waitUntilIdle()
        #expect(await provider.calls.count == 1)
        #expect(repo.papers.count == 1)
        #expect(repo.courseIDs(paperID: paper.id) == [first.id, second.id])
        #expect(paper.notes == "Keep annotations" && paper.isFavorite && paper.readingStatus == .read)
        #expect(paper.requestedVersion == 1 && paper.resolvedVersion == 1)
        #expect(paper.journalReference == "Reported journal")
        #expect(paper.aiStatusRaw == "notRequested")
        #expect(repo.importJobs.allSatisfy { $0.state == .completed })
        let separateContext = ModelContext(repo.store.container)
        #expect(try separateContext.fetchCount(FetchDescriptor<Paper>()) == 1)
    }

    @Test func refreshPreservesManualMetadataEditsAndAllAnnotations() async throws {
        let config = try configuration()
        defer { try? FileManager.default.removeItem(at: config.root) }
        let repo = try LibraryRepository(store: LibraryStore.open(configuration: config))
        let provider = FixtureArxivProvider()
        let queue = ImportCoordinator(repository: repo, provider: provider)
        try queue.enqueue(text: "1706.03762v1", destinationCourseID: nil, assignExisting: true, refreshMetadata: false)
        await queue.waitUntilIdle()
        let paper = try #require(repo.papers.first)
        try repo.updateMetadata(paperID: paper.id, draft: PaperDraft(title: "User corrected title", authors: ["User corrected author"], abstract: "User corrected abstract", doi: "10.user/fix"))
        try repo.saveNotes(paperID: paper.id, notes: "Protected notes")
        try queue.enqueue(text: "1706.03762v2", destinationCourseID: nil, assignExisting: true, refreshMetadata: true)
        await queue.waitUntilIdle()
        #expect(repo.papers.count == 1 && paper.title == "User corrected title")
        #expect(paper.abstract == "User corrected abstract" && paper.doi == "10.user/fix")
        #expect(paper.notes == "Protected notes")
        #expect(paper.resolvedVersion == 2)
        #expect(repo.importJobs.last?.outcomeRaw == "refreshedProtected")
    }

    @Test func failedBatchRetainsExistingDataAndCanRetry() async throws {
        let config = try configuration()
        defer { try? FileManager.default.removeItem(at: config.root) }
        let repo = try LibraryRepository(store: LibraryStore.open(configuration: config))
        _ = try repo.addPaper(PaperDraft(title: "Offline paper"))
        let provider = FixtureArxivProvider()
        await provider.configure(failure: URLError(.notConnectedToInternet))
        let queue = ImportCoordinator(repository: repo, provider: provider)
        try queue.enqueue(text: "1706.03762 invalid https://evil.test/abs/1706.03762", destinationCourseID: nil, assignExisting: true, refreshMetadata: false)
        await queue.waitUntilIdle()
        #expect(repo.importJobs.count == 3 && repo.importJobs.allSatisfy { $0.state == .failed })
        #expect(repo.papers.count == 1)
        await provider.configure()
        try queue.retry(ids: Set(repo.importJobs.map(\.id)), destinationCourseID: nil, assignExisting: true, refreshMetadata: false)
        await queue.waitUntilIdle()
        #expect(repo.papers.count == 2)
        #expect(repo.importJobs.filter { $0.state == .completed }.count == 1)
        #expect(await provider.calls.count == 2)
    }

    @Test func cancellationLeavesCompletedPapersAndCancelsOutstandingBatch() async throws {
        let config = try configuration()
        defer { try? FileManager.default.removeItem(at: config.root) }
        let repo = try LibraryRepository(store: LibraryStore.open(configuration: config))
        let provider = FixtureArxivProvider()
        let queue = ImportCoordinator(repository: repo, provider: provider)
        try queue.enqueue(text: "1706.03762v1", destinationCourseID: nil, assignExisting: true, refreshMetadata: false)
        await queue.waitUntilIdle()
        await provider.configure(delay: true)
        let batch = try queue.enqueue(text: "1706.03763", destinationCourseID: nil, assignExisting: true, refreshMetadata: false)
        while await provider.calls.count < 2 { await Task.yield() }
        try queue.cancel(batchID: batch)
        await queue.waitUntilIdle()
        #expect(repo.papers.count == 1)
        #expect(repo.importJobs.last?.state == .cancelled)
        #expect(repo.importJobs.first?.state == .completed)
    }

    @Test func interruptedJobsSurviveReopenAndRequireExplicitRetry() throws {
        let config = try configuration()
        defer { try? FileManager.default.removeItem(at: config.root) }
        try autoreleasepool {
            let repo = try LibraryRepository(store: LibraryStore.open(configuration: config))
            try repo.enqueueImports(ImportInput.parse("1706.03762"), destinationCourseID: nil, assignExisting: true, refreshMetadata: false)
            try repo.beginImports(ids: repo.importJobs.map(\.id))
        }
        try autoreleasepool {
            let repo = try LibraryRepository(store: LibraryStore.open(configuration: config))
            #expect(repo.importJobs.first?.state == .interrupted)
            #expect(repo.importJobs.first?.attemptCount == 1)
            #expect(repo.papers.isEmpty)
        }
    }

    @Test func missingResultsAndWrongVersionsNeverCreatePapers() async throws {
        let config = try configuration()
        defer { try? FileManager.default.removeItem(at: config.root) }
        let repo = try LibraryRepository(store: LibraryStore.open(configuration: config))
        let provider = FixtureArxivProvider()
        await provider.configure(omitResults: true)
        let queue = ImportCoordinator(repository: repo, provider: provider)
        try queue.enqueue(text: "1706.03762v2", destinationCourseID: nil, assignExisting: true, refreshMetadata: false)
        await queue.waitUntilIdle()
        #expect(repo.importJobs.first?.state == .failed && repo.papers.isEmpty)
        try repo.retryImports(ids: Set(repo.importJobs.map(\.id)), destinationCourseID: nil, assignExisting: true, refreshMetadata: true)
        let id = try #require(repo.importJobs.first?.id)
        try repo.beginImports(ids: [id])
        #expect(throws: ArxivError.wrongVersion) { try repo.completeImport(id: id, metadata: ArxivFixtures.metadata(id: "1706.03762v1")) }
        #expect(repo.papers.isEmpty)
    }

    @Test func v2MigrationPreservesManualLibraryAndAllowsDurableJobs() throws {
        let config = try configuration()
        defer { try? FileManager.default.removeItem(at: config.root) }
        try FileManager.default.createDirectory(at: config.storeDirectory, withIntermediateDirectories: true)
        let id = try autoreleasepool {
            let schema = Schema(versionedSchema: LibrarySchemaV2.self)
            let settings = ModelConfiguration("PaperLibrary", schema: schema, url: config.storeURL, cloudKitDatabase: .none)
            let container = try ModelContainer(for: schema, configurations: [settings])
            let context = ModelContext(container)
            context.autosaveEnabled = false
            let course = LibrarySchemaV2.Course(name: "Existing V2 course", color: "purple")
            let paper = LibrarySchemaV2.Paper(title: "Existing V2 paper", authors: ["First", "Second"])
            paper.notes = "Long term annotation"; paper.rating = 5
            context.insert(course); context.insert(paper)
            context.insert(LibrarySchemaV2.CoursePaper(courseID: course.id, paperID: paper.id, notes: "Course context", priority: 2))
            try context.save()
            return paper.id
        }
        try autoreleasepool {
            let store = try LibraryStore.open(configuration: config)
            let repo = try LibraryRepository(store: store)
            let paper = try #require(repo.paper(id: id))
            #expect(paper.notes == "Long term annotation" && paper.rating == 5)
            #expect(paper.metadataUserEdited)
            #expect(repo.memberships.first?.notes == "Course context")
            #expect(repo.courses.first?.color == "purple")
            #expect(store.startupBackup != nil)
            try repo.enqueueImports(ImportInput.parse("1706.03762"), destinationCourseID: nil, assignExisting: true, refreshMetadata: false)
            #expect(repo.importJobs.count == 1)
        }
    }

    @Test func batchUsesTwentyIDRequests() async throws {
        let config = try configuration()
        defer { try? FileManager.default.removeItem(at: config.root) }
        let repo = try LibraryRepository(store: LibraryStore.open(configuration: config))
        let provider = FixtureArxivProvider()
        let queue = ImportCoordinator(repository: repo, provider: provider)
        let input = (1...23).map { "2501.\(String(format: "%05d", $0))" }.joined(separator: "\n")
        try queue.enqueue(text: input, destinationCourseID: nil, assignExisting: true, refreshMetadata: false)
        await queue.waitUntilIdle()
        #expect(await provider.calls.map(\.count) == [20, 3])
        #expect(repo.papers.count == 23)
        #expect(repo.importJobs.allSatisfy { $0.state == .completed })
    }

    @Test func cancelPreservesEarlierChunksAndLetsOtherBatchContinue() async throws {
        let config = try configuration()
        defer { try? FileManager.default.removeItem(at: config.root) }
        let repo = try LibraryRepository(store: LibraryStore.open(configuration: config))
        let provider = FixtureArxivProvider()
        await provider.configure(delayStartingAt: 2)
        let queue = ImportCoordinator(repository: repo, provider: provider)
        let input = (1...21).map { "2501.\(String(format: "%05d", $0))" }.joined(separator: " ")
        let first = try queue.enqueue(text: input, destinationCourseID: nil, assignExisting: true, refreshMetadata: false)
        let second = try queue.enqueue(text: "1706.03762v1", destinationCourseID: nil, assignExisting: true, refreshMetadata: false)
        while await provider.calls.count < 2 { await Task.yield() }
        #expect(repo.papers.count == 20)
        await provider.configure()
        try queue.cancel(batchID: first)
        await queue.waitUntilIdle()
        #expect(repo.papers.count == 21)
        #expect(repo.importJobs.filter { $0.batchID == first && $0.state == .completed }.count == 20)
        #expect(repo.importJobs.filter { $0.batchID == first && $0.state == .cancelled }.count == 1)
        #expect(repo.importJobs.first { $0.batchID == second }?.state == .completed)
    }

    @Test func failedRefreshAndOptOutOfAssignmentPreserveExistingRecord() async throws {
        let config = try configuration()
        defer { try? FileManager.default.removeItem(at: config.root) }
        let repo = try LibraryRepository(store: LibraryStore.open(configuration: config))
        let course = try repo.addCourse(name: "Course")
        let provider = FixtureArxivProvider()
        let queue = ImportCoordinator(repository: repo, provider: provider)
        try queue.enqueue(text: "1706.03762v1", destinationCourseID: nil, assignExisting: true, refreshMetadata: false)
        await queue.waitUntilIdle()
        let paper = try #require(repo.papers.first)
        try repo.saveNotes(paperID: paper.id, notes: "Keep notes")
        try queue.enqueue(text: "1706.03762v2", destinationCourseID: course.id, assignExisting: false, refreshMetadata: false)
        await queue.waitUntilIdle()
        #expect(repo.memberships.isEmpty)
        await provider.configure(failure: URLError(.notConnectedToInternet))
        try queue.enqueue(text: "1706.03762v2", destinationCourseID: nil, assignExisting: true, refreshMetadata: true)
        await queue.waitUntilIdle()
        #expect(repo.papers.count == 1 && paper.resolvedVersion == 1)
        #expect(paper.notes == "Keep notes" && paper.title == "Imported paper")
        #expect(repo.importJobs.last?.state == .failed)
    }

    @Test func terminationPersistsInterruptionBeforeCancellingTask() async throws {
        let config = try configuration()
        defer { try? FileManager.default.removeItem(at: config.root) }
        let repo = try LibraryRepository(store: LibraryStore.open(configuration: config))
        let provider = FixtureArxivProvider()
        await provider.configure(delay: true)
        let queue = ImportCoordinator(repository: repo, provider: provider)
        try queue.enqueue(text: "1706.03762", destinationCourseID: nil, assignExisting: true, refreshMetadata: false)
        while await provider.calls.isEmpty { await Task.yield() }
        try queue.prepareForTermination()
        await queue.waitUntilIdle()
        #expect(repo.importJobs.first?.state == .interrupted)
        let context = ModelContext(repo.store.container)
        #expect(try context.fetch(FetchDescriptor<ImportJob>()).first?.state == .interrupted)
        #expect(repo.papers.isEmpty)
    }
}
