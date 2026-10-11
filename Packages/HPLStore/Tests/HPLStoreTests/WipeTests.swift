#if canImport(SwiftData)
import Foundation
import Testing
import HPLCore
@testable import HPLStore

/// M7 exit criterion: "Delete all" leaves no rows of any kind, and the result survives reopening the store.
@Suite struct WipeTests {
    @Test func eraseAllLeavesNoRowsOfAnyType() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hpl-wipe-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let t = Date(timeIntervalSince1970: 1_791_750_000)
        do {
            let store = try SwiftDataStore.persistent(directory: dir)
            try store.consents.save(Consent(scope: .disclaimer, version: "v1", grantedAt: t))
            try store.aggregates.replace(days: [LocalDay(string: "2026-10-10")!], with: [
                HealthAggregate(day: LocalDay(string: "2026-10-10")!, metric: .steps, window: .day, stats: AggregateStats(sum: 9000),
                                sourceBundleIDs: [], tz: "UTC", computedAt: t),
            ])
            try store.syncState.setAnchor(Data([1, 2, 3]), for: "steps")
            try store.meals.save(MealLog(startedAt: t, tz: "UTC", status: .confirmed, source: .manual, updatedAt: t))
            try store.records.put(kind: "egress", key: "r1", at: t, payload: Data("{}".utf8))
            try store.insights.save(Experiment(noteID: nil, title: "Earlier wind-down", intervention: "Lights out by 22:30",
                                               metricFieldPath: "sleep.total_min", days: 7, startDay: LocalDay(string: "2026-10-01")!,
                                               provenance: .device))
            #expect(try store.recordCount() >= 6)
            let report = await DataWiper(targets: [store.wipeTarget]).wipeAll()
            #expect(report.verified)
            #expect(try store.syncState.anchor(for: "steps") == nil, "HealthKit anchors reset → next launch backfills from scratch")
        }
        #expect(try SwiftDataStore.persistent(directory: dir).recordCount() == 0)
    }
}
#endif
