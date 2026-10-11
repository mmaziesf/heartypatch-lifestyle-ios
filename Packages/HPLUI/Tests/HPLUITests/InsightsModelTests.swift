import Foundation
import Testing
import HPLCore
import HPLStore
import HPLInference
import HPLPipeline
@testable import HPLUI

@MainActor @Suite struct InsightsModelTests {
    @Test func engineStatusShowsFallbackReason() async {
        let offline = ScriptedInsightEngine(availability: .unavailable(reason: "Apple Intelligence is turned off")) { _, _ in "" }
        let model = AppModel(consents: InMemoryConsentRepository(), pipeline: DailyPipeline(engine: offline))
        await model.refreshEngineStatus()
        #expect(model.engineStatus == "Rules only: Apple Intelligence is turned off")

        let rules = AppModel(consents: InMemoryConsentRepository())
        await rules.refreshEngineStatus()
        #expect(rules.engineStatus == "Rules only")
    }

    @Test func debugEvalScoresTheLiveEngine() async {
        let model = AppModel(consents: InMemoryConsentRepository())
        await model.runInsightEval()
        let report = model.evalReport
        #expect(report?.fixtures == EvalFixtures.count)
        #expect(report?.meetsM3Gate == true)
        #expect(!model.isRunningEval)
    }
}
