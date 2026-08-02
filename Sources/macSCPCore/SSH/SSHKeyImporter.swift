import Foundation

/// Inspects an existing OpenSSH private key file so the app can import it as a
/// managed key (M18). Shells out to the system `ssh-keygen` (argument array,
/// never a shell string) to derive the public key (`-y`). Reads only —
/// copying the file into the key store and creating the `ManagedKey`/Keychain
/// entry is the app's job (it owns the id/name/comment).
///
/// The passphrase is passed via `-P` in the argument array (never a shell
/// string) — it is briefly visible in the process's argv to the same user via
/// `ps`, the same accepted minor `SSHKeyGenerator` documents for its own `-N`.
public enum SSHKeyImporter {
    public struct ImportedKeyInfo: Equatable, Sendable {
        public let type: KeyType
        public let fingerprint: String
        public let publicKeyOpenSSH: String
    }

    public enum SSHKeyImportError: Error, Equatable {
        case unreadable
        case unsupportedOrEncrypted
        case toolMissing
    }

    public static func inspect(privateKeyURL: URL, passphrase: String?) throws -> ImportedKeyInfo {
        let tool = "/usr/bin/ssh-keygen"
        guard FileManager.default.isExecutableFile(atPath: tool) else {
            throw SSHKeyImportError.toolMissing
        }
        // Public key via `ssh-keygen -y -P <pass> -f <file>` (stdout).
        let pub = try run(tool, ["-y", "-P", passphrase ?? "", "-f", privateKeyURL.path(percentEncoded: false)])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard pub.contains(" ") else { throw SSHKeyImportError.unsupportedOrEncrypted }
        // Fingerprint derived from the SAME `-y` output above (never a
        // separate `ssh-keygen -l -f <file>` call, which prefers a sibling
        // `.pub` file over the private key — if that `.pub` is stale/foreign
        // it would silently report a different key's fingerprint). Mirrors
        // `SSHKeyGenerator.fingerprint(fromOpenSSHPublicKey:)` exactly, so
        // there is only one derivation path for both generate and import.
        let parts = pub.split(separator: " ")
        guard parts.count >= 2,
              let fingerprint = HostKeyFingerprint.sha256(ofKeyBlobBase64: String(parts[1]))
        else {
            throw SSHKeyImportError.unreadable
        }
        guard let type = keyType(fromOpenSSHPublicKey: pub) else {
            throw SSHKeyImportError.unsupportedOrEncrypted
        }
        return ImportedKeyInfo(
            type: type,
            fingerprint: fingerprint,
            publicKeyOpenSSH: pub)
    }

    private static func run(_ tool: String, _ args: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { throw SSHKeyImportError.toolMissing }
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw SSHKeyImportError.unsupportedOrEncrypted }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        guard let s = String(data: data, encoding: .utf8) else { throw SSHKeyImportError.unreadable }
        return s
    }

    /// `nil` for any OpenSSH key type macSCP doesn't model (e.g. `ssh-dss`,
    /// `sk-ssh-ed25519@openssh.com`) — the caller turns that into
    /// `.unsupportedOrEncrypted` rather than mislabeling an unknown type as
    /// RSA. `KeyType` intentionally gets no new case here: `.rsa`/`.ecdsa`
    /// are exhaustively switched over in the picker/badge/`isConnectable`
    /// call sites, and none of them need to distinguish "unsupported" from
    /// the types already known.
    private static func keyType(fromOpenSSHPublicKey line: String) -> KeyType? {
        if line.hasPrefix("ssh-ed25519") { return .ed25519 }
        if line.hasPrefix("ecdsa-") { return .ecdsa }
        if line.hasPrefix("ssh-rsa") { return .rsa(bits: 0) }   // bits unknown from the public line; not connect-relevant
        return nil
    }
}
