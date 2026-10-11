import Foundation
import HPLCore

/// Labeled synthetic days (`provenance: synthetic_fixture`) for example mode, tests and the golden payload fixture.
public enum SyntheticWindow {
    public static func make(days: Int, anchor: LocalDay, calendar: Calendar, seed: UInt64) -> CloudWindow {
        var rng = SeededRNG(seed: seed)
        let summaries = (0..<days).map { offset -> DailySummaryV1 in
            let day = anchor.adding(days: -offset, calendar: calendar)
            let trend = Double(days - offset) / Double(days)
            let sleep = Int(400 + rng.uniform(-50, 50) - trend * 20)
            let meals: [DailySummaryV1.Meal] = [
                .init(tLocal: String(format: "08:%02d", Int(rng.uniform(0, 59))), label: "breakfast", tags: ["home-cooked"]),
                .init(tLocal: String(format: "%02d:%02d", rng.uniform(0, 1) < 0.3 ? 21 : 19, Int(rng.uniform(0, 59))), label: "dinner",
                      tags: rng.uniform(0, 1) < 0.3 ? ["late"] : []),
            ]
            let workouts: [DailySummaryV1.Workout] = rng.uniform(0, 1) < 0.4
                ? [.init(type: ["running", "traditionalStrengthTraining", "yoga"][Int(rng.uniform(0, 2.99))], durationMin: Int(rng.uniform(20, 61)))] : []
            return DailySummaryV1(
                provenance: .syntheticFixture, day: day.description, dayOfWeek: day.weekdayAbbrev(calendar: calendar),
                sleep: .init(totalMin: sleep, deepMin: Int(rng.uniform(30, 80)), bedLocal: String(format: "23:%02d", Int(rng.uniform(0, 59))),
                             wakeLocal: String(format: "07:%02d", Int(rng.uniform(0, 59)))),
                heart: .init(restingHR: (rng.uniform(52, 62) + trend * 2).rounded(), hrvSDNNOvernightMedian: rng.uniform(30, 70).rounded()),
                activity: .init(steps: Int(rng.uniform(3000, 14000)), activeKcal: rng.uniform(200, 700).rounded(), exerciseMin: Int(rng.uniform(0, 60))),
                workouts: workouts, meals: meals,
                labsRecent: [.init(analyte: "ldl", value: 112.4, unit: "mg/dL", refLow: nil, refHigh: 100, reportFlag: "H", ageDays: 40 + offset),
                             .init(analyte: "hba1c", value: 5.43, unit: "%", refLow: nil, refHigh: 5.6, reportFlag: nil, ageDays: 40 + offset)],
                completeness: 1)
        }
        return CloudWindow(anchor: anchor, summaries: summaries.reversed(), calendar: calendar)
    }
}

/// SplitMix64: tiny, seedable, identical on every platform.
public struct SeededRNG: RandomNumberGenerator {
    var state: UInt64
    public init(seed: UInt64) { state = seed }
    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    public mutating func uniform(_ lo: Double, _ hi: Double) -> Double { lo + (hi - lo) * Double(next() >> 11) / Double(1 << 53) }
}
