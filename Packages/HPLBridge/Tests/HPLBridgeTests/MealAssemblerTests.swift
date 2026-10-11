import Foundation
import Testing
import HPLCore
import HPLStore
@testable import HPLBridge

private func event(_ id: String, _ type: String, _ at: String, session: String? = "01JA00000000000000000000S9", _ payload: String = "{}") -> String {
    let s = session.map { ",\"session_id\":\"\($0)\"" } ?? ""
    return "{\"spec\":\"hpl.event.v1\",\"event_id\":\"\(id)\",\"type\":\"\(type)\",\"occurred_at\":\"\(at)\",\"tz\":\"America/Los_Angeles\"," +
        "\"producer\":{\"name\":\"visionclaw\",\"version\":\"t\",\"processing\":\"cloud\"}\(s),\"payload\":\(payload)}"
}

@Suite struct MealAssemblerTests {
    @Test func outOfOrderSessionInOneFileAssembles() async throws {
        let h = try Harness()
        let file = try h.sign([
            event("01JA00000000000000000000E3", "meal.end", "2026-10-11T20:30:00Z"),
            event("01JA00000000000000000000E2", "meal.items", "2026-10-11T20:10:00Z",
                  "{\"items\":[{\"name\":\"soup\",\"confidence\":0.5}],\"tags\":[\"restaurant\",\"bogus\"]}"),
            event("01JA00000000000000000000E1", "meal.start", "2026-10-11T20:00:00Z", "{\"trigger\":\"vision\"}"),
        ])
        #expect(try await h.inbox.importFile(file).applied == 3)
        let meals = try h.repo.meals()
        #expect(meals.count == 1)
        let m = try #require(meals.first)
        #expect(m.items.map(\.name) == ["soup"] && m.tags == ["restaurant"] && m.processing == .cloud)
        #expect(m.startedAt == iso("2026-10-11T20:00:00Z") && m.endedAt == iso("2026-10-11T20:30:00Z"))
    }

    @Test func photosAreDroppedNeverStored() async throws {
        let h = try Harness()
        let sha = String(repeating: "a", count: 64)
        let file = try h.sign([
            event("01JA00000000000000000000F1", "meal.start", "2026-10-11T20:00:00Z", "{\"trigger\":\"voice\"}"),
            event("01JA00000000000000000000F2", "meal.photo", "2026-10-11T20:01:00Z",
                  "{\"photo_ref\":\"p1\",\"sha256\":\"\(sha)\",\"width\":10,\"height\":10}"),
        ])
        let r = try await h.inbox.importFile(file)
        #expect(r.photosDropped == 1)
        #expect(try h.repo.meals().first?.photosDropped == 1)
        #expect(try h.repo.bridgeState().photosAllowed == false)
    }

    @Test func sessionEventWithoutSessionIDIsRejected() async throws {
        let h = try Harness()
        let body = event("01JA00000000000000000000G1", "meal.items", "2026-10-11T20:00:00Z", session: nil, "{\"items\":[{\"name\":\"x\"}]}")
        let file = try h.sign([body])
        #expect(try await h.inbox.importFile(file).rejected == [.badEvent("missing session_id")])
    }

    @Test func openSessionsAutoCloseAfter90Minutes() throws {
        let repo = KeyedMealRepository.inMemory()
        let start = Date(timeIntervalSince1970: 1_791_750_000)
        try repo.save(MealLog(sessionKey: "s", startedAt: start, tz: "America/Los_Angeles", status: .pending, source: .glasses, updatedAt: start))
        let a = MealAssembler(repository: repo)
        #expect(try a.closeStale(now: start.addingTimeInterval(60 * 60)) == 0)
        #expect(try a.closeStale(now: start.addingTimeInterval(91 * 60)) == 1)
        #expect(try repo.meals().first?.endedAt == start.addingTimeInterval(90 * 60))
    }

    @Test func newItemsOnConfirmedMealNeedReconfirmation() async throws {
        let h = try Harness()
        let s = "01JA00000000000000000000H0"
        let first = event("01JA00000000000000000000H1", "meal.items", "2026-10-11T20:00:00Z", session: s, "{\"items\":[{\"name\":\"a\"}]}")
        _ = try await h.inbox.importFile(try h.sign([first]))
        var m = try #require(try h.repo.meals().first)
        m.status = .confirmed
        try h.repo.save(m)
        let second = event("01JA00000000000000000000H2", "meal.items", "2026-10-11T20:05:00Z", session: s, "{\"items\":[{\"name\":\"b\"}]}")
        _ = try await h.inbox.importFile(try h.sign([second]))
        let after = try #require(try h.repo.meals().first)
        #expect(after.items.map(\.name) == ["a", "b"] && after.status == .pending)
    }
}

@Suite struct SigningTests {
    @Test func swiftSignatureMatchesPythonReferenceFixtures() throws {
        let text = String(bytes: try load("signed/02-visionclaw-session.synthetic.hplevent"), encoding: .utf8) ?? ""
        let lines = text.split(separator: "\n")
        #expect(lines.count == 6)
        for line in lines {
            let w = try JSONDecoder().decode(SignedEvent.self, from: Data(line.utf8))
            #expect(w.verifies(secret: FixturePairing.secret))
            #expect(!w.verifies(secret: Array(repeating: 0, count: 32)))
            let resigned = SignedEvent.sign(body: w.body, pairingID: w.pairingID, secret: FixturePairing.secret, ts: w.ts)
            #expect(resigned.sig == w.sig)
        }
    }

    @Test func pairingURIRoundTripsAndRejectsJunk() {
        let p = PairingPayload.generate()
        #expect(PairingPayload.isValidID(p.id) && p.secret.count == 32)
        #expect(PairingPayload(uri: p.uri) == p)
        #expect(p != PairingPayload.generate())
        #expect(PairingPayload(uri: "hplpair://v1?id=short&k=AQID") == nil)
        #expect(PairingPayload(uri: "https://v1?id=fixturepair00001&k=" + Base64URL.encode(Array(1...32))) == nil)
        #expect(PairingPayload(uri: "hplpair://v1?id=fixturepair00001&k=" + Base64URL.encode(Array(1...31))) == nil)
        #expect(PairingPayload(uri: "hplpair://v1?id=fixturepair00001&k=" + Base64URL.encode(Array(1...32)))?.secret == Array(1...32))
    }
}

func iso(_ s: String) -> Date? { ISO8601DateFormatter().date(from: s) }
