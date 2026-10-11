import Foundation
import Observation
import HPLCore
import HPLInference
import HPLPipeline

/// App state for the M0 shell. Platform-neutral so it is unit-tested on Linux and macOS.
@MainActor @Observable
public final class AppModel {
    public private(set) var disclaimerAcknowledgedAt: Date?
    public private(set) var summary: DailySummaryV1?
    public private(set) var recommendations: [Recommendation] = []
    public private(set) var errorMessage: String?

    private let consents: any ConsentRepository
    private let pipeline: DailyPipeline
    private let now: @Sendable () -> Date

    public init(consents: any ConsentRepository, pipeline: DailyPipeline = DailyPipeline(), now: @escaping @Sendable () -> Date = Date.init) {
        self.consents = consents
        self.pipeline = pipeline
        self.now = now
        disclaimerAcknowledgedAt = try? consents.active(.disclaimer, version: Disclaimer.version)?.grantedAt
    }

    public var needsDisclaimer: Bool { disclaimerAcknowledgedAt == nil }
    public var engineName: String { pipeline.engine.id }

    public func acknowledgeDisclaimer() {
        let consent = Consent(scope: .disclaimer, version: Disclaimer.version, grantedAt: now())
        do {
            try consents.save(consent)
            disclaimerAcknowledgedAt = consent.grantedAt
        } catch {
            errorMessage = "Could not save acknowledgement."
        }
    }

    /// M0: Today is driven by the labeled synthetic fixture. M1 swaps in the HealthKit-built summary.
    public func loadToday() async {
        do {
            let s = try SyntheticFixtures.dailySummaryD0()
            summary = s
            recommendations = try await pipeline.run(s)
        } catch {
            errorMessage = "Could not build today's notes."
        }
    }
}
