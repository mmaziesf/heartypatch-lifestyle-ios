import HPLCore

/// Blood-work ingest (M2): PDFKit text layer -> Vision OCR -> LabParser -> human confirm. Nothing unconfirmed reaches DailySummary.
/// M0 is a compiling boundary only.
public enum LabIngest {
    public static let milestone = "M2"

    public enum ExtractionStatus: String, Codable, Sendable { case pending, extracted, confirmed, rejected }

    /// The only status allowed into DailySummary / the LLM.
    public static func isUsable(_ status: ExtractionStatus) -> Bool { status == .confirmed }
}
