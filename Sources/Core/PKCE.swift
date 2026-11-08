import CryptoKit
import Foundation
import Security

/// RFC 7636 PKCE helpers (S256).
enum PKCE {
    static func verifier() -> String {
        randomURLSafe(byteCount: 48)
    }

    static func state() -> String {
        randomURLSafe(byteCount: 32)
    }

    static func challenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return Data(digest).base64URLString()
    }

    private static func randomURLSafe(byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes)
        precondition(status == errSecSuccess, "Unable to generate secure random bytes")
        return Data(bytes).base64URLString()
    }
}

extension Data {
    func base64URLString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
