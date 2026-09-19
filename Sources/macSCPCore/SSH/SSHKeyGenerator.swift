import Foundation

/// Generates SSH keypairs by shelling out to the system `ssh-keygen` (M17).
/// Files are written into an app-owned directory (never `~/.ssh`); the
/// private key is chmod'd 0600. The passphrase is passed via `-N` in the
/// argument array (never a shell string) — it is briefly visible in the
/// process's argv to the same user via `ps`, an accepted minor since
/// `ssh-keygen` offers no stdin passphrase path for generation.
///
/// `async` because it waits for `ssh-keygen`, and that wait goes through
/// `SubprocessRunner.run` — a suspension, never a thread parked on the
/// child. It used to end in a blocking process wait, which from async code
/// holds a cooperative-pool thread for as long as the tool runs (CLAUDE.md,
/// "Tests never block the cooperative pool"). The argument array is handed
/// to the runner unchanged, so the passphrase reaches the child exactly as
/// before — argv, nothing else — and the runner's errors carry the argument
/// COUNT, never the arguments.
public enum SSHKeyGenerator {
    public struct GeneratedKey: Equatable, Sendable {
        public let privateKeyURL: URL
        public let publicKeyOpenSSH: String
        public let fingerprint: String
    }

    public enum SSHKeyGenError: Error, Equatable {
        case keygenFailed(status: Int32)
        case publicKeyUnreadable
        case toolMissing
        case fingerprintUnavailable
        /// `ssh-keygen` did not exit within `KeyToolBound.keygen`; it was
        /// ended and any file it had started is removed.
        case timedOut
    }

    /// Cancelling the calling task ends `ssh-keygen`, removes whatever it
    /// had written, and throws `CancellationError`.
    public static func generate(
        type: KeyType, comment: String, passphrase: String?, into dir: URL
    ) async throws -> GeneratedKey {
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        // `createDirectory` only applies `attributes` when it creates the
        // directory; if it already existed, permissions are left untouched.
        // Harden explicitly so the 0700 invariant holds either way.
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: dir.path(percentEncoded: false))

        let fileURL = dir.appendingPathComponent(UUID().uuidString)
        let tool = "/usr/bin/ssh-keygen"
        guard FileManager.default.isExecutableFile(atPath: tool) else {
            throw SSHKeyGenError.toolMissing
        }

        var args = ["-t", typeFlag(type)]
        if case .rsa(let bits) = type { args += ["-b", String(bits)] }
        args += [
            "-f", fileURL.path(percentEncoded: false),
            "-N", passphrase ?? "",
            "-C", comment,
            "-q",
        ]

        let pubURL = dir.appendingPathComponent(fileURL.lastPathComponent + ".pub")
        // Never inherit an interactive prompt: `stdin: nil` hands the child
        // the null device. Its output is collected and dropped — `-q` keeps
        // it quiet, and nothing here reads it.
        let result: SubprocessResult
        do {
            result = try await SubprocessRunner.run(
                URL(fileURLWithPath: tool), arguments: args, timeout: KeyToolBound.keygen)
        } catch is SubprocessTimeout {
            // The runner has ended the child; a half-written key must not
            // stay behind in the key directory with no metadata claiming it.
            try? FileManager.default.removeItem(at: fileURL)
            try? FileManager.default.removeItem(at: pubURL)
            throw SSHKeyGenError.timedOut
        } catch is SubprocessCancelled {
            try? FileManager.default.removeItem(at: fileURL)
            try? FileManager.default.removeItem(at: pubURL)
            throw CancellationError()
        }
        guard result.status == 0 else {
            throw SSHKeyGenError.keygenFailed(status: result.status)
        }

        // Harden perms (ssh-keygen already writes 0600, but be explicit).
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: fileURL.path(percentEncoded: false))

        guard let pubContents = try? String(contentsOf: pubURL, encoding: .utf8) else {
            try? FileManager.default.removeItem(at: fileURL)
            try? FileManager.default.removeItem(at: pubURL)
            throw SSHKeyGenError.publicKeyUnreadable
        }
        let publicKeyOpenSSH = pubContents.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let fingerprint = fingerprint(fromOpenSSHPublicKey: publicKeyOpenSSH) else {
            try? FileManager.default.removeItem(at: fileURL)
            try? FileManager.default.removeItem(at: pubURL)
            throw SSHKeyGenError.fingerprintUnavailable
        }

        return GeneratedKey(
            privateKeyURL: fileURL, publicKeyOpenSSH: publicKeyOpenSSH, fingerprint: fingerprint)
    }

    private static func typeFlag(_ type: KeyType) -> String {
        switch type {
        case .ed25519: return "ed25519"
        case .rsa: return "rsa"
        case .ecdsa: return "ecdsa"
        }
    }

    /// "ssh-ed25519 <base64> comment" → SHA256 fingerprint of the base64 blob.
    private static func fingerprint(fromOpenSSHPublicKey line: String) -> String? {
        let parts = line.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        return HostKeyFingerprint.sha256(ofKeyBlobBase64: String(parts[1]))
    }
}
