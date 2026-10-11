import Foundation
import Testing
import HPLCore
import HPLStore
import HPLHealth
@testable import HPLUI

/// Minimal HealthKit stand-in: steps + resting HR for given days, nothing else.
final class StubHealthSource: HealthDataSource, @unchecked Sendable {
    var available: Bool
    var steps: [LocalDay: Double]
    private(set) var authRequests = 0
    init(available: Bool = true, steps: [LocalDay: Double] = [:]) { self.available = available; self.steps = steps }

    var isHealthDataAvailable: Bool { available }
    func requestReadAuthorization(_ families: Set<HealthSync.MetricFamily>) async throws { authRequests += 1 }
    func dailyQuantities(_ spec: QuantitySpec, days: ClosedRange<LocalDay>, calendar: Calendar) async throws -> [DailyQuantity] {
        spec.metric == .steps ? steps.filter { days.contains($0.key) }.map { DailyQuantity(day: $0.key, stats: AggregateStats(sum: $0.value)) } : []
    }
    func samples(_ metric: HealthMetric, from: Date, to: Date) async throws -> [TimedValue] { [] }
    func sleepSegments(from: Date, to: Date) async throws -> [SleepSegment] { [] }
    func categoryEvents(_ kind: CategoryEventKind, from: Date, to: Date) async throws -> [TimedValue] { [] }
    func workouts(from: Date, to: Date) async throws -> [WorkoutRecord] { [] }
    func changes(_ feed: ChangeFeed, anchor: Data?, since: Date) async throws -> AnchoredChanges { AnchoredChanges(newAnchor: Data([1])) }
    func startObserving(_ feeds: [ChangeFeed], handler: @escaping @Sendable () async -> Void) async throws {}
}

private let laCal = Calendar.hplLocal(TimeZone(identifier: "America/Los_Angeles")!)
private let noonLA = LocalDay(string: "2026-10-10")!.date(minutesFromMidnight: 720, calendar: laCal)

@MainActor @Suite struct AppModelTests {
    static let la = laCal
    static let noon = noonLA

    func services(_ src: StubHealthSource) -> HealthServices {
        HealthServices(source: src, aggregates: InMemoryHealthAggregateRepository(), syncState: InMemorySyncStateRepository(), calendar: Self.la)
    }

    @Test func disclaimerGateThenFixtureRecommendationOnToday() async {
        let repo = InMemoryConsentRepository()
        let model = AppModel(consents: repo, now: { Date(timeIntervalSince1970: 1_791_000_000) })
        #expect(model.needsDisclaimer)

        model.acknowledgeDisclaimer()
        #expect(!model.needsDisclaimer)
        #expect(AppModel(consents: repo).needsDisclaimer == false, "acknowledgement persists for the next launch")

        await model.loadToday()
        #expect(model.summary?.provenance == .syntheticFixture)
        #expect(model.todaySource == .syntheticFixture)
        #expect(model.healthStatus == .unavailable)
        #expect(model.recommendations.first?.title == "Shorter sleep than your recent typical")
        #expect(model.errorMessage == nil)
    }

    @Test func connectHealthBackfillsAndShowsDeviceDataVsBaseline() async {
        var steps: [LocalDay: Double] = [:]
        let today = LocalDay(string: "2026-10-10")!
        for i in 1...10 { steps[today.adding(days: -i, calendar: Self.la)] = 9000 }
        steps[today] = 4210
        let src = StubHealthSource(steps: steps)
        let consents = InMemoryConsentRepository()
        let model = AppModel(consents: consents, health: services(src), now: { noonLA })
        model.acknowledgeDisclaimer()
        #expect(model.needsHealthPrompt)

        await model.connectHealth()
        #expect(src.authRequests == 1)
        #expect(!model.needsHealthPrompt)
        #expect(model.todaySource == .device)
        #expect(model.summary?.provenance == .device)
        #expect(model.healthStatus == .ready(lastSync: Self.noon))
        let stepsRow = model.todayMetrics.first { $0.title == "Steps" }
        #expect(stepsRow?.value == "4,210"); #expect(stepsRow?.typical == "9,000")
        #expect(model.todayMetrics.first { $0.title == "Sleep" }?.value == nil, "missing metrics show as no data, not zero")
        #expect((try? consents.active(.healthkit, version: HealthConsent.version)) != nil)
    }

    @Test func connectedButEmptyHealthShowsNoDataNotFixture() async {
        let model = AppModel(consents: InMemoryConsentRepository(), health: services(StubHealthSource()), now: { noonLA })
        model.acknowledgeDisclaimer()
        await model.connectHealth()
        #expect(model.todaySource == .noData)
        #expect(model.summary == nil)
        #expect(model.recommendations.isEmpty)
    }

    @Test func notNowKeepsFixtureWithConnectCard() async {
        let model = AppModel(consents: InMemoryConsentRepository(), health: services(StubHealthSource()), now: { noonLA })
        model.acknowledgeDisclaimer()
        model.dismissHealthPrompt()
        #expect(!model.needsHealthPrompt)
        await model.loadToday()
        #expect(model.healthStatus == .notConnected)
        #expect(model.todaySource == .syntheticFixture)
    }

    @Test func groupedNumbers() { #expect(AppModel.grouped(1234567) == "1,234,567"); #expect(AppModel.grouped(12) == "12") }
}
