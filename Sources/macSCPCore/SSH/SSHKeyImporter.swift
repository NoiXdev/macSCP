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
        /// A `<file>.pub` sits next to the private key that
        /// `fingerprint(ofPrivateKeyFileAt:)` was asked about. `ssh-keygen -l`
        /// would read THAT file instead of the private one, so the answer
        /// would describe whatever key the sibling holds — refused rather
        /// than reported (see that function's doc comment).
        case publicKeySiblingPresent
    }

    public static func inspect(privateKeyURL: URL, passphrase: String?) throws -> ImportedKeyInfo {
        let tool = "/usr/bin/ssh-keygen"
        guard FileManager.default.isExecutableFile(atPath: tool) else {
            throw SSHKeyImportError.toolMissing
        }
        // Public key via `ssh-keygen -y -P <pass> -f <file>` (stdout).
        let pub = try run(tool, ["-y", "-P", passphrase ?? "", "-f", privateKeyURL.path(percentEncoded: false)])
        // Fingerprint derived from the SAME `-y` output above (never a
        // separate `ssh-keygen -l -f <file>` call, which prefers a sibling
        // `.pub` file over the private key — if that `.pub` is stale/foreign
        // it would silently report a different key's fingerprint). Mirrors
        // `SSHKeyGenerator.fingerprint(fromOpenSSHPublicKey:)` exactly, so
        // there is only one derivation path for both generate and import.
        return try info(fromPublicKeyLine: pub)
    }

    /// The identity encoded in an OpenSSH public key line
    /// (`<type> <base64 blob> [comment]`). Pure: no subprocess, no file
    /// access — so a caller that ALREADY holds the public key line does not
    /// have to shell out (and does not have to put a passphrase into
    /// `ssh-keygen`'s argv) just to learn type and fingerprint.
    ///
    /// This says nothing about any private key: it verifies the line against
    /// itself, not against key material. Prefer `inspect` whenever the
    /// private key can actually be opened.
    ///
    /// The line's two halves are cross-checked against each other: `type` used
    /// to come from the PREFIX TEXT while `fingerprint` came from the BLOB,
    /// with nothing tying them together — so a crafted line could pair an
    /// "ED25519 / connectable" badge with an RSA key's fingerprint. An OpenSSH
    /// key blob names its own algorithm in its first wire field, and the type
    /// is now read from THERE, with the prefix required to agree.
    public static func info(fromPublicKeyLine line: String) throws -> ImportedKeyInfo {
        let pub = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard pub.contains(" ") else { throw SSHKeyImportError.unsupportedOrEncrypted }
        let parts = pub.split(separator: " ")
        guard parts.count >= 2,
              let fingerprint = HostKeyFingerprint.sha256(ofKeyBlobBase64: String(parts[1])),
              let algorithm = algorithmName(inKeyBlobBase64: String(parts[1])),
              algorithm == String(parts[0])
        else {
            throw SSHKeyImportError.unreadable
        }
        guard let type = keyType(forAlgorithmName: algorithm) else {
            throw SSHKeyImportError.unsupportedOrEncrypted
        }
        return ImportedKeyInfo(
            type: type,
            fingerprint: fingerprint,
            publicKeyOpenSSH: pub)
    }

    /// The fingerprint of the public key an `openssh-key-v1` FILE carries in
    /// CLEARTEXT — present even when the private half is encrypted, which is
    /// why `ssh-keygen -l -f <file>` answers with no passphrase, no prompt and
    /// no secret anywhere in argv.
    ///
    /// This is the only thing that ties an encrypted key file that cannot be
    /// opened to a declared identity, so `EmbeddedKeyPorter` needs it. It
    /// deliberately does NOT return an `ImportedKeyInfo`: `-l` prints a
    /// fingerprint, not a public key line, so the type and the line still have
    /// to come from (and be checked against) somewhere else.
    ///
    /// **The sibling-`.pub` trap is refused, not worked around.**
    /// `ssh-keygen -l -f <private key>` reads `<private key>.pub` when one
    /// exists and only falls back to the private file otherwise — the M18
    /// finding that made `inspect` derive its fingerprint from `-y`'s output
    /// instead. Here `-y` is not available (that is the whole point), so the
    /// sibling is checked for and rejected: no macSCP code writes a `.pub`
    /// next to a materialized key today, and the day one does, callers fail
    /// loudly here instead of quietly fingerprinting a different key.
    ///
    /// Formats with no cleartext public part — legacy PEM (`DEK-Info`)
    /// encrypted keys — make `ssh-keygen -l` exit non-zero, and so fail closed
    /// through `.unsupportedOrEncrypted`. That is deliberate: there would be
    /// nothing left to check such a file against.
    public static func fingerprint(ofPrivateKeyFileAt url: URL) throws -> String {
        let tool = "/usr/bin/ssh-keygen"
        guard FileManager.default.isExecutableFile(atPath: tool) else {
            throw SSHKeyImportError.toolMissing
        }
        let path = url.path(percentEncoded: false)
        guard !FileManager.default.fileExists(atPath: path + ".pub") else {
            throw SSHKeyImportError.publicKeySiblingPresent
        }
        // `256 SHA256:<base64> <comment> (ED25519)` — field 1 is the
        // fingerprint; the comment may contain spaces, so only that field is
        // ever read.
        let listed = try run(tool, ["-l", "-f", path])
        let fields = listed.split(separator: " ")
        guard fields.count >= 2, fields[1].hasPrefix("SHA256:") else {
            throw SSHKeyImportError.unreadable
        }
        return String(fields[1])
    }

    /// The algorithm an OpenSSH key blob names in its own first wire field
    /// (`uint32 length` + that many bytes). `nil` for anything that is not a
    /// well-formed blob.
    private static func algorithmName(inKeyBlobBase64 base64: String) -> String? {
        guard let raw = Data(base64Encoded: base64), raw.count >= 4 else { return nil }
        let length = raw.prefix(4).reduce(0) { $0 << 8 | Int($1) }
        // An algorithm name is short; the bound keeps a hostile length field
        // from asking for a huge slice before the count check below.
        guard length > 0, length <= 64, raw.count >= 4 + length else { return nil }
        return String(data: raw.dropFirst(4).prefix(length), encoding: .utf8)
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
    ///
    /// Matched EXACTLY, never by prefix: `ssh-ed25519-cert-v01@openssh.com`
    /// starts with `ssh-ed25519` but is a certificate, not a key macSCP can
    /// connect with, and a prefix test would have badged it as one.
    private static func keyType(forAlgorithmName name: String) -> KeyType? {
        switch name {
        case "ssh-ed25519": return .ed25519
        // bits unknown from the public line; not connect-relevant.
        case "ssh-rsa": return .rsa(bits: 0)
        case "ecdsa-sha2-nistp256", "ecdsa-sha2-nistp384", "ecdsa-sha2-nistp521": return .ecdsa
        default: return nil
        }
    }
}
