import Foundation
import HPLCore
import HPLInference

/// `hpl.cloud_insights.v1` (Spec/hpl.cloud_insights.v1.schema.json): what a cloud analyzer returns.
public struct CloudInsightsV1: Codable, Sendable, Equatable {
    public static let schemaID = "hpl.cloud_insights.v1"
    public static let maxInsights = 5

    public struct Insight: Codable, Sendable, Equatable {
        /// observation | nudge (no experiments or clinician prompts from the cloud in v1).
        public var kind: String
        public var title: String
        public var body: String
        /// Paths into the sent payload, e.g. `weeks.3.metrics.steps.median` or `daily.12.sleep_total_min`.
        public var evidence: [String]
        public init(kind: String, title: String, body: String, evidence: [String]) {
            self.kind = kind; self.title = title; self.body = body; self.evidence = evidence
        }
    }

    public var schema: String
    public var requestID: String
    public var insights: [Insight]
    enum CodingKeys: String, CodingKey { case schema, requestID = "request_id", insights }
    public init(requestID: String, insights: [Insight]) { schema = Self.schemaID; self.requestID = requestID; self.insights = insights }
}

public enum CloudResponseError: Error, Equatable { case notJSON, wrongSchema, wrongRequestID, tooManyInsights }

/// Validates a response against the job and turns surviving insights into local `Recommendation`s (engine `cloud`).
public struct CloudResponseProcessor: Sendable {
    public static let promptVersion = "cloud-v1"
    let guardrail = OutputGuard()

    public struct Output: Sendable, Equatable {
        public var recommendations: [Recommendation]
        public var blocked: Int
    }

    public func process(_ data: Data, job: PreparedJob, transportID: String) throws -> Output {
        guard let response = try? JSONDecoder().decode(CloudInsightsV1.self, from: data) else { throw CloudResponseError.notJSON }
        guard response.schema == CloudInsightsV1.schemaID else { throw CloudResponseError.wrongSchema }
        guard response.requestID == job.payload.requestID else { throw CloudResponseError.wrongRequestID }
        guard response.insights.count <= CloudInsightsV1.maxInsights else { throw CloudResponseError.tooManyInsights }
        let input = (try? JSONDecoder().decode(JSONValue.self, from: job.body)) ?? .null
        var recs: [Recommendation] = []
        var blocked = 0
        for i in response.insights {
            guard let kind = Self.kind(i.kind), (1...80).contains(i.title.count), (1...400).contains(i.body.count), (1...4).contains(i.evidence.count) else {
                blocked += 1
                continue
            }
            let draft = RecommendationDraft(kind: kind, title: i.title, body: i.body, evidenceFieldPaths: i.evidence)
            guard guardrail.check(draft, against: input).result == .pass else { blocked += 1; continue }
            recs.append(Recommendation(
                day: job.anchor.description, kind: kind, title: i.title, body: i.body,
                evidence: i.evidence.map { EvidenceRef(summaryDay: job.localDay(forEvidence: $0), fieldPath: $0, value: input.value(at: $0) ?? .null) },
                generator: Generator(engine: .cloud, modelID: transportID, promptVersion: Self.promptVersion), guardResult: .pass,
                provenance: job.payload.provenance))
        }
        return Output(recommendations: recs, blocked: blocked)
    }

    static func kind(_ raw: String) -> RecommendationKind? {
        switch raw {
        case "observation": .observation
        case "nudge": .nudge
        default: nil
        }
    }
}
