import Foundation
import HPLCore

/// Human-readable rendering of exactly what's in the payload, plus the raw JSON (the same bytes that get sent).
public struct CloudPreview: Sendable, Equatable {
    public struct Section: Sendable, Equatable {
        public var title: String
        public var lines: [String]
    }

    public var sections: [Section]
    public var json: String
    public var bytes: Int
    public var sha256: String

    public init(_ p: CloudPayloadV1, body: Data) {
        json = String(bytes: body, encoding: .utf8) ?? ""
        bytes = body.count
        sha256 = SHA256Digest.hex(body)
        var s: [Section] = []
        s.append(Section(title: "Request", lines: [
            "Random request id, new for this job. No account, device or user id.",
            p.provenance == .syntheticFixture ? "Data: synthetic example, not yours." : "Data: from this iPhone.",
            "Window: \(p.windowDays) days (\(p.daysWithData) with data), numbered D-\(p.windowDays - 1) … D0. No calendar dates.",
        ]))
        if let profile = p.profile {
            let lines = [profile.ageBand.map { "Age band \($0)" }, profile.sexForRanges.map { "Sex for ranges \($0)" }]
            s.append(Section(title: "Profile", lines: lines.compactMap { $0 }))
        }
        s.append(Section(title: "Weekly summaries (\(p.weeks.count))", lines: p.weeks.map { w in
            let metrics = w.metrics.keys.sorted().map { k in "\(Self.label(k)) \(Self.num(w.metrics[k]!.median))" }.joined(separator: ", ")
            return "W\(w.week): \(w.daysWithData) days · median " + (metrics.isEmpty ? "none" : metrics)
        }))
        s.append(Section(title: "Daily rows (\(p.daily.count))", lines: p.daily.map(Self.dayLine)))
        s.append(Section(title: "Lab values (\(p.labs.count))", lines: p.labs.isEmpty ? ["None"] : p.labs.map {
            "\($0.analyte) \(Self.num($0.value)) \($0.unit), measured \($0.ageBucket) days before"
        }))
        s.append(Section(title: "Never included", lines: [
            "Name, calendar dates, locations, food names, notes and voice notes, report text, lab or clinic names, device ids.",
        ]))
        sections = s
    }

    static func dayLine(_ d: CloudPayloadV1.Day) -> String {
        var bits = ["D\(d.day) \(d.dow)"]
        if let v = d.sleepTotalMin { bits.append("sleep \(v) min") }
        if let v = d.restingHR { bits.append("RHR \(v)") }
        if let v = d.hrvMs { bits.append("HRV \(v)") }
        if let v = d.steps { bits.append("\(v) steps") }
        if let v = d.exerciseMin { bits.append("exercise \(v) min") }
        if let b = d.bedLocal, let w = d.wakeLocal { bits.append("bed \(b) wake \(w)") }
        if !d.meals.isEmpty {
            let meals = d.meals.map { "\($0.label) \($0.tLocal)" + ($0.tags.isEmpty ? "" : " [\($0.tags.joined(separator: ","))]") }
            bits.append("meals " + meals.joined(separator: "; "))
        }
        if !d.workouts.isEmpty { bits.append("workouts " + d.workouts.map { "\($0.type) \($0.durationMin) min" }.joined(separator: ", ")) }
        return bits.joined(separator: " · ")
    }

    static func label(_ key: String) -> String {
        switch CloudMetric(rawValue: key) {
        case .sleepTotalMin: "sleep"
        case .sleepDeepMin: "deep"
        case .restingHR: "RHR"
        case .hrvMs: "HRV"
        case .steps: "steps"
        case .exerciseMin: "exercise"
        case .activeKcal: "active kcal"
        case nil: key
        }
    }

    static func num(_ v: Double) -> String { v == v.rounded() ? String(Int(v)) : String(v) }
}
