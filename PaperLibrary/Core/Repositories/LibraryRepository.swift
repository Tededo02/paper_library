import Foundation
import Observation
import PaperLibrarySupport
import SwiftData

public struct PaperDraft: Sendable {
    public var title: String
    public var authors: [String]
    public var abstract: String
    public var doi: String?

    public init(title: String = "", authors: [String] = [], abstract: String = "", doi: String? = nil) {
        self.title = title
        self.authors = authors
        self.abstract = abstract
        self.doi = doi
    }
}

@MainActor
@Observable
public final class LibraryRepository {
    public private(set) var papers: [Paper] = []
    public private(set) var courses: [Course] = []
    public private(set) var memberships: [CoursePaper] = []
    public private(set) var importJobs: [ImportJob] = []
    public private(set) var pdfRecords: [PDFDocumentRecord] = []
    public private(set) var pdfJobs: [PDFProcessingJob] = []
    public private(set) var aiJobs: [AIProcessingJob] = []
    public private(set) var profiles: [AnalysisProfile] = []
    public private(set) var topics: [Topic] = []
    public private(set) var paperTopics: [PaperTopic] = []
    public private(set) var analysisRevision = 0
    public let store: LibraryStore
    let context: ModelContext

    public init(store: LibraryStore) throws {
        self.store = store
        self.context = ModelContext(store.container)
        context.autosaveEnabled = false
        try reload()
        try validateReferences()
        try recoverInterruptedImports()
        try recoverPDFJobs()
        try seedAnalysisProfiles()
        try interruptAIJobs()
    }

    public func reload() throws {
        papers = try context.fetch(FetchDescriptor<Paper>(sortBy: [SortDescriptor(\Paper.createdAt, order: .reverse)]))
        courses = try context.fetch(FetchDescriptor<Course>(sortBy: [SortDescriptor(\Course.sortOrder), SortDescriptor(\Course.createdAt)]))
        memberships = try context.fetch(FetchDescriptor<CoursePaper>())
        importJobs = try context.fetch(FetchDescriptor<ImportJob>(sortBy: [SortDescriptor(\ImportJob.createdAt)]))
        pdfRecords = try context.fetch(FetchDescriptor<PDFDocumentRecord>())
        pdfJobs = try context.fetch(FetchDescriptor<PDFProcessingJob>(sortBy: [SortDescriptor(\PDFProcessingJob.createdAt)]))
        aiJobs = try context.fetch(FetchDescriptor<AIProcessingJob>(sortBy: [SortDescriptor(\AIProcessingJob.createdAt)]))
        profiles = try context.fetch(FetchDescriptor<AnalysisProfile>(sortBy: [SortDescriptor(\AnalysisProfile.sortOrder), SortDescriptor(\AnalysisProfile.name)]))
        topics = try context.fetch(FetchDescriptor<Topic>(sortBy: [SortDescriptor(\Topic.name)]))
        paperTopics = try context.fetch(FetchDescriptor<PaperTopic>())
        analysisRevision &+= 1
    }

    public func paper(id: UUID) -> Paper? { papers.first { $0.id == id } }
    public func course(id: UUID) -> Course? { courses.first { $0.id == id } }
    public func count(courseID: UUID) -> Int { memberships.filter { $0.courseID == courseID }.count }
    public func courseIDs(paperID: UUID) -> Set<UUID> {
        Set(memberships.filter { $0.paperID == paperID }.map(\.courseID))
    }

    @discardableResult
    public func addPaper(_ draft: PaperDraft, courseIDs: Set<UUID> = []) throws -> Paper {
        let title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw LibraryError.invalidInput }
        try validateCourses(courseIDs)
        return try commit {
            let paper = Paper(title: title, authors: cleanAuthors(draft.authors), abstract: draft.abstract)
            paper.doi = draft.doi?.nilIfBlank
            context.insert(paper)
            for id in courseIDs { context.insert(CoursePaper(courseID: id, paperID: paper.id)) }
            return paper
        }
    }

    public func updateMetadata(paperID: UUID, draft: PaperDraft) throws {
        guard let paper = paper(id: paperID) else { throw LibraryError.missingRecord }
        let title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw LibraryError.invalidInput }
        try commit {
            paper.title = title
            paper.authors = cleanAuthors(draft.authors)
            paper.abstract = draft.abstract
            paper.doi = draft.doi?.nilIfBlank
            paper.metadataUserEdited = true
            paper.updatedAt = Date()
        }
    }

    public func saveNotes(paperID: UUID, notes: String) throws {
        guard let paper = paper(id: paperID) else { throw LibraryError.missingRecord }
        try commit { paper.notes = notes; paper.updatedAt = Date() }
    }

    public func setReadingStatus(_ status: ReadingStatus, paperIDs: Set<UUID>) throws {
        let selected = try selectedPapers(paperIDs)
        try commit {
            for paper in selected { paper.readingStatusRaw = status.rawValue; paper.updatedAt = Date() }
        }
    }

    public func setFavorite(_ favorite: Bool, paperIDs: Set<UUID>) throws {
        let selected = try selectedPapers(paperIDs)
        try commit {
            for paper in selected { paper.isFavorite = favorite; paper.updatedAt = Date() }
        }
    }

    @discardableResult
    public func addCourse(name: String, description: String = "", color: String? = nil) throws -> Course {
        let trimmed = try validatedCourseName(name)
        return try commit {
            let course = Course(name: trimmed, courseDescription: description, sortOrder: (courses.map(\.sortOrder).max() ?? -1) + 1, color: color)
            context.insert(course)
            return course
        }
    }

    public func updateCourse(id: UUID, name: String, description: String, color: String?) throws {
        guard let course = course(id: id) else { throw LibraryError.missingRecord }
        let trimmed = try validatedCourseName(name, excluding: id)
        try commit {
            course.name = trimmed
            course.courseDescription = description
            course.color = color
            course.updatedAt = Date()
        }
    }

    public func moveCourse(id: UUID, offset: Int) throws {
        guard let index = courses.firstIndex(where: { $0.id == id }) else { throw LibraryError.missingRecord }
        let destination = index + offset
        guard courses.indices.contains(destination) else { return }
        var ordered = courses
        ordered.swapAt(index, destination)
        try commit {
            for (position, course) in ordered.enumerated() { course.sortOrder = position; course.updatedAt = Date() }
        }
    }

    public func deleteCourse(id: UUID) throws {
        guard let course = course(id: id) else { throw LibraryError.missingRecord }
        try commit {
            for link in memberships where link.courseID == id { context.delete(link) }
            context.delete(course)
        }
    }

    public func assign(paperIDs: Set<UUID>, to courseID: UUID) throws {
        _ = try selectedPapers(paperIDs)
        try validateCourses([courseID])
        let existing = Set(memberships.filter { $0.courseID == courseID }.map(\.paperID))
        try commit {
            for id in paperIDs.subtracting(existing) { context.insert(CoursePaper(courseID: courseID, paperID: id)) }
        }
    }

    public func remove(paperIDs: Set<UUID>, from courseID: UUID) throws {
        _ = try selectedPapers(paperIDs)
        try validateCourses([courseID])
        try commit {
            for link in memberships where link.courseID == courseID && paperIDs.contains(link.paperID) { context.delete(link) }
        }
    }

    public func setCourses(paperID: UUID, courseIDs: Set<UUID>) throws {
        guard paper(id: paperID) != nil else { throw LibraryError.missingRecord }
        try validateCourses(courseIDs)
        let current = self.courseIDs(paperID: paperID)
        try commit {
            for link in memberships where link.paperID == paperID && !courseIDs.contains(link.courseID) { context.delete(link) }
            for id in courseIDs.subtracting(current) { context.insert(CoursePaper(courseID: id, paperID: paperID)) }
        }
    }

    public func deletePapers(ids: Set<UUID>) throws {
        let selected = try selectedPapers(ids)
        let identities = Set(selected.compactMap(\.providerIdentifier))
        try commit {
            for record in pdfRecords where ids.contains(record.paperID) { record.isRemoved = true; try deletePDFText(recordID: record.id) }
            for id in ids { for analysis in try analyses(paperID: id, limit: nil) { context.delete(analysis) } }
            for link in paperTopics where ids.contains(link.paperID) { context.delete(link) }
            for job in aiJobs where ids.contains(job.paperID) && [.pending, .inProgress].contains(job.state) {
                job.stateRaw = ImportJobState.cancelled.rawValue; job.updatedAt = Date()
            }
            for job in pdfJobs where ids.contains(job.paperID) && [.pending, .inProgress].contains(job.state) {
                job.stateRaw = ImportJobState.cancelled.rawValue; job.updatedAt = Date()
            }
            for job in importJobs {
                if job.paperID.map(ids.contains) == true { job.paperID = nil }
                if job.canonicalIdentifier.map(identities.contains) == true && [.pending, .inProgress].contains(job.state) {
                    job.stateRaw = ImportJobState.cancelled.rawValue
                    job.updatedAt = Date()
                }
            }
            for link in memberships where ids.contains(link.paperID) { context.delete(link) }
            for paper in selected { context.delete(paper) }
        }
    }

    private func selectedPapers(_ ids: Set<UUID>) throws -> [Paper] {
        let selected = papers.filter { ids.contains($0.id) }
        guard selected.count == ids.count else { throw LibraryError.missingRecord }
        return selected
    }

    private func validatedCourseName(_ name: String, excluding id: UUID? = nil) throws -> String {
        let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw LibraryError.invalidInput }
        guard !courses.contains(where: { $0.id != id && $0.name.compare(value, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }) else {
            throw LibraryError.duplicateRecord
        }
        return value
    }

    func validateCourses(_ ids: Set<UUID>) throws {
        guard ids.isSubset(of: Set(courses.map(\.id))) else { throw LibraryError.missingRecord }
    }

    private func cleanAuthors(_ authors: [String]) -> [String] { authors.compactMap(\.nilIfBlank) }

    private func validateReferences() throws {
        let papers = Set(papers.map(\.id))
        let courses = Set(courses.map(\.id))
        guard memberships.allSatisfy({ papers.contains($0.paperID) && courses.contains($0.courseID) }) else {
            throw LibraryError.inconsistentStore
        }
    }

    func commit<T>(_ action: () throws -> T) throws -> T {
        do {
            let result = try action()
            try context.save()
            try reload()
            return result
        } catch {
            context.rollback()
            try? reload()
            throw error
        }
    }
}

extension String {
    fileprivate var nilIfBlank: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
