import Foundation
import Observation
import HPLCore
import HPLIngest

/// Lab import wiring handed to the app.
public struct LabServices: Sendable {
    public let importer: LabImporter
    public let repository: any LabRepository
    public init(importer: LabImporter, repository: any LabRepository) { self.importer = importer; self.repository = repository }
}

/// Labs tab + confirm-every-value review (§5.2, §9.2). Platform-neutral so the flow is tested on Linux.
/// Copy only restates the report; it never says what a value means.
@MainActor @Observable
public final class LabsModel {
    public struct PanelItem: Identifiable, Equatable, Sendable {
        public var id: UUID { panel.id }
        public var panel: LabPanel
        public var results: [LabResult]
    }

    public private(set) var panels: [PanelItem] = []
    public private(set) var review: ReviewSession?
    public private(set) var notice: String?
    public private(set) var isImporting = false

    private let services: LabServices?
    private let calendar: Calendar

    public init(services: LabServices?, calendar: Calendar = .hplLocal()) {
        self.services = services; self.calendar = calendar
        reload()
    }

    public var isAvailable: Bool { services != nil }

    public func reload() {
        guard let repo = services?.repository else { return }
        panels = ((try? repo.panels()) ?? []).map { p in
            PanelItem(panel: p, results: ((try? repo.results(panelID: p.id)) ?? []).sorted { $0.analyteRaw < $1.analyteRaw })
        }
    }

    public func dismissNotice() { notice = nil }

    public func importFile(_ data: Data, kind: SourceDocument.Kind, fileExtension: String) async {
        guard let services else { return }
        isImporting = true
        defer { isImporting = false }
        do {
            switch try await services.importer.importFile(data, kind: kind, fileExtension: fileExtension) {
            case .duplicate(let doc):
                notice = "This report was already imported on \(LocalDay(doc.importedAt, calendar: calendar)). Nothing new was added."
            case .review(let session):
                if session.rows.isEmpty {
                    try await services.importer.discard(session)
                    notice = "No lab rows were recognized in this file. Manual entry arrives later in M2."
                } else {
                    review = session
                }
            }
        } catch {
            notice = "Couldn't read that file on this device."
        }
    }

    public func confirm(_ id: Int) { review?.confirm(id) }
    public func reject(_ id: Int) { review?.reject(id) }
    public func reopen(_ id: Int) { review?.reopen(id) }

    /// Applies a user correction from text fields. Returns false (and changes nothing) if the value isn't a number or known text result.
    @discardableResult
    public func edit(_ id: Int, value: String, unit: String, analyteKey: String?) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        if let v = Double(trimmed.replacingOccurrences(of: ",", with: "")) {
            review?.edit(id, value: v, unit: unit, analyteKey: analyteKey)
        } else if let t = LabParser.textValue(trimmed) {
            review?.edit(id, value: nil, valueText: t.value, unit: unit, analyteKey: analyteKey)
        } else {
            return false
        }
        return true
    }

    public func setCollectedOn(_ date: Date) { review?.collectedOn = LocalDay(date, calendar: calendar) }

    public func saveReview() async {
        guard let services, let review else { return }
        do {
            try await services.importer.save(review)
            self.review = nil
            notice = "Saved \(review.confirmedCount) confirmed values."
            reload()
        } catch LabReviewError.rowsStillPending(let n) {
            notice = "Confirm, edit, or reject the \(n) remaining rows first."
        } catch {
            notice = "Couldn't save. Nothing was stored."
        }
    }

    public func cancelReview() async {
        guard let services, let review else { return }
        try? await services.importer.discard(review)
        self.review = nil
    }

    // MARK: Restating copy (never interpretation)

    public static func valueText(_ value: Double?, _ text: String?, unit: String) -> String {
        let v = text ?? value.map(LabParser.fmt) ?? "—"
        return unit.isEmpty ? v : "\(v) \(unit)"
    }

    public static func rangeText(low: Double?, high: Double?, text: String?) -> String {
        switch (low, high) {
        case let (l?, h?): "Range on report: \(LabParser.fmt(l))–\(LabParser.fmt(h))"
        case let (nil, h?): "Range on report: <\(LabParser.fmt(h))"
        case let (l?, nil): "Range on report: >\(LabParser.fmt(l))"
        default: text.map { "On report: \($0)" } ?? "No range on report"
        }
    }

    public static func flagText(_ flag: ReportFlag?) -> String? {
        flag.map { "Report marks this \($0.rawValue)" }
    }
}
