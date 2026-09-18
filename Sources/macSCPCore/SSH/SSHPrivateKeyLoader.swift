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
    /// A PEM file `PEMPrivateKeyDecoder` opened far enough to NAME what
    /// stops it — a cipher the stack does not carry, a password scheme that
    /// is not PBES2, a key algorithm this loader does not build, a PuTTY
    /// file, or contents that do not parse.
    ///
    /// The payload is one of the decoder's own constants and never a
    /// substring of the file (see `PEMReadFailure`), because it reaches a
    /// user-visible message and the command the failure surface offers.
    case pemNotReadable(PEMReadFailure)
    /// The key needed a passphrase, and the one place it could have come
    /// from could not be looked at: the key lies in the managed key
    /// directory, and `managed_keys.json` could not be read.
    ///
    /// Never thrown by this loader, which only knows that no passphrase
    /// came: it is `passphraseRequired` renamed after the dial, by
    /// `ManagedKeyPassphraseSecretSource.namingUnreadableStore(_:in:)`, from
    /// what the secret chain's managed-key link saw when it was asked. No
    /// payload: the finding is the store, and the store has one name.
    case managedKeyStoreUnreadable
}

/// Loads private SSH keys — ed25519, RSA and ECDSA on all three NIST
/// curves, each optionally encrypted — from OpenSSH's own container via
/// Citadel's parser, and from PEM files via `PEMPrivateKeyDecoder`.
///
/// RSA is offered under the RFC 8332 SHA-2 signature algorithms only; see
/// `authentication(username:keyPath:passphrase:)` for why the SHA-1
/// fallback is passed explicitly. PEM is PARSED since 2026-09-10 (PEM
/// private keys plan); what the PEM reader cannot open it names
/// (`pemNotReadable`), as do key types Citadel does not model (DSA, FIDO
/// `sk-*`, certificates).
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

        // A PEM file — anything with a `-----BEGIN` boundary that is not
        // OpenSSH's own, plus a PuTTY file — goes to the PEM reader. This is
        // exactly the set the boundary check standing here until 2026-09-10
        // turned away unread.
        if PEMPrivateKeyDecoder.isPEM(contents) {
            let decoded = try Self.decodePEM(contents, passphrase: passphrase)
            do {
                return try Self.authentication(username: username, decoded: decoded)
            } catch {
                // The decoder said the file holds a key of this shape and
                // the key type's own initialiser disagreed — a scalar of the
                // wrong length, a container Citadel's parser refuses. Not a
                // FEATURE the reader lacks, so not `pemNotReadable`: the
                // same verdict the OpenSSH path gives a file it cannot make
                // a key out of.
                throw SSHKeyError.unsupportedFormat(reason: String(describing: error))
            }
        }

        // Name the key before parsing it. The openssh-key-v1 header is cleartext
        // even when the private half is encrypted, so a key type this loader
        // cannot use is reported as itself before anyone is asked for a
        // passphrase that could never have helped.
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

    /// `PEMPrivateKeyDecoder.decode` with its errors in this type's
    /// vocabulary.
    ///
    /// The two passphrase verdicts keep their meaning across the two
    /// readers, which is what lets `ConnectionViewModel.failureKind(for:)`
    /// go on classifying them as `.needsPerson` without knowing which reader
    /// produced them. `.notPEM` cannot arise from a call the `isPEM` guard
    /// let through — the decoder throws it only for OpenSSH's own label —
    /// and is mapped rather than force-unwrapped away.
    ///
    /// An EMPTY passphrase means "no passphrase", the same normalisation the
    /// OpenSSH path does above: the decoder takes `nil` as the absence and
    /// would otherwise derive a key from the empty string and report a wrong
    /// passphrase where the honest answer is that one is needed.
    private static func decodePEM(
        _ contents: String, passphrase: String?
    ) throws -> PEMPrivateKeyDecoder.DecodedPrivateKey {
        let effective = passphrase.flatMap { $0.isEmpty ? nil : $0 }
        do {
            return try PEMPrivateKeyDecoder.decode(contents, passphrase: effective)
        } catch PEMPrivateKeyDecoder.DecodeError.passphraseRequired {
            throw SSHKeyError.passphraseRequired
        } catch PEMPrivateKeyDecoder.DecodeError.wrongPassphrase {
            throw SSHKeyError.wrongPassphrase
        } catch PEMPrivateKeyDecoder.DecodeError.notReadable(let failure) {
            throw SSHKeyError.pemNotReadable(failure)
        } catch PEMPrivateKeyDecoder.DecodeError.notPEM {
            throw SSHKeyError.unsupportedFormat(reason: "not PEM")
        }
    }

    /// The decoded material as an authentication method — the same five
    /// factories the OpenSSH path dispatches to (ed25519, RSA, and one per
    /// NIST curve; counted 2026-09-10 in both switches), reached from
    /// components instead of from a file.
    ///
    /// RSA takes the detour through `OpenSSHKeyContainer.unencryptedRSA`
    /// because Citadel's `Insecure.RSA.PrivateKey` has no component
    /// initialiser reachable from outside its module (design, "Feeding the
    /// keys to a connection"). The container exists in memory for the length
    /// of this call and is written nowhere.
    private static func authentication(
        username: String, decoded: PEMPrivateKeyDecoder.DecodedPrivateKey
    ) throws -> SSHAuthenticationMethod {
        switch decoded {
        case .rsa(let components):
            // `includeSHA1Fallback` is passed EXPLICITLY here for the same
            // reason as on the OpenSSH path above — see that call's comment.
            // `SSHPrivateKeyLoaderTests.pemRSAKeyOffersSHA2Only` is this
            // call's own pin.
            return .rsaSHA2(
                username: username,
                privateKey: try Insecure.RSA.PrivateKey(
                    sshRsa: OpenSSHKeyContainer.unencryptedRSA(components, comment: "")),
                includeSHA1Fallback: false)
        case .ecdsa(.p256, let scalar):
            return .p256(username: username,
                         privateKey: try P256.Signing.PrivateKey(rawRepresentation: scalar))
        case .ecdsa(.p384, let scalar):
            return .p384(username: username,
                         privateKey: try P384.Signing.PrivateKey(rawRepresentation: scalar))
        case .ecdsa(.p521, let scalar):
            return .p521(username: username,
                         privateKey: try P521.Signing.PrivateKey(rawRepresentation: scalar))
        case .ed25519(let seed):
            return .ed25519(username: username,
                            privateKey: try Curve25519.Signing.PrivateKey(rawRepresentation: seed))
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
