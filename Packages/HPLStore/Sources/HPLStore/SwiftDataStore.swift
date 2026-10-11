#if canImport(SwiftData)
import Foundation
import SwiftData
import HPLCore

// SwiftData persistence (architecture §4 DECISION), kept behind HPLCore repository protocols so GRDB can replace it.
// Health values live only in this store, which sits in a directory with NSFileProtectionComplete on iOS.

@Model final class HealthAggregateRecord {
    @Attribute(.unique) var key: String
    var day: String
    var metric: String
    var window: String
    var qualifier: String?
    var min: Double?
    var max: Double?
    var mean: Double?
    var median: Double?
    var p10: Double?
    var p90: Double?
    var sum: Double?
    var count: Int?
    var stdev: Double?
    var sourceBundleIDs: [String]
    var tz: String
    var computedAt: Date

    init(_ a: HealthAggregate) {
        key = a.id; day = a.day.description; metric = a.metric.rawValue; window = a.window.rawValue; qualifier = a.qualifier
        min = a.stats.min; max = a.stats.max; mean = a.stats.mean; median = a.stats.median
        p10 = a.stats.p10; p90 = a.stats.p90; sum = a.stats.sum; count = a.stats.count; stdev = a.stats.stdev
        sourceBundleIDs = a.sourceBundleIDs; tz = a.tz; computedAt = a.computedAt
    }

    var value: HealthAggregate? {
        guard let d = LocalDay(string: day), let m = HealthMetric(rawValue: metric), let w = AggregateWindow(rawValue: window) else { return nil }
        return HealthAggregate(day: d, metric: m, window: w, qualifier: qualifier,
                               stats: AggregateStats(min: min, max: max, mean: mean, median: median, p10: p10, p90: p90,
                                                     sum: sum, count: count, stdev: stdev),
                               sourceBundleIDs: sourceBundleIDs, tz: tz, computedAt: computedAt)
    }
}

@Model final class SyncStateRecord {
    @Attribute(.unique) var key: String
    var anchor: Data?
    var date: Date?
    init(key: String) { self.key = key }
}

@Model final class ConsentRecord {
    @Attribute(.unique) var id: UUID
    var scope: String
    var version: String
    var grantedAt: Date
    var revokedAt: Date?

    init(_ c: Consent) { id = c.id; scope = c.scope.rawValue; version = c.version; grantedAt = c.grantedAt; revokedAt = c.revokedAt }

    var value: Consent? {
        ConsentScope(rawValue: scope).map { Consent(id: id, scope: $0, version: version, grantedAt: grantedAt, revokedAt: revokedAt) }
    }
}

/// One SQLite-backed SwiftData store exposing all three repositories. Access is serialized by a lock around one context.
public final class SwiftDataStore: @unchecked Sendable {
    public static let schemaTypes: [any PersistentModel.Type] = [
        HealthAggregateRecord.self, SyncStateRecord.self, ConsentRecord.self,
        SourceDocumentRecord.self, LabPanelRecord.self, LabResultRecord.self,
        StoredNoteRecord.self, ExperimentRecord.self, BridgeRecord.self,
    ]

    private let container: ModelContainer
    private let context: ModelContext
    private let lock = NSLock()

    /// On-disk store at `Application Support/HPL/hpl.store`, directory protected with `.complete` (§10).
    public static func persistent(directory: URL? = nil) throws -> SwiftDataStore {
        let fm = FileManager.default
        let dir = try directory ?? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("HPL", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        #if os(iOS)
        // New files inherit the directory's protection class (store, -wal, -shm).
        try fm.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: dir.path)
        #endif
        // Backup inclusion stays the OS default (§12 open decision; toggle lands in M7).
        let config = ModelConfiguration("HPL", schema: Schema(schemaTypes), url: dir.appendingPathComponent("hpl.store"), cloudKitDatabase: .none)
        return try SwiftDataStore(configuration: config)
    }

    public static func inMemory() throws -> SwiftDataStore {
        try SwiftDataStore(configuration: ModelConfiguration("HPL-mem", schema: Schema(schemaTypes), isStoredInMemoryOnly: true, cloudKitDatabase: .none))
    }

    /// SwiftData can SIGSEGV when containers are created concurrently (macOS CI run 38129994082); creation is rare, so serialize.
    private static let creationLock = NSLock()
    private init(configuration: ModelConfiguration) throws {
        Self.creationLock.lock(); defer { Self.creationLock.unlock() }
        container = try ModelContainer(for: Schema(Self.schemaTypes), configurations: [configuration])
        context = ModelContext(container)
        context.autosaveEnabled = false
    }

    func withContext<T>(_ body: (ModelContext) throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        return try body(context)
    }

    public var aggregates: any HealthAggregateRepository { SwiftDataHealthAggregateRepository(store: self) }
    public var syncState: any SyncStateRepository { SwiftDataSyncStateRepository(store: self) }
    public var consents: any ConsentRepository { SwiftDataConsentRepository(store: self) }
    public var labs: any LabRepository { SwiftDataLabRepository(store: self) }
    public var insights: any InsightsRepository { SwiftDataInsightsRepository(store: self) }
    public var meals: any MealRepository { KeyedMealRepository(store: SwiftDataBridgeRecordStore(store: self)) }

    /// "Delete all" for health data (§10): aggregates + anchors. HealthKit itself is untouched.
    public func deleteAllHealthData() throws {
        try withContext { ctx in
            try ctx.delete(model: HealthAggregateRecord.self)
            try ctx.delete(model: SyncStateRecord.self)
            try ctx.save()
        }
    }

    /// One-time move of M0 UserDefaults consents into the protected store; the old key is cleared after a successful copy.
    public func migrateConsents(from legacy: UserDefaultsConsentRepository) throws {
        let old = try legacy.all()
        guard !old.isEmpty else { return }
        let repo = consents
        let existing = Set(try repo.all().map(\.id))
        for c in old where !existing.contains(c.id) { try repo.save(c) }
        legacy.removeAll()
    }
}

@Model final class SourceDocumentRecord {
    @Attribute(.unique) var id: UUID
    var kind: String
    var sha256: String
    var storedFileName: String
    var importedAt: Date
    var extractor: String
    var status: String

    init(_ d: SourceDocument) {
        id = d.id; kind = d.kind.rawValue; sha256 = d.sha256; storedFileName = d.storedFileName
        importedAt = d.importedAt; extractor = d.extractor; status = d.status.rawValue
    }

    var value: SourceDocument? {
        guard let k = SourceDocument.Kind(rawValue: kind), let s = SourceDocument.Status(rawValue: status) else { return nil }
        return SourceDocument(id: id, kind: k, sha256: sha256, storedFileName: storedFileName, importedAt: importedAt, extractor: extractor, status: s)
    }
}

@Model final class LabPanelRecord {
    @Attribute(.unique) var id: UUID
    var collectedOn: String
    var sourceDocumentID: UUID?
    var confirmedAt: Date

    init(_ p: LabPanel) { id = p.id; collectedOn = p.collectedOn.description; sourceDocumentID = p.sourceDocumentID; confirmedAt = p.confirmedAt }

    var value: LabPanel? {
        LocalDay(string: collectedOn).map { LabPanel(id: id, collectedOn: $0, sourceDocumentID: sourceDocumentID, confirmedAt: confirmedAt) }
    }
}

/// Stored as one Codable blob per result: labs are low-volume and always read per panel.
@Model final class LabResultRecord {
    @Attribute(.unique) var id: UUID
    var panelID: UUID
    var payload: Data

    init(_ r: LabResult) throws { id = r.id; panelID = r.panelID; payload = try HPLJSON.encoder.encode(r) }
    var value: LabResult? { try? HPLJSON.decoder.decode(LabResult.self, from: payload) }
}

struct SwiftDataLabRepository: LabRepository {
    let store: SwiftDataStore

    func document(sha256: String) throws -> SourceDocument? {
        try store.withContext { ctx in
            var d = FetchDescriptor<SourceDocumentRecord>(predicate: #Predicate { $0.sha256 == sha256 })
            d.fetchLimit = 1
            return try ctx.fetch(d).first?.value
        }
    }

    func documents() throws -> [SourceDocument] {
        try store.withContext { try $0.fetch(FetchDescriptor<SourceDocumentRecord>(sortBy: [SortDescriptor(\.importedAt)])).compactMap(\.value) }
    }

    func saveDocument(_ doc: SourceDocument) throws {
        try store.withContext { ctx in
            try upsert(doc, in: ctx)
            try ctx.save()
        }
    }

    private func upsert(_ doc: SourceDocument, in ctx: ModelContext) throws {
        let id = doc.id
        var d = FetchDescriptor<SourceDocumentRecord>(predicate: #Predicate { $0.id == id })
        d.fetchLimit = 1
        if let r = try ctx.fetch(d).first {
            r.kind = doc.kind.rawValue; r.sha256 = doc.sha256; r.storedFileName = doc.storedFileName
            r.importedAt = doc.importedAt; r.extractor = doc.extractor; r.status = doc.status.rawValue
        } else {
            ctx.insert(SourceDocumentRecord(doc))
        }
    }

    func saveConfirmed(panel: LabPanel, results: [LabResult]) throws {
        guard results.allSatisfy(\.userConfirmed) else { throw LabRepositoryError.unconfirmedResult }
        try store.withContext { ctx in
            ctx.insert(LabPanelRecord(panel))
            for r in results { ctx.insert(try LabResultRecord(r)) }
            if let docID = panel.sourceDocumentID {
                var d = FetchDescriptor<SourceDocumentRecord>(predicate: #Predicate { $0.id == docID })
                d.fetchLimit = 1
                try ctx.fetch(d).first?.status = SourceDocument.Status.confirmed.rawValue
            }
            try ctx.save()
        }
    }

    func panels() throws -> [LabPanel] {
        try store.withContext { ctx in
            try ctx.fetch(FetchDescriptor<LabPanelRecord>(sortBy: [SortDescriptor(\.collectedOn, order: .reverse)])).compactMap(\.value)
        }
    }

    func results(panelID: UUID) throws -> [LabResult] {
        try store.withContext { ctx in
            try ctx.fetch(FetchDescriptor<LabResultRecord>(predicate: #Predicate { $0.panelID == panelID })).compactMap(\.value)
        }
    }

    func deleteAll() throws {
        try store.withContext { ctx in
            try ctx.delete(model: LabResultRecord.self)
            try ctx.delete(model: LabPanelRecord.self)
            try ctx.delete(model: SourceDocumentRecord.self)
            try ctx.save()
        }
    }
}

struct SwiftDataHealthAggregateRepository: HealthAggregateRepository {
    let store: SwiftDataStore

    func replace(days: [LocalDay], with aggregates: [HealthAggregate]) throws {
        try store.withContext { ctx in
            let keys = days.map(\.description)
            try ctx.delete(model: HealthAggregateRecord.self, where: #Predicate { keys.contains($0.day) })
            for a in aggregates { ctx.insert(HealthAggregateRecord(a)) }
            try ctx.save()
        }
    }

    func aggregates(from first: LocalDay, through last: LocalDay) throws -> [HealthAggregate] {
        let lo = first.description, hi = last.description
        return try store.withContext { ctx in
            let d = FetchDescriptor<HealthAggregateRecord>(predicate: #Predicate { $0.day >= lo && $0.day <= hi },
                                                           sortBy: [SortDescriptor(\.key)])
            return try ctx.fetch(d).compactMap(\.value)
        }
    }

    func deleteAll() throws {
        try store.withContext { ctx in try ctx.delete(model: HealthAggregateRecord.self); try ctx.save() }
    }
}

struct SwiftDataSyncStateRepository: SyncStateRepository {
    let store: SwiftDataStore

    private func record(_ key: String, in ctx: ModelContext, create: Bool) throws -> SyncStateRecord? {
        var d = FetchDescriptor<SyncStateRecord>(predicate: #Predicate { $0.key == key })
        d.fetchLimit = 1
        if let r = try ctx.fetch(d).first { return r }
        guard create else { return nil }
        let r = SyncStateRecord(key: key)
        ctx.insert(r)
        return r
    }

    func anchor(for key: String) throws -> Data? { try store.withContext { try record(key, in: $0, create: false)?.anchor } }
    func setAnchor(_ data: Data?, for key: String) throws {
        try store.withContext { ctx in try record(key, in: ctx, create: true)?.anchor = data; try ctx.save() }
    }
    func date(for key: String) throws -> Date? { try store.withContext { try record(key, in: $0, create: false)?.date } }
    func setDate(_ date: Date?, for key: String) throws {
        try store.withContext { ctx in try record(key, in: ctx, create: true)?.date = date; try ctx.save() }
    }
    func reset() throws { try store.withContext { ctx in try ctx.delete(model: SyncStateRecord.self); try ctx.save() } }
}

struct SwiftDataConsentRepository: ConsentRepository {
    let store: SwiftDataStore

    func all() throws -> [Consent] {
        try store.withContext { ctx in
            try ctx.fetch(FetchDescriptor<ConsentRecord>(sortBy: [SortDescriptor(\.grantedAt)])).compactMap(\.value)
        }
    }

    func save(_ consent: Consent) throws {
        let id = consent.id
        try store.withContext { ctx in
            var d = FetchDescriptor<ConsentRecord>(predicate: #Predicate { $0.id == id })
            d.fetchLimit = 1
            if let r = try ctx.fetch(d).first {
                r.scope = consent.scope.rawValue; r.version = consent.version; r.grantedAt = consent.grantedAt; r.revokedAt = consent.revokedAt
            } else {
                ctx.insert(ConsentRecord(consent))
            }
            try ctx.save()
        }
    }
}

#endif
