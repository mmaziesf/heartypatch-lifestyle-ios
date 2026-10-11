import Foundation
import HPLCore

/// One row in the confirm-every-value screen.
public struct ReviewRow: Sendable, Equatable, Identifiable {
    public enum Decision: Sendable, Equatable { case pending, confirmed, rejected }
    public var id: Int { candidate.lineIndex }
    public var candidate: LabCandidate
    public var decision: Decision = .pending
    public var edited = false
}

public enum LabReviewError: Error, Equatable, Sendable {
    case rowsStillPending(Int)
    case missingCollectionDate
    case nothingConfirmed
}

/// The review flow (§5.2): every extracted row must be explicitly confirmed, edited, or rejected before saving.
/// There is deliberately no "confirm all".
public struct ReviewSession: Sendable, Equatable {
    public var document: SourceDocument
    public var rows: [ReviewRow]
    public var collectedOn: LocalDay?
    public let collectedOnFromReport: Bool
    public let identifierLinesDropped: Int

    public init(document: SourceDocument, parse: LabParseResult) {
        self.document = document
        rows = parse.candidates.map { ReviewRow(candidate: $0) }
        collectedOn = parse.collectedOn
        collectedOnFromReport = parse.collectedOn != nil
        identifierLinesDropped = parse.identifierLinesDropped
    }

    public var pendingCount: Int { rows.filter { $0.decision == .pending }.count }
    public var confirmedCount: Int { rows.filter { $0.decision == .confirmed }.count }
    public var canSave: Bool { pendingCount == 0 && confirmedCount > 0 && collectedOn != nil }

    public mutating func confirm(_ id: Int) { set(id) { $0.decision = .confirmed } }
    public mutating func reject(_ id: Int) { set(id) { $0.decision = .rejected } }
    public mutating func reopen(_ id: Int) { set(id) { $0.decision = .pending } }

    /// User correction. Editing counts as confirming that row; the dictionary mapping and unit are re-derived.
    public mutating func edit(_ id: Int, value: Double?, valueText: String? = nil, unit: String, analyteKey: String?) {
        set(id) { row in
            row.candidate.valueNumeric = value
            row.candidate.valueText = valueText
            row.candidate.unitRaw = unit
            row.candidate.unitNormalized = LabUnits.normalize(unit) ?? (unit.isEmpty ? nil : unit)
            if let analyteKey, AnalyteDictionary.analyte(key: analyteKey) != nil { row.candidate.analyteKey = analyteKey }
            if analyteKey == nil { row.candidate.analyteKey = nil }
            row.edited = true
            row.decision = .confirmed
        }
    }

    private mutating func set(_ id: Int, _ change: (inout ReviewRow) -> Void) {
        if let i = rows.firstIndex(where: { $0.id == id }) { change(&rows[i]) }
    }

    /// Builds the records to store. Throws unless every row was decided and a collection date is set.
    public func makeRecords(now: Date) throws -> (panel: LabPanel, results: [LabResult]) {
        guard pendingCount == 0 else { throw LabReviewError.rowsStillPending(pendingCount) }
        guard let collectedOn else { throw LabReviewError.missingCollectionDate }
        guard confirmedCount > 0 else { throw LabReviewError.nothingConfirmed }
        let panel = LabPanel(collectedOn: collectedOn, sourceDocumentID: document.id, confirmedAt: now)
        let results = rows.filter { $0.decision == .confirmed }.map { row in
            let c = row.candidate
            return LabResult(panelID: panel.id, analyteRaw: c.analyteRaw, analyteCanonical: c.analyteKey, loinc: c.analyte?.loinc,
                             valueNumeric: c.valueNumeric, valueText: c.valueText, unitRaw: c.unitRaw, unitCanonical: c.analyte?.unit,
                             valueCanonical: c.valueCanonical, refLow: c.refLow, refHigh: c.refHigh, refText: c.refText,
                             flagFromReport: c.flag, extractionConfidence: c.confidence, page: c.page,
                             userConfirmed: true, userEdited: row.edited)
        }
        return (panel, results)
    }
}

public enum ImportOutcome: Sendable, Equatable {
    /// This exact file was already confirmed; nothing new was stored.
    case duplicate(SourceDocument)
    case review(ReviewSession)
}

/// Import → extract → parse → review → save. Only `save` writes results, and only confirmed ones.
public actor LabImporter {
    private let repository: any LabRepository
    private let files: any LabFileStore
    private let extractor: any LabTextExtractor
    private let parser: LabParser
    private let now: @Sendable () -> Date

    public init(repository: any LabRepository, files: any LabFileStore, extractor: any LabTextExtractor,
                parser: LabParser = LabParser(), now: @escaping @Sendable () -> Date = Date.init) {
        self.repository = repository; self.files = files; self.extractor = extractor; self.parser = parser; self.now = now
    }

    public func importFile(_ data: Data, kind: SourceDocument.Kind, fileExtension: String) async throws -> ImportOutcome {
        let hash = SHA256Digest.hex(data)
        let existing = try repository.document(sha256: hash)
        if let existing, existing.status == .confirmed { return .duplicate(existing) }

        let name = existing?.storedFileName ?? "\(hash.prefix(16)).\(fileExtension.lowercased())"
        try files.store(data, name: name)
        let text = try await extractor.extract(data, kind: kind)
        var doc = existing ?? SourceDocument(kind: kind, sha256: hash, storedFileName: name, importedAt: now(),
                                             extractor: text.extractor, status: .pending)
        doc.extractor = text.extractor
        doc.status = .extracted
        try repository.saveDocument(doc)
        return .review(ReviewSession(document: doc, parse: parser.parse(text.lines)))
    }

    @discardableResult
    public func save(_ session: ReviewSession) throws -> LabPanel {
        let records = try session.makeRecords(now: now())
        try repository.saveConfirmed(panel: records.panel, results: records.results)
        return records.panel
    }

    /// User backed out: the stored copy of the file is deleted; the document row stays `rejected` (hash only).
    public func discard(_ session: ReviewSession) throws {
        var doc = session.document
        doc.status = .rejected
        try repository.saveDocument(doc)
        try? files.delete(name: doc.storedFileName)
    }
}
