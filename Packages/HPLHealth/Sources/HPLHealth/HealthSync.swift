import HPLCore
#if canImport(HealthKit)
import HealthKit
#endif

/// HealthKit read path (M1): progressive auth per metric family, anchored backfill, observer + background delivery.
/// M0 is a compiling boundary only. It never fabricates samples.
public enum HealthSync {
    public static let milestone = "M1"

    /// Metric families requested progressively (architecture §4.3).
    public enum MetricFamily: String, CaseIterable, Sendable { case sleep, heart, activity, body, workouts }

    public static var isHealthDataAvailable: Bool {
        #if canImport(HealthKit)
        HKHealthStore.isHealthDataAvailable()
        #else
        false
        #endif
    }
}
