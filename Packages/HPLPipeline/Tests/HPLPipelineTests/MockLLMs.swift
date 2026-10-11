import Foundation
import HPLCore
import HPLInference

/// Stand-ins for an on-device LLM so the M3 paths run on Linux CI. They read the same prompt a real model gets.
enum MockLLM {
    /// Field each rule's note cites. Late meal is skipped on purpose (a model won't cover every hit).
    static let citedPath: [String: (path: String, label: String)] = [
        RuleID.sleepShort: ("sleep.total_min", "Total sleep"),
        RuleID.deepSleepLow: ("sleep.deep_min", "Deep sleep"),
        RuleID.bedtimeLate: ("sleep.bed_local", "Bedtime"),
        RuleID.hrvLow: ("heart.hrv_sdnn_ms_overnight_median", "Overnight HRV"),
        RuleID.restingHRHigh: ("heart.resting_hr", "Resting HR"),
        RuleID.stepsLow: ("activity.steps", "Steps"),
        RuleID.stepsHigh: ("activity.steps", "Steps"),
        RuleID.noExercise: ("activity.exercise_min", "Exercise minutes"),
        RuleID.hardWorkout: ("workouts.0.duration_min", "Workout length"),
        RuleID.experimentActive: ("active_experiments.0.day", "Experiment day"),
        RuleID.lowCompleteness: ("completeness", "Data completeness"),
    ]

    static func text(_ v: JSONValue) -> String? {
        if case .number(let n) = v { return n.rounded() == n ? String(Int(n)) : String(n) }
        if case .string(let s) = v { return s }
        return nil
    }

    static func note(_ kind: String, _ title: String, _ body: String, _ path: String, experiment: String = "") -> String {
        let exp = experiment.isEmpty ? "" : #","experiment":{"intervention":"\#(experiment)","duration_days":14,"metric":"\#(path)"}"#
        return #"{"kind":"\#(kind)","title":"\#(title)","body":"\#(body)","evidence":["\#(path)"]\#(exp)}"#
    }

    /// Copies numbers verbatim, proposes one experiment. Should pass the M3 gate.
    static let careful: ScriptedInsightEngine.Responder = { _, input in
        let data = try JSONDecoder().decode(JSONValue.self, from: Data(input.dataJSON.utf8))
        var notes: [String] = []
        for id in input.ruleHitIDs.prefix(3) {
            guard let (path, label) = citedPath[id], let value = data.value(at: path).flatMap(text) else { continue }
            let isExperiment = id == RuleID.sleepShort || id == RuleID.stepsLow
            notes.append(note(isExperiment ? "experiment" : "observation", label, "\(label) was \(value) today.", path,
                              experiment: isExperiment ? "One small change each day" : ""))
        }
        return #"{"notes":[\#(notes.joined(separator: ","))]}"#
    }

    /// Invents arithmetic ("x% below") and parrots meal labels: the guard must rewrite/drop all of it.
    static let sloppy: ScriptedInsightEngine.Responder = { _, input in
        let data = try JSONDecoder().decode(JSONValue.self, from: Data(input.dataJSON.utf8))
        var notes: [String] = []
        for id in input.ruleHitIDs.prefix(2) {
            guard let (path, label) = citedPath[id], case .number(let n)? = data.value(at: path) else { continue }
            notes.append(note("observation", label, "\(label) was \(Int(n * 1.13) + 3), about 17 percent off your usual.", path))
        }
        if case .array(let meals)? = data.value(at: "meals"), meals.count > 1, let label = meals.last?.value(at: "label").flatMap(text) {
            notes.append(note("observation", "About your meal", "Your note says: \(label)", "meals.\(meals.count - 1).label"))
        }
        return #"{"notes":[\#(notes.prefix(3).joined(separator: ","))]}"#
    }

    /// Not JSON at all.
    static let broken: ScriptedInsightEngine.Responder = { _, _ in "I'm sorry, I can't help with health data." }
}
