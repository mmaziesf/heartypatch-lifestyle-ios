import SwiftUI
import HPLStore
import HPLHealth
import HPLIngest
import HPLInference
import HPLPipeline
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
        WindowGroup { RootView(model: model) }
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

@MainActor
enum AppBootstrap {
    static func makeModel() -> AppModel {
        let legacy = UserDefaultsConsentRepository()
        do {
            let store = try SwiftDataStore.persistent()
            try? store.migrateConsents(from: legacy)
            let health = HealthServices(source: HealthKitDataSource(), aggregates: store.aggregates, syncState: store.syncState)
            let importer = LabImporter(repository: store.labs, files: try ProtectedLabFileStore(), extractor: OnDeviceLabExtractor())
            return AppModel(consents: store.consents, health: health, labs: LabServices(importer: importer, repository: store.labs),
                            insights: store.insights, pipeline: DailyPipeline(engine: InsightEngines.preferred()))
        } catch {
            // Data Protection: the store is unreadable until first unlock. No HealthKit work this launch (§10 DECISION: defer).
            return AppModel(consents: legacy, health: nil, pipeline: DailyPipeline(engine: InsightEngines.preferred()), isDegraded: true)
        }
    }
}
