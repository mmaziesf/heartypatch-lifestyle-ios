import Foundation
import HPLCore

/// M0 consent store: append-only JSON in UserDefaults. Holds no health data.
/// M1 moves consents into the SwiftData store (NSFileProtectionComplete) behind the same protocol.
public final class UserDefaultsConsentRepository: ConsentRepository, @unchecked Sendable {
    private let defaults: UserDefaults
    private let key: String
    private let lock = NSLock()

    public init(defaults: UserDefaults = .standard, key: String = "hpl.consents.v1") {
        self.defaults = defaults
        self.key = key
    }

    public func all() throws -> [Consent] {
        lock.lock(); defer { lock.unlock() }
        return try load()
    }

    public func save(_ consent: Consent) throws {
        lock.lock(); defer { lock.unlock() }
        var list = try load()
        if let i = list.firstIndex(where: { $0.id == consent.id }) { list[i] = consent } else { list.append(consent) }
        defaults.set(try HPLJSON.encoder.encode(list), forKey: key)
    }

    private func load() throws -> [Consent] {
        guard let data = defaults.data(forKey: key) else { return [] }
        return try HPLJSON.decoder.decode([Consent].self, from: data)
    }
}

/// In-memory store for previews and tests.
public final class InMemoryConsentRepository: ConsentRepository, @unchecked Sendable {
    private var items: [Consent]
    private let lock = NSLock()
    public init(_ items: [Consent] = []) { self.items = items }
    public func all() throws -> [Consent] { lock.lock(); defer { lock.unlock() }; return items }
    public func save(_ consent: Consent) throws {
        lock.lock(); defer { lock.unlock() }
        if let i = items.firstIndex(where: { $0.id == consent.id }) { items[i] = consent } else { items.append(consent) }
    }
}
