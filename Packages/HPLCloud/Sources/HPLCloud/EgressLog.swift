import Foundation
import HPLCore

/// Local audit trail of every send attempt (data model `EgressRecord`, kind `cloud_analysis`). Stays on the device.
public struct EgressRecord: Codable, Sendable, Equatable, Identifiable {
    public enum Outcome: String, Codable, Sendable { case sent, failed }
    public var id: UUID
    public var at: Date
    public var requestID: String
    public var sha256: String
    public var bytes: Int
    public var transport: String
    public var leftDevice: Bool
    public var outcome: Outcome
    public var accepted: Int
    public var blocked: Int
    /// The exact JSON that was (or would have been) sent, so you can see later what left the phone.
    public var payloadJSON: String

    public init(id: UUID = UUID(), at: Date, requestID: String, sha256: String, bytes: Int, transport: String, leftDevice: Bool,
                outcome: Outcome, accepted: Int, blocked: Int, payloadJSON: String) {
        self.id = id; self.at = at; self.requestID = requestID; self.sha256 = sha256; self.bytes = bytes; self.transport = transport
        self.leftDevice = leftDevice; self.outcome = outcome; self.accepted = accepted; self.blocked = blocked; self.payloadJSON = payloadJSON
    }
}

public protocol EgressLog: Sendable {
    func append(_ record: EgressRecord) throws
    func all() throws -> [EgressRecord]
}

/// Egress log on the shared keyed record store (SwiftData in the app, memory in tests).
public struct RecordStoreEgressLog: EgressLog {
    static let kind = "egress"
    let store: any BridgeRecordStore
    public init(store: any BridgeRecordStore) { self.store = store }

    public func append(_ record: EgressRecord) throws {
        try store.put(kind: Self.kind, key: record.id.uuidString, at: record.at, payload: try HPLJSON.encoder.encode(record))
    }

    public func all() throws -> [EgressRecord] {
        try store.all(kind: Self.kind).compactMap { try? HPLJSON.decoder.decode(EgressRecord.self, from: $0) }.sorted { $0.at > $1.at }
    }
}
