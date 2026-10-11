import Foundation
import Testing
@testable import HPLCore

@Suite struct CryptoAndMealTests {
    @Test func sha256KnownVectors() {
        #expect(SHA256Digest.hex(Data("abc".utf8)) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        #expect(SHA256Digest.hex(Data()) == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

    /// RFC 4231 test cases 1, 2 and 6 (key longer than the block size).
    @Test func hmacRFC4231() {
        #expect(HMACSHA256.hex(key: Array(repeating: 0x0b, count: 20), message: Data("Hi There".utf8))
                == "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7")
        #expect(HMACSHA256.hex(key: Array("Jefe".utf8), message: Data("what do ya want for nothing?".utf8))
                == "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843")
        #expect(HMACSHA256.hex(key: Array(repeating: 0xaa, count: 131),
                               message: Data("Test Using Larger Than Block-Size Key - Hash Key First".utf8))
                == "60e431591ee0b67f0d8a26aacbf5b77f8e0bc6213728c5140546040f0ee37f54")
    }

    @Test func constantTimeEqualAndBase64URL() {
        #expect(HMACSHA256.equal("ABCD", "abcd") && !HMACSHA256.equal("abcd", "abce") && !HMACSHA256.equal("ab", "abc"))
        let bytes: [UInt8] = [0xfb, 0xff, 0x00, 0x3e]
        #expect(Base64URL.encode(bytes) == "-_8APg")
        #expect(Base64URL.decode("-_8APg") == bytes)
    }

    @Test func mealTagsAreControlledVocabulary() {
        #expect(MealTag.filter(["late", "yummy", "late", "high-protein"]) == ["late", "high-protein"])
        let m = MealLog(startedAt: Date(), tz: "UTC", tags: ["free text"], status: .pending, source: .manual, updatedAt: Date())
        #expect(m.tags.isEmpty)
    }

    @Test func mealLoggedEventDecodes() throws {
        let json = """
        {"spec":"hpl.event.v1","event_id":"01M4P7SAJGANKTHYVGBT9W1TXP","type":"meal.logged","occurred_at":"2026-10-11T19:42:10Z",
         "tz":"America/Los_Angeles","producer":{"name":"glance","version":"0.1","processing":"on_device"},
         "payload":{"items":[{"name":"salad","kcal_est":470}]}}
        """
        let e = try HPLJSON.decoder.decode(HPLEventV1.self, from: Data(json.utf8))
        #expect(e.type == .mealLogged && e.producer.processing == .onDevice && e.sessionID == nil)
        guard case .mealLogged(let p) = try e.typedPayload() else { Issue.record("payload"); return }
        #expect(p.items == [MealItem(name: "salad", kcalEst: 470)])
    }
}

@Suite struct PairingCodeTests {
    /// Same value Glance shows for the fixture pairing (rayban-vlm-poc docs/HPL_BRIDGE.md) and hpl_event_sign.py prints.
    @Test func matchesGlanceFingerprint() {
        #expect(PairingCode.of(Array(1...32)) == "ae216c2e")
        #expect(PairingCode.display("ae216c2e") == "ae21 6c2e")
    }
}
