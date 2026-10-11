import Foundation
import HPLCore

/// In-memory notes + experiments for tests, Linux, and the synthetic-fixture Today (example actions aren't persisted).
public final class InMemoryInsightsRepository: InsightsRepository, @unchecked Sendable {
    private var noteRows: [UUID: StoredNote] = [:]
    private var experimentRows: [UUID: Experiment] = [:]
    private let lock = NSLock()

    public init() {}

    public func notes() throws -> [StoredNote] {
        lock.lock(); defer { lock.unlock() }
        return noteRows.values.sorted { ($0.day, $0.createdAt) > ($1.day, $1.createdAt) }
    }

    public func upsert(_ notes: [StoredNote]) throws {
        lock.lock(); defer { lock.unlock() }
        for n in notes { noteRows[n.id] = n }
    }

    public func deleteNotes(ids: [UUID]) throws {
        lock.lock(); defer { lock.unlock() }
        for id in ids { noteRows[id] = nil }
    }

    public func experiments() throws -> [Experiment] {
        lock.lock(); defer { lock.unlock() }
        return experimentRows.values.sorted { $0.startDay > $1.startDay }
    }

    public func save(_ experiment: Experiment) throws { lock.lock(); defer { lock.unlock() }; experimentRows[experiment.id] = experiment }

    public func deleteAll() throws { lock.lock(); defer { lock.unlock() }; noteRows = [:]; experimentRows = [:] }
}
