import Foundation
import Testing
@testable import macSCPCore

@Suite("EmbeddedKeyPorter")
struct EmbeddedKeyPorterTests {
    private func tempDir() -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-embedkey-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeStore(in dir: URL) -> ManagedKeyStore {
        ManagedKeyStore(directory: dir.appendingPathComponent("state", isDirectory: true))
    }

    /// Generates a REAL ed25519 key into the store's key directory and
    /// registers it as a managed key (same `ssh-keygen` route the M17/M18 key
    /// tests use), so `embed` sees exactly what production sees.
    @discardableResult
    private func addManagedKey(
        to store: ManagedKeyStore, secrets: any SecretStore,
        name: String = "work", comment: String = "work-key", passphrase: String? = nil
    ) throws -> ManagedKey {
        let generated = try SSHKeyGenerator.generate(
            type: .ed25519, comment: comment, passphrase: passphrase, into: store.keyDirectory)
        let key = ManagedKey(
            name: name, comment: comment, type: .ed25519, fingerprint: generated.fingerprint,
            publicKeyOpenSSH: generated.publicKeyOpenSSH, createdAt: Date(),
            hasPassphrase: passphrase != nil, fileName: generated.privateKeyURL.lastPathComponent)
        try store.add(key)
        if let passphrase { try secrets.savePassword(passphrase, for: key.id) }
        return key
    }

    private func path(of key: ManagedKey, in store: ManagedKeyStore) -> String {
        store.keyDirectory.appendingPathComponent(key.fileName).path(percentEncoded: false)
    }

    private func permissions(of path: String) throws -> Int16 {
        let value = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions]
        return (value as? NSNumber)?.int16Value ?? -1
    }

    // MARK: - embed

    @Test func embedsOnlyManagedKeys() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = makeStore(in: dir)
        let secrets = InMemorySecretStore()
        let key = try addManagedKey(to: store, secrets: secrets, name: "prod", comment: "prod-key")

        let embedded = try #require(
            try EmbeddedKeyPorter.embed(
                keyPath: path(of: key, in: store), includePassphrase: false,
                store: store, secrets: secrets))
        #expect(embedded.name == "prod")
        #expect(embedded.comment == "prod-key")
        #expect(embedded.type == .ed25519)
        #expect(embedded.fingerprint == key.fingerprint)
        #expect(embedded.hasPassphrase == false)
        #expect(embedded.passphrase == nil)
        #expect(embedded.fileContents
            == (try Data(contentsOf: URL(fileURLWithPath: path(of: key, in: store)))))

        // A readable private key OUTSIDE the store (the `~/.ssh/id_ed25519`
        // case) is never ours to carry — nil, and its bytes never appear
        // anywhere in the result.
        let external = dir.appendingPathComponent("id_ed25519")
        try Data("EXTERNAL PRIVATE KEY".utf8).write(to: external)
        #expect(try EmbeddedKeyPorter.embed(
            keyPath: external.path(percentEncoded: false), includePassphrase: true,
            store: store, secrets: secrets) == nil)

        // An UNREADABLE external file (mode 0000) must behave the same: nil,
        // never a thrown "permission denied". An implementation that opens
        // the path before deciding ownership fails right here.
        let locked = dir.appendingPathComponent("locked_key")
        try Data("EXTERNAL PRIVATE KEY".utf8).write(to: locked)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o000], ofItemAtPath: locked.path(percentEncoded: false))
        #expect(try EmbeddedKeyPorter.embed(
            keyPath: locked.path(percentEncoded: false), includePassphrase: true,
            store: store, secrets: secrets) == nil)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: locked.path(percentEncoded: false))

        // No key path at all, and a path that does not exist: both nil, no throw.
        #expect(try EmbeddedKeyPorter.embed(
            keyPath: nil, includePassphrase: true, store: store, secrets: secrets) == nil)
        #expect(try EmbeddedKeyPorter.embed(
            keyPath: dir.appendingPathComponent("missing").path(percentEncoded: false),
            includePassphrase: true, store: store, secrets: secrets) == nil)
    }

    /// Second leg of the "external paths are never READ" invariant: the path
    /// is a FIFO, which cannot be read like a file at all. Opening it for
    /// reading either blocks until a writer shows up (a `FileHandle`/`open`
    /// based read) or fails outright (`Data(contentsOf:)` rejects non-regular
    /// files) — so any implementation that touches the path either hangs,
    /// which the watchdog below turns into a failure, or throws instead of
    /// returning nil. Only an implementation that never goes near the path
    /// passes. (What no in-process test can catch is a read whose error is
    /// swallowed by `try?`; `embedReadsNothingBeforeDecidingOwnership` covers
    /// that leg at the source level.)
    @Test func embedNeverOpensAnExternalKeyPath() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = makeStore(in: dir)
        let secrets = InMemorySecretStore()
        try addManagedKey(to: store, secrets: secrets)

        let fifoPath = dir.appendingPathComponent("external-fifo").path(percentEncoded: false)
        #expect(mkfifo(fifoPath, 0o600) == 0)

        let outcome = TestBox<Result<EmbeddedKey?, any Error>?>(nil)
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            outcome.value = Result {
                try EmbeddedKeyPorter.embed(
                    keyPath: fifoPath, includePassphrase: true, store: store, secrets: secrets)
            }
            finished.signal()
        }

        if finished.wait(timeout: .now() + 10) == .timedOut {
            Issue.record("embed opened an external key path (blocked reading the FIFO)")
            // Unblock the stuck reader so it does not linger for the rest of
            // the suite: opening the FIFO for writing releases its open().
            let fd = open(fifoPath, O_WRONLY | O_NONBLOCK)
            if fd >= 0 { close(fd) }
            _ = finished.wait(timeout: .now() + 10)
        } else {
            #expect(try #require(outcome.value).get() == nil)
        }
    }

    /// `#filePath` here is
    /// `<repoRoot>/Tests/macSCPCoreTests/EmbeddedKeyPorterTests.swift`; three
    /// `deletingLastPathComponent()` calls recover the repo root regardless
    /// of `swift test`'s working directory (same trick as
    /// `LocalizableStringsTests`).
    private static let porterSource: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Sources/macSCPCore/Sessions/EmbeddedKeyPorter.swift")

    /// Third leg, and the only one that can see a read whose failure is
    /// swallowed: `_ = try? Data(contentsOf: keyPath)` placed before the
    /// ownership check would be invisible to every behavioural test above,
    /// yet it would have pulled `~/.ssh/id_ed25519` into memory. So this is a
    /// source guard (same spirit as `LocalizableStringsTests`): inside
    /// `embed`, the ownership decision must textually precede every
    /// file-reading construct, which is what keeps a later refactor from
    /// quietly moving the read above the guard.
    @Test func embedReadsNothingBeforeDecidingOwnership() throws {
        let source = try String(contentsOf: Self.porterSource, encoding: .utf8)
        let start = try #require(source.range(of: "public static func embed("))
        let end = try #require(source.range(of: "public static func materialize("))
        // Comments are stripped so prose about reading files cannot trip the scan.
        let body = source[start.upperBound..<end.lowerBound]
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")

        let ownership = try #require(body.range(of: "store.key(forPath:"))
        for construct in [
            "Data(contentsOf", "String(contentsOf", "FileHandle(", "contentsOfFile",
            "FileManager.default.contents(",
        ] {
            guard let read = body.range(of: construct) else { continue }
            #expect(
                read.lowerBound > ownership.upperBound,
                "\(construct) must not run before the managed-key lookup in embed")
        }
    }

    @Test func embedCarriesThePassphraseOnlyWhenAsked() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = makeStore(in: dir)
        let secrets = InMemorySecretStore()
        let key = try addManagedKey(to: store, secrets: secrets, passphrase: "s3cr3t")
        let keyPath = path(of: key, in: store)

        let without = try #require(
            try EmbeddedKeyPorter.embed(
                keyPath: keyPath, includePassphrase: false, store: store, secrets: secrets))
        // The FACT that the key is encrypted still travels (the import side
        // has to know) — the passphrase itself does not.
        #expect(without.hasPassphrase == true)
        #expect(without.passphrase == nil)

        let with = try #require(
            try EmbeddedKeyPorter.embed(
                keyPath: keyPath, includePassphrase: true, store: store, secrets: secrets))
        #expect(with.hasPassphrase == true)
        #expect(with.passphrase == "s3cr3t")

        // A key without a passphrase never gets one, even when asked.
        let plain = try addManagedKey(to: store, secrets: secrets, name: "plain")
        let plainEmbedded = try #require(
            try EmbeddedKeyPorter.embed(
                keyPath: path(of: plain, in: store), includePassphrase: true,
                store: store, secrets: secrets))
        #expect(plainEmbedded.hasPassphrase == false)
        #expect(plainEmbedded.passphrase == nil)
    }

    // MARK: - materialize

    @Test func materializeWritesThePrivateKeyWith0600() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let source = makeStore(in: dir)
        let secrets = InMemorySecretStore()
        let key = try addManagedKey(to: source, secrets: secrets)
        let embedded = try #require(
            try EmbeddedKeyPorter.embed(
                keyPath: path(of: key, in: source), includePassphrase: false,
                store: source, secrets: secrets))

        let target = ManagedKeyStore(directory: dir.appendingPathComponent("imported"))
        let targetSecrets = InMemorySecretStore()
        let path = try EmbeddedKeyPorter.materialize(
            embedded, store: target, secrets: targetSecrets)

        #expect(try permissions(of: path) == 0o600)
        #expect(try permissions(of: target.keyDirectory.path(percentEncoded: false)) == 0o700)
        #expect(try target.key(forPath: path) != nil)
        #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == embedded.fileContents)
        // The materialized file is a usable key, not just matching bytes.
        _ = try SSHPrivateKeyLoader.authentication(username: "t", keyPath: path, passphrase: nil)
    }

    @Test func materializeHardensAPreexistingKeyDirectoryTo0700() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let source = makeStore(in: dir)
        let secrets = InMemorySecretStore()
        let key = try addManagedKey(to: source, secrets: secrets)
        let embedded = try #require(
            try EmbeddedKeyPorter.embed(
                keyPath: path(of: key, in: source), includePassphrase: false,
                store: source, secrets: secrets))

        let target = ManagedKeyStore(directory: dir.appendingPathComponent("imported"))
        // Pre-existing, world-readable key directory: `createDirectory`'s
        // `attributes:` would leave it as-is, so the permissions have to be
        // set explicitly.
        try FileManager.default.createDirectory(
            at: target.keyDirectory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o777])
        #expect(try permissions(of: target.keyDirectory.path(percentEncoded: false)) == 0o777)

        _ = try EmbeddedKeyPorter.materialize(embedded, store: target, secrets: InMemorySecretStore())
        #expect(try permissions(of: target.keyDirectory.path(percentEncoded: false)) == 0o700)
    }

    @Test func materializeUsesAFreshIDAndStoresThePassphraseUnderIt() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let source = makeStore(in: dir)
        let secrets = InMemorySecretStore()
        let key = try addManagedKey(to: source, secrets: secrets, passphrase: "s3cr3t")
        let embedded = try #require(
            try EmbeddedKeyPorter.embed(
                keyPath: path(of: key, in: source), includePassphrase: true,
                store: source, secrets: secrets))

        let target = ManagedKeyStore(directory: dir.appendingPathComponent("imported"))
        let targetSecrets = InMemorySecretStore()
        let path = try EmbeddedKeyPorter.materialize(
            embedded, store: target, secrets: targetSecrets)

        let imported = try #require(try target.key(forPath: path))
        #expect(imported.id != key.id)
        #expect(imported.fileName == imported.id.uuidString)
        #expect(imported.hasPassphrase == true)
        #expect(imported.fingerprint == key.fingerprint)
        #expect(imported.name == key.name)
        // The passphrase lives in the Keychain under the NEW id only.
        #expect(try targetSecrets.password(for: imported.id) == "s3cr3t")
        #expect(try targetSecrets.password(for: key.id) == nil)
        // …and nowhere on disk: neither the key file nor the metadata JSON
        // may contain it.
        let onDisk = try Data(contentsOf: URL(fileURLWithPath: path))
        #expect(!String(decoding: onDisk, as: UTF8.self).contains("s3cr3t"))
        let metadata = try Data(
            contentsOf: target.keyDirectory.deletingLastPathComponent()
                .appendingPathComponent("managed_keys.json"))
        #expect(!String(decoding: metadata, as: UTF8.self).contains("s3cr3t"))
    }

    @Test func materializeCleansUpTheFileAndKeychainSlotWhenAStepFails() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let source = makeStore(in: dir)
        let secrets = InMemorySecretStore()
        let key = try addManagedKey(to: source, secrets: secrets, passphrase: "s3cr3t")
        let embedded = try #require(
            try EmbeddedKeyPorter.embed(
                keyPath: path(of: key, in: source), includePassphrase: true,
                store: source, secrets: secrets))

        let target = ManagedKeyStore(directory: dir.appendingPathComponent("imported"))
        let targetSecrets = RecordingSecretStore(failSaves: true)
        #expect(throws: (any Error).self) {
            _ = try EmbeddedKeyPorter.materialize(embedded, store: target, secrets: targetSecrets)
        }
        // Nothing left behind: no key file, no metadata entry, and the
        // Keychain slot under the fresh id was cleared even though the save
        // itself had failed.
        let leftovers = (try? FileManager.default.contentsOfDirectory(
            atPath: target.keyDirectory.path(percentEncoded: false))) ?? []
        #expect(leftovers.isEmpty)
        #expect(try target.all().isEmpty)
        #expect(targetSecrets.stored.isEmpty)
        #expect(targetSecrets.deleted.count == 1)
    }

    /// The import file's metadata is a claim, not a fact: where the key
    /// material can be inspected, the derived type/fingerprint win over
    /// whatever the file declared.
    @Test func materializeTakesTypeAndFingerprintFromTheKeyMaterial() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let source = makeStore(in: dir)
        let secrets = InMemorySecretStore()
        let key = try addManagedKey(to: source, secrets: secrets)
        var embedded = try #require(
            try EmbeddedKeyPorter.embed(
                keyPath: path(of: key, in: source), includePassphrase: false,
                store: source, secrets: secrets))
        // The file claims an RSA key; the bytes are the ed25519 key above.
        embedded.type = .rsa(bits: 4096)

        let target = ManagedKeyStore(directory: dir.appendingPathComponent("imported"))
        let importedPath = try EmbeddedKeyPorter.materialize(
            embedded, store: target, secrets: InMemorySecretStore())

        let imported = try #require(try target.key(forPath: importedPath))
        #expect(imported.type == .ed25519)
        #expect(imported.fingerprint == key.fingerprint)
    }

    /// A crafted export can name the fingerprint of a key the victim knows
    /// ("SHA256:<their prod key>") next to foreign key bytes. Importing it
    /// would put that fingerprint in the keys list, so anyone checking "is
    /// this my prod key?" by fingerprint would be lied to. A declared
    /// fingerprint the material does not have is therefore a hard stop.
    @Test func materializeRejectsADeclaredFingerprintTheKeyMaterialDoesNotHave() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let source = makeStore(in: dir)
        let secrets = InMemorySecretStore()
        let key = try addManagedKey(to: source, secrets: secrets, passphrase: "s3cr3t")
        var embedded = try #require(
            try EmbeddedKeyPorter.embed(
                keyPath: path(of: key, in: source), includePassphrase: true,
                store: source, secrets: secrets))
        // The victim's real fingerprint, claimed for someone else's key.
        let victim = try addManagedKey(to: source, secrets: secrets, name: "prod")
        embedded.fingerprint = victim.fingerprint
        #expect(embedded.fingerprint != key.fingerprint)

        let target = ManagedKeyStore(directory: dir.appendingPathComponent("imported"))
        let targetSecrets = RecordingSecretStore()
        #expect(throws: EmbeddedKeyPorter.PorterError.fingerprintMismatch) {
            _ = try EmbeddedKeyPorter.materialize(embedded, store: target, secrets: targetSecrets)
        }
        // The usual rollback: no key file, no metadata entry, no Keychain slot.
        let leftovers = (try? FileManager.default.contentsOfDirectory(
            atPath: target.keyDirectory.path(percentEncoded: false))) ?? []
        #expect(leftovers.isEmpty)
        #expect(try target.all().isEmpty)
        #expect(targetSecrets.stored.isEmpty)
    }

    /// Same invariant one step later: the Keychain write succeeded and the
    /// metadata write is what fails. Both the file and the Keychain slot have
    /// to go.
    @Test func materializeCleansUpWhenTheMetadataWriteFails() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let source = makeStore(in: dir)
        let secrets = InMemorySecretStore()
        let key = try addManagedKey(to: source, secrets: secrets, passphrase: "s3cr3t")
        let embedded = try #require(
            try EmbeddedKeyPorter.embed(
                keyPath: path(of: key, in: source), includePassphrase: true,
                store: source, secrets: secrets))

        let targetDirectory = dir.appendingPathComponent("imported")
        let target = ManagedKeyStore(directory: targetDirectory)
        // `managed_keys.json` as a DIRECTORY makes every store read/write fail.
        try FileManager.default.createDirectory(
            at: targetDirectory.appendingPathComponent("managed_keys.json"),
            withIntermediateDirectories: true)

        let targetSecrets = RecordingSecretStore()
        #expect(throws: (any Error).self) {
            _ = try EmbeddedKeyPorter.materialize(embedded, store: target, secrets: targetSecrets)
        }
        let leftovers = (try? FileManager.default.contentsOfDirectory(
            atPath: target.keyDirectory.path(percentEncoded: false))) ?? []
        #expect(leftovers.isEmpty)
        // The passphrase HAD been written under the fresh id and was rolled
        // back again — no secret survives the failed import.
        #expect(targetSecrets.stored.isEmpty)
        #expect(targetSecrets.deleted == targetSecrets.savedIDs)
        #expect(targetSecrets.savedIDs.count == 1)
    }
}

/// Thread-safe box so a value produced on a background queue can be read back
/// after a semaphore hand-off without tripping concurrency checking.
private final class TestBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: T
    init(_ value: T) { storage = value }
    var value: T {
        get { lock.lock(); defer { lock.unlock() }; return storage }
        set { lock.lock(); defer { lock.unlock() }; storage = newValue }
    }
}

/// Test double for the rollback legs: like `InMemorySecretStore`, but it
/// records which ids were written/deleted and can be told to fail every save.
/// (`FailingSecretStore` in `SessionListViewModelTests` covers the same
/// failure mode but is file-private there, and only a recording double can
/// show that the fresh id's slot was actually cleared — the id itself never
/// leaves `materialize`.)
private final class RecordingSecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [UUID: String] = [:]
    private var savedOrder: [UUID] = []
    private var deletedOrder: [UUID] = []
    private let failSaves: Bool

    init(failSaves: Bool = false) { self.failSaves = failSaves }

    var stored: [UUID: String] { lock.lock(); defer { lock.unlock() }; return storage }
    var savedIDs: [UUID] { lock.lock(); defer { lock.unlock() }; return savedOrder }
    var deleted: [UUID] { lock.lock(); defer { lock.unlock() }; return deletedOrder }

    func savePassword(_ password: String, for sessionID: UUID) throws {
        if failSaves { throw KeychainError(status: -1) }
        lock.lock(); defer { lock.unlock() }
        storage[sessionID] = password
        savedOrder.append(sessionID)
    }

    func password(for sessionID: UUID) throws -> String? {
        lock.lock(); defer { lock.unlock() }
        return storage[sessionID]
    }

    func deletePassword(for sessionID: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        storage[sessionID] = nil
        deletedOrder.append(sessionID)
    }
}
