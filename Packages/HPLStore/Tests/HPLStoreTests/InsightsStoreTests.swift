import Foundation
import Testing
import HPLCore
@testable import HPLStore

private func note(_ title: String, day: String, createdAt: TimeInterval) -> StoredNote {
    let rec = Recommendation(day: day, kind: .experiment, title: title, body: "b",
                             evidence: [EvidenceRef(summaryDay: day, fieldPath: "sleep.total_min", value: .number(352))],
                             experiment: .init(intervention: "Wind down earlier", durationDays: 14, metricFieldPath: "sleep.total_min"),
                             generator: Generator(engine: .rules, promptVersion: "rules-v1"), guardResult: .pass, provenance: .device)
    return StoredNote(recommendation: rec, day: LocalDay(string: day)!, createdAt: Date(timeIntervalSince1970: createdAt))
}

func checkInsightsContract(_ repo: any InsightsRepository) throws {
    let a = note("A", day: "2026-10-09", createdAt: 1), b = note("B", day: "2026-10-10", createdAt: 2)
    try repo.upsert([a, b])
    #expect(try repo.notes().map(\.recommendation.title) == ["B", "A"], "newest day first")
    #expect(try repo.notes(on: LocalDay(string: "2026-10-09")!).map(\.id) == [a.id])

    var changed = b
    changed.status = .dismissed
    changed.feedback = .notHelpful
    try repo.upsert([changed])
    #expect(try repo.notes().first == changed)
    #expect(try repo.notes().count == 2)

    try repo.deleteNotes(ids: [a.id])
    #expect(try repo.notes().map(\.id) == [b.id])

    var e = Experiment(noteID: b.id, title: "B", intervention: "Wind down earlier", metricFieldPath: "sleep.total_min", days: 14,
                       startDay: LocalDay(string: "2026-10-10")!, provenance: .device)
    try repo.save(e)
    e.checkIns["2026-10-10"] = true
    e.status = .completed
    e.result = ExperimentResult(baselineMean: 405, baselineDaysWithData: 14, baselineSD: 4, interventionMean: 440,
                                interventionDaysWithData: 14, checkInsYes: 1, checkInsTotal: 1, enoughData: true, summary: "s")
    try repo.save(e)
    #expect(try repo.experiments() == [e])

    try repo.deleteAll()
    #expect(try repo.notes().isEmpty && repo.experiments().isEmpty)
}

@Suite struct InsightsStoreTests {
    @Test func inMemoryContract() throws { try checkInsightsContract(InMemoryInsightsRepository()) }

    #if canImport(SwiftData)
    @Test func swiftDataContract() throws { try checkInsightsContract(try SwiftDataStore.inMemory().insights) }

    /// M4 exit criterion: history persists across launches.
    @Test func historySurvivesReopeningTheStore() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hpl-insights-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let n = note("Persisted", day: "2026-10-10", createdAt: 5)
        do {
            let store = try SwiftDataStore.persistent(directory: dir)
            try store.insights.upsert([n])
        }
        let reopened = try SwiftDataStore.persistent(directory: dir)
        #expect(try reopened.insights.notes() == [n])
    }
    #endif
}
