import Foundation
import Observation
import HPLCore
import HPLStore
import HPLPipeline

/// Notes history, note actions, and experiments for Today and the Insights tab. Platform-neutral (tested on Linux).
/// Synthetic-fixture days use a throwaway in-memory store: example actions work but never reach real history.
@MainActor @Observable
public final class InsightsModel {
    public enum Filter: String, CaseIterable, Identifiable, Sendable {
        case all = "All", accepted = "Accepted", dismissed = "Dismissed", snoozed = "Snoozed"
        public var id: String { rawValue }
    }

    public private(set) var today: [StoredNote] = []
    public private(set) var history: [StoredNote] = []
    public private(set) var experiments: [Experiment] = []
    public private(set) var isExample = false
    public private(set) var notice: String?
    public var filter: Filter = .all

    private let persistent: (any InsightsRepository)?
    private let metrics: (any ExperimentMetricSource)?
    private var example: any InsightsRepository = InMemoryInsightsRepository()
    private let calendar: Calendar
    private let now: @Sendable () -> Date

    public init(repository: (any InsightsRepository)?, metrics: (any ExperimentMetricSource)?, calendar: Calendar = .hplLocal(),
                now: @escaping @Sendable () -> Date = Date.init) {
        persistent = repository; self.metrics = metrics; self.calendar = calendar; self.now = now
    }

    /// History is saved on this device (false when launched without the protected store, or showing example data).
    public var isPersistent: Bool { persistent != nil && !isExample }
    var repository: any InsightsRepository { isExample ? example : (persistent ?? example) }
    var ledger: NoteLedger { NoteLedger(repository: repository, calendar: calendar) }
    var tracker: ExperimentTracker { ExperimentTracker(repository: repository, metrics: isExample ? nil : metrics, calendar: calendar) }
    public var todayDay: LocalDay { LocalDay(now(), calendar: calendar) }

    // MARK: Pipeline hooks (called by AppModel around each run)

    /// Switches between the user's history and the example sandbox, and completes experiments that are due.
    public func begin(example: Bool) {
        isExample = example
        do {
            for e in try tracker.finishDue(today: todayDay, now: now()) where !isExample {
                notice = "Experiment finished: \(e.title). See Insights for the comparison."
            }
        } catch {
            notice = "Could not update experiments."
        }
        reload()
    }

    public func context() -> PipelineContext { (try? ledger.context(today: todayDay)) ?? .init() }

    public func activeExperimentEntry() -> DailySummaryV1.ActiveExperiment? { try? tracker.summaryEntry(today: todayDay) }

    public func record(_ recs: [Recommendation]) {
        do {
            today = try ledger.record(recs, day: todayDay, now: now())
        } catch {
            today = []
            notice = "Could not save today's notes."
        }
        reload()
    }

    // MARK: Note actions

    public func accept(_ note: StoredNote) { act { try self.ledger.setStatus(note.id, .accepted, now: self.now()) } }
    public func dismiss(_ note: StoredNote) { act { try self.ledger.setStatus(note.id, .dismissed, now: self.now()) } }
    public func snooze(_ note: StoredNote) { act { try self.ledger.setStatus(note.id, .snoozed, now: self.now()) } }
    public func feedback(_ note: StoredNote, _ value: NoteFeedback?) { act { try self.ledger.setFeedback(note.id, value) } }

    // MARK: Experiments

    public var activeExperiment: Experiment? { experiments.first { $0.status == .active } }
    public var pastExperiments: [Experiment] { experiments.filter { $0.status != .active } }

    public func canStartExperiment(_ note: StoredNote) -> Bool {
        note.recommendation.experiment != nil && note.status == .new && activeExperiment == nil
    }

    public func startExperiment(from note: StoredNote) {
        do {
            let e = try tracker.start(from: note, on: todayDay, now: now())
            notice = "Started: \(e.intervention) for \(e.interventionDays) days."
        } catch InsightsError.experimentAlreadyActive {
            notice = "Finish or stop your current experiment first."
        } catch {
            notice = "Could not start the experiment."
        }
        reload()
    }

    public func checkIn(_ e: Experiment, did: Bool) { act { try self.tracker.checkIn(e.id, day: self.todayDay, did: did) } }
    public func stop(_ e: Experiment) { act { try self.tracker.stop(e.id, on: self.todayDay, now: self.now()) } }
    public func progress(_ e: Experiment) -> ExperimentTracker.Progress { tracker.progress(e, today: todayDay) }

    // MARK: History

    public var filteredHistory: [StoredNote] {
        switch filter {
        case .all: history
        case .accepted: history.filter { $0.status == .accepted || $0.status == .done }
        case .dismissed: history.filter { $0.status == .dismissed }
        case .snoozed: history.filter { $0.status == .snoozed }
        }
    }

    /// Days with notes, newest first, for a sectioned list.
    public struct DayGroup: Identifiable, Sendable {
        public var day: LocalDay
        public var notes: [StoredNote]
        public var id: LocalDay { day }
    }

    public var historyByDay: [DayGroup] {
        Dictionary(grouping: filteredHistory, by: \.day).sorted { $0.key > $1.key }.map { DayGroup(day: $0.key, notes: $0.value) }
    }

    /// `hpl.insights_export.v1` JSON of the user's own history (never the example sandbox).
    public func exportJSON() throws -> Data {
        try NoteLedger(repository: persistent ?? example, calendar: calendar).export(now: now())
    }

    public func clearNotice() { notice = nil }

    private func act(_ body: () throws -> Any) {
        do { _ = try body() } catch { notice = "Could not save that change." }
        reload()
    }

    private func reload() {
        history = (try? ledger.history()) ?? []
        experiments = (try? tracker.all()) ?? []
        let ids = Set(today.map(\.id))
        let byID = Dictionary(history.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        today = today.compactMap { byID[$0.id] }.filter { NoteLedger.visibleStatuses.contains($0.status) && ids.contains($0.id) }
    }
}
