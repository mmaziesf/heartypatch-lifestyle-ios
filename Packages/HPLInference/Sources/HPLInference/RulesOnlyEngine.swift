import HPLCore

/// Always-available floor: deterministic templates per rule hit. No LLM.
/// Template copy stays digit-light: every number must come from the summary (OutputGuard enforces it).
public struct RulesOnlyEngine: InsightEngine {
    public let id = "rules-only"
    public let generator = Generator(engine: .rules, promptVersion: "rules-v0")
    public static let maxRecommendations = 3

    public init() {}

    public func isAvailable() async -> EngineAvailability { .available }

    public func generate(summary: DailySummaryV1, ruleHits: [RuleHit]) async throws -> [RecommendationDraft] {
        Array(ruleHits.compactMap { draft(for: $0, summary) }.prefix(Self.maxRecommendations))
    }

    private func draft(for hit: RuleHit, _ s: DailySummaryV1) -> RecommendationDraft? {
        switch hit.id {
        case "SLEEP_SHORT_VS_BASELINE":
            guard let total = s.sleep?.totalMin, let base = s.sleep?.baseline28d?.totalMinMedian else { return nil }
            return .init(kind: .experiment,
                         title: "Shorter sleep than your recent typical",
                         body: "You slept \(total) min vs your 28-day median of \(fmt(base)) min. "
                             + "Experiment idea: start winding down earlier for the next week and see whether total sleep moves.",
                         evidenceFieldPaths: hit.evidenceFieldPaths)
        case "HRV_BELOW_P10":
            guard let hrv = s.heart?.hrvSDNNOvernightMedian, let p10 = s.heart?.hrv28dP10 else { return nil }
            return .init(kind: .nudge,
                         title: "Overnight HRV in your low band",
                         body: "Overnight HRV (SDNN) was \(fmt(hrv)) ms, below your 28-day low band of \(fmt(p10)) ms. "
                             + "Consider an easier training day and an earlier night, then watch whether it rebounds.",
                         evidenceFieldPaths: hit.evidenceFieldPaths)
        case "LATE_MEAL_ALCOHOL":
            guard let path = hit.evidenceFieldPaths.first(where: { $0.hasSuffix(".t_local") }),
                  let idx = path.split(separator: ".").dropFirst().first.flatMap({ Int($0) }),
                  s.meals.indices.contains(idx) else { return nil }
            return .init(kind: .observation,
                         title: "Late meal with alcohol",
                         body: "Your \(s.meals[idx].label) at \(s.meals[idx].tLocal) was tagged late and alcohol. "
                             + "Compare tonight's deep sleep against nights without both tags.",
                         evidenceFieldPaths: hit.evidenceFieldPaths)
        default:
            return nil
        }
    }

    private func fmt(_ v: Double) -> String { v.rounded() == v ? String(Int(v)) : String(format: "%.1f", v) }
}
