import Foundation
import Testing
import HPLCore
import HPLStore
import HPLInference
@testable import HPLPipeline

private let la = Calendar.hplLocal(TimeZone(identifier: "America/Los_Angeles")!)
private let day0 = LocalDay(string: "2026-10-10")!
private func at(_ d: LocalDay, hour: Int = 9) -> Date { d.date(minutesFromMidnight: hour * 60, calendar: la) }

private func rec(_ title: String, _ paths: [String], kind: RecommendationKind = .observation, experiment: ExperimentProposal? = nil,
                 day: LocalDay = day0) -> Recommendation {
    Recommendation(day: day.description, kind: kind, title: title, body: "b",
                   evidence: paths.map { EvidenceRef(summaryDay: day.description, fieldPath: $0, value: .number(1)) },
                   experiment: experiment, generator: Generator(engine: .rules, promptVersion: "rules-v1"), guardResult: .pass,
                   provenance: .device)
}

private let sleepExp = ExperimentProposal(intervention: "Wind down earlier", durationDays: 14, metricFieldPath: "sleep.total_min")

private struct FakeMetrics: ExperimentMetricSource {
    var value: @Sendable (LocalDay) -> Double?
    func values(metric fieldPath: String, days: [LocalDay]) throws -> [LocalDay: Double] {
        Dictionary(uniqueKeysWithValues: days.compactMap { d in value(d).map { (d, $0) } })
    }
}

@Suite struct NoteLedgerTests {
    let repo = InMemoryInsightsRepository()
    var ledger: NoteLedger { NoteLedger(repository: repo, calendar: la) }

    @Test func topicIgnoresArrayIndices() {
        #expect(InsightTopic.key(["meals.1.t_local", "meals.1.tags"]) == "meals.t_local")
        #expect(InsightTopic.key([]) == "none")
    }

    @Test func rerunsKeepIdsAndStatusAndDropStaleNotes() throws {
        let first = try ledger.record([rec("Sleep", ["sleep.total_min"]), rec("Steps", ["activity.steps"])], day: day0, now: at(day0))
        try ledger.setStatus(first[1].id, .accepted, now: at(day0))
        let second = try ledger.record([rec("Sleep v2", ["sleep.total_min"]), rec("Steps v2", ["activity.steps"])], day: day0, now: at(day0, hour: 12))
        #expect(second.map(\.id) == first.map(\.id))
        #expect(second[0].recommendation.title == "Sleep v2", "untouched notes take the newer text")
        #expect(second[1].recommendation.title == "Steps" && second[1].status == .accepted, "acted-on notes are kept as the user saw them")
        // Next run no longer produces "sleep": the untouched note goes, the accepted one stays.
        let third = try ledger.record([rec("HRV", ["heart.hrv_sdnn_ms_overnight_median"])], day: day0, now: at(day0, hour: 15))
        #expect(third.map(\.recommendation.title) == ["HRV", "Steps"])
        #expect(try repo.notes().count == 2)
    }

    @Test func dismissedAndSnoozedAreHiddenFromToday() throws {
        let notes = try ledger.record([rec("A", ["sleep.total_min"]), rec("B", ["activity.steps"])], day: day0, now: at(day0))
        try ledger.setStatus(notes[0].id, .dismissed, now: at(day0))
        try ledger.setStatus(notes[1].id, .snoozed, now: at(day0))
        #expect(try ledger.visible(on: day0).isEmpty)
        #expect(try ledger.history().count == 2)
    }

    @Test func dismissedTopicsAreDeprioritizedForSevenDays() throws {
        let n = try ledger.record([rec("A", ["sleep.total_min"])], day: day0, now: at(day0))
        try ledger.setStatus(n[0].id, .dismissed, now: at(day0))
        #expect(try ledger.context(today: day0.adding(days: 7, calendar: la)).deprioritizedTopics == ["sleep.total_min"])
        #expect(try ledger.context(today: day0.adding(days: 8, calendar: la)).deprioritizedTopics.isEmpty)
    }

    @Test func snoozeHidesTheTopicUntilTomorrow() throws {
        let n = try ledger.record([rec("A", ["activity.steps"])], day: day0, now: at(day0))
        let snoozed = try ledger.setStatus(n[0].id, .snoozed, now: at(day0))
        #expect(snoozed.snoozedUntil == day0.adding(days: 1, calendar: la))
        #expect(try ledger.context(today: day0).suppressedTopics == ["activity.steps"])
        #expect(try ledger.context(today: day0.adding(days: 1, calendar: la)).suppressedTopics.isEmpty)
    }

    @Test func clinicianDismissalsDontDeprioritize() throws {
        let n = try ledger.record([rec("Flag", ["labs_recent.0.analyte"], kind: .clinicianPrompt)], day: day0, now: at(day0))
        try ledger.setStatus(n[0].id, .dismissed, now: at(day0))
        #expect(try ledger.context(today: day0).deprioritizedTopics.isEmpty)
    }

    @Test func feedbackIsStoredAndExportIsValidJSON() throws {
        let n = try ledger.record([rec("A", ["sleep.total_min"])], day: day0, now: at(day0))
        try ledger.setFeedback(n[0].id, .helpful)
        let data = try ledger.export(now: at(day0))
        let decoded = try HPLJSON.decoder.decode(InsightsExportV1.self, from: data)
        #expect(decoded.schema == InsightsExportV1.schemaID)
        #expect(decoded.notes.first?.feedback == .helpful)
        #expect(decoded.disclaimer == Disclaimer.footer)
        #expect(throws: InsightsError.notFound) { try ledger.setFeedback(UUID(), nil) }
    }
}

@Suite struct PipelineContextTests {
    @Test func dismissedTopicMovesBehindOthersAndSnoozedDisappears() async throws {
        let d0 = try SyntheticFixtures.dailySummaryD0()
        let plain = try await DailyPipeline().run(d0)
        #expect(plain.first?.topic == "sleep.total_min")

        let later = try await DailyPipeline().run(d0, context: .init(deprioritizedTopics: ["sleep.total_min"]))
        #expect(later.first?.topic != "sleep.total_min")
        #expect(later.count == 3)

        let snoozed = try await DailyPipeline().run(d0, context: .init(suppressedTopics: ["sleep.total_min", "heart.hrv_sdnn_ms_overnight_median"]))
        #expect(!snoozed.map(\.topic).contains("sleep.total_min") && !snoozed.map(\.topic).contains("heart.hrv_sdnn_ms_overnight_median"))
    }

    @Test func clinicianPromptIgnoresContext() async throws {
        let s = EvalFixtures.make(3).summary
        let recs = try await DailyPipeline().run(s, context: .init(deprioritizedTopics: ["labs_recent.analyte"], suppressedTopics: ["labs_recent.analyte"]))
        #expect(recs.first?.kind == .clinicianPrompt)
    }
}

@Suite struct ExperimentTrackerTests {
    let repo = InMemoryInsightsRepository()

    func tracker(_ metrics: (any ExperimentMetricSource)? = nil) -> ExperimentTracker {
        ExperimentTracker(repository: repo, metrics: metrics, calendar: la)
    }

    func experimentNote(days: Int = 14) throws -> StoredNote {
        let proposal = ExperimentProposal(intervention: "Wind down earlier", durationDays: days, metricFieldPath: "sleep.total_min")
        return try NoteLedger(repository: repo, calendar: la)
            .record([rec("Short sleep", ["sleep.total_min"], kind: .experiment, experiment: proposal)], day: day0, now: at(day0))[0]
    }

    @Test func startFromNoteMarksItAcceptedAndOnlyOneRuns() throws {
        let note = try experimentNote()
        let e = try tracker().start(from: note, on: day0, now: at(day0))
        #expect(e.status == .active && e.interventionDays == 14 && e.baselineDays == 14 && e.noteID == note.id)
        let stored = try #require(try repo.notes().first)
        #expect(stored.status == .accepted && stored.experimentID == e.id)
        #expect(throws: InsightsError.experimentAlreadyActive) { try tracker().start(from: note, on: day0, now: at(day0)) }
        let plain = try NoteLedger(repository: repo, calendar: la).record([rec("x", ["activity.steps"])], day: day0, now: at(day0))
        #expect(throws: InsightsError.notAnExperiment) { try tracker().start(from: plain[0], on: day0, now: at(day0)) }
        // The running experiment's topic isn't suggested again.
        #expect(try NoteLedger(repository: repo, calendar: la).context(today: day0).suppressedTopics.contains("sleep.total_min"))
    }

    @Test func dailyProgressAndCheckIns() throws {
        let e = try tracker().start(from: try experimentNote(days: 7), on: day0, now: at(day0))
        let d3 = day0.adding(days: 2, calendar: la)
        try tracker().checkIn(e.id, day: day0, did: true)
        try tracker().checkIn(e.id, day: d3, did: false)
        let updated = try #require(try tracker().active())
        let p = tracker().progress(updated, today: d3)
        #expect(p == .init(day: 3, of: 7, checkInsYes: 1, checkInsTotal: 2, today: false))
        #expect(try tracker().summaryEntry(today: d3) == .init(id: "E1", intervention: "Wind down earlier", day: 3, of: 7))
    }

    @Test func completesAfterLastDayWithBaselineVsInterventionResult() throws {
        // Baseline days hover around 400; experiment days around 440 (more than the usual spread).
        let metrics = FakeMetrics { d in d < day0 ? 400 + Double(d.day % 3) * 5 : 440 }
        let e = try tracker(metrics).start(from: try experimentNote(), on: day0, now: at(day0))
        let last = e.lastDay(calendar: la)
        #expect(last == day0.adding(days: 13, calendar: la))
        #expect(try tracker(metrics).finishDue(today: last, now: at(last)).isEmpty, "the last day itself still counts")

        let done = try #require(try tracker(metrics).finishDue(today: last.adding(days: 1, calendar: la), now: at(last)).first)
        let r = try #require(done.result)
        #expect(done.status == .completed && done.endedOn == last)
        #expect(r.enoughData && r.baselineDaysWithData == 14 && r.interventionDaysWithData == 14)
        #expect(r.interventionMean == 440)
        #expect(r.summary.hasPrefix("Total sleep: average 405 min over 14 days before vs 440 min over 14 days during."))
        #expect(r.summary.contains("larger than your usual day-to-day variation"))
        #expect(try repo.notes().first?.status == .done)
    }

    @Test func smallDifferenceIsCalledWithinUsualVariation() {
        let r = ExperimentResultCopy.make(metric: "activity.steps", baseline: [8000, 9000, 10000, 8500, 9500], during: [9100, 8900, 9200, 9000],
                                          baselineDays: 7, duringDays: 7, checkInsYes: 5, checkInsTotal: 6, needed: 4)
        #expect(r.enoughData)
        #expect(r.summary.contains("within your usual day-to-day variation"))
        #expect(r.summary.contains("You checked in as doing it on 5 of 6 days."))
    }

    @Test func missingDataSaysSoAndStopEndsEarly() throws {
        let metrics = FakeMetrics { d in d < day0 && d.day % 2 == 0 ? 400 : nil }
        let e = try tracker(metrics).start(from: try experimentNote(), on: day0, now: at(day0))
        let stopped = try tracker(metrics).stop(e.id, on: day0.adding(days: 3, calendar: la), now: at(day0))
        #expect(stopped.status == .stopped)
        #expect(stopped.result?.enoughData == false)
        #expect(stopped.result?.summary.hasPrefix("Not enough days with total sleep data to compare") == true)
        #expect(throws: InsightsError.experimentNotActive) { try tracker(metrics).checkIn(e.id, day: day0, did: true) }
    }

    /// Experiment copy is generated text the user reads: it must pass the same blocklist as notes.
    @Test func resultCopyHasNoMedicalLanguage() {
        let guardrail = OutputGuard()
        let texts = [
            ExperimentResultCopy.make(metric: "sleep.total_min", baseline: [1, 2, 3, 4], during: [9, 9, 9, 9], baselineDays: 7, duringDays: 7,
                                      checkInsYes: 1, checkInsTotal: 2, needed: 4).summary,
            ExperimentResultCopy.make(metric: "heart.resting_hr", baseline: [], during: [], baselineDays: 14, duringDays: 3,
                                      checkInsYes: 0, checkInsTotal: 0, needed: 7).summary,
        ]
        for t in texts { #expect(guardrail.blocklistHits(t).isEmpty, "\(t)") }
    }
}

/// M4 exit criterion end to end: a 14-day experiment from a note, daily progress, and a baseline-vs-intervention result
/// computed from real stored aggregates through the same DailySummary path the note cited.
@Suite struct ExperimentEndToEndTests {
    @Test func fourteenDayExperimentOverStoredAggregates() async throws {
        let start = day0
        var rows: [HealthAggregate] = []
        for i in -45...13 {
            let d = start.adding(days: i, calendar: la)
            let sleep: Double = i < 0 ? 400 + Double((i + 100) % 3) * 4 : 430 + Double(i % 2) * 4
            rows.append(HealthAggregate(day: d, metric: .sleepAsleep, window: .night, qualifier: nil, stats: AggregateStats(sum: sleep),
                                        tz: "America/Los_Angeles", computedAt: Date(timeIntervalSince1970: 0)))
        }
        let aggregates = InMemoryHealthAggregateRepository(rows)
        let metrics = SummaryMetricSource(builder: SummaryBuilder(aggregates: aggregates, calendar: la))
        let repo = InMemoryInsightsRepository()
        let ledger = NoteLedger(repository: repo, calendar: la)

        let summary = try #require(try SummaryBuilder(aggregates: aggregates, calendar: la).build(day: start))
        let recs = try await DailyPipeline().run(summary, context: try ledger.context(today: start))
        let notes = try ledger.record(recs, day: start, now: at(start))
        // This stored history isn't short-sleep shaped, so use an experiment note for the same metric.
        var note = notes.first { $0.recommendation.experiment != nil }
        if note == nil {
            note = try ledger.record([rec("Short sleep", ["sleep.total_min"], kind: .experiment, experiment: sleepExp)], day: start, now: at(start))
                .first { $0.recommendation.experiment != nil }
        }

        let tracker = ExperimentTracker(repository: repo, metrics: metrics, calendar: la)
        let e = try tracker.start(from: try #require(note), on: start, now: at(start))
        for i in 0..<14 {
            let d = start.adding(days: i, calendar: la)
            try tracker.checkIn(e.id, day: d, did: i % 4 != 3)
            let p = tracker.progress(try #require(try tracker.active()), today: d)
            #expect(p.day == i + 1 && p.of == 14)
        }
        let done = try #require(try tracker.finishDue(today: start.adding(days: 14, calendar: la), now: at(start)).first)
        let r = try #require(done.result)
        #expect(r.enoughData && r.baselineDaysWithData == 14 && r.interventionDaysWithData == 14)
        #expect(r.checkInsYes == 11 && r.checkInsTotal == 14)
        #expect((r.baselineMean ?? 0) < 410 && (r.interventionMean ?? 0) > 429)
    }
}
