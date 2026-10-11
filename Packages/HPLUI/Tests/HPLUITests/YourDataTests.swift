import Foundation
import Testing
import HPLCore
import HPLStore
import HPLBridge
import HPLIngest
import HPLInference
import HPLCloud
@testable import HPLUI

private let noon = Date(timeIntervalSince1970: 1_791_720_000)

struct Scheduled: Equatable { var hour: Int; var minute: Int; var title: String; var body: String }

final class FakeScheduler: ReminderScheduler, @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [Scheduled] = []
    let allow: Bool
    init(allow: Bool = true) { self.allow = allow }
    var scheduled: [Scheduled] { lock.withLock { pending } }
    func requestAuthorization() async -> Bool { allow }
    func scheduleDaily(hour: Int, minute: Int, title: String, body: String) async throws {
        lock.withLock { pending.append(Scheduled(hour: hour, minute: minute, title: title, body: body)) }
    }
    func cancelAll() async { lock.withLock { pending = [] } }
    func pendingCount() async -> Int { lock.withLock { pending.count } }
}

@MainActor @Suite struct YourDataTests {
    @Test func deleteAllWipesEveryTargetAndVerifies() async throws {
        let consents = InMemoryConsentRepository()
        let secrets = InMemoryPairingSecretStore(["pair1": Array(1...32)])
        let files = InMemoryLabFileStore()
        try files.store(Data("%PDF".utf8), name: "report.pdf")
        let prefs = InMemoryPreferences()
        let scheduler = FakeScheduler()
        let records = InMemoryBridgeRecordStore()
        let db = ClosureWipeTarget(name: "Database", wipe: { try records.deleteAll() }, remaining: { try records.all(kind: "egress").count })
        try records.put(kind: "egress", key: "r1", at: noon, payload: Data("{}".utf8))
        let app = AppModel(consents: consents, reminders: scheduler, prefs: prefs,
                           wiper: DataWiper(targets: [db, files.wipeTarget, secrets.wipeTarget, prefs.wipeTarget, scheduler.wipeTarget]),
                           now: { noon })
        app.acknowledgeDisclaimer()
        await app.reminders.setEnabled(true)
        #expect(prefs.ownedKeys() == [ReminderModel.key] && scheduler.scheduled.count == 1)
        #expect(app.canDeleteAll)

        await app.deleteAll()
        let report = try #require(app.wipeReport)
        #expect(report.verified, "\(report.items)")
        #expect(try secrets.count() == 0)
        #expect(try files.count() == 0)
        #expect(prefs.ownedKeys().isEmpty && scheduler.scheduled.isEmpty)
        #expect(PrivacyCopy.wipeSummary(report).hasPrefix("All data deleted"))
        app.clearWipeReport()
        #expect(app.wipeReport == nil)
    }

    @Test func deleteAllUnavailableWithoutWiperOrInDegradedLaunch() async {
        #expect(!AppModel(consents: InMemoryConsentRepository()).canDeleteAll)
        let degraded = AppModel(consents: InMemoryConsentRepository(), wiper: DataWiper(targets: []), isDegraded: true)
        #expect(!degraded.canDeleteAll)
    }

    @Test func exportAllHasEverythingButSecrets() throws {
        let consents = InMemoryConsentRepository()
        try consents.save(Consent(scope: .glasses, version: "glasses-v1", grantedAt: noon))
        let meals = KeyedMealRepository.inMemory()
        try meals.save(MealLog(startedAt: noon, tz: "UTC", items: [MealItem(name: "Overnight oats", kcalEst: 350)], status: .confirmed,
                               source: .manual, updatedAt: noon))
        let insights = InMemoryInsightsRepository()
        let data = try AllDataExport.make(.init(consents: consents, aggregates: InMemoryHealthAggregateRepository(), labs: InMemoryLabRepository(),
                                                meals: meals, insights: insights, egress: nil), now: noon, calendar: .hplLocal()).encoded()
        let json = try #require(String(bytes: data, encoding: .utf8))
        #expect(json.contains("\"schema\" : \"hpl.export_all.v1\"") && json.contains("Overnight oats") && json.contains("glasses-v1"))
        #expect(!json.contains("\"k\"") && !json.lowercased().contains("secret"))
        let app = AppModel(consents: consents, now: { noon })
        #expect(try app.exportAllJSON().count > 100)
    }

    @Test func reminderIsOptInAndContentFree() async {
        let prefs = InMemoryPreferences()
        let denied = ReminderModel(scheduler: FakeScheduler(allow: false), prefs: prefs)
        await denied.setEnabled(true)
        #expect(!denied.settings.enabled && denied.notice == ReminderCopy.denied)

        let s = FakeScheduler()
        let m = ReminderModel(scheduler: s, prefs: prefs)
        #expect(!m.settings.enabled, "off by default")
        await m.setEnabled(true)
        await m.setTime(hour: 21, minute: 15)
        #expect(s.scheduled.count == 1 && s.scheduled[0].hour == 21 && s.scheduled[0].minute == 15)
        #expect(s.scheduled[0].body == ReminderCopy.body && !ReminderCopy.body.contains(where: \.isNumber))
        #expect(ReminderModel(scheduler: s, prefs: prefs).settings == ReminderSettings(enabled: true, hour: 21, minute: 15), "persists")
        await m.setEnabled(false)
        #expect(s.scheduled.isEmpty)
    }

    @Test func privacyAndReminderCopyPassTheBlocklistAndAvoidOverclaims() {
        let guardrail = OutputGuard()
        var texts = PrivacyCopy.points + [PrivacyCopy.exportExplainer, PrivacyCopy.deleteTitle, PrivacyCopy.deleteMessage, PrivacyCopy.deleteHealthAccess]
        texts += [ReminderCopy.title, ReminderCopy.body, ReminderCopy.denied, ReminderCopy.explainer]
        texts += ConsentScope.allCases.map(PrivacyCopy.scopeLabel)
        for t in texts {
            #expect(guardrail.blocklistHits(t).isEmpty, "\(t)")
            let lower = t.lowercased()
            for claim in ["anonymous", "hipaa", "fda", "clinically", "guarantee", "100%"] { #expect(!lower.contains(claim), "\(claim) in \(t)") }
        }
    }
}
