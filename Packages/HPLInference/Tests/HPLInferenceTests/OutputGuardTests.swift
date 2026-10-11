import Testing
import HPLCore
@testable import HPLInference

@Suite struct OutputGuardTests {
    let summary: JSONValue
    let guardrail = OutputGuard()

    init() throws { summary = try SyntheticFixtures.dailySummaryD0().jsonTree() }

    func draft(_ body: String, paths: [String] = ["sleep.total_min"]) -> RecommendationDraft {
        .init(kind: .observation, title: "t", body: body, evidenceFieldPaths: paths)
    }

    @Test func passesCleanTraceableCopy() {
        #expect(guardrail.check(draft("You slept 352 min vs a 28-day median of 431 min."), against: summary).result == .pass)
    }

    @Test(arguments: [
        "This suggests you have prediabetes.",
        "Your HRV pattern indicates AFib.",
        "Take 2000 IU vitamin D daily.",
        "Try magnesium 400mg before bed.",
        "Stop taking your medication.",
    ])
    func blocksMedicalLanguage(_ body: String) {
        #expect(guardrail.check(draft(body), against: summary).result == .blocked)
    }

    @Test func blocksHallucinatedNumbers() {
        let v = guardrail.check(draft("You slept 512 min."), against: summary)
        #expect(v.result == .blocked)
        #expect(v.reasons == ["untraceable number: 512.0"])
    }

    @Test func blocksUnresolvedOrMissingEvidence() {
        #expect(guardrail.check(draft("ok", paths: ["sleep.nope"]), against: summary).result == .blocked)
        #expect(guardrail.check(draft("ok", paths: []), against: summary).result == .blocked)
    }

    @Test func rulesEngineTemplatesPassGuard() async throws {
        let s = try SyntheticFixtures.dailySummaryD0()
        let hits = [
            RuleHit(id: "SLEEP_SHORT_VS_BASELINE", evidenceFieldPaths: ["sleep.total_min", "sleep.baseline_28d.total_min_median"]),
            RuleHit(id: "HRV_BELOW_P10", evidenceFieldPaths: ["heart.hrv_sdnn_ms_overnight_median", "heart.hrv_28d_p10"]),
            RuleHit(id: "LATE_MEAL_ALCOHOL", evidenceFieldPaths: ["meals.1.t_local", "meals.1.tags"]),
            RuleHit(id: "UNKNOWN_RULE", evidenceFieldPaths: []),
        ]
        let drafts = try await RulesOnlyEngine().generate(summary: s, ruleHits: hits)
        #expect(drafts.count == 3)
        for d in drafts { #expect(guardrail.check(d, against: summary).result == .pass, "\(d.title): \(guardrail.check(d, against: summary).reasons)") }
    }
}
