import Foundation

/// A user-local calendar day ("YYYY-MM-DD"). Architecture §4: timestamps are UTC; "day" uses the user's local day.
public struct LocalDay: Hashable, Comparable, Sendable, Codable, CustomStringConvertible {
    public let year: Int
    public let month: Int
    public let day: Int

    public init(year: Int, month: Int, day: Int) {
        self.year = year; self.month = month; self.day = day
    }

    /// The local day containing `date` in `calendar`'s time zone.
    public init(_ date: Date, calendar: Calendar) {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        self.init(year: c.year ?? 1970, month: c.month ?? 1, day: c.day ?? 1)
    }

    /// Parses "YYYY-MM-DD".
    public init?(string: String) {
        let parts = string.split(separator: "-")
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]),
              (1...12).contains(m), (1...31).contains(d) else { return nil }
        self.init(year: y, month: m, day: d)
    }

    public var description: String { String(format: "%04d-%02d-%02d", year, month, day) }

    /// Local midnight at the start of this day (DST-safe: uses the calendar, not 86 400 s arithmetic).
    public func start(in calendar: Calendar) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day)).map { calendar.startOfDay(for: $0) } ?? .distantPast
    }

    /// Local midnight at the start of the next day.
    public func end(in calendar: Calendar) -> Date { adding(days: 1, calendar: calendar).start(in: calendar) }

    /// A local time on this day, `minutes` after local midnight (negative = previous evening).
    public func date(minutesFromMidnight minutes: Int, calendar: Calendar) -> Date {
        calendar.date(byAdding: .minute, value: minutes, to: start(in: calendar)) ?? start(in: calendar)
    }

    public func adding(days: Int, calendar: Calendar) -> LocalDay {
        let noon = calendar.date(byAdding: .hour, value: 12, to: start(in: calendar)) ?? start(in: calendar)
        return LocalDay(calendar.date(byAdding: .day, value: days, to: noon) ?? noon, calendar: calendar)
    }

    /// Every day from `self` through `last`, inclusive.
    public func through(_ last: LocalDay, calendar: Calendar) -> [LocalDay] {
        var out: [LocalDay] = []
        var d = self
        while d <= last { out.append(d); d = d.adding(days: 1, calendar: calendar) }
        return out
    }

    /// "Mon"..."Sun" (the DailySummary v1 enum).
    public func weekdayAbbrev(calendar: Calendar) -> String {
        let names = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        let w = calendar.component(.weekday, from: start(in: calendar))
        return names[(w - 1) % 7]
    }

    public static func < (a: LocalDay, b: LocalDay) -> Bool { (a.year, a.month, a.day) < (b.year, b.month, b.day) }

    public init(from decoder: Decoder) throws {
        let s = try decoder.singleValueContainer().decode(String.self)
        guard let d = LocalDay(string: s) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Bad LocalDay \(s)"))
        }
        self = d
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(description)
    }
}

public extension Calendar {
    /// Gregorian calendar pinned to a time zone (the user's current one by default).
    static func hplLocal(_ tz: TimeZone = .current) -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = tz
        return c
    }
}
