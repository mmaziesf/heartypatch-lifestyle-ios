import Testing
@testable import HPLIngest

@Test func onlyConfirmedIsUsable() {
    #expect(LabIngest.isUsable(.confirmed))
    #expect(![.pending, .extracted, .rejected].contains { LabIngest.isUsable($0) })
}
