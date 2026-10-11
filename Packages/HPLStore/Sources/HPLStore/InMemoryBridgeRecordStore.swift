import Foundation
import HPLCore

/// In-memory `BridgeRecordStore` for tests, Linux, and example mode.
public final class InMemoryBridgeRecordStore: BridgeRecordStore, @unchecked Sendable {
    private var rows: [String: [String: Data]] = [:]
    private let lock = NSLock()
    public init() {}

    public func put(kind: String, key: String, at: Date, payload: Data) throws {
        lock.lock(); defer { lock.unlock() }
        rows[kind, default: [:]][key] = payload
    }
    public func get(kind: String, key: String) throws -> Data? { lock.lock(); defer { lock.unlock() }; return rows[kind]?[key] }
    public func all(kind: String) throws -> [Data] { lock.lock(); defer { lock.unlock() }; return Array((rows[kind] ?? [:]).values) }
    public func delete(kind: String, key: String) throws { lock.lock(); defer { lock.unlock() }; rows[kind]?[key] = nil }
    public func deleteAll() throws { lock.lock(); defer { lock.unlock() }; rows = [:] }
}

public extension KeyedMealRepository {
    static func inMemory() -> KeyedMealRepository { KeyedMealRepository(store: InMemoryBridgeRecordStore()) }
}
