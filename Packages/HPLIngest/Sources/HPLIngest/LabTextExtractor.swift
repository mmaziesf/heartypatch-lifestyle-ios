import Foundation
import HPLCore

public struct ExtractedText: Sendable, Equatable {
    public var lines: [LabTextLine]
    /// "pdfkit-text", "vision-ocr", "plain-text".
    public var extractor: String
    public init(lines: [LabTextLine], extractor: String) { self.lines = lines; self.extractor = extractor }
}

public enum LabExtractionError: Error, Equatable, Sendable { case unreadable, noText, unsupported }

/// On-device text extraction boundary (§5.2): PDFKit text layer first, Vision OCR for scans and photos.
public protocol LabTextExtractor: Sendable {
    func extract(_ data: Data, kind: SourceDocument.Kind) async throws -> ExtractedText
}

/// UTF-8 text, one line per row. Used by tests and the synthetic fixture corpus (no real reports in the repo).
public struct PlainTextExtractor: LabTextExtractor {
    public init() {}
    public func extract(_ data: Data, kind: SourceDocument.Kind) async throws -> ExtractedText {
        guard let s = String(data: data, encoding: .utf8) else { throw LabExtractionError.unreadable }
        var page = 1
        var lines: [LabTextLine] = []
        for raw in s.components(separatedBy: .newlines) {
            if raw.contains("\u{0C}") { page += 1 } // form feed = page break
            let t = raw.replacingOccurrences(of: "\u{0C}", with: "").trimmingCharacters(in: .whitespaces)
            if !t.isEmpty { lines.append(LabTextLine(text: Self.collapseSpaces(t), page: page)) }
        }
        guard !lines.isEmpty else { throw LabExtractionError.noText }
        return ExtractedText(lines: lines, extractor: "plain-text")
    }

    static func collapseSpaces(_ s: String) -> String {
        s.split(whereSeparator: { $0 == " " || $0 == "\t" }).joined(separator: " ")
    }
}
