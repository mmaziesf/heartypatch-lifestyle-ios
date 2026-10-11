import Foundation
import Testing
import HPLCore
import HPLStore
import HPLInference
import HPLCloud
@testable import HPLUI

private let laCal = Calendar.hplLocal(TimeZone(identifier: "America/Los_Angeles")!)
private let noon = LocalDay(string: "2026-10-11")!.date(minutesFromMidnight: 720, calendar: laCal)
private let canary = "Grandma Okafor's lasagna at 12 Elm St"

/// The user's own window (provenance `device`) with identifying strings planted wherever the summary allows strings.
private func deviceWindow(days: Int) -> CloudWindow {
    var w = SyntheticWindow.make(days: days, anchor: LocalDay(string: "2026-10-10")!, calendar: laCal, seed: 11)
    w.summaries = w.summaries.map { s in
        var s = s
        s.provenance = .device
        s.meals.append(.init(tLocal: "12:07", label: canary, tags: ["late", canary]))
        s.workouts.append(.init(type: canary, durationMin: 33))
        s.labsRecent.append(.init(analyte: canary, value: 1, unit: "mg/dL", refLow: nil, refHigh: nil, reportFlag: canary, ageDays: 3))
        s.profile = .init(ageBand: canary, sexForRanges: canary)
        return s
    }
    return w
}

@MainActor @Suite struct CloudModelTests {
    let consents = InMemoryConsentRepository()
    let log = RecordStoreEgressLog(store: InMemoryBridgeRecordStore())

    func model(source: CloudServices.WindowSource? = nil) -> CloudModel {
        CloudModel(services: CloudServices(transport: DemoCloudTransport(), log: log), consents: consents, windowSource: source,
                   calendar: laCal, now: { noon })
    }

    @Test func offByDefaultAndUnreachableWithoutOptIn() async {
        let app = AppModel(consents: consents, now: { noon })
        #expect(!app.cloud.hasConsent)
        await app.cloud.prepare()
        #expect(app.cloud.phase == .failed(CloudCopy.error(EgressGate.EgressError.consentMissing)))
        #expect(app.cloud.history.isEmpty)
    }

    @Test func exampleModeWhenHealthNotConnectedIsLabeled() async throws {
        let m = model()
        m.grantConsent()
        await m.prepare()
        guard case .preview(let job) = m.phase else { Issue.record("expected preview, got \(m.phase)"); return }
        #expect(m.usingExample && job.payload.provenance == .syntheticFixture)
        #expect(job.preview.sections.first?.lines.contains("Data: synthetic example, not yours.") == true)
        #expect(job.payload.labs.isEmpty, "labs are off unless ticked")
    }

    @Test func previewThenSendLogsExactBytes() async throws {
        let m = model(source: { deviceWindow(days: $0) })
        m.grantConsent()
        m.policy.includeLabs = true
        await m.prepare()
        guard case .preview(let job) = m.phase else { Issue.record("expected preview, got \(m.phase)"); return }
        #expect(!m.usingExample && job.payload.provenance == .device)
        #expect(!job.bodyText.contains("Grandma") && !job.bodyText.contains("Elm") && !job.bodyText.contains("2026-"),
                "canary meal / workout / lab / profile strings and calendar dates never reach the payload")
        #expect(job.payload.profile == nil)
        await m.send()
        guard case .done(let result) = m.phase else { Issue.record("expected done, got \(m.phase)"); return }
        #expect(!result.recommendations.isEmpty && result.record.payloadJSON == job.preview.json)
        #expect(m.history.count == 1 && m.history[0].sha256 == job.sha256 && m.history[0].leftDevice == false)
    }

    @Test func revokingConsentBlocksTheNextJob() async {
        let m = model()
        m.grantConsent()
        await m.prepare()
        guard case .preview(let job) = m.phase else { Issue.record("expected preview"); return }
        m.revokeConsent()
        #expect(!m.hasConsent && m.phase == .idle)
        await m.prepare()
        #expect(m.phase == .failed(CloudCopy.error(EgressGate.EgressError.consentMissing)))
        // Even a stale prepared job can't be pushed through the gate.
        let gate = EgressGate(consents: consents, transport: DemoCloudTransport())
        await #expect(throws: EgressGate.EgressError.consentMissing) { try await gate.send(job, approvedSHA256: job.sha256) }
        #expect(m.history.isEmpty)
    }

    @Test func tooLittleDeviceDataIsRefusedNotPadded() async {
        let m = model(source: { _ in deviceWindow(days: 10) })
        m.grantConsent()
        await m.prepare()
        #expect(m.phase == .failed(CloudCopy.error(EgressGate.EgressError.anonymizer(.insufficientData(daysWithData: 10, required: 14)))))
    }

    @Test func cloudCopyPassesTheBlocklist() throws {
        let guardrail = OutputGuard()
        var texts = CloudConsent.points + [CloudCopy.exampleNote, CloudCopy.previewNote, CloudCopy.resultsNote]
        texts += [CloudCopy.transport(id: "demo-on-device", leavesDevice: false), CloudCopy.transport(id: "x", leavesDevice: true)]
        let errors: [EgressGate.EgressError] = [.consentMissing, .anonymizer(.mixedProvenance), .auditFailed([]), .hashMismatch, .transportFailed,
                                                .badResponse(.notJSON), .anonymizer(.windowNotAllowed(7))]
        texts += errors.map(CloudCopy.error)
        let insights = DemoCloudAnalyzer.analyze(try Anonymizer.payload(deviceWindow(days: 28), policy: .init(), requestID: UUID())).insights
        texts += insights.flatMap { [$0.title, $0.body] }
        for t in texts { #expect(guardrail.blocklistHits(t).isEmpty, "\(t)") }
    }
}
