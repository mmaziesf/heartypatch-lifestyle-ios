import HPLCore

/// Blood-work ingest (M2): PDFKit text layer -> Vision OCR -> LabParser -> human confirm. Nothing unconfirmed reaches DailySummary.
public enum LabIngest {
    public static let milestone = "M2"

    public typealias ExtractionStatus = SourceDocument.Status

    /// The only status allowed into DailySummary / the LLM.
    public static func isUsable(_ status: ExtractionStatus) -> Bool { status == .confirmed }
}
