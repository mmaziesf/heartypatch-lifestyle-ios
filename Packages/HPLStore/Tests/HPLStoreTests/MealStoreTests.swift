import Foundation
import Testing
import HPLCore
@testable import HPLStore

func checkMealContract(_ repo: any MealRepository) throws {
    let t = Date(timeIntervalSince1970: 1_791_750_000)
    let a = MealLog(sessionKey: "s1", startedAt: t, tz: "America/Los_Angeles", items: [MealItem(name: "soup")], status: .pending,
                    source: .glasses, producer: "glance", processing: .onDevice, updatedAt: t)
    var b = MealLog(startedAt: t.addingTimeInterval(3600), tz: "UTC", status: .confirmed, source: .manual, updatedAt: t)
    try repo.save(a)
    try repo.save(b)
    #expect(try repo.meals() == [b, a], "newest first")
    b.status = .rejected
    try repo.save(b)
    #expect(try repo.meals().count == 2 && repo.meals().first?.status == .rejected, "save is an upsert")
    try repo.deleteMeal(id: b.id)
    #expect(try repo.meals() == [a])

    try repo.save(LifestyleLog(id: "e1", occurredAt: t, tz: "UTC", kind: .alcohol, amount: 1, unit: "glass"))
    try repo.save(VoiceNoteLog(id: "e2", occurredAt: t, text: "tired", intent: .energy))
    #expect(try repo.lifestyle().map(\.id) == ["e1"] && repo.voiceNotes().map(\.text) == ["tired"])

    #expect(try repo.receipt(eventID: "E") == nil)
    let r = EventReceipt(eventID: "E", type: "meal.logged", occurredAt: t, receivedAt: t, pairingID: "p", producer: "glance", disposition: .applied)
    try repo.save(r)
    #expect(try repo.receipt(eventID: "E") == r)

    #expect(try repo.bridgeState() == BridgeState(), "defaults: not paused, photos off, no pairings")
    let s = BridgeState(paused: true, pairings: [PairingInfo(id: "fixturepair00001", label: "Glance", createdAt: t)], lastEventAt: t, lastProducer: "glance")
    try repo.save(s)
    #expect(try repo.bridgeState() == s)

    try repo.deleteAll()
    #expect(try repo.meals().isEmpty && repo.receipt(eventID: "E") == nil && repo.bridgeState() == BridgeState())
}

@Suite struct MealStoreTests {
    @Test func inMemoryContract() throws { try checkMealContract(KeyedMealRepository.inMemory()) }

    #if canImport(SwiftData)
    @Test func swiftDataContract() throws { try checkMealContract(try SwiftDataStore.inMemory().meals) }

    /// Idempotency must survive relaunch: receipts and meals persist on disk.
    @Test func receiptsAndMealsSurviveReopeningTheStore() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hpl-meals-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let t = Date(timeIntervalSince1970: 1_791_750_000)
        let meal = MealLog(startedAt: t, tz: "UTC", status: .confirmed, source: .manual, updatedAt: t)
        do {
            let store = try SwiftDataStore.persistent(directory: dir)
            try store.meals.save(meal)
            try store.meals.save(EventReceipt(eventID: "E", type: "ping", occurredAt: t, receivedAt: t, pairingID: "p", producer: "x",
                                              disposition: .ignoredPing))
        }
        let reopened = try SwiftDataStore.persistent(directory: dir)
        #expect(try reopened.meals.meals() == [meal])
        #expect(try reopened.meals.receipt(eventID: "E")?.disposition == .ignoredPing)
    }
    #endif
}
