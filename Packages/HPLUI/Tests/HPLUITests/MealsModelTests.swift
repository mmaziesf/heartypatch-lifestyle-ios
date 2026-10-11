import Foundation
import Testing
import HPLCore
import HPLStore
import HPLBridge
import HPLInference
@testable import HPLUI

private let laCal = Calendar.hplLocal(TimeZone(identifier: "America/Los_Angeles")!)
private let day = LocalDay(string: "2026-10-10")!
private let noon = day.date(minutesFromMidnight: 720, calendar: laCal)
private let secret: [UInt8] = Array(1...32)
private let pairingID = "fixturepair00001"

private func glanceEvent(id: String, at: Date, name: String, kcal: Int) -> String {
    let f = ISO8601DateFormatter()
    return "{\"spec\":\"hpl.event.v1\",\"event_id\":\"\(id)\",\"type\":\"meal.logged\",\"occurred_at\":\"\(f.string(from: at))\"," +
        "\"tz\":\"America/Los_Angeles\",\"producer\":{\"name\":\"glance\",\"version\":\"0.1\",\"processing\":\"on_device\"}," +
        "\"payload\":{\"items\":[{\"name\":\"\(name)\",\"kcal_est\":\(kcal),\"protein_g\":30}]}}"
}

private func signed(_ bodies: [String], at: Date = noon) throws -> Data {
    let lines = try bodies.map { try SignedEvent.sign(body: $0, pairingID: pairingID, secret: secret, ts: Int64(at.timeIntervalSince1970)).line() }
    return Data(lines.joined(separator: "\n").utf8)
}

@MainActor @Suite struct MealsModelTests {
    let repo = KeyedMealRepository.inMemory()
    let secrets = InMemoryPairingSecretStore()
    let consents = InMemoryConsentRepository()

    func model() -> MealsModel {
        MealsModel(services: MealServices(repository: repo, secrets: secrets), consents: consents, calendar: laCal, now: { noon })
    }
    func pairFixture() throws {
        try PairingManager(repository: repo, secrets: secrets).pair(label: "Glance", payload: PairingPayload(id: pairingID, secret: secret))
    }

    @Test func importNeedsConsentThenLandsPendingAndConfirms() async throws {
        let m = model()
        try pairFixture()
        let file = try signed([glanceEvent(id: "01M4P7SAJGANKTHYVGBT9W1TXP", at: noon.addingTimeInterval(-1800), name: "salad", kcal: 470)])
        await m.importFile(file)
        #expect(m.notice == "Turn on glasses meals in Settings first." && m.pending.isEmpty)

        m.grantConsent()
        #expect(m.hasConsent)
        await m.importFile(file)
        #expect(m.notice == "1 new event imported.")
        #expect(m.pending.map { MealsCopy.title($0) } == ["salad"])
        #expect(MealsCopy.detail(m.pending[0]) == "about 470 kcal (estimate) · from glance, analyzed on your phone")
        #expect(m.lastEventText == "Last event 30 min ago from glance")

        await m.importFile(file)
        #expect(m.notice == "1 already imported.")

        var changed = 0
        m.onChange = { changed += 1 }
        await m.edit(m.pending[0].id, name: "caesar salad", kcal: 500)
        await m.confirm(m.pending[0].id)
        #expect(m.pending.isEmpty && changed == 2)
        #expect(m.timeline.first?.meals.map { MealsCopy.title($0) } == ["caesar salad"])
        #expect(m.timeline.first?.meals.first?.kcalTotal == 500)
    }

    @Test func rejectManualAddPauseAndPairing() async throws {
        let m = model()
        m.grantConsent()
        m.pair(label: "Glance")
        let p = try #require(m.newPairing)
        #expect(m.state.pairings.map(\.label) == ["Glance"] && PairingPayload(uri: p.uri) == p)
        #expect(try secrets.secret(for: p.id) == p.secret)
        #expect(m.state.pairings.first?.code == PairingCode.of(p.secret))
        #expect(m.codeText(for: m.state.pairings[0]) == PairingCode.display(PairingCode.of(p.secret)))
        m.finishPairing()
        #expect(m.newPairing == nil)

        let file = Data(try SignedEvent.sign(body: glanceEvent(id: "01M4P7SAJGANKTHYVGBT9W1TXQ", at: noon, name: "chips", kcal: 300),
                                             pairingID: p.id, secret: p.secret, ts: Int64(noon.timeIntervalSince1970)).line().utf8)
        m.setPaused(true)
        await m.importFile(file)
        #expect(m.notice == "The glasses bridge is paused. Nothing was imported." && m.pending.isEmpty)
        m.setPaused(false)
        await m.importFile(file)
        await m.reject(try #require(m.pending.first).id)
        #expect(m.pending.isEmpty && m.timeline.isEmpty)

        await m.addManual(name: "  oatmeal ", at: day.date(minutesFromMidnight: 450, calendar: laCal), tags: [.homeCooked])
        #expect(m.timeline.first?.meals.first?.status == .confirmed && m.timeline.first?.meals.first?.items.first?.name == "oatmeal")
        await m.addManual(name: "   ", at: noon)
        #expect(m.notice == "A meal needs a name.")

        m.revoke(p.id)
        #expect(try m.state.pairings.isEmpty && secrets.secret(for: p.id) == nil)
        await m.importFile(file)
        #expect(m.notice == "1 rejected (not from a paired companion).")
    }

    @Test func confirmedGlassesMealReachesTodaySummary() async throws {
        let src = StubHealthSource(steps: [day: 5000])
        let health = HealthServices(source: src, aggregates: InMemoryHealthAggregateRepository(), syncState: InMemorySyncStateRepository(), calendar: laCal)
        let app = AppModel(consents: consents, health: health, meals: MealServices(repository: repo, secrets: secrets), now: { noon })
        app.acknowledgeDisclaimer()
        await app.connectHealth()
        #expect(app.summary?.meals.isEmpty == true)

        app.meals.grantConsent()
        try pairFixture()
        app.meals.reload()
        let lunch = noon.addingTimeInterval(-45 * 60)
        await app.meals.importFile(try signed([glanceEvent(id: "01M4P7SAJGANKTHYVGBT9W1TXS", at: lunch, name: "ramen", kcal: 800)]))
        #expect(app.summary?.meals.isEmpty == true, "pending meals never reach the summary")
        await app.meals.confirm(try #require(app.meals.pending.first).id)
        #expect(app.summary?.meals == [.init(tLocal: "11:15", label: "lunch", tags: [])])
    }

    @Test func mealCopyHasNoMedicalLanguage() {
        let guardrail = OutputGuard()
        let rejections: [EventInbox.Rejection] = [.paused, .fileTooLarge, .malformedWrapper, .unknownPairing, .badSignature, .stale,
                                                  .fromFuture, .badEvent("x")]
        var texts = GlassesConsent.points + rejections.map(MealsCopy.reason)
        texts += [MealsCopy.processing(.onDevice), MealsCopy.processing(.cloud)].compactMap { $0 }
        texts += [MealsCopy.emptyCopy]
        for t in texts { #expect(guardrail.blocklistHits(t).isEmpty, "\(t)") }
    }
}
