import Foundation

/// Metrics HPL aggregates from HealthKit (architecture §4.3, minus clinical records).
/// Raw values use these canonical units; nothing here is ever a raw HealthKit sample.
public enum HealthMetric: String, Codable, Sendable, CaseIterable {
    // Sleep (window .night, assigned to the day the night ENDS on). Values in minutes.
    case sleepAsleep = "sleep_asleep_min"
    case sleepInBed = "sleep_in_bed_min"
    case sleepCore = "sleep_core_min"
    case sleepDeep = "sleep_deep_min"
    case sleepREM = "sleep_rem_min"
    case sleepAwake = "sleep_awake_min"
    /// Minutes from local midnight of the wake day (negative = previous evening). Stored in `min`.
    case sleepOnset = "sleep_onset_min_from_midnight"
    case sleepWake = "sleep_wake_min_from_midnight"

    // Heart
    case heartRate = "heart_rate_bpm"
    case restingHeartRate = "resting_heart_rate_bpm"
    case walkingHeartRateAverage = "walking_heart_rate_avg_bpm"
    /// HealthKit HRV is SDNN, sampled sporadically (§4.3 note). `.night` window = overnight samples.
    case hrvSDNN = "hrv_sdnn_ms"
    case heartRateRecoveryOneMinute = "hr_recovery_1min_bpm"
    case vo2Max = "vo2max_ml_kg_min"
    case respiratoryRate = "respiratory_rate_brpm"
    /// Fraction 0–1 as HealthKit reports it.
    case oxygenSaturation = "spo2_fraction"
    case wristTemperature = "wrist_temperature_c"
    case highHeartRateEvents = "high_hr_event_count"
    case lowHeartRateEvents = "low_hr_event_count"
    case irregularRhythmEvents = "irregular_rhythm_event_count"

    // Activity
    case steps = "steps"
    case distanceWalkingRunning = "distance_walking_running_m"
    case activeEnergy = "active_energy_kcal"
    case basalEnergy = "basal_energy_kcal"
    case exerciseTime = "exercise_min"
    case standTime = "stand_time_min"
    case standHours = "stand_hours"
    case flightsClimbed = "flights_climbed"
    case timeInDaylight = "time_in_daylight_min"
    case walkingSpeed = "walking_speed_m_s"
    case mindfulMinutes = "mindful_min"

    // Body
    case bodyMass = "body_mass_kg"
    case bodyFatPercentage = "body_fat_fraction"

    // Workouts (window .workout; `qualifier` = DailySummary workout type, e.g. "running")
    case workoutDuration = "workout_duration_min"
    case workoutAvgHeartRate = "workout_avg_hr_bpm"
}

public enum AggregateWindow: String, Codable, Sendable { case day, night, workout, hourly }

/// Per-window summary statistics. Every field is optional: absent means "not computed / no data", never zero.
public struct AggregateStats: Codable, Sendable, Equatable {
    public var min, max, mean, median, p10, p90, sum, stdev: Double?
    public var count: Int?

    public init(min: Double? = nil, max: Double? = nil, mean: Double? = nil, median: Double? = nil,
                p10: Double? = nil, p90: Double? = nil, sum: Double? = nil, count: Int? = nil, stdev: Double? = nil) {
        self.min = min; self.max = max; self.mean = mean; self.median = median
        self.p10 = p10; self.p90 = p90; self.sum = sum; self.count = count; self.stdev = stdev
    }

    /// Full distribution stats from raw values (used for sparse metrics like HRV; values are discarded afterwards).
    public static func of(_ values: [Double]) -> AggregateStats? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let n = Double(values.count)
        let mean = values.reduce(0, +) / n
        let variance = values.count > 1 ? values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / (n - 1) : 0
        return AggregateStats(min: sorted.first, max: sorted.last, mean: mean,
                              median: percentile(sorted, 0.5), p10: percentile(sorted, 0.1), p90: percentile(sorted, 0.9),
                              sum: values.reduce(0, +), count: values.count, stdev: variance.squareRoot())
    }

    /// Linear-interpolated percentile of pre-sorted values (same as numpy's default).
    public static func percentile(_ sorted: [Double], _ q: Double) -> Double? {
        guard !sorted.isEmpty else { return nil }
        let pos = q * Double(sorted.count - 1)
        let lo = Int(pos.rounded(.down)), hi = Int(pos.rounded(.up))
        return sorted[lo] + (sorted[hi] - sorted[lo]) * (pos - Double(lo))
    }
}

/// One stored aggregate (architecture §4.2). Raw HealthKit samples are never copied; HealthKit stays the source of truth.
public struct HealthAggregate: Codable, Sendable, Equatable, Identifiable {
    public var day: LocalDay
    public var metric: HealthMetric
    public var window: AggregateWindow
    /// Sub-key, e.g. workout type. `nil` for most metrics.
    public var qualifier: String?
    public var stats: AggregateStats
    /// Local only; never sent to an LLM or the cloud.
    public var sourceBundleIDs: [String]
    /// IANA zone the day boundaries were computed in.
    public var tz: String
    public var computedAt: Date

    public init(day: LocalDay, metric: HealthMetric, window: AggregateWindow, qualifier: String? = nil,
                stats: AggregateStats, sourceBundleIDs: [String] = [], tz: String, computedAt: Date) {
        self.day = day; self.metric = metric; self.window = window; self.qualifier = qualifier
        self.stats = stats; self.sourceBundleIDs = sourceBundleIDs; self.tz = tz; self.computedAt = computedAt
    }

    /// Natural key: one row per (day, metric, window, qualifier).
    public var id: String { "\(day)|\(metric.rawValue)|\(window.rawValue)|\(qualifier ?? "")" }
}

/// Storage boundary for aggregates (keep the store behind protocols; SwiftData today, GRDB if it hurts).
public protocol HealthAggregateRepository: Sendable {
    /// Atomically replaces every aggregate on `days` with `aggregates` (recompute semantics: stale rows disappear).
    func replace(days: [LocalDay], with aggregates: [HealthAggregate]) throws
    func aggregates(from first: LocalDay, through last: LocalDay) throws -> [HealthAggregate]
    func deleteAll() throws
}

public extension HealthAggregateRepository {
    func aggregates(on day: LocalDay) throws -> [HealthAggregate] { try aggregates(from: day, through: day) }
}

/// Sync bookkeeping: HealthKit query anchors (opaque archived `HKQueryAnchor`) and last-sync times. Holds no health values.
public protocol SyncStateRepository: Sendable {
    func anchor(for key: String) throws -> Data?
    func setAnchor(_ data: Data?, for key: String) throws
    func date(for key: String) throws -> Date?
    func setDate(_ date: Date?, for key: String) throws
    func reset() throws
}
