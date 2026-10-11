import Foundation
import Observation
import HPLCore
import HPLHealth
import HPLInference
import HPLPipeline

/// HealthKit wiring handed to the app model. `nil` services = no persistent store (e.g. launched while locked).
public struct HealthServices: Sendable {
    public let source: any HealthDataSource
    public let engine: HealthSyncEngine
    public let aggregates: any HealthAggregateRepository
    public let calendar: Calendar

    public init(source: any HealthDataSource, aggregates: any HealthAggregateRepository, syncState: any SyncStateRepository,
                calendar: Calendar = .hplLocal()) {
        self.source = source; self.aggregates = aggregates; self.calendar = calendar
        engine = HealthSyncEngine(source: source, aggregates: aggregates, state: syncState, calendar: calendar)
    }
}

public enum HealthStatus: Equatable, Sendable {
    /// HealthKit isn't available on this device (or no protected store this launch).
    case unavailable
    case notConnected
    case syncing(progress: Double?)
    case ready(lastSync: Date?)
    case failed
}

/// What Today is showing. Provenance is always explicit: synthetic fixture data is never presented as the user's.
public enum TodaySource: Equatable, Sendable { case syntheticFixture, device, noData }

/// One Today row: today's value vs the 28-day typical. `nil` value = no data (or access not granted).
public struct MetricRow: Identifiable, Equatable, Sendable {
    public var id: String { title }
    public var title: String
    public var value: String?
    public var typical: String?
    public var note: String?
}

/// App state. Platform-neutral so it is unit-tested on Linux and macOS.
@MainActor @Observable
public final class AppModel {
    public static let healthFamilies: Set<HealthSync.MetricFamily> = Set(HealthSync.MetricFamily.allCases)

    public private(set) var disclaimerAcknowledgedAt: Date?
    public private(set) var summary: DailySummaryV1?
    public private(set) var recommendations: [Recommendation] = []
    public private(set) var errorMessage: String?
    public private(set) var healthStatus: HealthStatus = .unavailable
    public private(set) var todaySource: TodaySource = .syntheticFixture
    public private(set) var healthPromptDismissed = false
    public let isDegraded: Bool

    private let consents: any ConsentRepository
    private let pipeline: DailyPipeline
    private let health: HealthServices?
    private let now: @Sendable () -> Date
    private var isSyncing = false
    private var observing = false

    public init(consents: any ConsentRepository, health: HealthServices? = nil, pipeline: DailyPipeline = DailyPipeline(),
                isDegraded: Bool = false, now: @escaping @Sendable () -> Date = Date.init) {
        self.consents = consents
        self.health = health
        self.pipeline = pipeline
        self.isDegraded = isDegraded
        self.now = now
        disclaimerAcknowledgedAt = try? consents.active(.disclaimer, version: Disclaimer.version)?.grantedAt
        if let health, health.source.isHealthDataAvailable {
            healthStatus = isHealthConnected ? .ready(lastSync: nil) : .notConnected
        }
    }

    public var needsDisclaimer: Bool { disclaimerAcknowledgedAt == nil }
    public var engineName: String { pipeline.engine.id }
    public var isHealthConnected: Bool { (try? consents.active(.healthkit, version: HealthConsent.version)) != nil }
    /// Onboarding step after the disclaimer (§9.2): offer Apple Health once; "Not now" leaves a card on Today.
    public var needsHealthPrompt: Bool { !needsDisclaimer && healthStatus == .notConnected && !healthPromptDismissed }

    public func acknowledgeDisclaimer() {
        let consent = Consent(scope: .disclaimer, version: Disclaimer.version, grantedAt: now())
        do {
            try consents.save(consent)
            disclaimerAcknowledgedAt = consent.grantedAt
        } catch {
            errorMessage = "Could not save acknowledgement."
        }
    }

    public func dismissHealthPrompt() { healthPromptDismissed = true }

    /// Asks HealthKit for read access, records the consent, backfills 90 days, then rebuilds Today.
    /// HealthKit never says whether read access was denied, so "connected" means "asked"; empty data shows the empty state.
    public func connectHealth() async {
        guard let health, health.source.isHealthDataAvailable else { return }
        healthPromptDismissed = true
        do {
            try await health.source.requestReadAuthorization(Self.healthFamilies)
            try consents.save(Consent(scope: .healthkit, version: HealthConsent.version, grantedAt: now()))
        } catch {
            healthStatus = .failed
            errorMessage = "Could not request Apple Health access."
            return
        }
        await startBackgroundObservers()
        await loadToday()
    }

    /// Today: the user's own HealthKit summary when connected; otherwise the labeled synthetic fixture.
    public func loadToday() async {
        guard let health, health.source.isHealthDataAvailable, isHealthConnected else {
            await loadFixture()
            return
        }
        await sync(health)
        do {
            let today = LocalDay(now(), calendar: health.calendar)
            if let s = try SummaryBuilder(aggregates: health.aggregates, calendar: health.calendar).build(day: today) {
                summary = s
                todaySource = .device
                recommendations = try await pipeline.run(s)
            } else {
                summary = nil
                recommendations = []
                todaySource = .noData
            }
        } catch {
            errorMessage = "Could not build today's notes."
        }
    }

    /// Foreground refresh (§5.1: background delivery is best-effort; recompute when the app is opened).
    public func refresh() async { await loadToday() }

    /// Registers HealthKit observer queries + background delivery. Call at launch so background wakes are handled.
    public func startBackgroundObservers() async {
        guard let health, health.source.isHealthDataAvailable, isHealthConnected, !observing else { return }
        observing = true
        let engine = health.engine
        let now = self.now
        try? await health.source.startObserving(ChangeFeed.allCases) {
            _ = try? await engine.syncIncremental(now: now())
        }
    }

    private func sync(_ health: HealthServices) async {
        guard !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }
        do {
            if try await health.engine.hasBackfilled() {
                healthStatus = .syncing(progress: nil)
                try await health.engine.syncIncremental(now: now())
            } else {
                healthStatus = .syncing(progress: 0)
                try await health.engine.backfill(now: now()) { [weak self] p in
                    Task { @MainActor in
                        if case .syncing = self?.healthStatus { self?.healthStatus = .syncing(progress: p) }
                    }
                }
            }
            healthStatus = .ready(lastSync: try await health.engine.lastSync())
        } catch {
            healthStatus = .failed
            errorMessage = "Could not read Apple Health. Showing the last synced data."
        }
    }

    private func loadFixture() async {
        do {
            let s = try SyntheticFixtures.dailySummaryD0()
            summary = s
            todaySource = .syntheticFixture
            recommendations = try await pipeline.run(s)
        } catch {
            errorMessage = "Could not build today's notes."
        }
    }

    /// Today vs 28-day typical (§11 M1: sleep / HR / HRV / activity).
    public var todayMetrics: [MetricRow] {
        let s = summary
        func dur(_ m: Int?) -> String? { m.map { "\($0 / 60)h \(String(format: "%02d", $0 % 60))m" } }
        func durD(_ m: Double?) -> String? { dur(m.map { Int($0.rounded()) }) }
        func num(_ v: Double?, _ unit: String) -> String? { v.map { "\(Int($0.rounded())) \(unit)" } }
        func steps(_ v: Double?) -> String? { v.map { Self.grouped(Int($0.rounded())) } }
        let sleepNote = [s?.sleep?.bedLocal, s?.sleep?.wakeLocal].compactMap { $0 }.joined(separator: " → ")
        return [
            MetricRow(title: "Sleep", value: dur(s?.sleep?.totalMin), typical: durD(s?.sleep?.baseline28d?.totalMinMedian),
                      note: sleepNote.isEmpty ? nil : sleepNote),
            MetricRow(title: "Resting heart rate", value: num(s?.heart?.restingHR, "bpm"), typical: num(s?.heart?.restingHR28dMedian, "bpm"), note: nil),
            MetricRow(title: "HRV (SDNN, overnight)", value: num(s?.heart?.hrvSDNNOvernightMedian, "ms"), typical: num(s?.heart?.hrv28dMedian, "ms"),
                      note: "Apple Watch samples HRV a few times a night; compare with your own typical, not other people."),
            MetricRow(title: "Steps", value: steps(s?.activity?.steps.map(Double.init)), typical: steps(s?.activity?.steps28dMedian),
                      note: todaySource == .device ? "So far today" : nil),
            MetricRow(title: "Active energy", value: num(s?.activity?.activeKcal, "kcal"), typical: nil, note: nil),
            MetricRow(title: "Exercise", value: s?.activity?.exerciseMin.map { "\($0) min" }, typical: nil, note: nil),
        ]
    }

    static func grouped(_ n: Int) -> String {
        let digits = String(abs(n))
        var out = ""
        for (i, ch) in digits.reversed().enumerated() {
            if i > 0, i % 3 == 0 { out.append(",") }
            out.append(ch)
        }
        return (n < 0 ? "-" : "") + String(out.reversed())
    }
}
