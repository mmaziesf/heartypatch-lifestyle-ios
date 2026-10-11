import Foundation
import Testing
import HPLCore
import HPLStore
@testable import HPLIngest

@Test func onlyConfirmedIsUsable() {
    #expect(LabIngest.isUsable(.confirmed))
    #expect(![.pending, .extracted, .rejected].contains { LabIngest.isUsable($0) })
}

/// Repo-root `Fixtures/labs` (synthetic text only).
let labFixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/labs")

struct Expected: Decodable {
    struct Row: Decodable {
        var analyte: String
        var value: Double
        var unit: String
        var ref_low: Double?
        var ref_high: Double?
        var flag: String?
        var canonical: Double?
    }
    var collected_on: String
    var forbidden: [String]
    var rows: [Row]
    var unmapped: [String]?
}

func fixtureNames() throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: labFixtures.path)
        .filter { $0.hasSuffix(".synthetic.txt") }.map { String($0.dropLast(".synthetic.txt".count)) }.sorted()
}

func parseFixture(_ name: String) async throws -> (LabParseResult, Expected) {
    let text = try await PlainTextExtractor().extract(Data(contentsOf: labFixtures.appendingPathComponent("\(name).synthetic.txt")), kind: .pdf)
    let exp = try JSONDecoder().decode(Expected.self, from: Data(contentsOf: labFixtures.appendingPathComponent("\(name).expected.json")))
    return (LabParser().parse(text.lines), exp)
}

@Suite struct LabParserCorpusTests {
    @Test func corpusHasAtLeastFourSyntheticFormats() throws { #expect(try fixtureNames().count >= 4) }

    /// Mirrors the M2 exit metric on the synthetic corpus: in-dictionary rows with correct value + unit + report range + flag.
    @Test func everyExpectedRowExtractedExactly() async throws {
        var total = 0, correct = 0
        var misses: [String] = []
        for name in try fixtureNames() {
            let (parsed, exp) = try await parseFixture(name)
            #expect(parsed.collectedOn?.description == exp.collected_on, "\(name) collection date")
            for row in exp.rows {
                total += 1
                let c = parsed.candidates.first { $0.analyteKey == row.analyte }
                let ok = c != nil && c?.valueNumeric == row.value && c?.unitNormalized == row.unit
                    && c?.refLow == row.ref_low && c?.refHigh == row.ref_high && c?.flag?.rawValue == row.flag
                    && (row.canonical == nil || abs((c?.valueCanonical ?? -1) - row.canonical!) < 0.01)
                if ok { correct += 1 } else { misses.append("\(name):\(row.analyte) got \(String(describing: c))") }
            }
            let mappedKeys = Set(parsed.candidates.compactMap(\.analyteKey))
            #expect(mappedKeys == Set(exp.rows.map(\.analyte)), "\(name): no extra dictionary rows")
            #expect(Set(parsed.candidates.filter { $0.analyteKey == nil }.map(\.analyteRaw)) == Set(exp.unmapped ?? []), "\(name) unmapped")
        }
        #expect(misses.isEmpty, "\(misses.joined(separator: "\n"))")
        #expect(total >= 50 && Double(correct) / Double(total) >= 0.9)
    }

    /// Property: identifiers printed on the report never reach a candidate (and so never reach LabPanel/LabResult).
    @Test func identifiersNeverAppearInCandidates() async throws {
        for name in try fixtureNames() {
            let (parsed, exp) = try await parseFixture(name)
            #expect(parsed.identifierLinesDropped >= 2, "\(name)")
            for c in parsed.candidates {
                let blob = [c.sourceText, c.analyteRaw, c.valueText ?? "", c.unitRaw, c.refText ?? ""].joined(separator: "|")
                for f in exp.forbidden { #expect(!blob.contains(f), "\(name): '\(f)' leaked via \(c.sourceText)") }
            }
        }
    }
}

@Suite struct LabParserUnitTests {
    let p = LabParser()

    @Test func comparatorValueAndTextResults() {
        let lpa = p.parse([LabTextLine(text: "Lp(a) <8.4 nmol/L <75")]).candidates.first
        #expect(lpa?.valueNumeric == 8.4); #expect(lpa?.valueText == "<8.4"); #expect(lpa?.refHigh == 75)
        #expect(p.parse([LabTextLine(text: "Glucose 65-99 mg/dL")]).candidates.isEmpty, "a range with no value is not a result")
    }

    @Test func noRangeOnReportStaysNil() {
        let c = p.parse([LabTextLine(text: "Ferritin 154 ng/mL")]).candidates.first
        #expect(c?.refLow == nil && c?.refHigh == nil && c?.refText == nil, "never invent a population range")
    }

    @Test func unknownUnitIsKeptButNotConverted() {
        let c = p.parse([LabTextLine(text: "Lp(a) 30 mg/dL <30")]).candidates.first
        #expect(c?.valueNumeric == 30); #expect(c?.valueCanonical == nil, "mg/dL ↔ nmol/L for Lp(a) has no fixed factor")
    }

    @Test func identifierLines() {
        for line in ["Patient Name: X", "DOB 01/01/1900", "MRN: 1", "Phone: 555", "Age: 40", "Account #: 9"] {
            #expect(LabParser.isIdentifierLine(line.lowercased()), "\(line)")
        }
        for line in ["Sex Hormone Binding Globulin 45 nmol/L", "Albumin 4.6 g/dL", "Phosphorus 3.4 mg/dL"] {
            #expect(!LabParser.isIdentifierLine(line.lowercased()), "\(line)")
        }
    }

    @Test func dictionaryHasAbout80UniqueAnalytes() {
        #expect(AnalyteDictionary.all.count >= 75)
        #expect(Set(AnalyteDictionary.all.map(\.key)).count == AnalyteDictionary.all.count)
        #expect(Set(AnalyteDictionary.all.map(\.loinc)).count == AnalyteDictionary.all.count)
    }
}

@Suite struct SHA256Tests {
    @Test func knownVectors() {
        #expect(SHA256Digest.hex(Data()) == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        #expect(SHA256Digest.hex(Data("abc".utf8)) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        let long = Data("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq".utf8)
        #expect(SHA256Digest.hex(long) == "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
    }
}

@Suite struct LabImportFlowTests {
    func importer(_ repo: InMemoryLabRepository, _ files: InMemoryLabFileStore) -> LabImporter {
        LabImporter(repository: repo, files: files, extractor: PlainTextExtractor(), now: { Date(timeIntervalSince1970: 1_791_000_000) })
    }

    func session(_ outcome: ImportOutcome) throws -> ReviewSession {
        guard case .review(let s) = outcome else { throw LabReviewError.nothingConfirmed }
        return s
    }

    @Test func confirmEveryValueThenSaveThenDedupe() async throws {
        let repo = InMemoryLabRepository(), files = InMemoryLabFileStore()
        let imp = importer(repo, files)
        let data = try Data(contentsOf: labFixtures.appendingPathComponent("ocr-noisy.synthetic.txt"))
        var s = try session(try await imp.importFile(data, kind: .pdf, fileExtension: "PDF"))
        #expect(files.names.count == 1 && files.names[0].hasSuffix(".pdf"))
        #expect(s.collectedOn?.description == "2025-11-20")
        #expect(!s.canSave)

        // Saving with undecided rows is refused (no "confirm all").
        await #expect(throws: LabReviewError.rowsStillPending(s.rows.count)) { try await imp.save(s) }
        #expect(try repo.panels().isEmpty)

        let ids = s.rows.map(\.id)
        s.reject(ids[0])
        s.edit(ids[1], value: 11.0, unit: "uIU/mL", analyteKey: "insulin")
        for id in ids.dropFirst(2) { s.confirm(id) }
        #expect(s.canSave)
        let panel = try await imp.save(s)

        let stored = try repo.results(panelID: panel.id)
        #expect(stored.count == ids.count - 1)
        #expect(stored.allSatisfy { $0.userConfirmed })
        #expect(stored.first { $0.analyteCanonical == "insulin" }?.userEdited == true)
        #expect(stored.first { $0.analyteCanonical == "insulin" }?.valueNumeric == 11.0)
        #expect(!stored.contains { $0.analyteCanonical == "glucose" }, "rejected row not stored")
        #expect(panel.collectedOn.description == "2025-11-20")
        #expect(try repo.document(sha256: SHA256Digest.hex(data))?.status == .confirmed)

        // Same bytes again: duplicate, nothing new stored.
        guard case .duplicate = try await imp.importFile(data, kind: .pdf, fileExtension: "pdf") else {
            Issue.record("expected duplicate"); return
        }
        #expect(try repo.panels().count == 1)
    }

    @Test func missingCollectionDateBlocksSave() async throws {
        let repo = InMemoryLabRepository(), files = InMemoryLabFileStore()
        var s = try session(try await importer(repo, files).importFile(Data("Glucose 90 mg/dL 65-99".utf8), kind: .pdf, fileExtension: "pdf"))
        s.confirm(s.rows[0].id)
        #expect(throws: LabReviewError.missingCollectionDate) { _ = try s.makeRecords(now: Date()) }
        s.collectedOn = LocalDay(string: "2026-01-02")
        #expect(s.canSave)
    }

    @Test func discardDeletesStoredCopyAndAllowsReReview() async throws {
        let repo = InMemoryLabRepository(), files = InMemoryLabFileStore()
        let imp = importer(repo, files)
        let data = Data("Glucose 90 mg/dL 65-99".utf8)
        let s = try session(try await imp.importFile(data, kind: .pdf, fileExtension: "pdf"))
        try await imp.discard(s)
        #expect(files.names.isEmpty)
        #expect(try repo.document(sha256: SHA256Digest.hex(data))?.status == .rejected)
        _ = try session(try await imp.importFile(data, kind: .pdf, fileExtension: "pdf"))
        #expect(try repo.documents().count == 1, "re-import reuses the same document row")
    }

    @Test func repositoryRejectsUnconfirmedResults() {
        let repo = InMemoryLabRepository()
        let panel = LabPanel(collectedOn: LocalDay(string: "2026-01-01")!, sourceDocumentID: nil, confirmedAt: Date())
        let r = LabResult(panelID: panel.id, analyteRaw: "Glucose", analyteCanonical: "glucose", loinc: nil, valueNumeric: 90, valueText: nil,
                          unitRaw: "mg/dL", unitCanonical: "mg/dL", valueCanonical: 90, refLow: nil, refHigh: nil, refText: nil,
                          flagFromReport: nil, extractionConfidence: 1, page: 1, userConfirmed: false, userEdited: false)
        #expect(throws: LabRepositoryError.unconfirmedResult) { try repo.saveConfirmed(panel: panel, results: [r]) }
    }
}
