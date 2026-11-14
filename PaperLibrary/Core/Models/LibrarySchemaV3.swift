import Foundation
import PaperLibrarySupport
import SwiftData

public enum LibrarySchemaV3: VersionedSchema {
    public static var versionIdentifier: Schema.Version { Schema.Version(3, 0, 0) }
    public static var models: [any PersistentModel.Type] { [Course.self, Paper.self, CoursePaper.self, ImportJob.self] }

    @Model
    public final class Course {
        @Attribute(.unique) public var id: UUID
        public var name: String
        public var courseDescription: String
        public var sortOrder: Int
        public var createdAt: Date
        public var updatedAt: Date
        public var color: String?

        public init(id: UUID = UUID(), name: String, courseDescription: String = "", sortOrder: Int = 0, color: String? = nil) {
            self.id = id
            self.name = name
            self.courseDescription = courseDescription
            self.sortOrder = sortOrder
            self.createdAt = Date()
            self.updatedAt = Date()
            self.color = color
        }
    }

    @Model
    public final class Paper {
        @Attribute(.unique) public var id: UUID
        @Attribute(.unique) public var identityKey: String
        public var provider: String
        public var providerIdentifier: String?
        public var canonicalURL: String?
        public var sourceURL: String?
        public var requestedVersion: Int?
        public var resolvedVersion: Int?
        public var title: String
        public var authors: [String]
        public var abstract: String
        public var doi: String?
        public var publicationDate: Date?
        public var sourceUpdatedAt: Date?
        public var categories: [String]
        public var pdfSourceURL: String?
        public var createdAt: Date
        public var updatedAt: Date
        public var readingStatusRaw: String
        public var isFavorite: Bool
        public var notes: String
        public var metadataStatusRaw: String
        public var aiStatusRaw: String
        public var rating: Int?
        public var journalReference: String?
        public var metadataUserEdited: Bool = true

        public init(id: UUID = UUID(), title: String, authors: [String] = [], abstract: String = "") {
            self.id = id
            self.identityKey = "manual:\(id.uuidString.lowercased())"
            self.provider = "manual"
            self.title = title
            self.authors = authors
            self.abstract = abstract
            self.categories = []
            self.createdAt = Date()
            self.updatedAt = Date()
            self.readingStatusRaw = ReadingStatus.toRead.rawValue
            self.isFavorite = false
            self.notes = ""
            self.metadataStatusRaw = "manual"
            self.aiStatusRaw = "notRequested"
        }
    }

    @Model
    public final class CoursePaper {
        @Attribute(.unique) public var id: UUID
        @Attribute(.unique) public var membershipKey: String
        public var courseID: UUID
        public var paperID: UUID
        public var addedAt: Date
        public var notes: String
        public var priority: Int?

        public init(id: UUID = UUID(), courseID: UUID, paperID: UUID, notes: String = "", priority: Int? = nil) {
            self.id = id
            self.membershipKey = "\(courseID.uuidString.lowercased()):\(paperID.uuidString.lowercased())"
            self.courseID = courseID
            self.paperID = paperID
            self.addedAt = Date()
            self.notes = notes
            self.priority = priority
        }
    }

    @Model
    public final class ImportJob {
        @Attribute(.unique) public var id: UUID
        public var batchID: UUID
        public var input: String
        public var canonicalIdentifier: String?
        public var requestedVersion: Int?
        public var destinationCourseID: UUID?
        public var assignExisting: Bool
        public var refreshMetadata: Bool
        public var paperID: UUID?
        public var stateRaw: String
        public var progress: Double
        public var outcomeRaw: String?
        public var errorMessage: String?
        public var attemptCount: Int
        public var createdAt: Date
        public var updatedAt: Date
        public var startedAt: Date?
        public var completedAt: Date?

        public init(batchID: UUID, input: String, canonicalIdentifier: String?, requestedVersion: Int?, destinationCourseID: UUID?, assignExisting: Bool, refreshMetadata: Bool) {
            self.id = UUID()
            self.batchID = batchID
            self.input = input
            self.canonicalIdentifier = canonicalIdentifier
            self.requestedVersion = requestedVersion
            self.destinationCourseID = destinationCourseID
            self.assignExisting = assignExisting
            self.refreshMetadata = refreshMetadata
            self.stateRaw = ImportJobState.pending.rawValue
            self.progress = 0
            self.attemptCount = 0
            self.createdAt = Date()
            self.updatedAt = Date()
        }
    }
}
