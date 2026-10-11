import Foundation
import Testing
import HPLCore
import HPLStore
@testable import HPLPipeline

private let la = Calendar.hplLocal(TimeZone(identifier: "America/Los_Angeles")!)

@Suite struct MealSummaryTests {
    let day = LocalDay(string: "2026-10-10")!
    func at(_ h: Int, _ m: Int, _ d: LocalDay? = nil) -> Date { (d ?? day).date(minutesFromMidnight: h * 60 + m, calendar: la) }
    func meal(_ date: Date, _ status: MealLog.Status, name: String = "secret dish name", tags: [String] = []) -> MealLog {
        MealLog(startedAt: date, tz: "America/Los_Angeles", items: [MealItem(name: name, kcalEst: 500)], tags: tags, status: status,
                source: .glasses, producer: "glance", processing: .onDevice, updatedAt: date)
    }

    @Test func labelsByLocalTime() {
        #expect(MealSummary.label(minuteOfDay: 7 * 60) == "breakfast")
        #expect(MealSummary.label(minuteOfDay: 13 * 60) == "lunch")
        #expect(MealSummary.label(minuteOfDay: 19 * 60) == "dinner")
        #expect(MealSummary.label(minuteOfDay: 16 * 60) == "snack")
        #expect(MealSummary.label(minuteOfDay: 23 * 60) == "snack")
    }

    @Test func onlyConfirmedMealsOfTheDayWithDerivedTagsAndNoFreeText() throws {
        let repo = KeyedMealRepository.inMemory()
        try repo.save(meal(at(8, 5), .confirmed, tags: ["home-cooked"]))
        try repo.save(meal(at(21, 40), .confirmed))
        try repo.save(meal(at(13, 0), .pending))
        try repo.save(meal(at(12, 0), .rejected))
        try repo.save(meal(at(12, 0, day.adding(days: -1, calendar: la)), .confirmed))
        try repo.save(LifestyleLog(id: "a", occurredAt: at(22, 30), tz: "America/Los_Angeles", kind: .alcohol))

        let aggregates = InMemoryHealthAggregateRepository([
            HealthAggregate(day: day, metric: .steps, window: .day, stats: AggregateStats(sum: 5000), tz: "America/Los_Angeles", computedAt: Date()),
        ])
        let s = try #require(try SummaryBuilder(aggregates: aggregates, meals: repo, calendar: la).build(day: day))
        #expect(s.meals == [.init(tLocal: "08:05", label: "breakfast", tags: ["home-cooked"]),
                            .init(tLocal: "21:40", label: "dinner", tags: ["late", "alcohol"])])
        let json = String(bytes: try HPLJSON.encoder.encode(s), encoding: .utf8) ?? ""
        #expect(!json.contains("secret dish") && !json.contains("glance") && !json.contains("kcal_est"))
        #expect(RulesEngine.evaluate(s).contains { $0.id == RuleID.lateMealAlcohol })
    }
}
