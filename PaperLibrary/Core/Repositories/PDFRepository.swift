import Foundation
import SwiftData
import PaperLibrarySupport

extension PDFDocumentRecord {
    public var fileReference: PDFFileReference { PDFFileReference(relativePath: relativePath, size: fileSize, checksum: checksum, pageCount: pageCount) }
}

extension LibraryRepository {
    public func pdfRecord(id: UUID) -> PDFDocumentRecord? { pdfRecords.first { $0.id == id } }
    public func pdfRecords(paperID: UUID) -> [PDFDocumentRecord] { pdfRecords.filter { $0.paperID == paperID && !$0.isRemoved }.sorted { $0.version > $1.version } }
    public func pdfJob(id: UUID) -> PDFProcessingJob? { pdfJobs.first { $0.id == id } }

    @discardableResult
    public func enqueuePDF(paperID: UUID, operation: String, version: Int? = nil) throws -> UUID {
        guard let paper = paper(id: paperID), ["download", "extract"].contains(operation) else { throw LibraryError.missingRecord }
        let version = version ?? paper.resolvedVersion ?? pdfRecords(paperID: paperID).first?.version ?? (paper.provider == "doi" ? 1 : nil)
        guard let version, version > 0 else { throw PDFLibraryError.invalidSource }
        if let active = pdfJobs.first(where: { $0.paperID == paperID && $0.version == version && $0.operation == operation && [.pending, .inProgress].contains($0.state) }) { return active.id }
        var source: String?
        if operation == "download" {
            if paper.provider == "arxiv", let rawID = paper.providerIdentifier, let id = try? ArxivIdentifier(rawID + "v\(version)") {
                source = id.pdfURL.absoluteString
            } else if paper.provider == "doi", let url = paper.pdfDownloadURL { source = url.absoluteString }
            else { throw PDFLibraryError.invalidSource }
        } else { guard pdfRecords(paperID: paperID).contains(where: { $0.version == version }) else { throw PDFLibraryError.missing } }
        return try commit {
            let job = PDFProcessingJob(paperID: paperID, version: version, operation: operation, sourceURL: source)
            context.insert(job); return job.id
        }
    }

    func updatePDFJob(id: UUID, state: ImportJobState, error: String? = nil, received: Int64? = nil, total: Int64? = nil) throws {
        guard let job = pdfJob(id: id) else { throw LibraryError.missingRecord }
        if job.state == .cancelled || job.state == .completed { return }
        try commit {
            job.stateRaw = state.rawValue; job.errorMessage = error; job.updatedAt = Date()
            if let received { job.bytesReceived = received }
            if let total { job.totalBytes = total }
        }
    }

    func completePDFDownload(jobID: UUID, reference: PDFFileReference) throws {
        guard let job = pdfJob(id: jobID), job.state == .inProgress, paper(id: job.paperID) != nil else { return }
        try commit {
            let existing = pdfRecords.first { $0.paperID == job.paperID && $0.version == job.version }
            let record = existing ?? PDFDocumentRecord(paperID: job.paperID, version: job.version, relativePath: reference.relativePath, fileSize: reference.size, checksum: reference.checksum)
            if existing == nil { context.insert(record) }
            if record.checksum != reference.checksum { try deletePDFText(recordID: record.id) }
            record.relativePath = reference.relativePath; record.fileSize = reference.size; record.checksum = reference.checksum
            record.isRemoved = false; record.downloadedAt = Date()
            record.pageCount = reference.pageCount
            record.extractionStatus = "notExtracted"; record.indexStatus = "notIndexed"
            job.stateRaw = ImportJobState.completed.rawValue; job.bytesReceived = reference.size; job.totalBytes = reference.size; job.updatedAt = Date(); job.errorMessage = nil
            if !pdfJobs.contains(where: { $0.paperID == job.paperID && $0.version == job.version && $0.operation == "extract" && [.pending, .inProgress].contains($0.state) }) {
                context.insert(PDFProcessingJob(paperID: job.paperID, version: job.version, operation: "extract"))
            }
        }
    }

    func completePDFExtraction(jobID: UUID, recordID: UUID, checksum: String, result: ExtractedPDF, chunks: [PDFChunk]) throws {
        guard let job = pdfJob(id: jobID), job.state == .inProgress,
              let record = pdfRecord(id: recordID), !record.isRemoved, record.checksum == checksum,
              paper(id: record.paperID) != nil else { return }
        try commit {
            try deletePDFText(recordID: recordID)
            for page in result.pages { context.insert(PDFPageText(recordID: recordID, pageNumber: page.number, text: page.text)) }
            for chunk in chunks {
                context.insert(TextChunk(id: chunk.id(recordID: recordID), paperID: record.paperID, recordID: recordID, chunkIndex: chunk.index, text: chunk.text, startPage: chunk.page, endPage: chunk.page, contentHash: chunk.hash))
            }
            record.pageCount = result.totalPages
            record.extractionStatus = result.incomplete ? "incomplete" : "completed"
            record.indexStatus = chunks.isEmpty ? "noText" : "chunksReady"
            job.stateRaw = ImportJobState.completed.rawValue; job.updatedAt = Date(); job.errorMessage = nil
        }
    }

    public func pdfPages(recordID: UUID) throws -> [PDFPageText] {
        try context.fetch(FetchDescriptor<PDFPageText>(predicate: #Predicate { $0.recordID == recordID }, sortBy: [SortDescriptor(\PDFPageText.pageNumber)]))
    }
    public func pdfChunks(recordID: UUID) throws -> [TextChunk] {
        try context.fetch(FetchDescriptor<TextChunk>(predicate: #Predicate { $0.recordID == recordID }, sortBy: [SortDescriptor(\TextChunk.chunkIndex)]))
    }
    func deletePDFText(recordID: UUID) throws {
        for page in try pdfPages(recordID: recordID) { context.delete(page) }
        for chunk in try pdfChunks(recordID: recordID) { context.delete(chunk) }
    }
    public func saveReadingPosition(recordID: UUID, page: Int) throws {
        guard let record = pdfRecord(id: recordID), !record.isRemoved else { return }
        try commit { record.lastReadPage = max(1, min(page, max(1, record.pageCount))) }
    }
    public func removePDF(recordID: UUID) throws {
        guard let record = pdfRecord(id: recordID) else { throw LibraryError.missingRecord }
        try commit {
            record.isRemoved = true; try deletePDFText(recordID: recordID)
            for job in aiJobs where job.recordID == recordID && [.pending, .inProgress].contains(job.state) {
                job.stateRaw = "cancelled"; job.updatedAt = Date(); paper(id: job.paperID)?.aiStatusRaw = "cancelled"
            }
            for job in pdfJobs where job.paperID == record.paperID && job.version == record.version && [.pending, .inProgress].contains(job.state) {
                job.stateRaw = ImportJobState.cancelled.rawValue; job.updatedAt = Date()
            }
        }
    }
    func recoverPDFJobs() throws {
        guard pdfJobs.contains(where: { [.pending, .inProgress].contains($0.state) }) else { return }
        try interruptPDFJobs()
    }
    func interruptPDFJobs() throws {
        try commit {
            for job in pdfJobs where [.pending, .inProgress].contains(job.state) {
                job.stateRaw = ImportJobState.interrupted.rawValue; job.updatedAt = Date()
                job.errorMessage = Strings.text("pdf.interrupted")
            }
        }
    }
    func retryPDFJob(id: UUID) throws {
        guard let job = pdfJob(id: id), job.state.canRetry, paper(id: job.paperID) != nil else { return }
        try commit { job.stateRaw = ImportJobState.pending.rawValue; job.errorMessage = nil; job.bytesReceived = 0; job.totalBytes = nil; job.updatedAt = Date() }
    }
}
