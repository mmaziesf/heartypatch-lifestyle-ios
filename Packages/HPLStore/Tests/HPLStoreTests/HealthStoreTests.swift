import Foundation
import Testing
import HPLCore
@testable import HPLStore

private func agg(_ day: String, _ m: HealthMetric, _ sum: Double) -> HealthAggregate {
    HealthAggregate(day: LocalDay(string: day)!, metric: m, window: .day, stats: AggregateStats(sum: sum),
                    sourceBundleIDs: ["com.apple.health"], tz: "America/Los_Angeles", computedAt: Date(timeIntervalSince1970: 1_791_000_000))
}

/// Shared contract every HealthAggregateRepository must satisfy.
func checkAggregateContract(_ repo: any HealthAggregateRepository) throws {
    try repo.replace(days: [LocalDay(string: "2026-10-09")!, LocalDay(string: "2026-10-10")!],
                     with: [agg("2026-10-09", .steps, 9000), agg("2026-10-10", .steps, 4000), agg("2026-10-10", .activeEnergy, 300)])
    #expect(try repo.aggregates(on: LocalDay(string: "2026-10-10")!).count == 2)

    // Recompute of one day replaces it wholesale; other days untouched.
    try repo.replace(days: [LocalDay(string: "2026-10-10")!], with: [agg("2026-10-10", .steps, 4500)])
    let all = try repo.aggregates(from: LocalDay(string: "2026-10-01")!, through: LocalDay(string: "2026-10-31")!)
    #expect(all.map(\.stats.sum) == [9000, 4500])
    #expect(all.last == agg("2026-10-10", .steps, 4500), "round-trips every field")

    try repo.deleteAll()
    #expect(try repo.aggregates(from: LocalDay(string: "2026-01-01")!, through: LocalDay(string: "2026-12-31")!).isEmpty)
}

func checkSyncStateContract(_ state: any SyncStateRepository) throws {
    #expect(try state.anchor(for: "a") == nil)
    try state.setAnchor(Data([1, 2]), for: "a")
    try state.setDate(Date(timeIntervalSince1970: 5), for: "d")
    #expect(try state.anchor(for: "a") == Data([1, 2]))
    #expect(try state.date(for: "d") == Date(timeIntervalSince1970: 5))
    try state.reset()
    #expect(try state.anchor(for: "a") == nil)
}

@Suite struct InMemoryHealthStoreTests {
    @Test func aggregateContract() throws { try checkAggregateContract(InMemoryHealthAggregateRepository()) }
    @Test func syncStateContract() throws { try checkSyncStateContract(InMemorySyncStateRepository()) }
}

#if canImport(SwiftData)
@Suite struct SwiftDataStoreTests {
    @Test func aggregateContract() throws { try checkAggregateContract(try SwiftDataStore.inMemory().aggregates) }
    @Test func syncStateContract() throws { try checkSyncStateContract(try SwiftDataStore.inMemory().syncState) }

    @Test func consentsMigrateFromUserDefaultsOnce() throws {
        let suite = "hpl.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let legacy = UserDefaultsConsentRepository(defaults: defaults)
        let ack = Consent(scope: .disclaimer, version: Disclaimer.version, grantedAt: Date(timeIntervalSince1970: 1_791_000_000))
        try legacy.save(ack)

        let store = try SwiftDataStore.inMemory()
        try store.migrateConsents(from: legacy)
        try store.migrateConsents(from: legacy)
        #expect(try store.consents.all() == [ack])
        #expect(try legacy.all().isEmpty)
    }

    @Test func persistentStoreReopensWithData() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hpl-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try SwiftDataStore.persistent(directory: dir).aggregates.replace(days: [LocalDay(string: "2026-10-10")!], with: [agg("2026-10-10", .steps, 1)])
        #expect(try SwiftDataStore.persistent(directory: dir).aggregates.aggregates(on: LocalDay(string: "2026-10-10")!).count == 1)
    }
}
#endif
