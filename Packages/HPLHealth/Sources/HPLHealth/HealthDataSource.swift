import Foundation
import HPLCore

/// One day's statistics for a quantity metric, as computed by the platform (never from fabricated samples).
public struct DailyQuantity: Sendable, Equatable {
    public var day: LocalDay
    public var stats: AggregateStats
    public var sourceBundleIDs: [String]
    public init(day: LocalDay, stats: AggregateStats, sourceBundleIDs: [String] = []) {
        self.day = day; self.stats = stats; self.sourceBundleIDs = sourceBundleIDs
    }
}

/// A transient sample used only inside an aggregation pass; never persisted.
public struct TimedValue: Sendable, Equatable {
    public var start: Date
    public var end: Date
    public var value: Double
    public var sourceBundleID: String
    public init(start: Date, end: Date, value: Double, sourceBundleID: String = "") {
        self.start = start; self.end = end; self.value = value; self.sourceBundleID = sourceBundleID
    }
}

public enum SleepStage: String, Sendable, CaseIterable { case inBed, asleepUnspecified, core, deep, rem, awake
    public var isAsleep: Bool { self == .asleepUnspecified || self == .core || self == .deep || self == .rem }
}

public struct SleepSegment: Sendable, Equatable {
    public var start: Date
    public var end: Date
    public var stage: SleepStage
    public var sourceBundleID: String
    /// Recorded by an Apple Watch (preferred when sources overlap, §5.1).
    public var isWatch: Bool
    public init(start: Date, end: Date, stage: SleepStage, sourceBundleID: String, isWatch: Bool) {
        self.start = start; self.end = end; self.stage = stage; self.sourceBundleID = sourceBundleID; self.isWatch = isWatch
    }
}

public enum CategoryEventKind: String, Sendable, CaseIterable {
    case standHour, mindfulSession, highHeartRate, lowHeartRate, irregularRhythm
}

public struct WorkoutRecord: Sendable, Equatable {
    public var start: Date
    public var end: Date
    /// DailySummary v1 workout type: running, cycling, strength, walking, yoga, swimming, hiit, other.
    public var type: String
    public var avgHeartRate: Double?
    public var sourceBundleID: String
    public init(start: Date, end: Date, type: String, avgHeartRate: Double?, sourceBundleID: String = "") {
        self.start = start; self.end = end; self.type = type; self.avgHeartRate = avgHeartRate; self.sourceBundleID = sourceBundleID
    }
}

/// Low-volume sample types tracked with anchored queries so late or back-dated data (a night synced at noon,
/// a manually added workout) re-aggregates the right older day. High-volume types (heart rate, energy) are covered
/// by always recomputing the trailing window on each sync instead of anchoring millions of samples.
public enum ChangeFeed: String, Sendable, CaseIterable {
    case sleep, workouts, hrv, restingHeartRate, steps, bodyMass, vo2Max
    public var anchorKey: String { "anchor.\(rawValue)" }
}

public struct AnchoredChanges: Sendable {
    /// (start, end) of added samples. Deleted samples carry no dates in HealthKit, hence `deletedCount`.
    public var addedIntervals: [ClosedRange<Date>]
    public var deletedCount: Int
    public var newAnchor: Data?
    public init(addedIntervals: [ClosedRange<Date>] = [], deletedCount: Int = 0, newAnchor: Data?) {
        self.addedIntervals = addedIntervals; self.deletedCount = deletedCount; self.newAnchor = newAnchor
    }
}

/// The HealthKit boundary. `HealthKitDataSource` implements it on Apple platforms; tests use fakes.
public protocol HealthDataSource: Sendable {
    var isHealthDataAvailable: Bool { get }
    /// Read-only authorization. HealthKit never reveals whether read access was denied (§5.1), so this can't either.
    func requestReadAuthorization(_ families: Set<HealthSync.MetricFamily>) async throws
    func dailyQuantities(_ spec: QuantitySpec, days: ClosedRange<LocalDay>, calendar: Calendar) async throws -> [DailyQuantity]
    func samples(_ metric: HealthMetric, from: Date, to: Date) async throws -> [TimedValue]
    func sleepSegments(from: Date, to: Date) async throws -> [SleepSegment]
    func categoryEvents(_ kind: CategoryEventKind, from: Date, to: Date) async throws -> [TimedValue]
    func workouts(from: Date, to: Date) async throws -> [WorkoutRecord]
    func changes(_ feed: ChangeFeed, anchor: Data?, since: Date) async throws -> AnchoredChanges
    /// Registers observer queries + background delivery; `handler` runs on each change notification.
    func startObserving(_ feeds: [ChangeFeed], handler: @escaping @Sendable () async -> Void) async throws
}
