import Foundation
import HPLCore

/// Model output schema v1, shared by every LLM engine. Foundation Models fills it through guided generation;
/// text engines (MLX, scripted test engines) return it as JSON. Validation here is structural; content goes to OutputGuard.
public struct NotesOutputV1: Codable, Sendable, Equatable {
    public struct Experiment: Codable, Sendable, Equatable {
        public var intervention: String
        public var durationDays: Int
        public var metric: String
        public init(intervention: String, durationDays: Int, metric: String) {
            self.intervention = intervention; self.durationDays = durationDays; self.metric = metric
        }
        enum CodingKeys: String, CodingKey { case intervention, durationDays = "duration_days", metric }
    }

    public struct Note: Codable, Sendable, Equatable {
        public var kind: String
        public var title: String
        public var body: String
        public var evidence: [String]
        public var experiment: Experiment?
        public init(kind: String, title: String, body: String, evidence: [String], experiment: Experiment? = nil) {
            self.kind = kind; self.title = title; self.body = body; self.evidence = evidence; self.experiment = experiment
        }
    }

    public static let allowedKinds: [String: RecommendationKind] = ["observation": .observation, "nudge": .nudge, "experiment": .experiment]
    public static let maxTitleLength = 80
    public static let maxBodyLength = 320

    public var notes: [Note]
    public init(notes: [Note]) { self.notes = notes }

    public static func decode(json text: String) throws -> NotesOutputV1 {
        // Models sometimes wrap JSON in prose or code fences: take the outermost object.
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end else {
            throw InsightEngineError.schemaInvalid("no JSON object")
        }
        do {
            return try JSONDecoder().decode(NotesOutputV1.self, from: Data(text[start...end].utf8))
        } catch {
            throw InsightEngineError.schemaInvalid("decode: \(error)")
        }
    }

    /// Schema-valid drafts or an error. An engine may not emit clinician prompts; those are fixed copy.
    public func drafts() throws -> [RecommendationDraft] {
        guard notes.count <= InsightPrompt.maxNotes else { throw InsightEngineError.schemaInvalid("too many notes: \(notes.count)") }
        return try notes.map { note in
            guard let kind = Self.allowedKinds[note.kind] else { throw InsightEngineError.schemaInvalid("kind: \(note.kind)") }
            let title = note.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let body = note.body.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty, !body.isEmpty, title.count <= Self.maxTitleLength, body.count <= Self.maxBodyLength else {
                throw InsightEngineError.schemaInvalid("title/body length")
            }
            if kind == .experiment, note.experiment == nil { throw InsightEngineError.schemaInvalid("experiment without proposal") }
            let experiment = kind == .experiment ? note.experiment.map {
                ExperimentProposal(intervention: $0.intervention, durationDays: $0.durationDays, metricFieldPath: $0.metric)
            } : nil
            return RecommendationDraft(kind: kind, title: title, body: body, evidenceFieldPaths: note.evidence, experiment: experiment)
        }
    }
}

/// Test/eval engine that behaves like a text LLM: gets the real prompt, returns JSON text.
/// Used on Linux/CI (no Apple FM) to exercise prompt building, schema validation, guard and fallback paths.
public struct ScriptedInsightEngine: InsightEngine {
    public typealias Responder = @Sendable (_ instructions: String, _ prompt: InsightPrompt.Input) async throws -> String

    public let id: String
    public let generator: Generator
    private let availability: EngineAvailability
    private let respond: Responder

    public init(id: String = "scripted", availability: EngineAvailability = .available, respond: @escaping Responder) {
        self.id = id
        self.generator = Generator(engine: .mlx, modelID: id, promptVersion: InsightPrompt.version)
        self.availability = availability
        self.respond = respond
    }

    public func isAvailable() async -> EngineAvailability { availability }

    public func generate(summary: DailySummaryV1, ruleHits: [RuleHit]) async throws -> [RecommendationDraft] {
        let input = try InsightPrompt.input(summary: summary, ruleHits: ruleHits)
        return try NotesOutputV1.decode(json: try await respond(InsightPrompt.instructions, input)).drafts()
    }
}
