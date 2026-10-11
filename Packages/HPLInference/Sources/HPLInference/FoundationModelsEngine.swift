#if canImport(FoundationModels)
import Foundation
import FoundationModels
import HPLCore

/// Apple Foundation Models engine (architecture §6.2 DECISION: default LLM). On-device only; nothing leaves the phone.
/// Guided generation fills `FMNotes`, which maps 1:1 onto `NotesOutputV1` so every engine shares one validator and guard.
@available(iOS 26.0, macOS 26.0, *)
public struct FoundationModelsEngine: InsightEngine {
    public let id = "apple-foundation-models"
    public let generator = Generator(engine: .fm, modelID: "apple.system.default", promptVersion: InsightPrompt.version)

    public init() {}

    public func isAvailable() async -> EngineAvailability {
        switch SystemLanguageModel.default.availability {
        case .available: return .available
        case .unavailable(.deviceNotEligible): return .unavailable(reason: "This device doesn't support Apple Intelligence")
        case .unavailable(.appleIntelligenceNotEnabled): return .unavailable(reason: "Apple Intelligence is turned off")
        case .unavailable(.modelNotReady): return .unavailable(reason: "The on-device model is still downloading")
        case .unavailable: return .unavailable(reason: "The on-device model is unavailable")
        }
    }

    public func generate(summary: DailySummaryV1, ruleHits: [RuleHit]) async throws -> [RecommendationDraft] {
        let input = try InsightPrompt.input(summary: summary, ruleHits: ruleHits)
        guard input.estimatedTokens <= InsightPrompt.maxDataTokens * 2 else { throw InsightEngineError.contextOverflow }
        // One fresh single-turn session per day: no transcript carries between days.
        let session = LanguageModelSession(model: .default, tools: []) { InsightPrompt.instructions }
        let options = GenerationOptions(sampling: .greedy, maximumResponseTokens: 600)
        do {
            let response = try await session.respond(to: input.text, generating: FMNotes.self, options: options)
            return try response.content.output.drafts()
        } catch let error as LanguageModelSession.GenerationError {
            throw Self.map(error)
        }
    }

    static func map(_ error: LanguageModelSession.GenerationError) -> InsightEngineError {
        switch error {
        case .guardrailViolation: .refused("guardrail")
        case .exceededContextWindowSize: .contextOverflow
        case .decodingFailure: .schemaInvalid("fm decoding")
        default: .generationFailed(String(describing: error))
        }
    }
}

@available(iOS 26.0, macOS 26.0, *)
@Generable
struct FMNotes {
    @Guide(description: "Zero to three lifestyle notes about this day.", .maximumCount(3))
    var notes: [FMNote]

    var output: NotesOutputV1 { NotesOutputV1(notes: notes.map(\.output)) }
}

@available(iOS 26.0, macOS 26.0, *)
@Generable
struct FMNote {
    @Guide(description: "Note kind.", .anyOf(["observation", "nudge", "experiment"]))
    var kind: String
    @Guide(description: "Short title, under eight words.")
    var title: String
    @Guide(description: "One or two plain sentences. Only numbers copied from the data.")
    var body: String
    @Guide(description: "Field paths from the data that support this note, e.g. sleep.total_min.", .minimumCount(1), .maximumCount(4))
    var evidence: [String]
    @Guide(description: "Only for kind experiment: the self-experiment to try.")
    var experiment: FMExperiment?

    var output: NotesOutputV1.Note {
        .init(kind: kind, title: title, body: body, evidence: evidence, experiment: experiment.map {
            // `.range` can't express {7, 14}; snap so the guard's duration check sees an allowed window.
            .init(intervention: $0.intervention, durationDays: $0.durationDays < 11 ? 7 : 14, metric: $0.metric)
        })
    }
}

@available(iOS 26.0, macOS 26.0, *)
@Generable
struct FMExperiment {
    @Guide(description: "One behaviour change, no numbers, no products.")
    var intervention: String
    @Guide(description: "Length in days: 7 or 14.", .range(7...14))
    var durationDays: Int
    @Guide(description: "One field path from the data to compare before vs during, e.g. sleep.total_min.")
    var metric: String
}
#endif
