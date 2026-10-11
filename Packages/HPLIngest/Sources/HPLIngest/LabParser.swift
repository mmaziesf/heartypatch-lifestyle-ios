import Foundation
import HPLCore

/// A text line from a report page. Box is normalized (0–1) page coordinates when the extractor knows them.
public struct LabTextLine: Sendable, Equatable {
    public struct Box: Sendable, Equatable {
        public var x, y, width, height: Double
        public init(x: Double, y: Double, width: Double, height: Double) { self.x = x; self.y = y; self.width = width; self.height = height }
    }
    public var text: String
    public var page: Int
    public var box: Box?
    public init(text: String, page: Int = 1, box: Box? = nil) { self.text = text; self.page = page; self.box = box }
}

/// A parsed row awaiting human confirmation. Never stored as-is.
public struct LabCandidate: Sendable, Equatable, Identifiable {
    public var id: Int { lineIndex }
    public var lineIndex: Int
    public var page: Int
    public var box: LabTextLine.Box?
    /// The printed row (for side-by-side review). Identifier lines never become candidates.
    public var sourceText: String
    public var analyteRaw: String
    public var analyteKey: String?
    public var valueNumeric: Double?
    public var valueText: String?
    public var unitRaw: String
    public var unitNormalized: String?
    public var refLow: Double?
    public var refHigh: Double?
    public var refText: String?
    public var flag: ReportFlag?
    public var confidence: Double

    public var analyte: Analyte? { analyteKey.flatMap(AnalyteDictionary.analyte(key:)) }
    /// Value in the analyte's canonical unit, when the unit is known and convertible.
    public var valueCanonical: Double? {
        guard let a = analyte, let v = valueNumeric else { return nil }
        if let u = unitNormalized { return a.toCanonical(v, unit: u) }
        return a.unit == "ratio" ? v : nil
    }
}

public struct LabParseResult: Sendable, Equatable {
    public var candidates: [LabCandidate]
    /// Collection date printed on the report, if found (user can change it before saving).
    public var collectedOn: LocalDay?
    /// How many lines were discarded as identifiers (name, DOB, MRN, address...). Their text is not kept.
    public var identifierLinesDropped: Int
}

/// Deterministic parser (§5.2 step 1): analyte dictionary + unit table + reference-range patterns.
/// It restates what the report prints; it never derives flags or ranges on its own.
public struct LabParser: Sendable {
    public init() {}

    /// Labels that introduce identifiers. Lines starting with these are dropped before any parsing.
    static let identifierLabels = [
        "patient", "name", "dob", "d.o.b", "date of birth", "birth date", "birthdate", "mrn", "medical record", "address",
        "phone", "tel", "ssn", "social security", "account", "acct", "accession", "specimen id", "requisition", "ordering",
        "physician", "provider", "doctor", "npi", "insurance", "member id", "sex", "gender", "age", "email",
    ]
    static let collectedLabels = ["date collected", "collection date", "collected", "specimen collected", "date drawn", "drawn", "date of collection"]

    public func parse(_ lines: [LabTextLine]) -> LabParseResult {
        var out = LabParseResult(candidates: [], collectedOn: nil, identifierLinesDropped: 0)
        for (i, line) in lines.enumerated() {
            let text = line.text.trimmingCharacters(in: .whitespaces)
            let lower = text.lowercased()
            if out.collectedOn == nil, let label = Self.collectedLabels.first(where: { lower.hasPrefix($0) }) {
                out.collectedOn = Self.parseDate(String(text.dropFirst(label.count)))
                continue
            }
            if Self.isIdentifierLine(lower) { out.identifierLinesDropped += 1; continue }
            if let c = parseRow(text, index: i, page: line.page, box: line.box) { out.candidates.append(c) }
        }
        return out
    }

    /// "Label: value" / "Label # value" lines whose label starts with an identifier word, plus "DOB 01/02/1980"-style lines.
    static func isIdentifierLine(_ lower: String) -> Bool {
        if let sep = lower.firstIndex(where: { $0 == ":" || $0 == "#" }), lower.distance(from: lower.startIndex, to: sep) <= 32 {
            let label = lower[..<sep].trimmingCharacters(in: .whitespaces)
            if identifierLabels.contains(where: { label.hasPrefix($0) }) { return true }
        }
        return ["dob ", "d.o.b ", "mrn ", "ssn "].contains { lower.hasPrefix($0) }
    }

    func parseRow(_ text: String, index: Int, page: Int, box: LabTextLine.Box?) -> LabCandidate? {
        let name: String, key: String?, rest: String
        if let m = AnalyteDictionary.match(lineStart: text) {
            name = String(text.prefix(m.length)); key = m.analyte.key; rest = String(text.dropFirst(m.length))
        } else if let split = Self.unmappedSplit(text) {
            name = split.name; key = nil; rest = split.rest
        } else {
            return nil
        }
        var c = LabCandidate(lineIndex: index, page: page, box: box, sourceText: text, analyteRaw: name.trimmingCharacters(in: .whitespaces),
                             analyteKey: key, valueNumeric: nil, valueText: nil, unitRaw: "", unitNormalized: nil,
                             refLow: nil, refHigh: nil, refText: nil, flag: nil, confidence: 0)
        var remaining: [String] = []
        for token in LabUnits.preJoin(rest).split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init) {
            if c.unitNormalized == nil, let u = LabUnits.normalize(token) {
                c.unitRaw = token; c.unitNormalized = u
            } else if c.flag == nil, let f = Self.flag(token) {
                c.flag = f
            } else {
                remaining.append(token)
            }
        }
        var tail = remaining.joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: " :"))
        if let v = Self.leadingValue(tail) {
            c.valueNumeric = v.value; c.valueText = v.comparator.map { "\($0)\(Self.fmt(v.value))" }
            tail = String(tail.dropFirst(v.length)).trimmingCharacters(in: .whitespaces)
        } else if let t = Self.textValue(tail) {
            c.valueText = t.value; tail = String(tail.dropFirst(t.length)).trimmingCharacters(in: .whitespaces)
        } else {
            return nil
        }
        Self.applyRange(tail, to: &c)
        c.confidence = Self.confidence(c)
        return c
    }

    /// Out-of-dictionary row: "<name> <number> ..." where the rest also has a unit or a range (to skip prose).
    static func unmappedSplit(_ text: String) -> (name: String, rest: String)? {
        guard let first = text.first, first.isLetter else { return nil }
        let chars = Array(text)
        for i in 1..<chars.count where chars[i - 1] == " " && (chars[i].isNumber || "<>".contains(chars[i])) {
            let name = String(chars[0..<i]).trimmingCharacters(in: .whitespaces)
            let rest = String(chars[i...])
            let hasUnit = rest.split(separator: " ").contains { LabUnits.normalize(String($0)) != nil }
            let hasRange = rangeMatch(rest) != nil
            guard name.count >= 2, name.count <= 48, hasUnit || hasRange else { return nil }
            return (name, rest)
        }
        return nil
    }

    static func flag(_ token: String) -> ReportFlag? {
        let t = token.trimmingCharacters(in: CharacterSet(charactersIn: "()*![]")).uppercased()
        switch t {
        case "H", "HIGH": return .high
        case "L", "LOW": return .low
        case "HH", "CRIT HIGH", "H*": return .criticalHigh
        case "LL", "CRIT LOW", "L*": return .criticalLow
        case "A", "ABN", "ABNORMAL": return .abnormal
        default: return nil
        }
    }

    static let comparators = ["<=", ">=", "≤", "≥", "<", ">"]

    /// A number at the start of `s`, with an optional comparator ("<0.5").
    struct LeadingValue { let value: Double; let comparator: String?; let length: Int }
    struct RangeMatch { let low: Double?; let high: Double?; let text: String }

    static func leadingValue(_ s: String) -> LeadingValue? {
        var idx = s.startIndex
        var comparator: String?
        if let c = comparators.first(where: { s.hasPrefix($0) }) {
            comparator = c; idx = s.index(idx, offsetBy: c.count)
            while idx < s.endIndex, s[idx] == " " { idx = s.index(after: idx) }
        }
        let numStart = idx
        while idx < s.endIndex, s[idx].isNumber || s[idx] == "." || (s[idx] == "," && idx > numStart) { idx = s.index(after: idx) }
        let raw = s[numStart..<idx].replacingOccurrences(of: ",", with: "")
        guard !raw.isEmpty, let v = Double(raw.hasSuffix(".") ? String(raw.dropLast()) : raw) else { return nil }
        // "65-99" right after the name is a range with no value, not a value.
        if idx < s.endIndex, s[idx] == "-", comparator == nil { return nil }
        return LeadingValue(value: v, comparator: comparator, length: s.distance(from: s.startIndex, to: idx))
    }

    static let textValues = ["not detected", "non-reactive", "nonreactive", "negative", "positive", "reactive", "detected", "trace", "normal"]

    public static func textValue(_ s: String) -> (value: String, length: Int)? {
        let lower = s.lowercased()
        return textValues.first { lower.hasPrefix($0) }.map { (String(s.prefix($0.count)), $0.count) }
    }

    /// "65-99", "65 - 99", "3.5 to 5.0", "<200", ">39", or a printed note ("See note").
    static func rangeMatch(_ s: String) -> RangeMatch? {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return nil }
        for sep in [" - ", "-", "–", " to "] {
            let parts = t.components(separatedBy: sep)
            if parts.count == 2, let lo = Double(parts[0].trimmingCharacters(in: .whitespaces)),
               let hi = Double(parts[1].trimmingCharacters(in: .whitespaces).split(separator: " ").first.map(String.init) ?? "") {
                return RangeMatch(low: lo, high: hi, text: "\(fmt(lo))-\(fmt(hi))")
            }
        }
        if let v = leadingValue(t), let c = v.comparator {
            let upper = c.hasPrefix("<") || c == "≤"
            return RangeMatch(low: upper ? nil : v.value, high: upper ? v.value : nil, text: "\(c)\(fmt(v.value))")
        }
        return nil
    }

    static func applyRange(_ tail: String, to c: inout LabCandidate) {
        guard let r = rangeMatch(tail) else {
            if !tail.isEmpty, tail.count <= 40 { c.refText = tail } // printed qualifier such as "See note"
            return
        }
        c.refLow = r.low; c.refHigh = r.high; c.refText = r.text
    }

    static func confidence(_ c: LabCandidate) -> Double {
        var score = c.analyteKey == nil ? 0.2 : 0.5
        if c.valueNumeric != nil || c.valueText != nil { score += 0.2 }
        if c.unitNormalized != nil, c.analyteKey == nil || c.valueCanonical != nil { score += 0.15 }
        if c.refText != nil { score += 0.15 }
        return min(1, (score * 100).rounded() / 100)
    }

    public static func fmt(_ v: Double) -> String {
        v.rounded() == v ? String(Int(v)) : String(v)
    }

    /// MM/DD/YYYY, YYYY-MM-DD, or "Mar 14, 2026". Day-first formats are ambiguous and left for the user to enter.
    static func parseDate(_ raw: String) -> LocalDay? {
        let s = raw.trimmingCharacters(in: CharacterSet(charactersIn: " :")).split(separator: " ").prefix(3).joined(separator: " ")
        let token = s.split(separator: " ").first.map(String.init) ?? ""
        if let d = LocalDay(string: token) { return d }
        let mdy = token.split(separator: "/").compactMap { Int($0) }
        if mdy.count == 3, (1...12).contains(mdy[0]), (1...31).contains(mdy[1]) {
            let y = mdy[2] < 100 ? 2000 + mdy[2] : mdy[2]
            return LocalDay(year: y, month: mdy[0], day: mdy[1])
        }
        let months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
        let parts = s.lowercased().replacingOccurrences(of: ",", with: "").split(separator: " ").map(String.init)
        if parts.count >= 3, let m = months.firstIndex(where: { parts[0].hasPrefix($0) }), let d = Int(parts[1]), let y = Int(parts[2]) {
            return LocalDay(year: y, month: m + 1, day: d)
        }
        return nil
    }
}
