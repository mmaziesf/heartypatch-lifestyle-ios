import Foundation
import HPLCore

public struct SyncReport: Sendable, Equatable {
    public var recomputedDays: [LocalDay]
    public var aggregateCount: Int
    public var finishedAt: Date
}

/// Turns HealthKit data into per-day `HealthAggregate` rows (§5.1). Every pass recomputes whole days from HealthKit,
/// so results are idempotent and late data simply overwrites the day. Raw samples stay in HealthKit.
public actor HealthSyncEngine {
    public static let lastSyncKey = "sync.last"
    public static let backfillDoneKey = "sync.backfill_done"
    /// Recomputed on every incremental sync regardless of anchors (covers Watch→iPhone sync lag for high-volume types).
    public static let trailingDays = 3
    /// Deleted HealthKit samples carry no dates, so a deletion re-aggregates this many recent days.
    public static let deletionRecomputeDays = 30
    static let chunkDays = 14

    private let source: any HealthDataSource
    private let aggregates: any HealthAggregateRepository
    private let state: any SyncStateRepository
    private let calendar: Calendar

    public init(source: any HealthDataSource, aggregates: any HealthAggregateRepository, state: any SyncStateRepository,
                calendar: Calendar = .hplLocal()) {
        self.source = source; self.aggregates = aggregates; self.state = state; self.calendar = calendar
    }

    public func hasBackfilled() throws -> Bool { try state.date(for: Self.backfillDoneKey) != nil }
    public func lastSync() throws -> Date? { try state.date(for: Self.lastSyncKey) }

    /// First run: prime anchors at "now", then aggregate the last `days` days in chunks (newest first, so Today fills fast).
    @discardableResult
    public func backfill(days: Int = HealthSync.backfillDays, now: Date,
                         progress: (@Sendable (Double) -> Void)? = nil) async throws -> SyncReport {
        let today = LocalDay(now, calendar: calendar)
        let first = today.adding(days: -(days - 1), calendar: calendar)
        let since = first.start(in: calendar)
        // Anchors first: anything written while the backfill runs shows up in the next incremental sync.
        var anchors: [ChangeFeed: Data?] = [:]
        for feed in ChangeFeed.allCases {
            anchors[feed] = try await source.changes(feed, anchor: try state.anchor(for: feed.anchorKey), since: since).newAnchor
        }
        let all = first.through(today, calendar: calendar)
        var count = 0
        let chunks = stride(from: all.count, to: 0, by: -Self.chunkDays).map { Array(all[max(0, $0 - Self.chunkDays)..<$0]) }
        for (i, chunk) in chunks.enumerated() {
            count += try await recompute(chunk)
            progress?(Double(i + 1) / Double(chunks.count))
        }
        for (feed, anchor) in anchors { try state.setAnchor(anchor, for: feed.anchorKey) }
        try state.setDate(now, for: Self.backfillDoneKey)
        try state.setDate(now, for: Self.lastSyncKey)
        return SyncReport(recomputedDays: all, aggregateCount: count, finishedAt: now)
    }

    /// Foreground / observer-triggered sync: trailing days + any older days touched since the saved anchors.
    @discardableResult
    public func syncIncremental(now: Date) async throws -> SyncReport {
        let today = LocalDay(now, calendar: calendar)
        let floor = today.adding(days: -(HealthSync.backfillDays - 1), calendar: calendar)
        var dirty = Set(today.adding(days: -(Self.trailingDays - 1), calendar: calendar).through(today, calendar: calendar))
        var newAnchors: [ChangeFeed: Data?] = [:]
        for feed in ChangeFeed.allCases {
            let ch = try await source.changes(feed, anchor: try state.anchor(for: feed.anchorKey), since: floor.start(in: calendar))
            newAnchors[feed] = ch.newAnchor
            for r in ch.addedIntervals {
                if feed == .sleep {
                    dirty.insert(SleepAggregator.nightDay(forEnd: r.upperBound, calendar: calendar))
                } else {
                    for d in LocalDay(r.lowerBound, calendar: calendar).through(LocalDay(r.upperBound, calendar: calendar), calendar: calendar) {
                        dirty.insert(d)
                    }
                }
            }
            if ch.deletedCount > 0 {
                dirty.formUnion(today.adding(days: -(Self.deletionRecomputeDays - 1), calendar: calendar).through(today, calendar: calendar))
            }
        }
        let days = dirty.filter { $0 >= floor && $0 <= today }.sorted()
        var count = 0
        for run in Self.contiguousRuns(days, calendar: calendar) {
            for start in stride(from: 0, to: run.count, by: Self.chunkDays) {
                count += try await recompute(Array(run[start..<min(run.count, start + Self.chunkDays)]))
            }
        }
        // Anchors advance only after the recompute succeeded, so a failure retries the same changes next time.
        for (feed, anchor) in newAnchors { try state.setAnchor(anchor, for: feed.anchorKey) }
        try state.setDate(now, for: Self.lastSyncKey)
        return SyncReport(recomputedDays: days, aggregateCount: count, finishedAt: now)
    }

    /// Recomputes and replaces every aggregate for `days` (must be contiguous). Returns rows written.
    @discardableResult
    public func recompute(_ days: [LocalDay]) async throws -> Int {
        guard let first = days.first, let last = days.last else { return 0 }
        var rows = Rows(tz: calendar.timeZone.identifier, computedAt: Date())
        try await addQuantities(first...last, into: &rows)
        try await addSleepAndHRV(days, into: &rows)
        try await addCategoryEvents(first...last, into: &rows)
        try await addWorkouts(first...last, into: &rows)
        try aggregates.replace(days: days, with: rows.items)
        return rows.items.count
    }

    /// Accumulates aggregate rows for one recompute pass.
    struct Rows {
        let tz: String
        let computedAt: Date
        var items: [HealthAggregate] = []

        mutating func add(_ day: LocalDay, _ metric: HealthMetric, _ window: AggregateWindow, qualifier: String? = nil,
                          _ stats: AggregateStats, sources: [String] = []) {
            items.append(HealthAggregate(day: day, metric: metric, window: window, qualifier: qualifier, stats: stats,
                                         sourceBundleIDs: sources, tz: tz, computedAt: computedAt))
        }
    }

    private func addQuantities(_ range: ClosedRange<LocalDay>, into rows: inout Rows) async throws {
        for spec in QuantitySpec.all {
            for dq in try await source.dailyQuantities(spec, days: range, calendar: calendar) where range.contains(dq.day) {
                rows.add(dq.day, spec.metric, .day, dq.stats, sources: dq.sourceBundleIDs)
            }
        }
    }

    private func addSleepAndHRV(_ days: [LocalDay], into rows: inout Rows) async throws {
        guard let first = days.first, let last = days.last else { return }
        let range = first...last
        let window = SleepAggregator.fetchWindow(range, calendar: calendar)
        let nights = SleepAggregator.nights(try await source.sleepSegments(from: window.from, to: window.to), calendar: calendar)
            .filter { range.contains($0.key) }
        for n in nights.values {
            let src = [n.sourceBundleID]
            rows.add(n.day, .sleepAsleep, .night, AggregateStats(sum: Double(n.asleepMin)), sources: src)
            let stages: [(HealthMetric, Int?)] = [(.sleepInBed, n.inBedMin), (.sleepCore, n.coreMin), (.sleepDeep, n.deepMin),
                                                  (.sleepREM, n.remMin), (.sleepAwake, n.awakeMin)]
            for (metric, minutes) in stages {
                if let minutes { rows.add(n.day, metric, .night, AggregateStats(sum: Double(minutes)), sources: src) }
            }
            let midnight = n.day.start(in: calendar)
            if let on = n.onset { rows.add(n.day, .sleepOnset, .night, AggregateStats(min: (on.timeIntervalSince(midnight) / 60).rounded()), sources: src) }
            if let off = n.wake { rows.add(n.day, .sleepWake, .night, AggregateStats(min: (off.timeIntervalSince(midnight) / 60).rounded()), sources: src) }
        }
        let hrv = try await source.samples(.hrvSDNN, from: first.date(minutesFromMidnight: -24 * 60, calendar: calendar), to: last.end(in: calendar))
        for o in HRVAggregator.overnight(hrv, nights: nights, days: days, calendar: calendar) {
            rows.add(o.day, .hrvSDNN, .night, qualifier: o.qualifier, o.stats)
        }
    }

    /// Category event kind -> stored metric; `sumsMinutes` stores total duration instead of a count.
    private struct EventMapping { let kind: CategoryEventKind; let metric: HealthMetric; let sumsMinutes: Bool }
    private static let eventMappings = [
        EventMapping(kind: .standHour, metric: .standHours, sumsMinutes: false),
        EventMapping(kind: .mindfulSession, metric: .mindfulMinutes, sumsMinutes: true),
        EventMapping(kind: .highHeartRate, metric: .highHeartRateEvents, sumsMinutes: false),
        EventMapping(kind: .lowHeartRate, metric: .lowHeartRateEvents, sumsMinutes: false),
        EventMapping(kind: .irregularRhythm, metric: .irregularRhythmEvents, sumsMinutes: false),
    ]

    private func addCategoryEvents(_ range: ClosedRange<LocalDay>, into rows: inout Rows) async throws {
        let from = range.lowerBound.start(in: calendar), to = range.upperBound.end(in: calendar)
        for m in Self.eventMappings {
            let byDay = Dictionary(grouping: try await source.categoryEvents(m.kind, from: from, to: to)) { LocalDay($0.start, calendar: calendar) }
            for (day, evs) in byDay where range.contains(day) {
                let total = m.sumsMinutes ? evs.reduce(0) { $0 + $1.end.timeIntervalSince($1.start) / 60 } : Double(evs.count)
                rows.add(day, m.metric, .day, AggregateStats(sum: total.rounded(), count: evs.count))
            }
        }
    }

    /// Workouts grouped by start day and type; avg HR is duration-weighted across that type's sessions.
    private func addWorkouts(_ range: ClosedRange<LocalDay>, into rows: inout Rows) async throws {
        let workouts = try await source.workouts(from: range.lowerBound.start(in: calendar), to: range.upperBound.end(in: calendar))
        let groups = Dictionary(grouping: workouts) { "\(LocalDay($0.start, calendar: calendar))|\($0.type)" }
        for ws in groups.values {
            guard let w0 = ws.first else { continue }
            let day = LocalDay(w0.start, calendar: calendar)
            guard range.contains(day) else { continue }
            let mins = ws.map { $0.end.timeIntervalSince($0.start) / 60 }
            rows.add(day, .workoutDuration, .workout, qualifier: w0.type, AggregateStats(sum: mins.reduce(0, +).rounded(), count: ws.count),
                     sources: Array(Set(ws.map(\.sourceBundleID))).sorted())
            let withHR = zip(ws, mins).compactMap { w, m in w.avgHeartRate.map { (hr: $0, min: m) } }
            let weight = withHR.reduce(0) { $0 + $1.min }
            if weight > 0 {
                rows.add(day, .workoutAvgHeartRate, .workout, qualifier: w0.type,
                         AggregateStats(mean: withHR.reduce(0) { $0 + $1.hr * $1.min } / weight, count: withHR.count))
            }
        }
    }

    static func contiguousRuns(_ days: [LocalDay], calendar: Calendar) -> [[LocalDay]] {
        var runs: [[LocalDay]] = []
        for d in days.sorted() {
            if let prev = runs.last?.last, prev.adding(days: 1, calendar: calendar) == d { runs[runs.count - 1].append(d) } else { runs.append([d]) }
        }
        return runs
    }
}
