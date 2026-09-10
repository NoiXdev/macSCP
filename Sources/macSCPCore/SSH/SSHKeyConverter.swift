import Foundation

/// Copies a private key file and rewrites the COPY to OpenSSH format with
/// `/usr/bin/ssh-keygen -p`, leaving the original untouched.
///
/// This is the "Convert" remedy for a key `PEMPrivateKeyDecoder` cannot open
/// (or opens but that `EmbeddedKeyPorter` cannot export, since export
/// requires the OpenSSH boundary): one click turns a copy into a managed key
/// instead of asking the person to run a command themselves.
/// `inPlaceCommandLine` is that same command, for the person who would
/// rather run it than click.
///
/// The passphrase reaches `ssh-keygen` through `-P`/`-N` in the argument
/// array — the accepted minor `SSHKeyImporter`'s doc comment documents.
public enum SSHKeyConverter {
    public enum ConversionError: Error, Equatable, Sendable {
        case toolMissing, sourceUnreadable, conversionFailed, destinationExists
    }

    public static let opensshBoundary = "-----BEGIN OPENSSH PRIVATE KEY-----"

    /// True when the first non-blank line of `url` is the OpenSSH boundary.
    /// `false` for anything else, including a file that cannot be read.
    public static func isOpenSSHFormat(fileAt url: URL) -> Bool {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return false }
        guard let firstNonBlank = text.split(separator: "\n", omittingEmptySubsequences: false)
            .first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
        else { return false }
        return firstNonBlank.trimmingCharacters(in: .whitespacesAndNewlines) == opensshBoundary
    }

    /// Copies `source` to `destination` with mode 0600 and, unless the copy
    /// is already OpenSSH-format, rewrites the COPY with `ssh-keygen -p`
    /// (argument array, never a shell string). The source is never opened
    /// for writing. On any failure after the copy, the destination is
    /// removed. Returns `true` when a conversion ran, `false` when the copy
    /// was already OpenSSH-format.
    @discardableResult
    public static func copyAsOpenSSH(from source: URL, to destination: URL, passphrase: String?) throws -> Bool {
        let tool = "/usr/bin/ssh-keygen"
        guard FileManager.default.isExecutableFile(atPath: tool) else {
            throw ConversionError.toolMissing
        }
        let destinationPath = destination.path(percentEncoded: false)
        guard !FileManager.default.fileExists(atPath: destinationPath) else {
            throw ConversionError.destinationExists
        }
        do {
            try FileManager.default.copyItem(at: source, to: destination)
        } catch {
            throw ConversionError.sourceUnreadable
        }
        do {
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destinationPath)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw ConversionError.conversionFailed
        }

        if isOpenSSHFormat(fileAt: destination) {
            return false
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = ["-q", "-p", "-P", passphrase ?? "", "-N", passphrase ?? "", "-f", destinationPath]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw ConversionError.conversionFailed
        }
        process.waitUntilExit()

        guard process.terminationStatus == 0, isOpenSSHFormat(fileAt: destination) else {
            try? FileManager.default.removeItem(at: destination)
            throw ConversionError.conversionFailed
        }
        return true
    }

    /// The in-place conversion a person runs in a terminal themselves:
    /// `ssh-keygen -p -f '<path>'`, with `path` quoted for a POSIX shell.
    public static func inPlaceCommandLine(forKeyAt path: String) -> String {
        "ssh-keygen -p -f " + PosixQuoting.singleQuoted(path)
    }
}
