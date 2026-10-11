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

/// Copy versions for per-source consents. Connecting Apple Health records `Consent(scope: .healthkit, version: HealthConsent.version)`.
public enum HealthConsent {
    public static let version = "healthkit-v1"
}

/// Consent copy for the opt-in cloud tier (architecture §5.5, §7, M6). A new copy version requires re-acknowledgement.
public enum CloudConsent {
    public static let version = "cloud-v1"
    public static let points = [
        "Off unless you turn it on. Each analysis is a separate job that you start, preview and approve.",
        "What's sent: weekly and daily numbers for sleep, resting heart rate, HRV, steps and exercise, rounded and with extremes capped; " +
            "meal times rounded to 30 minutes with simple tags; and, only if you tick it, a few common lab values, rounded.",
        "Never sent: your name, calendar dates, locations, food names, notes, report text, lab or clinic names, device or account ids.",
        "Days are numbered relative to the analysis (D-27 … D0), so no calendar dates leave your phone.",
        "We remove identifiers and coarsen values. A determined party with other data about you could still potentially link it. " +
            "Only use this if you're comfortable with that.",
        "Results are lifestyle observations only, checked by the same safety rules as on-device notes.",
        "You can turn this off at any time; the next analysis is then blocked.",
    ]
}
