import Foundation
import Testing
import HPLCore
import HPLStore
import HPLIngest
@testable import HPLUI

@MainActor @Suite struct LabsModelTests {
    let report = Data("""
    Patient: ZZTEST SYNTHETIC
    Collected: 03/14/2026
    Glucose 105 H mg/dL 65-99
    Ferritin 154 ng/mL
    """.utf8)

    func model() -> (LabsModel, InMemoryLabRepository) {
        let repo = InMemoryLabRepository()
        let importer = LabImporter(repository: repo, files: InMemoryLabFileStore(), extractor: PlainTextExtractor())
        return (LabsModel(services: LabServices(importer: importer, repository: repo)), repo)
    }

    @Test func importReviewEditSaveThenDuplicateNotice() async throws {
        let (m, repo) = model()
        await m.importFile(report, kind: .pdf, fileExtension: "pdf")
        let review = try #require(m.review)
        #expect(review.rows.count == 2)
        #expect(!review.rows.contains { $0.candidate.sourceText.contains("ZZTEST") })

        await m.saveReview()
        #expect(m.notice == "Confirm, edit, or reject the 2 remaining rows first.")
        #expect(try repo.panels().isEmpty)

        #expect(!m.edit(review.rows[0].id, value: "abc", unit: "mg/dL", analyteKey: "glucose"), "garbage value refused")
        #expect(m.edit(review.rows[0].id, value: "104", unit: "mg/dL", analyteKey: "glucose"))
        m.confirm(review.rows[1].id)
        await m.saveReview()
        #expect(m.review == nil)
        #expect(m.panels.count == 1)
        #expect(m.panels[0].results.first { $0.analyteCanonical == "glucose" }?.valueNumeric == 104)

        await m.importFile(report, kind: .pdf, fileExtension: "pdf")
        #expect(m.review == nil)
        #expect(m.notice?.hasPrefix("This report was already imported") == true)
    }

    @Test func unrecognizedFileIsDiscardedWithNotice() async {
        let (m, repo) = model()
        await m.importFile(Data("Just a letter with no results.".utf8), kind: .pdf, fileExtension: "pdf")
        #expect(m.review == nil)
        #expect(m.notice?.hasPrefix("No lab rows were recognized") == true)
        #expect((try? repo.documents().first?.status) == .rejected)
    }

    @Test func copyRestatesTheReportOnly() {
        #expect(LabsModel.rangeText(low: 65, high: 99, text: "65-99") == "Range on report: 65–99")
        #expect(LabsModel.rangeText(low: nil, high: nil, text: nil) == "No range on report")
        #expect(LabsModel.flagText(.high) == "Report marks this H")
        #expect(LabsModel.valueText(8.4, "<8.4", unit: "nmol/L") == "<8.4 nmol/L")
    }
}
