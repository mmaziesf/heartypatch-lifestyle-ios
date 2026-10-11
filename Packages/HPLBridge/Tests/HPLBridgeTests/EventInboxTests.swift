import Foundation
import Testing
import HPLCore
import HPLStore
@testable import HPLBridge

let fixtures = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures")

/// Test-only pairing shared with scripts/hpl_event_sign.py (FIXTURE_PAIRING_ID / FIXTURE_SECRET).
enum FixturePairing {
    static let id = "fixturepair00001"
    static let secret: [UInt8] = Array(1...32)
    /// The `ts` the signed fixtures carry (2026-10-11 22:15:00Z).
    static let signedAt = Date(timeIntervalSince1970: 1_791_756_900)
}

func load(_ path: String) throws -> Data { try Data(contentsOf: fixtures.appendingPathComponent(path)) }

struct Harness {
    let repo = KeyedMealRepository.inMemory()
    let secrets = InMemoryPairingSecretStore()
    let inbox: EventInbox

    init(now: Date = FixturePairing.signedAt.addingTimeInterval(60), paired: Bool = true) throws {
        if paired {
            try PairingManager(repository: repo, secrets: secrets)
                .pair(label: "Glance", payload: PairingPayload(id: FixturePairing.id, secret: FixturePairing.secret))
        }
        inbox = EventInbox(repository: repo, secrets: secrets, now: { now })
    }

    func sign(_ events: [String], ts: Date = FixturePairing.signedAt) throws -> Data {
        let lines = try events.map {
            try SignedEvent.sign(body: $0, pairingID: FixturePairing.id, secret: FixturePairing.secret, ts: Int64(ts.timeIntervalSince1970)).line()
        }
        return Data(lines.joined(separator: "\n").utf8)
    }
}

@Suite struct EventInboxTests {
    @Test func glanceMealLoggedBecomesPendingMealAndDedupes() async throws {
        let h = try Harness()
        let file = try load("signed/01-glance-meal.synthetic.hplevent")
        let r = try await h.inbox.importFile(file)
        #expect(r.applied == 1 && r.rejected.isEmpty)
        let meals = try h.repo.meals()
        #expect(meals.count == 1)
        let m = try #require(meals.first)
        #expect(m.status == .pending && m.source == .glasses && m.producer == "glance" && m.processing == .onDevice)
        #expect(m.items.map(\.name) == ["chicken caesar salad"] && m.kcalTotal == 470 && m.items.first?.confidence == nil)
        #expect(m.endedAt == m.startedAt && !m.isOpen)
        let again = try await h.inbox.importFile(file)
        #expect(again.duplicates == 1 && again.applied == 0)
        #expect(try h.repo.meals().count == 1)
        let state = try h.repo.bridgeState()
        #expect(state.lastProducer == "glance" && state.lastEventAt == m.startedAt)
    }

    @Test func visionClawSessionAssemblesWithLifestyleVoiceAndUnknown() async throws {
        let h = try Harness()
        let r = try await h.inbox.importFile(try load("signed/02-visionclaw-session.synthetic.hplevent"))
        #expect(r.rejected.isEmpty && r.applied == 5 && r.ignored == 1)
        let m = try #require(try h.repo.meals().first)
        #expect(m.items.count == 2 && m.tags == ["home-cooked"] && m.sessionKey == "01JA00000000000000000000S1")
        #expect(m.endedAt != nil && m.status == .pending)
        #expect(try h.repo.lifestyle().map(\.kind) == [.caffeine])
        #expect(try h.repo.voiceNotes().first?.intent == .energy)
        #expect(try h.repo.receipt(eventID: "01JA0000000000000000000006")?.disposition == .ignoredUnknownType)
    }

    @Test func rejectsTamperedUnknownPairingAndUnsigned() async throws {
        let h = try Harness()
        func reasons(_ path: String) async throws -> [EventInbox.Rejection] { try await h.inbox.importFile(try load(path)).rejected }
        #expect(try await reasons("invalid/signed-tampered-body.hplevent") == [.badSignature])
        #expect(try await reasons("invalid/signed-unknown-pairing.hplevent") == [.unknownPairing])
        #expect(try await reasons("invalid/signed-unsigned-raw-event.hplevent") == [.malformedWrapper])
        #expect(try h.repo.meals().isEmpty)
    }

    @Test func enforcesSignatureAgeAndFutureSkew() async throws {
        let file = try load("signed/01-glance-meal.synthetic.hplevent")
        let stale = try Harness(now: FixturePairing.signedAt.addingTimeInterval(8 * 24 * 3600))
        #expect(try await stale.inbox.importFile(file).rejected == [.stale])
        let early = try Harness(now: FixturePairing.signedAt.addingTimeInterval(-10 * 60))
        #expect(try await early.inbox.importFile(file).rejected == [.fromFuture])
        let withinSkew = try Harness(now: FixturePairing.signedAt.addingTimeInterval(-60))
        #expect(try await withinSkew.inbox.importFile(file).applied == 1)
    }

    @Test func pausedImportsNothing() async throws {
        let h = try Harness()
        var s = try h.repo.bridgeState(); s.paused = true; try h.repo.save(s)
        let r = try await h.inbox.importFile(try load("signed/01-glance-meal.synthetic.hplevent"))
        #expect(r.rejected == [.paused])
        #expect(try h.repo.meals().isEmpty && h.repo.receipt(eventID: "01M4P7SAJGANKTHYVGBT9W1TXP") == nil)
    }

    @Test func pairingCodeMatchesGlanceAndFallsBackToKeychain() throws {
        let h = try Harness()
        let info = try #require(try h.repo.bridgeState().pairings.first)
        #expect(info.code == "ae216c2e")
        let legacy = PairingInfo(id: FixturePairing.id, label: "old", createdAt: Date())
        #expect(PairingManager(repository: h.repo, secrets: h.secrets).code(for: legacy) == "ae216c2e")
    }

    @Test func revokedPairingIsRejected() async throws {
        let h = try Harness()
        try PairingManager(repository: h.repo, secrets: h.secrets).revoke(id: FixturePairing.id)
        #expect(try await h.inbox.importFile(try load("signed/01-glance-meal.synthetic.hplevent")).rejected == [.unknownPairing])
    }

    @Test func sizeLimits() async throws {
        let h = try Harness()
        #expect(try await h.inbox.importFile(Data(count: 1_048_577)).rejected == [.fileTooLarge])
        #expect(try await h.inbox.importFile(Data(String(repeating: "x\n", count: 1_001).utf8)).rejected == [.tooManyLines])
        #expect(try await h.inbox.importFile(Data()).outcomes.isEmpty)
    }
}
