import Foundation
import Observation
import HPLCore
import HPLCloud

/// Cloud-analysis wiring handed to the app. The shipping app uses `DemoCloudTransport` (nothing leaves the device).
public struct CloudServices: Sendable {
    /// Returns the user's last `days` daily summaries ending yesterday, or `nil` when Apple Health isn't connected
    /// (the model then uses the labeled synthetic example).
    public typealias WindowSource = @Sendable (_ days: Int) async -> CloudWindow?
    public let transport: any CloudTransport
    public let log: (any EgressLog)?
    public init(transport: any CloudTransport, log: (any EgressLog)?) { self.transport = transport; self.log = log }
}

/// User-facing strings for cloud analysis (kept here so the copy blocklist test covers them).
public enum CloudCopy {
    public static let exampleNote = "Apple Health isn't connected, so this uses a synthetic example, not your data."
    public static let previewNote = "This is exactly what will be sent. Nothing leaves until you tap Send."
    public static let resultsNote = "Lifestyle observations only, checked by the same safety rules as on-device notes."

    public static func transport(id: String, leavesDevice: Bool) -> String {
        leavesDevice ? "Remote service (\(id))" : "Demo analyzer on this iPhone. Nothing leaves the device in this version."
    }

    public static func error(_ e: Error) -> String {
        switch e as? EgressGate.EgressError {
        case .consentMissing: "Cloud analysis is off. Turn it on in Settings first."
        case .anonymizer(.insufficientData(let have, let need)): "Needs at least \(need) days with data in the window; found \(have)."
        case .anonymizer(.windowNotAllowed): "Choose a 28 or 56 day window."
        case .anonymizer(.mixedProvenance): "The window mixes example and device data, so it can't be sent."
        case .auditFailed: "The payload failed the privacy check, so it wasn't sent."
        case .hashMismatch: "The payload changed after preview, so it wasn't sent. Prepare it again."
        case .transportFailed: "The analysis service couldn't be reached. Nothing else was sent."
        case .badResponse: "The analysis came back in an unexpected format and was discarded."
        case nil: "Something went wrong. Nothing was sent."
        }
    }
}

/// Opt-in cloud analysis (§5.5, §9.2): consent → choose window → preview → approve → results. Platform-neutral.
@MainActor @Observable
public final class CloudModel {
    public enum Phase: Equatable, Sendable {
        case idle, preparing
        case preview(PreparedJob)
        case sending(PreparedJob)
        case done(CloudResult)
        case failed(String)
    }

    public var policy = AnonymizationPolicy()
    public private(set) var phase: Phase = .idle
    public private(set) var history: [EgressRecord] = []
    /// True when the current job uses the synthetic example (Apple Health not connected).
    public private(set) var usingExample = false

    private let gate: EgressGate
    private let log: (any EgressLog)?
    private let consents: any ConsentRepository
    private let windowSource: CloudServices.WindowSource?
    private let calendar: Calendar
    private let now: @Sendable () -> Date

    public init(services: CloudServices, consents: any ConsentRepository, windowSource: CloudServices.WindowSource?,
                calendar: Calendar = .hplLocal(), now: @escaping @Sendable () -> Date = Date.init,
                makeRequestID: @escaping @Sendable () -> UUID = { UUID() }) {
        gate = EgressGate(consents: consents, transport: services.transport, log: services.log, now: now, makeRequestID: makeRequestID)
        log = services.log
        self.consents = consents; self.windowSource = windowSource; self.calendar = calendar; self.now = now
        reloadHistory()
    }

    public var hasConsent: Bool { gate.hasConsent() }
    public var transportLabel: String { CloudCopy.transport(id: gate.transportID, leavesDevice: gate.transportLeavesDevice) }

    public func grantConsent() {
        try? consents.save(Consent(scope: .cloudAnalysis, version: CloudConsent.version, grantedAt: now()))
    }

    /// Revokes every active cloud consent and drops any prepared job; the next `prepare`/`send` is refused by the gate.
    public func revokeConsent() {
        let at = now()
        for var c in (try? consents.all()) ?? [] where c.scope == .cloudAnalysis && c.isActive {
            c.revokedAt = at
            try? consents.save(c)
        }
        phase = .idle
    }

    /// Builds the anonymized payload and preview. Nothing is sent.
    public func prepare() async {
        phase = .preparing
        let days = policy.windowDays
        var window = await windowSource?(days)
        usingExample = window == nil
        if window == nil {
            let yesterday = LocalDay(now(), calendar: calendar).adding(days: -1, calendar: calendar)
            window = SyntheticWindow.make(days: days, anchor: yesterday, calendar: calendar, seed: 7)
        }
        guard let window else { return }
        do { phase = .preview(try gate.prepare(window, policy: policy)) } catch { phase = .failed(CloudCopy.error(error)) }
    }

    /// Sends the previewed job; approval is the hash the user saw.
    public func send() async {
        guard case .preview(let job) = phase else { return }
        phase = .sending(job)
        do { phase = .done(try await gate.send(job, approvedSHA256: job.preview.sha256)) } catch { phase = .failed(CloudCopy.error(error)) }
        reloadHistory()
    }

    public func cancel() { phase = .idle }

    public func reloadHistory() { history = (try? log?.all()) ?? [] }
}
