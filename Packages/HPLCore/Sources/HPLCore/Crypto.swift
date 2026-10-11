import Foundation

/// Portable SHA-256 (FIPS 180-4) for lab-file dedupe and event signatures; no crypto dependency, so it runs on Linux too.
public enum SHA256Digest {
    private static let k: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    ]

    public static func hex(_ data: Data) -> String { digest(data).map { String(format: "%02x", $0) }.joined() }

    public static func digest(_ data: Data) -> [UInt8] {
        var h: [UInt32] = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19]
        var msg = [UInt8](data)
        let bitLength = UInt64(msg.count) * 8
        msg.append(0x80)
        while msg.count % 64 != 56 { msg.append(0) }
        for i in (0..<8).reversed() { msg.append(UInt8((bitLength >> (UInt64(i) * 8)) & 0xff)) }
        var w = [UInt32](repeating: 0, count: 64)
        for chunk in stride(from: 0, to: msg.count, by: 64) {
            for i in 0..<16 {
                let b = chunk + i * 4
                w[i] = UInt32(msg[b]) << 24 | UInt32(msg[b + 1]) << 16 | UInt32(msg[b + 2]) << 8 | UInt32(msg[b + 3])
            }
            for i in 16..<64 {
                let s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >> 3)
                let s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >> 10)
                w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
            }
            var v = h
            for i in 0..<64 {
                let s1 = rotr(v[4], 6) ^ rotr(v[4], 11) ^ rotr(v[4], 25)
                let ch = (v[4] & v[5]) ^ (~v[4] & v[6])
                let t1 = v[7] &+ s1 &+ ch &+ k[i] &+ w[i]
                let s0 = rotr(v[0], 2) ^ rotr(v[0], 13) ^ rotr(v[0], 22)
                let maj = (v[0] & v[1]) ^ (v[0] & v[2]) ^ (v[1] & v[2])
                let t2 = s0 &+ maj
                v = [t1 &+ t2, v[0], v[1], v[2], v[3] &+ t1, v[4], v[5], v[6]]
            }
            for i in 0..<8 { h[i] = h[i] &+ v[i] }
        }
        return h.flatMap { word in (0..<4).reversed().map { UInt8((word >> (UInt32($0) * 8)) & 0xff) } }
    }

    private static func rotr(_ x: UInt32, _ n: UInt32) -> UInt32 { (x >> n) | (x << (32 - n)) }
}

/// HMAC-SHA256 (RFC 2104) for `hpl.signed_event.v1` (architecture §8.2).
public enum HMACSHA256 {
    public static func mac(key: [UInt8], message: Data) -> [UInt8] {
        var k = key.count > 64 ? SHA256Digest.digest(Data(key)) : key
        k += [UInt8](repeating: 0, count: 64 - k.count)
        let inner = SHA256Digest.digest(Data(k.map { $0 ^ 0x36 }) + message)
        return SHA256Digest.digest(Data(k.map { $0 ^ 0x5c } + inner))
    }

    public static func hex(key: [UInt8], message: Data) -> String { mac(key: key, message: message).map { String(format: "%02x", $0) }.joined() }

    /// Constant-time comparison of two hex strings (case-insensitive), so timing doesn't leak how much of a signature matched.
    public static func equal(_ a: String, _ b: String) -> Bool {
        let x = Array(a.lowercased().utf8), y = Array(b.lowercased().utf8)
        guard x.count == y.count else { return false }
        return zip(x, y).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
}

/// base64url without padding (RFC 4648 §5), used in the pairing QR payload.
public enum Base64URL {
    public static func encode(_ bytes: [UInt8]) -> String {
        Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public static func decode(_ s: String) -> [UInt8]? {
        var t = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while t.count % 4 != 0 { t += "=" }
        return Data(base64Encoded: t).map { [UInt8]($0) }
    }
}
