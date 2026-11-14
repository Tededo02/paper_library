import Foundation

public actor AnalysisPipeline {
    private let model: any OnDeviceAnalysisModel
    public init(model: any OnDeviceAnalysisModel) { self.model = model }

    public func run(source: AnalysisSourceSnapshot, request: AnalysisRequest, progress: @Sendable (Double) async -> Void) async throws -> AnalysisResult {
        guard !source.parts.isEmpty, source.parts.count <= 64, request.profile.count <= 1600 else { throw AnalysisError.resourceLimit }
        if source.kind == .pdf { return try await analyzePDF(source: source, request: request, progress: progress) }
        var outputs: [AnalysisOutput] = []
        var calls = 0
        for (index, part) in source.parts.enumerated() {
            try Task.checkCancellation()
            outputs += try await analyze(part: part, request: request, depth: 0, calls: &calls)
            await progress(Double(index + 1) / Double(source.parts.count) * 0.85)
        }
        let output: AnalysisOutput
        if outputs.count == 1 && source.kind == .abstract { output = outputs[0] }
        else {
            var seen = Set<String>()
            let all = outputs.flatMap(\.points).filter { seen.insert($0.field.rawValue + AnalysisValidation.normalized($0.text)).inserted }
            var selected: [AnalysisPoint] = []
            for field in AnalysisField.allCases {
                if let first = all.first(where: { $0.field == field }) { selected.append(first) }
            }
            selected += all.filter { point in !selected.contains(point) }.prefix(max(0, 12 - selected.count))
            var combined: AnalysisOutput?
            for _ in 0..<4 {
                try Task.checkCancellation()
                let material = String(decoding: try JSONEncoder().encode(selected), as: UTF8.self)
                do { combined = try await model.generate(request: request, material: material, aggregation: true); break }
                catch AnalysisError.contextLimit {
                    guard selected.count > 2 else { throw AnalysisError.contextLimit }
                    selected = Array(selected.prefix(max(2, selected.count / 2)))
                }
            }
            guard let combined else { throw AnalysisError.contextLimit }
            let supplied = selected.flatMap { $0.quotes }.map { AnalysisSourcePart(id: "aggregation", text: $0) }
            _ = try AnalysisValidation.citations(output: combined, parts: supplied)
            output = combined
        }
        let citations = try AnalysisValidation.citations(output: output, parts: source.parts)
        try Task.checkCancellation()
        await progress(0.98)
        return AnalysisResult(output: output, citations: citations, incomplete: source.incomplete, processedParts: source.parts.count,
                              modelIdentifier: "apple.SystemLanguageModel.default", systemVersion: ProcessInfo.processInfo.operatingSystemVersionString)
    }

    private func analyzePDF(source: AnalysisSourceSnapshot, request: AnalysisRequest, progress: @Sendable (Double) async -> Void) async throws -> AnalysisResult {
        var passages: [(point: AnalysisPoint, part: AnalysisSourcePart)] = []
        for part in source.parts {
            for evidence in try AnalysisEvidenceBuilder.table(material: part.text, aggregation: false) {
                passages.append((AnalysisPoint(field: .summary, text: "", quote: evidence.passage), part))
            }
        }
        guard !passages.isEmpty else { throw AnalysisError.missingSource }
        var count = min(64, passages.count)
        while true {
            try Task.checkCancellation()
            let indices = PDFAnalysisSource.selectedIndices(sections: passages.map { $0.part.section }, limit: count)
            let selected = indices.map { passages[$0] }
            let material = String(decoding: try JSONEncoder().encode(selected.map(\.point)), as: UTF8.self)
            await progress(0.15)
            do {
                let output = try await model.generate(request: request, material: material, aggregation: true)
                let citations = try AnalysisValidation.citations(output: output, parts: selected.map(\.part))
                try Task.checkCancellation()
                await progress(0.98)
                return AnalysisResult(output: output, citations: citations, incomplete: source.incomplete || selected.count < passages.count,
                                      processedParts: Set(selected.map { $0.part.id }).count,
                                      modelIdentifier: "apple.SystemLanguageModel.default", systemVersion: ProcessInfo.processInfo.operatingSystemVersionString)
            } catch AnalysisError.contextLimit {
                guard count > 1 else { throw AnalysisError.contextLimit }
                count = max(1, count * 2 / 3)
            }
        }
    }

    private func analyze(part: AnalysisSourcePart, request: AnalysisRequest, depth: Int, calls: inout Int) async throws -> [AnalysisOutput] {
        try Task.checkCancellation()
        guard calls < 160 else { throw AnalysisError.resourceLimit }
        calls += 1
        do {
            let output = try await model.generate(request: request, material: part.text, aggregation: false)
            _ = try AnalysisValidation.citations(output: output, parts: [part])
            return [output]
        } catch AnalysisError.contextLimit {
            guard depth < 6, part.text.count > 160 else { throw AnalysisError.contextLimit }
            let middle = part.text.index(part.text.startIndex, offsetBy: part.text.count / 2)
            let split = part.text[..<middle].lastIndex(where: \.isWhitespace) ?? middle
            let first = AnalysisSourcePart(id: part.id + "a", page: part.page, text: String(part.text[..<split]))
            let second = AnalysisSourcePart(id: part.id + "b", page: part.page, text: String(part.text[split...]))
            let a = try await analyze(part: first, request: request, depth: depth + 1, calls: &calls)
            let b = try await analyze(part: second, request: request, depth: depth + 1, calls: &calls)
            return a + b
        }
    }
}
