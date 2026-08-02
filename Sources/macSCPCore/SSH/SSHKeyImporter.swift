import Foundation

/// Inspects an existing OpenSSH private key file so the app can import it as a
/// managed key (M18). Shells out to the system `ssh-keygen` (argument array,
/// never a shell string) to derive the public key (`-y`) and fingerprint
/// (`-l`). Reads only — copying the file into the key store and creating the
/// `ManagedKey`/Keychain entry is the app's job (it owns the id/name/comment).
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
        // Fingerprint via `ssh-keygen -l -f <file>` → "<bits> SHA256:… comment (TYPE)".
        let lf = try run(tool, ["-l", "-f", privateKeyURL.path(percentEncoded: false)])
        guard let fingerprint = lf.split(separator: " ").first(where: { $0.hasPrefix("SHA256:") }).map(String.init)
        else {
            throw SSHKeyImportError.unreadable
        }
        return ImportedKeyInfo(
            type: keyType(fromOpenSSHPublicKey: pub),
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

    private static func keyType(fromOpenSSHPublicKey line: String) -> KeyType {
        if line.hasPrefix("ssh-ed25519") { return .ed25519 }
        if line.hasPrefix("ecdsa-") { return .ecdsa }
        return .rsa(bits: 0)   // bits unknown from the public line; not connect-relevant
    }
}
