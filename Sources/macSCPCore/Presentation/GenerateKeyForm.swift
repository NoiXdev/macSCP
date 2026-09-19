import Foundation
import Observation

/// The "Generate SSH Key" sheet's state and its one action.
///
/// Lifted out of the sheet (`MacSCPAppKit/SSHKeysSheet.swift`,
/// `GenerateKeySheet`) when `SSHKeyGenerator.generate` became `async`
/// (2026-09-19, the CI-starvation plan, Task 2). While generation blocked,
/// nothing could change between handing `ssh-keygen` its inputs and writing
/// the record; now the sheet's fields are live for as long as the tool runs.
/// So a run works from a `Request` captured when it starts and never reads
/// the fields again, and the sheet disables the fields while `isGenerating`
/// anyway. `GenerateKeyFormTests` edits the fields mid-run and checks the
/// record against what `ssh-keygen` was given.
///
/// Main-actor isolated, like every other writer of `managed_keys.json`
/// (`EmbeddedKeyPorter.materialize` says why that matters).
@Observable
@MainActor
public final class GenerateKeyForm {
    /// A `Picker`-friendly stand-in for `KeyType` — `KeyType.rsa` carries a
    /// `bits` payload, so it can't be a segmented-picker `tag` on its own;
    /// `rsaBits` supplies that payload separately.
    public enum TypeChoice: String, CaseIterable, Identifiable, Sendable {
        case ed25519, rsa, ecdsa
        public var id: String { rawValue }
    }

    /// Why the last run did not produce a key. The sheet maps each case to a
    /// fixed, localized message and never shows the underlying error.
    public enum Failure: Equatable, Sendable {
        case failed
        /// `ssh-keygen` ran past `KeyToolBound.keygen` and was ended.
        case timedOut
    }

    /// How a run ended.
    public enum Outcome: Equatable, Sendable {
        /// The key is in the store. `false`: its passphrase did not reach the
        /// Keychain (the key is kept; see `run`).
        case generated(keptPassphrase: Bool)
        case failed(Failure)
        case cancelled
    }

    /// What `ssh-keygen` is asked for. The default is `SSHKeyGenerator.generate`;
    /// a test hands in one it can hold open.
    public typealias Generator = @Sendable (
        _ type: KeyType, _ comment: String, _ passphrase: String?, _ directory: URL
    ) async throws -> SSHKeyGenerator.GeneratedKey

    public var name = ""
    public var comment = ""
    public var typeChoice: TypeChoice = .ed25519
    public var rsaBits = 3072
    public var passphrase = ""
    public var passphraseConfirm = ""

    public private(set) var isGenerating = false
    public private(set) var failure: Failure?

    private var task: Task<Outcome, Never>?

    /// Everything a run uses, taken from the fields when it starts.
    struct Request: Equatable, Sendable {
        let name: String
        let comment: String
        let type: KeyType
        /// `nil` for an empty field: no passphrase, no Keychain slot.
        let passphrase: String?
    }

    public init() {}

    public var resolvedType: KeyType {
        switch typeChoice {
        case .ed25519: return .ed25519
        case .rsa: return .rsa(bits: rsaBits)
        case .ecdsa: return .ecdsa
        }
    }

    public var passphrasesMismatch: Bool { passphrase != passphraseConfirm }

    public var isGenerateDisabled: Bool {
        isGenerating || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || passphrasesMismatch
    }

    /// Starts a run unless one is in flight; `nil` when refused.
    @discardableResult
    public func start(
        store: ManagedKeyStore, secrets: any SecretStore,
        generator: @escaping Generator = SSHKeyGenerator.generate
    ) -> Task<Outcome, Never>? {
        guard !isGenerating else { return nil }
        isGenerating = true
        failure = nil
        let request = Request(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            comment: comment.trimmingCharacters(in: .whitespacesAndNewlines),
            type: resolvedType,
            passphrase: passphrase.isEmpty ? nil : passphrase)
        let task = Task { @MainActor [self] () -> Outcome in
            defer { isGenerating = false }
            let outcome = await Self.run(request, store: store, secrets: secrets, generator: generator)
            if case .failed(let why) = outcome { failure = why }
            return outcome
        }
        self.task = task
        return task
    }

    /// Cancels a run in flight, if there is one. The run then records
    /// nothing and removes whatever `ssh-keygen` wrote — whether the
    /// cancellation reached the tool (the runner ends it) or arrived after
    /// the tool had already finished.
    public func cancel() {
        task?.cancel()
    }

    /// Generates the key on disk, persists the resulting `ManagedKey`, and
    /// only THEN saves the passphrase (if any) to the Keychain under the same
    /// fresh id.
    ///
    /// The two failures fall in opposite directions, deliberately. A failed
    /// METADATA write rolls the key files back: without a metadata entry there
    /// is no key, and nothing on disk may pretend otherwise. A failed
    /// PASSPHRASE write keeps everything — the key is already listed, so
    /// "encrypted key, no stored passphrase" is a state the app carries (the
    /// connection form shows the passphrase row, `ManagedKeyPassphrase.resolve`
    /// falls back to what is typed, and typing it once persists it). Writing
    /// the passphrase first left a Keychain entry under an id
    /// `managed_keys.json` never learned. New orphans only: existing ones
    /// cannot be collected without a Keychain enumeration, which
    /// `SecretStore` deliberately does not have.
    ///
    /// `static`, so it cannot read the form's fields: `request` is all it has.
    private static func run(
        _ request: Request, store: ManagedKeyStore, secrets: any SecretStore, generator: Generator
    ) async -> Outcome {
        do {
            let generated = try await generator(
                request.type, request.comment, request.passphrase, store.keyDirectory)
            // A cancellation that arrived after `ssh-keygen` had finished:
            // the user has already left the sheet, so the key must not
            // appear in the list.
            guard !Task.isCancelled else {
                removeFiles(of: generated)
                return .cancelled
            }
            let newID = UUID()
            do {
                let key = ManagedKey(
                    id: newID, name: request.name, comment: request.comment, type: request.type,
                    fingerprint: generated.fingerprint, publicKeyOpenSSH: generated.publicKeyOpenSSH,
                    createdAt: Date(), hasPassphrase: request.passphrase != nil,
                    fileName: generated.privateKeyURL.lastPathComponent)
                try store.add(key)
            } catch {
                removeFiles(of: generated)
                throw error
            }
            var keptPassphrase = true
            if let passphrase = request.passphrase {
                do {
                    try secrets.savePassword(passphrase, for: newID)
                } catch {
                    keptPassphrase = false
                }
            }
            return .generated(keptPassphrase: keptPassphrase)
        } catch is CancellationError {
            return .cancelled
        } catch SSHKeyGenerator.SSHKeyGenError.timedOut {
            return .failed(.timedOut)
        } catch {
            return .failed(.failed)
        }
    }

    private static func removeFiles(of generated: SSHKeyGenerator.GeneratedKey) {
        try? FileManager.default.removeItem(at: generated.privateKeyURL)
        try? FileManager.default.removeItem(
            at: generated.privateKeyURL.deletingLastPathComponent()
                .appendingPathComponent(generated.privateKeyURL.lastPathComponent + ".pub"))
    }
}
