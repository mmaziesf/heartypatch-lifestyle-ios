import Foundation
import HPLCore

/// Where an approved payload goes. `EgressGate` is the only caller.
public protocol CloudTransport: Sendable {
    var id: String { get }
    /// True if `post` sends bytes off the device (shown in Settings and stored in the egress log).
    var leavesDevice: Bool { get }
    func post(_ body: Data, requestID: String) async throws -> Data
}

/// The build's default transport: a deterministic analyzer that runs on this iPhone. Nothing leaves the device.
/// It exercises the full egress path (consent, preview, hash, audit, response schema, OutputGuard) without a server.
public struct DemoCloudTransport: CloudTransport {
    public let id = "demo-on-device"
    public let leavesDevice = false
    public init() {}

    public func post(_ body: Data, requestID: String) async throws -> Data {
        let payload = try JSONDecoder().decode(CloudPayloadV1.self, from: body)
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return try e.encode(DemoCloudAnalyzer.analyze(payload))
    }
}

/// Multi-week pattern copy from the payload alone. Every number it writes is copied from the payload, so it passes OutputGuard.
public enum DemoCloudAnalyzer {
    public static func analyze(_ p: CloudPayloadV1) -> CloudInsightsV1 {
        var out: [CloudInsightsV1.Insight] = []
        if let i = trend(p, .sleepTotalMin, title: "Sleep across your weeks", unit: "minutes", noun: "sleep") { out.append(i) }
        if let i = trend(p, .steps, title: "Steps across your weeks", unit: "steps", noun: "step count") { out.append(i) }
        if let i = trend(p, .restingHR, title: "Resting heart rate across your weeks", unit: "bpm", noun: "resting heart rate") { out.append(i) }
        if let i = busiestDay(p) { out.append(i) }
        if let i = lateMeals(p) { out.append(i) }
        return CloudInsightsV1(requestID: p.requestID, insights: Array(out.prefix(CloudInsightsV1.maxInsights)))
    }

    static func trend(_ p: CloudPayloadV1, _ m: CloudMetric, title: String, unit: String, noun: String) -> CloudInsightsV1.Insight? {
        let idx = p.weeks.indices.filter { p.weeks[$0].metrics[m.rawValue] != nil }
        guard let first = idx.first, let last = idx.last, first != last,
              let a = p.weeks[first].metrics[m.rawValue]?.median, let b = p.weeks[last].metrics[m.rawValue]?.median else { return nil }
        let direction = a == b ? "held steady at" : (b > a ? "rose from \(CloudPreview.num(a)) to" : "fell from \(CloudPreview.num(a)) to")
        return .init(kind: "observation", title: title,
                     body: "Your weekly median \(noun) \(direction) \(CloudPreview.num(b)) \(unit) between the first and the most recent week.",
                     evidence: ["weeks.\(first).metrics.\(m.rawValue).median", "weeks.\(last).metrics.\(m.rawValue).median"])
    }

    static func busiestDay(_ p: CloudPayloadV1) -> CloudInsightsV1.Insight? {
        guard let i = p.daily.indices.filter({ p.daily[$0].steps != nil }).max(by: { (p.daily[$0].steps ?? 0, $1) < (p.daily[$1].steps ?? 0, $0) }),
              let steps = p.daily[i].steps else { return nil }
        return .init(kind: "observation", title: "Your most active recent day",
                     body: "Your highest step count in the recent rows was \(steps) steps, on a \(p.daily[i].dow).",
                     evidence: ["daily.\(i).steps"])
    }

    static func lateMeals(_ p: CloudPayloadV1) -> CloudInsightsV1.Insight? {
        for (i, d) in p.daily.enumerated() {
            if let j = d.meals.firstIndex(where: { $0.tags.contains("late") }) {
                return .init(kind: "nudge", title: "Late meals showed up",
                             body: "Some recent evenings had late meals. Finishing dinner a little earlier is an easy thing to try for 14 days.",
                             evidence: ["daily.\(i).meals.\(j).tags"])
            }
        }
        return nil
    }
}
