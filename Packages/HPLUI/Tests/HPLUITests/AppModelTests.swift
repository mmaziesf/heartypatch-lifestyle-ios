import Foundation
import Testing
import HPLCore
import HPLStore
@testable import HPLUI

@MainActor @Suite struct AppModelTests {
    @Test func disclaimerGateThenFixtureRecommendationOnToday() async {
        let repo = InMemoryConsentRepository()
        let model = AppModel(consents: repo, now: { Date(timeIntervalSince1970: 1_791_000_000) })
        #expect(model.needsDisclaimer)

        model.acknowledgeDisclaimer()
        #expect(!model.needsDisclaimer)
        #expect(AppModel(consents: repo).needsDisclaimer == false, "acknowledgement persists for the next launch")

        await model.loadToday()
        #expect(model.summary?.provenance == .syntheticFixture)
        #expect(model.recommendations.first?.title == "Shorter sleep than your recent typical")
        #expect(model.errorMessage == nil)
    }
}
