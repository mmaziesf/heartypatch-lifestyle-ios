#if canImport(SwiftData)
import Foundation
import SwiftData
import HPLCore

/// Glasses-bridge rows (meals, lifestyle, voice notes, event receipts, bridge state): one Codable payload per row.
@Model final class BridgeRecord {
    /// "kind:key"; unique, so event-id receipts are idempotent at the storage layer too.
    @Attribute(.unique) var uid: String
    var kind: String
    var key: String
    var at: Date
    var payload: Data
    init(kind: String, key: String, at: Date, payload: Data) {
        uid = "\(kind):\(key)"; self.kind = kind; self.key = key; self.at = at; self.payload = payload
    }
}

struct SwiftDataBridgeRecordStore: BridgeRecordStore {
    let store: SwiftDataStore

    func put(kind: String, key: String, at: Date, payload: Data) throws {
        try store.withContext { ctx in
            let uid = "\(kind):\(key)"
            var d = FetchDescriptor<BridgeRecord>(predicate: #Predicate { $0.uid == uid })
            d.fetchLimit = 1
            if let r = try ctx.fetch(d).first {
                r.at = at; r.payload = payload
            } else {
                ctx.insert(BridgeRecord(kind: kind, key: key, at: at, payload: payload))
            }
            try ctx.save()
        }
    }

    func get(kind: String, key: String) throws -> Data? {
        try store.withContext { ctx in
            let uid = "\(kind):\(key)"
            var d = FetchDescriptor<BridgeRecord>(predicate: #Predicate { $0.uid == uid })
            d.fetchLimit = 1
            return try ctx.fetch(d).first?.payload
        }
    }

    func all(kind: String) throws -> [Data] {
        try store.withContext { ctx in try ctx.fetch(FetchDescriptor<BridgeRecord>(predicate: #Predicate { $0.kind == kind })).map(\.payload) }
    }

    func delete(kind: String, key: String) throws {
        try store.withContext { ctx in
            let uid = "\(kind):\(key)"
            try ctx.delete(model: BridgeRecord.self, where: #Predicate { $0.uid == uid })
            try ctx.save()
        }
    }

    func deleteAll() throws {
        try store.withContext { ctx in
            try ctx.delete(model: BridgeRecord.self)
            try ctx.save()
        }
    }
}
#endif
