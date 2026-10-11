import Foundation

/// An imported report file (architecture §4.2). The original stays in the protected container; no identifiers are copied out.
public struct SourceDocument: Codable, Sendable, Equatable, Identifiable {
    public enum Kind: String, Codable, Sendable { case pdf, image, manual }
    public enum Status: String, Codable, Sendable { case pending, extracted, confirmed, rejected }

    public var id: UUID
    public var kind: Kind
    /// SHA-256 of the file bytes (hex). Re-importing the same file is detected by this.
    public var sha256: String
    /// File name inside the app's protected documents folder (not the user's original path).
    public var storedFileName: String
    public var importedAt: Date
    /// e.g. "pdfkit-text", "vision-ocr".
    public var extractor: String
    public var status: Status

    public init(id: UUID = UUID(), kind: Kind, sha256: String, storedFileName: String, importedAt: Date, extractor: String, status: Status) {
        self.id = id; self.kind = kind; self.sha256 = sha256; self.storedFileName = storedFileName
        self.importedAt = importedAt; self.extractor = extractor; self.status = status
    }
}

/// A confirmed set of results from one report. Lab name, patient, and ordering clinician are never stored.
public struct LabPanel: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    /// Specimen collection day (from the report if found, else user-entered).
    public var collectedOn: LocalDay
    public var sourceDocumentID: UUID?
    public var confirmedAt: Date

    public init(id: UUID = UUID(), collectedOn: LocalDay, sourceDocumentID: UUID?, confirmedAt: Date) {
        self.id = id; self.collectedOn = collectedOn; self.sourceDocumentID = sourceDocumentID; self.confirmedAt = confirmedAt
    }
}

/// Flags exactly as printed on the report. HPL restates them; it never derives its own.
public enum ReportFlag: String, Codable, Sendable, CaseIterable { case high = "H", low = "L", criticalHigh = "HH", criticalLow = "LL", abnormal = "A" }

public struct LabResult: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var panelID: UUID
    /// As printed, e.g. "Hemoglobin A1c".
    public var analyteRaw: String
    /// Dictionary key, e.g. "hba1c". `nil` = not in the dictionary (kept, but excluded from summaries).
    public var analyteCanonical: String?
    public var loinc: String?
    public var valueNumeric: Double?
    /// Non-numeric results ("Negative") or the comparator form ("<0.5").
    public var valueText: String?
    public var unitRaw: String
    /// UCUM-style canonical unit for the analyte, when known.
    public var unitCanonical: String?
    /// `valueNumeric` converted to `unitCanonical` (nil if no conversion is known).
    public var valueCanonical: Double?
    /// Reference range FROM THE REPORT only (never a population default), in the report's unit.
    public var refLow: Double?
    public var refHigh: Double?
    public var refText: String?
    public var flagFromReport: ReportFlag?
    public var extractionConfidence: Double
    public var page: Int?
    public var userConfirmed: Bool
    public var userEdited: Bool

    public init(id: UUID = UUID(), panelID: UUID, analyteRaw: String, analyteCanonical: String?, loinc: String?,
                valueNumeric: Double?, valueText: String?, unitRaw: String, unitCanonical: String?, valueCanonical: Double?,
                refLow: Double?, refHigh: Double?, refText: String?, flagFromReport: ReportFlag?,
                extractionConfidence: Double, page: Int?, userConfirmed: Bool, userEdited: Bool) {
        self.id = id; self.panelID = panelID; self.analyteRaw = analyteRaw; self.analyteCanonical = analyteCanonical
        self.loinc = loinc; self.valueNumeric = valueNumeric; self.valueText = valueText; self.unitRaw = unitRaw
        self.unitCanonical = unitCanonical; self.valueCanonical = valueCanonical; self.refLow = refLow; self.refHigh = refHigh
        self.refText = refText; self.flagFromReport = flagFromReport; self.extractionConfidence = extractionConfidence
        self.page = page; self.userConfirmed = userConfirmed; self.userEdited = userEdited
    }
}

public enum LabRepositoryError: Error, Equatable, Sendable {
    /// Only user-confirmed results may be stored (§5.2 rule: nothing unconfirmed reaches the summary or the LLM).
    case unconfirmedResult
    case duplicateDocument
}

/// Storage boundary for labs. Implementations must reject unconfirmed results.
public protocol LabRepository: Sendable {
    func document(sha256: String) throws -> SourceDocument?
    func documents() throws -> [SourceDocument]
    func saveDocument(_ doc: SourceDocument) throws
    /// Saves a confirmed panel and its results atomically and marks the document confirmed.
    func saveConfirmed(panel: LabPanel, results: [LabResult]) throws
    func panels() throws -> [LabPanel]
    func results(panelID: UUID) throws -> [LabResult]
    func deleteAll() throws
}

public extension LabRepository {
    /// Every stored result with its panel, newest collection first.
    func confirmedResults() throws -> [(panel: LabPanel, result: LabResult)] {
        try panels().sorted { $0.collectedOn > $1.collectedOn }.flatMap { p in try results(panelID: p.id).map { (p, $0) } }
    }
}
