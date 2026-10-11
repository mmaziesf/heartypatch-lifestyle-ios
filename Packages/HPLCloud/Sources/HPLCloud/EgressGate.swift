import HPLCore

/// The ONLY module allowed to send health-derived data off device (M6): consent check -> Anonymizer -> preview -> hash match -> send.
/// M0: hard-disabled. No networking code exists yet.
public enum EgressGate {
    public static let milestone = "M6"

    public enum EgressError: Error, Equatable { case disabled, consentMissing }

    public static func authorize(consents: [Consent]) throws {
        guard consents.contains(where: { $0.scope == .cloudAnalysis && $0.isActive }) else { throw EgressError.consentMissing }
        throw EgressError.disabled
    }
}
