import Foundation
import Observation

/// The "Correct the stored passphrase" sheet's state and its one action: the
/// key FILE is untouched, only the app's memory of what opens it is wrong or
/// missing.
///
/// That memory became load-bearing on 2026-09-20, when a managed key's stored
/// passphrase started winning over one typed for a jump hop. Winning is
/// right — the stored value is the key's own, the typed one is the session's
/// guess — but it left a wrong or missing stored value with nowhere in the app
/// to correct it: the typed passphrase was saved into the session's slot and
/// then never consulted again. This is that place.
///
/// The typed passphrase is VERIFIED against the key file before it is stored
/// (`ssh-keygen -y`, through `SSHKeyPassphraseTool.opensKey`), so a wrong one
/// cannot replace a right one. The verification is the whole reason this is a
/// form with a run and a cancel rather than a `TextField` and a save: it waits
/// for a child process, and a wait for a child process here is a suspension
/// the sheet's fields survive.
///
/// Shaped after `GenerateKeyForm`, and for the same reason: a run works from a
/// `Request` captured when it starts and never reads the fields again, because
/// the sheet's fields stay live while `ssh-keygen` runs. Re-reading live
/// `@State` after an `await` was a real defect in these very sheets (fixed
/// 2026-09-20).
///
/// Main-actor isolated, like every other writer of a managed key's Keychain
/// slot.
@Observable
@MainActor
public final class CorrectKeyPassphraseForm {
    /// Proves that a passphrase opens a key file. The default is
    /// `SSHKeyPassphraseTool.opensKey`; a test hands in one it can hold open.
    public typealias Verifier = @Sendable (_ keyURL: URL, _ passphrase: String) async throws -> Bool

    /// Why the last run did not store anything. The sheet maps each case to a
    /// fixed, localized message and never shows the underlying error.
    public enum Failure: Equatable, Sendable {
        /// The typed passphrase does not open the key file. Nothing was
        /// written — this is the one case the verification exists for.
        case doesNotOpenTheKey
        /// The key's stored `fileName` does not address a file inside the
        /// app's own key directory (`ManagedKeyStore.privateKeyURL(for:)`),
        /// so there is no file to verify against.
        case notManaged
        /// There is no file at the path the metadata names. Told apart from a
        /// wrong passphrase because retyping is not the remedy for it.
        case keyFileMissing
        /// The key file is not encrypted at all, whatever
        /// `ManagedKey.hasPassphrase` says. `ssh-keygen -y` ignores `-P` for
        /// such a file, so EVERY passphrase "opens" it and storing the typed
        /// one would store an arbitrary value under the key's id — see `run`.
        case keyIsNotEncrypted
        /// The passphrase opens the key and the Keychain write failed anyway.
        /// Nothing about the key file changed, so retrying is free.
        case notStored
        /// `ssh-keygen` ran past `KeyToolBound.keygen` and was ended.
        case timedOut
        case failed
    }

    /// How a run ended.
    public enum Outcome: Equatable, Sendable {
        /// The passphrase opens the key file and now sits in the key's own
        /// Keychain slot. The only thing this run wrote.
        case stored
        case failed(Failure)
        case cancelled
    }

    public var passphrase = ""

    public private(set) var isRunning = false
    public private(set) var failure: Failure?

    private var task: Task<Outcome, Never>?

    /// Everything a run uses, taken from the fields and the key when it
    /// starts.
    struct Request: Sendable {
        let keyID: UUID
        let keyURL: URL?
        let passphrase: String
    }

    public init() {}

    /// An empty passphrase is refused before the tool runs: this action is
    /// offered only for a key file that IS encrypted, and no encrypted key
    /// opens on nothing.
    public var isSaveDisabled: Bool { isRunning || passphrase.isEmpty }

    /// Starts a run unless one is in flight; `nil` when refused.
    @discardableResult
    public func start(
        key: ManagedKey, store: ManagedKeyStore, secrets: any SecretStore,
        verifier: @escaping Verifier = SSHKeyPassphraseTool.opensKey
    ) -> Task<Outcome, Never>? {
        guard !isRunning else { return nil }
        isRunning = true
        failure = nil
        let request = Request(
            keyID: key.id, keyURL: store.privateKeyURL(for: key), passphrase: passphrase)
        let task = Task { @MainActor [self] () -> Outcome in
            defer { isRunning = false }
            let outcome = await Self.run(request, secrets: secrets, verifier: verifier)
            if case .failed(let why) = outcome { failure = why }
            return outcome
        }
        self.task = task
        return task
    }

    /// Cancels a run in flight, if there is one. Nothing is written either
    /// way — the only write this form makes comes after the verification, and
    /// a cancellation that reaches it first stops before it.
    public func cancel() {
        task?.cancel()
    }

    /// Verifies TWICE, writes once — and writes exactly one thing, the
    /// Keychain slot under the key's own id. The key file is never opened for
    /// writing here and `managed_keys.json` is never touched: the file's
    /// passphrase did not change, so nothing the metadata records about it
    /// did either.
    ///
    /// **The second probe is the one that is not obvious.** `ssh-keygen -y`
    /// ignores `-P` for a key file that is not encrypted, so it answers "it
    /// opens" for every passphrase there — and the only thing keeping this
    /// action away from such a key is `ManagedKey.hasPassphrase`, a metadata
    /// flag that can be stale-true (a hand-edited store, a file replaced
    /// underneath macSCP). With the flag as the sole guard, an arbitrary typed
    /// value would verify and be stored silently under the key's id. So after
    /// the typed value opens the key, the EMPTY passphrase is tried too: if
    /// that opens it as well, the file is not encrypted at all and there is
    /// nothing to remember (`.keyIsNotEncrypted`). The extra `ssh-keygen` run
    /// is paid only on the path that is about to write.
    ///
    /// A failing Keychain write is its own failure rather than a partial
    /// success, because nothing else happened: the key file is exactly as it
    /// was, and pressing Save again costs those runs over again.
    ///
    /// `static`, so it cannot read the form's fields: `request` is all it has.
    private static func run(
        _ request: Request, secrets: any SecretStore, verifier: Verifier
    ) async -> Outcome {
        guard let keyURL = request.keyURL else { return .failed(.notManaged) }
        do {
            let opens = try await verifier(keyURL, request.passphrase)
            // A cancellation that arrived while `ssh-keygen` ran, or after it
            // had already answered: the user has left the sheet, and nothing
            // has been written yet, so there is nothing to undo.
            guard !Task.isCancelled else { return .cancelled }
            guard opens else { return .failed(.doesNotOpenTheKey) }
            let nothingOpensItToo = try await verifier(keyURL, "")
            guard !Task.isCancelled else { return .cancelled }
            guard !nothingOpensItToo else { return .failed(.keyIsNotEncrypted) }
            do {
                try secrets.savePassword(request.passphrase, for: request.keyID)
            } catch {
                return .failed(.notStored)
            }
            return .stored
        } catch is CancellationError {
            return .cancelled
        } catch SSHKeyPassphraseTool.PassphraseToolError.keyFileMissing {
            return .failed(.keyFileMissing)
        } catch SSHKeyPassphraseTool.PassphraseToolError.timedOut {
            return .failed(.timedOut)
        } catch {
            return .failed(.failed)
        }
    }
}
