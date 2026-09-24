import Foundation
import Synchronization
import Testing
@testable import macSCPCore

/// `CorrectKeyPassphraseForm` and `ChangeKeyPassphraseForm` — the two actions
/// the maintainer's answer of 2026-09-24 asked for, side by side because the
/// whole point of having two is what each one does NOT do.
///
/// Nothing here runs `ssh-keygen`: the verifier and the changer are handed in,
/// so a wrong passphrase, a failing tool and a Keychain that will not write
/// are the test's own sequence rather than a rig. The real tool has its own
/// suite (`SSHKeyPassphraseToolTests`), which generates its keys at runtime.
///
/// Every passphrase below lives in a named constant and every expectation is a
/// `Bool` computed first, so neither a value nor its spelling can reach a
/// failure message (CLAUDE.md, "A value a test must not leak has two exits,
/// not one"). That rule is the whole subject matter here.
@Suite("Managed key passphrase forms", .timeLimit(.minutes(1)))
@MainActor
struct KeyPassphraseFormsTests {
    /// What the key file actually opens with, before anything in a test runs.
    private static let rightPassphrase = "fixture-opens-the-key"
    /// What the app wrongly remembered, or what a user mistypes.
    private static let wrongPassphrase = "fixture-does-not-open-it"
    /// What a change sets the file to.
    private static let replacementPassphrase = "fixture-replacement"

    private func tempStore() -> (ManagedKeyStore, URL) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-passform-\(UUID().uuidString)")
        return (ManagedKeyStore(directory: dir), dir)
    }

    /// A managed key whose `fileName` is a single path component, so
    /// `ManagedKeyStore.privateKeyURL(for:)` resolves it inside the key
    /// directory. No file is written: nothing in this suite opens one.
    private func managedKey(encrypted: Bool = true) -> ManagedKey {
        let id = UUID()
        return ManagedKey(
            id: id, name: "work", comment: "work-key", type: .ed25519,
            fingerprint: "SHA256:placeholder",
            publicKeyOpenSSH: "ssh-ed25519 AAAAplaceholder work-key",
            createdAt: Date(), hasPassphrase: encrypted, fileName: id.uuidString)
    }

    /// A metadata entry whose `fileName` leaves the key directory — the shape
    /// a hand-edited or tampered `managed_keys.json` produces, and the only
    /// way a listed key can fail to name a file macSCP owns.
    private func unmanagedKey() -> ManagedKey {
        var key = managedKey()
        key.fileName = "../elsewhere"
        return key
    }

    // MARK: - Correcting the stored passphrase

    @Test func correctingWithThePassphraseThatOpensTheKeyStoresIt() async throws {
        let (store, dir) = tempStore(); defer { try? FileManager.default.removeItem(at: dir) }
        let secrets = InMemorySecretStore()
        let key = managedKey()
        let verifier = ScriptedVerifier(accepting: Self.rightPassphrase)
        let form = CorrectKeyPassphraseForm()
        form.passphrase = Self.rightPassphrase

        let started = form.start(key: key, store: store, secrets: secrets, verifier: verifier.verify)
        let task = try #require(started)
        let outcome = await task.value

        #expect(outcome == .stored)
        let slotHoldsIt = secrets.peek(key.id) == Self.rightPassphrase
        #expect(slotHoldsIt)
        // TWO runs, not one: the typed value, and then the empty one, which
        // must NOT open the key — see
        // `aKeyWhoseFileTurnsOutNotToBeEncryptedIsRefused`. Without this the
        // refusal checks below could pass over a verifier never called at all.
        #expect(verifier.calls == 2)
        let askedAboutTheKeysOwnFile = verifier.lastURL == store.privateKeyURL(for: key)
        #expect(askedAboutTheKeysOwnFile)
        #expect(form.failure == nil)
        #expect(form.isRunning == false)
    }

    @Test func correctingWithAPassphraseThatDoesNotOpenTheKeyStoresNothing() async throws {
        let (store, dir) = tempStore(); defer { try? FileManager.default.removeItem(at: dir) }
        let secrets = InMemorySecretStore()
        let key = managedKey()
        let verifier = ScriptedVerifier(accepting: Self.rightPassphrase)
        let form = CorrectKeyPassphraseForm()
        form.passphrase = Self.wrongPassphrase

        let started = form.start(key: key, store: store, secrets: secrets, verifier: verifier.verify)
        let task = try #require(started)
        let outcome = await task.value

        #expect(outcome == .failed(.doesNotOpenTheKey))
        #expect(form.failure == .doesNotOpenTheKey)
        // Not just "the key's slot is empty": no slot anywhere was written.
        #expect(secrets.storedIDs.isEmpty)
        #expect(verifier.calls == 1)
    }

    @Test func correctingAKeyOutsideTheAppsOwnDirectoryIsRefusedBeforeTheToolRuns() async throws {
        let (store, dir) = tempStore(); defer { try? FileManager.default.removeItem(at: dir) }
        let secrets = InMemorySecretStore()
        let verifier = ScriptedVerifier(accepting: Self.rightPassphrase)
        let form = CorrectKeyPassphraseForm()
        form.passphrase = Self.rightPassphrase

        let started = form.start(
            key: unmanagedKey(), store: store, secrets: secrets, verifier: verifier.verify)
        let task = try #require(started)
        let outcome = await task.value

        #expect(outcome == .failed(.notManaged))
        #expect(verifier.calls == 0)
        #expect(secrets.storedIDs.isEmpty)
    }

    @Test func aKeychainThatWillNotWriteIsItsOwnFailureAndLeavesTheKeyFileAlone() async throws {
        let (store, dir) = tempStore(); defer { try? FileManager.default.removeItem(at: dir) }
        let secrets = UnreliableSecretStore(failsSaves: true)
        let key = managedKey()
        let verifier = ScriptedVerifier(accepting: Self.rightPassphrase)
        let form = CorrectKeyPassphraseForm()
        form.passphrase = Self.rightPassphrase

        let started = form.start(key: key, store: store, secrets: secrets, verifier: verifier.verify)
        let task = try #require(started)

        #expect(await task.value == .failed(.notStored))
        #expect(form.failure == .notStored)
        let slotIsStillEmpty = secrets.peek(key.id) == nil
        #expect(slotIsStillEmpty)
    }

    @Test func aFieldEditedDuringTheVerificationDoesNotReachTheSlot() async throws {
        let (store, dir) = tempStore(); defer { try? FileManager.default.removeItem(at: dir) }
        let secrets = InMemorySecretStore()
        let key = managedKey()
        let verifier = HeldVerifier(accepting: Self.rightPassphrase)
        let form = CorrectKeyPassphraseForm()
        form.passphrase = Self.rightPassphrase

        let started = form.start(key: key, store: store, secrets: secrets, verifier: verifier.verify)
        let task = try #require(started)
        _ = await verifier.entered.wait()
        // What a user can do to the sheet while `ssh-keygen` runs.
        form.passphrase = Self.wrongPassphrase
        verifier.release.signal()
        let outcome = await task.value

        #expect(outcome == .stored)
        // The slot holds what was VERIFIED, not what the field says now.
        let slotHoldsTheVerifiedOne = secrets.peek(key.id) == Self.rightPassphrase
        #expect(slotHoldsTheVerifiedOne)
        let toolWasAskedAboutTheVerifiedOne = verifier.lastPassphrase == Self.rightPassphrase
        #expect(toolWasAskedAboutTheVerifiedOne)
    }

    @Test func anOverlappingCorrectionIsRefused() async throws {
        let (store, dir) = tempStore(); defer { try? FileManager.default.removeItem(at: dir) }
        let key = managedKey()
        let verifier = HeldVerifier(accepting: Self.rightPassphrase)
        let form = CorrectKeyPassphraseForm()
        form.passphrase = Self.rightPassphrase

        let started = form.start(
            key: key, store: store, secrets: InMemorySecretStore(),
            verifier: verifier.verify)
        let first = try #require(started)
        _ = await verifier.entered.wait()
        #expect(form.isRunning)
        #expect(form.isSaveDisabled)
        let second = form.start(
            key: key, store: store, secrets: InMemorySecretStore(), verifier: verifier.verify)
        #expect(second == nil)
        verifier.release.signal()
        #expect(await first.value == .stored)
    }

    @Test func aCancelDuringTheVerificationStoresNothing() async throws {
        let (store, dir) = tempStore(); defer { try? FileManager.default.removeItem(at: dir) }
        let secrets = InMemorySecretStore()
        let key = managedKey()
        let verifier = HeldVerifier(accepting: Self.rightPassphrase)
        let form = CorrectKeyPassphraseForm()
        form.passphrase = Self.rightPassphrase

        let started = form.start(key: key, store: store, secrets: secrets, verifier: verifier.verify)
        let task = try #require(started)
        _ = await verifier.entered.wait()
        form.cancel()
        // The held verifier ignores the cancellation and answers "it opens" —
        // the case of a cancel landing after `ssh-keygen` already succeeded.
        verifier.release.signal()

        #expect(await task.value == .cancelled)
        #expect(secrets.storedIDs.isEmpty)
    }

    @Test func aCorrectionTimeoutIsItsOwnFailure() async throws {
        let (store, dir) = tempStore(); defer { try? FileManager.default.removeItem(at: dir) }
        let form = CorrectKeyPassphraseForm()
        form.passphrase = Self.rightPassphrase
        let started = form.start(key: managedKey(), store: store, secrets: InMemorySecretStore()) { _, _ in
            throw SSHKeyPassphraseTool.PassphraseToolError.timedOut
        }
        let task = try #require(started)
        #expect(await task.value == .failed(.timedOut))
        #expect(form.failure == .timedOut)
    }

    @Test func aKeyWhoseFileTurnsOutNotToBeEncryptedIsRefused() async throws {
        let (store, dir) = tempStore(); defer { try? FileManager.default.removeItem(at: dir) }
        let secrets = InMemorySecretStore()
        // The metadata says the file is encrypted (which is what offers this
        // action at all) and the file disagrees: every passphrase opens it,
        // including the empty one. `ssh-keygen -y` ignores `-P` for an
        // unencrypted key, so without the second probe ANY typed value would
        // verify and be stored.
        let verifier = OpensForAnything()
        let form = CorrectKeyPassphraseForm()
        form.passphrase = Self.wrongPassphrase

        let started = form.start(key: managedKey(), store: store, secrets: secrets, verifier: verifier.verify)
        let task = try #require(started)

        #expect(await task.value == .failed(.keyIsNotEncrypted))
        #expect(form.failure == .keyIsNotEncrypted)
        #expect(secrets.storedIDs.isEmpty)
    }

    @Test func aCorrectionAgainstAKeyFileThatIsGoneSaysSo() async throws {
        let (store, dir) = tempStore(); defer { try? FileManager.default.removeItem(at: dir) }
        let secrets = InMemorySecretStore()
        let form = CorrectKeyPassphraseForm()
        form.passphrase = Self.rightPassphrase

        let started = form.start(key: managedKey(), store: store, secrets: secrets) { _, _ in
            throw SSHKeyPassphraseTool.PassphraseToolError.keyFileMissing
        }
        let task = try #require(started)

        // Not the generic failure: "the file is not there" is something the
        // user can act on, and retyping the passphrase is not the action.
        #expect(await task.value == .failed(.keyFileMissing))
        #expect(form.failure == .keyFileMissing)
        #expect(secrets.storedIDs.isEmpty)
    }

    // MARK: - Changing the key file's passphrase

    @Test func changingTheFilesPassphraseReEncryptsItAndStoresTheNewValue() async throws {
        let (store, dir) = tempStore(); defer { try? FileManager.default.removeItem(at: dir) }
        let secrets = InMemorySecretStore()
        let key = managedKey()
        try store.add(key)
        try secrets.savePassword(Self.rightPassphrase, for: key.id)
        let verifier = ScriptedVerifier(accepting: Self.rightPassphrase)
        let changer = RecordingChanger()
        let form = filledChangeForm()

        let started = form.start(
            key: key, store: store, secrets: secrets,
            verifier: verifier.verify, changer: changer.change)
        let task = try #require(started)
        let outcome = await task.value

        #expect(outcome == .changed)
        #expect(changer.calls == 1)
        let theToolRewroteTheKeysOwnFile = changer.lastURL == store.privateKeyURL(for: key)
        #expect(theToolRewroteTheKeysOwnFile)
        let theToolWasGivenBothValues =
            changer.lastOld == Self.rightPassphrase && changer.lastNew == Self.replacementPassphrase
        #expect(theToolWasGivenBothValues)
        let slotFollowedTheFile = secrets.peek(key.id) == Self.replacementPassphrase
        #expect(slotFollowedTheFile)
    }

    @Test func aKeychainFailureAfterAGoodReEncryptionSaysTheFileChangedAnyway() async throws {
        let (store, dir) = tempStore(); defer { try? FileManager.default.removeItem(at: dir) }
        let secrets = UnreliableSecretStore(failsSaves: true)
        let key = managedKey()
        try store.add(key)
        let verifier = ScriptedVerifier(accepting: Self.rightPassphrase)
        let changer = RecordingChanger()
        let form = filledChangeForm()

        let started = form.start(
            key: key, store: store, secrets: secrets,
            verifier: verifier.verify, changer: changer.change)
        let task = try #require(started)
        let outcome = await task.value

        // NOT a failure: the file really was rewritten, and saying otherwise
        // would send the user back to a passphrase that no longer opens it.
        #expect(outcome == .changedButNotStored)
        #expect(form.failure == nil)
        // Positive check beside the negative one below: the rewrite happened.
        #expect(changer.calls == 1)
        let nothingReachedTheSlot = secrets.peek(key.id) == nil
        #expect(nothingReachedTheSlot)
    }

    @Test func anOldPassphraseThatDoesNotOpenTheKeyNeverReachesTheRewrite() async throws {
        let (store, dir) = tempStore(); defer { try? FileManager.default.removeItem(at: dir) }
        let secrets = InMemorySecretStore()
        let key = managedKey()
        try store.add(key)
        try secrets.savePassword(Self.rightPassphrase, for: key.id)
        let verifier = ScriptedVerifier(accepting: Self.rightPassphrase)
        let changer = RecordingChanger()
        let form = filledChangeForm()
        form.oldPassphrase = Self.wrongPassphrase

        let started = form.start(
            key: key, store: store, secrets: secrets,
            verifier: verifier.verify, changer: changer.change)
        let task = try #require(started)

        #expect(await task.value == .failed(.oldDoesNotOpenTheKey))
        #expect(form.failure == .oldDoesNotOpenTheKey)
        // The verification ran (positive) and the rewrite did not (negative).
        #expect(verifier.calls == 1)
        #expect(changer.calls == 0)
        let theOldStoredValueSurvived = secrets.peek(key.id) == Self.rightPassphrase
        #expect(theOldStoredValueSurvived)
    }

    @Test func changingAKeyOutsideTheAppsOwnDirectoryIsRefusedBeforeAnyToolRuns() async throws {
        let (store, dir) = tempStore(); defer { try? FileManager.default.removeItem(at: dir) }
        let secrets = InMemorySecretStore()
        let verifier = ScriptedVerifier(accepting: Self.rightPassphrase)
        let changer = RecordingChanger()
        let form = filledChangeForm()

        let started = form.start(
            key: unmanagedKey(), store: store, secrets: secrets,
            verifier: verifier.verify, changer: changer.change)
        let task = try #require(started)

        #expect(await task.value == .failed(.notManaged))
        #expect(form.failure == .notManaged)
        #expect(verifier.calls == 0)
        #expect(changer.calls == 0)
        #expect(secrets.storedIDs.isEmpty)
    }

    @Test func encryptingAKeyThatHadNoPassphraseRecordsThatItHasOneNow() async throws {
        let (store, dir) = tempStore(); defer { try? FileManager.default.removeItem(at: dir) }
        let secrets = InMemorySecretStore()
        let key = managedKey(encrypted: false)
        try store.add(key)
        let verifier = ScriptedVerifier(accepting: "")
        let changer = RecordingChanger()
        let form = filledChangeForm()
        form.oldPassphrase = ""

        let started = form.start(
            key: key, store: store, secrets: secrets,
            verifier: verifier.verify, changer: changer.change)
        let task = try #require(started)

        #expect(await task.value == .changed)
        let recorded = try #require(try store.all().first { $0.id == key.id })
        #expect(recorded.hasPassphrase)
        let slotHoldsTheNewOne = secrets.peek(key.id) == Self.replacementPassphrase
        #expect(slotHoldsTheNewOne)
    }

    @Test func fieldsEditedDuringTheRewriteReachNeitherTheToolNorTheSlot() async throws {
        let (store, dir) = tempStore(); defer { try? FileManager.default.removeItem(at: dir) }
        let secrets = InMemorySecretStore()
        let key = managedKey()
        try store.add(key)
        let changer = HeldChanger()
        let form = filledChangeForm()

        let started = form.start(
            key: key, store: store, secrets: secrets,
            verifier: { _, _ in true }, changer: changer.change)
        let task = try #require(started)
        _ = await changer.entered.wait()
        form.oldPassphrase = Self.wrongPassphrase
        form.newPassphrase = Self.wrongPassphrase
        form.newPassphraseConfirm = Self.wrongPassphrase
        changer.release.signal()

        #expect(await task.value == .changed)
        let theToolGotTheCapturedValues =
            changer.lastOld == Self.rightPassphrase && changer.lastNew == Self.replacementPassphrase
        #expect(theToolGotTheCapturedValues)
        let slotHoldsTheCapturedNewOne = secrets.peek(key.id) == Self.replacementPassphrase
        #expect(slotHoldsTheCapturedNewOne)
    }

    @Test func aCancelThatLandsAfterTheRewriteStillRecordsTheNewPassphrase() async throws {
        let (store, dir) = tempStore(); defer { try? FileManager.default.removeItem(at: dir) }
        let secrets = InMemorySecretStore()
        let key = managedKey()
        try store.add(key)
        let changer = HeldChanger()
        let form = filledChangeForm()

        let started = form.start(
            key: key, store: store, secrets: secrets,
            verifier: { _, _ in true }, changer: changer.change)
        let task = try #require(started)
        _ = await changer.entered.wait()
        // The file is being rewritten right now. Cancelling must NOT abandon
        // the record: the new passphrase would then be the only thing that
        // opens the key and nothing would know it.
        form.cancel()
        changer.release.signal()

        #expect(await task.value == .changed)
        let slotHoldsTheNewOne = secrets.peek(key.id) == Self.replacementPassphrase
        #expect(slotHoldsTheNewOne)
    }

    @Test func aCancelBeforeTheRewriteLeavesTheFileAlone() async throws {
        let (store, dir) = tempStore(); defer { try? FileManager.default.removeItem(at: dir) }
        let secrets = InMemorySecretStore()
        let key = managedKey()
        try store.add(key)
        let verifier = HeldVerifier(accepting: Self.rightPassphrase)
        let changer = RecordingChanger()
        let form = filledChangeForm()

        let started = form.start(
            key: key, store: store, secrets: secrets,
            verifier: verifier.verify, changer: changer.change)
        let task = try #require(started)
        _ = await verifier.entered.wait()
        form.cancel()
        verifier.release.signal()

        #expect(await task.value == .cancelled)
        #expect(changer.calls == 0)
        #expect(secrets.storedIDs.isEmpty)
    }

    @Test func aRewriteTimeoutIsItsOwnFailure() async throws {
        let (store, dir) = tempStore(); defer { try? FileManager.default.removeItem(at: dir) }
        let form = filledChangeForm()
        let started = form.start(
            key: managedKey(), store: store, secrets: InMemorySecretStore(),
            verifier: { _, _ in true },
            changer: { _, _, _ in throw SSHKeyPassphraseTool.PassphraseToolError.timedOut })
        let task = try #require(started)
        #expect(await task.value == .failed(.timedOut))
        #expect(form.failure == .timedOut)
    }

    @Test func anEmptyOrMismatchedNewPassphraseCannotBeSaved() {
        let form = ChangeKeyPassphraseForm()
        form.oldPassphrase = Self.rightPassphrase
        #expect(form.isSaveDisabled)          // new is empty
        form.newPassphrase = Self.replacementPassphrase
        #expect(form.isSaveDisabled)          // confirmation still empty
        #expect(form.passphrasesMismatch)
        form.newPassphraseConfirm = Self.replacementPassphrase
        #expect(form.isSaveDisabled == false)
    }

    @Test func aChangeAgainstAKeyFileThatIsGoneSaysSo() async throws {
        let (store, dir) = tempStore(); defer { try? FileManager.default.removeItem(at: dir) }
        let secrets = InMemorySecretStore()
        let form = filledChangeForm()

        let started = form.start(
            key: managedKey(), store: store, secrets: secrets,
            verifier: { _, _ in throw SSHKeyPassphraseTool.PassphraseToolError.keyFileMissing },
            changer: { _, _, _ in })
        let task = try #require(started)

        #expect(await task.value == .failed(.keyFileMissing))
        #expect(form.failure == .keyFileMissing)
        #expect(secrets.storedIDs.isEmpty)
    }

    @Test func aCancellationThrownOutOfTheRewriteIsReportedAsCancelled() async throws {
        let (store, dir) = tempStore(); defer { try? FileManager.default.removeItem(at: dir) }
        let secrets = InMemorySecretStore()
        let key = managedKey(encrypted: false)
        try store.add(key)
        let form = filledChangeForm()

        // What the REAL tool does when the run is cancelled: `SubprocessRunner`
        // throws `SubprocessCancelled`, `SSHKeyPassphraseTool` maps it to
        // `CancellationError`, and the rollback has already put the key file
        // back (`SSHKeyPassphraseToolTests`). The old `HeldChanger` case below
        // covers the other half — a changer that FINISHED and was cancelled
        // afterwards — and never this one.
        let started = form.start(
            key: key, store: store, secrets: secrets,
            verifier: { _, _ in true },
            changer: { _, _, _ in throw CancellationError() })
        let task = try #require(started)

        #expect(await task.value == .cancelled)
        // Nothing recorded, because nothing happened: the file is as it was.
        #expect(secrets.storedIDs.isEmpty)
        let recorded = try #require(try store.all().first { $0.id == key.id })
        #expect(recorded.hasPassphrase == false)
    }

    private func filledChangeForm() -> ChangeKeyPassphraseForm {
        let form = ChangeKeyPassphraseForm()
        form.oldPassphrase = Self.rightPassphrase
        form.newPassphrase = Self.replacementPassphrase
        form.newPassphraseConfirm = Self.replacementPassphrase
        return form
    }
}

/// A verifier that accepts exactly one passphrase, the way the key file does,
/// and counts how often it was asked.
private final class ScriptedVerifier: Sendable {
    private let accepted: String
    private let state = Mutex<(calls: Int, url: URL?)>((0, nil))

    init(accepting accepted: String) { self.accepted = accepted }

    var calls: Int { state.withLock { $0.calls } }
    var lastURL: URL? { state.withLock { $0.url } }

    var verify: CorrectKeyPassphraseForm.Verifier {
        { [self] url, passphrase in
            state.withLock { $0.calls += 1; $0.url = url }
            return passphrase == accepted
        }
    }
}

/// A verifier that answers `true` for every passphrase — an UNENCRYPTED key
/// file, which `ssh-keygen -y` opens whatever `-P` says.
private final class OpensForAnything: Sendable {
    private let state = Mutex<Int>(0)

    var calls: Int { state.withLock { $0 } }

    var verify: CorrectKeyPassphraseForm.Verifier {
        { [self] _, _ in
            state.withLock { $0 += 1 }
            return true
        }
    }
}

/// A verifier held open until the test raises `release` — only on its FIRST
/// call, which is the one whose window a test needs to reach into. Later calls
/// (the correction's empty-passphrase probe) answer at once, and like the key
/// file itself this accepts exactly one passphrase: a double that opened for
/// everything would now be an UNENCRYPTED key and refused as one.
private final class HeldVerifier: Sendable {
    let entered = AsyncSignal()
    let release = AsyncSignal()
    private let accepted: String
    private let state = Mutex<(first: String?, calls: Int)>((nil, 0))

    init(accepting accepted: String) { self.accepted = accepted }

    /// What the HELD call was asked about — the value captured when the run
    /// started, which is the whole point of the fixture.
    var lastPassphrase: String? { state.withLock { $0.first } }

    var verify: CorrectKeyPassphraseForm.Verifier {
        { [self] _, passphrase in
            let isFirstCall = state.withLock { state -> Bool in
                state.calls += 1
                if state.calls == 1 { state.first = passphrase }
                return state.calls == 1
            }
            if isFirstCall {
                entered.signal()
                _ = await release.wait()
            }
            return passphrase == accepted
        }
    }
}

/// A changer that records what `ssh-keygen -p` would have been given and
/// rewrites nothing.
private final class RecordingChanger: Sendable {
    private let state = Mutex<(calls: Int, url: URL?, old: String?, new: String?)>(
        (0, nil, nil, nil))

    var calls: Int { state.withLock { $0.calls } }
    var lastURL: URL? { state.withLock { $0.url } }
    var lastOld: String? { state.withLock { $0.old } }
    var lastNew: String? { state.withLock { $0.new } }

    var change: ChangeKeyPassphraseForm.Changer {
        { [self] url, old, new in
            state.withLock { $0.calls += 1; $0.url = url; $0.old = old; $0.new = new }
        }
    }
}

/// A changer held open until the test raises `release` — the window in which
/// the key file is mid-rewrite.
private final class HeldChanger: Sendable {
    let entered = AsyncSignal()
    let release = AsyncSignal()
    private let state = Mutex<(old: String?, new: String?)>((nil, nil))

    var lastOld: String? { state.withLock { $0.old } }
    var lastNew: String? { state.withLock { $0.new } }

    var change: ChangeKeyPassphraseForm.Changer {
        { [self] _, old, new in
            state.withLock { $0.old = old; $0.new = new }
            entered.signal()
            _ = await release.wait()
        }
    }
}
