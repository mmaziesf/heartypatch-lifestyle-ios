import Foundation
import HPLCore

/// N-of-1 experiments (M4): start from an experiment note, daily self-reported check-ins, and a plain
/// before-vs-during comparison of one summary metric. One active experiment at a time keeps comparisons readable.
public struct ExperimentTracker: Sendable {
    let repository: any InsightsRepository
    let metrics: (any ExperimentMetricSource)?
    let calendar: Calendar

    public init(repository: any InsightsRepository, metrics: (any ExperimentMetricSource)?, calendar: Calendar = .hplLocal()) {
        self.repository = repository; self.metrics = metrics; self.calendar = calendar
    }

    var ledger: NoteLedger { NoteLedger(repository: repository, calendar: calendar) }

    public struct Progress: Sendable, Equatable {
        public var day: Int
        public var of: Int
        public var checkInsYes: Int
        public var checkInsTotal: Int
        /// nil = not checked in today yet.
        public var today: Bool?
    }

    public func active() throws -> Experiment? { try repository.experiments().first { $0.status == .active } }
    public func all() throws -> [Experiment] { try repository.experiments() }

    /// Starts today (day 1). The baseline is the same number of days just before today, read from data already stored.
    public func start(from note: StoredNote, on day: LocalDay, now: Date) throws -> Experiment {
        guard let proposal = note.recommendation.experiment else { throw InsightsError.notAnExperiment }
        guard try active() == nil else { throw InsightsError.experimentAlreadyActive }
        let e = Experiment(noteID: note.id, title: note.recommendation.title, intervention: proposal.intervention,
                           metricFieldPath: proposal.metricFieldPath, days: proposal.durationDays, startDay: day,
                           provenance: note.recommendation.provenance)
        try repository.save(e)
        try ledger.setStatus(note.id, .accepted, now: now, experimentID: e.id)
        return e
    }

    @discardableResult
    public func checkIn(_ id: UUID, day: LocalDay, did: Bool) throws -> Experiment {
        guard var e = try repository.experiments().first(where: { $0.id == id }) else { throw InsightsError.notFound }
        guard e.status == .active else { throw InsightsError.experimentNotActive }
        e.checkIns[day.description] = did
        try repository.save(e)
        return e
    }

    /// Ends early; the comparison covers the days so far (usually "not enough data").
    @discardableResult
    public func stop(_ id: UUID, on day: LocalDay, now: Date) throws -> Experiment {
        guard var e = try repository.experiments().first(where: { $0.id == id }) else { throw InsightsError.notFound }
        guard e.status == .active else { throw InsightsError.experimentNotActive }
        e.status = .stopped
        e.endedOn = min(day, e.lastDay(calendar: calendar))
        e.result = try result(for: e, through: e.endedOn ?? day)
        try repository.save(e)
        if let noteID = e.noteID { _ = try? ledger.setStatus(noteID, .done, now: now) }
        return e
    }

    /// Completes experiments whose last day is over. Call on each foreground/daily run.
    @discardableResult
    public func finishDue(today: LocalDay, now: Date) throws -> [Experiment] {
        var finished: [Experiment] = []
        for var e in try repository.experiments() where e.status == .active && today > e.lastDay(calendar: calendar) {
            e.status = .completed
            e.endedOn = e.lastDay(calendar: calendar)
            e.result = try result(for: e, through: e.lastDay(calendar: calendar))
            try repository.save(e)
            if let noteID = e.noteID { _ = try? ledger.setStatus(noteID, .done, now: now) }
            finished.append(e)
        }
        return finished
    }

    public func progress(_ e: Experiment, today: LocalDay) -> Progress {
        let window = Set(e.startDay.through(min(today, e.lastDay(calendar: calendar)), calendar: calendar).map(\.description))
        let inWindow = e.checkIns.filter { window.contains($0.key) }
        return Progress(day: e.dayNumber(on: today, calendar: calendar), of: e.interventionDays,
                        checkInsYes: inWindow.values.filter { $0 }.count, checkInsTotal: inWindow.count, today: e.checkIns[today.description])
    }

    /// The `active_experiments` entry for today's DailySummary (so notes can mention progress).
    public func summaryEntry(today: LocalDay) throws -> DailySummaryV1.ActiveExperiment? {
        guard let e = try active(), today >= e.startDay else { return nil }
        return .init(id: "E1", intervention: e.intervention, day: e.dayNumber(on: today, calendar: calendar), of: e.interventionDays)
    }

    public func result(for e: Experiment, through last: LocalDay) throws -> ExperimentResult {
        let baseline = e.baselineRange(calendar: calendar)
        let during = e.startDay.through(min(last, e.lastDay(calendar: calendar)), calendar: calendar)
        let values = try metrics?.values(metric: e.metricFieldPath, days: baseline + during) ?? [:]
        let b = baseline.compactMap { values[$0] }
        let i = during.compactMap { values[$0] }
        let checks = during.compactMap { e.checkIns[$0.description] }
        let needed = max(3, (e.interventionDays + 1) / 2)
        return ExperimentResultCopy.make(
            metric: e.metricFieldPath, baseline: b, during: i, baselineDays: e.baselineDays, duringDays: during.count,
            checkInsYes: checks.filter { $0 }.count, checkInsTotal: checks.count, needed: needed)
    }
}

/// Deterministic result wording. Restates averages against the user's own day-to-day spread; never a health claim.
enum ExperimentResultCopy {
    static func mean(_ v: [Double]) -> Double? { v.isEmpty ? nil : v.reduce(0, +) / Double(v.count) }

    static func sd(_ v: [Double]) -> Double? {
        guard v.count >= 2, let m = mean(v) else { return nil }
        return (v.map { ($0 - m) * ($0 - m) }.reduce(0, +) / Double(v.count - 1)).squareRoot()
    }

    static func fmt(_ v: Double) -> String { abs(v) >= 20 ? String(Int(v.rounded())) : String(format: "%.1f", v) }

    static func make(metric: String, baseline b: [Double], during i: [Double], baselineDays: Int, duringDays: Int,
                     checkInsYes: Int, checkInsTotal: Int, needed: Int) -> ExperimentResult {
        let label = FieldLabels.label(for: metric)
        let unit = label.unit.map { " \($0)" } ?? ""
        let enough = b.count >= needed && i.count >= needed
        var text: String
        if enough, let bm = mean(b), let im = mean(i) {
            text = "\(label.name): average \(fmt(bm))\(unit) over \(b.count) days before vs \(fmt(im))\(unit) over \(i.count) days during."
            if let spread = sd(b) {
                text += abs(im - bm) <= spread
                    ? " That difference is within your usual day-to-day variation, so this run doesn't show a clear change."
                    : " That difference is larger than your usual day-to-day variation."
            }
        } else {
            text = "Not enough days with \(label.name.lowercased()) data to compare "
                + "(before: \(b.count) of \(baselineDays) days, during: \(i.count) of \(duringDays) days)."
        }
        if checkInsTotal > 0 { text += " You checked in as doing it on \(checkInsYes) of \(checkInsTotal) days." }
        text += " One run on one person is a hint, not proof."
        return ExperimentResult(baselineMean: mean(b), baselineDaysWithData: b.count, baselineSD: sd(b), interventionMean: mean(i),
                                interventionDaysWithData: i.count, checkInsYes: checkInsYes, checkInsTotal: checkInsTotal,
                                enoughData: enough, summary: text)
    }
}

/// Reads experiment metrics from the same DailySummary the note cited, so "sleep.total_min" means the same thing everywhere.
public struct SummaryMetricSource: ExperimentMetricSource {
    let builder: SummaryBuilder
    public init(builder: SummaryBuilder) { self.builder = builder }

    public func values(metric fieldPath: String, days: [LocalDay]) throws -> [LocalDay: Double] {
        var out: [LocalDay: Double] = [:]
        for day in days {
            guard let s = try builder.build(day: day), case .number(let v)? = try s.jsonTree().value(at: fieldPath) else { continue }
            out[day] = v
        }
        return out
    }
}
