import Foundation
import HPLCore

/// One line of an `.hplevent` file (Spec/hpl.signed_event.v1.schema.json).
/// `body` is the producer's exact event JSON string, so verification needs no canonicalization.
public struct SignedEvent: Codable, Sendable, Equatable {
    public static let specID = "hpl.signed_event.v1"
    public static let maxBodyBytes = 16_384

    public var spec: String
    public var pairingID: String
    public var ts: Int64
    public var sig: String
    public var body: String

    enum CodingKeys: String, CodingKey { case spec, pairingID = "pairing_id", ts, sig, body }

    public static func signingInput(pairingID: String, ts: Int64, body: String) -> Data {
        Data("\(specID)\n\(pairingID)\n\(ts)\n\(body)".utf8)
    }

    /// Producer side (reference; the same algorithm as scripts/hpl_event_sign.py).
    public static func sign(body: String, pairingID: String, secret: [UInt8], ts: Int64) -> SignedEvent {
        let sig = HMACSHA256.hex(key: secret, message: signingInput(pairingID: pairingID, ts: ts, body: body))
        return SignedEvent(spec: specID, pairingID: pairingID, ts: ts, sig: sig, body: body)
    }

    public func verifies(secret: [UInt8]) -> Bool {
        HMACSHA256.equal(HMACSHA256.hex(key: secret, message: Self.signingInput(pairingID: pairingID, ts: ts, body: body)), sig)
    }

    /// One JSON line (compact) for an `.hplevent` file.
    public func line() throws -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(bytes: try enc.encode(self), encoding: .utf8) ?? ""
    }
}
