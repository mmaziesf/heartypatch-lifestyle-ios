import Foundation
import HPLCore

/// Confirmed meals → DailySummary `meals[]` (§5.3 step 4, §6.3). Only time, a fixed label and controlled tags leave
/// the meal: item names, kcal, producer and free text never reach the summary (and so never reach the LLM or cloud).
public enum MealSummary {
    /// Late = started at or after 21:00, or before 04:00 local.
    public static let lateFromMinute = 21 * 60
    public static let lateUntilMinute = 4 * 60
    /// A `lifestyle.event` alcohol/caffeine this close to a meal tags the meal.
    public static let lifestyleWindow: TimeInterval = 90 * 60

    public static func label(minuteOfDay m: Int) -> String {
        switch m {
        case 300..<660: "breakfast"
        case 660..<960: "lunch"
        case 1020..<1320: "dinner"
        default: "snack"
        }
    }

    public static func meals(on day: LocalDay, meals: [MealLog], lifestyle: [LifestyleLog], calendar: Calendar) -> [DailySummaryV1.Meal] {
        meals.filter { $0.status == .confirmed && LocalDay($0.startedAt, calendar: calendar) == day }
            .sorted { $0.startedAt < $1.startedAt }
            .map { m in
                let c = calendar.dateComponents([.hour, .minute], from: m.startedAt)
                let minute = (c.hour ?? 0) * 60 + (c.minute ?? 0)
                var tags = m.tags
                if minute >= lateFromMinute || minute < lateUntilMinute { tags.append(MealTag.late.rawValue) }
                for l in lifestyle where abs(l.occurredAt.timeIntervalSince(m.startedAt)) <= lifestyleWindow {
                    if l.kind == .alcohol { tags.append(MealTag.alcohol.rawValue) }
                    if l.kind == .caffeine { tags.append(MealTag.caffeine.rawValue) }
                }
                return DailySummaryV1.Meal(tLocal: String(format: "%02d:%02d", minute / 60, minute % 60), label: label(minuteOfDay: minute),
                                           tags: MealTag.filter(tags))
            }
    }
}
