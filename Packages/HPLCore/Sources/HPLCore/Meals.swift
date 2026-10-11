import Foundation

public typealias MealItem = EventPayload.MealItems.Item

/// Controlled meal-tag vocabulary shared by hpl.event.v1 and hpl.daily_summary.v1 (`mealTag`). Anything else is dropped.
public enum MealTag: String, Codable, Sendable, CaseIterable {
    case late, alcohol, highSugar = "high-sugar", highProtein = "high-protein", highFiber = "high-fiber"
    case homeCooked = "home-cooked", restaurant, caffeine, processed

    public static func filter(_ raw: [String]) -> [String] {
        var seen = Set<String>()
        return raw.compactMap { MealTag(rawValue: $0)?.rawValue }.filter { seen.insert($0).inserted }
    }
}

/// A meal on the user's timeline (§5.3). Glasses meals arrive `pending` and only reach the DailySummary once confirmed.
public struct MealLog: Codable, Sendable, Equatable, Identifiable {
    public enum Status: String, Codable, Sendable { case pending, confirmed, rejected }
    public enum Source: String, Codable, Sendable { case glasses, manual }

    public var id: UUID
    /// Producer session id (meal.start…meal.end) or the event id of a self-contained `meal.logged`.
    public var sessionKey: String?
    public var startedAt: Date
    public var endedAt: Date?
    /// IANA zone at meal time (from the event); local time-of-day uses this, not the phone's current zone.
    public var tz: String
    public var items: [MealItem]
    public var tags: [String]
    public var status: Status
    public var source: Source
    public var producer: String?
    public var processing: HPLEventV1.Producer.Processing?
    /// `meal.photo` events seen for this meal and dropped by the photo policy (M5 never imports photos).
    public var photosDropped: Int
    public var updatedAt: Date

    public init(id: UUID = UUID(), sessionKey: String? = nil, startedAt: Date, endedAt: Date? = nil, tz: String, items: [MealItem] = [],
                tags: [String] = [], status: Status, source: Source, producer: String? = nil,
                processing: HPLEventV1.Producer.Processing? = nil, photosDropped: Int = 0, updatedAt: Date) {
        self.id = id; self.sessionKey = sessionKey; self.startedAt = startedAt; self.endedAt = endedAt; self.tz = tz
        self.items = items; self.tags = MealTag.filter(tags); self.status = status; self.source = source; self.producer = producer
        self.processing = processing; self.photosDropped = photosDropped; self.updatedAt = updatedAt
    }

    public var isOpen: Bool { endedAt == nil && source == .glasses }
    public var kcalTotal: Double? {
        let k = items.compactMap(\.kcalEst)
        return k.isEmpty ? nil : k.reduce(0, +)
    }

    public var calendar: Calendar { .hplLocal(TimeZone(identifier: tz) ?? .current) }
    public var day: LocalDay { LocalDay(startedAt, calendar: calendar) }
}

/// `lifestyle.event` (caffeine, alcohol, water, …) as stored.
public struct LifestyleLog: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var occurredAt: Date
    public var tz: String
    public var kind: EventPayload.LifestyleEvent.Kind
    public var amount: Double?
    public var unit: String?
    public init(id: String, occurredAt: Date, tz: String, kind: EventPayload.LifestyleEvent.Kind, amount: Double? = nil, unit: String? = nil) {
        self.id = id; self.occurredAt = occurredAt; self.tz = tz; self.kind = kind; self.amount = amount; self.unit = unit
    }
}

/// `voice.note` as stored. Free text stays on the device: never in the DailySummary, never sent to the LLM, never interpreted.
public struct VoiceNoteLog: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var occurredAt: Date
    public var text: String
    public var intent: EventPayload.VoiceNote.Intent?
    public init(id: String, occurredAt: Date, text: String, intent: EventPayload.VoiceNote.Intent?) {
        self.id = id; self.occurredAt = occurredAt; self.text = text; self.intent = intent
    }
}

/// Persistent idempotency record for one verified event (§8.2: idempotent on `event_id`).
public struct EventReceipt: Codable, Sendable, Equatable {
    public enum Disposition: String, Codable, Sendable { case applied, ignoredUnknownType, droppedPhoto, ignoredPing, orphaned }
    public var eventID: String
    public var type: String
    public var occurredAt: Date
    public var receivedAt: Date
    public var pairingID: String
    public var producer: String
    public var disposition: Disposition
    public init(eventID: String, type: String, occurredAt: Date, receivedAt: Date, pairingID: String, producer: String, disposition: Disposition) {
        self.eventID = eventID; self.type = type; self.occurredAt = occurredAt; self.receivedAt = receivedAt
        self.pairingID = pairingID; self.producer = producer; self.disposition = disposition
    }
}

/// A paired producer. The secret lives in the Keychain (HPLBridge `PairingSecretStore`), never here.
public struct PairingInfo: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var label: String
    public var createdAt: Date
    /// 8-char pairing code (`PairingCode.of(secret)`), shown on both sides so you can check they hold the same key.
    /// Not secret (32 bits of a hash). `nil` for pairings made before the code existed; the UI then reads the Keychain.
    public var code: String?
    public init(id: String, label: String, createdAt: Date, code: String? = nil) {
        self.id = id; self.label = label; self.createdAt = createdAt; self.code = code
    }
}

/// Short pairing code: first 8 lowercase hex chars of SHA-256(secret). Same as Glance's `HplPairing.fingerprint()`
/// and `hpl_event_sign.py pair` → `secret_sha256[:8]` (docs/m5-glasses.md §3, rayban-vlm-poc docs/HPL_BRIDGE.md).
public enum PairingCode {
    public static func of(_ secret: [UInt8]) -> String { String(SHA256Digest.hex(Data(secret)).prefix(8)) }
    /// "ae21 6c2e": grouped for reading aloud / comparing at a glance.
    public static func display(_ code: String) -> String { code.count == 8 ? "\(code.prefix(4)) \(code.suffix(4))" : code }
}

/// User-controlled bridge state (§8.4): pause toggle, photo policy, pairings, last-event indicator.
public struct BridgeState: Codable, Sendable, Equatable {
    public var paused: Bool
    /// Off by default. M5 has no photo import path at all; this stays false and the UI shows it as unavailable.
    public var photosAllowed: Bool
    public var pairings: [PairingInfo]
    public var lastEventAt: Date?
    public var lastProducer: String?
    public init(paused: Bool = false, photosAllowed: Bool = false, pairings: [PairingInfo] = [], lastEventAt: Date? = nil, lastProducer: String? = nil) {
        self.paused = paused; self.photosAllowed = photosAllowed; self.pairings = pairings; self.lastEventAt = lastEventAt; self.lastProducer = lastProducer
    }
}

public protocol MealRepository: Sendable {
    func meals() throws -> [MealLog]
    func save(_ meal: MealLog) throws
    func deleteMeal(id: UUID) throws
    func lifestyle() throws -> [LifestyleLog]
    func save(_ log: LifestyleLog) throws
    func voiceNotes() throws -> [VoiceNoteLog]
    func save(_ note: VoiceNoteLog) throws
    func receipt(eventID: String) throws -> EventReceipt?
    func save(_ receipt: EventReceipt) throws
    func bridgeState() throws -> BridgeState
    func save(_ state: BridgeState) throws
    func deleteAll() throws
}

/// Minimal keyed blob storage the meal repository is built on (in-memory and SwiftData implement it).
public protocol BridgeRecordStore: Sendable {
    func put(kind: String, key: String, at: Date, payload: Data) throws
    func get(kind: String, key: String) throws -> Data?
    func all(kind: String) throws -> [Data]
    func delete(kind: String, key: String) throws
    func deleteAll() throws
}

/// `MealRepository` over any `BridgeRecordStore`; all encoding lives here so both backends behave identically.
public struct KeyedMealRepository: MealRepository {
    enum Kind: String { case meal, lifestyle, voice, receipt, state }
    let store: any BridgeRecordStore
    public init(store: any BridgeRecordStore) { self.store = store }

    private func put(_ kind: Kind, _ key: String, _ at: Date, _ value: some Encodable) throws {
        try store.put(kind: kind.rawValue, key: key, at: at, payload: try HPLJSON.encoder.encode(value))
    }
    private func all<T: Decodable>(_ kind: Kind, _ type: T.Type) throws -> [T] {
        try store.all(kind: kind.rawValue).compactMap { try? HPLJSON.decoder.decode(T.self, from: $0) }
    }

    public func meals() throws -> [MealLog] { try all(.meal, MealLog.self).sorted { $0.startedAt > $1.startedAt } }
    public func save(_ meal: MealLog) throws { try put(.meal, meal.id.uuidString, meal.startedAt, meal) }
    public func deleteMeal(id: UUID) throws { try store.delete(kind: Kind.meal.rawValue, key: id.uuidString) }
    public func lifestyle() throws -> [LifestyleLog] { try all(.lifestyle, LifestyleLog.self).sorted { $0.occurredAt > $1.occurredAt } }
    public func save(_ log: LifestyleLog) throws { try put(.lifestyle, log.id, log.occurredAt, log) }
    public func voiceNotes() throws -> [VoiceNoteLog] { try all(.voice, VoiceNoteLog.self).sorted { $0.occurredAt > $1.occurredAt } }
    public func save(_ note: VoiceNoteLog) throws { try put(.voice, note.id, note.occurredAt, note) }
    public func receipt(eventID: String) throws -> EventReceipt? {
        try store.get(kind: Kind.receipt.rawValue, key: eventID).flatMap { try? HPLJSON.decoder.decode(EventReceipt.self, from: $0) }
    }
    public func save(_ receipt: EventReceipt) throws { try put(.receipt, receipt.eventID, receipt.receivedAt, receipt) }
    public func bridgeState() throws -> BridgeState {
        try store.get(kind: Kind.state.rawValue, key: "bridge").flatMap { try? HPLJSON.decoder.decode(BridgeState.self, from: $0) } ?? BridgeState()
    }
    public func save(_ state: BridgeState) throws { try put(.state, "bridge", Date(timeIntervalSince1970: 0), state) }
    public func deleteAll() throws { try store.deleteAll() }
}

/// Consent copy for the glasses bridge (§8.4). A new copy version requires re-acknowledgement.
public enum GlassesConsent {
    public static let version = "glasses-v1"
    public static let points = [
        "HPL only accepts signed event files from a companion app you pair here (for example Glance or VisionClaw).",
        "Meals arrive as pending. Nothing counts until you confirm it.",
        "Only the time of day and simple tags (like \"late\") from confirmed meals go into your daily summary. " +
            "Food names, calories and voice notes stay on this iPhone.",
        "Photos are never imported in this version.",
        "Where the companion runs its camera AI is up to that app: Glance runs on your phone without a network; " +
            "VisionClaw sends camera and audio to a cloud model. Each imported meal shows which.",
        "You can pause the bridge or remove a pairing at any time.",
    ]
}
