import Foundation
import Testing
import HPLCore
import HPLInference
@testable import HPLPipeline

private actor HitRecorder {
    var seen: [[String]] = []
    func record(_ ids: [String]) { seen.append(ids) }
}

@Suite struct RulesEngineTests {
    @Test func atLeastTenRules() { #expect(RulesEngine.rules.count >= 10) }

    @Test(arguments: [
        (1, RuleID.sleepShort), (1, RuleID.deepSleepLow), (1, RuleID.bedtimeLate), (2, RuleID.hrvLow), (3, RuleID.restingHRHigh),
        (4, RuleID.lateMealAlcohol), (5, RuleID.hardWorkout), (6, RuleID.stepsLow), (7, RuleID.stepsHigh), (8, RuleID.noExercise),
        (9, RuleID.lowCompleteness), (3, RuleID.clinicianLabCritical), (1, RuleID.experimentActive),
    ])
    func scenarioTriggersRule(index: Int, rule: String) {
        #expect(RulesEngine.evaluate(EvalFixtures.make(index).summary).map(\.id).contains(rule))
    }

    @Test func quietFixtureTriggersNoBaselineRules() {
        let ids = RulesEngine.evaluate(EvalFixtures.make(0).summary).map(\.id)
        #expect(ids.isEmpty)
    }

    @Test func fixturesAreDeterministicAndSynthetic() {
        let a = EvalFixtures.all(), b = EvalFixtures.all()
        #expect(a.count == 50)
        #expect(a.map(\.summary) == b.map(\.summary))
        #expect(a.allSatisfy { $0.summary.provenance == .syntheticFixture })
        #expect(a.filter(\.expectsClinicianPrompt).count >= 5 && a.filter(\.isAdversarial).count >= 5)
    }
}

@Suite struct PipelineM3Tests {
    @Test func clinicianPromptIsFixedFirstAndNeverSentToTheModel() async throws {
        let recorder = HitRecorder()
        let engine = ScriptedInsightEngine { _, input in
            await recorder.record(input.ruleHitIDs)
            return #"{"notes":[]}"#
        }
        let fixture = EvalFixtures.make(3)
        let report = try await DailyPipeline(engine: engine).runDetailed(fixture.summary)
        #expect(report.recommendations.first?.kind == .clinicianPrompt)
        #expect(report.recommendations.first?.generator.engine == .rules)
        #expect(await recorder.seen.flatMap { $0 }.allSatisfy { !RuleID.isClinicianPrompt($0) })
        #expect(await !recorder.seen.isEmpty)
    }

    @Test func engineErrorFallsBackToRules() async throws {
        let report = try await DailyPipeline(engine: ScriptedInsightEngine(respond: MockLLM.broken)).runDetailed(SyntheticFixtures.dailySummaryD0())
        #expect(report.engineID == "rules-only")
        #expect(report.fallbackReason?.contains("schemaInvalid") == true)
        #expect(!report.recommendations.isEmpty && report.recommendations.allSatisfy { $0.generator.engine == .rules })
    }

    @Test func unavailableEngineReportsReason() async throws {
        let engine = ScriptedInsightEngine(availability: .unavailable(reason: "Apple Intelligence is turned off")) { _, _ in
            Issue.record("must not run")
            return ""
        }
        let report = try await DailyPipeline(engine: engine).runDetailed(SyntheticFixtures.dailySummaryD0())
        #expect(report.fallbackReason == "Apple Intelligence is turned off")
    }

    @Test func hallucinatedNumberIsRewrittenWithTheRuleTemplate() async throws {
        let engine = ScriptedInsightEngine { _, _ in
            #"{"notes":[{"kind":"observation","title":"Short night","body":"You slept 300 min.","evidence":["sleep.total_min"]}]}"#
        }
        let recs = try await DailyPipeline(engine: engine).run(SyntheticFixtures.dailySummaryD0())
        let first = try #require(recs.first)
        #expect(first.guardResult == .rewritten)
        #expect(first.title == "Shorter sleep than your recent typical")
        #expect(first.generator.engine == .rules)
    }

    @Test func carefulModelNotesPassThroughWithExperiments() async throws {
        let recs = try await DailyPipeline(engine: ScriptedInsightEngine(respond: MockLLM.careful)).run(SyntheticFixtures.dailySummaryD0())
        #expect(recs.count == 2) // late meal isn't covered by this mock
        #expect(recs.allSatisfy { $0.guardResult == .pass && $0.generator.engine == .mlx })
        #expect(recs.first?.experiment?.metricFieldPath == "sleep.total_min")
    }
}

@Suite struct EvalHarnessTests {
    @Test func rulesOnlyMeetsTheM3Gate() async throws {
        let r = try await EvalHarness(pipeline: DailyPipeline()).run()
        #expect(r.fixtures == 50)
        #expect(r.meetsM3Gate, "\(r.gateFailures)")
        #expect(r.numericTraceableRate == 1)
        #expect(r.notesShown > 50)
        #expect(r.clinicianExpected > 0 && r.clinicianShownFirst == r.clinicianExpected)
    }

    @Test func carefulModelMeetsTheGate() async throws {
        let r = try await EvalHarness(pipeline: DailyPipeline(engine: ScriptedInsightEngine(respond: MockLLM.careful))).run()
        #expect(r.meetsM3Gate, "\(r.gateFailures)")
        #expect(r.fallbacks == 0 && r.draftsBlocked == 0)
    }

    /// The harness must catch a bad model, while the guard keeps the shipped output clean regardless.
    @Test func sloppyModelFailsTheGateButFinalOutputStaysClean() async throws {
        let pipeline = DailyPipeline(engine: ScriptedInsightEngine(respond: MockLLM.sloppy))
        let r = try await EvalHarness(pipeline: pipeline).run()
        #expect(!r.meetsM3Gate)
        #expect(r.numericTraceableRate < 0.95)
        #expect(r.finalBlocklistHits == 0)
        #expect(r.draftsBlocked > 0 && r.notesRewritten > 0)
        for f in EvalFixtures.all() {
            let tree = try f.summary.jsonTree()
            for rec in try await pipeline.run(f.summary) {
                #expect(OutputGuard().untraceableNumbers(in: rec.title + " " + rec.body, against: tree).isEmpty)
            }
        }
    }

    @Test func brokenModelIsScoredAsSchemaInvalidAndFallsBack() async throws {
        let r = try await EvalHarness(pipeline: DailyPipeline(engine: ScriptedInsightEngine(respond: MockLLM.broken))).run()
        #expect(r.schemaValidRate == 0 && r.fallbacks == 50)
        #expect(r.finalBlocklistHits == 0 && r.notesShown > 0)
    }

    #if canImport(FoundationModels)
    /// Runs only where Apple Intelligence is actually available (a real device or eligible Mac); CI runners skip it.
    @Test func foundationModelsEval() async throws {
        guard #available(iOS 26.0, macOS 26.0, *) else { return }
        let engine = FoundationModelsEngine()
        guard await engine.isAvailable() == .available else { return }
        let r = try await EvalHarness(pipeline: DailyPipeline(engine: engine)).run()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("hpl-eval-\(engine.id).json")
        try HPLJSON.encoder.encode(r).write(to: url)
        #expect(r.meetsM3Gate, "\(r.gateFailures) — report at \(url.path)")
    }
    #endif
}
