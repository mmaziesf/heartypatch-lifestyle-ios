import Foundation
import Testing
import HPLCore
import HPLInference
@testable import HPLPipeline

@Suite struct PipelineTests {
    @Test func fixtureProducesGuardedRecommendationsEndToEnd() async throws {
        let recs = try await DailyPipeline().run(SyntheticFixtures.dailySummaryD0())
        #expect(recs.map(\.title) == ["Shorter sleep than your recent typical", "Overnight HRV in your low band", "Late meal with alcohol"])
        let first = try #require(recs.first)
        #expect(first.body.hasPrefix("You slept 352 min vs your 28-day median of 431 min."))
        #expect(first.evidence.map(\.value) == [.number(352), .number(431)])
        #expect(first.generator.engine == .rules)
        #expect(recs.allSatisfy { $0.guardResult == .pass && $0.provenance == .syntheticFixture })
    }

    @Test func quietDayProducesNothing() async throws {
        var s = try SyntheticFixtures.dailySummaryD0()
        s.sleep?.totalMin = 430
        s.heart?.hrvSDNNOvernightMedian = 55
        s.meals = []
        #expect(RulesEngine.evaluate(s).isEmpty)
        #expect(try await DailyPipeline().run(s).isEmpty)
    }

    @Test func unavailableEngineFallsBackToRules() async throws {
        struct OfflineEngine: InsightEngine {
            let id = "offline"
            let generator = Generator(engine: .fm, promptVersion: "test")
            func isAvailable() async -> EngineAvailability { .unavailable(reason: "Apple Intelligence off") }
            func generate(summary: DailySummaryV1, ruleHits: [RuleHit]) async throws -> [RecommendationDraft] { Issue.record("must not run"); return [] }
        }
        let recs = try await DailyPipeline(engine: OfflineEngine()).run(SyntheticFixtures.dailySummaryD0())
        #expect(!recs.isEmpty && recs.allSatisfy { $0.generator.engine == .rules })
    }

    @Test func guardDropsBadEngineOutput() async throws {
        struct RogueEngine: InsightEngine {
            let id = "rogue"
            let generator = Generator(engine: .mlx, promptVersion: "test")
            func isAvailable() async -> EngineAvailability { .available }
            func generate(summary: DailySummaryV1, ruleHits: [RuleHit]) async throws -> [RecommendationDraft] {
                [.init(kind: .observation, title: "Bad", body: "You may be prediabetic.", evidenceFieldPaths: ["labs_recent.0.value"]),
                 .init(kind: .observation, title: "Good", body: "Steps were 4210.", evidenceFieldPaths: ["activity.steps"])]
            }
        }
        #expect(try await DailyPipeline(engine: RogueEngine()).run(SyntheticFixtures.dailySummaryD0()).map(\.title) == ["Good"])
    }

    @Test func minimalFixtureIsSafe() async throws {
        let json = #"{"schema":"hpl.daily_summary.v1","provenance":"synthetic_fixture","day":"D0","day_of_week":"Sat","#
            + #""workouts":[],"meals":[],"labs_recent":[],"rule_hits":[],"active_experiments":[],"completeness":0}"#
        let s = try HPLJSON.decoder.decode(DailySummaryV1.self, from: Data(json.utf8))
        #expect(try await DailyPipeline().run(s).isEmpty)
    }
}
