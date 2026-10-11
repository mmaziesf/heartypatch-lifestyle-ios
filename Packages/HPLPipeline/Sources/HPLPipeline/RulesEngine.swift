import HPLCore

/// Deterministic rules over a DailySummary (architecture §5.4 step 3). Order is priority: the pipeline keeps at most 3 notes.
/// Thresholds compare the user to their own 28-day baseline; none of them is a clinical cut-off.
public enum RulesEngine {
    public typealias Rule = @Sendable (DailySummaryV1) -> RuleHit?

    /// Sleep counts as short below this fraction of the 28-day median.
    public static let shortSleepRatio = 0.85
    public static let lowDeepSleepRatio = 0.75
    public static let restingHRDeltaBPM = 5.0
    public static let lowStepsRatio = 0.6
    public static let highStepsRatio = 1.3
    /// Minutes in the top two HR zones that make a workout "hard".
    public static let hardZoneMinutes = 20
    public static let lowCompleteness = 0.5

    public static let rules: [Rule] = [
        clinicianLabCritical, lowDataCompleteness, sleepShort, hrvLow, lateMealAlcohol, restingHRHigh,
        deepSleepLow, bedtimeLate, hardWorkout, stepsLow, noExercise, stepsHigh, experimentActive,
    ]

    public static func evaluate(_ s: DailySummaryV1) -> [RuleHit] { rules.compactMap { $0(s) } }

    // MARK: Rules

    static let clinicianLabCritical: Rule = { s in
        guard let i = s.labsRecent.firstIndex(where: { ["HH", "LL"].contains($0.reportFlag ?? "") }) else { return nil }
        return RuleHit(id: RuleID.clinicianLabCritical, evidenceFieldPaths: ["labs_recent.\(i).analyte", "labs_recent.\(i).report_flag"])
    }

    static let lowDataCompleteness: Rule = { s in
        s.completeness < lowCompleteness ? RuleHit(id: RuleID.lowCompleteness, evidenceFieldPaths: ["completeness"]) : nil
    }

    static let sleepShort: Rule = { s in
        guard let total = s.sleep?.totalMin, let base = s.sleep?.baseline28d?.totalMinMedian, base > 0,
              Double(total) < base * shortSleepRatio else { return nil }
        return RuleHit(id: RuleID.sleepShort, evidenceFieldPaths: ["sleep.total_min", "sleep.baseline_28d.total_min_median"])
    }

    static let deepSleepLow: Rule = { s in
        guard let deep = s.sleep?.deepMin, let base = s.sleep?.baseline28d?.deepMinMedian, base > 0,
              Double(deep) < base * lowDeepSleepRatio else { return nil }
        return RuleHit(id: RuleID.deepSleepLow, evidenceFieldPaths: ["sleep.deep_min", "sleep.baseline_28d.deep_min_median"])
    }

    static let bedtimeLate: Rule = { s in
        guard let bed = s.sleep?.bedLocal, let hour = Int(bed.prefix(2)), bed.count == 5, (0..<5).contains(hour) else { return nil }
        return RuleHit(id: RuleID.bedtimeLate, evidenceFieldPaths: ["sleep.bed_local"])
    }

    static let hrvLow: Rule = { s in
        guard let hrv = s.heart?.hrvSDNNOvernightMedian, let p10 = s.heart?.hrv28dP10, hrv < p10 else { return nil }
        return RuleHit(id: RuleID.hrvLow, evidenceFieldPaths: ["heart.hrv_sdnn_ms_overnight_median", "heart.hrv_28d_p10"])
    }

    static let restingHRHigh: Rule = { s in
        guard let rhr = s.heart?.restingHR, let base = s.heart?.restingHR28dMedian, rhr >= base + restingHRDeltaBPM else { return nil }
        return RuleHit(id: RuleID.restingHRHigh, evidenceFieldPaths: ["heart.resting_hr", "heart.resting_hr_28d_median"])
    }

    static let stepsLow: Rule = { s in
        guard let steps = s.activity?.steps, let base = s.activity?.steps28dMedian, base > 0,
              Double(steps) < base * lowStepsRatio else { return nil }
        return RuleHit(id: RuleID.stepsLow, evidenceFieldPaths: ["activity.steps", "activity.steps_28d_median"])
    }

    static let stepsHigh: Rule = { s in
        guard let steps = s.activity?.steps, let base = s.activity?.steps28dMedian, base > 0,
              Double(steps) >= base * highStepsRatio else { return nil }
        return RuleHit(id: RuleID.stepsHigh, evidenceFieldPaths: ["activity.steps", "activity.steps_28d_median"])
    }

    static let noExercise: Rule = { s in
        guard s.activity?.exerciseMin == 0, s.workouts.isEmpty else { return nil }
        return RuleHit(id: RuleID.noExercise, evidenceFieldPaths: ["activity.exercise_min"])
    }

    static let hardWorkout: Rule = { s in
        guard let i = s.workouts.firstIndex(where: { ($0.zoneMinutes ?? []).dropFirst(3).reduce(0, +) >= hardZoneMinutes }) else { return nil }
        return RuleHit(id: RuleID.hardWorkout, evidenceFieldPaths: ["workouts.\(i).type", "workouts.\(i).duration_min", "workouts.\(i).zone_minutes"])
    }

    static let lateMealAlcohol: Rule = { s in
        guard let i = s.meals.firstIndex(where: { $0.tags.contains("late") && $0.tags.contains("alcohol") }) else { return nil }
        return RuleHit(id: RuleID.lateMealAlcohol, evidenceFieldPaths: ["meals.\(i).t_local", "meals.\(i).tags"])
    }

    static let experimentActive: Rule = { s in
        guard !s.activeExperiments.isEmpty else { return nil }
        return RuleHit(id: RuleID.experimentActive,
                       evidenceFieldPaths: ["active_experiments.0.intervention", "active_experiments.0.day", "active_experiments.0.of"])
    }
}
