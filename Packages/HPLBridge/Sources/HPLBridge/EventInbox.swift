import Foundation
import HPLCore

/// Validates and de-duplicates `hpl.event.v1` events (architecture §8.2).
/// M0: decode + idempotency + unknown-type handling. M5 adds HMAC verification, clock-skew check, persistence.
public actor EventInbox {
    public enum Outcome: Sendable, Equatable {
        case accepted(HPLEventV1)
        case duplicate(eventID: String)
        case ignoredUnknownType(String)
        case rejected(reason: String)
    }

    private var seen: Set<String> = []
    public init() {}

    public func ingest(_ data: Data) -> Outcome {
        let event: HPLEventV1
        do {
            event = try HPLJSON.decoder.decode(HPLEventV1.self, from: data)
        } catch {
            return .rejected(reason: "decode: \(error)")
        }
        guard seen.insert(event.eventID).inserted else { return .duplicate(eventID: event.eventID) }
        if case .unknown(let raw) = event.type { return .ignoredUnknownType(raw) }
        do {
            _ = try event.typedPayload()
        } catch {
            return .rejected(reason: "payload for \(event.type.rawValue)")
        }
        return .accepted(event)
    }
}
