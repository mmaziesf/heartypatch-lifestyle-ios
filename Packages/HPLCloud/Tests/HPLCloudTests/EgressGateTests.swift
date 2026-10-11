import Foundation
import Testing
import HPLCore
import HPLStore
@testable import HPLCloud

@Suite struct EgressGateTests {
    let w = SyntheticWindow.make(days: 28, anchor: anchor, calendar: la, seed: 3)

    @Test func unreachableWithoutConsent() async throws {
        let t = RecordingTransport()
        let gate = EgressGate(consents: InMemoryConsentRepository(), transport: t)
        #expect(throws: EgressGate.EgressError.consentMissing) { try gate.prepare(w, policy: .init()) }
        let job = try EgressGate(consents: try consented(), transport: t).prepare(w, policy: .init())
        await #expect(throws: EgressGate.EgressError.consentMissing) { try await gate.send(job, approvedSHA256: job.sha256) }
        #expect(t.received.isEmpty)
    }

    @Test func previewEqualsSentBytesAndResultsMapBack() async throws {
        let t = RecordingTransport()
        let log = RecordStoreEgressLog(store: InMemoryBridgeRecordStore())
        let gate = EgressGate(consents: try consented(), transport: t, log: log, now: { Date(timeIntervalSince1970: 1_791_700_000) })
        let job = try gate.prepare(w, policy: .init())
        #expect(job.preview.json == job.bodyText && job.preview.sha256 == job.sha256 && job.preview.bytes == job.body.count)
        let result = try await gate.send(job, approvedSHA256: job.preview.sha256)
        #expect(t.received == [job.body], "preview == sent, byte for byte")
        #expect(SHA256Digest.hex(t.received[0]) == job.sha256)
        #expect(result.blocked == 0 && result.recommendations.count >= 3)
        #expect(result.recommendations.allSatisfy { $0.generator.engine == .cloud && $0.guardResult == .pass && $0.provenance == .syntheticFixture })
        let daily = try #require(result.recommendations.flatMap(\.evidence).first { $0.fieldPath.hasPrefix("daily.") })
        #expect(LocalDay(string: daily.summaryDay) != nil, "relative day mapped back to a calendar date, locally")
        let records = try log.all()
        #expect(records.count == 1 && records[0].outcome == .sent && records[0].payloadJSON == job.bodyText)
        #expect(records.first?.accepted == result.recommendations.count)
    }

    @Test func revokingConsentBlocksTheNextSend() async throws {
        let consents = try consented()
        let t = RecordingTransport()
        let gate = EgressGate(consents: consents, transport: t)
        let job = try gate.prepare(w, policy: .init())
        var c = try #require(try consents.active(.cloudAnalysis, version: CloudConsent.version))
        c.revokedAt = Date()
        try consents.save(c)
        await #expect(throws: EgressGate.EgressError.consentMissing) { try await gate.send(job, approvedSHA256: job.sha256) }
        #expect(t.received.isEmpty)
    }

    @Test func hashMismatchOrTamperingAborts() async throws {
        let t = RecordingTransport()
        let gate = EgressGate(consents: try consented(), transport: t)
        let job = try gate.prepare(w, policy: .init())
        await #expect(throws: EgressGate.EgressError.hashMismatch) { try await gate.send(job, approvedSHA256: String(repeating: "0", count: 64)) }
        var tampered = job
        tampered.body = Data(job.bodyText.replacingOccurrences(of: "\"Sat\"", with: "\"Sun\"").utf8)
        await #expect(throws: EgressGate.EgressError.hashMismatch) { try await gate.send(tampered, approvedSHA256: job.sha256) }
        #expect(t.received.isEmpty)
    }

    @Test func responseGuardDropsUnsafeOrUntraceableInsights() async throws {
        let t = RecordingTransport { body in
            let p = try JSONDecoder().decode(CloudPayloadV1.self, from: body)
            let ok = "weeks.0.metrics.steps.median"
            return try JSONEncoder().encode(CloudInsightsV1(requestID: p.requestID, insights: [
                .init(kind: "observation", title: "Steps", body: "Your steps look steady.", evidence: [ok]),
                .init(kind: "observation", title: "Sleep", body: "This suggests sleep apnea; see a doctor.", evidence: [ok]),
                .init(kind: "observation", title: "Steps", body: "You walked 123457 steps.", evidence: [ok]),
                .init(kind: "observation", title: "X", body: "Unsupported evidence.", evidence: ["profile.name"]),
                .init(kind: "clinician_prompt", title: "X", body: "Fixed copy only on device.", evidence: [ok]),
            ]))
        }
        let gate = EgressGate(consents: try consented(), transport: t)
        let job = try gate.prepare(w, policy: .init())
        let r = try await gate.send(job, approvedSHA256: job.sha256)
        #expect(r.recommendations.map(\.body) == ["Your steps look steady."] && r.blocked == 4)
    }

    @Test func badResponsesAndTransportFailuresAreLogged() async throws {
        let log = RecordStoreEgressLog(store: InMemoryBridgeRecordStore())
        let wrongID = RecordingTransport { _ in try JSONEncoder().encode(CloudInsightsV1(requestID: UUID().uuidString.lowercased(), insights: [])) }
        let gate1 = EgressGate(consents: try consented(), transport: wrongID, log: log)
        let job1 = try gate1.prepare(w, policy: .init())
        await #expect(throws: EgressGate.EgressError.badResponse(.wrongRequestID)) { try await gate1.send(job1, approvedSHA256: job1.sha256) }
        let garbage = EgressGate(consents: try consented(), transport: RecordingTransport { _ in Data("<html>".utf8) }, log: log)
        let job2 = try garbage.prepare(w, policy: .init())
        await #expect(throws: EgressGate.EgressError.badResponse(.notJSON)) { try await garbage.send(job2, approvedSHA256: job2.sha256) }
        let down = EgressGate(consents: try consented(), transport: RecordingTransport { _ in throw Boom() }, log: log)
        let job3 = try down.prepare(w, policy: .init())
        await #expect(throws: EgressGate.EgressError.transportFailed) { try await down.send(job3, approvedSHA256: job3.sha256) }
        #expect(try log.all().map(\.outcome) == [.failed, .failed, .failed])
    }

    @Test func demoAnalyzerAlwaysPassesTheGuard() async throws {
        let gate = EgressGate(consents: try consented(), transport: DemoCloudTransport())
        #expect(!gate.transportLeavesDevice)
        for seed in 1...50 {
            let job = try gate.prepare(SyntheticWindow.make(days: seed % 2 == 0 ? 56 : 28, anchor: anchor, calendar: la, seed: UInt64(seed)),
                                       policy: .init(windowDays: seed % 2 == 0 ? 56 : 28, includeLabs: true))
            let r = try await gate.send(job, approvedSHA256: job.sha256)
            #expect(r.blocked == 0 && !r.recommendations.isEmpty, "seed \(seed)")
        }
    }

    @Test func previewIsHumanReadableAndDateFree() throws {
        let job = try EgressGate(consents: try consented(), transport: DemoCloudTransport()).prepare(w, policy: .init(includeLabs: true))
        let titles = job.preview.sections.map(\.title)
        #expect(titles.first == "Request" && titles.contains("Daily rows (28)") && titles.contains("Lab values (2)") && titles.last == "Never included")
        #expect(job.preview.sections.flatMap(\.lines).allSatisfy { !$0.contains("2026") })
        #expect(job.preview.sections[0].lines.contains("Data: synthetic example, not yours."))
    }

    #if canImport(Security)
    @Test func httpsTransportRequiresTLSAndPinsAndSendsNoIdentity() throws {
        #expect(HTTPSCloudTransport(endpoint: URL(string: "http://example.com/a")!, publicKeyPins: ["x"]) == nil)
        #expect(HTTPSCloudTransport(endpoint: URL(string: "https://example.com/a")!, publicKeyPins: []) == nil)
        let t = try #require(HTTPSCloudTransport(endpoint: URL(string: "https://example.com/a")!, publicKeyPins: ["x"]))
        #expect(t.leavesDevice && t.id == "https:example.com")
        let r = HTTPSCloudTransport.request(endpoint: URL(string: "https://example.com/a")!, body: Data("{}".utf8), requestID: "abc")
        #expect(r.httpMethod == "POST" && r.httpBody == Data("{}".utf8) && !r.httpShouldHandleCookies)
        #expect(Set(r.allHTTPHeaderFields?.keys.map { $0 } ?? []) == ["Content-Type", "Accept", "X-HPL-Request-ID"])
    }
    #endif
}
