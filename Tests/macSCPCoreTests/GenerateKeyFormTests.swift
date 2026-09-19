import Foundation
import Synchronization
import Testing
@testable import macSCPCore

/// `GenerateKeyForm`, the state behind the "Generate SSH Key" sheet.
///
/// `ssh-keygen` is awaited, so the sheet's fields are live while it runs.
/// These tests hold the generator open on a signal, change the fields the way
/// a user typing into the sheet would, and then let it finish — so "the
/// fields changed during the run" is the test's own sequence, not a race.
/// Nothing here runs `ssh-keygen`: the generator writes two placeholder files
/// where the real one would, so the tests can see whether they are removed.
@Suite("GenerateKeyForm", .timeLimit(.minutes(1)))
@MainActor
struct GenerateKeyFormTests {
    /// Never written into an `#expect` expression's source text (CLAUDE.md,
    /// "A value a test must not leak has two exits, not one").
    private static let passphrase = "fixture-passphrase-first"

    private func tempStore() -> (ManagedKeyStore, URL) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-genform-\(UUID().uuidString)")
        return (ManagedKeyStore(directory: dir), dir)
    }

    private func filledForm() -> GenerateKeyForm {
        let form = GenerateKeyForm()
        form.name = "work"
        form.comment = "work-key"
        form.typeChoice = .ed25519
        form.passphrase = Self.passphrase
        form.passphraseConfirm = Self.passphrase
        return form
    }

    @Test func fieldsEditedDuringTheRunDoNotReachTheRecord() async throws {
        let (store, dir) = tempStore(); defer { try? FileManager.default.removeItem(at: dir) }
        let secrets = InMemorySecretStore()
        let generator = HeldGenerator()
        let form = filledForm()

        let task = try #require(form.start(store: store, secrets: secrets, generator: generator.generate))
        _ = await generator.entered.wait()
        // What a user can do to the sheet while the tool runs.
        form.name = "edited"
        form.comment = "edited"
        form.typeChoice = .rsa
        form.passphrase = ""
        form.passphraseConfirm = ""
        generator.release.signal()
        let outcome = await task.value

        #expect(outcome == .generated(keptPassphrase: true))
        let keys = try store.all()
        #expect(keys.count == 1)
        let key = try #require(keys.first)
        #expect(key.name == "work")
        #expect(key.comment == "work-key")
        #expect(key.type == .ed25519)
        #expect(key.hasPassphrase)
        // The Keychain slot holds the passphrase `ssh-keygen` was given.
        let given = generator.received
        let generatorGotThePassphrase = given?.passphrase == Self.passphrase
        let slotHoldsThePassphrase = (try secrets.password(for: key.id)) == Self.passphrase
        #expect(generatorGotThePassphrase)
        #expect(slotHoldsThePassphrase)
        #expect(given?.type == .ed25519)
    }

    @Test func aCancelDuringTheRunRecordsNothingAndRemovesTheFiles() async throws {
        let (store, dir) = tempStore(); defer { try? FileManager.default.removeItem(at: dir) }
        let secrets = InMemorySecretStore()
        let generator = HeldGenerator()
        let form = filledForm()

        let task = try #require(form.start(store: store, secrets: secrets, generator: generator.generate))
        _ = await generator.entered.wait()
        form.cancel()
        // The held generator ignores the cancellation and finishes, files
        // written — the case of a cancel that lands after `ssh-keygen` has
        // already produced the key.
        generator.release.signal()
        let outcome = await task.value

        #expect(outcome == .cancelled)
        #expect(try store.all().isEmpty)
        #expect(secrets.storedIDs.isEmpty)
        let written = try #require(generator.writtenFiles)
        // Positive: the generator did write them, so their absence below is
        // the removal and not a file that was never there.
        #expect(written.count == 2)
        for file in written {
            #expect(FileManager.default.fileExists(atPath: file.path(percentEncoded: false)) == false, "\(file.lastPathComponent)")
        }
        #expect(form.isGenerating == false)
    }

    @Test func anOverlappingStartIsRefused() async throws {
        let (store, dir) = tempStore(); defer { try? FileManager.default.removeItem(at: dir) }
        let generator = HeldGenerator()
        let form = filledForm()

        let first = try #require(form.start(store: store, secrets: InMemorySecretStore(), generator: generator.generate))
        _ = await generator.entered.wait()
        #expect(form.isGenerating)
        #expect(form.isGenerateDisabled)
        #expect(form.start(store: store, secrets: InMemorySecretStore(), generator: generator.generate) == nil)
        generator.release.signal()
        _ = await first.value
        #expect(try store.all().count == 1)
    }

    @Test func aTimeoutIsItsOwnFailure() async throws {
        let (store, dir) = tempStore(); defer { try? FileManager.default.removeItem(at: dir) }
        let form = filledForm()
        let task = try #require(form.start(store: store, secrets: InMemorySecretStore()) { _, _, _, _ in
            throw SSHKeyGenerator.SSHKeyGenError.timedOut
        })
        #expect(await task.value == .failed(.timedOut))
        #expect(form.failure == .timedOut)
    }

    @Test func anyOtherFailureIsTheGenericOne() async throws {
        let (store, dir) = tempStore(); defer { try? FileManager.default.removeItem(at: dir) }
        let form = filledForm()
        let task = try #require(form.start(store: store, secrets: InMemorySecretStore()) { _, _, _, _ in
            throw SSHKeyGenerator.SSHKeyGenError.keygenFailed(status: 1)
        })
        #expect(await task.value == .failed(.failed))
        #expect(form.failure == .failed)
    }
}

/// A generator held open until the test raises `release`. It records what it
/// was asked for and writes a private and a public placeholder file into the
/// key directory, as `ssh-keygen` would.
private final class HeldGenerator: Sendable {
    struct Request: Sendable {
        let type: KeyType
        let passphrase: String?
    }

    let entered = AsyncSignal()
    let release = AsyncSignal()
    private let state = Mutex<(request: Request?, files: [URL]?)>((nil, nil))

    var received: Request? { state.withLock { $0.request } }
    var writtenFiles: [URL]? { state.withLock { $0.files } }

    var generate: GenerateKeyForm.Generator {
        { [self] type, _, passphrase, directory in
            state.withLock { $0.request = Request(type: type, passphrase: passphrase) }
            entered.signal()
            _ = await release.wait()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let privateKey = directory.appendingPathComponent(UUID().uuidString)
            let publicKey = directory.appendingPathComponent(privateKey.lastPathComponent + ".pub")
            try Data("placeholder".utf8).write(to: privateKey)
            try Data("placeholder.pub".utf8).write(to: publicKey)
            state.withLock { $0.files = [privateKey, publicKey] }
            return SSHKeyGenerator.GeneratedKey(
                privateKeyURL: privateKey,
                publicKeyOpenSSH: "ssh-ed25519 AAAAplaceholder work-key",
                fingerprint: "SHA256:placeholder")
        }
    }
}
