import Foundation
import Testing
import HPLCore
@testable import HPLStore

func checkLabContract(_ repo: any LabRepository) throws {
    let doc = SourceDocument(kind: .pdf, sha256: "abc123", storedFileName: "abc.pdf", importedAt: Date(timeIntervalSince1970: 1_791_000_000),
                             extractor: "plain-text", status: .extracted)
    try repo.saveDocument(doc)
    #expect(try repo.document(sha256: "abc123")?.status == .extracted)
    #expect(try repo.document(sha256: "nope") == nil)

    let panel = LabPanel(collectedOn: LocalDay(string: "2026-03-14")!, sourceDocumentID: doc.id, confirmedAt: Date(timeIntervalSince1970: 1_791_000_100))
    func result(confirmed: Bool) -> LabResult {
        LabResult(panelID: panel.id, analyteRaw: "Glucose", analyteCanonical: "glucose", loinc: "2345-7", valueNumeric: 105, valueText: nil,
                  unitRaw: "mg/dL", unitCanonical: "mg/dL", valueCanonical: 105, refLow: 65, refHigh: 99, refText: "65-99",
                  flagFromReport: .high, extractionConfidence: 1, page: 1, userConfirmed: confirmed, userEdited: false)
    }
    #expect(throws: LabRepositoryError.unconfirmedResult) { try repo.saveConfirmed(panel: panel, results: [result(confirmed: false)]) }
    #expect(try repo.panels().isEmpty)

    let r = result(confirmed: true)
    try repo.saveConfirmed(panel: panel, results: [r])
    #expect(try repo.panels() == [panel])
    #expect(try repo.results(panelID: panel.id) == [r])
    #expect(try repo.document(sha256: "abc123")?.status == .confirmed)
    #expect(try repo.confirmedResults().count == 1)

    try repo.deleteAll()
    #expect(try repo.panels().isEmpty && repo.documents().isEmpty)
}

@Suite struct LabStoreTests {
    @Test func inMemoryContract() throws { try checkLabContract(InMemoryLabRepository()) }

    #if canImport(SwiftData)
    @Test func swiftDataContract() throws { try checkLabContract(try SwiftDataStore.inMemory().labs) }
    #endif
}
