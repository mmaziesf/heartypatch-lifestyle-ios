import HPLCore
import HPLPipeline

/// User-facing strings for notes, kept out of views so they're unit-tested and reviewed in one place (§13 copy review).
public enum NoteCopy {
    public static func kindLabel(_ kind: RecommendationKind) -> String {
        switch kind {
        case .observation: "OBSERVATION"
        case .nudge: "NUDGE"
        case .experiment: "EXPERIMENT IDEA"
        case .clinicianPrompt: "FROM YOUR REPORT"
        }
    }

    public static func statusBadge(_ status: NoteStatus) -> String? {
        switch status {
        case .new: nil
        case .accepted: "Accepted"
        case .dismissed: "Dismissed"
        case .snoozed: "Snoozed"
        case .done: "Done"
        }
    }

    public static func proposal(_ e: ExperimentProposal) -> String {
        "Try for \(e.durationDays) days: \(e.intervention). Compare \(FieldLabels.label(for: e.metricFieldPath).name.lowercased())."
    }

    public static func engine(_ g: Generator) -> String {
        switch g.engine {
        case .rules: "Fixed templates (no AI model)"
        case .fm: "Apple's on-device model"
        case .mlx: "Downloaded on-device model"
        case .cloud: "Cloud analysis"
        }
    }

    public static func guardExplanation(_ rec: Recommendation) -> String {
        if rec.kind == .clinicianPrompt {
            return "This is fixed wording shown whenever your report prints a critical flag. It isn't written by an AI model and doesn't interpret the value."
        }
        switch rec.guardResult {
        case .pass:
            return "Checked by fixed safety rules: no medical claims, every number appears in your data, every value above is cited."
        case .rewritten:
            return "The model's version used a number that isn't in your data, so it was replaced by a fixed template."
        case .blocked:
            return "Blocked by safety rules."
        }
    }
}

public enum ExperimentCopy {
    public static func progressLine(_ e: Experiment, _ p: ExperimentTracker.Progress) -> String {
        "Compared on \(FieldLabels.label(for: e.metricFieldPath).name.lowercased()). Did it on \(p.checkInsYes) of \(p.checkInsTotal) days checked in."
    }
}
