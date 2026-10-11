import HPLCore
#if canImport(HealthKit)
import HealthKit
#endif

/// HealthKit read path (M1): progressive auth per metric family, anchored backfill, observer + background delivery.
/// Platform-neutral pieces (aggregators, sync engine) are tested on Linux with fakes; `HealthKitDataSource` is Apple-only.
/// Nothing in this module fabricates samples: no data in HealthKit means no aggregate row.
public enum HealthSync {
    public static let milestone = "M1"

    /// Metric families requested progressively (architecture §4.3).
    public enum MetricFamily: String, CaseIterable, Sendable { case sleep, heart, activity, body, workouts }

    /// Default first-run backfill (§5.1).
    public static let backfillDays = 90

    public static var isHealthDataAvailable: Bool {
        #if canImport(HealthKit)
        HKHealthStore.isHealthDataAvailable()
        #else
        false
        #endif
    }
}

/// How a quantity metric is reduced per local day.
public struct QuantitySpec: Sendable, Hashable {
    public enum Aggregation: Sendable, Hashable {
        /// HKStatisticsCollectionQuery `.cumulativeSum`: de-duplicates Watch + iPhone the way the Health app does (§5.1).
        case cumulative
        /// HKStatisticsCollectionQuery discrete min/max/average.
        case discrete
    }

    public let metric: HealthMetric
    public let aggregation: Aggregation
    public let family: HealthSync.MetricFamily

    public static let all: [QuantitySpec] = [
        .init(metric: .steps, aggregation: .cumulative, family: .activity),
        .init(metric: .distanceWalkingRunning, aggregation: .cumulative, family: .activity),
        .init(metric: .activeEnergy, aggregation: .cumulative, family: .activity),
        .init(metric: .basalEnergy, aggregation: .cumulative, family: .activity),
        .init(metric: .exerciseTime, aggregation: .cumulative, family: .activity),
        .init(metric: .standTime, aggregation: .cumulative, family: .activity),
        .init(metric: .flightsClimbed, aggregation: .cumulative, family: .activity),
        .init(metric: .timeInDaylight, aggregation: .cumulative, family: .activity),
        .init(metric: .walkingSpeed, aggregation: .discrete, family: .activity),
        .init(metric: .heartRate, aggregation: .discrete, family: .heart),
        .init(metric: .restingHeartRate, aggregation: .discrete, family: .heart),
        .init(metric: .walkingHeartRateAverage, aggregation: .discrete, family: .heart),
        .init(metric: .hrvSDNN, aggregation: .discrete, family: .heart),
        .init(metric: .heartRateRecoveryOneMinute, aggregation: .discrete, family: .heart),
        .init(metric: .vo2Max, aggregation: .discrete, family: .heart),
        .init(metric: .respiratoryRate, aggregation: .discrete, family: .heart),
        .init(metric: .oxygenSaturation, aggregation: .discrete, family: .heart),
        .init(metric: .wristTemperature, aggregation: .discrete, family: .heart),
        .init(metric: .bodyMass, aggregation: .discrete, family: .body),
        .init(metric: .bodyFatPercentage, aggregation: .discrete, family: .body),
    ]
}
