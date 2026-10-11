import Foundation
import Testing
import HPLCore
@testable import HPLCloud

@Suite struct CloudEndpointConfigTests {
    let pinA = Data(repeating: 1, count: 32).base64EncodedString()
    let pinB = Data(repeating: 2, count: 32).base64EncodedString()

    @Test func emptyOrPlaceholderSettingsMeanDemo() {
        #expect(CloudEndpointConfig(info: [:]) == nil)
        #expect(CloudEndpointConfig(info: ["HPLCloudEndpoint": "", "HPLCloudPublicKeyPins": ""]) == nil)
        #expect(CloudEndpointConfig(info: ["HPLCloudEndpoint": "$(HPL_CLOUD_ENDPOINT)", "HPLCloudPublicKeyPins": pinA]) == nil)
        #expect(!CloudTransports.make(config: nil).leavesDevice)
        #expect(CloudTransports.make(config: nil).id == "demo-on-device")
    }

    @Test func requiresHTTPSHostAndAWellFormedPin() {
        let ok = "https://cloud.example.com/v1/analyze"
        #expect(CloudEndpointConfig(endpoint: "http://cloud.example.com/v1/analyze", pins: pinA) == nil)
        #expect(CloudEndpointConfig(endpoint: "https:///v1/analyze", pins: pinA) == nil)
        #expect(CloudEndpointConfig(endpoint: "https://u:p@cloud.example.com/v1/analyze", pins: pinA) == nil)
        #expect(CloudEndpointConfig(endpoint: ok + "?user=arash", pins: pinA) == nil)
        #expect(CloudEndpointConfig(endpoint: ok, pins: "") == nil)
        #expect(CloudEndpointConfig(endpoint: ok, pins: "not-a-pin, AAAA") == nil)
        let c = CloudEndpointConfig(info: ["HPLCloudEndpoint": " \(ok) ", "HPLCloudPublicKeyPins": "\(pinA), \(pinB),junk"])
        #expect(c?.endpoint.absoluteString == ok)
        #expect(c?.pins == [pinA, pinB])
    }

    #if canImport(Security)
    @Test func configuredEndpointUsesPinnedHTTPS() throws {
        let c = try #require(CloudEndpointConfig(endpoint: "https://cloud.example.com/v1/analyze", pins: pinA))
        let t = CloudTransports.make(config: c)
        #expect(t.leavesDevice && t.id == "https:cloud.example.com")
    }

    @Test func attestationHeadersAreTheOnlyExtras() {
        let r = HTTPSCloudTransport.request(endpoint: URL(string: "https://example.com/a")!, body: Data("{}".utf8), requestID: "abc",
                                            extraHeaders: [CloudAttestationHeader.keyID: "k", CloudAttestationHeader.assertion: "a",
                                                           "Authorization": "Bearer x", "Cookie": "s=1"])
        #expect(Set(r.allHTTPHeaderFields?.keys.map { $0 } ?? [])
            == ["Content-Type", "Accept", "X-HPL-Request-ID", CloudAttestationHeader.keyID, CloudAttestationHeader.assertion])
    }
    #endif
}
