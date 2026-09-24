import Foundation
import Observation

/// The "Change the key file's passphrase" sheet's state and its one action:
/// the key FILE is re-encrypted, and the app's stored passphrase follows in
/// the same operation.
///
/// The sibling action, `CorrectKeyPassphraseForm`, is the other half of the
/// maintainer's answer of 2026-09-24 ("both, as two separate actions") and
/// changes nothing on disk. They are deliberately not one sheet with a
/// checkbox: one of them cannot get the key file wrong, and the other rewrites
/// it irreversibly.
///
/// ## What happens when only half of it works
///
/// `ssh-keygen -p` rewrites the key file IN PLACE, and a run that is stopped
/// part-way through would leave a file neither passphrase opens.
/// `SSHKeyPassphraseTool.rewritingWithRollback` is what stands between the
/// user and that: it copies the file aside first and puts the original back
/// whenever the run throws or exits non-zero, so by the time an outcome
/// reaches here, the file is either fully rewritten or byte-for-byte what it
/// was. That invariant is what lets the cases below mean anything at all.
///
/// What the rollback cannot cover is the record AFTER a rewrite that
/// succeeded (the Keychain slot, and the `hasPassphrase` flag when a
/// previously unencrypted key has just been encrypted): the file is already
/// the new one, and there is no honest way to present that as a failure —
/// the change HAPPENED. `.changedButNotStored` is that state, and the sheet
/// says so: the file's new passphrase is the truth from now on, and macSCP
/// may ask for it on the next connection because it could not finish writing
/// it down. Reporting it as an error would send the user back to a key their
/// old passphrase no longer opens.
///
/// ## What a cancellation means
///
/// `.cancelled` means the key file is exactly as it was — at EVERY point a
/// cancellation can arrive, not only before the tool starts. A cancel during
/// the verification stops before anything is touched; a cancel during the
/// rewrite reaches `ssh-keygen` as `SIGTERM`/`SIGKILL`, comes back out of the
/// tool as `CancellationError`, and the rollback has already restored the
/// file by then. So there is nothing for the sheet to tell the user, and it
/// tells them nothing.
///
/// The one place a cancellation is deliberately IGNORED is after the rewrite
/// has returned successfully: the file is the new one, and abandoning the
/// record there would be the single thing guaranteed to lose the new
/// passphrase.
///
/// Shaped after `GenerateKeyForm`: a run works from a `Request` captured when
/// it starts and never reads the fields again, because the sheet's fields stay
/// live while `ssh-keygen` runs.
@Observable
@MainActor
public final class ChangeKeyPassphraseForm {
    /// See `CorrectKeyPassphraseForm.Verifier`.
    public typealias Verifier = @Sendable (_ keyURL: URL, _ passphrase: String) async throws -> Bool
    /// Re-encrypts a key file. The default is
    /// `SSHKeyPassphraseTool.changePassphrase`; a test hands in one it can
    /// hold open or fail on demand.
    public typealias Changer = @Sendable (
        _ keyURL: URL, _ old: String, _ new: String
    ) async throws -> Void

    /// Why the last run left the key file exactly as it was — every case
    /// here does, including the two that can arrive from the rewrite itself,
    /// because the rewrite rolls back. What the SHEET says about `.timedOut`
    /// and `.failed` is weaker than that on purpose: restoring the copy is the
    /// one step the tool cannot guarantee, so the wording sends the user to
    /// check rather than promising them the file is intact.
    public enum Failure: Equatable, Sendable {
        /// The key's stored `fileName` does not address a file inside the
        /// app's own key directory (`ManagedKeyStore.privateKeyURL(for:)`) —
        /// a key macSCP did not put there, and will not rewrite.
        case notManaged
        /// There is no file at the path the metadata names. Told apart from a
        /// wrong passphrase because retyping is not the remedy for it.
        case keyFileMissing
        /// The old passphrase does not open the key file. Proven with
        /// `ssh-keygen -y` BEFORE `-p` runs, so this can be told apart from
        /// a run that broke for some other reason.
        case oldDoesNotOpenTheKey
        /// `ssh-keygen` ran past `KeyToolBound.keygen` and was ended.
        case timedOut
        case failed
    }

    /// How a run ended. Note that only `failed` and `cancelled` mean the key
    /// file is untouched.
    public enum Outcome: Equatable, Sendable {
        /// The file is re-encrypted and the app's record followed: the new
        /// passphrase is in the key's own Keychain slot.
        case changed
        /// The file is re-encrypted and the app's record did NOT follow —
        /// see the type's own doc. The new passphrase is what opens the key
        /// from now on.
        case changedButNotStored
        case failed(Failure)
        case cancelled
    }

    /// Empty for a key file that is not encrypted yet — this action then
    /// ENCRYPTS it, and the metadata flag follows.
    public var oldPassphrase = ""
    public var newPassphrase = ""
    public var newPassphraseConfirm = ""

    public private(set) var isRunning = false
    public private(set) var failure: Failure?

    private var task: Task<Outcome, Never>?

    /// Everything a run uses, taken from the fields and the key when it
    /// starts.
    struct Request: Sendable {
        let key: ManagedKey
        let keyURL: URL?
        let old: String
        let new: String
    }

    public init() {}

    public var passphrasesMismatch: Bool { newPassphrase != newPassphraseConfirm }

    /// An EMPTY new passphrase is refused: it would decrypt the key file, and
    /// removing a key's protection is not what an action called "change the
    /// passphrase" is asked to do. There is no other action for it today; a
    /// key that should stop being encrypted is re-generated or re-imported.
    public var isSaveDisabled: Bool {
        isRunning || newPassphrase.isEmpty || passphrasesMismatch
    }

    /// Starts a run unless one is in flight; `nil` when refused.
    @discardableResult
    public func start(
        key: ManagedKey, store: ManagedKeyStore, secrets: any SecretStore,
        verifier: @escaping Verifier = SSHKeyPassphraseTool.opensKey,
        changer: @escaping Changer = SSHKeyPassphraseTool.changePassphrase
    ) -> Task<Outcome, Never>? {
        guard !isRunning else { return nil }
        isRunning = true
        failure = nil
        let request = Request(
            key: key, keyURL: store.privateKeyURL(for: key),
            old: oldPassphrase, new: newPassphrase)
        let task = Task { @MainActor [self] () -> Outcome in
            defer { isRunning = false }
            let outcome = await Self.run(
                request, store: store, secrets: secrets, verifier: verifier, changer: changer)
            if case .failed(let why) = outcome { failure = why }
            return outcome
        }
        self.task = task
        return task
    }

    /// Cancels a run in flight, if there is one. However far the run has got,
    /// a cancellation leaves the key file as it was — see "What a
    /// cancellation means" on the type.
    public func cancel() {
        task?.cancel()
    }

    /// Four steps, in the only order that can be told apart afterwards:
    /// resolve the file, prove the OLD passphrase opens it, rewrite it, then
    /// record. The proof is what lets `.oldDoesNotOpenTheKey` exist at all —
    /// `ssh-keygen -p` answers a wrong old passphrase with the same non-zero
    /// exit it answers everything else with.
    ///
    /// Steps 1-3 leave the file untouched unless they all succeed: the
    /// rewrite is wrapped in `SSHKeyPassphraseTool.rewritingWithRollback`, so
    /// a throw or a non-zero exit puts the original back before the error ever
    /// reaches this function. Everything after it is recorded on a best-effort
    /// basis and never turns the run into a failure. The metadata write only happens for
    /// a key that was not encrypted before, and only carries the flag the lock
    /// glyph and `ManagedKeyPassphrase.resolve`'s fast path read; the Keychain
    /// write is attempted whether or not that one worked, because a slot is
    /// worth having either way. Either one failing is `.changedButNotStored`.
    ///
    /// `static`, so it cannot read the form's fields: `request` is all it has.
    private static func run(
        _ request: Request, store: ManagedKeyStore, secrets: any SecretStore,
        verifier: Verifier, changer: Changer
    ) async -> Outcome {
        guard let keyURL = request.keyURL else { return .failed(.notManaged) }
        do {
            let opens = try await verifier(keyURL, request.old)
            // The last point at which abandoning costs nothing: the file has
            // not been touched yet.
            guard !Task.isCancelled else { return .cancelled }
            guard opens else { return .failed(.oldDoesNotOpenTheKey) }
            try await changer(keyURL, request.old, request.new)
        } catch is CancellationError {
            return .cancelled
        } catch SSHKeyPassphraseTool.PassphraseToolError.keyFileMissing {
            return .failed(.keyFileMissing)
        } catch SSHKeyPassphraseTool.PassphraseToolError.timedOut {
            return .failed(.timedOut)
        } catch {
            return .failed(.failed)
        }

        // Past here the rewrite RETURNED, so the file is re-encrypted and
        // `Task.isCancelled` is deliberately NOT consulted: the new passphrase
        // is already the only one that opens the key, and a cancellation
        // honoured now would be the one thing that loses it. A cancellation
        // that arrived while the tool was still running never gets here — it
        // is thrown out of `changer` above, with the file already restored.
        var recorded = true
        if !request.key.hasPassphrase {
            var updated = request.key
            updated.hasPassphrase = true
            do { try store.add(updated) } catch { recorded = false }
        }
        do {
            try secrets.savePassword(request.new, for: request.key.id)
        } catch {
            recorded = false
        }
        return recorded ? .changed : .changedButNotStored
    }
}
