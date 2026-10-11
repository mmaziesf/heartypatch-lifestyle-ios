import Foundation
import Testing
import HPLCore
@testable import HPLStore

@Suite struct ConsentRepositoryTests {
    @Test func disclaimerAcknowledgementPersistsAcrossInstances() throws {
        let suite = "hpl.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        #expect(try UserDefaultsConsentRepository(defaults: defaults).active(.disclaimer, version: Disclaimer.version) == nil)
        let ack = Consent(scope: .disclaimer, version: Disclaimer.version, grantedAt: Date(timeIntervalSince1970: 1_791_000_000))
        try UserDefaultsConsentRepository(defaults: defaults).save(ack)

        let reopened = UserDefaultsConsentRepository(defaults: defaults)
        #expect(try reopened.active(.disclaimer, version: Disclaimer.version) == ack)
        #expect(try reopened.active(.disclaimer, version: "disclaimer-v2") == nil, "new copy version requires re-acknowledgement")
    }

    @Test func revokedConsentIsNotActive() throws {
        let repo = InMemoryConsentRepository()
        var c = Consent(scope: .cloudAnalysis, version: "cloud-v1", grantedAt: Date())
        try repo.save(c)
        c.revokedAt = Date()
        try repo.save(c)
        #expect(try repo.all().count == 1)
        #expect(try repo.active(.cloudAnalysis, version: "cloud-v1") == nil)
    }
}
