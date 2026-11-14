import Foundation
import FoundationModels

@Generable
struct GuidedSummary {
    @Guide(description: "FIRST choose 1 to 4 source passage ids that together support the summary. Include passages containing every number or dimension mentioned.", .maximumCount(4))
    var evidenceIDs: [Int]
    @Guide(description: "THEN write 1 to 3 concise sentences in the requested language, supported only by the chosen passages. No unsupported numbers. Do not put evidence ids or bracketed citations in the text.")
    var text: String
    init(text: String, evidenceID: Int) { self.evidenceIDs = [evidenceID]; self.text = text }
    init(evidenceIDs: [Int], text: String) { self.evidenceIDs = evidenceIDs; self.text = text }
}

@Generable
struct GuidedPoint {
    var field: AnalysisField
    @Guide(description: "FIRST choose 1 to 4 source passage ids supporting this statement, including every number or dimension mentioned.", .maximumCount(4))
    var evidenceIDs: [Int]
    @Guide(description: "THEN write one concise statement in the requested language, supported only by the chosen passages. Do not put evidence ids or bracketed citations in the text.")
    var text: String
}

@Generable
struct GuidedAnalysis {
    var summary: GuidedSummary
    @Guide(description: "Additional supported details; omit absent fields and avoid repetition.", .maximumCount(7))
    var details: [GuidedPoint]
    @Guide(description: "Specific scientific topic labels.", .maximumCount(5))
    var topics: [String]
    @Guide(description: "In the requested output language. Only for Research Review: brief hypothetical open questions, not author claims. Otherwise empty.")
    var interpretation: String
}

struct SourceEvidence: Codable, Sendable {
    let id: Int
    let passage: String
    let intermediateExplanation: String?
}

enum AnalysisEvidenceBuilder {
    static func prose(_ text: String, evidence: [SourceEvidence]) throws -> String {
        let pattern = #"(?i)(?:,?\s+(?:as (?:stated|described|shown|reported) in|according to|come (?:indicato|descritto|mostrato|riportato) in|secondo)\s+)?(?<![\p{L}\p{N}_])\[(\d+)\]"#
        let expression = try NSRegularExpression(pattern: pattern)
        let value = NSMutableString(string: text)
        let ids = Set(evidence.map(\.id))
        for match in expression.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let range = Range(match.range(at: 1), in: text), let id = Int(text[range]), ids.contains(id) else { continue }
            value.replaceCharacters(in: match.range, with: "")
        }
        return AnalysisValidation.readableProse(value as String).replacingOccurrences(of: #"\s+([.,;:!?])"#, with: "$1", options: .regularExpression)
    }

    static func table(material: String, aggregation: Bool) throws -> [SourceEvidence] {
        if aggregation {
            let points = try JSONDecoder().decode([AnalysisPoint].self, from: Data(material.utf8))
            guard !points.isEmpty, points.count <= 64 else { throw AnalysisError.resourceLimit }
            let passages = points.flatMap { point in point.quotes.map { ($0, point.text) } }
            guard passages.count <= 64 else { throw AnalysisError.resourceLimit }
            return passages.enumerated().map { SourceEvidence(id: $0.offset, passage: $0.element.0, intermediateExplanation: $0.element.1) }
        }
        var remaining = material[...]
        var entries: [SourceEvidence] = []
        while !remaining.isEmpty {
            guard entries.count < 64 else { throw AnalysisError.resourceLimit }
            var end = remaining.index(remaining.startIndex, offsetBy: min(360, remaining.count))
            if end != remaining.endIndex {
                let slice = remaining[..<end]
                if let edge = slice.lastIndex(where: { ".!?\n".contains($0) }), slice.distance(from: slice.startIndex, to: edge) >= 80 { end = remaining.index(after: edge) }
                else if let space = slice.lastIndex(where: \.isWhitespace), space != remaining.startIndex { end = space }
            }
            let text = String(remaining[..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { entries.append(SourceEvidence(id: entries.count, passage: text, intermediateExplanation: nil)) }
            remaining = remaining[end...]
        }
        guard !entries.isEmpty else { throw AnalysisError.missingSource }
        return entries
    }
    static func output(_ draft: GuidedAnalysis, evidence: [SourceEvidence]) throws -> AnalysisOutput {
        func point(field: AnalysisField, text: String, ids: [Int]) throws -> AnalysisPoint {
            guard (1...4).contains(ids.count) else { throw AnalysisError.ungrounded }
            var quotes: [String] = []
            for id in ids {
                guard let source = evidence.first(where: { $0.id == id }) else { throw AnalysisError.ungrounded }
                if !quotes.contains(source.passage) { quotes.append(source.passage) }
            }
            return AnalysisPoint(field: field, text: try prose(text, evidence: evidence), quote: quotes[0], supportingQuotes: Array(quotes.dropFirst()))
        }
        let summary = try point(field: .summary, text: draft.summary.text, ids: draft.summary.evidenceIDs)
        let parts = evidence.map { AnalysisSourcePart(id: String($0.id), text: $0.passage) }
        _ = try AnalysisValidation.citations(point: summary, parts: parts)
        let details = draft.details.filter { $0.field != .summary }.compactMap { detail -> AnalysisPoint? in
            guard let resolved = try? point(field: detail.field, text: detail.text, ids: detail.evidenceIDs),
                  (try? AnalysisValidation.citations(point: resolved, parts: parts)) != nil else { return nil }
            return resolved
        }
        return AnalysisOutput(points: [summary] + details, topics: draft.topics, interpretation: draft.interpretation)
    }
}
