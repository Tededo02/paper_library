import Foundation
import PaperLibrarySupport
import SwiftData

public enum BuiltinAnalysisProfiles {
    public static let quickID = PDFHash.uuid("profile.quick")
    public static let definitions: [(UUID, String, String)] = [
        (quickID, "Quick Summary", "Quick Summary: explain the research problem, core idea and key contribution in 2 to 5 sentences total. Prefer a concise summary; do not repeat the same fact across fields."),
        (PDFHash.uuid("profile.technical"), "Technical Summary", "Technical Summary: cover problem and motivation, method, technical contribution, experimental evidence, assumptions and limitations only where explicitly supported. Omit missing fields."),
        (PDFHash.uuid("profile.review"), "Research Review", "Research Review: identify the problem, author-claimed novelty, reported comparisons, technical strengths and limitations. In interpretation only, suggest clearly hypothetical open questions and possible follow-up directions; never attribute these to the authors.")
    ]

    public static func displayName(id: UUID, name: String) -> String {
        let legacyNames = [quickID: "Sintesi rapida", PDFHash.uuid("profile.technical"): "Sintesi tecnica", PDFHash.uuid("profile.review"): "Revisione di ricerca"]
        guard legacyNames[id] == name else { return name }
        return definitions.first { $0.0 == id }?.1 ?? name
    }
}

extension LibraryRepository {
    func seedAnalysisProfiles() throws {
        let missing = BuiltinAnalysisProfiles.definitions.filter { id, _, _ in !profiles.contains { $0.id == id } }
        guard !missing.isEmpty else { return }
        try commit {
            for (index, item) in missing.enumerated() { context.insert(AnalysisProfile(id: item.0, name: item.1, instructions: item.2, sortOrder: index)) }
        }
    }
    public func saveProfile(id: UUID?, name: String, instructions: String) throws {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 80, !text.isEmpty, text.count <= 1600 else { throw LibraryError.invalidInput }
        try commit {
            if let id {
                guard let profile = profiles.first(where: { $0.id == id }) else { throw LibraryError.missingRecord }
                profile.name = name; profile.instructions = text
            } else { context.insert(AnalysisProfile(name: name, instructions: text, sortOrder: profiles.count)) }
        }
    }
    public func analyses(paperID: UUID, limit: Int? = 100) throws -> [AIAnalysis] {
        var descriptor = FetchDescriptor<AIAnalysis>(predicate: #Predicate { $0.paperID == paperID }, sortBy: [SortDescriptor(\AIAnalysis.generatedAt, order: .reverse)])
        descriptor.fetchLimit = limit
        return try context.fetch(descriptor)
    }
    public func analysis(id: UUID) throws -> AIAnalysis? {
        var descriptor = FetchDescriptor<AIAnalysis>(predicate: #Predicate { $0.id == id }); descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }
    public func editAnalysis(id: UUID, text: String) throws {
        guard let analysis = try analysis(id: id), text.count <= 32_000 else { throw LibraryError.invalidInput }
        try commit { analysis.userContent = text; analysis.userEdited = true; analysis.revision += 1 }
    }
    public func sourceSnapshot(paperID: UUID, kind: AnalysisSourceKind, recordID: UUID?) throws -> AnalysisSourceSnapshot {
        guard let paper = paper(id: paperID) else { throw LibraryError.missingRecord }
        if kind == .abstract {
            let source = paper.abstract.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !source.isEmpty else { throw AnalysisError.missingSource }
            guard source.count <= 192_000 else { throw AnalysisError.resourceLimit }
            var parts: [AnalysisSourcePart] = []
            var remaining = source[...]
            while !remaining.isEmpty {
                let end = remaining.index(remaining.startIndex, offsetBy: min(3000, remaining.count))
                parts.append(AnalysisSourcePart(id: "abstract:\(parts.count)", text: String(remaining[..<end])))
                remaining = remaining[end...]
            }
            return AnalysisSourceSnapshot(kind: kind, hash: PDFHash.text(source), parts: parts)
        }
        guard let recordID, let record = pdfRecord(id: recordID), record.paperID == paperID, !record.isRemoved, record.indexStatus == "chunksReady" else { throw AnalysisError.missingSource }
        let pages = try pdfPages(recordID: recordID)
        if !pages.isEmpty {
            let all = try PDFAnalysisSource.parts(pages: pages.map { ExtractedPDFPage(number: $0.pageNumber, text: $0.text) })
            let selected = PDFAnalysisSource.selectedIndices(sections: all.map(\.section), limit: 64).map { all[$0] }
            guard !selected.isEmpty else { throw AnalysisError.missingSource }
            let hash = PDFHash.text("pdf-sections-1:" + record.checksum + record.extractionStatus + selected.map { "\($0.page ?? 0):\(PDFHash.text($0.text))" }.joined(separator: ":"))
            return AnalysisSourceSnapshot(kind: kind, recordID: recordID, version: record.version, hash: hash, parts: selected, incomplete: selected.count < all.count || record.extractionStatus != "completed")
        }
        var descriptor = FetchDescriptor<TextChunk>(predicate: #Predicate { $0.recordID == recordID }, sortBy: [SortDescriptor(\TextChunk.chunkIndex)])
        descriptor.fetchLimit = 65
        let all = try context.fetch(descriptor)
        let chunks = Array(all.prefix(64))
        guard !chunks.isEmpty else { throw AnalysisError.missingSource }
        guard chunks.allSatisfy({ !$0.text.isEmpty && $0.text.count <= 3200 && $0.startPage > 0 }) else { throw AnalysisError.resourceLimit }
        let parts = chunks.map { AnalysisSourcePart(id: $0.id.uuidString, page: $0.startPage, text: $0.text) }
        let hash = PDFHash.text(record.checksum + record.extractionStatus + all.map(\.contentHash).joined(separator: ":"))
        return AnalysisSourceSnapshot(kind: kind, recordID: recordID, version: record.version, hash: hash, parts: parts, incomplete: all.count > 64 || record.extractionStatus != "completed")
    }
    @discardableResult
    public func enqueueAnalysis(paperID: UUID, profileID: UUID, kind: AnalysisSourceKind, recordID: UUID?, language: String, confirmEdited: Bool = false) throws -> UUID {
        if let active = aiJobs.first(where: { $0.paperID == paperID && [.pending, .inProgress].contains($0.state) }) { return active.id }
        guard ["it", "en"].contains(language), let profile = profiles.first(where: { $0.id == profileID }) else { throw LibraryError.invalidInput }
        let source = try sourceSnapshot(paperID: paperID, kind: kind, recordID: recordID)
        let previous = try analyses(paperID: paperID, limit: nil).first { $0.profileID == profileID && $0.sourceKind == kind.rawValue && $0.language == language }
        if previous?.userEdited == true && !confirmEdited { throw AnalysisError.edited }
        return try commit {
            let job = AIProcessingJob(paperID: paperID, profile: profile, source: source, language: language, previous: previous)
            context.insert(job); paper(id: paperID)?.aiStatusRaw = "pending"; return job.id
        }
    }
    func updateAIJob(id: UUID, state: ImportJobState, progress: Double? = nil, error: String? = nil) throws {
        guard let job = aiJobs.first(where: { $0.id == id }), job.state != .completed, job.state != .cancelled else { return }
        try commit {
            job.stateRaw = state.rawValue; job.updatedAt = Date(); job.errorMessage = error
            if let progress { job.progress = max(0, min(1, progress)) }
            paper(id: job.paperID)?.aiStatusRaw = state.rawValue
        }
    }
    func completeAnalysis(jobID: UUID, result: AnalysisResult) throws {
        guard let job = aiJobs.first(where: { $0.id == jobID }), job.state == .inProgress, paper(id: job.paperID) != nil else { return }
        guard let kind = AnalysisSourceKind(rawValue: job.sourceKind) else { throw AnalysisError.stale }
        let current = try sourceSnapshot(paperID: job.paperID, kind: kind, recordID: job.recordID)
        guard current.hash == job.sourceHash else { throw AnalysisError.stale }
        if let previousID = job.previousAnalysisID, let previous = try analysis(id: previousID), previous.revision != job.previousRevision { throw AnalysisError.edited }
        _ = try AnalysisValidation.citations(output: result.output, parts: current.parts)
        let content = String(decoding: try JSONEncoder().encode(result.output), as: UTF8.self)
        let provenance = String(decoding: try JSONEncoder().encode(result.citations), as: UTF8.self)
        try commit {
            context.insert(AIAnalysis(job: job, contentJSON: content, provenanceJSON: provenance, incomplete: result.incomplete, processedParts: result.processedParts, modelIdentifier: result.modelIdentifier, systemVersion: result.systemVersion))
            if paper(id: job.paperID)?.topicsUserEdited == false { try addTopics(paperID: job.paperID, names: result.output.topics, origin: "ai") }
            job.stateRaw = "completed"; job.progress = 1; job.updatedAt = Date(); job.errorMessage = nil
            paper(id: job.paperID)?.aiStatusRaw = "completed"
        }
    }
    public func retryAnalysis(id: UUID, confirmEdited: Bool = false) throws -> UUID {
        guard let job = aiJobs.first(where: { $0.id == id }), job.state.canRetry, let kind = AnalysisSourceKind(rawValue: job.sourceKind) else { throw LibraryError.missingRecord }
        return try enqueueAnalysis(paperID: job.paperID, profileID: job.profileID, kind: kind, recordID: job.recordID, language: job.language, confirmEdited: confirmEdited)
    }
    func interruptAIJobs() throws {
        guard aiJobs.contains(where: { [.pending, .inProgress].contains($0.state) }) else { return }
        try commit {
            for job in aiJobs where [.pending, .inProgress].contains(job.state) {
                job.stateRaw = "interrupted"; job.updatedAt = Date(); job.errorMessage = Strings.text("ai.interrupted")
                paper(id: job.paperID)?.aiStatusRaw = "interrupted"
            }
        }
    }
    public func topicNames(paperID: UUID) -> [String] {
        let ids = Set(paperTopics.filter { $0.paperID == paperID }.map(\.topicID))
        return topics.filter { ids.contains($0.id) }.map(\.name)
    }
    public func replaceTopics(paperID: UUID, names: [String]) throws {
        guard paper(id: paperID) != nil, names.count <= 30 else { throw LibraryError.invalidInput }
        try commit {
            for link in paperTopics where link.paperID == paperID { context.delete(link) }
            try addTopics(paperID: paperID, names: names, origin: "manual", replacing: true)
            paper(id: paperID)?.topicsUserEdited = true
        }
    }
    private func addTopics(paperID: UUID, names: [String], origin: String, replacing: Bool = false) throws {
        var byKey = Dictionary(uniqueKeysWithValues: topics.map { ($0.normalizedKey, $0) })
        var assigned = replacing ? Set<UUID>() : Set(paperTopics.filter { $0.paperID == paperID }.map(\.topicID))
        for raw in names {
            let name = AnalysisValidation.normalized(raw)
            guard !name.isEmpty, name.count <= 80 else { throw LibraryError.invalidInput }
            let key = name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            let topic = byKey[key] ?? Topic(name: name, normalizedKey: key)
            if byKey[key] == nil { context.insert(topic); byKey[key] = topic }
            if assigned.insert(topic.id).inserted { context.insert(PaperTopic(paperID: paperID, topicID: topic.id, origin: origin)) }
        }
    }
}
