import Citadel
import Crypto
import Foundation

/// Typed errors when loading private SSH keys.
public enum SSHKeyError: Error, Equatable, Sendable {
    case fileNotFound(path: String)
    case passphraseRequired
    case wrongPassphrase
    case unsupportedFormat(reason: String)
}

/// Loads private OpenSSH keys (M3b: ed25519, optionally encrypted) via
/// Citadel's parser. RSA/ecdsa and ssh-agent are deliberately deferred (YAGNI).
public enum SSHPrivateKeyLoader {
    public static func authentication(
        username: String, keyPath: String, passphrase: String?
    ) throws -> SSHAuthenticationMethod {
        let expanded = NSString(string: keyPath).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: expanded) else {
            throw SSHKeyError.fileNotFound(path: keyPath)
        }

        let contents: String
        do {
            contents = try String(contentsOfFile: expanded, encoding: .utf8)
        } catch {
            throw SSHKeyError.unsupportedFormat(reason: String(describing: error))
        }

        // Empty passphrase == no passphrase (unencrypted key).
        let decryptionKey = passphrase.flatMap { $0.isEmpty ? nil : Data($0.utf8) }
        do {
            let key = try Curve25519.Signing.PrivateKey(
                sshEd25519: contents, decryptionKey: decryptionKey)
            return .ed25519(username: username, privateKey: key)
        } catch {
            throw Self.map(error, hadPassphrase: decryptionKey != nil)
        }
    }

    /// Translates Citadel's parser errors into `SSHKeyError`.
    ///
    /// Citadel doesn't throw publicly distinguishable enum cases for the
    /// OpenSSH parser: the internal `OpenSSH.KeyError` (among others
    /// `missingDecryptionKey`) is `internal`, and while `InvalidOpenSSHKey` is
    /// `public`, its `reason` field is `internal`. We therefore evaluate the
    /// stable, hard-coded `reason` strings via `String(describing:)`:
    ///  - `missingDecryptionKey` → the key is encrypted, no passphrase given.
    ///  - `invalidCheck`/`invalidPadding`/crypto errors given a passphrase
    ///    → wrong passphrase (decryption produced garbage).
    ///  - everything else (`invalidOpenSSHBoundary`, `invalidBase64Payload`, …)
    ///    → unsupported/broken format.
    private static func map(_ error: Error, hadPassphrase: Bool) -> SSHKeyError {
        let text = String(describing: error).lowercased()

        // Encrypted key, but no passphrase supplied.
        if text.contains("missingdecryptionkey") {
            return .passphraseRequired
        }

        // Decryption-specific errors.
        if text.contains("invalidcheck") || text.contains("invalidpadding")
            || text.contains("crypto") || text.contains("decrypt")
            || text.contains("cipher") || text.contains("passphrase")
            || text.contains("encrypted") {
            return hadPassphrase ? .wrongPassphrase : .passphraseRequired
        }

        return .unsupportedFormat(reason: String(describing: error))
    }
}
