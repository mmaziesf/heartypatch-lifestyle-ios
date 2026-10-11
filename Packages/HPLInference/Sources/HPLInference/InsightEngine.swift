import HPLCore

public enum EngineAvailability: Sendable, Equatable {
    case available
    case unavailable(reason: String)
}

/// One protocol for every engine (rules, Foundation Models, MLX, cloud) so they can be swapped and A/B'd on fixtures.
/// `extractLabRows` (architecture §6.2) joins this protocol in M2 alongside HPLIngest's OCR types.
public protocol InsightEngine: Sendable {
    var id: String { get }
    var generator: Generator { get }
    func isAvailable() async -> EngineAvailability
    func generate(summary: DailySummaryV1, ruleHits: [RuleHit]) async throws -> [RecommendationDraft]
}
