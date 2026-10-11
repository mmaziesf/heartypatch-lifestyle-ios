import Foundation
import Testing
import HPLCore
@testable import HPLCloud

/// M6 exit criterion: no identifier leakage across 1,000 randomized profiles (§7.4, §11).
/// Every string field the anonymizer can see carries a unique canary; none may reach the bytes.
@Suite struct PropertyTests {
    @Test func noCanaryLeaksAcrossOneThousandRandomWindows() throws {
        var rng = SeededRNG(seed: 0xC0FFEE)
        var maxBytes = 0
        for run in 0..<1_000 {
            let canary = "zqx\(run)canary"
            let n = Int(rng.uniform(14, 57))
            let w = window(n) { i, d in randomSummary(d, i: i, canary: canary, rng: &rng) }
            let windowDays = n > 28 && rng.uniform(0, 1) < 0.5 ? 56 : 28
            let policy = AnonymizationPolicy(windowDays: windowDays, includeMeals: rng.uniform(0, 1) < 0.8, includeLabs: rng.uniform(0, 1) < 0.5)
            let p: CloudPayloadV1
            do { p = try Anonymizer.payload(w, policy: policy, requestID: UUID()) } catch AnonymizerError.insufficientData { continue }
            let body = try p.encoded()
            maxBytes = max(maxBytes, body.count)
            let text = String(bytes: body, encoding: .utf8) ?? ""
            #expect(!text.contains("canary") && !text.contains("zqx"), "run \(run)")
            #expect(text.range(of: #"\d{4}-\d{2}-\d{2}"#, options: .regularExpression) == nil, "no calendar dates, run \(run)")
            #expect(PayloadAudit.violations(body, maxBytes: EgressGate.maxPayloadBytes).isEmpty, "run \(run)")
            #expect(p.daily.count <= 28 && p.daily.allSatisfy { (-27...0).contains($0.day) })
            for d in p.daily {
                if let v = d.sleepTotalMin { #expect(CloudMetric.sleepTotalMin.range.contains(Double(v))) }
                if let v = d.restingHR { #expect(CloudMetric.restingHR.range.contains(Double(v))) }
                if let v = d.steps { #expect(CloudMetric.steps.range.contains(Double(v)) && v % 100 == 0) }
            }
        }
        #expect(maxBytes <= EgressGate.maxPayloadBytes)
    }

    @Test func auditCatchesWhatTheAnonymizerMustNeverEmit() {
        func audit(_ s: String) -> [String] { PayloadAudit.violations(Data(s.utf8), maxBytes: 10_000) }
        #expect(!audit(#"{"name":"Arash"}"#).isEmpty)
        #expect(!audit(#"{"daily":[{"dow":"2026-10-10"}]}"#).isEmpty)
        #expect(!audit(#"{"daily":[{"bed_local":"23:44"}]}"#).isEmpty, "times must be on the half hour")
        #expect(!audit(#"{"request_id":"not-a-uuid"}"#).isEmpty)
        #expect(!audit(#"{"labs":[{"analyte":"lpa"}]}"#).isEmpty)
        #expect(audit(#"{"daily":[{"bed_local":"23:30","dow":"Sat"}],"profile":{"age_band":"35-39"}}"#).isEmpty)
        #expect(!PayloadAudit.violations(Data(repeating: 32, count: 20), maxBytes: 10).isEmpty)
    }
}

private func pick<T>(_ xs: [T], _ rng: inout SeededRNG) -> T { xs[Int(rng.uniform(0, Double(xs.count) - 0.001))] }

private func randomSummary(_ d: LocalDay, i: Int, canary: String, rng: inout SeededRNG) -> DailySummaryV1 {
    func maybe<T>(_ v: T) -> T? { rng.uniform(0, 1) < 0.85 ? v : nil }
    let wild = [-50.0, 0, 3, 55, 61.37, 140, 999, 1e7, .nan, .infinity]
    let time = pick(["23:44", "07:15", canary, "25:99", "00:00", "1:5"], &rng)
    return DailySummaryV1(
        provenance: .device, day: d.description, dayOfWeek: d.weekdayAbbrev(calendar: la),
        profile: .init(ageBand: pick(["35-39", canary, "37-41", "80+"], &rng), sexForRanges: pick(["M", "F", canary], &rng)),
        sleep: .init(totalMin: maybe(Int(rng.uniform(-100, 2000))), deepMin: maybe(Int(rng.uniform(0, 400))), bedLocal: time, wakeLocal: canary),
        heart: .init(restingHR: maybe(pick(wild, &rng)), hrvSDNNOvernightMedian: maybe(pick(wild, &rng))),
        activity: .init(steps: maybe(Int(rng.uniform(-10, 200_000))), activeKcal: maybe(pick(wild, &rng)), exerciseMin: maybe(Int(rng.uniform(0, 900)))),
        workouts: [.init(type: "\(canary)-run", durationMin: Int(rng.uniform(0, 1000))), .init(type: "running", durationMin: 31)],
        meals: [.init(tLocal: time, label: canary, tags: [canary, "late"]), .init(tLocal: "12:20", label: "lunch", tags: ["high-protein"])],
        labsRecent: [.init(analyte: canary, value: 1, unit: "mg/dL", refLow: nil, refHigh: nil, reportFlag: canary, ageDays: 3),
                     .init(analyte: "ldl", value: pick(wild, &rng), unit: pick(["mg/dL", canary], &rng), refLow: nil, refHigh: nil,
                           reportFlag: canary, ageDays: Int(rng.uniform(0, 400)))],
        activeExperiments: [.init(id: canary, intervention: canary, day: 1, of: 14)], completeness: 1)
}
