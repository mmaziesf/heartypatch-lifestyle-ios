import Foundation
import Testing
import HPLCore
@testable import HPLCloud

@Suite struct AnonymizerTests {
    @Test func syntheticWindowShapeAndDefaults() throws {
        let w = SyntheticWindow.make(days: 28, anchor: anchor, calendar: la, seed: 1)
        let p = try Anonymizer.payload(w, policy: AnonymizationPolicy(), requestID: fixedID)
        #expect(p.daysWithData == 28 && p.windowDays == 28 && p.provenance == .syntheticFixture)
        #expect(p.weeks.map(\.week) == [-3, -2, -1, 0] && p.weeks.allSatisfy { $0.daysWithData == 7 })
        #expect(p.daily.map(\.day) == Array(-27...0))
        #expect(p.labs.isEmpty, "labs are opt-in per job")
        let body = try p.encoded()
        let text = String(bytes: body, encoding: .utf8) ?? ""
        #expect(!text.contains("2026") && !text.contains("traditionalStrengthTraining"))
        #expect(PayloadAudit.violations(body, maxBytes: EgressGate.maxPayloadBytes).isEmpty)
    }

    @Test func fiftySixDayWindowFitsTheCap() throws {
        let w = SyntheticWindow.make(days: 56, anchor: anchor, calendar: la, seed: 2)
        let p = try Anonymizer.payload(w, policy: AnonymizationPolicy(windowDays: 56, includeLabs: true), requestID: fixedID)
        #expect(p.weeks.count == 8 && p.daily.count == 28)
        #expect(try p.encoded().count <= EgressGate.maxPayloadBytes)
    }

    @Test func roundsClampsAndDropsOutsideVocabulary() throws {
        let w = window(20) { i, d in
            guard i == 0 else { return summary(d) }
            return summary(d, sleep: 1000, rhr: 30, steps: 123_456,
                           meals: [.init(tLocal: "23:46", label: "brunch", tags: ["late", "bogus"]), .init(tLocal: "noon", label: "lunch", tags: [])],
                           workouts: [.init(type: "Kickboxing", durationMin: 33), .init(type: "traditionalStrengthTraining", durationMin: 900)],
                           labs: [.init(analyte: "ldl", value: 112.4, unit: "mg/dL", refLow: nil, refHigh: 100, reportFlag: "H", ageDays: 200),
                                  .init(analyte: "ldl_mmol", value: 2.9, unit: "mmol/L", refLow: nil, refHigh: nil, reportFlag: nil, ageDays: 1),
                                  .init(analyte: "hba1c", value: 5.43, unit: "%", refLow: nil, refHigh: nil, reportFlag: nil, ageDays: 10),
                                  .init(analyte: "lpa", value: 180, unit: "nmol/L", refLow: nil, refHigh: nil, reportFlag: "H", ageDays: 10),
                                  .init(analyte: "glucose", value: 5.1, unit: "mmol/L", refLow: nil, refHigh: nil, reportFlag: nil, ageDays: 10)],
                           profile: .init(ageBand: "37-41", sexForRanges: "X"), bed: "23:44")
        }
        let p = try Anonymizer.payload(w, policy: AnonymizationPolicy(includeLabs: true), requestID: fixedID)
        let d0 = try #require(p.daily.last)
        #expect(d0.day == 0 && d0.sleepTotalMin == 720 && d0.restingHR == 38 && d0.steps == 35_000)
        #expect(d0.bedLocal == "23:30" && d0.wakeLocal == "07:00")
        #expect(d0.meals == [.init(tLocal: "00:00", label: "meal", tags: ["late"])], "unparseable time dropped; label/tags from vocabulary")
        #expect(d0.workouts == [.init(type: "other", durationMin: 35), .init(type: "strength", durationMin: 300)])
        #expect(p.labs == [.init(analyte: "hba1c", value: 5.4, unit: "%", ageBucket: "0-30"),
                           .init(analyte: "ldl", value: 110, unit: "mg/dL", ageBucket: "180+")])
        #expect(p.profile == nil, "bad age band and unknown sex are dropped")
        let ok = window(20) { _, d in summary(d, profile: .init(ageBand: "35-39", sexForRanges: "F")) }
        #expect(try Anonymizer.payload(ok, policy: .init(), requestID: fixedID).profile == .init(ageBand: "35-39", sexForRanges: "F"))
    }

    @Test func refusesShortOrOddWindowsAndMixedProvenance() throws {
        #expect(throws: AnonymizerError.insufficientData(daysWithData: 13, required: 14)) {
            try Anonymizer.payload(window(13) { summary($1) }, policy: .init(), requestID: fixedID)
        }
        #expect(throws: AnonymizerError.windowNotAllowed(30)) {
            try Anonymizer.payload(window(30) { summary($1) }, policy: .init(windowDays: 30), requestID: fixedID)
        }
        #expect(throws: AnonymizerError.mixedProvenance) {
            try Anonymizer.payload(window(20) { summary($1, provenance: $0 == 3 ? .syntheticFixture : .device) }, policy: .init(), requestID: fixedID)
        }
        let old = window(40) { summary($1) }
        #expect(try Anonymizer.payload(old, policy: .init(), requestID: fixedID).daysWithData == 28, "days outside the window are ignored")
    }

    @Test func mealsOptOut() throws {
        let w = window(20) { summary($1, meals: [.init(tLocal: "12:10", label: "lunch", tags: [])]) }
        #expect(try Anonymizer.payload(w, policy: .init(includeMeals: false), requestID: fixedID).daily.allSatisfy { $0.meals.isEmpty })
        #expect(try Anonymizer.payload(w, policy: .init(), requestID: fixedID).daily[0].meals == [.init(tLocal: "12:00", label: "lunch", tags: [])])
    }

    /// Golden payload + demo response; the CI spec job validates both against the JSON Schemas in Python.
    @Test func goldenFixtures() throws {
        let p = try Anonymizer.payload(SyntheticWindow.make(days: 28, anchor: anchor, calendar: la, seed: 1),
                                       policy: AnonymizationPolicy(includeLabs: true), requestID: fixedID)
        let insights = DemoCloudAnalyzer.analyze(p)
        let payloadURL = repoRoot.appendingPathComponent("Fixtures/cloud/payload-28d.synthetic.json")
        let insightsURL = repoRoot.appendingPathComponent("Fixtures/cloud/insights-28d.synthetic.json")
        if ProcessInfo.processInfo.environment["HPL_WRITE_GOLDEN"] == "1" {
            let e = JSONEncoder()
            e.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
            try FileManager.default.createDirectory(at: payloadURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try e.encode(p).write(to: payloadURL)
            try e.encode(insights).write(to: insightsURL)
        }
        #expect(try JSONDecoder().decode(CloudPayloadV1.self, from: Data(contentsOf: payloadURL)) == p)
        #expect(try JSONDecoder().decode(CloudInsightsV1.self, from: Data(contentsOf: insightsURL)) == insights)
    }
}
