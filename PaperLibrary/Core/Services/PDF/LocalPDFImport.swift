import CryptoKit
import Foundation
import PDFKit
import PaperLibrarySupport

public struct LocalPDFMetadata: Sendable {
    public let title: String
    public let authors: [String]
    public let abstract: String
    public let filename: String
    public let size: Int64
    public let pageCount: Int
    let frontMatter: String
    public var hasExtractableText: Bool { !frontMatter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    public var filenameTitle: String { URL(fileURLWithPath: filename).deletingPathExtension().lastPathComponent }
}

struct StagedLocalPDF: Sendable {
    let url: URL
    let checksum: String
}

extension PDFFileStore {
    public func inspectLocal(_ source: URL, limits: PDFLimits) throws -> LocalPDFMetadata {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        try Task.checkCancellation()
        let size = try localFileSize(source, limits: limits)
        guard let document = PDFDocument(url: source), !document.isLocked, document.pageCount > 0 else { throw PDFLibraryError.invalidFile }
        let attributes = document.documentAttributes ?? [:]
        let embeddedTitle = (attributes[PDFDocumentAttribute.titleAttribute] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let filenameTitle = source.deletingPathExtension().lastPathComponent
        let title = embeddedTitle.isEmpty || embeddedTitle.lowercased() == "untitled" ? filenameTitle : embeddedTitle
        let author = (attributes[PDFDocumentAttribute.authorAttribute] as? String) ?? ""
        let authors = author.components(separatedBy: CharacterSet(charactersIn: ";\n")).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let explicitAbstract = ["Abstract", "abstract", "dc:description"].compactMap { attributes[$0] as? String }.first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? ""
        let subject = (attributes[PDFDocumentAttribute.subjectAttribute] as? String) ?? ""
        let labeledSubject = subject.range(of: #"^\s*abstract\s*[:\n]"#, options: [.regularExpression, .caseInsensitive])
        let abstract = !explicitAbstract.isEmpty ? explicitAbstract : labeledSubject.map { String(subject[$0.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
        var frontMatter: [String] = []
        var remaining = 20_000
        for index in 0..<min(3, document.pageCount) {
            try Task.checkCancellation()
            let page = document.page(at: index)?.string ?? ""
            let text = String(page.prefix(remaining))
            if let end = text.range(of: #"(?im)^\s*(?:1[.)]?\s*)?introduction\s*$"#, options: .regularExpression) {
                frontMatter.append(String(text[..<end.lowerBound])); break
            }
            frontMatter.append(text); remaining -= text.count
            if remaining <= 0 { break }
        }
        try Task.checkCancellation()
        return LocalPDFMetadata(title: String(title.prefix(4096)), authors: authors.map { String($0.prefix(4096)) }, abstract: String(abstract.prefix(16_000)), filename: source.lastPathComponent, size: size, pageCount: document.pageCount, frontMatter: frontMatter.joined(separator: "\n\n"))
    }

    func stageLocal(_ source: URL, limits: PDFLimits) throws -> StagedLocalPDF {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        try Task.checkCancellation()
        try prepare()
        let size = try localFileSize(source, limits: limits)
        try checkSpace(required: size, reserve: limits.reserveBytes)
        let staged = try stagingURL(jobID: UUID())
        do {
            let input = try FileHandle(forReadingFrom: source)
            defer { try? input.close() }
            guard FileManager.default.createFile(atPath: staged.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw PDFLibraryError.diskSpace }
            let output = try FileHandle(forWritingTo: staged)
            defer { try? output.close() }
            var hasher = SHA256()
            var copied: Int64 = 0
            while let bytes = try input.read(upToCount: 65_536), !bytes.isEmpty {
                try Task.checkCancellation()
                copied += Int64(bytes.count)
                guard copied <= limits.maximumBytes else { throw PDFLibraryError.tooLarge }
                try output.write(contentsOf: bytes)
                hasher.update(data: bytes)
            }
            guard copied == size else { throw PDFLibraryError.invalidFile }
            try output.synchronize()
            try Task.checkCancellation()
            return StagedLocalPDF(url: staged, checksum: hasher.finalize().map { String(format: "%02x", $0) }.joined())
        } catch {
            try? discard(staged: staged)
            throw error
        }
    }

    private func localFileSize(_ source: URL, limits: PDFLimits) throws -> Int64 {
        guard source.isFileURL else { throw PDFLibraryError.invalidFile }
        let values = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, let size = values.fileSize, size > 5 else { throw PDFLibraryError.invalidFile }
        guard Int64(size) <= limits.maximumBytes else { throw PDFLibraryError.tooLarge }
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        guard try input.read(upToCount: 5) == Data("%PDF-".utf8) else { throw PDFLibraryError.invalidFile }
        return Int64(size)
    }
}

extension LibraryRepository {
    func validateLocalPDF(draft: PaperDraft, courseIDs: Set<UUID>) throws {
        guard !draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw LibraryError.invalidInput }
        try validateCourses(courseIDs)
    }

    func completeLocalPDF(paperID: UUID, version: Int, reference: PDFFileReference, draft: PaperDraft, courseIDs: Set<UUID>, filename: String) throws -> UUID {
        try validateLocalPDF(draft: draft, courseIDs: courseIDs)
        return try commit {
            let existing = paper(id: paperID)
            let paper = existing ?? Paper(id: paperID, title: draft.title.trimmingCharacters(in: .whitespacesAndNewlines), authors: draft.authors.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }, abstract: draft.abstract)
            if existing == nil {
                paper.provider = "localPDF"; paper.identityKey = "local-pdf:\(reference.checksum)"; paper.doi = draft.doi
                context.insert(paper)
            } else {
                if paper.provider == "localPDF" {
                    let filenames = importJobs.filter { $0.paperID == paperID && $0.canonicalIdentifier == nil }.map(\.input) + [filename]
                    let placeholders = Set(filenames.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent })
                    let title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
                    if placeholders.contains(paper.title) && !title.isEmpty && !placeholders.contains(title) {
                        paper.title = title; paper.updatedAt = Date()
                    }
                }
                let authors = draft.authors.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
                if paper.authors.isEmpty && !authors.isEmpty { paper.authors = authors; paper.updatedAt = Date() }
                if paper.abstract.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !draft.abstract.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    paper.abstract = draft.abstract; paper.updatedAt = Date()
                }
            }
            let oldRecord = pdfRecords.first { $0.paperID == paperID && $0.version == version }
            let record = oldRecord ?? PDFDocumentRecord(paperID: paperID, version: version, relativePath: reference.relativePath, fileSize: reference.size, checksum: reference.checksum)
            if oldRecord == nil { context.insert(record) }
            if record.isRemoved || record.checksum != reference.checksum {
                try deletePDFText(recordID: record.id)
                record.extractionStatus = "notExtracted"; record.indexStatus = "notIndexed"
            }
            record.relativePath = reference.relativePath; record.fileSize = reference.size; record.checksum = reference.checksum
            record.pageCount = reference.pageCount; record.isRemoved = false
            for courseID in courseIDs where !memberships.contains(where: { $0.paperID == paperID && $0.courseID == courseID }) {
                context.insert(CoursePaper(courseID: courseID, paperID: paperID))
            }
            if !["chunksReady", "noText"].contains(record.indexStatus) && !pdfJobs.contains(where: { $0.paperID == paperID && $0.version == version && $0.operation == "extract" && [.pending, .inProgress].contains($0.state) }) {
                context.insert(PDFProcessingJob(paperID: paperID, version: version, operation: "extract"))
            }
            let job = ImportJob(batchID: UUID(), input: filename, canonicalIdentifier: nil, requestedVersion: nil, destinationCourseID: courseIDs.first, assignExisting: true, refreshMetadata: false)
            job.paperID = paperID; job.stateRaw = "completed"; job.outcomeRaw = existing == nil ? "localPDF" : "existing"
            job.progress = 1; job.completedAt = Date(); job.updatedAt = Date()
            context.insert(job)
            return paperID
        }
    }
}
