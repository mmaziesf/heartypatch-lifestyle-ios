import Foundation
import HPLCore

/// Turns verified events into timeline rows (§5.3). Meals arrive `pending`; the user confirms them in the Meals tab.
/// Two producer shapes are supported:
/// - single-shot `meal.logged` (rayban-vlm-poc "Glance": "log this meal" → one self-contained meal), and
/// - sessions `meal.start` / `meal.items`* / `meal.photo`* / `meal.end` keyed by `session_id` (VisionClaw-style), in any order.
public struct MealAssembler: Sendable {
    /// An open glasses session with no `meal.end` is closed this long after it started.
    public static let autoCloseAfter: TimeInterval = 90 * 60
    public static let maxItemsPerMeal = 50

    let repository: any MealRepository
    public init(repository: any MealRepository) { self.repository = repository }

    public func apply(_ event: HPLEventV1, now: Date) throws -> EventReceipt.Disposition {
        guard let payload = try event.typedPayload() else { return .ignoredUnknownType }
        switch payload {
        case .mealLogged(let p):
            try repository.save(MealLog(sessionKey: event.eventID, startedAt: event.occurredAt, endedAt: event.occurredAt, tz: event.tz,
                                        items: Array(p.items.prefix(Self.maxItemsPerMeal)), tags: p.tags ?? [], status: .pending,
                                        source: .glasses, producer: event.producer.name, processing: event.producer.processing, updatedAt: now))
            return .applied
        case .mealStart:
            try updateSession(event, now: now) { m in m.startedAt = min(m.startedAt, event.occurredAt) }
        case .mealItems(let p):
            try updateSession(event, now: now) { m in
                m.items = Array((m.items + p.items).prefix(Self.maxItemsPerMeal))
                m.tags = MealTag.filter(m.tags + (p.tags ?? []))
            }
        case .mealEnd:
            try updateSession(event, now: now) { m in m.endedAt = max(m.endedAt ?? event.occurredAt, event.occurredAt) }
        case .mealPhoto:
            // §8.4: no photos by default, and M5 has no photo import path; only count that one was offered.
            try updateSession(event, now: now) { m in m.photosDropped += 1 }
            return .droppedPhoto
        case .lifestyleEvent(let p):
            try repository.save(LifestyleLog(id: event.eventID, occurredAt: event.occurredAt, tz: event.tz, kind: p.kind, amount: p.amount, unit: p.unit))
        case .voiceNote(let p):
            try repository.save(VoiceNoteLog(id: event.eventID, occurredAt: event.occurredAt, text: String(p.text.prefix(1000)), intent: p.intent))
        case .ping:
            return .ignoredPing
        }
        return .applied
    }

    private func updateSession(_ event: HPLEventV1, now: Date, _ change: (inout MealLog) -> Void) throws {
        guard let session = event.sessionID else { return }
        var meal = try repository.meals().first { $0.sessionKey == session && $0.source == .glasses }
            ?? MealLog(sessionKey: session, startedAt: event.occurredAt, tz: event.tz, status: .pending, source: .glasses,
                       producer: event.producer.name, processing: event.producer.processing, updatedAt: now)
        let before = meal
        change(&meal)
        // New content on an already-confirmed meal needs a fresh look; a rejected meal stays rejected.
        if meal.status == .confirmed, meal.items != before.items { meal.status = .pending }
        meal.updatedAt = now
        try repository.save(meal)
    }

    /// Closes glasses sessions that never sent `meal.end`. Returns how many were closed.
    @discardableResult
    public func closeStale(now: Date) throws -> Int {
        var closed = 0
        for var m in try repository.meals() where m.isOpen && now.timeIntervalSince(m.startedAt) >= Self.autoCloseAfter {
            m.endedAt = m.startedAt.addingTimeInterval(Self.autoCloseAfter)
            m.updatedAt = now
            try repository.save(m)
            closed += 1
        }
        return closed
    }
}
