import Foundation
import HPLCore

/// One night of sleep, assigned to the local day it ENDS on (§5.1).
public struct SleepNight: Sendable, Equatable {
    public var day: LocalDay
    public var asleepMin: Int
    public var inBedMin: Int?
    public var coreMin: Int?
    public var deepMin: Int?
    public var remMin: Int?
    public var awakeMin: Int?
    public var onset: Date?
    public var wake: Date?
    public var sourceBundleID: String
}

public enum SleepAggregator {
    /// A night belongs to day D if it ends in [D-1 18:00, D 18:00) local. VERIFY against the Health app on device.
    public static let dayBoundaryHour = 18

    public static func nightDay(forEnd end: Date, calendar: Calendar) -> LocalDay {
        LocalDay(calendar.date(byAdding: .hour, value: 24 - dayBoundaryHour, to: end) ?? end, calendar: calendar)
    }

    /// Fetch window that covers every segment that can belong to nights `days`.
    public static func fetchWindow(_ days: ClosedRange<LocalDay>, calendar: Calendar) -> (from: Date, to: Date) {
        let from = days.lowerBound.date(minutesFromMidnight: (dayBoundaryHour - 48) * 60, calendar: calendar)
        let to = days.upperBound.date(minutesFromMidnight: dayBoundaryHour * 60, calendar: calendar)
        return (from, to)
    }

    /// Groups segments into nights. When several sources recorded the same night, one source wins (Watch first,
    /// then the most asleep time), mirroring the Health app's single-source-per-night display instead of summing.
    public static func nights(_ segments: [SleepSegment], calendar: Calendar) -> [LocalDay: SleepNight] {
        var out: [LocalDay: SleepNight] = [:]
        let byDay = Dictionary(grouping: segments.filter { $0.end > $0.start }) { nightDay(forEnd: $0.end, calendar: calendar) }
        for (day, segs) in byDay {
            let bySource = Dictionary(grouping: segs, by: \.sourceBundleID)
            let ranked = bySource.map { (id: $0.key, segs: $0.value,
                                         isWatch: $0.value.contains(where: \.isWatch),
                                         asleep: Interval.total(Interval.union($0.value.filter { $0.stage.isAsleep }))) }
                .filter { $0.asleep > 0 }
                .sorted { ($0.isWatch ? 1 : 0, $0.asleep, $0.id) > ($1.isWatch ? 1 : 0, $1.asleep, $1.id) }
            guard let winner = ranked.first else { continue } // in-bed only: no asleep total to report
            let s = winner.segs
            let asleep = Interval.union(s.filter { $0.stage.isAsleep })
            func minutes(_ stage: SleepStage) -> Int? {
                let segs = s.filter { $0.stage == stage }
                return segs.isEmpty ? nil : toMinutes(Interval.total(Interval.union(segs)))
            }
            let awakeRaw = Interval.union(s.filter { $0.stage == .awake })
            let hasStages = s.contains { [.core, .deep, .rem].contains($0.stage) }
            out[day] = SleepNight(
                day: day,
                asleepMin: toMinutes(Interval.total(asleep)),
                inBedMin: minutes(.inBed),
                coreMin: hasStages ? (minutes(.core) ?? 0) : nil,
                deepMin: hasStages ? (minutes(.deep) ?? 0) : nil,
                remMin: hasStages ? (minutes(.rem) ?? 0) : nil,
                awakeMin: awakeRaw.isEmpty ? nil : toMinutes(Interval.total(Interval.subtract(awakeRaw, asleep))),
                onset: asleep.first?.lowerBound, wake: asleep.last?.upperBound,
                sourceBundleID: winner.id)
        }
        return out
    }

    static func toMinutes(_ seconds: TimeInterval) -> Int { Int((seconds / 60).rounded()) }
}

/// Minimal interval math on [start, end) ranges.
enum Interval {
    static func union(_ segs: [SleepSegment]) -> [ClosedRange<Date>] { union(segs.map { $0.start...$0.end }) }

    static func union(_ ranges: [ClosedRange<Date>]) -> [ClosedRange<Date>] {
        var out: [ClosedRange<Date>] = []
        for r in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = out.last, r.lowerBound <= last.upperBound {
                out[out.count - 1] = last.lowerBound...max(last.upperBound, r.upperBound)
            } else {
                out.append(r)
            }
        }
        return out
    }

    static func total(_ ranges: [ClosedRange<Date>]) -> TimeInterval {
        ranges.reduce(0) { $0 + $1.upperBound.timeIntervalSince($1.lowerBound) }
    }

    /// `a` minus `b` (both unions).
    static func subtract(_ a: [ClosedRange<Date>], _ b: [ClosedRange<Date>]) -> [ClosedRange<Date>] {
        var out: [ClosedRange<Date>] = []
        for r in a {
            var pieces = [r]
            for cut in b {
                pieces = pieces.flatMap { p -> [ClosedRange<Date>] in
                    guard cut.lowerBound < p.upperBound, cut.upperBound > p.lowerBound else { return [p] }
                    var keep: [ClosedRange<Date>] = []
                    if cut.lowerBound > p.lowerBound { keep.append(p.lowerBound...cut.lowerBound) }
                    if cut.upperBound < p.upperBound { keep.append(cut.upperBound...p.upperBound) }
                    return keep
                }
            }
            out += pieces
        }
        return out
    }
}
