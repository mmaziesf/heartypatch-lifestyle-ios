import Foundation
import HPLCore
@testable import HPLHealth

/// Deterministic in-memory HealthKit stand-in. Returns only what a test puts in it.
final class FakeHealthDataSource: HealthDataSource, @unchecked Sendable {
    var available = true
    var steps: [LocalDay: Double] = [:]
    var restingHR: [LocalDay: Double] = [:]
    var hrv: [TimedValue] = []
    var sleep: [SleepSegment] = []
    var standHours: [TimedValue] = []
    var workoutList: [WorkoutRecord] = []
    var pendingChanges: [ChangeFeed: AnchoredChanges] = [:]
    private(set) var authorizedFamilies: Set<HealthSync.MetricFamily> = []
    private(set) var dailyQueryCount = 0
    private var anchorCounter = 0

    var isHealthDataAvailable: Bool { available }

    func requestReadAuthorization(_ families: Set<HealthSync.MetricFamily>) async throws { authorizedFamilies = families }

    func dailyQuantities(_ spec: QuantitySpec, days: ClosedRange<LocalDay>, calendar: Calendar) async throws -> [DailyQuantity] {
        dailyQueryCount += 1
        switch spec.metric {
        case .steps: return steps.filter { days.contains($0.key) }.map { DailyQuantity(day: $0.key, stats: AggregateStats(sum: $0.value)) }
        case .restingHeartRate:
            return restingHR.filter { days.contains($0.key) }
                .map { DailyQuantity(day: $0.key, stats: AggregateStats(min: $0.value, max: $0.value, mean: $0.value)) }
        default: return []
        }
    }

    func samples(_ metric: HealthMetric, from: Date, to: Date) async throws -> [TimedValue] {
        metric == .hrvSDNN ? hrv.filter { $0.start >= from && $0.start < to } : []
    }

    func sleepSegments(from: Date, to: Date) async throws -> [SleepSegment] { sleep.filter { $0.end > from && $0.start < to } }

    func categoryEvents(_ kind: CategoryEventKind, from: Date, to: Date) async throws -> [TimedValue] {
        kind == .standHour ? standHours.filter { $0.start >= from && $0.start < to } : []
    }

    func workouts(from: Date, to: Date) async throws -> [WorkoutRecord] { workoutList.filter { $0.start >= from && $0.start < to } }

    func changes(_ feed: ChangeFeed, anchor: Data?, since: Date) async throws -> AnchoredChanges {
        anchorCounter += 1
        var ch = pendingChanges.removeValue(forKey: feed) ?? AnchoredChanges(newAnchor: nil)
        ch.newAnchor = Data("\(feed.rawValue)-\(anchorCounter)".utf8)
        return ch
    }

    func startObserving(_ feeds: [ChangeFeed], handler: @escaping @Sendable () async -> Void) async throws {}
}
