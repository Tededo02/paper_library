import Foundation
@testable import PaperLibraryCore

actor FixtureAnalysisModel: OnDeviceAnalysisModel {
    var calls = 0
    var requests: [AnalysisRequest] = []
    var materials: [String] = []
    var status: AIAvailability
    var failure: AnalysisError?
    let delay: Duration
    let maximumInput: Int
    let maximumAggregationInput: Int
    var topics = ["SLAM", "slam", "Robotics"]
    init(status: AIAvailability = .available, failure: AnalysisError? = nil, delay: Duration = .zero, maximumInput: Int = .max, maximumAggregationInput: Int = .max) {
        self.status = status; self.failure = failure; self.delay = delay; self.maximumInput = maximumInput; self.maximumAggregationInput = maximumAggregationInput
    }
    func configure(status: AIAvailability? = nil, failure: AnalysisError? = nil, topics: [String]? = nil) {
        if let status { self.status = status }; self.failure = failure; if let topics { self.topics = topics }
    }
    func availability(language: String) -> AIAvailability { status }
    func generate(request: AnalysisRequest, material: String, aggregation: Bool) async throws -> AnalysisOutput {
        calls += 1; requests.append(request); materials.append(material)
        guard status == .available else { throw AnalysisError.unavailable(status) }
        if material.count > maximumInput && !aggregation { throw AnalysisError.contextLimit }
        if material.count > maximumAggregationInput && aggregation { throw AnalysisError.contextLimit }
        if delay != .zero { try await Task.sleep(for: delay) }
        if let failure { throw failure }
        let quote: String
        if aggregation, let points = try? JSONDecoder().decode([AnalysisPoint].self, from: Data(material.utf8)), let first = points.first { quote = first.quote }
        else { quote = String(material.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120)) }
        return AnalysisOutput(points: [AnalysisPoint(field: .summary, text: "Sintesi del materiale fornito.", quote: quote)], topics: topics)
    }
}
