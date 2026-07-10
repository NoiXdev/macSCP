import Crypto
import Foundation

/// OpenSSH-compatible SHA256 fingerprints ("SHA256:" + Base64 without padding).
public enum HostKeyFingerprint {
    public static func sha256(ofKeyBlobBase64 keyBlobBase64: String) -> String? {
        guard let raw = Data(base64Encoded: keyBlobBase64) else { return nil }
        let digest = SHA256.hash(data: raw)
        let b64 = Data(digest).base64EncodedString()
            .trimmingCharacters(in: CharacterSet(charactersIn: "="))
        return "SHA256:" + b64
    }
}
