import Foundation
import Testing
import HPLCore
@testable import HPLCloud

@Test func egressIsUnreachableInM0() {
    #expect(throws: EgressGate.EgressError.consentMissing) { try EgressGate.authorize(consents: []) }
    let c = Consent(scope: .cloudAnalysis, version: "cloud-v1", grantedAt: Date())
    #expect(throws: EgressGate.EgressError.disabled) { try EgressGate.authorize(consents: [c]) }
}
