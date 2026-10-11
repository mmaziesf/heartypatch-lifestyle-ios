#if canImport(HealthKit)
import Foundation
import HealthKit
import HPLCore

/// Live HealthKit implementation (read-only). Uses statistics collection queries for per-day totals so Watch + iPhone
/// overlap is de-duplicated exactly like the Health app (§5.1: never sum raw samples).
public final class HealthKitDataSource: HealthDataSource, @unchecked Sendable {
    private let store: HKHealthStore

    public init(store: HKHealthStore = HKHealthStore()) { self.store = store }

    public var isHealthDataAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    // MARK: Type mapping

    static func quantityType(_ m: HealthMetric) -> HKQuantityType? {
        let table: [HealthMetric: HKQuantityTypeIdentifier] = [
            .steps: .stepCount, .distanceWalkingRunning: .distanceWalkingRunning, .activeEnergy: .activeEnergyBurned,
            .basalEnergy: .basalEnergyBurned, .exerciseTime: .appleExerciseTime, .standTime: .appleStandTime,
            .flightsClimbed: .flightsClimbed, .timeInDaylight: .timeInDaylight, .walkingSpeed: .walkingSpeed,
            .heartRate: .heartRate, .restingHeartRate: .restingHeartRate, .walkingHeartRateAverage: .walkingHeartRateAverage,
            .hrvSDNN: .heartRateVariabilitySDNN, .heartRateRecoveryOneMinute: .heartRateRecoveryOneMinute, .vo2Max: .vo2Max,
            .respiratoryRate: .respiratoryRate, .oxygenSaturation: .oxygenSaturation, .wristTemperature: .appleSleepingWristTemperature,
            .bodyMass: .bodyMass, .bodyFatPercentage: .bodyFatPercentage,
        ]
        return table[m].map { HKQuantityType($0) }
    }

    static func unit(_ m: HealthMetric) -> HKUnit {
        let bpm = HKUnit.count().unitDivided(by: .minute())
        let table: [HealthMetric: HKUnit] = [
            .distanceWalkingRunning: .meter(), .activeEnergy: .kilocalorie(), .basalEnergy: .kilocalorie(),
            .exerciseTime: .minute(), .standTime: .minute(), .timeInDaylight: .minute(),
            .walkingSpeed: .meter().unitDivided(by: .second()),
            .heartRate: bpm, .restingHeartRate: bpm, .walkingHeartRateAverage: bpm, .heartRateRecoveryOneMinute: bpm,
            .respiratoryRate: bpm, .workoutAvgHeartRate: bpm,
            .hrvSDNN: .secondUnit(with: .milli), .vo2Max: HKUnit(from: "ml/kg*min"),
            .oxygenSaturation: .percent(), .bodyFatPercentage: .percent(), .wristTemperature: .degreeCelsius(),
            .bodyMass: .gramUnit(with: .kilo),
        ]
        return table[m] ?? .count()
    }

    static func categoryType(_ k: CategoryEventKind) -> HKCategoryType {
        switch k {
        case .standHour: HKCategoryType(.appleStandHour)
        case .mindfulSession: HKCategoryType(.mindfulSession)
        case .highHeartRate: HKCategoryType(.highHeartRateEvent)
        case .lowHeartRate: HKCategoryType(.lowHeartRateEvent)
        case .irregularRhythm: HKCategoryType(.irregularHeartRhythmEvent)
        }
    }

    static func sampleType(_ feed: ChangeFeed) -> HKSampleType {
        switch feed {
        case .sleep: HKCategoryType(.sleepAnalysis)
        case .workouts: HKObjectType.workoutType()
        case .hrv: HKQuantityType(.heartRateVariabilitySDNN)
        case .restingHeartRate: HKQuantityType(.restingHeartRate)
        case .steps: HKQuantityType(.stepCount)
        case .bodyMass: HKQuantityType(.bodyMass)
        case .vo2Max: HKQuantityType(.vo2Max)
        }
    }

    /// Read types for each family (§4.3 minus clinical records, workout routes, and cycle tracking).
    public static func readTypes(_ families: Set<HealthSync.MetricFamily>) -> Set<HKObjectType> {
        var out = Set<HKObjectType>()
        for spec in QuantitySpec.all where families.contains(spec.family) {
            if let t = quantityType(spec.metric) { out.insert(t) }
        }
        if families.contains(.sleep) { out.insert(HKCategoryType(.sleepAnalysis)) }
        if families.contains(.heart) {
            for k in [CategoryEventKind.highHeartRate, .lowHeartRate, .irregularRhythm] { out.insert(categoryType(k)) }
        }
        if families.contains(.activity) {
            out.insert(categoryType(.standHour)); out.insert(categoryType(.mindfulSession))
        }
        if families.contains(.workouts) {
            out.insert(HKObjectType.workoutType()); out.insert(HKQuantityType(.heartRate))
        }
        return out
    }

    // MARK: HealthDataSource

    public func requestReadAuthorization(_ families: Set<HealthSync.MetricFamily>) async throws {
        try await store.requestAuthorization(toShare: Set<HKSampleType>(), read: Self.readTypes(families))
    }

    public func dailyQuantities(_ spec: QuantitySpec, days: ClosedRange<LocalDay>, calendar: Calendar) async throws -> [DailyQuantity] {
        guard let type = Self.quantityType(spec.metric) else { return [] }
        let start = days.lowerBound.start(in: calendar), end = days.upperBound.end(in: calendar)
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: [])
        let options: HKStatisticsOptions = switch spec.aggregation {
        case .cumulative: [.cumulativeSum, .separateBySource]
        case .discrete: [.discreteMin, .discreteMax, .discreteAverage, .separateBySource]
        }
        let query = HKStatisticsCollectionQueryDescriptor(
            predicate: .quantitySample(type: type, predicate: predicate), options: options,
            anchorDate: start, intervalComponents: DateComponents(day: 1))
        let unit = Self.unit(spec.metric)
        return try await query.result(for: store).statistics().compactMap { s in
            let stats: AggregateStats
            switch spec.aggregation {
            case .cumulative:
                guard let sum = s.sumQuantity()?.doubleValue(for: unit) else { return nil }
                stats = AggregateStats(sum: sum)
            case .discrete:
                guard let avg = s.averageQuantity()?.doubleValue(for: unit) else { return nil }
                stats = AggregateStats(min: s.minimumQuantity()?.doubleValue(for: unit), max: s.maximumQuantity()?.doubleValue(for: unit), mean: avg)
            }
            let sources = (s.sources ?? []).map(\.bundleIdentifier).sorted()
            return DailyQuantity(day: LocalDay(s.startDate, calendar: calendar), stats: stats, sourceBundleIDs: sources)
        }
    }

    public func samples(_ metric: HealthMetric, from: Date, to: Date) async throws -> [TimedValue] {
        guard let type = Self.quantityType(metric) else { return [] }
        let unit = Self.unit(metric)
        let query = HKSampleQueryDescriptor(
            predicates: [.quantitySample(type: type, predicate: HKQuery.predicateForSamples(withStart: from, end: to, options: .strictStartDate))],
            sortDescriptors: [SortDescriptor(\.startDate)])
        return try await query.result(for: store).map {
            TimedValue(start: $0.startDate, end: $0.endDate, value: $0.quantity.doubleValue(for: unit),
                       sourceBundleID: $0.sourceRevision.source.bundleIdentifier)
        }
    }

    public func sleepSegments(from: Date, to: Date) async throws -> [SleepSegment] {
        let query = HKSampleQueryDescriptor(
            predicates: [.categorySample(type: HKCategoryType(.sleepAnalysis),
                                         predicate: HKQuery.predicateForSamples(withStart: from, end: to, options: []))],
            sortDescriptors: [SortDescriptor(\.startDate)])
        return try await query.result(for: store).compactMap { s in
            let stage: SleepStage? = switch HKCategoryValueSleepAnalysis(rawValue: s.value) {
            case .inBed: .inBed
            case .asleepUnspecified: .asleepUnspecified
            case .asleepCore: .core
            case .asleepDeep: .deep
            case .asleepREM: .rem
            case .awake: .awake
            default: nil
            }
            guard let stage else { return nil }
            let isWatch = (s.sourceRevision.productType?.hasPrefix("Watch") ?? false) || s.device?.model == "Watch"
            return SleepSegment(start: s.startDate, end: s.endDate, stage: stage,
                                sourceBundleID: s.sourceRevision.source.bundleIdentifier, isWatch: isWatch)
        }
    }

    public func categoryEvents(_ kind: CategoryEventKind, from: Date, to: Date) async throws -> [TimedValue] {
        let query = HKSampleQueryDescriptor(
            predicates: [.categorySample(type: Self.categoryType(kind),
                                         predicate: HKQuery.predicateForSamples(withStart: from, end: to, options: .strictStartDate))],
            sortDescriptors: [SortDescriptor(\.startDate)])
        return try await query.result(for: store)
            .filter { kind != .standHour || $0.value == HKCategoryValueAppleStandHour.stood.rawValue }
            .map { TimedValue(start: $0.startDate, end: $0.endDate, value: 1, sourceBundleID: $0.sourceRevision.source.bundleIdentifier) }
    }

    public func workouts(from: Date, to: Date) async throws -> [WorkoutRecord] {
        let query = HKSampleQueryDescriptor(
            predicates: [.workout(HKQuery.predicateForSamples(withStart: from, end: to, options: .strictStartDate))],
            sortDescriptors: [SortDescriptor(\.startDate)])
        let bpm = Self.unit(.workoutAvgHeartRate)
        return try await query.result(for: store).map { w in
            WorkoutRecord(start: w.startDate, end: w.endDate, type: Self.summaryType(w.workoutActivityType),
                          avgHeartRate: w.statistics(for: HKQuantityType(.heartRate))?.averageQuantity()?.doubleValue(for: bpm),
                          sourceBundleID: w.sourceRevision.source.bundleIdentifier)
        }
    }

    static func summaryType(_ t: HKWorkoutActivityType) -> String {
        switch t {
        case .running: "running"
        case .cycling: "cycling"
        case .traditionalStrengthTraining, .functionalStrengthTraining: "strength"
        case .walking, .hiking: "walking"
        case .yoga: "yoga"
        case .swimming: "swimming"
        case .highIntensityIntervalTraining: "hiit"
        default: "other"
        }
    }

    public func changes(_ feed: ChangeFeed, anchor: Data?, since: Date) async throws -> AnchoredChanges {
        let previous = anchor.flatMap { try? NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: $0) }
        let query = HKAnchoredObjectQueryDescriptor(
            predicates: [HKSamplePredicate<HKSample>.sample(type: Self.sampleType(feed),
                                                            predicate: HKQuery.predicateForSamples(withStart: since, end: nil, options: []))],
            anchor: previous)
        let r = try await query.result(for: store)
        return AnchoredChanges(
            addedIntervals: r.addedSamples.map { $0.startDate...max($0.startDate, $0.endDate) },
            deletedCount: r.deletedObjects.count,
            newAnchor: try NSKeyedArchiver.archivedData(withRootObject: r.newAnchor, requiringSecureCoding: true))
    }

    public func startObserving(_ feeds: [ChangeFeed], handler: @escaping @Sendable () async -> Void) async throws {
        for feed in feeds {
            let type = Self.sampleType(feed)
            let query = HKObserverQuery(sampleType: type, predicate: nil) { _, completion, error in
                // Completion is called right away; the recompute is idempotent and also runs on next foreground.
                if error == nil { Task { await handler() } }
                completion()
            }
            store.execute(query)
            // Best effort: needs the background-delivery entitlement and is throttled by iOS (§5.1, §9.4).
            try? await store.enableBackgroundDelivery(for: type, frequency: feed == .workouts ? .immediate : .hourly)
        }
    }
}
#endif
