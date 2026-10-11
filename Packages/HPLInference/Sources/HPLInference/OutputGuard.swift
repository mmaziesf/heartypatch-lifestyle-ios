import Foundation
import HPLCore

/// Deterministic post-engine guard (architecture §6.6). Runs on every draft from every engine.
public struct OutputGuard: Sendable {
    public struct Verdict: Sendable, Equatable {
        public var result: GuardResult
        public var reasons: [String]
    }

    /// Window lengths baked into field names (e.g. `_28d`) may appear in copy without being values.
    public var allowedConstants: Set<Double> = [7, 28]

    /// Diagnostic / treatment / dosing language. Lowercased substring match; curated list grows in M3.
    public var blockedPhrases: [String] = [
        "diagnos", "you have ", "deficien", "disease", "disorder", "syndrome", "prediabet", "diabet", "afib",
        "atrial fibrillation", "arrhythmia", "hypertension", "apnea", "cancer", "depression", "anxiety disorder",
        "treat", "cure", "prescri", "medication", "stop taking", "dosage", "supplement",
    ]

    public init() {}

    public func check(_ draft: RecommendationDraft, against summary: JSONValue) -> Verdict {
        var reasons: [String] = []
        let text = (draft.title + " " + draft.body).lowercased()

        for phrase in blockedPhrases where text.contains(phrase) { reasons.append("blocked phrase: \(phrase.trimmingCharacters(in: .whitespaces))") }
        if containsDose(text) { reasons.append("dose pattern") }

        if draft.evidenceFieldPaths.isEmpty { reasons.append("no evidence") }
        for path in draft.evidenceFieldPaths where summary.value(at: path) == nil { reasons.append("unresolved evidence: \(path)") }

        let inputNumbers = summary.allNumbers
        for n in NumberScanner.numbers(in: draft.title + " " + draft.body) where !traceable(n, inputNumbers) {
            reasons.append("untraceable number: \(n)")
        }
        // M0: any failure blocks. M3 adds template rewrite (-> .rewritten) for number failures.
        return Verdict(result: reasons.isEmpty ? .pass : .blocked, reasons: reasons)
    }

    private func traceable(_ n: Double, _ inputs: [Double]) -> Bool {
        if allowedConstants.contains(n) { return true }
        let tolerance = n.rounded() == n ? 0.5 : 0.05
        return inputs.contains { abs($0 - n) <= tolerance }
    }

    private func containsDose(_ text: String) -> Bool {
        let units = ["mg", "mcg", "µg", "iu", "units"]
        let tokens = text.split(whereSeparator: { $0.isWhitespace })
        for (i, tok) in tokens.enumerated() {
            let t = tok.trimmingCharacters(in: .punctuationCharacters)
            // "500mg" or "500 mg"
            if let unit = units.first(where: { t.hasSuffix($0) }), Double(t.dropLast(unit.count)) != nil { return true }
            if Double(t) != nil, i + 1 < tokens.count,
               units.contains(tokens[i + 1].trimmingCharacters(in: .punctuationCharacters)) { return true }
        }
        return false
    }
}
