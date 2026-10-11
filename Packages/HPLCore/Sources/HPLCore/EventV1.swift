import Foundation

/// `hpl.event.v1` envelope. Mirrors Spec/hpl.event.v1.schema.json. Signature lives in transport headers.
public struct HPLEventV1: Codable, Sendable, Equatable {
    public static let specID = "hpl.event.v1"

    public enum EventType: Codable, Sendable, Hashable, RawRepresentable {
        case mealStart, mealItems, mealPhoto, mealEnd, voiceNote, lifestyleEvent, ping
        case unknown(String)

        public init(rawValue: String) {
            self = switch rawValue {
            case "meal.start": .mealStart
            case "meal.items": .mealItems
            case "meal.photo": .mealPhoto
            case "meal.end": .mealEnd
            case "voice.note": .voiceNote
            case "lifestyle.event": .lifestyleEvent
            case "ping": .ping
            default: .unknown(rawValue)
            }
        }

        public var rawValue: String {
            switch self {
            case .mealStart: "meal.start"
            case .mealItems: "meal.items"
            case .mealPhoto: "meal.photo"
            case .mealEnd: "meal.end"
            case .voiceNote: "voice.note"
            case .lifestyleEvent: "lifestyle.event"
            case .ping: "ping"
            case .unknown(let raw): raw
            }
        }

        public init(from decoder: Decoder) throws { self.init(rawValue: try decoder.singleValueContainer().decode(String.self)) }
        public func encode(to encoder: Encoder) throws { var c = encoder.singleValueContainer(); try c.encode(rawValue) }
    }

    public struct Producer: Codable, Sendable, Equatable {
        public var name: String
        public var version: String
        public init(name: String, version: String) { self.name = name; self.version = version }
    }

    public var spec: String
    public var eventID: String
    public var type: EventType
    public var occurredAt: Date
    public var tz: String
    public var producer: Producer
    public var sessionID: String?
    public var payload: JSONValue

    enum CodingKeys: String, CodingKey {
        case spec, eventID = "event_id", type, occurredAt = "occurred_at", tz, producer, sessionID = "session_id", payload
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        spec = try c.decode(String.self, forKey: .spec)
        guard spec == Self.specID else {
            throw DecodingError.dataCorruptedError(forKey: .spec, in: c, debugDescription: "Expected \(Self.specID), got \(spec)")
        }
        eventID = try c.decode(String.self, forKey: .eventID)
        type = try c.decode(EventType.self, forKey: .type)
        occurredAt = try c.decode(Date.self, forKey: .occurredAt)
        tz = try c.decode(String.self, forKey: .tz)
        producer = try c.decode(Producer.self, forKey: .producer)
        sessionID = try c.decodeIfPresent(String.self, forKey: .sessionID)
        payload = try c.decode(JSONValue.self, forKey: .payload)
    }

    /// Typed payload for known event types; `nil` for unknown types (stored as ignored by the bridge).
    public func typedPayload() throws -> EventPayload? {
        switch type {
        case .mealStart: .mealStart(try payload.decode(EventPayload.MealStart.self))
        case .mealItems: .mealItems(try payload.decode(EventPayload.MealItems.self))
        case .mealPhoto: .mealPhoto(try payload.decode(EventPayload.MealPhoto.self))
        case .mealEnd: .mealEnd
        case .voiceNote: .voiceNote(try payload.decode(EventPayload.VoiceNote.self))
        case .lifestyleEvent: .lifestyleEvent(try payload.decode(EventPayload.LifestyleEvent.self))
        case .ping: .ping
        case .unknown: nil
        }
    }
}

public enum EventPayload: Sendable, Equatable {
    case mealStart(MealStart), mealItems(MealItems), mealPhoto(MealPhoto), mealEnd
    case voiceNote(VoiceNote), lifestyleEvent(LifestyleEvent), ping

    public struct MealStart: Codable, Sendable, Equatable {
        public enum Trigger: String, Codable, Sendable { case voice, vision, manual }
        public var trigger: Trigger
    }

    public struct MealItems: Codable, Sendable, Equatable {
        public struct Item: Codable, Sendable, Equatable {
            public var name: String
            public var portionText: String?
            public var kcalEst, proteinG, carbsG, fatG, fiberG: Double?
            public var confidence: Double
            enum CodingKeys: String, CodingKey {
                case name, portionText = "portion_text", kcalEst = "kcal_est", proteinG = "protein_g"
                case carbsG = "carbs_g", fatG = "fat_g", fiberG = "fiber_g", confidence
            }
        }
        public var items: [Item]
        public var tags: [String]?
    }

    public struct MealPhoto: Codable, Sendable, Equatable {
        public var photoRef: String
        public var sha256: String
        public var width: Int
        public var height: Int
        enum CodingKeys: String, CodingKey { case photoRef = "photo_ref", sha256, width, height }
    }

    public struct VoiceNote: Codable, Sendable, Equatable {
        public enum Intent: String, Codable, Sendable { case craving, mood, energy, symptom, other }
        public var text: String
        public var intent: Intent?
    }

    public struct LifestyleEvent: Codable, Sendable, Equatable {
        public enum Kind: String, Codable, Sendable { case caffeine, alcohol, water, sunlight, screenLate = "screen_late", custom }
        public var kind: Kind
        public var amount: Double?
        public var unit: String?
    }
}
