import Foundation
import HPLCore

/// Deterministic post-engine guard (architecture §6.6). Runs on every draft from every engine, rules included.
public struct OutputGuard: Sendable {
    public struct Verdict: Sendable, Equatable {
        public var result: GuardResult
        public var reasons: [String]
        /// True when the draft failed only on untraceable numbers: the pipeline may swap in the rule template (`.rewritten`).
        public var failedOnlyOnNumbers: Bool {
            result == .blocked && !reasons.isEmpty && reasons.allSatisfy { $0.hasPrefix(Self.numberReasonPrefix) }
        }
        public static let numberReasonPrefix = "untraceable number"
    }

    /// Window lengths in field names (`_28d`) and experiment durations may appear in copy without being values.
    public var allowedConstants: Set<Double> = [7, 14, 28]

    /// Diagnostic / treatment / dosing / interpretation language. Lowercased substring match, so entries are chosen
    /// not to collide with ordinary words ("risk of", not "risk", which would hit "brisk").
    public var blockedPhrases: [String] = [
        "diagnos", "you have ", "deficien", "disease", "disorder", "syndrome", "prediabet", "diabet", "afib",
        "atrial fibrillation", "arrhythmia", "hypertension", "apnea", "cancer", "depression", "anxiety disorder",
        "treat", "cure", "prescri", "medication", "stop taking", "dosage", "supplement",
        "insulin", "metformin", "statin", "melatonin", "magnesium", "thyroid", "anemi", "inflamm", "infection",
        "abnormal", "dangerous", "risk of", "doctor", "symptom", "illness",
    ]

    public init() {}

    public func check(_ draft: RecommendationDraft, against summary: JSONValue) -> Verdict {
        var reasons = languageReasons(draft.title + " " + draft.body)
        reasons += evidenceReasons(draft, summary)
        reasons += clinicianReasons(draft)
        if let e = draft.experiment { reasons += experimentReasons(e, summary) }
        for n in untraceableNumbers(in: draft.title + " " + draft.body, against: summary) {
            reasons.append("\(Verdict.numberReasonPrefix): \(n)")
        }
        return Verdict(result: reasons.isEmpty ? .pass : .blocked, reasons: reasons)
    }

    /// Numbers in copy that don't appear in the input (± rounding) and aren't allowed constants.
    public func untraceableNumbers(in text: String, against summary: JSONValue) -> [Double] {
        let inputs = summary.allNumbers
        return NumberScanner.numbers(in: text).filter { !traceable($0, inputs) }
    }

    /// Blocklist hits in final copy, for eval reporting.
    public func blocklistHits(_ text: String) -> [String] {
        let lower = text.lowercased()
        return blockedPhrases.filter { lower.contains($0) }
    }

    private func languageReasons(_ text: String) -> [String] {
        var reasons = blocklistHits(text).map { "blocked phrase: \($0.trimmingCharacters(in: .whitespaces))" }
        if containsDose(text.lowercased()) { reasons.append("dose pattern") }
        return reasons
    }

    private func evidenceReasons(_ draft: RecommendationDraft, _ summary: JSONValue) -> [String] {
        if draft.evidenceFieldPaths.isEmpty { return ["no evidence"] }
        return draft.evidenceFieldPaths.filter { summary.value(at: $0) == nil }.map { "unresolved evidence: \($0)" }
    }

    /// Clinician prompts are fixed copy (§6.6); anything else with that kind was written by something it shouldn't have been.
    private func clinicianReasons(_ draft: RecommendationDraft) -> [String] {
        guard draft.kind == .clinicianPrompt else { return [] }
        return draft.body == RuleTemplates.clinicianCopy && draft.experiment == nil ? [] : ["clinician prompt not fixed copy"]
    }

    private func experimentReasons(_ e: ExperimentProposal, _ summary: JSONValue) -> [String] {
        var reasons: [String] = []
        if !ExperimentProposal.allowedDurations.contains(e.durationDays) { reasons.append("experiment duration: \(e.durationDays)") }
        if case .number = summary.value(at: e.metricFieldPath) {} else { reasons.append("experiment metric: \(e.metricFieldPath)") }
        let text = e.intervention.trimmingCharacters(in: .whitespaces)
        if text.isEmpty || text.count > 80 { reasons.append("experiment intervention length") }
        if !NumberScanner.numbers(in: text).isEmpty { reasons.append("experiment intervention has numbers") }
        reasons += languageReasons(text).map { "experiment " + $0 }
        return reasons
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
