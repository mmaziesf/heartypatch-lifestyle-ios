import Foundation
import Testing
@testable import HPLCore

/// Repo root, resolved from this file so tests read the same Fixtures/ the Python validator checks.
let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

func fixtures(_ dir: String) throws -> [URL] {
    try FileManager.default.contentsOfDirectory(at: repoRoot.appendingPathComponent("Fixtures/\(dir)"), includingPropertiesForKeys: nil)
        .filter { $0.lastPathComponent.hasSuffix(".synthetic.json") }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
}

/// fixture -> typed -> JSON must equal fixture (null == absent), and typed -> JSON -> typed must be identity.
func assertRoundTrip<T: Codable & Equatable>(_ type: T.Type, _ data: Data, _ label: String) throws {
    let original = try HPLJSON.decoder.decode(JSONValue.self, from: data)
    let typed = try HPLJSON.decoder.decode(T.self, from: data)
    let encoded = try HPLJSON.encoder.encode(typed)
    let reencoded = try HPLJSON.decoder.decode(JSONValue.self, from: encoded)
    #expect(original.strippingNulls == reencoded.strippingNulls, "JSON drift in \(label)")
    #expect(try HPLJSON.decoder.decode(T.self, from: encoded) == typed, "typed drift in \(label)")
}

@Suite struct DailySummaryRoundTrip {
    @Test func fixturesRoundTrip() throws {
        let files = try fixtures("daily_summary")
        #expect(files.count >= 2)
        for f in files { try assertRoundTrip(DailySummaryV1.self, Data(contentsOf: f), f.lastPathComponent) }
    }

    @Test func embeddedFixtureMatchesRepoFixture() throws {
        let file = try JSONValue.decodeData(Data(contentsOf: repoRoot.appendingPathComponent("Fixtures/daily_summary/d0.synthetic.json")))
        let embedded = try JSONValue.decodeData(Data(SyntheticFixtures.dailySummaryD0JSON.utf8))
        #expect(file == embedded)
        #expect(try SyntheticFixtures.dailySummaryD0().provenance == .syntheticFixture)
    }

    @Test func rejectsWrongSchemaID() {
        let bad = SyntheticFixtures.dailySummaryD0JSON.replacingOccurrences(of: "hpl.daily_summary.v1", with: "hpl.daily_summary.v2")
        #expect(throws: DecodingError.self) { try HPLJSON.decoder.decode(DailySummaryV1.self, from: Data(bad.utf8)) }
    }

    @Test func pathLookup() throws {
        let tree = try SyntheticFixtures.dailySummaryD0().jsonTree()
        #expect(tree.value(at: "sleep.baseline_28d.total_min_median") == .number(431))
        #expect(tree.value(at: "meals.1.t_local") == .string("21:45"))
        #expect(tree.value(at: "meals.9.t_local") == nil)
        #expect(tree.value(at: "nope") == nil)
    }
}

@Suite struct EventRoundTrip {
    @Test func fixturesRoundTrip() throws {
        let files = try fixtures("events")
        #expect(files.count >= 6)
        for f in files { try assertRoundTrip(HPLEventV1.self, Data(contentsOf: f), f.lastPathComponent) }
    }

    @Test func typedPayloads() throws {
        let events = try fixtures("events").map { try HPLJSON.decoder.decode(HPLEventV1.self, from: Data(contentsOf: $0)) }
        #expect(try events[0].typedPayload() == .mealStart(.init(trigger: .voice)))
        guard case .mealItems(let items)? = try events[1].typedPayload() else { Issue.record("meal.items"); return }
        #expect(items.items.map(\.name) == ["grilled salmon", "white rice"])
        #expect(try events[2].typedPayload() == .mealEnd)
        #expect(events[5].type == .unknown("future.thing"))
        #expect(try events[5].typedPayload() == nil)
    }

    @Test func eventTypeRawValues() {
        for raw in ["meal.start", "meal.items", "meal.photo", "meal.end", "voice.note", "lifestyle.event", "ping", "x.y"] {
            #expect(HPLEventV1.EventType(rawValue: raw).rawValue == raw)
        }
    }
}

@Suite struct NumberScanning {
    @Test func scansIntegersDecimalsAndTimes() {
        #expect(NumberScanner.numbers(in: "slept 352 min vs 431; HbA1c 5.6%. At 21:45.") == [352, 431, 5.6, 21, 45])
    }
}

extension JSONValue {
    static func decodeData(_ d: Data) throws -> JSONValue { try HPLJSON.decoder.decode(JSONValue.self, from: d) }
}
