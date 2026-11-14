import Foundation
import FoundationModels

public actor AppleAnalysisModel: OnDeviceAnalysisModel {
    private let model = SystemLanguageModel.default
    private let validationFailure: (@Sendable (String) -> Void)?
    public init(validationFailure: (@Sendable (String) -> Void)? = nil) { self.validationFailure = validationFailure }

    public func availability(language: String) -> AIAvailability {
        switch model.availability {
        case .available:
            return ["it", "en"].contains(language) && model.supportsLocale(Locale(identifier: language)) ? .available : .unsupportedLanguage
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible: return .deviceNotEligible
            case .appleIntelligenceNotEnabled: return .appleIntelligenceNotEnabled
            case .modelNotReady: return .modelNotReady
            @unknown default: return .unknown
            }
        }
    }

    public func generate(request: AnalysisRequest, material: String, aggregation: Bool) async throws -> AnalysisOutput {
        try Task.checkCancellation()
        let status = availability(language: request.language)
        guard status == .available else { throw AnalysisError.unavailable(status) }
        let instructions = AnalysisPrompt.instructions(request)
        let evidence = try AnalysisEvidenceBuilder.table(material: material, aggregation: aggregation)
        let table = String(decoding: try JSONEncoder().encode(evidence), as: UTF8.self)
        let prompt = try AnalysisPrompt.prompt(material: table, aggregation: aggregation, language: request.language)
        let repair = AnalysisPrompt.repair(language: request.language)
        let summaryOnly = request.language == "it"
            ? "\nGenera soltanto una breve sintesi in italiano con evidenceIDs e text. Usa una o due frasi e solo fatti espliciti nei passaggi scelti. Ometti numeri, dimensioni e percentuali. Nessun altro campo o dettaglio."
            : "\nGenerate only a short summary with evidenceIDs and text, in English. Use one or two sentences and only explicit facts from the selected passages. Omit numbers, dimensions and percentages. No other fields or details."
        let outputBudget = 1400
        do {
            let inputTokens: Int
            if #available(macOS 26.4, *) {
                let a = try await model.tokenCount(for: Instructions(instructions))
                let b = try await model.tokenCount(for: prompt + repair + summaryOnly)
                let c = try await model.tokenCount(for: GuidedAnalysis.generationSchema)
                inputTokens = a + b + c
            } else {
                let schemaBytes = try JSONEncoder().encode(GuidedAnalysis.generationSchema).count
                inputTokens = instructions.utf8.count + prompt.utf8.count + repair.utf8.count + summaryOnly.utf8.count + schemaBytes
            }
            guard inputTokens + outputBudget + 384 < model.contextSize else { throw AnalysisError.contextLimit }
            for attempt in 0..<2 {
                try Task.checkCancellation()
                let session = LanguageModelSession(model: model, tools: [], instructions: instructions)
                let response = try await session.respond(to: prompt + (attempt == 0 ? "" : repair), generating: GuidedAnalysis.self, options: GenerationOptions(samplingMode: .greedy, maximumResponseTokens: outputBudget))
                try Task.checkCancellation()
                do {
                    let output = try AnalysisEvidenceBuilder.output(response.content, evidence: evidence)
                    try AnalysisValidation.language(output: output, requested: request.language)
                    _ = try AnalysisValidation.citations(output: output, parts: evidence.map { AnalysisSourcePart(id: String($0.id), text: $0.passage) })
                    return output
                } catch let error as AnalysisError where [.ungrounded, .wrongLanguage, .invalidOutput].contains(error) {
                    validationFailure?("Rejected attempt \(attempt + 1): \(error) · \(String(reflecting: response.content))")
                    continue
                }
            }
            let session = LanguageModelSession(model: model, tools: [], instructions: instructions)
            let response = try await session.respond(to: prompt + repair + summaryOnly, generating: GuidedSummary.self,
                                                    options: GenerationOptions(samplingMode: .greedy, maximumResponseTokens: outputBudget))
            try Task.checkCancellation()
            let output: AnalysisOutput
            do { output = try AnalysisEvidenceBuilder.output(GuidedAnalysis(summary: response.content, details: [], topics: [], interpretation: ""), evidence: evidence) }
            catch { validationFailure?("Rejected short summary: \(error) · \(String(reflecting: response.content))"); throw error }
            try AnalysisValidation.language(output: output, requested: request.language)
            _ = try AnalysisValidation.citations(output: output, parts: evidence.map { AnalysisSourcePart(id: String($0.id), text: $0.passage) })
            return output
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            if let known = error as? AnalysisError { throw known }
            if #available(macOS 27.0, *), let modern = error as? LanguageModelError {
                switch modern {
                case .contextSizeExceeded: throw AnalysisError.contextLimit
                case .guardrailViolation, .refusal: throw AnalysisError.refused
                case .unsupportedLanguageOrLocale: throw AnalysisError.unavailable(.unsupportedLanguage)
                case .rateLimited, .timeout: throw AnalysisError.resourceLimit
                default: throw AnalysisError.failed
                }
            }
            if let legacy = error as? LanguageModelSession.GenerationError {
                switch legacy {
                case .exceededContextWindowSize: throw AnalysisError.contextLimit
                case .guardrailViolation, .refusal: throw AnalysisError.refused
                case .unsupportedLanguageOrLocale: throw AnalysisError.unavailable(.unsupportedLanguage)
                case .assetsUnavailable: throw AnalysisError.unavailable(.modelNotReady)
                case .rateLimited: throw AnalysisError.resourceLimit
                default: throw AnalysisError.failed
                }
            }
            throw AnalysisError.failed
        }
    }
}
