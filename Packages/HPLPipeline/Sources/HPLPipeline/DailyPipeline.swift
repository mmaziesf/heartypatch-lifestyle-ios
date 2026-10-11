import HPLCore
import HPLInference

/// summary -> rules -> engine -> guard -> recommendations. Falls back to rules-only if the engine is unavailable.
public struct DailyPipeline: Sendable {
    public var engine: any InsightEngine
    public var fallback: any InsightEngine = RulesOnlyEngine()
    public var outputGuard = OutputGuard()

    public init(engine: any InsightEngine = RulesOnlyEngine()) { self.engine = engine }

    public func run(_ input: DailySummaryV1) async throws -> [Recommendation] {
        let hits = RulesEngine.evaluate(input)
        var summary = input
        summary.ruleHits = hits.map(\.id)
        let tree = try summary.jsonTree()

        let active = await engine.isAvailable() == .available ? engine : fallback
        let drafts = try await active.generate(summary: summary, ruleHits: hits)

        return drafts.prefix(RulesOnlyEngine.maxRecommendations).compactMap { draft in
            let verdict = outputGuard.check(draft, against: tree)
            guard verdict.result == .pass else { return nil } // M0: blocked drafts are dropped (logged locally in M3)
            return Recommendation(
                day: summary.day, kind: draft.kind, title: draft.title, body: draft.body,
                evidence: draft.evidenceFieldPaths.map { EvidenceRef(summaryDay: summary.day, fieldPath: $0, value: tree.value(at: $0) ?? .null) },
                generator: active.generator, guardResult: verdict.result, provenance: summary.provenance)
        }
    }
}
