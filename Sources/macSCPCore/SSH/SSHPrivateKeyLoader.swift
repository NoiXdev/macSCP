import Citadel
import Crypto
import Foundation

/// Typed errors when loading private SSH keys.
public enum SSHKeyError: Error, Equatable, Sendable {
    case fileNotFound(path: String)
    case passphraseRequired
    case wrongPassphrase
    case unsupportedFormat(reason: String)
    /// An `openssh-key-v1` file holding a key type this loader cannot hand to
    /// a connection. `algorithm` is the type's own wire name as
    /// `SSHKeyDetection` read it out of the container's cleartext header
    /// (e.g. `ssh-dss`, `sk-ssh-ed25519@openssh.com`), because that is the
    /// only name available for a type Citadel does not model.
    case typeNotLoadable(algorithm: String)
    /// The file begins with a PEM boundary other than
    /// `-----BEGIN OPENSSH PRIVATE KEY-----`.
    case pemNotSupported
}

/// Loads private OpenSSH keys — ed25519, RSA and ECDSA on all three NIST
/// curves, each optionally encrypted — via Citadel's parser.
///
/// RSA is offered under the RFC 8332 SHA-2 signature algorithms only; see
/// `authentication(username:keyPath:passphrase:)` for why the SHA-1
/// fallback is passed explicitly. PEM-format files and key types Citadel
/// does not model (DSA, FIDO `sk-*`, certificates) are named rather than
/// parsed.
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

        // Name the key before parsing it. The openssh-key-v1 header is cleartext
        // even when the private half is encrypted, so a key type this loader
        // cannot use is reported as itself before anyone is asked for a
        // passphrase that could never have helped.
        let trimmed = contents.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("-----BEGIN ") && !trimmed.hasPrefix("-----BEGIN OPENSSH PRIVATE KEY-----") {
            throw SSHKeyError.pemNotSupported
        }

        let type: SSHKeyType
        do {
            type = try SSHKeyDetection.detectPrivateKeyType(from: contents)
        } catch SSHKeyDetectionError.unsupportedKeyType(let name) {
            // The header parsed and named a type Citadel does not model —
            // DSA, a FIDO `sk-*` key, a certificate. The wire name is the one
            // thing the person holding the file can act on, so it survives.
            throw SSHKeyError.typeNotLoadable(algorithm: name ?? "")
        } catch {
            throw SSHKeyError.unsupportedFormat(reason: String(describing: error))
        }

        // Empty passphrase == no passphrase (unencrypted key).
        let decryptionKey = passphrase.flatMap { $0.isEmpty ? nil : Data($0.utf8) }
        do {
            switch type {
            case .ed25519:
                return .ed25519(username: username, privateKey: try Curve25519.Signing.PrivateKey(
                    sshEd25519: contents, decryptionKey: decryptionKey))
            case .rsa:
                // `includeSHA1Fallback` is passed EXPLICITLY, never left to the
                // default. The default is `false` in the NoiXdev fork and `true`
                // upstream, so a rebase onto a merged upstream PR #135 would
                // otherwise start signing with SHA-1 here without a diff.
                // `SSHPrivateKeyLoaderTests.rsaKeyOffersSHA2Only` is the pin.
                return .rsaSHA2(username: username, privateKey: try Insecure.RSA.PrivateKey(
                    sshRsa: contents, decryptionKey: decryptionKey), includeSHA1Fallback: false)
            case .ecdsaP256:
                return .p256(username: username, privateKey: try P256.Signing.PrivateKey(
                    sshEcdsa: contents, decryptionKey: decryptionKey))
            case .ecdsaP384:
                return .p384(username: username, privateKey: try P384.Signing.PrivateKey(
                    sshEcdsa: contents, decryptionKey: decryptionKey))
            case .ecdsaP521:
                return .p521(username: username, privateKey: try P521.Signing.PrivateKey(
                    sshEcdsa: contents, decryptionKey: decryptionKey))
            default:
                // `SSHKeyType` is a struct, not an enum, precisely so Citadel
                // can add algorithms without a source break — which means this
                // arm is reachable the day it does. Name the type rather than
                // guess at a parser for it.
                throw SSHKeyError.typeNotLoadable(algorithm: type.rawValue)
            }
        } catch let error as SSHKeyError {
            throw error
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
    ///
    /// One mapping serves all five key types: decryption happens once in
    /// Citadel's shared `openssh-key-v1` reader, before the key type is
    /// dispatched. Measured 2026-09-02 on a passphrase-protected key of each
    /// of RSA, ECDSA P-256 and ed25519: no passphrase gives
    /// `OpenSSH.KeyError.missingDecryptionKey`, a wrong one gives
    /// `InvalidOpenSSHKey(reason: "invalidCheck")` — identical strings for all
    /// three.
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
