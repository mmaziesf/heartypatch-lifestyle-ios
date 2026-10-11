import SwiftUI
import HPLStore
import HPLUI

@main
struct HeartyPatchLifestyleApp: App {
    @State private var model = AppModel(consents: UserDefaultsConsentRepository())

    var body: some Scene {
        WindowGroup { RootView(model: model) }
    }
}
