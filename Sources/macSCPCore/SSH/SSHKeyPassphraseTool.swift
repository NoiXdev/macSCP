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
        try await rewritingWithRollback(fileAt: url) {
            try await run(["-q", "-p", "-P", old, "-N", new, "-f", path]) == 0
        }
    }

    /// Runs `rewrite` over the file at `url` with a copy of it kept beside it,
    /// and puts the original back whenever `rewrite` throws or answers `false`.
    ///
    /// **Why the file needs protecting at all.** `ssh-keygen -p` rewrites a key
    /// file IN PLACE: measured 2026-09-24, the inode is the same before and
    /// after, so the tool truncates and writes rather than building a new file
    /// and renaming it over the old one. `SubprocessRunner` ends a cancelled or
    /// timed-out child with `SIGTERM` and then `SIGKILL`
    /// (`SubprocessRunner.swift`), and a signal landing between the truncation
    /// and the last byte leaves a key file that NEITHER passphrase opens, with
    /// nothing anywhere to restore it from. Pressing Cancel — or Escape, or
    /// closing the window — reaches that window in one click, and the bound
    /// expiring reaches it on its own.
    ///
    /// **The invariant**, the same one `SSHKeyConverter.copyAsOpenSSH` states
    /// for its destination, one level up: when this returns or throws, the file
    /// at `url` is either fully rewritten or byte-for-byte what it was, and the
    /// copy is gone.
    ///
    /// The copy holds the same key material as the original, at the same 0600
    /// mode in the same directory — no more exposed than the file it protects,
    /// and only for the length of one `ssh-keygen` run. A copy that cannot be
    /// MADE stops the rewrite before it starts (`.failed`): a rewrite with no
    /// way back is not attempted.
    ///
    /// Beside the original deliberately, not in a temporary directory: a
    /// rename has to stay on one file system to be the atomic step this
    /// depends on.
    ///
    /// What that costs, stated no wider than it was measured (2026-09-24, by
    /// reading every `contentsOfDirectory` call in `Sources/`): no KEY-MANAGING
    /// code lists the directory — `ManagedKeyStore`, `EmbeddedKeyPorter`,
    /// `GenerateKeyForm` and the keys sheet each address a file by name through
    /// `ManagedKeyStore.privateKeyURL(for:)` — so a leftover copy is not a
    /// stray key in any list macSCP builds OF KEYS. The exception is
    /// `LocalFileSystem.listNamesAndKinds`, the app's ordinary local browser:
    /// it enumerates whatever directory the user opens, without
    /// `.skipsHiddenFiles`, so a user who browses to the key folder would see
    /// the copy by name. An earlier version of this comment claimed no
    /// enumeration anywhere reaches it, which was a whole-tree negative — the
    /// shape CLAUDE.md warns goes stale in silence — and it was already false
    /// when it was written.
    ///
    /// A copy outlives the run in exactly two cases, since every ordinary
    /// ending removes or restores it: a HARD crash, and a `rename` the file
    /// system refuses. The second is the one thing the restore cannot promise,
    /// and there the copy is deliberately LEFT BEHIND rather than removed — at
    /// that point it is the only intact key there is, and deleting it to tidy
    /// up would be the very loss this function exists to prevent.
    ///
    /// Nothing sweeps a copy that survives either way, on purpose: it holds the
    /// same key material at the same 0600 mode as the file beside it, so it is
    /// no more exposed than the key it protected, and the user documentation
    /// says where to find it and what it is.
    ///
    /// Not `private` only so `SSHKeyPassphraseToolTests` can hand in a
    /// `rewrite` that damages the file deterministically: racing a real
    /// `ssh-keygen` for the SIGKILL window would be a test that measures the
    /// machine.
    static func rewritingWithRollback(
        fileAt url: URL, _ rewrite: () async throws -> Bool
    ) async throws {
        let backup = url.deletingLastPathComponent()
            .appendingPathComponent(".macscp-rollback-\(UUID().uuidString)")
        do {
            try FileManager.default.copyItem(at: url, to: backup)
        } catch {
            throw PassphraseToolError.failed
        }
        let rewritten: Bool
        do {
            rewritten = try await rewrite()
        } catch {
            restore(backup, to: url)
            throw error
        }
        guard rewritten else {
            restore(backup, to: url)
            throw PassphraseToolError.failed
        }
        try? FileManager.default.removeItem(at: backup)
    }

    /// Puts `backup` back at `url` in ONE step, with `rename(2)`.
    ///
    /// Not `FileManager.moveItem`, which refuses an existing destination and so
    /// needs a `removeItem` before it — and that pair is the same defect this
    /// whole function exists to prevent, moved one step later: between the
    /// remove and the move the key exists only under the rollback name, and a
    /// crash, a power loss or a kill inside that window leaves nothing at all
    /// at the key's own path. `rename(2)` removes the destination and links the
    /// source over it as a single operation, so there is no instant at which
    /// the path is empty; both files are in the same directory, which is what
    /// keeps it on one file system and off `EXDEV`. `FileManager.replaceItemAt`
    /// would also close the window, but it moves the original aside into a
    /// temporary of its own choosing first, and the original here is precisely
    /// the damaged file there is no reason to keep.
    ///
    /// **The window is gone, not tested.** There is no seam between `rename`'s
    /// entry and its return to interrupt, and a test that killed the process
    /// hoping to land inside one syscall would measure the machine, not the
    /// code. What IS pinned is the behaviour that the remove-then-move version
    /// needed the remove for: `rewritingWithRollback`'s cases restore over a
    /// destination file that exists, which `moveItem` alone would have refused.
    ///
    /// A `rename` that fails leaves the copy where it is rather than cleaning
    /// it up — see the invariant on `rewritingWithRollback` for why.
    private static func restore(_ backup: URL, to url: URL) {
        let source = backup.path(percentEncoded: false)
        let destination = url.path(percentEncoded: false)
        guard rename(source, destination) == 0 else { return }
        // `copyItem` carries the mode across and `rename` keeps it, so this
        // only makes the 0600 invariant explicit the way the generator and the
        // converter do.
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: destination)
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
