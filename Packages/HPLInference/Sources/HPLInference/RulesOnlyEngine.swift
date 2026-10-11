import Foundation
import HPLCore

/// Always-available floor: deterministic templates per rule hit. No LLM.
/// Template copy stays digit-light: every number must come from the summary (OutputGuard enforces it).
public struct RulesOnlyEngine: InsightEngine {
    public let id = "rules-only"
    public let generator = Generator(engine: .rules, promptVersion: "rules-v1")
    public static let maxRecommendations = 3

    public init() {}

    public func isAvailable() async -> EngineAvailability { .available }

    public func generate(summary: DailySummaryV1, ruleHits: [RuleHit]) async throws -> [RecommendationDraft] {
        Array(ruleHits.compactMap { draft(for: $0, summary) }.prefix(Self.maxRecommendations))
    }

    /// Template for one hit, or nil when the rule is unknown or its inputs are missing.
    public func draft(for hit: RuleHit, _ s: DailySummaryV1) -> RecommendationDraft? {
        RuleTemplates.all[hit.id]?(hit, s)
    }
}

/// Copy for each rule in `RuleID`. Restates the user's numbers against their own baseline; no clinical meaning.
enum RuleTemplates {
    typealias Template = @Sendable (RuleHit, DailySummaryV1) -> RecommendationDraft?

    static let all: [String: Template] = [
        RuleID.clinicianLabCritical: clinicianLabCritical,
        RuleID.lowCompleteness: lowCompleteness,
        RuleID.sleepShort: sleepShort,
        RuleID.deepSleepLow: deepSleepLow,
        RuleID.bedtimeLate: bedtimeLate,
        RuleID.hrvLow: hrvLow,
        RuleID.restingHRHigh: restingHRHigh,
        RuleID.stepsLow: stepsLow,
        RuleID.stepsHigh: stepsHigh,
        RuleID.noExercise: noExercise,
        RuleID.hardWorkout: hardWorkout,
        RuleID.lateMealAlcohol: lateMealAlcohol,
        RuleID.experimentActive: experimentActive,
    ]

    /// Fixed red-flag copy (§6.6). Names no analyte or value; the evidence view shows what the report printed.
    static let clinicianCopy = "Your lab report printed a critical flag next to one result. Consider contacting a clinician about it."

    static let clinicianLabCritical: Template = { hit, _ in
        .init(kind: .clinicianPrompt, title: "Your report flagged a result", body: clinicianCopy, evidenceFieldPaths: hit.evidenceFieldPaths)
    }

    static let lowCompleteness: Template = { hit, _ in
        .init(kind: .observation, title: "Limited data today",
              body: "Some of today's data is missing, so notes may be incomplete. Wearing the watch overnight fills in sleep and HRV.",
              evidenceFieldPaths: hit.evidenceFieldPaths)
    }

    static let sleepShort: Template = { hit, s in
        guard let total = s.sleep?.totalMin, let base = s.sleep?.baseline28d?.totalMinMedian else { return nil }
        return .init(kind: .experiment,
                     title: "Shorter sleep than your recent typical",
                     body: "You slept \(total) min vs your 28-day median of \(fmt(base)) min. "
                         + "Experiment idea: start winding down earlier for the next week and see whether total sleep moves.",
                     evidenceFieldPaths: hit.evidenceFieldPaths,
                     experiment: .init(intervention: "Start winding down earlier each night", durationDays: 7, metricFieldPath: "sleep.total_min"))
    }

    static let deepSleepLow: Template = { hit, s in
        guard let deep = s.sleep?.deepMin, let base = s.sleep?.baseline28d?.deepMinMedian else { return nil }
        return .init(kind: .observation, title: "Less deep sleep than usual",
                     body: "Deep sleep was \(deep) min vs your 28-day median of \(fmt(base)) min. Look at what was different about last evening.",
                     evidenceFieldPaths: hit.evidenceFieldPaths)
    }

    static let bedtimeLate: Template = { hit, s in
        guard let bed = s.sleep?.bedLocal else { return nil }
        return .init(kind: .experiment, title: "Bedtime after midnight",
                     body: "You went to bed at \(bed). Experiment idea: keep a consistent, earlier lights-out and compare total sleep.",
                     evidenceFieldPaths: hit.evidenceFieldPaths,
                     experiment: .init(intervention: "Consistent lights-out before midnight", durationDays: 14, metricFieldPath: "sleep.total_min"))
    }

    static let hrvLow: Template = { hit, s in
        guard let hrv = s.heart?.hrvSDNNOvernightMedian, let p10 = s.heart?.hrv28dP10 else { return nil }
        return .init(kind: .nudge,
                     title: "Overnight HRV in your low band",
                     body: "Overnight HRV (SDNN) was \(fmt(hrv)) ms, below your 28-day low band of \(fmt(p10)) ms. "
                         + "Consider an easier training day and an earlier night, then watch whether it rebounds.",
                     evidenceFieldPaths: hit.evidenceFieldPaths)
    }

    static let restingHRHigh: Template = { hit, s in
        guard let rhr = s.heart?.restingHR, let base = s.heart?.restingHR28dMedian else { return nil }
        return .init(kind: .nudge, title: "Resting heart rate above your usual",
                     body: "Resting HR was \(fmt(rhr)) bpm vs your 28-day median of \(fmt(base)) bpm. "
                         + "Short sleep, alcohol, heat and hard training can all nudge it up; an easier day is a reasonable choice.",
                     evidenceFieldPaths: hit.evidenceFieldPaths)
    }

    static let stepsLow: Template = { hit, s in
        guard let steps = s.activity?.steps, let base = s.activity?.steps28dMedian else { return nil }
        return .init(kind: .experiment, title: "A quieter day on your feet",
                     body: "You took \(steps) steps vs your 28-day median of \(fmt(base)). Experiment idea: add a short walk after lunch each day.",
                     evidenceFieldPaths: hit.evidenceFieldPaths,
                     experiment: .init(intervention: "Short walk after lunch each day", durationDays: 14, metricFieldPath: "activity.steps"))
    }

    static let stepsHigh: Template = { hit, s in
        guard let steps = s.activity?.steps, let base = s.activity?.steps28dMedian else { return nil }
        return .init(kind: .observation, title: "A more active day than usual",
                     body: "You took \(steps) steps vs your 28-day median of \(fmt(base)). Notice how you sleep tonight.",
                     evidenceFieldPaths: hit.evidenceFieldPaths)
    }

    static let noExercise: Template = { hit, _ in
        .init(kind: .nudge, title: "No exercise minutes yet",
              body: "Your watch logged no exercise minutes today. A brisk walk counts.",
              evidenceFieldPaths: hit.evidenceFieldPaths)
    }

    static let hardWorkout: Template = { hit, s in
        guard let path = hit.evidenceFieldPaths.first, let i = index(in: path), s.workouts.indices.contains(i) else { return nil }
        let w = s.workouts[i]
        return .init(kind: .observation, title: "Hard \(w.type) session",
                     body: "Your \(w.durationMin) min \(w.type) spent a lot of time in your top heart-rate zones. "
                         + "Compare tonight's HRV and resting HR with your 28-day medians.",
                     evidenceFieldPaths: hit.evidenceFieldPaths)
    }

    static let lateMealAlcohol: Template = { hit, s in
        guard let path = hit.evidenceFieldPaths.first(where: { $0.hasSuffix(".t_local") }),
              let i = index(in: path), s.meals.indices.contains(i) else { return nil }
        return .init(kind: .experiment,
                     title: "Late meal with alcohol",
                     body: "Your \(s.meals[i].label) at \(s.meals[i].tLocal) was tagged late and alcohol. "
                         + "Compare tonight's deep sleep against nights without both tags.",
                     evidenceFieldPaths: hit.evidenceFieldPaths,
                     experiment: .init(intervention: "Finish dinner earlier, no alcohol after it", durationDays: 14, metricFieldPath: "sleep.deep_min"))
    }

    static let experimentActive: Template = { hit, s in
        guard let e = s.activeExperiments.first else { return nil }
        return .init(kind: .observation, title: "Experiment in progress",
                     body: "Day \(e.day) of \(e.of): \(e.intervention). Keep logging; the comparison comes at the end.",
                     evidenceFieldPaths: hit.evidenceFieldPaths)
    }

    /// Array index from a path like `meals.1.t_local`.
    static func index(in path: String) -> Int? { path.split(separator: ".").dropFirst().first.flatMap { Int($0) } }

    static func fmt(_ v: Double) -> String { v.rounded() == v ? String(Int(v)) : String(format: "%.1f", v) }
}
