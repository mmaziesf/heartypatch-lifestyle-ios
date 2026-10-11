import Foundation

public enum ConsentScope: String, Codable, Sendable, CaseIterable {
    case disclaimer, healthkit, labs, glasses, cloudAnalysis = "cloud_analysis", mediaRetention = "media_retention"
}

public struct Consent: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var scope: ConsentScope
    public var version: String
    public var grantedAt: Date
    public var revokedAt: Date?

    public init(id: UUID = UUID(), scope: ConsentScope, version: String, grantedAt: Date, revokedAt: Date? = nil) {
        self.id = id; self.scope = scope; self.version = version; self.grantedAt = grantedAt; self.revokedAt = revokedAt
    }

    public var isActive: Bool { revokedAt == nil }
}

/// Storage boundary for consents (architecture §4: keep the store behind protocols from day one).
public protocol ConsentRepository: Sendable {
    func all() throws -> [Consent]
    func save(_ consent: Consent) throws
}

public extension ConsentRepository {
    /// Active consent for `scope` at exactly `version` (a new copy version requires re-acknowledgement).
    func active(_ scope: ConsentScope, version: String) throws -> Consent? {
        try all().last { $0.scope == scope && $0.version == version && $0.isActive }
    }
}
