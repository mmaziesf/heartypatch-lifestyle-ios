import Foundation
import HPLCore

/// In-memory aggregates for previews, tests, and Linux. Production uses `SwiftDataStore`.
public final class InMemoryHealthAggregateRepository: HealthAggregateRepository, @unchecked Sendable {
    private var rows: [String: HealthAggregate] = [:]
    private let lock = NSLock()

    public init(_ initial: [HealthAggregate] = []) { for a in initial { rows[a.id] = a } }

    public func replace(days: [LocalDay], with aggregates: [HealthAggregate]) throws {
        lock.lock(); defer { lock.unlock() }
        let set = Set(days)
        rows = rows.filter { !set.contains($0.value.day) }
        for a in aggregates { rows[a.id] = a }
    }

    public func aggregates(from first: LocalDay, through last: LocalDay) throws -> [HealthAggregate] {
        lock.lock(); defer { lock.unlock() }
        return rows.values.filter { $0.day >= first && $0.day <= last }.sorted { $0.id < $1.id }
    }

    public func deleteAll() throws { lock.lock(); defer { lock.unlock() }; rows = [:] }
}

public final class InMemorySyncStateRepository: SyncStateRepository, @unchecked Sendable {
    private var anchors: [String: Data] = [:]
    private var dates: [String: Date] = [:]
    private let lock = NSLock()

    public init() {}

    public func anchor(for key: String) throws -> Data? { lock.lock(); defer { lock.unlock() }; return anchors[key] }
    public func setAnchor(_ data: Data?, for key: String) throws { lock.lock(); defer { lock.unlock() }; anchors[key] = data }
    public func date(for key: String) throws -> Date? { lock.lock(); defer { lock.unlock() }; return dates[key] }
    public func setDate(_ date: Date?, for key: String) throws { lock.lock(); defer { lock.unlock() }; dates[key] = date }
    public func reset() throws { lock.lock(); defer { lock.unlock() }; anchors = [:]; dates = [:] }
}
