import Foundation

/// The two `ssh-keygen` runs a managed key's passphrase needs: proving that a
/// passphrase opens a key file (`-y`), and re-encrypting that file with a new
/// one (`-p`).
///
/// Both exist because the app remembers a managed key's passphrase in the
/// Keychain under the key's own id, and until now nothing could correct that
/// memory or change what it is a memory OF. `SSHKeyConverter` already runs
/// `ssh-keygen -p`, but only over a COPY it is making, and
/// `SSHKeyImporter.inspect` already runs `-y`, but throws away the one bit a
/// verification wants — whether the tool exited zero — by folding a non-zero
/// exit into `.unsupportedOrEncrypted` together with unreadable output.
/// `opensKey(at:passphrase:)` answers that bit as a `Bool` instead: "this
/// passphrase does not open this key" is an ordinary answer here, not an
/// error.
///
/// The passphrase reaches `ssh-keygen` through `-P`/`-N` in the argument
/// array, never a shell string — briefly visible in the process's argv to the
/// same user via `ps`, the accepted minor `SSHKeyGenerator` and
/// `SSHKeyImporter` already document for their own runs.
///
/// Both are `async` and wait through `SubprocessRunner.run`, bounded by
/// `KeyToolBound.keygen`: a suspension, never a cooperative-pool thread
/// parked on the child (CLAUDE.md, "Tests never block the cooperative pool").
/// Cancelling the calling task ends the child and throws `CancellationError`.
public enum SSHKeyPassphraseTool {
    public enum PassphraseToolError: Error, Equatable, Sendable {
        case toolMissing
        /// No file at the path handed in. Distinguished from "the passphrase
        /// does not open it" deliberately: `ssh-keygen` exits non-zero for
        /// both, and reporting a missing file as a wrong passphrase would
        /// send the user to retype something that was never the problem.
        case keyFileMissing
        /// `ssh-keygen` did not exit within `KeyToolBound.keygen` and was
        /// ended. For `changePassphrase` this says nothing about whether the
        /// file was rewritten — see that function's own doc.
        case timedOut
        /// The tool could not be launched, or `-p` exited non-zero.
        case failed
    }

    private static let tool = "/usr/bin/ssh-keygen"

    /// Whether `passphrase` opens the private key file at `url`.
    ///
    /// Runs `ssh-keygen -y -P <passphrase> -f <path>`, which derives the
    /// public half and therefore has to decrypt the private one. A zero exit
    /// is `true`; any other exit is `false`. The tool's output is dropped
    /// unread: the exit status is the whole answer, and the output would
    /// otherwise be a public key nobody asked for.
    ///
    /// An UNENCRYPTED key file opens under any passphrase, `ssh-keygen`
    /// ignoring `-P` for it — so `true` means "this passphrase is not wrong
    /// for this key", which is exactly what both callers need. The correction
    /// action is offered only for a key whose file IS encrypted
    /// (`ManagedKey.hasPassphrase`), so the vacuous answer never decides
    /// anything there.
    public static func opensKey(at url: URL, passphrase: String) async throws -> Bool {
        let path = try existingKeyPath(url)
        return try await run(["-y", "-P", passphrase, "-f", path]) == 0
    }

    /// Re-encrypts the private key file at `url` in place: `ssh-keygen -q -p
    /// -P <old> -N <new> -f <path>`.
    ///
    /// The file is the ONLY thing this touches — no metadata, no Keychain.
    /// Whoever calls it owns the record that follows, and owns saying so when
    /// that record cannot be written: once this returns, the new passphrase is
    /// the only one that opens the file, and nothing can undo that without the
    /// new one.
    ///
    /// A non-zero exit throws `.failed` — including the case of a wrong `old`.
    /// Callers that want to tell a wrong old passphrase from a broken run
    /// prove it first with `opensKey(at:passphrase:)`, as
    /// `ChangeKeyPassphraseForm` does, rather than reading it out of an exit
    /// status that means several things.
    public static func changePassphrase(
        ofKeyAt url: URL, from old: String, to new: String
    ) async throws {
        let path = try existingKeyPath(url)
        guard try await run(["-q", "-p", "-P", old, "-N", new, "-f", path]) == 0 else {
            throw PassphraseToolError.failed
        }
    }

    /// The file-system path of `url`, once it is known to name an existing
    /// file. Both entry points ask first, so that `ssh-keygen`'s single
    /// non-zero exit does not have to stand for two different answers.
    private static func existingKeyPath(_ url: URL) throws -> String {
        let path = url.path(percentEncoded: false)
        guard FileManager.default.fileExists(atPath: path) else {
            throw PassphraseToolError.keyFileMissing
        }
        return path
    }

    /// `ssh-keygen`'s exit status. Stdin is the null device (`stdin: nil`), so
    /// the tool can never wait on a passphrase prompt; both streams are
    /// collected by the runner and dropped here — one of them would otherwise
    /// be a public key, and the other a diagnostic naming the key's path.
    private static func run(_ arguments: [String]) async throws -> Int32 {
        guard FileManager.default.isExecutableFile(atPath: tool) else {
            throw PassphraseToolError.toolMissing
        }
        do {
            return try await SubprocessRunner.run(
                URL(fileURLWithPath: tool), arguments: arguments,
                timeout: KeyToolBound.keygen).status
        } catch is SubprocessTimeout {
            throw PassphraseToolError.timedOut
        } catch is SubprocessCancelled {
            throw CancellationError()
        } catch {
            throw PassphraseToolError.failed
        }
    }
}
