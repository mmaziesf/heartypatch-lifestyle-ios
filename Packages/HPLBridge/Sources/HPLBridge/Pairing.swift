import Foundation
import HPLCore

/// Pairing payload shown as a QR code / copyable link: `hplpair://v1?id=<16 chars>&k=<base64url 32-byte secret>`.
/// The producer (Glance, VisionClaw, a script) stores id + secret and signs every event with them (§8.2).
public struct PairingPayload: Sendable, Equatable {
    public static let secretBytes = 32
    public var id: String
    public var secret: [UInt8]

    public init(id: String, secret: [UInt8]) { self.id = id; self.secret = secret }

    /// Fresh id + secret from the system CSPRNG.
    public static func generate() -> PairingPayload {
        var rng = SystemRandomNumberGenerator()
        let alphabet = Array("0123456789abcdefghijklmnopqrstuvwxyz")
        let id = String((0..<16).map { _ in alphabet[Int(rng.next(upperBound: UInt32(alphabet.count)))] })
        return PairingPayload(id: id, secret: (0..<secretBytes).map { _ in UInt8.random(in: 0...255, using: &rng) })
    }

    public var uri: String { "hplpair://v1?id=\(id)&k=\(Base64URL.encode(secret))" }
    /// 8-char code Glance shows after pairing; matching codes = same secret.
    public var code: String { PairingCode.of(secret) }

    public init?(uri: String) {
        guard let c = URLComponents(string: uri), c.scheme == "hplpair", c.host == "v1",
              let id = c.queryItems?.first(where: { $0.name == "id" })?.value, Self.isValidID(id),
              let k = c.queryItems?.first(where: { $0.name == "k" })?.value, let secret = Base64URL.decode(k),
              secret.count == Self.secretBytes else { return nil }
        self.init(id: id, secret: secret)
    }

    public static func isValidID(_ id: String) -> Bool {
        id.count == 16 && id.allSatisfy { ($0.isASCII && $0.isLowercase && $0.isLetter) || ($0.isASCII && $0.isNumber) }
    }
}

/// Where pairing secrets live. The app uses the Keychain; tests and Linux use memory.
public protocol PairingSecretStore: Sendable {
    func secret(for pairingID: String) throws -> [UInt8]?
    func setSecret(_ secret: [UInt8], for pairingID: String) throws
    func removeSecret(for pairingID: String) throws
    /// "Delete all" (§10): every pairing secret this app stored.
    func removeAll() throws
    func count() throws -> Int
}

public extension PairingSecretStore {
    var wipeTarget: any WipeTarget {
        ClosureWipeTarget(name: "Keychain pairing secrets", wipe: { try self.removeAll() }, remaining: { try self.count() })
    }
}

public final class InMemoryPairingSecretStore: PairingSecretStore, @unchecked Sendable {
    private var rows: [String: [UInt8]] = [:]
    private let lock = NSLock()
    public init(_ initial: [String: [UInt8]] = [:]) { rows = initial }
    public func secret(for pairingID: String) throws -> [UInt8]? { lock.lock(); defer { lock.unlock() }; return rows[pairingID] }
    public func setSecret(_ secret: [UInt8], for pairingID: String) throws { lock.lock(); defer { lock.unlock() }; rows[pairingID] = secret }
    public func removeSecret(for pairingID: String) throws { lock.lock(); defer { lock.unlock() }; rows[pairingID] = nil }
    public func removeAll() throws { lock.lock(); defer { lock.unlock() }; rows = [:] }
    public func count() throws -> Int { lock.lock(); defer { lock.unlock() }; return rows.count }
}

#if canImport(Security)
import Security

/// Keychain-backed secrets: generic password, this-device-only, available after first unlock (so a background import works).
/// Not exercised in CI (no keychain on Linux; simulator keychains need entitlements); `InMemoryPairingSecretStore` covers the logic.
public struct KeychainPairingSecretStore: PairingSecretStore {
    let service: String
    public init(service: String = "com.hpl.lifestyle.pairing") { self.service = service }

    private func query(_ id: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: id]
    }

    public func secret(for pairingID: String) throws -> [UInt8]? {
        var q = query(pairingID)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = out as? Data else { throw PairingError.keychain(status) }
        return [UInt8](data)
    }

    public func setSecret(_ secret: [UInt8], for pairingID: String) throws {
        try removeSecret(for: pairingID)
        var q = query(pairingID)
        q[kSecValueData as String] = Data(secret)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(q as CFDictionary, nil)
        guard status == errSecSuccess else { throw PairingError.keychain(status) }
    }

    public func removeSecret(for pairingID: String) throws {
        let status = SecItemDelete(query(pairingID) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw PairingError.keychain(status) }
    }

    /// Every generic password under this service (all pairings, including any orphaned by a crash mid-pair).
    public func removeAll() throws {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
        let status = SecItemDelete(q as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw PairingError.keychain(status) }
    }

    public func count() throws -> Int {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecMatchLimit as String: kSecMatchLimitAll, kSecReturnAttributes as String: true]
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecItemNotFound { return 0 }
        guard status == errSecSuccess else { throw PairingError.keychain(status) }
        return (out as? [[String: Any]])?.count ?? 0
    }
}
#endif

public enum PairingError: Error, Equatable { case keychain(Int32), unknownPairing }

/// Pair / list / revoke. Metadata goes to `BridgeState`; the secret only to the secret store.
public struct PairingManager: Sendable {
    let repository: any MealRepository
    let secrets: any PairingSecretStore
    public init(repository: any MealRepository, secrets: any PairingSecretStore) { self.repository = repository; self.secrets = secrets }

    @discardableResult
    public func pair(label: String, now: Date = Date(), payload: PairingPayload = .generate()) throws -> PairingPayload {
        try secrets.setSecret(payload.secret, for: payload.id)
        var state = try repository.bridgeState()
        state.pairings.removeAll { $0.id == payload.id }
        state.pairings.append(PairingInfo(id: payload.id, label: String(label.prefix(40)), createdAt: now, code: payload.code))
        try repository.save(state)
        return payload
    }

    /// The pairing's code, from metadata or (older pairings) recomputed from the Keychain secret.
    public func code(for info: PairingInfo) -> String? {
        info.code ?? (try? secrets.secret(for: info.id)).flatMap { $0.map(PairingCode.of) }
    }

    public func revoke(id: String) throws {
        try secrets.removeSecret(for: id)
        var state = try repository.bridgeState()
        state.pairings.removeAll { $0.id == id }
        try repository.save(state)
    }
}
