import Foundation
import HPLCore

/// Overnight HRV (SDNN) per night: the median of readings taken while asleep, not a single reading (§4.3 note).
public struct OvernightHRV: Sendable, Equatable {
    public var day: LocalDay
    public var stats: AggregateStats
    /// `nil` = readings inside the recorded sleep window; `HRVAggregator.fallbackQualifier` otherwise.
    public var qualifier: String?
}

public enum HRVAggregator {
    /// Used when no sleep was recorded for that night: [D-1 22:00, D 10:00) local. Marked via `qualifier`.
    public static let fallbackQualifier = "no_sleep_window"

    public static func overnight(_ samples: [TimedValue], nights: [LocalDay: SleepNight], days: [LocalDay],
                                 calendar: Calendar) -> [OvernightHRV] {
        days.compactMap { day in
            let window: ClosedRange<Date>
            let qualifier: String?
            if let n = nights[day], let on = n.onset, let off = n.wake, on < off {
                window = on...off; qualifier = nil
            } else {
                window = day.date(minutesFromMidnight: -120, calendar: calendar)...day.date(minutesFromMidnight: 600, calendar: calendar)
                qualifier = fallbackQualifier
            }
            let values = samples.filter { window.contains($0.start) }.map(\.value)
            return AggregateStats.of(values).map { OvernightHRV(day: day, stats: $0, qualifier: qualifier) }
        }
    }
}
