import Foundation

public enum RecommendationKind: String, Codable, Sendable { case observation, experiment, nudge, clinicianPrompt = "clinician_prompt" }

/// A deterministic rule that fired, with the summary fields that justify it.
public struct RuleHit: Codable, Sendable, Hashable {
    public var id: String
    public var evidenceFieldPaths: [String]
    public init(id: String, evidenceFieldPaths: [String]) { self.id = id; self.evidenceFieldPaths = evidenceFieldPaths }
}

/// Engine output before the output guard.
public struct RecommendationDraft: Codable, Sendable, Equatable {
    public var kind: RecommendationKind
    public var title: String
    public var body: String
    public var evidenceFieldPaths: [String]
    public init(kind: RecommendationKind, title: String, body: String, evidenceFieldPaths: [String]) {
        self.kind = kind; self.title = title; self.body = body; self.evidenceFieldPaths = evidenceFieldPaths
    }
}

public struct EvidenceRef: Codable, Sendable, Hashable {
    public var summaryDay: String
    public var fieldPath: String
    public var value: JSONValue
    public init(summaryDay: String, fieldPath: String, value: JSONValue) {
        self.summaryDay = summaryDay; self.fieldPath = fieldPath; self.value = value
    }
}

public struct Generator: Codable, Sendable, Hashable {
    public enum Engine: String, Codable, Sendable { case fm, mlx, rules, cloud }
    public var engine: Engine
    public var modelID: String?
    public var promptVersion: String
    public init(engine: Engine, modelID: String? = nil, promptVersion: String) {
        self.engine = engine; self.modelID = modelID; self.promptVersion = promptVersion
    }
}

public enum GuardResult: String, Codable, Sendable { case pass, rewritten, blocked }

public struct Recommendation: Codable, Sendable, Identifiable, Equatable {
    public var id: UUID
    public var day: String
    public var kind: RecommendationKind
    public var title: String
    public var body: String
    public var evidence: [EvidenceRef]
    public var generator: Generator
    public var guardResult: GuardResult
    public var provenance: DailySummaryV1.Provenance

    public init(id: UUID = UUID(), day: String, kind: RecommendationKind, title: String, body: String,
                evidence: [EvidenceRef], generator: Generator, guardResult: GuardResult,
                provenance: DailySummaryV1.Provenance) {
        self.id = id; self.day = day; self.kind = kind; self.title = title; self.body = body
        self.evidence = evidence; self.generator = generator; self.guardResult = guardResult; self.provenance = provenance
    }
}
