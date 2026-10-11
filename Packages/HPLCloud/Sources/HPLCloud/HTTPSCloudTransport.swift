#if canImport(Security)
import Foundation
import Security
import HPLCore

/// Real network transport (§10): HTTPS POST to a stateless endpoint, TLS 1.3, public-key pinned, ephemeral session
/// (no cookies, no cache, no credentials), no user/device id, a per-request random id only.
/// This is the ONLY file in the app that may use networking for health-derived data (scripts/check_egress_boundary.sh).
/// The app ships without an endpoint configured, so `DemoCloudTransport` is used; see docs/m6-cloud.md.
public final class HTTPSCloudTransport: NSObject, CloudTransport, URLSessionDelegate, @unchecked Sendable {
    public let id: String
    public let leavesDevice = true
    let endpoint: URL
    /// Base64 SHA-256 of a certificate public key in the server chain (`SecKeyCopyExternalRepresentation` bytes).
    let pins: Set<String>
    private var session: URLSession?

    public enum TransportError: Error, Equatable { case status(Int), notJSON, tooLarge }

    /// `nil` unless the endpoint is https with a host and at least one pin is given.
    public init?(endpoint: URL, publicKeyPins: Set<String>) {
        guard endpoint.scheme == "https", endpoint.host != nil, !publicKeyPins.isEmpty else { return nil }
        self.endpoint = endpoint
        self.pins = publicKeyPins
        id = "https:\(endpoint.host ?? "")"
        super.init()
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieAcceptPolicy = .never
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.urlCredentialStorage = nil
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.tlsMinimumSupportedProtocolVersion = .TLSv13
        config.timeoutIntervalForRequest = 30
        config.waitsForConnectivity = false
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    /// The request, without sending it (tested).
    public static func request(endpoint: URL, body: Data, requestID: String) -> URLRequest {
        var r = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 30)
        r.httpMethod = "POST"
        r.httpBody = body
        r.httpShouldHandleCookies = false
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        r.setValue(requestID, forHTTPHeaderField: "X-HPL-Request-ID")
        return r
    }

    public func post(_ body: Data, requestID: String) async throws -> Data {
        guard let session else { throw URLError(.cancelled) }
        let (data, response) = try await session.data(for: Self.request(endpoint: endpoint, body: body, requestID: requestID))
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw TransportError.status((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        guard data.count <= EgressGate.maxResponseBytes else { throw TransportError.tooLarge }
        return data
    }

    public func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge) async
        -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        let space = challenge.protectionSpace
        guard space.authenticationMethod == NSURLAuthenticationMethodServerTrust, space.host == endpoint.host,
              let trust = space.serverTrust, SecTrustEvaluateWithError(trust, nil),
              let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate] else { return (.cancelAuthenticationChallenge, nil) }
        for cert in chain {
            guard let key = SecCertificateCopyKey(cert), let bytes = SecKeyCopyExternalRepresentation(key, nil) as Data? else { continue }
            if pins.contains(Data(SHA256Digest.digest(bytes)).base64EncodedString()) { return (.useCredential, URLCredential(trust: trust)) }
        }
        return (.cancelAuthenticationChallenge, nil)
    }
}
#endif
