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
    /// for writing. On any failure once the copy has started, the
    /// destination is removed (best-effort — including a partial file left
    /// by `copyItem` itself, which cannot be provoked deterministically to
    /// test). Returns `true` when a conversion ran, `false` when the copy
    /// was already OpenSSH-format.
    ///
    /// `async` because it waits for a child process, and a wait for a child
    /// process is never allowed to be a blocking one here (CLAUDE.md, "Tests
    /// never block the cooperative pool"): every test that called this
    /// parked a cooperative-pool thread on `ssh-keygen` for as long as it
    /// ran, and that pool is exactly as wide as the machine has cores. The
    /// waiting is `waitForExit(_:)` below, an `await` on the process's own
    /// termination handler. The file system work around it stays
    /// synchronous — it is the process wait, not the I/O, that this changed
    /// for.
    @discardableResult
    public static func copyAsOpenSSH(from source: URL, to destination: URL,
                                     passphrase: String?) async throws -> Bool {
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
            // Best-effort: `copyItem` can fail after writing a partial file
            // (e.g. it dies mid-copy on a large source); removing here holds
            // the "removed on any failure after the copy started" invariant
            // for that case too. Not deterministically provokable, so it has
            // no dedicated test.
            try? FileManager.default.removeItem(at: destination)
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
        let status: Int32
        do {
            status = try await waitForExit(process)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw ConversionError.conversionFailed
        }

        guard status == 0, isOpenSSHFormat(fileAt: destination) else {
            try? FileManager.default.removeItem(at: destination)
            throw ConversionError.conversionFailed
        }
        return true
    }

    /// Starts `process` and suspends until it exits, handing back its exit
    /// status; throws whatever `run()` threw when it could not be started at
    /// all.
    ///
    /// The termination handler is installed BEFORE `run()`, which is the
    /// only order that cannot lose the notification for a process that exits
    /// immediately. The continuation is resumed exactly once on each path:
    /// `run()` throwing means the handler will never be called (nothing was
    /// started), and clearing it there keeps that true even if the reference
    /// outlives this call. The handler reads the exit status off the
    /// `Process` it is HANDED rather than the one captured here, so there is
    /// no shared mutable state between the two sides of the suspension.
    private static func waitForExit(_ process: Process) async throws -> Int32 {
        try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { finished in
                continuation.resume(returning: finished.terminationStatus)
            }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(throwing: error)
            }
        }
    }

    /// The in-place conversion a person runs in a terminal themselves:
    /// `ssh-keygen -p -f '<path>'`, with `path` quoted for a POSIX shell.
    public static func inPlaceCommandLine(forKeyAt path: String) -> String {
        "ssh-keygen -p -f " + PosixQuoting.singleQuoted(path)
    }
}
