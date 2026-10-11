import Foundation
import HPLCore
import HPLInference

/// summary -> rules -> engine -> guard -> recommendations (architecture §5.4).
/// - Clinician-prompt hits never reach an LLM: their fixed copy comes from the rules templates and goes first.
/// - Unavailable or failing engines fall back to rules-only; the app never depends on an LLM.
/// - A draft that fails only on untraceable numbers is replaced by its rule template (`.rewritten`); other failures drop it.
public struct DailyPipeline: Sendable {
    public var engine: any InsightEngine
    public var fallback = RulesOnlyEngine()
    public var outputGuard = OutputGuard()
    public static let maxRecommendations = InsightPrompt.maxNotes

    public init(engine: any InsightEngine = RulesOnlyEngine()) { self.engine = engine }

    /// What happened on one run, kept on device for evals and the debug screen. Never uploaded.
    public struct Report: Sendable {
        public struct DraftOutcome: Sendable {
            public var draft: RecommendationDraft
            public var verdict: OutputGuard.Verdict
        }
        public var recommendations: [Recommendation]
        public var engineID: String
        public var fallbackReason: String?
        public var drafts: [DraftOutcome]
        public var latency: Duration
    }

    public func run(_ input: DailySummaryV1) async throws -> [Recommendation] { try await runDetailed(input).recommendations }

    public func runDetailed(_ input: DailySummaryV1) async throws -> Report {
        let hits = RulesEngine.evaluate(input)
        var summary = input
        summary.ruleHits = hits.map(\.id)
        let tree = try summary.jsonTree()

        let fixed = hits.filter { RuleID.isClinicianPrompt($0.id) }.compactMap { fallback.draft(for: $0, summary) }
        let open = hits.filter { !RuleID.isClinicianPrompt($0.id) }

        let clock = ContinuousClock()
        let start = clock.now
        var used: any InsightEngine = engine
        var fallbackReason: String?
        var drafts: [RecommendationDraft]
        if case .unavailable(let reason) = await engine.isAvailable() {
            used = fallback
            fallbackReason = reason
            drafts = try await fallback.generate(summary: summary, ruleHits: open)
        } else {
            do {
                drafts = try await engine.generate(summary: summary, ruleHits: open)
            } catch {
                used = fallback
                fallbackReason = "engine error: \(error)"
                drafts = try await fallback.generate(summary: summary, ruleHits: open)
            }
        }
        let latency = clock.now - start

        var outcomes: [Report.DraftOutcome] = []
        var recs: [Recommendation] = []
        let sourced: [(draft: RecommendationDraft, engine: any InsightEngine)] = fixed.map { ($0, fallback) } + drafts.map { ($0, used) }
        for (draft, source) in sourced {
            let verdict = outputGuard.check(draft, against: tree)
            outcomes.append(.init(draft: draft, verdict: verdict))
            if let rec = accept(draft, verdict, used: source, hits: open, summary: summary, tree: tree) { recs.append(rec) }
        }
        return Report(recommendations: Array(dedupe(recs).prefix(Self.maxRecommendations)), engineID: used.id,
                      fallbackReason: fallbackReason, drafts: outcomes, latency: latency)
    }

    private func accept(_ draft: RecommendationDraft, _ verdict: OutputGuard.Verdict, used: any InsightEngine,
                        hits: [RuleHit], summary: DailySummaryV1, tree: JSONValue) -> Recommendation? {
        if verdict.result == .pass { return make(draft, .pass, generator: used.generator, summary, tree) }
        guard verdict.failedOnlyOnNumbers, used.generator.engine != .rules,
              let hit = hits.first(where: { !Set($0.evidenceFieldPaths).isDisjoint(with: draft.evidenceFieldPaths) }),
              let template = fallback.draft(for: hit, summary),
              outputGuard.check(template, against: tree).result == .pass else { return nil }
        return make(template, .rewritten, generator: fallback.generator, summary, tree)
    }

    private func make(_ d: RecommendationDraft, _ result: GuardResult, generator: Generator,
                      _ summary: DailySummaryV1, _ tree: JSONValue) -> Recommendation {
        Recommendation(
            day: summary.day, kind: d.kind, title: d.title, body: d.body,
            evidence: d.evidenceFieldPaths.map { EvidenceRef(summaryDay: summary.day, fieldPath: $0, value: tree.value(at: $0) ?? .null) },
            experiment: d.experiment, generator: generator, guardResult: result, provenance: summary.provenance)
    }

    /// Two notes with the same title (e.g. a rewrite that matches a template already present) collapse to one.
    private func dedupe(_ recs: [Recommendation]) -> [Recommendation] {
        var seen: Set<String> = []
        return recs.filter { seen.insert($0.title).inserted }
    }
}
