import Foundation
import HPLCore

/// A prepared, not-yet-sent job. `body` is what the preview shows, what gets hashed, and what the transport receives.
public struct PreparedJob: Sendable, Equatable {
    public var payload: CloudPayloadV1
    public var body: Data
    public var sha256: String
    /// Local only: maps relative day indices back to calendar dates on this device. Never in `body`.
    public var anchor: LocalDay
    public var calendar: Calendar
    public var preview: CloudPreview

    public var bodyText: String { String(bytes: body, encoding: .utf8) ?? "" }

    /// "daily.12.steps" → the calendar day of that row; "weeks.3…" → first day of that week; else the anchor.
    public func localDay(forEvidence path: String) -> String {
        let parts = path.split(separator: ".")
        guard parts.count >= 2, let i = Int(parts[1]) else { return anchor.description }
        if parts[0] == "daily", payload.daily.indices.contains(i) {
            return anchor.adding(days: payload.daily[i].day, calendar: calendar).description
        }
        if parts[0] == "weeks", payload.weeks.indices.contains(i) {
            return anchor.adding(days: payload.weeks[i].week * 7 - 6, calendar: calendar).description
        }
        return anchor.description
    }
}

public struct CloudResult: Sendable, Equatable {
    public var recommendations: [Recommendation]
    public var blocked: Int
    public var record: EgressRecord
}

/// The ONLY path for health-derived data to leave the device (§5.5, §7.4):
/// consent → Anonymizer → audit → preview (+ SHA-256) → user approves that hash → consent re-checked → hash re-checked →
/// audit re-run on the exact bytes → transport → response schema + OutputGuard → local recommendations + log.
public struct EgressGate: Sendable {
    public static let maxPayloadBytes = 16_384
    public static let maxResponseBytes = 65_536

    public enum EgressError: Error, Equatable {
        case consentMissing
        case anonymizer(AnonymizerError)
        case auditFailed([String])
        case hashMismatch
        case transportFailed
        case badResponse(CloudResponseError)
    }

    let consents: any ConsentRepository
    let transport: any CloudTransport
    let log: (any EgressLog)?
    let now: @Sendable () -> Date
    let makeRequestID: @Sendable () -> UUID

    public init(consents: any ConsentRepository, transport: any CloudTransport, log: (any EgressLog)? = nil,
                now: @escaping @Sendable () -> Date = { Date() }, makeRequestID: @escaping @Sendable () -> UUID = { UUID() }) {
        self.consents = consents; self.transport = transport; self.log = log; self.now = now; self.makeRequestID = makeRequestID
    }

    public var transportID: String { transport.id }
    public var transportLeavesDevice: Bool { transport.leavesDevice }

    public func hasConsent() -> Bool { (try? consents.active(.cloudAnalysis, version: CloudConsent.version)) != nil }

    /// Builds the job and its preview. Nothing is sent.
    public func prepare(_ window: CloudWindow, policy: AnonymizationPolicy) throws -> PreparedJob {
        guard hasConsent() else { throw EgressError.consentMissing }
        let payload: CloudPayloadV1
        do { payload = try Anonymizer.payload(window, policy: policy, requestID: makeRequestID()) } catch let e as AnonymizerError {
            throw EgressError.anonymizer(e)
        }
        let body = try payload.encoded()
        let problems = PayloadAudit.violations(body, maxBytes: Self.maxPayloadBytes)
        guard problems.isEmpty else { throw EgressError.auditFailed(problems) }
        return PreparedJob(payload: payload, body: body, sha256: SHA256Digest.hex(body), anchor: window.anchor, calendar: window.calendar,
                           preview: CloudPreview(payload, body: body))
    }

    /// Sends exactly `job.body`, only if the user approved this hash and consent is still active.
    public func send(_ job: PreparedJob, approvedSHA256: String) async throws -> CloudResult {
        guard hasConsent() else { throw EgressError.consentMissing }
        let hash = SHA256Digest.hex(job.body)
        guard hash == approvedSHA256, hash == job.sha256 else { throw EgressError.hashMismatch }
        let problems = PayloadAudit.violations(job.body, maxBytes: Self.maxPayloadBytes)
        guard problems.isEmpty else { throw EgressError.auditFailed(problems) }

        var record = EgressRecord(at: now(), requestID: job.payload.requestID, sha256: hash, bytes: job.body.count, transport: transport.id,
                                  leftDevice: transport.leavesDevice, outcome: .failed, accepted: 0, blocked: 0, payloadJSON: job.bodyText)
        let response: Data
        do {
            response = try await transport.post(job.body, requestID: job.payload.requestID)
        } catch {
            try? log?.append(record)
            throw EgressError.transportFailed
        }
        guard response.count <= Self.maxResponseBytes else { try? log?.append(record); throw EgressError.badResponse(.notJSON) }
        let out: CloudResponseProcessor.Output
        do { out = try CloudResponseProcessor().process(response, job: job, transportID: transport.id) } catch let e as CloudResponseError {
            try? log?.append(record)
            throw EgressError.badResponse(e)
        }
        record.outcome = .sent
        record.accepted = out.recommendations.count
        record.blocked = out.blocked
        try? log?.append(record)
        return CloudResult(recommendations: out.recommendations, blocked: out.blocked, record: record)
    }
}
