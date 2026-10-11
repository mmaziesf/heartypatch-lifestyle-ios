#if canImport(SwiftData)
import Foundation
import SwiftData
import HPLCore

/// Notes and experiments are low-volume and always read whole: one Codable payload per row, plus sort/filter keys.
@Model final class StoredNoteRecord {
    @Attribute(.unique) var id: UUID
    var day: String
    var createdAt: Date
    var payload: Data
    init(_ n: StoredNote) throws { id = n.id; day = n.day.description; createdAt = n.createdAt; payload = try HPLJSON.encoder.encode(n) }
    var value: StoredNote? { try? HPLJSON.decoder.decode(StoredNote.self, from: payload) }
}

@Model final class ExperimentRecord {
    @Attribute(.unique) var id: UUID
    var startDay: String
    var payload: Data
    init(_ e: Experiment) throws { id = e.id; startDay = e.startDay.description; payload = try HPLJSON.encoder.encode(e) }
    var value: Experiment? { try? HPLJSON.decoder.decode(Experiment.self, from: payload) }
}

struct SwiftDataInsightsRepository: InsightsRepository {
    let store: SwiftDataStore

    func notes() throws -> [StoredNote] {
        try store.withContext { ctx in
            let sort = [SortDescriptor(\StoredNoteRecord.day, order: .reverse), SortDescriptor(\StoredNoteRecord.createdAt, order: .reverse)]
            return try ctx.fetch(FetchDescriptor<StoredNoteRecord>(sortBy: sort)).compactMap(\.value)
        }
    }

    func upsert(_ notes: [StoredNote]) throws {
        try store.withContext { ctx in
            for n in notes {
                let id = n.id
                var d = FetchDescriptor<StoredNoteRecord>(predicate: #Predicate { $0.id == id })
                d.fetchLimit = 1
                if let r = try ctx.fetch(d).first {
                    r.day = n.day.description; r.createdAt = n.createdAt; r.payload = try HPLJSON.encoder.encode(n)
                } else {
                    ctx.insert(try StoredNoteRecord(n))
                }
            }
            try ctx.save()
        }
    }

    func deleteNotes(ids: [UUID]) throws {
        try store.withContext { ctx in
            try ctx.delete(model: StoredNoteRecord.self, where: #Predicate { ids.contains($0.id) })
            try ctx.save()
        }
    }

    func experiments() throws -> [Experiment] {
        try store.withContext { ctx in
            try ctx.fetch(FetchDescriptor<ExperimentRecord>(sortBy: [SortDescriptor(\.startDay, order: .reverse)])).compactMap(\.value)
        }
    }

    func save(_ e: Experiment) throws {
        try store.withContext { ctx in
            let id = e.id
            var d = FetchDescriptor<ExperimentRecord>(predicate: #Predicate { $0.id == id })
            d.fetchLimit = 1
            if let r = try ctx.fetch(d).first {
                r.startDay = e.startDay.description; r.payload = try HPLJSON.encoder.encode(e)
            } else {
                ctx.insert(try ExperimentRecord(e))
            }
            try ctx.save()
        }
    }

    func deleteAll() throws {
        try store.withContext { ctx in
            try ctx.delete(model: StoredNoteRecord.self)
            try ctx.delete(model: ExperimentRecord.self)
            try ctx.save()
        }
    }
}
#endif
