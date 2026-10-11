import SwiftUI
import HPLCore
import HPLCore
import HPLStore
import HPLHealth
import HPLIngest
import HPLInference
import HPLPipeline
import HPLBridge
import HPLCloud
import HPLUI

@main
struct HeartyPatchLifestyleApp: App {
    @State private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let m = AppBootstrap.makeModel()
        _model = State(initialValue: m)
        // HealthKit observer queries must be registered at launch so background-delivery wakes are handled (§9.4).
        Task { await m.startBackgroundObservers() }
    }

    var body: some Scene {
        WindowGroup {
            RootView(model: model, onReset: { resetAfterWipe() })
                // §10: hide health numbers from the app-switcher snapshot.
                .overlay { if scenePhase != .active { PrivacyShieldView() } }
                // A shared / opened .hplevent file from a paired glasses companion (transport A, docs/m5-glasses.md).
                .onOpenURL { url in
                    guard url.isFileURL else { return }
                    Task { await model.meals.importFile(at: url) }
                }
        }
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active else { return }
                if model.isDegraded {
                    // Launched in the background while locked: the protected store wasn't readable. Reopen now.
                    let m = AppBootstrap.makeModel()
                    model = m
                    Task { await m.startBackgroundObservers() }
                } else {
                    Task { await model.refresh() }
                }
            }
    }
}

extension HeartyPatchLifestyleApp {
    /// After "Delete all": fresh model on the empty store → disclaimer onboarding again.
    @MainActor func resetAfterWipe() {
        let m = AppBootstrap.makeModel()
        model = m
    }
}

@MainActor
enum AppBootstrap {
    /// One store per process: after "Delete all" the model is rebuilt on the same (now empty) container.
    private static var store: SwiftDataStore?

    static func makeModel() -> AppModel {
        let legacy = UserDefaultsConsentRepository()
        let prefs = UserDefaultsPreferences()
        let reminders = UserNotificationReminderScheduler()
        do {
            let store = try Self.store ?? SwiftDataStore.persistent()
            Self.store = store
            try? store.migrateConsents(from: legacy)
            let health = HealthServices(source: HealthKitDataSource(), aggregates: store.aggregates, syncState: store.syncState)
            let files = try ProtectedLabFileStore()
            let secrets = KeychainPairingSecretStore()
            let importer = LabImporter(repository: store.labs, files: files, extractor: OnDeviceLabExtractor())
            // §10 "Delete all": DB (incl. HealthKit anchors), report files, Keychain, preferences + legacy consents, reminders,
            // and files iOS copied in via "Open in" / share. There is no model cache yet (no downloaded models).
            let wiper = DataWiper(targets: [
                store.wipeTarget, files.wipeTarget, secrets.wipeTarget, prefs.wipeTarget, reminders.wipeTarget,
                DirectoryWipeTarget(name: "Imported files inbox", directory: URL.documentsDirectory.appending(path: "Inbox")),
                DirectoryWipeTarget(name: "Temporary files", directory: FileManager.default.temporaryDirectory),
            ])
            return AppModel(consents: store.consents, health: health, labs: LabServices(importer: importer, repository: store.labs),
                            insights: store.insights, meals: MealServices(repository: store.meals, secrets: secrets),
                            // M6: the demo analyzer runs on this iPhone; no endpoint is configured, so nothing leaves the device.
                            cloud: CloudServices(transport: DemoCloudTransport(), log: RecordStoreEgressLog(store: store.records)),
                            reminders: reminders, prefs: prefs, wiper: wiper,
                            pipeline: DailyPipeline(engine: InsightEngines.preferred()))
        } catch {
            // Data Protection: the store is unreadable until first unlock. No HealthKit work this launch (§10 DECISION: defer).
            return AppModel(consents: legacy, health: nil, pipeline: DailyPipeline(engine: InsightEngines.preferred()), isDegraded: true)
        }
    }
}
