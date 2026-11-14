import Foundation

public enum PDFAnalysisSource {
    public static func parts(pages: [ExtractedPDFPage]) throws -> [AnalysisSourcePart] {
        var result: [AnalysisSourcePart] = []
        var section = "introduction"
        var finished = false
        for page in pages.sorted(by: { $0.number < $1.number }) {
            try Task.checkCancellation()
            if finished { break }
            var lines: [String] = []
            func flush() throws {
                let text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                lines = []
                guard !text.isEmpty else { return }
                let chunks = try PDFChunker.chunks(pages: [ExtractedPDFPage(number: page.number, text: text)], maximumCharacters: 2800, overlap: 0)
                for chunk in chunks {
                    result.append(AnalysisSourcePart(id: "pdf:\(page.number):\(result.count):\(chunk.hash)", page: page.number, text: chunk.text, section: section))
                }
            }
            for raw in page.text.components(separatedBy: .newlines) {
                let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                let heading = line.replacingOccurrences(of: #"^\s*(?:\d+(?:\.\d+)*[.)]?\s*)?"#, with: "", options: .regularExpression).lowercased()
                let compact = heading.replacingOccurrences(of: " ", with: "").trimmingCharacters(in: CharacterSet(charactersIn: ":."))
                if ["references", "bibliography", "acknowledgments", "acknowledgements", "appendix", "appendices", "supplementarymaterial"].contains(compact)
                    || (line.count < 100 && (compact.hasPrefix("acknowledg") || compact.hasPrefix("appendix") || compact.hasPrefix("supplementarymaterial"))) {
                    try flush(); finished = true; break
                }
                let numbered = line.range(of: #"^\d+(?:\.\d+)*[.)]?\s*[A-Za-z]"#, options: .regularExpression) != nil
                let standalone = ["abstract", "introduction", "method", "methods", "results", "experiments", "discussion", "conclusion", "conclusions", "relatedwork", "background"].contains(compact)
                if line.count < 100 && (numbered || standalone) {
                    let next: String?
                    if compact.contains("conclu") || compact.contains("discussion") || compact.contains("futurework") { next = "conclusion" }
                    else if compact.contains("experiment") || compact.contains("result") || compact.contains("evaluation") || compact.contains("ablation") { next = "results" }
                    else if compact.contains("method") || compact.contains("approach") || compact.contains("framework") || compact.contains("algorithm") { next = "method" }
                    else if compact.contains("introduction") || compact == "abstract" { next = "introduction" }
                    else if compact.contains("relatedwork") || compact.contains("background") || compact.contains("preliminar") { next = "other" }
                    else { next = nil }
                    if let next, next != section { try flush(); section = next }
                }
                if !line.isEmpty { lines.append(line) }
            }
            try flush()
        }
        return result
    }

    public static func selectedIndices(sections: [String?], limit: Int) -> [Int] {
        guard limit > 0 else { return [] }
        if sections.count <= limit { return Array(sections.indices) }
        let weights: [(String, Double)] = [("method", 0.30), ("results", 0.30), ("conclusion", 0.20), ("introduction", 0.15), ("other", 0.05)]
        let groups = Dictionary(grouping: sections.indices) { index in sections[index] ?? "other" }
        var counts: [String: Int] = [:]
        for _ in 0..<limit {
            let eligible = weights.filter { (counts[$0.0] ?? 0) < (groups[$0.0]?.count ?? 0) }
            guard let next = eligible.max(by: { $0.1 / Double((counts[$0.0] ?? 0) + 1) < $1.1 / Double((counts[$1.0] ?? 0) + 1) }) else { break }
            counts[next.0, default: 0] += 1
        }
        return weights.flatMap { section, _ -> [Int] in
            guard let indices = groups[section], let count = counts[section], count > 0 else { return [] }
            if count == 1 { return [section == "introduction" ? indices[0] : indices[indices.count / 2]] }
            return (0..<count).map { indices[$0 * (indices.count - 1) / (count - 1)] }
        }.sorted()
    }
}
