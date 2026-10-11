import Foundation
import HPLCore

/// Builds `hpl.daily_summary.v1` (provenance `device`) from stored HealthKit aggregates (§5.4 step 2, M1 slice).
/// Baselines are medians over the 28 days BEFORE `day`, and only when at least 7 of those days have data.
public struct SummaryBuilder: Sendable {
    public static let baselineDays = 28
    public static let minBaselineDays = 7
    /// Signals counted in `completeness` for M1 (meals and labs join in later milestones).
    public static let expectedSignals = 6

    /// Confirmed lab results older than this are left out of the summary.
    public static let labsLookbackDays = 365

    private let aggregates: any HealthAggregateRepository
    private let labs: (any LabRepository)?
    private let meals: (any MealRepository)?
    private let calendar: Calendar

    public init(aggregates: any HealthAggregateRepository, labs: (any LabRepository)? = nil, meals: (any MealRepository)? = nil,
                calendar: Calendar = .hplLocal()) {
        self.aggregates = aggregates; self.labs = labs; self.meals = meals; self.calendar = calendar
    }

    /// Confirmed meals only (pending glasses meals wait for the user).
    public func mealsSummary(on day: LocalDay) throws -> [DailySummaryV1.Meal] {
        guard let meals else { return [] }
        return MealSummary.meals(on: day, meals: try meals.meals(), lifestyle: try meals.lifestyle(), calendar: calendar)
    }

    /// Latest confirmed result per dictionary analyte (§5.2: nothing unconfirmed, nothing out-of-dictionary).
    /// Values and the report's own range are expressed in the canonical unit when a conversion is known.
    public func labsRecent(on day: LocalDay) throws -> [DailySummaryV1.LabRecent] {
        guard let labs else { return [] }
        var seen = Set<String>()
        var out: [DailySummaryV1.LabRecent] = []
        for (panel, r) in try labs.confirmedResults() where panel.collectedOn <= day && r.userConfirmed {
            guard let key = r.analyteCanonical, !seen.contains(key) else { continue }
            let age = calendar.dateComponents([.day], from: panel.collectedOn.start(in: calendar), to: day.start(in: calendar)).day ?? 0
            guard age <= Self.labsLookbackDays else { continue }
            let canonical = r.valueCanonical != nil && r.unitCanonical != nil
            var factor: Double? = 1
            if canonical {
                if let raw = r.valueNumeric, raw != 0, let c = r.valueCanonical { factor = c / raw } else { factor = nil }
            }
            let unit = (canonical ? r.unitCanonical : r.unitRaw) ?? ""
            guard !unit.isEmpty, unit.count <= 16 else { continue }
            func conv(_ v: Double?) -> Double? { v.flatMap { v in factor.map { ((v * $0) * 100).rounded() / 100 } } }
            seen.insert(key)
            out.append(.init(analyte: key, value: (canonical ? r.valueCanonical : r.valueNumeric).map { ($0 * 100).rounded() / 100 },
                             unit: unit, refLow: conv(r.refLow), refHigh: conv(r.refHigh), reportFlag: r.flagFromReport?.rawValue, ageDays: age))
        }
        return out.sorted { $0.analyte < $1.analyte }
    }

    /// `nil` when HealthKit gave us nothing for `day` (no data, or read access not granted; HealthKit can't tell us which).
    public func build(day: LocalDay) throws -> DailySummaryV1? {
        let first = day.adding(days: -Self.baselineDays, calendar: calendar)
        let rows = try aggregates.aggregates(from: first, through: day)
        let today = rows.filter { $0.day == day }
        guard !today.isEmpty else { return nil }
        let history = rows.filter { $0.day < day }

        func value(_ m: HealthMetric, _ w: AggregateWindow, _ key: KeyPath<AggregateStats, Double?>) -> Double? {
            today.first { $0.metric == m && $0.window == w && $0.qualifier == nil }?.stats[keyPath: key]
        }
        func baseline(_ m: HealthMetric, _ w: AggregateWindow, _ key: KeyPath<AggregateStats, Double?>, q: Double = 0.5) -> Double? {
            let vals = history.filter { $0.metric == m && $0.window == w && $0.qualifier == nil }.compactMap { $0.stats[keyPath: key] }
            guard vals.count >= Self.minBaselineDays else { return nil }
            return AggregateStats.percentile(vals.sorted(), q).map { ($0 * 10).rounded() / 10 }
        }
        func hrvNight(_ rows: [HealthAggregate]) -> [HealthAggregate] { rows.filter { $0.metric == .hrvSDNN && $0.window == .night } }
        func round1(_ v: Double?) -> Double? { v.map { ($0 * 10).rounded() / 10 } }
        func int(_ v: Double?) -> Int? { v.map { Int($0.rounded()) } }

        let sleepTotal = int(value(.sleepAsleep, .night, \.sum))
        let sleep = DailySummaryV1.Sleep(
            totalMin: sleepTotal, deepMin: int(value(.sleepDeep, .night, \.sum)), remMin: int(value(.sleepREM, .night, \.sum)),
            awakeMin: int(value(.sleepAwake, .night, \.sum)),
            bedLocal: value(.sleepOnset, .night, \.min).map(Self.hhmm), wakeLocal: value(.sleepWake, .night, \.min).map(Self.hhmm),
            baseline28d: .init(totalMinMedian: baseline(.sleepAsleep, .night, \.sum), deepMinMedian: baseline(.sleepDeep, .night, \.sum)))

        let hrvToday = hrvNight(today).first?.stats.median
        let hrvHistory = hrvNight(history).compactMap(\.stats.median).sorted()
        let enoughHRV = hrvHistory.count >= Self.minBaselineDays
        let heart = DailySummaryV1.Heart(
            restingHR: round1(value(.restingHeartRate, .day, \.mean)), restingHR28dMedian: baseline(.restingHeartRate, .day, \.mean),
            hrvSDNNOvernightMedian: round1(hrvToday),
            hrv28dP10: enoughHRV ? round1(AggregateStats.percentile(hrvHistory, 0.1)) : nil,
            hrv28dMedian: enoughHRV ? round1(AggregateStats.percentile(hrvHistory, 0.5)) : nil)

        let activity = DailySummaryV1.Activity(
            steps: int(value(.steps, .day, \.sum)), steps28dMedian: baseline(.steps, .day, \.sum),
            activeKcal: round1(value(.activeEnergy, .day, \.sum)), exerciseMin: int(value(.exerciseTime, .day, \.sum)),
            standHours: int(value(.standHours, .day, \.sum)).map { min($0, 24) })

        let workouts = today.filter { $0.metric == .workoutDuration }.compactMap { w -> DailySummaryV1.Workout? in
            guard let type = w.qualifier, let mins = w.stats.sum else { return nil }
            let hr = today.first { $0.metric == .workoutAvgHeartRate && $0.qualifier == type }?.stats.mean
            return .init(type: type, durationMin: Int(mins.rounded()), avgHR: hr.map { $0.rounded() })
        }.sorted { $0.type < $1.type }

        let present = [sleepTotal != nil, heart.restingHR != nil, heart.hrvSDNNOvernightMedian != nil,
                       activity.steps != nil, activity.activeKcal != nil, activity.exerciseMin != nil].filter { $0 }.count
        return DailySummaryV1(
            provenance: .device, day: day.description, dayOfWeek: day.weekdayAbbrev(calendar: calendar),
            sleep: sleep, heart: heart, activity: activity, workouts: workouts, meals: try mealsSummary(on: day), labsRecent: try labsRecent(on: day),
            completeness: (Double(present) / Double(Self.expectedSignals) * 100).rounded() / 100)
    }

    /// Minutes from local midnight (may be negative = previous evening) as "HH:mm".
    static func hhmm(_ minutes: Double) -> String {
        let m = ((Int(minutes.rounded()) % 1440) + 1440) % 1440
        return String(format: "%02d:%02d", m / 60, m % 60)
    }
}
