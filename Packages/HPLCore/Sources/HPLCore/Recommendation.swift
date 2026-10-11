import Foundation

public enum RecommendationKind: String, Codable, Sendable { case observation, experiment, nudge, clinicianPrompt = "clinician_prompt" }

/// A deterministic rule that fired, with the summary fields that justify it.
public struct RuleHit: Codable, Sendable, Hashable {
    public var id: String
    public var evidenceFieldPaths: [String]
    public init(id: String, evidenceFieldPaths: [String]) { self.id = id; self.evidenceFieldPaths = evidenceFieldPaths }
}

/// An N-of-1 self-experiment idea: one behaviour change, a fixed window, one summary metric to compare
/// (baseline window vs intervention window). Tracking/results arrive in M4.
public struct ExperimentProposal: Codable, Sendable, Equatable, Hashable {
    public static let allowedDurations: Set<Int> = [7, 14]
    public var intervention: String
    public var durationDays: Int
    /// Summary field path compared before vs during, e.g. `sleep.total_min`.
    public var metricFieldPath: String
    public init(intervention: String, durationDays: Int, metricFieldPath: String) {
        self.intervention = intervention; self.durationDays = durationDays; self.metricFieldPath = metricFieldPath
    }
    enum CodingKeys: String, CodingKey { case intervention, durationDays = "duration_days", metricFieldPath = "metric_field_path" }
}

/// Engine output before the output guard.
public struct RecommendationDraft: Codable, Sendable, Equatable {
    public var kind: RecommendationKind
    public var title: String
    public var body: String
    public var evidenceFieldPaths: [String]
    public var experiment: ExperimentProposal?
    public init(kind: RecommendationKind, title: String, body: String, evidenceFieldPaths: [String], experiment: ExperimentProposal? = nil) {
        self.kind = kind; self.title = title; self.body = body; self.evidenceFieldPaths = evidenceFieldPaths; self.experiment = experiment
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
    public var experiment: ExperimentProposal?
    public var generator: Generator
    public var guardResult: GuardResult
    public var provenance: DailySummaryV1.Provenance

    public init(id: UUID = UUID(), day: String, kind: RecommendationKind, title: String, body: String,
                evidence: [EvidenceRef], experiment: ExperimentProposal? = nil, generator: Generator, guardResult: GuardResult,
                provenance: DailySummaryV1.Provenance) {
        self.id = id; self.day = day; self.kind = kind; self.title = title; self.body = body
        self.evidence = evidence; self.experiment = experiment; self.generator = generator; self.guardResult = guardResult; self.provenance = provenance
    }
}
