import Foundation
import HPLCore

/// Small non-health settings (reminder time, …). Every key starts with `hpl.` so "Delete all" can find them.
public protocol PreferencesStore: Sendable {
    func data(forKey key: String) -> Data?
    func set(_ data: Data?, forKey key: String)
    /// Keys this app owns (prefix `hpl.`).
    func ownedKeys() -> [String]
}

public extension PreferencesStore {
    func value<T: Decodable>(_ type: T.Type, forKey key: String) -> T? { data(forKey: key).flatMap { try? HPLJSON.decoder.decode(T.self, from: $0) } }
    func setValue<T: Encodable>(_ value: T?, forKey key: String) { set(value.flatMap { try? HPLJSON.encoder.encode($0) }, forKey: key) }

    var wipeTarget: any WipeTarget {
        ClosureWipeTarget(name: "Preferences", wipe: { for k in self.ownedKeys() { self.set(nil, forKey: k) } }, remaining: { self.ownedKeys().count })
    }
}

public final class UserDefaultsPreferences: PreferencesStore, @unchecked Sendable {
    public static let prefix = "hpl."
    private let defaults: UserDefaults
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    public func data(forKey key: String) -> Data? { defaults.data(forKey: key) }
    public func set(_ data: Data?, forKey key: String) {
        if let data { defaults.set(data, forKey: key) } else { defaults.removeObject(forKey: key) }
    }
    public func ownedKeys() -> [String] { defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix(Self.prefix) }.sorted() }
}

public final class InMemoryPreferences: PreferencesStore, @unchecked Sendable {
    private var rows: [String: Data] = [:]
    private let lock = NSLock()
    public init() {}
    public func data(forKey key: String) -> Data? { lock.lock(); defer { lock.unlock() }; return rows[key] }
    public func set(_ data: Data?, forKey key: String) { lock.lock(); defer { lock.unlock() }; rows[key] = data }
    public func ownedKeys() -> [String] { lock.lock(); defer { lock.unlock() }; return rows.keys.filter { $0.hasPrefix("hpl.") }.sorted() }
}
