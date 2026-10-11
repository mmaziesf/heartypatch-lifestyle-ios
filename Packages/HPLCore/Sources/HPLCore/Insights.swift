import Foundation

/// Lifecycle of a note (architecture §4.2 `Recommendation.status`).
public enum NoteStatus: String, Codable, Sendable, CaseIterable {
    case new, accepted, dismissed, snoozed, done
}

public enum NoteFeedback: String, Codable, Sendable {
    case helpful, notHelpful = "not_helpful"
}

/// What a note is "about", for de-prioritising dismissed topics and snoozing. The first evidence path with array
/// indices removed: `meals.1.t_local` -> `meals.t_local`. Rule templates and LLM notes about the same signal share it.
public enum InsightTopic {
    public static func key(_ paths: [String]) -> String {
        guard let first = paths.first else { return "none" }
        return first.split(separator: ".").filter { Int($0) == nil }.joined(separator: ".")
    }
}

public extension Recommendation {
    var topic: String { InsightTopic.key(evidence.map(\.fieldPath)) }
}

/// A note as kept in history: the generated recommendation plus what the user did with it. Never uploaded.
public struct StoredNote: Codable, Sendable, Identifiable, Equatable {
    public var recommendation: Recommendation
    public var day: LocalDay
    public var topic: String
    public var status: NoteStatus
    public var statusChangedAt: Date?
    /// Hidden until this day (exclusive) when snoozed.
    public var snoozedUntil: LocalDay?
    public var feedback: NoteFeedback?
    public var experimentID: UUID?
    public var createdAt: Date

    public var id: UUID { recommendation.id }

    public init(recommendation: Recommendation, day: LocalDay, status: NoteStatus = .new, createdAt: Date) {
        self.recommendation = recommendation; self.day = day; topic = recommendation.topic
        self.status = status; self.createdAt = createdAt
    }
}

/// An N-of-1 self-experiment (§4.2): one behaviour change, compared on one summary metric,
/// `baselineDays` before the start vs `interventionDays` from the start. Results are descriptive only.
public struct Experiment: Codable, Sendable, Identifiable, Equatable {
    public enum Status: String, Codable, Sendable { case active, completed, stopped }

    public var id: UUID
    public var noteID: UUID?
    public var title: String
    public var intervention: String
    public var metricFieldPath: String
    public var baselineDays: Int
    public var interventionDays: Int
    public var startDay: LocalDay
    public var status: Status
    /// "YYYY-MM-DD" -> did the user do the intervention that day (self-reported).
    public var checkIns: [String: Bool]
    public var endedOn: LocalDay?
    public var result: ExperimentResult?
    public var provenance: DailySummaryV1.Provenance

    public init(id: UUID = UUID(), noteID: UUID?, title: String, intervention: String, metricFieldPath: String, days: Int,
                startDay: LocalDay, provenance: DailySummaryV1.Provenance) {
        self.id = id; self.noteID = noteID; self.title = title; self.intervention = intervention
        self.metricFieldPath = metricFieldPath; baselineDays = days; interventionDays = days; self.startDay = startDay
        status = .active; checkIns = [:]; self.provenance = provenance
    }

    public func lastDay(calendar: Calendar) -> LocalDay { startDay.adding(days: interventionDays - 1, calendar: calendar) }
    public func baselineRange(calendar: Calendar) -> [LocalDay] {
        startDay.adding(days: -baselineDays, calendar: calendar).through(startDay.adding(days: -1, calendar: calendar), calendar: calendar)
    }
    public func interventionRange(calendar: Calendar) -> [LocalDay] { startDay.through(lastDay(calendar: calendar), calendar: calendar) }

    /// 1-based day of the experiment, clamped to the window.
    public func dayNumber(on day: LocalDay, calendar: Calendar) -> Int {
        let n = (calendar.dateComponents([.day], from: startDay.start(in: calendar), to: day.start(in: calendar)).day ?? 0) + 1
        return min(max(n, 1), interventionDays)
    }
}

/// Baseline vs intervention, as plain numbers. No significance testing, no health meaning.
public struct ExperimentResult: Codable, Sendable, Equatable {
    public var baselineMean: Double?
    public var baselineDaysWithData: Int
    public var baselineSD: Double?
    public var interventionMean: Double?
    public var interventionDaysWithData: Int
    public var checkInsYes: Int
    public var checkInsTotal: Int
    public var enoughData: Bool
    public var summary: String

    public init(baselineMean: Double?, baselineDaysWithData: Int, baselineSD: Double?, interventionMean: Double?,
                interventionDaysWithData: Int, checkInsYes: Int, checkInsTotal: Int, enoughData: Bool, summary: String) {
        self.baselineMean = baselineMean; self.baselineDaysWithData = baselineDaysWithData; self.baselineSD = baselineSD
        self.interventionMean = interventionMean; self.interventionDaysWithData = interventionDaysWithData
        self.checkInsYes = checkInsYes; self.checkInsTotal = checkInsTotal; self.enoughData = enoughData; self.summary = summary
    }
}

/// Daily values of one summary metric, for experiment results.
public protocol ExperimentMetricSource: Sendable {
    func values(metric fieldPath: String, days: [LocalDay]) throws -> [LocalDay: Double]
}

public protocol InsightsRepository: Sendable {
    func notes() throws -> [StoredNote]
    func upsert(_ notes: [StoredNote]) throws
    func deleteNotes(ids: [UUID]) throws
    func experiments() throws -> [Experiment]
    func save(_ experiment: Experiment) throws
    func deleteAll() throws
}

public extension InsightsRepository {
    func notes(on day: LocalDay) throws -> [StoredNote] { try notes().filter { $0.day == day } }
}

/// `hpl.insights_export.v1`: user-initiated export of history + experiments (M4 exit criterion). Leaves only via the share sheet.
public struct InsightsExportV1: Codable, Sendable, Equatable {
    public static let schemaID = "hpl.insights_export.v1"
    public var schema = Self.schemaID
    public var exportedAt: Date
    public var disclaimer = Disclaimer.footer
    public var notes: [StoredNote]
    public var experiments: [Experiment]

    public init(exportedAt: Date, notes: [StoredNote], experiments: [Experiment]) {
        self.exportedAt = exportedAt; self.notes = notes; self.experiments = experiments
    }

    public func encoded() throws -> Data {
        let e = HPLJSON.encoder
        e.outputFormatting = [.sortedKeys, .prettyPrinted]
        return try e.encode(self)
    }
}

/// Human labels for DailySummary field paths ("Why am I seeing this?" and experiment metrics).
public enum FieldLabels {
    public struct Label: Sendable, Equatable {
        public var name: String
        public var unit: String?
    }

    static let table: [String: Label] = [
        "sleep.total_min": .init(name: "Total sleep", unit: "min"),
        "sleep.deep_min": .init(name: "Deep sleep", unit: "min"),
        "sleep.rem_min": .init(name: "REM sleep", unit: "min"),
        "sleep.awake_min": .init(name: "Awake in bed", unit: "min"),
        "sleep.bed_local": .init(name: "Bedtime", unit: nil),
        "sleep.wake_local": .init(name: "Wake time", unit: nil),
        "sleep.baseline_28d.total_min_median": .init(name: "Total sleep, your 28-day median", unit: "min"),
        "sleep.baseline_28d.deep_min_median": .init(name: "Deep sleep, your 28-day median", unit: "min"),
        "heart.resting_hr": .init(name: "Resting heart rate", unit: "bpm"),
        "heart.resting_hr_28d_median": .init(name: "Resting heart rate, your 28-day median", unit: "bpm"),
        "heart.hrv_sdnn_ms_overnight_median": .init(name: "Overnight HRV (SDNN)", unit: "ms"),
        "heart.hrv_28d_p10": .init(name: "HRV, your 28-day low band (10th percentile)", unit: "ms"),
        "heart.hrv_28d_median": .init(name: "HRV, your 28-day median", unit: "ms"),
        "activity.steps": .init(name: "Steps", unit: nil),
        "activity.steps_28d_median": .init(name: "Steps, your 28-day median", unit: nil),
        "activity.active_kcal": .init(name: "Active energy", unit: "kcal"),
        "activity.exercise_min": .init(name: "Exercise", unit: "min"),
        "activity.stand_hours": .init(name: "Stand hours", unit: nil),
        "workouts.type": .init(name: "Workout type", unit: nil),
        "workouts.duration_min": .init(name: "Workout length", unit: "min"),
        "workouts.zone_minutes": .init(name: "Minutes per heart-rate zone (1–5)", unit: nil),
        "meals.t_local": .init(name: "Meal time", unit: nil),
        "meals.tags": .init(name: "Meal tags", unit: nil),
        "meals.label": .init(name: "Meal", unit: nil),
        "labs_recent.analyte": .init(name: "Lab test (as on your report)", unit: nil),
        "labs_recent.report_flag": .init(name: "Flag printed on your report", unit: nil),
        "active_experiments.intervention": .init(name: "Experiment", unit: nil),
        "active_experiments.day": .init(name: "Experiment day", unit: nil),
        "active_experiments.of": .init(name: "Experiment length", unit: "days"),
        "completeness": .init(name: "Share of today's signals available", unit: nil),
    ]

    public static func label(for path: String) -> Label {
        table[InsightTopic.key([path])] ?? .init(name: path, unit: nil)
    }
}
