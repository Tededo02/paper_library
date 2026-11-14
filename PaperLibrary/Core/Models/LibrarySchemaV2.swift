import Foundation
import PaperLibrarySupport
import SwiftData

public enum LibrarySchemaV2: VersionedSchema {
    public static var versionIdentifier: Schema.Version { Schema.Version(2, 0, 0) }
    public static var models: [any PersistentModel.Type] { [Course.self, Paper.self, CoursePaper.self] }

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
}

