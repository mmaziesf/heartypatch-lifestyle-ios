import Foundation
import Testing
import HPLCore
import HPLStore
@testable import HPLPipeline

private let la = Calendar.hplLocal(TimeZone(identifier: "America/Los_Angeles")!)

private func agg(_ day: LocalDay, _ m: HealthMetric, _ w: AggregateWindow, q: String? = nil, _ s: AggregateStats) -> HealthAggregate {
    HealthAggregate(day: day, metric: m, window: w, qualifier: q, stats: s, tz: "America/Los_Angeles", computedAt: Date(timeIntervalSince1970: 0))
}

private func agg(_ day: LocalDay, _ m: HealthMetric, _ s: AggregateStats) -> HealthAggregate { agg(day, m, .day, s) }

@Suite struct SummaryBuilderTests {
    let today = LocalDay(string: "2026-10-10")!

    func history(days: Int) -> [HealthAggregate] {
        (1...days).flatMap { i -> [HealthAggregate] in
            let d = today.adding(days: -i, calendar: la)
            return [agg(d, .sleepAsleep, .night, AggregateStats(sum: 420 + Double(i % 3) * 10)),
                    agg(d, .steps, AggregateStats(sum: 9000)),
                    agg(d, .restingHeartRate, AggregateStats(mean: 55)),
                    agg(d, .hrvSDNN, .night, AggregateStats(median: Double(40 + i)))]
        }
    }

    @Test func deviceSummaryWithBaselinesIsSchemaShapedAndRunsThroughPipeline() async throws {
        let todayRows = [
            agg(today, .sleepAsleep, .night, AggregateStats(sum: 340)), agg(today, .sleepDeep, .night, AggregateStats(sum: 40)),
            agg(today, .sleepOnset, .night, AggregateStats(min: -25)), agg(today, .sleepWake, .night, AggregateStats(min: 395)),
            agg(today, .restingHeartRate, AggregateStats(mean: 61.04)), agg(today, .hrvSDNN, .night, AggregateStats(median: 30)),
            agg(today, .steps, AggregateStats(sum: 4210)), agg(today, .activeEnergy, AggregateStats(sum: 310.26)),
            agg(today, .standHours, AggregateStats(sum: 8)),
            agg(today, .workoutDuration, .workout, q: "running", AggregateStats(sum: 32, count: 1)),
            agg(today, .workoutAvgHeartRate, .workout, q: "running", AggregateStats(mean: 151.4)),
        ]
        let repo = InMemoryHealthAggregateRepository(history(days: 28) + todayRows)
        let s = try #require(try SummaryBuilder(aggregates: repo, calendar: la).build(day: today))

        #expect(s.provenance == .device); #expect(s.day == "2026-10-10"); #expect(s.dayOfWeek == "Sat")
        #expect(s.sleep?.totalMin == 340); #expect(s.sleep?.bedLocal == "23:35"); #expect(s.sleep?.wakeLocal == "06:35")
        #expect(s.sleep?.baseline28d?.totalMinMedian == 430)
        #expect(s.heart?.restingHR == 61); #expect(s.heart?.restingHR28dMedian == 55)
        #expect(s.heart?.hrvSDNNOvernightMedian == 30); #expect(s.heart?.hrv28dMedian == 54.5)
        #expect(s.activity?.steps == 4210); #expect(s.activity?.steps28dMedian == 9000); #expect(s.activity?.exerciseMin == nil)
        #expect(s.workouts == [.init(type: "running", durationMin: 32, avgHR: 151)])
        #expect(s.meals.isEmpty && s.labsRecent.isEmpty, "M1 never invents meals or labs")
        #expect(s.completeness == 0.83)

        let roundTrip = try HPLJSON.decoder.decode(DailySummaryV1.self, from: HPLJSON.encoder.encode(s))
        #expect(roundTrip == s)

        let recs = try await DailyPipeline().run(s)
        #expect(recs.contains { $0.title == "Shorter sleep than your recent typical" })
        #expect(recs.allSatisfy { $0.provenance == .device })
    }

    @Test func baselinesNeedSevenDaysAndEmptyDayIsNil() throws {
        let repo = InMemoryHealthAggregateRepository(history(days: 6) + [agg(today, .steps, AggregateStats(sum: 100))])
        let b = SummaryBuilder(aggregates: repo, calendar: la)
        let s = try #require(try b.build(day: today))
        #expect(s.activity?.steps28dMedian == nil); #expect(s.heart?.hrv28dP10 == nil)
        #expect(try b.build(day: today.adding(days: 1, calendar: la)) == nil, "no data is reported as no data, not zeros")
    }
}
