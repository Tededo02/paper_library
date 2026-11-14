import Foundation
import Testing
@testable import PaperLibraryCore
import PaperLibrarySupport

@Suite(.serialized)
@MainActor
struct RepositoryTests {
    private func withRepository(_ work: (LibraryRepository) throws -> Void) throws {
        let configuration = try StorageConfiguration.testing(at: FileManager.default.temporaryDirectory.appendingPathComponent("PaperLibraryRepo-\(UUID().uuidString)"))
        defer { try? FileManager.default.removeItem(at: configuration.root) }
        try autoreleasepool { try work(LibraryRepository(store: LibraryStore.open(configuration: configuration))) }
    }

    @Test func deletingCoursePreservesGlobalPaperAndOtherCourseContext() throws {
        try withRepository { repository in
            let first = try repository.addCourse(name: "First")
            let second = try repository.addCourse(name: "Second")
            let paper = try repository.addPaper(PaperDraft(title: "Shared paper"), courseIDs: [first.id, second.id])
            try repository.saveNotes(paperID: paper.id, notes: "Keep me")
            try repository.deleteCourse(id: first.id)
            #expect(repository.papers.count == 1)
            #expect(repository.paper(id: paper.id)?.notes == "Keep me")
            #expect(repository.courseIDs(paperID: paper.id) == [second.id])
            try repository.remove(paperIDs: [paper.id], from: second.id)
            #expect(repository.papers.count == 1)
            #expect(repository.memberships.isEmpty)
        }
    }

    @Test func assignmentIsIdempotentAndRejectsInvalidReferencesAtomically() throws {
        try withRepository { repository in
            let course = try repository.addCourse(name: "Course")
            let paper = try repository.addPaper(PaperDraft(title: "Paper"))
            try repository.assign(paperIDs: [paper.id], to: course.id)
            try repository.assign(paperIDs: [paper.id], to: course.id)
            #expect(repository.memberships.count == 1)
            #expect(throws: LibraryError.self) { try repository.setCourses(paperID: paper.id, courseIDs: [UUID()]) }
            #expect(repository.courseIDs(paperID: paper.id) == [course.id])
            #expect(throws: LibraryError.self) { try repository.addPaper(PaperDraft(title: "Rejected"), courseIDs: [UUID()]) }
            #expect(repository.papers.count == 1)
        }
    }

    @Test func metadataEditsPreserveNotesFavoriteAndReadingState() throws {
        try withRepository { repository in
            let paper = try repository.addPaper(PaperDraft(title: "Original"))
            try repository.saveNotes(paperID: paper.id, notes: "User annotation")
            try repository.setReadingStatus(.read, paperIDs: [paper.id])
            try repository.setFavorite(true, paperIDs: [paper.id])
            try repository.updateMetadata(paperID: paper.id, draft: PaperDraft(title: "Updated", authors: [" Author ", ""], abstract: "New source"))
            #expect(paper.notes == "User annotation")
            #expect(paper.readingStatus == .read)
            #expect(paper.isFavorite)
            #expect(paper.authors == ["Author"])
            #expect(throws: LibraryError.self) { try repository.updateMetadata(paperID: paper.id, draft: PaperDraft(title: "  ")) }
            #expect(paper.title == "Updated")
        }
    }

    @Test func paperDeletionRemovesAllMembershipsAndKeepsCourses() throws {
        try withRepository { repository in
            let a = try repository.addCourse(name: "A")
            let b = try repository.addCourse(name: "B")
            let paper = try repository.addPaper(PaperDraft(title: "Delete"), courseIDs: [a.id, b.id])
            try repository.deletePapers(ids: [paper.id])
            #expect(repository.papers.isEmpty)
            #expect(repository.memberships.isEmpty)
            #expect(repository.courses.count == 2)
        }
    }

    @Test func courseOrderingAndDuplicateValidation() throws {
        try withRepository { repository in
            let a = try repository.addCourse(name: "A")
            let b = try repository.addCourse(name: "B")
            #expect(throws: LibraryError.self) { try repository.addCourse(name: " a ") }
            try repository.moveCourse(id: b.id, offset: -1)
            #expect(repository.courses.map(\.id) == [b.id, a.id])
            try repository.updateCourse(id: a.id, name: "Alpha", description: "Description", color: "green")
            #expect(a.courseDescription == "Description")
            #expect(a.color == "green")
        }
    }
}
