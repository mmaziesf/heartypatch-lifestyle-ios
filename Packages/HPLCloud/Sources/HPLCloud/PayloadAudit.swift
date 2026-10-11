import Foundation
import HPLCore

/// Independent second check, run on the exact bytes right before they are sent (§7.4 defense in depth):
/// every key must be a known payload key and every string must come from a closed vocabulary or a fixed shape.
/// It doesn't trust `Anonymizer`; a bug there that leaked a string would fail here and block the send.
public enum PayloadAudit {
    static let keys: Set<String> = Set<String>([
        "schema", "request_id", "provenance", "window_days", "days_with_data", "profile", "weeks", "daily", "labs",
        "age_band", "sex_for_ranges", "week", "metrics", "median", "p10", "p90",
        "day", "dow", "sleep_total_min", "resting_hr", "hrv_ms", "steps", "exercise_min", "bed_local", "wake_local", "meals", "workouts",
        "t_local", "label", "tags", "type", "duration_min", "analyte", "value", "unit", "age_bucket",
    ]).union(CloudMetric.allCases.map(\.rawValue))

    static var strings: Set<String> {
        var s: Set<String> = [CloudPayloadV1.schemaID, "device", "synthetic_fixture"]
        s.formUnion(CloudVocabulary.daysOfWeek); s.formUnion(CloudVocabulary.mealLabels); s.formUnion(CloudVocabulary.workoutTypes)
        s.formUnion(CloudVocabulary.ageBuckets); s.formUnion(CloudVocabulary.sexes); s.formUnion(MealTag.allCases.map(\.rawValue))
        s.formUnion(CloudVocabulary.labs.keys); s.formUnion(CloudVocabulary.labs.values.map(\.unit))
        return s
    }

    /// Empty = clean.
    public static func violations(_ body: Data, maxBytes: Int) -> [String] {
        var out: [String] = []
        if body.count > maxBytes { out.append("size \(body.count) > \(maxBytes)") }
        guard let json = try? JSONDecoder().decode(JSONValue.self, from: body) else { return out + ["not JSON"] }
        walk(json, path: "$", allowed: strings, into: &out)
        return out
    }

    private static func walk(_ v: JSONValue, path: String, allowed: Set<String>, into out: inout [String]) {
        switch v {
        case .object(let o):
            for (k, child) in o {
                if !keys.contains(k) { out.append("unknown key \(path).\(k)") }
                walk(child, path: "\(path).\(k)", allowed: allowed, into: &out)
            }
        case .array(let a):
            for (i, child) in a.enumerated() { walk(child, path: "\(path)[\(i)]", allowed: allowed, into: &out) }
        case .string(let s):
            if !(allowed.contains(s) || isHalfHour(s) || isAgeBand(s) || (path == "$.request_id" && isUUID(s))) {
                out.append("string not allowed at \(path)")
            }
        case .number(let n):
            if !n.isFinite { out.append("non-finite number at \(path)") }
        case .bool, .null:
            break
        }
    }

    static func isHalfHour(_ s: String) -> Bool { CloudRounding.halfHour(s) == s && (s.hasSuffix(":00") || s.hasSuffix(":30")) }
    static func isAgeBand(_ s: String) -> Bool { CloudRounding.ageBand(s) == s }
    static func isUUID(_ s: String) -> Bool { UUID(uuidString: s) != nil && s == s.lowercased() }
}
