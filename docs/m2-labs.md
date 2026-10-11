# M2: Lab import (scaffold)

Personal wellness tracking only. The app restates what a lab report says. It does not interpret results, and it never invents reference ranges.

## Flow

1. **Import** (Labs tab → Import): pick a PDF or image with the system file importer.
2. **Hash + dedupe.** The app takes the SHA-256 of the file bytes. If that file was already confirmed, the import stops with "already imported". A file that was discarded or never confirmed can be imported again.
3. **Store original.** The file is copied to `Application Support/HPL/Documents/<sha>.<ext>` with `NSFileProtectionComplete`.
4. **Extract on device** (`OnDeviceLabExtractor`):
   - PDF text layer via PDFKit.
   - If a page has no usable text, the page is rendered and OCR'd with Vision (`VNRecognizeTextRequest`, accurate). Observations are grouped into rows by y-position.
   - Images use Vision OCR directly.
   - Nothing leaves the device.
5. **Parse** (`LabParser`, rules only):
   - Lines that look like identifiers (name, DOB, MRN, account, address, phone) are dropped before parsing.
   - Each row is matched against `AnalyteDictionary` (79 common tests, aliases, canonical unit, linear conversions).
   - The parser pulls out the value (numeric or text, including `<0.5`-style), unit, the report's reference range and the report's flag (H/L/HH/LL/A).
   - The collection date is taken from "Collected/Collection Date/Specimen Date" lines.
   - Unrecognised rows are kept as "unmapped". They can be confirmed, but they are excluded from the summary.
6. **Confirm every value** (`ReviewSession`, `LabReviewView`):
   - Each row must be individually confirmed or rejected. There is no confirm-all.
   - Edits mark the row `userEdited`.
   - Save is blocked until no rows are pending, a collection date is set, and at least one row is confirmed.
7. **Save.** Only confirmed results are written to the repository (`LabRepository` rejects unconfirmed results). The source document is marked `confirmed`.
8. **Summary.** `SummaryBuilder` emits `labs_recent`. It holds the latest confirmed value per dictionary analyte within 365 days, in the canonical unit, with the report's range converted by the same factor.

## Done (verified by CI on Linux/macOS/iOS simulator)

- Models: `SourceDocument`, `LabPanel`, `LabResult` (HPLCore). In-memory and SwiftData repositories share a contract test.
- Parser and dictionary: 100% exact extraction on 4 synthetic formats, 59 rows (`Fixtures/labs/*.synthetic.txt` + `.expected.json`):
  - US columns
  - US flag-last CBC
  - SI units
  - OCR-noisy
- Review session rules, dedupe, discard (deletes the stored file), and the SwiftData persistence.
- Labs tab UI: list, import, review, edit row, collection-date picker.
- Pure-Swift SHA-256 (tested against known vectors).

## Needs real PDFs / a device

- **Accuracy gate (exit criterion):** ≥90% of rows exactly right on 30+ real, redacted reports from ≥5 lab formats. The synthetic fixtures only show that the rules work on the layouts we invented.
  - Add real reports as `Fixtures/labs/<format>.redacted.pdf` + `.expected.json`, with all identifiers removed.
- PDFKit/Vision extraction has only been compiled, not run on real files. Row grouping on multi-column and scanned layouts is the biggest risk.
- Photo-of-paper OCR quality (lighting, skew).
- File importer, security-scoped access and file protection on a real iPhone.
- LOINC codes in `AnalyteDictionary` are marked `VERIFY`; check them against loinc.org before any export.

## Not built yet

- Side-by-side page image with the source row highlighted.
- VisionKit document camera (would need `NSCameraUsageDescription`).
- Share-sheet extension.
- Manual entry.
- LLM-assisted extraction for unmapped rows.
