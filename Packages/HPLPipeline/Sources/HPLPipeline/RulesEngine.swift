import HPLCore

/// Deterministic rules over a DailySummary (architecture §5.4 step 3). M0 ships three; M3 targets >= 10.
public enum RulesEngine {
    /// Sleep counts as short below this fraction of the 28-day median.
    public static let shortSleepRatio = 0.85

    public static func evaluate(_ s: DailySummaryV1) -> [RuleHit] {
        var hits: [RuleHit] = []
        if let total = s.sleep?.totalMin, let base = s.sleep?.baseline28d?.totalMinMedian, base > 0,
           Double(total) < base * shortSleepRatio {
            hits.append(.init(id: "SLEEP_SHORT_VS_BASELINE", evidenceFieldPaths: ["sleep.total_min", "sleep.baseline_28d.total_min_median"]))
        }
        if let hrv = s.heart?.hrvSDNNOvernightMedian, let p10 = s.heart?.hrv28dP10, hrv < p10 {
            hits.append(.init(id: "HRV_BELOW_P10", evidenceFieldPaths: ["heart.hrv_sdnn_ms_overnight_median", "heart.hrv_28d_p10"]))
        }
        if let i = s.meals.firstIndex(where: { $0.tags.contains("late") && $0.tags.contains("alcohol") }) {
            hits.append(.init(id: "LATE_MEAL_ALCOHOL", evidenceFieldPaths: ["meals.\(i).t_local", "meals.\(i).tags"]))
        }
        return hits
    }
}
