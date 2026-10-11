import Foundation
import HPLCore

/// `hpl.cloud_payload.v1` (Spec/hpl.cloud_payload.v1.schema.json): the ONLY shape that may leave the device (§7).
/// Built field-by-field from typed values by `Anonymizer`; nothing is copied through wholesale, so anything not
/// listed here can't be sent. Days are relative indices (0 = last day of the window), never calendar dates.
public struct CloudPayloadV1: Codable, Sendable, Equatable {
    public static let schemaID = "hpl.cloud_payload.v1"

    public struct Profile: Codable, Sendable, Equatable {
        public var ageBand: String?
        public var sexForRanges: String?
        enum CodingKeys: String, CodingKey { case ageBand = "age_band", sexForRanges = "sex_for_ranges" }
    }

    public struct Stat: Codable, Sendable, Equatable {
        public var median: Double
        public var p10: Double
        public var p90: Double
    }

    public struct Week: Codable, Sendable, Equatable {
        /// 0 = the last 7 days of the window, -1 the 7 before, …
        public var week: Int
        public var daysWithData: Int
        /// Keyed by `CloudMetric.rawValue`; a metric is present only with ≥ 3 days of data that week.
        public var metrics: [String: Stat]
        enum CodingKeys: String, CodingKey { case week, daysWithData = "days_with_data", metrics }
    }

    public struct Meal: Codable, Sendable, Equatable {
        public var tLocal: String
        public var label: String
        public var tags: [String]
        enum CodingKeys: String, CodingKey { case tLocal = "t_local", label, tags }
    }

    public struct Workout: Codable, Sendable, Equatable {
        public var type: String
        public var durationMin: Int
        enum CodingKeys: String, CodingKey { case type, durationMin = "duration_min" }
    }

    public struct Day: Codable, Sendable, Equatable {
        /// -27 … 0 (relative; 0 = last day of the window).
        public var day: Int
        public var dow: String
        public var sleepTotalMin: Int?
        public var restingHR: Int?
        public var hrvMs: Int?
        public var steps: Int?
        public var exerciseMin: Int?
        public var bedLocal: String?
        public var wakeLocal: String?
        public var meals: [Meal]
        public var workouts: [Workout]
        enum CodingKeys: String, CodingKey {
            case day, dow, sleepTotalMin = "sleep_total_min", restingHR = "resting_hr", hrvMs = "hrv_ms", steps
            case exerciseMin = "exercise_min", bedLocal = "bed_local", wakeLocal = "wake_local", meals, workouts
        }
    }

    public struct Lab: Codable, Sendable, Equatable {
        public var analyte: String
        public var value: Double
        public var unit: String
        public var ageBucket: String
        enum CodingKeys: String, CodingKey { case analyte, value, unit, ageBucket = "age_bucket" }
    }

    public var schema: String
    public var requestID: String
    public var provenance: DailySummaryV1.Provenance
    public var windowDays: Int
    public var daysWithData: Int
    public var profile: Profile?
    public var weeks: [Week]
    public var daily: [Day]
    public var labs: [Lab]

    enum CodingKeys: String, CodingKey {
        case schema, requestID = "request_id", provenance, windowDays = "window_days", daysWithData = "days_with_data"
        case profile, weeks, daily, labs
    }

    /// Exact bytes that are previewed, hashed and sent: compact JSON with sorted keys.
    public func encoded() throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try e.encode(self)
    }
}

/// Metrics allowed in weekly aggregates, with rounding step and population clamp range (§7.1: "beyond p1/p99 → bucket edge").
public enum CloudMetric: String, CaseIterable, Sendable {
    case sleepTotalMin = "sleep_total_min", sleepDeepMin = "sleep_deep_min", restingHR = "resting_hr", hrvMs = "hrv_ms"
    case steps, exerciseMin = "exercise_min", activeKcal = "active_kcal"

    public var step: Double {
        switch self {
        case .sleepTotalMin, .sleepDeepMin, .exerciseMin: 5
        case .restingHR, .hrvMs: 1
        case .steps: 100
        case .activeKcal: 10
        }
    }

    public var range: ClosedRange<Double> {
        switch self {
        case .sleepTotalMin: 180...720
        case .sleepDeepMin: 0...180
        case .restingHR: 38...100
        case .hrvMs: 8...160
        case .steps: 0...35_000
        case .exerciseMin: 0...240
        case .activeKcal: 0...2_000
        }
    }

    /// Round to the step, then clamp to the range.
    public func coarsen(_ v: Double) -> Double { min(max(CloudRounding.round(v, step: step), range.lowerBound), range.upperBound) }

    /// Non-finite values (NaN/inf from a bad source) are treated as missing.
    func value(_ s: DailySummaryV1) -> Double? { raw(s).flatMap { $0.isFinite ? $0 : nil } }

    private func raw(_ s: DailySummaryV1) -> Double? {
        switch self {
        case .sleepTotalMin: s.sleep?.totalMin.map(Double.init)
        case .sleepDeepMin: s.sleep?.deepMin.map(Double.init)
        case .restingHR: s.heart?.restingHR
        case .hrvMs: s.heart?.hrvSDNNOvernightMedian
        case .steps: s.activity?.steps.map(Double.init)
        case .exerciseMin: s.activity?.exerciseMin.map(Double.init)
        case .activeKcal: s.activity?.activeKcal
        }
    }
}

/// Closed vocabularies for every string the payload can carry.
public enum CloudVocabulary {
    public static let daysOfWeek: Set<String> = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
    public static let mealLabels: Set<String> = ["breakfast", "lunch", "dinner", "snack", "drink", "meal"]
    public static let workoutTypes: Set<String> = ["running", "cycling", "strength", "walking", "yoga", "swimming", "hiking", "hiit", "other"]
    public static let ageBuckets: Set<String> = ["0-30", "31-90", "91-180", "180+"]
    public static let sexes: Set<String> = ["M", "F"]

    /// Common labs only (§7.1), with canonical unit and rounding step. Anything else is never sent.
    public static let labs: [String: (unit: String, step: Double)] = [
        "ldl": ("mg/dL", 5), "hdl": ("mg/dL", 5), "cholesterol_total": ("mg/dL", 5), "non_hdl": ("mg/dL", 5),
        "triglycerides": ("mg/dL", 10), "glucose": ("mg/dL", 5), "hba1c": ("%", 0.1),
    ]

    static let workoutSynonyms: [String: String] = [
        "run": "running", "running": "running", "cycling": "cycling", "biking": "cycling", "bike": "cycling",
        "strength": "strength", "traditionalstrengthtraining": "strength", "functionalstrengthtraining": "strength",
        "walking": "walking", "walk": "walking", "yoga": "yoga", "swimming": "swimming", "swim": "swimming",
        "hiking": "hiking", "hike": "hiking", "hiit": "hiit", "highintensityintervaltraining": "hiit",
    ]

    public static func workoutType(_ raw: String) -> String {
        let key = raw.lowercased().filter { $0.isLetter }
        return workoutSynonyms[key] ?? "other"
    }
}

public enum CloudRounding {
    /// Rounds to a step without binary-fraction noise (0.1 steps give 5.6, not 5.6000000000000005).
    public static func round(_ v: Double, step: Double) -> Double {
        if step >= 1 { return (v / step).rounded() * step }
        let inverse = (1 / step).rounded()
        return (v * inverse).rounded() / inverse
    }

    /// "HH:mm" → nearest 30 minutes, wrapping at midnight. `nil` for anything not shaped like a time.
    public static func halfHour(_ hhmm: String) -> String? {
        let parts = hhmm.split(separator: ":")
        guard parts.count == 2, parts.allSatisfy({ $0.count == 2 }), let h = Int(parts[0]), let m = Int(parts[1]),
              (0..<24).contains(h), (0..<60).contains(m) else { return nil }
        let total = ((Int((Double(h * 60 + m) / 30).rounded()) * 30) % 1440 + 1440) % 1440
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    public static func ageBucket(days: Int) -> String {
        switch days {
        case ..<31: "0-30"
        case 31...90: "31-90"
        case 91...180: "91-180"
        default: "180+"
        }
    }

    /// Accepts only 5-year bands ("35-39") or "80+" (§7.1); anything else is dropped.
    public static func ageBand(_ raw: String?) -> String? {
        guard let raw else { return nil }
        if raw == "80+" { return raw }
        let p = raw.split(separator: "-")
        guard p.count == 2, p.allSatisfy({ $0.count == 2 }), let lo = Int(p[0]), let hi = Int(p[1]),
              lo % 5 == 0, hi == lo + 4, (15...75).contains(lo) else { return nil }
        return raw
    }
}
