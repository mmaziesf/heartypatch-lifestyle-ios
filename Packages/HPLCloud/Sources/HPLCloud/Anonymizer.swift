import Foundation
import HPLCore

/// Days of `DailySummaryV1` to analyze. `anchor` (the last day) stays on the device; the payload only has offsets.
public struct CloudWindow: Sendable {
    public var anchor: LocalDay
    public var summaries: [DailySummaryV1]
    public var calendar: Calendar
    public init(anchor: LocalDay, summaries: [DailySummaryV1], calendar: Calendar) {
        self.anchor = anchor; self.summaries = summaries; self.calendar = calendar
    }
}

/// Per-job choices the user makes before the preview.
public struct AnonymizationPolicy: Sendable, Equatable {
    public static let allowedWindows = [28, 56]
    public static let dailyRowDays = 28
    public static let minDaysWithData = 14

    public var windowDays: Int
    public var includeMeals: Bool
    /// Off by default: common labs (rounded, age-bucketed) only when ticked for this job.
    public var includeLabs: Bool
    public init(windowDays: Int = 28, includeMeals: Bool = true, includeLabs: Bool = false) {
        self.windowDays = windowDays; self.includeMeals = includeMeals; self.includeLabs = includeLabs
    }
}

public enum AnonymizerError: Error, Equatable {
    case windowNotAllowed(Int)
    case insufficientData(daysWithData: Int, required: Int)
    case mixedProvenance
}

/// `(LocalData, Policy) -> CloudPayloadV1` (§7.4). Pure: same input + request id → same payload.
public enum Anonymizer {
    public static func payload(_ window: CloudWindow, policy: AnonymizationPolicy, requestID: UUID) throws -> CloudPayloadV1 {
        guard AnonymizationPolicy.allowedWindows.contains(policy.windowDays) else { throw AnonymizerError.windowNotAllowed(policy.windowDays) }
        let days = indexed(window, windowDays: policy.windowDays)
        guard days.count >= AnonymizationPolicy.minDaysWithData else {
            throw AnonymizerError.insufficientData(daysWithData: days.count, required: AnonymizationPolicy.minDaysWithData)
        }
        let provenances = Set(days.map(\.summary.provenance))
        guard provenances.count == 1, let provenance = provenances.first else { throw AnonymizerError.mixedProvenance }
        let latest = days.last?.summary
        return CloudPayloadV1(
            schema: CloudPayloadV1.schemaID, requestID: requestID.uuidString.lowercased(), provenance: provenance,
            windowDays: policy.windowDays, daysWithData: days.count, profile: profile(days.reversed().compactMap(\.summary.profile).first),
            weeks: weeks(days, windowDays: policy.windowDays),
            daily: days.filter { $0.index > -AnonymizationPolicy.dailyRowDays }.map { row($0.index, $0.summary, includeMeals: policy.includeMeals) },
            labs: policy.includeLabs ? labs(latest?.labsRecent ?? [], offset: -(days.last?.index ?? 0)) : [])
    }

    /// Summaries inside the window with their relative index (0 = anchor), oldest first; one per day.
    static func indexed(_ w: CloudWindow, windowDays: Int) -> [(index: Int, summary: DailySummaryV1)] {
        var byIndex: [Int: DailySummaryV1] = [:]
        let anchorStart = w.anchor.start(in: w.calendar)
        for s in w.summaries {
            guard let day = LocalDay(string: s.day),
                  let diff = w.calendar.dateComponents([.day], from: anchorStart, to: day.start(in: w.calendar)).day,
                  diff <= 0, diff > -windowDays else { continue }
            byIndex[diff] = s
        }
        return byIndex.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
    }

    static func profile(_ p: DailySummaryV1.Profile?) -> CloudPayloadV1.Profile? {
        guard let p else { return nil }
        let band = CloudRounding.ageBand(p.ageBand)
        let sex = p.sexForRanges.flatMap { CloudVocabulary.sexes.contains($0) ? $0 : nil }
        return band == nil && sex == nil ? nil : CloudPayloadV1.Profile(ageBand: band, sexForRanges: sex)
    }

    static func weeks(_ days: [(index: Int, summary: DailySummaryV1)], windowDays: Int) -> [CloudPayloadV1.Week] {
        let grouped = Dictionary(grouping: days) { -((-$0.index) / 7) }
        return (0..<(windowDays / 7)).map { -$0 }.reversed().compactMap { w in
            guard let rows = grouped[w], !rows.isEmpty else { return nil }
            var metrics: [String: CloudPayloadV1.Stat] = [:]
            for m in CloudMetric.allCases {
                let vals = rows.compactMap { m.value($0.summary) }.sorted()
                guard vals.count >= 3, let med = AggregateStats.percentile(vals, 0.5), let p10 = AggregateStats.percentile(vals, 0.1),
                      let p90 = AggregateStats.percentile(vals, 0.9) else { continue }
                metrics[m.rawValue] = .init(median: m.coarsen(med), p10: m.coarsen(p10), p90: m.coarsen(p90))
            }
            return CloudPayloadV1.Week(week: w, daysWithData: rows.count, metrics: metrics)
        }
    }

    static func row(_ index: Int, _ s: DailySummaryV1, includeMeals: Bool) -> CloudPayloadV1.Day {
        func int(_ m: CloudMetric) -> Int? { m.value(s).map { Int(m.coarsen($0)) } }
        let meals: [CloudPayloadV1.Meal] = includeMeals ? s.meals.compactMap { meal in
            guard let t = CloudRounding.halfHour(meal.tLocal) else { return nil }
            let label = CloudVocabulary.mealLabels.contains(meal.label) ? meal.label : "meal"
            return CloudPayloadV1.Meal(tLocal: t, label: label, tags: MealTag.filter(meal.tags).sorted())
        }.sorted { $0.tLocal < $1.tLocal } : []
        let workouts = s.workouts.map {
            CloudPayloadV1.Workout(type: CloudVocabulary.workoutType($0.type),
                                   durationMin: Int(min(max(CloudRounding.round(Double($0.durationMin), step: 5), 0), 300)))
        }.sorted { ($0.type, $0.durationMin) < ($1.type, $1.durationMin) }
        let dow = CloudVocabulary.daysOfWeek.contains(s.dayOfWeek) ? s.dayOfWeek : "Mon"
        return CloudPayloadV1.Day(day: index, dow: dow, sleepTotalMin: int(.sleepTotalMin), restingHR: int(.restingHR), hrvMs: int(.hrvMs),
                                  steps: int(.steps), exerciseMin: int(.exerciseMin), bedLocal: s.sleep?.bedLocal.flatMap(CloudRounding.halfHour),
                                  wakeLocal: s.sleep?.wakeLocal.flatMap(CloudRounding.halfHour), meals: meals, workouts: workouts)
    }

    /// Common, confirmed labs only; value rounded to clinically meaningless precision, unit must be the canonical one.
    static func labs(_ recent: [DailySummaryV1.LabRecent], offset: Int) -> [CloudPayloadV1.Lab] {
        recent.compactMap { l in
            guard let rule = CloudVocabulary.labs[l.analyte], rule.unit == l.unit, let v = l.value, v.isFinite, v >= 0 else { return nil }
            return CloudPayloadV1.Lab(analyte: l.analyte, value: CloudRounding.round(v, step: rule.step), unit: rule.unit,
                                      ageBucket: CloudRounding.ageBucket(days: l.ageDays + offset))
        }.sorted { $0.analyte < $1.analyte }
    }
}
