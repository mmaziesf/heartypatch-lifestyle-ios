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

    @Test func ordinaryWordsAreNotBlocked() {
        #expect(guardrail.check(draft("A brisk walk counts; steps were 4210."), against: summary).result == .pass)
    }

    @Test func experimentProposalsAreChecked() {
        func exp(_ intervention: String, _ days: Int, _ metric: String) -> RecommendationDraft {
            .init(kind: .experiment, title: "t", body: "You slept 352 min.", evidenceFieldPaths: ["sleep.total_min"],
                  experiment: .init(intervention: intervention, durationDays: days, metricFieldPath: metric))
        }
        #expect(guardrail.check(exp("Lights out earlier", 7, "sleep.total_min"), against: summary).result == .pass)
        #expect(guardrail.check(exp("Lights out earlier", 30, "sleep.total_min"), against: summary).result == .blocked)
        #expect(guardrail.check(exp("Lights out earlier", 14, "sleep.nope"), against: summary).result == .blocked)
        #expect(guardrail.check(exp("Lights out earlier", 14, "meals.1.tags"), against: summary).result == .blocked)
        #expect(guardrail.check(exp("Take melatonin before bed", 14, "sleep.total_min"), against: summary).result == .blocked)
        #expect(guardrail.check(exp("Sleep 45 minutes more", 14, "sleep.total_min"), against: summary).result == .blocked)
    }

    @Test func clinicianPromptMustBeFixedCopy() {
        let paths = ["labs_recent.0.analyte"]
        let fixed = RecommendationDraft(kind: .clinicianPrompt, title: "x", body: RuleTemplates.clinicianCopy, evidenceFieldPaths: paths)
        let written = RecommendationDraft(kind: .clinicianPrompt, title: "x", body: "Please see someone about this.", evidenceFieldPaths: paths)
        #expect(guardrail.check(fixed, against: summary).result == .pass)
        #expect(guardrail.check(written, against: summary).reasons == ["clinician prompt not fixed copy"])
    }

    @Test func numberOnlyFailuresAreFlaggedForRewrite() {
        #expect(guardrail.check(draft("You slept 512 min."), against: summary).failedOnlyOnNumbers)
        #expect(!guardrail.check(draft("You slept 512 min and may have apnea."), against: summary).failedOnlyOnNumbers)
    }

    @Test func everyRuleHasATemplate() {
        let ids = [RuleID.sleepShort, RuleID.deepSleepLow, RuleID.bedtimeLate, RuleID.hrvLow, RuleID.restingHRHigh, RuleID.stepsLow,
                   RuleID.stepsHigh, RuleID.noExercise, RuleID.hardWorkout, RuleID.lateMealAlcohol, RuleID.experimentActive,
                   RuleID.lowCompleteness, RuleID.clinicianLabCritical]
        #expect(Set(RuleTemplates.all.keys) == Set(ids))
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
