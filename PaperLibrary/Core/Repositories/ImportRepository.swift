import Foundation
import PaperLibrarySupport

extension LibraryRepository {
    public func importJob(id: UUID) -> ImportJob? { importJobs.first { $0.id == id } }
    public func existingPaper(for identifier: ArxivIdentifier) -> Paper? {
        papers.first { $0.identityKey == "arxiv:\(identifier.canonical)" }
    }
    public func existingPaper(for identifier: ImportIdentifier) -> Paper? {
        if let exact = papers.first(where: { $0.identityKey == identifier.identityKey }) { return exact }
        guard let doi = identifier.doiIdentifier else { return nil }
        return papers.first { $0.doi.flatMap { try? DOIIdentifier($0) } == doi }
    }

    @discardableResult
    public func enqueueImports(_ inputs: [ImportInput], destinationCourseID: UUID?, assignExisting: Bool, refreshMetadata: Bool) throws -> UUID {
        guard !inputs.isEmpty, inputs.count <= 500 else { throw ArxivError.invalidIdentifier }
        try validateCourses(Set(destinationCourseID.map { [$0] } ?? []))
        let batchID = UUID()
        try commit {
            for input in inputs {
                let job = ImportJob(batchID: batchID, input: input.raw, canonicalIdentifier: input.identifier?.canonical,
                    requestedVersion: input.identifier?.version, destinationCourseID: destinationCourseID,
                    assignExisting: assignExisting, refreshMetadata: refreshMetadata)
                if let error = input.error {
                    job.stateRaw = ImportJobState.failed.rawValue; job.errorMessage = error; job.completedAt = Date()
                }
                context.insert(job)
            }
        }
        return batchID
    }

    func beginImports(ids: [UUID]) throws {
        try commit {
            for id in ids {
                guard let job = importJob(id: id), job.state == .pending else { continue }
                job.stateRaw = ImportJobState.inProgress.rawValue
                job.startedAt = Date(); job.updatedAt = Date(); job.completedAt = nil
                job.attemptCount += 1; job.progress = 0.1; job.errorMessage = nil
            }
        }
    }

    @discardableResult
    func completeExistingImport(id: UUID) throws -> Bool {
        guard let job = importJob(id: id), job.state == .inProgress, !job.refreshMetadata,
              let identifier = job.identifier, let existing = existingPaper(for: identifier) else { return false }
        try commit {
            try assignImportedPaper(existing, job: job, isNew: false)
            complete(job, paper: existing, outcome: "existing")
        }
        return true
    }

    func completeImport(id: UUID, metadata: ArxivMetadata) throws {
        guard let job = importJob(id: id), job.state == .inProgress else { return }
        guard let requested = job.identifier?.arxivIdentifier, metadata.identifier.canonical == requested.canonical else { throw ArxivError.invalidFeed }
        guard requested.version == nil || requested.version == metadata.identifier.version else { throw ArxivError.wrongVersion }
        try commit {
            let doiMatch = metadata.doi.flatMap { try? DOIIdentifier($0) }.flatMap { existingPaper(for: .doi($0)) }
            let existing = existingPaper(for: requested) ?? doiMatch.flatMap { $0.provider == "arxiv" ? nil : $0 }
            let paper = existing ?? Paper(title: metadata.title, authors: metadata.authors, abstract: metadata.abstract)
            let isNew = existing == nil
            if isNew { context.insert(paper); paper.metadataUserEdited = false }
            if isNew || job.refreshMetadata {
                if !paper.metadataUserEdited {
                    paper.title = metadata.title; paper.authors = metadata.authors; paper.abstract = metadata.abstract
                    paper.doi = metadata.doi; paper.journalReference = metadata.journalReference
                }
                paper.provider = "arxiv"; paper.providerIdentifier = requested.canonical
                paper.identityKey = "arxiv:\(requested.canonical)"
                paper.canonicalURL = requested.canonicalURL.absoluteString; paper.sourceURL = job.input
                paper.requestedVersion = requested.version; paper.resolvedVersion = metadata.identifier.version
                paper.publicationDate = metadata.publishedAt; paper.sourceUpdatedAt = metadata.updatedAt
                paper.categories = metadata.categories
                paper.pdfSourceURL = metadata.hasPDF ? metadata.identifier.pdfURL.absoluteString : nil
                paper.metadataStatusRaw = "fetched"; paper.updatedAt = Date()
            }
            try assignImportedPaper(paper, job: job, isNew: isNew)
            let outcome = isNew ? "imported" : (job.refreshMetadata ? (paper.metadataUserEdited ? "refreshedProtected" : "refreshed") : "existing")
            complete(job, paper: paper, outcome: outcome)
        }
    }

    func completeImport(id: UUID, metadata: DOIMetadata) throws {
        guard let job = importJob(id: id), job.state == .inProgress else { return }
        guard let requested = job.identifier?.doiIdentifier, metadata.identifier == requested else { throw DOIError.invalidResponse }
        try commit {
            let existing = existingPaper(for: .doi(requested))
            let paper = existing ?? Paper(title: metadata.title, authors: metadata.authors, abstract: metadata.abstract)
            let isNew = existing == nil
            if isNew { context.insert(paper); paper.metadataUserEdited = false }
            if isNew || job.refreshMetadata {
                if !paper.metadataUserEdited {
                    paper.title = metadata.title
                    if !metadata.authors.isEmpty { paper.authors = metadata.authors }
                    if !metadata.abstract.isEmpty { paper.abstract = metadata.abstract }
                    paper.doi = requested.canonical
                    if let journal = metadata.journalReference { paper.journalReference = journal }
                }
                if isNew || paper.provider == "doi" {
                    paper.provider = "doi"; paper.providerIdentifier = requested.canonical
                    paper.identityKey = "doi:\(requested.canonical)"
                    paper.canonicalURL = requested.canonicalURL.absoluteString; paper.sourceURL = job.input
                    if let date = metadata.publishedAt { paper.publicationDate = date }
                    if !metadata.categories.isEmpty { paper.categories = metadata.categories }
                    paper.metadataStatusRaw = "fetched"
                }
                paper.updatedAt = Date()
            }
            try assignImportedPaper(paper, job: job, isNew: isNew)
            let outcome = isNew ? "imported" : (job.refreshMetadata ? (paper.metadataUserEdited ? "refreshedProtected" : "refreshed") : "existing")
            complete(job, paper: paper, outcome: outcome)
        }
    }

    func failImport(id: UUID, error: any Error) throws {
        guard let job = importJob(id: id), [.inProgress, .pending].contains(job.state) else { return }
        try commit {
            job.stateRaw = ImportJobState.failed.rawValue
            job.errorMessage = error.localizedDescription
            job.updatedAt = Date(); job.completedAt = Date()
        }
    }

    public func cancelImports(batchID: UUID) throws {
        try commit {
            for job in importJobs where job.batchID == batchID && [.pending, .inProgress].contains(job.state) {
                job.stateRaw = ImportJobState.cancelled.rawValue
                job.updatedAt = Date(); job.completedAt = Date()
            }
        }
    }

    public func retryImports(ids: Set<UUID>, destinationCourseID: UUID?, assignExisting: Bool, refreshMetadata: Bool) throws {
        try validateCourses(Set(destinationCourseID.map { [$0] } ?? []))
        try commit {
            for id in ids {
                guard let job = importJob(id: id), job.state.canRetry, job.identifier != nil else { continue }
                job.stateRaw = ImportJobState.pending.rawValue; job.progress = 0
                job.errorMessage = nil; job.completedAt = nil; job.updatedAt = Date()
                job.destinationCourseID = destinationCourseID
                job.assignExisting = assignExisting; job.refreshMetadata = refreshMetadata
            }
        }
    }

    func recoverInterruptedImports() throws {
        guard importJobs.contains(where: { [.pending, .inProgress].contains($0.state) }) else { return }
        try interruptImports(includePending: true)
    }

    func interruptImports(includePending: Bool) throws {
        try commit {
            for job in importJobs where job.state == .inProgress || (includePending && job.state == .pending) {
                job.stateRaw = ImportJobState.interrupted.rawValue
                job.errorMessage = Strings.text("import.interruptedHelp"); job.updatedAt = Date()
            }
        }
    }

    private func assignImportedPaper(_ paper: Paper, job: ImportJob, isNew: Bool) throws {
        guard let id = job.destinationCourseID, isNew || job.assignExisting else { return }
        try validateCourses([id])
        if !memberships.contains(where: { $0.courseID == id && $0.paperID == paper.id }) {
            context.insert(CoursePaper(courseID: id, paperID: paper.id))
        }
    }

    private func complete(_ job: ImportJob, paper: Paper, outcome: String) {
        job.paperID = paper.id; job.outcomeRaw = outcome
        job.stateRaw = ImportJobState.completed.rawValue; job.progress = 1
        job.errorMessage = nil; job.updatedAt = Date(); job.completedAt = Date()
    }
}
