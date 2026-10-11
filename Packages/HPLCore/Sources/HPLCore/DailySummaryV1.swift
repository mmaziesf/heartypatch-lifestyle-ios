import Foundation

/// `hpl.daily_summary.v1` — the only input insight engines see. Mirrors Spec/hpl.daily_summary.v1.schema.json.
public struct DailySummaryV1: Codable, Sendable, Equatable {
    public static let schemaID = "hpl.daily_summary.v1"

    public enum Provenance: String, Codable, Sendable { case device, syntheticFixture = "synthetic_fixture" }

    public struct Profile: Codable, Sendable, Equatable {
        public var ageBand: String?
        public var sexForRanges: String?
        enum CodingKeys: String, CodingKey { case ageBand = "age_band", sexForRanges = "sex_for_ranges" }
    }

    public struct Sleep: Codable, Sendable, Equatable {
        public struct Baseline: Codable, Sendable, Equatable {
            public var totalMinMedian: Double?
            public var deepMinMedian: Double?
            enum CodingKeys: String, CodingKey { case totalMinMedian = "total_min_median", deepMinMedian = "deep_min_median" }
        }
        public var totalMin: Int?
        public var deepMin: Int?
        public var remMin: Int?
        public var awakeMin: Int?
        public var bedLocal: String?
        public var wakeLocal: String?
        public var baseline28d: Baseline?
        enum CodingKeys: String, CodingKey {
            case totalMin = "total_min", deepMin = "deep_min", remMin = "rem_min", awakeMin = "awake_min"
            case bedLocal = "bed_local", wakeLocal = "wake_local", baseline28d = "baseline_28d"
        }
    }

    public struct Heart: Codable, Sendable, Equatable {
        public var restingHR: Double?
        public var restingHR28dMedian: Double?
        public var hrvSDNNOvernightMedian: Double?
        public var hrv28dP10: Double?
        public var hrv28dMedian: Double?
        enum CodingKeys: String, CodingKey {
            case restingHR = "resting_hr", restingHR28dMedian = "resting_hr_28d_median"
            case hrvSDNNOvernightMedian = "hrv_sdnn_ms_overnight_median"
            case hrv28dP10 = "hrv_28d_p10", hrv28dMedian = "hrv_28d_median"
        }
    }

    public struct Activity: Codable, Sendable, Equatable {
        public var steps: Int?
        public var steps28dMedian: Double?
        public var activeKcal: Double?
        public var exerciseMin: Int?
        public var standHours: Int?
        enum CodingKeys: String, CodingKey {
            case steps, steps28dMedian = "steps_28d_median", activeKcal = "active_kcal"
            case exerciseMin = "exercise_min", standHours = "stand_hours"
        }
    }

    public struct Workout: Codable, Sendable, Equatable {
        public var type: String
        public var durationMin: Int
        public var avgHR: Double?
        public var zoneMinutes: [Int]?
        enum CodingKeys: String, CodingKey { case type, durationMin = "duration_min", avgHR = "avg_hr", zoneMinutes = "zone_minutes" }
    }

    public struct Meal: Codable, Sendable, Equatable {
        public var tLocal: String
        public var label: String
        public var tags: [String]
        enum CodingKeys: String, CodingKey { case tLocal = "t_local", label, tags }
    }

    public struct LabRecent: Codable, Sendable, Equatable {
        public var analyte: String
        public var value: Double?
        public var unit: String
        public var refLow: Double?
        public var refHigh: Double?
        public var reportFlag: String?
        public var ageDays: Int
        enum CodingKeys: String, CodingKey {
            case analyte, value, unit, refLow = "ref_low", refHigh = "ref_high", reportFlag = "report_flag", ageDays = "age_days"
        }
    }

    public struct ActiveExperiment: Codable, Sendable, Equatable {
        public var id: String
        public var intervention: String
        public var day: Int
        public var of: Int
    }

    public var schema: String
    public var provenance: Provenance
    public var day: String
    public var dayOfWeek: String
    public var profile: Profile?
    public var sleep: Sleep?
    public var heart: Heart?
    public var activity: Activity?
    public var workouts: [Workout]
    public var meals: [Meal]
    public var labsRecent: [LabRecent]
    public var ruleHits: [String]
    public var activeExperiments: [ActiveExperiment]
    public var completeness: Double

    enum CodingKeys: String, CodingKey {
        case schema, provenance, day, dayOfWeek = "day_of_week", profile, sleep, heart, activity
        case workouts, meals, labsRecent = "labs_recent", ruleHits = "rule_hits"
        case activeExperiments = "active_experiments", completeness
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schema = try c.decode(String.self, forKey: .schema)
        guard schema == Self.schemaID else {
            throw DecodingError.dataCorruptedError(forKey: .schema, in: c, debugDescription: "Expected \(Self.schemaID), got \(schema)")
        }
        provenance = try c.decode(Provenance.self, forKey: .provenance)
        day = try c.decode(String.self, forKey: .day)
        dayOfWeek = try c.decode(String.self, forKey: .dayOfWeek)
        profile = try c.decodeIfPresent(Profile.self, forKey: .profile)
        sleep = try c.decodeIfPresent(Sleep.self, forKey: .sleep)
        heart = try c.decodeIfPresent(Heart.self, forKey: .heart)
        activity = try c.decodeIfPresent(Activity.self, forKey: .activity)
        workouts = try c.decode([Workout].self, forKey: .workouts)
        meals = try c.decode([Meal].self, forKey: .meals)
        labsRecent = try c.decode([LabRecent].self, forKey: .labsRecent)
        ruleHits = try c.decode([String].self, forKey: .ruleHits)
        activeExperiments = try c.decode([ActiveExperiment].self, forKey: .activeExperiments)
        completeness = try c.decode(Double.self, forKey: .completeness)
    }

    /// The summary as a JSON tree, for evidence path resolution and numeric trace checks.
    public func jsonTree() throws -> JSONValue { try JSONValue(encoding: self) }
}
