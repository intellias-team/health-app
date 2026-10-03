import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

/// RFC 7636 PKCE helpers.
public enum PKCE {
    /// 64-character URL-safe random verifier.
    public static func makeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 48)
        var rng = SystemRandomNumberGenerator()
        for i in bytes.indices { bytes[i] = UInt8.random(in: 0...255, using: &rng) }
        return base64URL(Data(bytes))
    }

    public static func makeState() -> String {
        var rng = SystemRandomNumberGenerator()
        return base64URL(Data((0..<16).map { _ in UInt8.random(in: 0...255, using: &rng) }))
    }

    #if canImport(CryptoKit)
    /// S256 challenge = BASE64URL(SHA256(verifier)).
    public static func challenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }
    #endif

    public static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Decodes the (unverified) payload of a JWT — used only to read `sub`/`email`/`exp` from tokens we
    /// just received over TLS from Cognito. The API Gateway authorizer verifies signatures server-side.
    public static func jwtClaims(_ jwt: String) -> [String: Any]? {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var s = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s += "=" }
        guard let data = Data(base64Encoded: s) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
