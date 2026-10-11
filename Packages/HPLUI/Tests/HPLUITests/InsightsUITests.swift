import Foundation
import Testing
import HPLCore
import HPLStore
import HPLInference
import HPLPipeline
@testable import HPLUI

private let la = Calendar.hplLocal(TimeZone(identifier: "America/Los_Angeles")!)
private let noon = LocalDay(string: "2026-10-10")!.date(minutesFromMidnight: 720, calendar: la)

@MainActor @Suite struct InsightsUITests {
    func experimentRec() -> Recommendation {
        Recommendation(day: "2026-10-10", kind: .experiment, title: "Short sleep", body: "b",
                       evidence: [EvidenceRef(summaryDay: "2026-10-10", fieldPath: "sleep.total_min", value: .number(352))],
                       experiment: .init(intervention: "Wind down earlier", durationDays: 7, metricFieldPath: "sleep.total_min"),
                       generator: Generator(engine: .rules, promptVersion: "rules-v1"), guardResult: .pass, provenance: .device)
    }

    @Test func noteActionsUpdateTodayAndHistory() {
        let repo = InMemoryInsightsRepository()
        let m = InsightsModel(repository: repo, metrics: nil, calendar: la, now: { noon })
        m.begin(example: false)
        m.record([experimentRec()])
        #expect(m.today.count == 1 && m.isPersistent)
        let note = m.today[0]
        #expect(m.canStartExperiment(note))

        m.startExperiment(from: note)
        #expect(m.activeExperiment?.interventionDays == 7)
        #expect(m.today.first?.status == .accepted)
        #expect(!m.canStartExperiment(m.today[0]))
        m.checkIn(m.activeExperiment!, did: true)
        #expect(m.progress(m.activeExperiment!).today == true)

        m.dismiss(m.today[0])
        #expect(m.today.isEmpty)
        m.filter = .dismissed
        #expect(m.filteredHistory.count == 1)
        #expect(m.historyByDay.first?.day == LocalDay(string: "2026-10-10"))
        let export = try? HPLJSON.decoder.decode(InsightsExportV1.self, from: m.exportJSON())
        #expect(export?.experiments.count == 1 && export?.notes.count == 1)
    }

    @Test func exampleModeNeverWritesToRealHistory() throws {
        let repo = InMemoryInsightsRepository()
        let m = InsightsModel(repository: repo, metrics: nil, calendar: la, now: { noon })
        m.begin(example: true)
        m.record([experimentRec()])
        m.startExperiment(from: m.today[0])
        #expect(m.isExample && !m.isPersistent)
        #expect(m.activeExperiment != nil)
        #expect(try repo.notes().isEmpty && repo.experiments().isEmpty)
    }

    @Test func appModelRecordsFixtureNotesAsExamples() async throws {
        let repo = InMemoryInsightsRepository()
        let model = AppModel(consents: InMemoryConsentRepository(), insights: repo, now: { noon })
        await model.loadToday()
        #expect(model.todaySource == .syntheticFixture)
        #expect(model.insights.isExample)
        #expect(model.insights.today.map(\.recommendation.title) == model.recommendations.map(\.title))
        #expect(try repo.notes().isEmpty)
    }

    @Test func userFacingCopyHasNoMedicalLanguage() {
        let guardrail = OutputGuard()
        let rec = experimentRec()
        var texts = RecommendationKind.allCases.map(NoteCopy.kindLabel) + NoteStatus.allCases.compactMap(NoteCopy.statusBadge)
        texts += [NoteCopy.proposal(rec.experiment!), NoteCopy.guardExplanation(rec)]
        texts += [Generator.Engine.rules, .fm, .mlx, .cloud].map { NoteCopy.engine(Generator(engine: $0, promptVersion: "x")) }
        for t in texts { #expect(guardrail.blocklistHits(t).isEmpty, "\(t)") }
        #expect(FieldLabels.label(for: "meals.1.t_local").name == "Meal time")
        #expect(FieldLabels.label(for: "heart.hrv_28d_p10").unit == "ms")
    }
}
