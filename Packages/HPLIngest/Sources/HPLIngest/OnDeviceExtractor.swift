#if canImport(PDFKit) && canImport(Vision)
import Foundation
import CoreGraphics
import ImageIO
import PDFKit
import Vision
import HPLCore

/// PDFKit text layer, falling back to Vision OCR per page when a PDF is a scan; Vision OCR for photos.
/// Runs entirely on device. VERIFY on real reports: column order of PDFKit text and OCR line grouping.
public struct OnDeviceLabExtractor: LabTextExtractor {
    /// Pages rendered for OCR at this scale (points → pixels).
    static let ocrScale: CGFloat = 2.5
    static let maxPages = 20

    public init() {}

    public func extract(_ data: Data, kind: SourceDocument.Kind) async throws -> ExtractedText {
        switch kind {
        case .pdf: return try pdf(data)
        case .image:
            guard let src = CGImageSourceCreateWithData(data as CFData, nil), let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
                throw LabExtractionError.unreadable
            }
            let lines = try Self.ocr(img, page: 1)
            guard !lines.isEmpty else { throw LabExtractionError.noText }
            return ExtractedText(lines: lines, extractor: "vision-ocr")
        case .manual: throw LabExtractionError.unsupported
        }
    }

    private func pdf(_ data: Data) throws -> ExtractedText {
        guard let doc = PDFDocument(data: data) else { throw LabExtractionError.unreadable }
        var lines: [LabTextLine] = []
        var usedOCR = false
        for i in 0..<min(doc.pageCount, Self.maxPages) {
            guard let page = doc.page(at: i) else { continue }
            let text = page.string ?? ""
            if text.trimmingCharacters(in: .whitespacesAndNewlines).count > 20 {
                lines += text.components(separatedBy: .newlines)
                    .map { PlainTextExtractor.collapseSpaces($0.trimmingCharacters(in: .whitespaces)) }
                    .filter { !$0.isEmpty }
                    .map { LabTextLine(text: $0, page: i + 1) }
            } else if let img = Self.render(page) {
                usedOCR = true
                lines += try Self.ocr(img, page: i + 1)
            }
        }
        guard !lines.isEmpty else { throw LabExtractionError.noText }
        return ExtractedText(lines: lines, extractor: usedOCR ? "pdfkit+vision-ocr" : "pdfkit-text")
    }

    static func render(_ page: PDFPage) -> CGImage? {
        let bounds = page.bounds(for: .mediaBox)
        let w = Int(bounds.width * ocrScale), h = Int(bounds.height * ocrScale)
        guard w > 0, h > 0, let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.scaleBy(x: ocrScale, y: ocrScale)
        page.draw(with: .mediaBox, to: ctx)
        return ctx.makeImage()
    }

    /// Vision text recognition, then rows rebuilt by grouping observations with overlapping vertical centers.
    static func ocr(_ image: CGImage, page: Int) throws -> [LabTextLine] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false // keeps "mg/dL", "HbA1c" intact
        try VNImageRequestHandler(cgImage: image).perform([request])
        let obs = (request.results ?? []).compactMap { o -> (String, CGRect)? in
            o.topCandidates(1).first.map { ($0.string, o.boundingBox) }
        }
        var rows: [[(String, CGRect)]] = []
        for o in obs.sorted(by: { $0.1.midY > $1.1.midY }) {
            if let last = rows.last?.first, abs(last.1.midY - o.1.midY) < max(last.1.height, o.1.height) * 0.5 {
                rows[rows.count - 1].append(o)
            } else {
                rows.append([o])
            }
        }
        return rows.map { row in
            let sorted = row.sorted { $0.1.minX < $1.1.minX }
            let box = sorted.map(\.1).reduce(sorted[0].1) { $0.union($1) }
            return LabTextLine(text: PlainTextExtractor.collapseSpaces(sorted.map(\.0).joined(separator: " ")), page: page,
                               box: .init(x: box.minX, y: 1 - box.maxY, width: box.width, height: box.height))
        }
    }
}
#endif
