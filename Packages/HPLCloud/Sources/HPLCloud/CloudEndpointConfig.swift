import Foundation
import HPLCore

/// Where cloud analysis goes, from build settings (docs/m8-cloud-endpoint.md).
///
/// Info.plist keys (set via project.yml build settings `HPL_CLOUD_ENDPOINT` / `HPL_CLOUD_PINS`):
/// - `HPLCloudEndpoint`: full https URL of `POST /v1/analyze`. Empty → the on-device demo analyzer (nothing leaves).
/// - `HPLCloudPublicKeyPins`: comma/space separated base64 pins from `hpl-cloud pin chain.pem`. At least one; ship two
///   (current key + a pre-generated backup key) so a key rotation doesn't strand installed apps.
///
/// This is deliberately a build-time setting, not a Settings field: a user can't be talked into pointing their health
/// summaries at an arbitrary server.
public struct CloudEndpointConfig: Equatable, Sendable {
    public static let endpointKey = "HPLCloudEndpoint"
    public static let pinsKey = "HPLCloudPublicKeyPins"

    public let endpoint: URL
    public let pins: Set<String>

    /// `nil` (use the demo analyzer) unless the endpoint is https with a host, no user/password/query/fragment, and at
    /// least one well-formed pin is present.
    public init?(endpoint rawEndpoint: String?, pins rawPins: String?) {
        let trimmed = (rawEndpoint ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = URL(string: trimmed), url.scheme == "https", let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else { return nil }
        let pins = Set((rawPins ?? "").split(whereSeparator: { $0 == "," || $0 == " " || $0 == "\n" }).map(String.init)
            .filter { Data(base64Encoded: $0)?.count == 32 })
        guard !pins.isEmpty else { return nil }
        endpoint = url
        self.pins = pins
    }

    /// Reads the two Info.plist keys. Unexpanded `$(VAR)` placeholders count as unset.
    public init?(info: [String: Any]) {
        func value(_ key: String) -> String? {
            guard let s = info[key] as? String, !s.hasPrefix("$(") else { return nil }
            return s
        }
        self.init(endpoint: value(Self.endpointKey), pins: value(Self.pinsKey))
    }
}

/// Optional App Attest hook. Returns the headers that prove this request comes from a genuine install of the app,
/// signed over `clientDataHash` = SHA-256 of the exact body (the hash the user approved on the preview screen).
/// The server contract is `X-HPL-Attest-Key-ID` + `X-HPL-Attest-Assertion` (base64). Not implemented on device yet:
/// it needs a key-registration round trip (docs/m8-cloud-endpoint.md, "Deploy gaps").
public protocol CloudAttestationProvider: Sendable {
    func headers(clientDataHash: Data) async throws -> [String: String]
}

public enum CloudAttestationHeader {
    public static let keyID = "X-HPL-Attest-Key-ID"
    public static let assertion = "X-HPL-Attest-Assertion"
}

public enum CloudTransports {
    /// The configured HTTPS transport, or the on-device demo when nothing (valid) is configured.
    public static func make(config: CloudEndpointConfig?, attestation: (any CloudAttestationProvider)? = nil) -> any CloudTransport {
        #if canImport(Security)
        if let config, let t = HTTPSCloudTransport(endpoint: config.endpoint, publicKeyPins: config.pins, attestation: attestation) {
            return t
        }
        #endif
        return DemoCloudTransport()
    }

    /// From the main bundle's Info.plist.
    public static func fromMainBundle() -> any CloudTransport {
        make(config: CloudEndpointConfig(info: Bundle.main.infoDictionary ?? [:]))
    }
}
