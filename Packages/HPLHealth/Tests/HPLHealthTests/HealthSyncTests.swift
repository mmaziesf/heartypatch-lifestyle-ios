import Foundation
import Testing
import HPLCore
import HPLStore
@testable import HPLHealth

let la = Calendar.hplLocal(TimeZone(identifier: "America/Los_Angeles")!)

func at(_ day: String, _ hhmm: String, _ cal: Calendar = la) -> Date {
    let p = hhmm.split(separator: ":").compactMap { Int($0) }
    return LocalDay(string: day)!.date(minutesFromMidnight: p[0] * 60 + p[1], calendar: cal)
}

func seg(_ d0: String, _ t0: String, _ d1: String, _ t1: String, _ stage: SleepStage, src: String = "watch", watch: Bool = true) -> SleepSegment {
    SleepSegment(start: at(d0, t0), end: at(d1, t1), stage: stage, sourceBundleID: src, isWatch: watch)
}

@Test func metricFamiliesDeclared() { #expect(HealthSync.MetricFamily.allCases.count == 5) }

@Suite struct LocalDayTests {
    @Test func dstSpringForwardDayIs23Hours() {
        let d = LocalDay(string: "2026-03-08")!
        #expect(d.end(in: la).timeIntervalSince(d.start(in: la)) == 23 * 3600)
        #expect(d.adding(days: 1, calendar: la).description == "2026-03-09")
        #expect(d.weekdayAbbrev(calendar: la) == "Sun")
    }

    @Test func sameInstantIsDifferentDayInDifferentZones() {
        let instant = at("2026-10-10", "22:30") // 05:30 UTC on the 11th
        #expect(LocalDay(instant, calendar: la).description == "2026-10-10")
        #expect(LocalDay(instant, calendar: .hplLocal(TimeZone(identifier: "UTC")!)).description == "2026-10-11")
    }

    @Test func codableAsISODate() throws {
        let d = try HPLJSON.decoder.decode([LocalDay].self, from: Data(#"["2026-01-31"]"#.utf8))
        #expect(d == [LocalDay(year: 2026, month: 1, day: 31)])
        #expect(LocalDay(string: "2026-13-01") == nil)
    }
}

@Suite struct StatsTests {
    @Test func percentilesMatchNumpyLinear() {
        let s = AggregateStats.of([10, 20, 30, 40, 50])!
        #expect(s.median == 30); #expect(s.p10 == 14); #expect(s.p90 == 46); #expect(s.count == 5); #expect(s.sum == 150)
        #expect(AggregateStats.of([]) == nil, "no data never becomes zero")
    }
}

@Suite struct SleepAggregatorTests {
    @Test func nightAssignedToWakeDayWithStageTotals() {
        let segs = [
            seg("2026-10-09", "23:30", "2026-10-10", "00:00", .inBed),
            seg("2026-10-09", "23:40", "2026-10-10", "01:40", .core),
            seg("2026-10-10", "01:40", "2026-10-10", "02:40", .deep),
            seg("2026-10-10", "02:40", "2026-10-10", "02:55", .awake),
            seg("2026-10-10", "02:55", "2026-10-10", "04:25", .rem),
            seg("2026-10-10", "04:25", "2026-10-10", "07:05", .core),
        ]
        let n = SleepAggregator.nights(segs, calendar: la)[LocalDay(string: "2026-10-10")!]!
        #expect(n.asleepMin == 120 + 60 + 90 + 160)
        #expect(n.deepMin == 60); #expect(n.remMin == 90); #expect(n.coreMin == 280); #expect(n.awakeMin == 15)
        #expect(n.onset == at("2026-10-09", "23:40")); #expect(n.wake == at("2026-10-10", "07:05"))
    }

    @Test func watchWinsOverIPhoneInsteadOfDoubleCounting() {
        let segs = [
            seg("2026-10-09", "23:00", "2026-10-10", "07:00", .asleepUnspecified, src: "com.third.party", watch: false),
            seg("2026-10-10", "00:00", "2026-10-10", "06:00", .core),
        ]
        let n = SleepAggregator.nights(segs, calendar: la)[LocalDay(string: "2026-10-10")!]!
        #expect(n.asleepMin == 360); #expect(n.sourceBundleID == "watch")
    }

    @Test func overlappingSegmentsFromOneSourceAreUnioned() {
        let segs = [seg("2026-10-10", "01:00", "2026-10-10", "03:00", .core), seg("2026-10-10", "02:00", "2026-10-10", "04:00", .core)]
        #expect(SleepAggregator.nights(segs, calendar: la)[LocalDay(string: "2026-10-10")!]?.asleepMin == 180)
    }

    @Test func eveningNapAfterBoundaryGoesToNextDayAndInBedOnlyIsNoNight() {
        let nap = [seg("2026-10-10", "18:30", "2026-10-10", "19:00", .asleepUnspecified)]
        #expect(SleepAggregator.nights(nap, calendar: la).keys.map(\.description) == ["2026-10-11"])
        let inBedOnly = [seg("2026-10-09", "23:00", "2026-10-10", "07:00", .inBed, src: "phone", watch: false)]
        #expect(SleepAggregator.nights(inBedOnly, calendar: la).isEmpty)
    }
}

@Suite struct HRVAggregatorTests {
    @Test func overnightMedianUsesSleepWindowElseLabeledFallback() {
        let day = LocalDay(string: "2026-10-10")!
        let night = SleepAggregator.nights([seg("2026-10-09", "23:00", "2026-10-10", "07:00", .core)], calendar: la)
        let samples = [at("2026-10-09", "21:00"), at("2026-10-10", "01:00"), at("2026-10-10", "03:00"), at("2026-10-10", "05:00")]
            .enumerated().map { i, t in TimedValue(start: t, end: t, value: [99.0, 40, 50, 60][i]) }
        let r = HRVAggregator.overnight(samples, nights: night, days: [day], calendar: la)
        #expect(r.first?.stats.median == 50); #expect(r.first?.qualifier == nil)
        let fb = HRVAggregator.overnight(samples, nights: [:], days: [day], calendar: la)
        #expect(fb.first?.qualifier == HRVAggregator.fallbackQualifier)
        #expect(fb.first?.stats.median == 50, "fallback window is 22:00-10:00, so the 21:00 reading is excluded")
    }
}

@Suite struct HealthSyncEngineTests {
    struct Harness {
        let engine: HealthSyncEngine
        let repo: InMemoryHealthAggregateRepository
        let state: InMemorySyncStateRepository
    }

    func engine(_ src: FakeHealthDataSource) -> Harness {
        let repo = InMemoryHealthAggregateRepository(), state = InMemorySyncStateRepository()
        return Harness(engine: HealthSyncEngine(source: src, aggregates: repo, state: state, calendar: la), repo: repo, state: state)
    }

    @Test func backfillStoresAggregatesOnlyForDaysWithDataAndPrimesAnchors() async throws {
        let src = FakeHealthDataSource()
        let today = LocalDay(string: "2026-10-10")!
        src.steps = [today: 8123, today.adding(days: -40, calendar: la): 5000, today.adding(days: -120, calendar: la): 1]
        src.sleep = [seg("2026-10-09", "23:00", "2026-10-10", "06:30", .core)]
        src.hrv = [TimedValue(start: at("2026-10-10", "03:00"), end: at("2026-10-10", "03:01"), value: 47)]
        src.workoutList = [WorkoutRecord(start: at("2026-10-10", "08:00"), end: at("2026-10-10", "08:30"), type: "running", avgHeartRate: 150)]
        let h = engine(src); let (eng, repo, state) = (h.engine, h.repo, h.state)

        let report = try await eng.backfill(days: 90, now: at("2026-10-10", "12:00"))
        #expect(report.recomputedDays.count == 90)
        let rows = try repo.aggregates(from: today.adding(days: -200, calendar: la), through: today)
        #expect(rows.filter { $0.metric == .steps }.count == 2, "the day outside the 90-day window is not stored")
        let mine = try repo.aggregates(on: today)
        #expect(mine.first { $0.metric == .steps }?.stats.sum == 8123)
        #expect(mine.first { $0.metric == .sleepAsleep }?.stats.sum == 450)
        #expect(mine.first { $0.metric == .hrvSDNN && $0.window == .night }?.stats.median == 47)
        #expect(mine.first { $0.metric == .workoutDuration }?.qualifier == "running")
        #expect(mine.allSatisfy { $0.tz == "America/Los_Angeles" })
        #expect(try state.anchor(for: ChangeFeed.sleep.anchorKey) != nil)
        #expect(try await eng.hasBackfilled())
    }

    @Test func emptyHealthKitProducesNoRows() async throws {
        let h = engine(FakeHealthDataSource()); let (eng, repo) = (h.engine, h.repo)
        try await eng.backfill(days: 30, now: at("2026-10-10", "12:00"))
        #expect(try repo.aggregates(from: LocalDay(string: "2026-01-01")!, through: LocalDay(string: "2026-12-31")!).isEmpty)
    }

    @Test func incrementalRecomputesTrailingDaysPlusAnchoredOldDay() async throws {
        let src = FakeHealthDataSource()
        let h = engine(src); let (eng, repo) = (h.engine, h.repo)
        try await eng.backfill(days: 90, now: at("2026-10-10", "12:00"))

        // A sleep night ending Oct 1 synced late, plus new steps today.
        src.sleep = [seg("2026-09-30", "23:00", "2026-10-01", "07:00", .core)]
        src.steps = [LocalDay(string: "2026-10-10")!: 4000]
        src.pendingChanges[.sleep] = AnchoredChanges(addedIntervals: [at("2026-09-30", "23:00")...at("2026-10-01", "07:00")], newAnchor: nil)
        let r = try await eng.syncIncremental(now: at("2026-10-10", "18:00"))
        #expect(r.recomputedDays.map(\.description) == ["2026-10-01", "2026-10-08", "2026-10-09", "2026-10-10"])
        #expect(try repo.aggregates(on: LocalDay(string: "2026-10-01")!).first { $0.metric == .sleepAsleep }?.stats.sum == 480)
        #expect(try repo.aggregates(on: LocalDay(string: "2026-10-10")!).first { $0.metric == .steps }?.stats.sum == 4000)
    }

    @Test func deletionRecomputesAndDropsStaleRows() async throws {
        let src = FakeHealthDataSource()
        let day = LocalDay(string: "2026-09-20")!
        src.steps = [day: 7000]
        let h = engine(src); let (eng, repo) = (h.engine, h.repo)
        try await eng.backfill(days: 90, now: at("2026-10-10", "12:00"))
        #expect(try repo.aggregates(on: day).count == 1)

        src.steps = [:]
        src.pendingChanges[.steps] = AnchoredChanges(deletedCount: 1, newAnchor: nil)
        let r = try await eng.syncIncremental(now: at("2026-10-10", "13:00"))
        #expect(r.recomputedDays.count == HealthSyncEngine.deletionRecomputeDays)
        #expect(try repo.aggregates(on: day).isEmpty, "deleted HealthKit data disappears from the store")
    }
}
