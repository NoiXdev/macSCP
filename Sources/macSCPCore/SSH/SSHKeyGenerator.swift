import Foundation

/// Generates SSH keypairs by shelling out to the system `ssh-keygen` (M17).
/// Files are written into an app-owned directory (never `~/.ssh`); the
/// private key is chmod'd 0600. The passphrase is passed via `-N` in the
/// argument array (never a shell string) — it is briefly visible in the
/// process's argv to the same user via `ps`, an accepted minor since
/// `ssh-keygen` offers no stdin passphrase path for generation.
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
    }

    public static func generate(
        type: KeyType, comment: String, passphrase: String?, into dir: URL
    ) throws -> GeneratedKey {
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])

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

        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = args
        // Never inherit an interactive prompt; keep output quiet.
        process.standardInput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw SSHKeyGenError.keygenFailed(status: process.terminationStatus)
        }

        // Harden perms (ssh-keygen already writes 0600, but be explicit).
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: fileURL.path(percentEncoded: false))

        let pubURL = dir.appendingPathComponent(fileURL.lastPathComponent + ".pub")
        guard let pubContents = try? String(contentsOf: pubURL, encoding: .utf8) else {
            throw SSHKeyGenError.publicKeyUnreadable
        }
        let publicKeyOpenSSH = pubContents.trimmingCharacters(in: .whitespacesAndNewlines)
        let fingerprint = fingerprint(fromOpenSSHPublicKey: publicKeyOpenSSH)
            ?? SSHKeyGenerator.fingerprintViaTool(pubURL: pubURL)
            ?? ""

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

    /// Fallback: `ssh-keygen -lf <pub>` prints "<bits> SHA256:… comment (TYPE)".
    private static func fingerprintViaTool(pubURL: URL) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        process.arguments = ["-lf", pubURL.path(percentEncoded: false)]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardInput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let out = String(data: data, encoding: .utf8) else { return nil }
        return out.split(separator: " ").first { $0.hasPrefix("SHA256:") }.map(String.init)
    }
}
