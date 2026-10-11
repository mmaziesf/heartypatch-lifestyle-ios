import Foundation
import HPLCore

/// Note history (architecture §4.2 Recommendation.status): records each day's generated notes, keeps what the user did,
/// and turns that into the next run's `PipelineContext`. Pure logic over an `InsightsRepository`; stays on device.
public struct NoteLedger: Sendable {
    /// Dismissed topics are moved behind other notes for this many days.
    public static let dismissMemoryDays = 7
    public static let visibleStatuses: Set<NoteStatus> = [.new, .accepted, .done]

    let repository: any InsightsRepository
    let calendar: Calendar

    public init(repository: any InsightsRepository, calendar: Calendar = .hplLocal()) {
        self.repository = repository; self.calendar = calendar
    }

    public func context(today: LocalDay) throws -> PipelineContext {
        let since = today.adding(days: -Self.dismissMemoryDays, calendar: calendar)
        let notes = try repository.notes()
        let dismissed = notes.filter { $0.status == .dismissed && $0.day >= since && $0.recommendation.kind != .clinicianPrompt }
        var suppressed = Set(notes.filter { $0.status == .snoozed && ($0.snoozedUntil ?? today) > today }.map(\.topic))
        // Don't keep suggesting what the user is already testing.
        let running = Set(try repository.experiments().filter { $0.status == .active }.compactMap(\.noteID))
        suppressed.formUnion(notes.filter { running.contains($0.id) }.map(\.topic))
        return PipelineContext(deprioritizedTopics: Set(dismissed.map(\.topic)), suppressedTopics: suppressed)
    }

    /// Stores today's run. The same topic on the same day keeps its id and status across re-runs (pull-to-refresh
    /// doesn't duplicate history); untouched notes that the new run no longer produces are dropped.
    @discardableResult
    public func record(_ recs: [Recommendation], day: LocalDay, now: Date) throws -> [StoredNote] {
        let existing = try repository.notes(on: day)
        var byTopic: [String: StoredNote] = [:]
        for n in existing where byTopic[n.topic] == nil { byTopic[n.topic] = n }

        var upserts: [StoredNote] = []
        for rec in recs {
            if var note = byTopic[rec.topic] {
                if note.status == .new {
                    var r = rec
                    r.id = note.id
                    note.recommendation = r
                    upserts.append(note)
                }
            } else {
                upserts.append(StoredNote(recommendation: rec, day: day, createdAt: now))
            }
        }
        let topics = Set(recs.map(\.topic))
        let stale = existing.filter { $0.status == .new && !topics.contains($0.topic) }.map(\.id)
        try repository.upsert(upserts)
        if !stale.isEmpty { try repository.deleteNotes(ids: stale) }
        return try visible(on: day, order: recs.map(\.topic))
    }

    /// Today's notes the user hasn't dismissed or snoozed, in pipeline order.
    public func visible(on day: LocalDay, order: [String] = []) throws -> [StoredNote] {
        let notes = try repository.notes(on: day).filter { Self.visibleStatuses.contains($0.status) }
        func rank(_ n: StoredNote) -> Int {
            if n.recommendation.kind == .clinicianPrompt { return -1 }
            return order.firstIndex(of: n.topic) ?? order.count
        }
        return notes.sorted { (rank($0), $0.createdAt) < (rank($1), $1.createdAt) }
    }

    public func history() throws -> [StoredNote] { try repository.notes() }

    /// Snooze hides the topic until `snoozeDays` days from now (default: back tomorrow).
    @discardableResult
    public func setStatus(_ id: UUID, _ status: NoteStatus, now: Date, snoozeDays: Int = 1, experimentID: UUID? = nil) throws -> StoredNote {
        guard var note = try repository.notes().first(where: { $0.id == id }) else { throw InsightsError.notFound }
        note.status = status
        note.statusChangedAt = now
        note.snoozedUntil = status == .snoozed ? LocalDay(now, calendar: calendar).adding(days: snoozeDays, calendar: calendar) : nil
        if let experimentID { note.experimentID = experimentID }
        try repository.upsert([note])
        return note
    }

    @discardableResult
    public func setFeedback(_ id: UUID, _ feedback: NoteFeedback?) throws -> StoredNote {
        guard var note = try repository.notes().first(where: { $0.id == id }) else { throw InsightsError.notFound }
        note.feedback = feedback
        try repository.upsert([note])
        return note
    }

    public func export(now: Date) throws -> Data {
        try InsightsExportV1(exportedAt: now, notes: repository.notes(), experiments: repository.experiments()).encoded()
    }
}

public enum InsightsError: Error, Equatable, Sendable {
    case notFound
    case notAnExperiment
    case experimentAlreadyActive
    case experimentNotActive
}
