import HPLCore

public enum EngineAvailability: Sendable, Equatable {
    case available
    case unavailable(reason: String)
}

public enum InsightEngineError: Error, Sendable, Equatable {
    /// The model's output did not match the notes schema (bad JSON, unknown kind, too many notes).
    case schemaInvalid(String)
    /// The model refused or tripped its own safety guardrails.
    case refused(String)
    /// Prompt + output did not fit the context window.
    case contextOverflow
    case generationFailed(String)
}

/// One protocol for every engine (rules, Foundation Models, MLX, cloud) so they can be swapped and A/B'd on fixtures.
/// Engines see only the DailySummary (via `InsightPrompt`) and rule hits. Clinician-prompt hits are never passed to an LLM engine.
/// `extractLabRows` (architecture §6.2) is deferred: M2 shipped rules-only lab parsing.
public protocol InsightEngine: Sendable {
    var id: String { get }
    var generator: Generator { get }
    func isAvailable() async -> EngineAvailability
    func generate(summary: DailySummaryV1, ruleHits: [RuleHit]) async throws -> [RecommendationDraft]
}
