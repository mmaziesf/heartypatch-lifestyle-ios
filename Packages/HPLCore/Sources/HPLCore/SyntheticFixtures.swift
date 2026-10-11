import Foundation

/// Labeled synthetic data for M0 (no HealthKit yet). Never presented as the user's data.
/// Must stay semantically identical to Fixtures/daily_summary/d0.synthetic.json (enforced by HPLCoreTests).
public enum SyntheticFixtures {
    public static let dailySummaryD0JSON = #"""
    {
      "schema": "hpl.daily_summary.v1",
      "provenance": "synthetic_fixture",
      "day": "D0",
      "day_of_week": "Tue",
      "profile": { "age_band": "35-39", "sex_for_ranges": "M" },
      "sleep": {
        "total_min": 352, "deep_min": 41, "rem_min": 77, "awake_min": 28,
        "bed_local": "00:41", "wake_local": "07:03",
        "baseline_28d": { "total_min_median": 431, "deep_min_median": 58 }
      },
      "heart": {
        "resting_hr": 61, "resting_hr_28d_median": 56,
        "hrv_sdnn_ms_overnight_median": 38, "hrv_28d_p10": 40, "hrv_28d_median": 52
      },
      "activity": { "steps": 4210, "steps_28d_median": 8900, "active_kcal": 310, "exercise_min": 12, "stand_hours": 8 },
      "workouts": [ { "type": "running", "duration_min": 32, "avg_hr": 151, "zone_minutes": [0, 4, 12, 14, 2] } ],
      "meals": [
        { "t_local": "13:10", "label": "lunch", "tags": ["home-cooked"] },
        { "t_local": "21:45", "label": "dinner", "tags": ["late", "alcohol"] }
      ],
      "labs_recent": [
        { "analyte": "hba1c", "value": 5.6, "unit": "%", "ref_low": null, "ref_high": 5.6, "report_flag": null, "age_days": 41 }
      ],
      "rule_hits": [],
      "active_experiments": [ { "id": "E1", "intervention": "dinner before 20:00", "day": 4, "of": 14 } ],
      "completeness": 0.92
    }
    """#

    public static func dailySummaryD0() throws -> DailySummaryV1 {
        try HPLJSON.decoder.decode(DailySummaryV1.self, from: Data(dailySummaryD0JSON.utf8))
    }
}
