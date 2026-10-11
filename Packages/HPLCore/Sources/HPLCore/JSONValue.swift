import Foundation

/// Untyped JSON tree. Used for event payloads, evidence values, and path lookups into summaries.
public enum JSONValue: Codable, Sendable, Hashable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
        } else if let b = try? c.decode(Bool.self) {
            self = .bool(b)
        } else if let n = try? c.decode(Double.self) {
            self = .number(n)
        } else if let s = try? c.decode(String.self) {
            self = .string(s)
        } else if let a = try? c.decode([JSONValue].self) {
            self = .array(a)
        } else if let o = try? c.decode([String: JSONValue].self) {
            self = .object(o)
        } else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unsupported JSON value")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n):
            if n.rounded() == n, abs(n) < 1e15 { try c.encode(Int64(n)) } else { try c.encode(n) }
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    /// Re-encodes any Encodable into a JSON tree.
    public init<T: Encodable>(encoding value: T) throws {
        self = try HPLJSON.decoder.decode(JSONValue.self, from: HPLJSON.encoder.encode(value))
    }

    /// Decodes this tree into a typed value.
    public func decode<T: Decodable>(_ type: T.Type) throws -> T {
        try HPLJSON.decoder.decode(T.self, from: HPLJSON.encoder.encode(self))
    }

    /// Dot path lookup; array indices are numeric segments: `meals.1.tags`.
    public func value(at path: String) -> JSONValue? {
        var node = self
        for seg in path.split(separator: ".", omittingEmptySubsequences: false).map(String.init) {
            switch node {
            case .object(let o): guard let next = o[seg] else { return nil }; node = next
            case .array(let a): guard let i = Int(seg), a.indices.contains(i) else { return nil }; node = a[i]
            default: return nil
            }
        }
        return node
    }

    /// Same tree with `null` members removed (null and absent are equivalent in our schemas).
    public var strippingNulls: JSONValue {
        switch self {
        case .object(let o): .object(o.compactMapValues { $0 == .null ? nil : $0.strippingNulls })
        case .array(let a): .array(a.map(\.strippingNulls))
        default: self
        }
    }

    /// Every number in the tree, including digit runs inside strings ("21:45" -> 21, 45).
    public var allNumbers: [Double] {
        switch self {
        case .number(let n): [n]
        case .string(let s): NumberScanner.numbers(in: s)
        case .array(let a): a.flatMap(\.allNumbers)
        case .object(let o): o.values.flatMap(\.allNumbers)
        case .null, .bool: []
        }
    }
}

public enum NumberScanner {
    /// Numbers in free text: integers and decimals, e.g. "382 min vs 5.6%" -> [382, 5.6].
    /// Digits glued to a preceding letter are part of a name, not a quantity ("HbA1c", "VO2max").
    public static func numbers(in text: String) -> [Double] {
        var out: [Double] = []
        var current = ""
        var inWord = false
        func flush() {
            let trimmed = current.hasSuffix(".") ? String(current.dropLast()) : current
            if let n = Double(trimmed) { out.append(n) }
            current = ""
        }
        for ch in text {
            let isDigit = ch.isASCII && ch.isNumber
            if isDigit, current.isEmpty, inWord { continue }
            if isDigit {
                current.append(ch)
            } else if ch == ".", !current.isEmpty, !current.contains(".") {
                current.append(ch)
            } else {
                if !current.isEmpty { flush() }
                inWord = ch.isLetter
            }
        }
        if !current.isEmpty { flush() }
        return out
    }
}

public enum HPLJSON {
    public static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }

    public static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
