import Foundation
import Observation
import HPLCore

/// Local notifications. The app posts at most one per day, and it never carries health values (lock screens are public).
public protocol ReminderScheduler: Sendable {
    func requestAuthorization() async -> Bool
    func scheduleDaily(hour: Int, minute: Int, title: String, body: String) async throws
    func cancelAll() async
    func pendingCount() async -> Int
}

public extension ReminderScheduler {
    var wipeTarget: any WipeTarget {
        ClosureWipeTarget(name: "Scheduled reminders", wipe: { await self.cancelAll() }, remaining: { await self.pendingCount() })
    }
}

public struct ReminderSettings: Codable, Sendable, Equatable {
    public var enabled = false
    public var hour = 8
    public var minute = 0
    public init(enabled: Bool = false, hour: Int = 8, minute: Int = 0) { self.enabled = enabled; self.hour = hour; self.minute = minute }
}

public enum ReminderCopy {
    public static let title = "HP Lifestyle"
    /// Deliberately content-free: no values, no metric names, nothing that reads as a health alert.
    public static let body = "Your daily notes are ready when you are."
    public static let denied = "Notifications are off for HP Lifestyle. You can allow them in iOS Settings › Notifications."
    public static let explainer = "One reminder a day at the time you pick. It never shows your data on the lock screen."
}

/// Settings › Daily reminder (§5.4 step 6, §9.2). Off by default; enabling asks iOS for permission.
@MainActor @Observable
public final class ReminderModel {
    public static let key = "hpl.reminder.v1"
    public private(set) var settings: ReminderSettings
    public private(set) var notice: String?

    private let scheduler: (any ReminderScheduler)?
    private let prefs: any PreferencesStore

    public init(scheduler: (any ReminderScheduler)?, prefs: any PreferencesStore) {
        self.scheduler = scheduler; self.prefs = prefs
        settings = prefs.value(ReminderSettings.self, forKey: Self.key) ?? ReminderSettings()
    }

    public var isAvailable: Bool { scheduler != nil }

    public func setEnabled(_ on: Bool) async {
        guard let scheduler else { return }
        notice = nil
        if on, !(await scheduler.requestAuthorization()) {
            notice = ReminderCopy.denied
            settings.enabled = false
        } else {
            settings.enabled = on
        }
        await apply()
    }

    public func setTime(hour: Int, minute: Int) async {
        settings.hour = min(max(hour, 0), 23)
        settings.minute = min(max(minute, 0), 59)
        await apply()
    }

    private func apply() async {
        prefs.setValue(settings, forKey: Self.key)
        guard let scheduler else { return }
        await scheduler.cancelAll()
        guard settings.enabled else { return }
        do {
            try await scheduler.scheduleDaily(hour: settings.hour, minute: settings.minute, title: ReminderCopy.title, body: ReminderCopy.body)
        } catch {
            notice = "Could not schedule the reminder."
        }
    }
}

#if canImport(UserNotifications)
import UserNotifications

/// `UNUserNotificationCenter`, one repeating calendar trigger with a fixed identifier.
public struct UserNotificationReminderScheduler: ReminderScheduler {
    static let id = "com.hpl.daily-reminder"
    public init() {}

    public func requestAuthorization() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
    }

    public func scheduleDaily(hour: Int, minute: Int, title: String, body: String) async throws {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let trigger = UNCalendarNotificationTrigger(dateMatching: DateComponents(hour: hour, minute: minute), repeats: true)
        try await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: Self.id, content: content, trigger: trigger))
    }

    public func cancelAll() async {
        let center = UNUserNotificationCenter.current()
        center.removeAllPendingNotificationRequests()
        center.removeAllDeliveredNotifications()
    }

    public func pendingCount() async -> Int { await UNUserNotificationCenter.current().pendingNotificationRequests().count }
}
#endif
