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
        #expect(embedded.fingerprint == key.fingerprint)
        #expect(embedded.hasPassphrase == false)
        #expect(embedded.passphrase == nil)
        // The public key is not secret and is already in `ManagedKey`, so it
        // travels unconditionally — `materialize` must not have to re-derive
        // it (which it cannot do for an encrypted key exported without its
        // passphrase).
        #expect(embedded.publicKeyOpenSSH == key.publicKeyOpenSSH)
        #expect(!embedded.publicKeyOpenSSH.isEmpty)
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
    @Test func embedNeverOpensAnExternalKeyPath() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = makeStore(in: dir)
        let secrets = InMemorySecretStore()
        try addManagedKey(to: store, secrets: secrets)

        let fifoPath = dir.appendingPathComponent("external-fifo").path(percentEncoded: false)
        #expect(mkfifo(fifoPath, 0o600) == 0)

        let outcome = TestBox<Result<EmbeddedKey?, any Error>?>(nil)
        let finished = AsyncSignal()
        // A dedicated thread, not `DispatchQueue.global()`: `embed` may block
        // forever here (that is the defect this test exists to catch), and a
        // block submitted to a shared queue would sit unscheduled on a
        // CPU-poor CI runner for longer than the watchdog below allows. That
        // failed the test for a reason that has nothing to do with the
        // invariant — observed on CI, where BOTH waits below timed out, which
        // is only possible if the work never ran at all (had `embed` really
        // blocked on the FIFO, the O_WRONLY open would have released it and
        // the second wait would have returned at once). `Thread` is scheduled
        // on its own and cannot be starved by pool work.
        //
        // The waiting side, by contrast, is an `await`: a semaphore here held
        // a cooperative-pool thread for the whole watchdog (CLAUDE.md, "Tests
        // never block the cooperative pool"), which is exactly the starvation
        // the comment above describes, caused from this side of the handoff.
        Thread.detachNewThread {
            outcome.value = Result {
                try EmbeddedKeyPorter.embed(
                    keyPath: fifoPath, includePassphrase: true, store: store, secrets: secrets)
            }
            finished.signal()
        }

        if await finished.wait(timeout: .seconds(10)) != .signalled {
            Issue.record("embed opened an external key path (blocked reading the FIFO)")
            // Unblock the stuck reader so it does not linger for the rest of
            // the suite: opening the FIFO for writing releases its open().
            let fd = open(fifoPath, O_WRONLY | O_NONBLOCK)
            if fd >= 0 { close(fd) }
            _ = await finished.wait(timeout: .seconds(10))
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
    /// yet it would have pulled `~/.ssh/id_ed25519` into memory.
    ///
    /// So this is a **lint over the text of `embed`'s body** (same spirit as
    /// `LocalizableStringsTests`), and it is worth being precise about what
    /// that does and does not buy:
    ///
    /// - It catches the refactor that matters in practice — someone moving or
    ///   adding a read above the ownership guard inside `embed`.
    /// - It does NOT prove "no read happens first". A read reached through a
    ///   helper — in this file or any other — is outside the slice and passes
    ///   unseen, and the construct list below is a list, not a grammar. A
    ///   reviewer, not this test, is what stops a deliberate bypass.
    ///
    /// The list is deliberately broad (Foundation, `AsyncBytes` and the POSIX
    /// spellings), because the point is to trip over an accident — and it
    /// matches the CALL rather than the receiver, so the same read spelled a
    /// different way trips the same entry: `FileManager().contents(atPath:)` is
    /// `FileManager.default.contents(atPath:)`, and `Data.init(contentsOf:)` is
    /// `Data(contentsOf:)`.
    @Test func embedReadsNothingBeforeDecidingOwnership() throws {
        let source = try String(contentsOf: Self.porterSource, encoding: .utf8)
        switch Self.readsBeforeOwnership(inEmbedBodyOf: source) {
        case .anchorsLost(let why):
            Issue.record("\(why); re-anchor this source lint")
        case .reads(let found):
            #expect(found.isEmpty, "\(found) must not run before the managed-key lookup in embed")
        }
    }

    /// The lint above is only worth its comment if it cannot be walked past by
    /// writing the same read differently. Each mutant below is a real read of
    /// `keyPath`, inserted immediately above the ownership guard — spelled the
    /// way this file's own style would wrap it.
    @Test func embedSourceLintCatchesAReadHoweverItIsWrapped() throws {
        let mutants = [
            // The reviewer's two: both are ordinary line wraps, and both used
            // to keep the suite green.
            "_ = try? Data(\n            contentsOf: URL(fileURLWithPath: keyPath))",
            "_ = FileManager.default.contents(\n            atPath: keyPath)",
            // Three more of the same kind, each breaking a different needle:
            // a handle whose opening paren wrapped,
            "_ = FileHandle\n            (forReadingAtPath: keyPath)",
            // an explicit `.init` that ALSO wrapped (normalizing `.init(` away
            // is not enough once the label moved to the next line),
            "_ = try? Data.init(\n            contentsOf: URL(fileURLWithPath: keyPath))",
            // and a stream whose receiver and call parted company.
            "_ = InputStream\n            (fileAtPath: keyPath)",
            // Two real reads past the OLD needle list, found against this
            // very source: `.contentsEqual` opens and reads `keyPath` to
            // compare its bytes against another file, and `copyItem` reads
            // `keyPath`'s bytes out to a destination — neither is
            // `.contents(atPath` nor any `(contentsOf` spelling, so both used
            // to walk straight past the lint.
            "_ = FileManager.default.contentsEqual(\n            atPath: keyPath, andPath: keyPath)",
            "_ = try? FileManager.default.copyItem(\n            atPath: keyPath, toPath: keyPath)",
            // Controls: reads that the literal-text scan already caught, kept
            // so a future rewrite cannot lose them while chasing the wraps.
            "_ = try? Data.init(contentsOf: URL(fileURLWithPath: keyPath))",
            "_ = FileManager\n            .default\n            .contents(atPath: keyPath)",
            "_ = try? String(\n            contentsOfFile: keyPath, encoding: .utf8)",
        ]
        let source = try String(contentsOf: Self.porterSource, encoding: .utf8)
        let anchor = try #require(source.range(of: "guard let key = try store.key(forPath:"))
        for mutant in mutants {
            let mutated = source.replacingCharacters(
                in: anchor.lowerBound..<anchor.lowerBound, with: mutant + "\n        ")
            switch Self.readsBeforeOwnership(inEmbedBodyOf: mutated) {
            case .anchorsLost(let why):
                Issue.record("\(why) for mutant <\(mutant)>")
            case .reads(let found):
                #expect(!found.isEmpty, "the source lint did not catch <\(mutant)>")
            }
        }
    }

    private enum EmbedBodyScan {
        /// The slice anchors no longer hold — the lint is scanning nothing and
        /// must be re-anchored rather than silently passing.
        case anchorsLost(String)
        /// The read constructs found BEFORE the ownership guard.
        case reads([String])
    }

    /// The scanner behind both tests above: everything in `embed`'s body that
    /// reads a file before `store.key(forPath:)` has decided the key is ours.
    private static func readsBeforeOwnership(inEmbedBodyOf source: String) -> EmbedBodyScan {
        guard let start = source.range(of: "public static func embed(") else {
            return .anchorsLost("`embed` not found")
        }
        guard let end = source.range(of: "public static func materialize(") else {
            return .anchorsLost("`materialize` not found")
        }
        // A refactor that swaps the two functions must FAIL this test, not
        // trap the whole process on an inverted range (`String.subscript`
        // requires lowerBound <= upperBound).
        guard start.upperBound <= end.lowerBound else {
            return .anchorsLost("`materialize` now precedes `embed`")
        }
        // Comments go first, so prose about reading files cannot trip the scan
        // — whole-line ones AND the tail of a line that ends in one. (A `//`
        // inside a string literal would truncate that line too; `embed` has no
        // string literals, and losing the tail of one can only ever make this
        // lint miss a read, which the reviewer it backs is there to catch.)
        let code = source[start.upperBound..<end.lowerBound]
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> Substring in
                guard let comment = line.range(of: "//") else { return line }
                return line[line.startIndex..<comment.lowerBound]
            }
            .joined(separator: "\n")
        // ALL whitespace then goes, needles included. Swift lets a call wrap
        // anywhere, so `Data(\n    contentsOf: …)` is the same call as
        // `Data(contentsOf: …)` and has to trip the same needle; matching the
        // literal text let an ordinary line wrap — the way this file's own
        // style breaks long calls — walk straight past this lint. Explicit
        // `.init` is normalized away for the same reason.
        //
        // The cost of joining without a separator is that tokens from adjacent
        // lines touch, so a needle could in principle be spelled by two
        // innocent line ends meeting. That fails LOUDLY (this test goes red and
        // the needle gets refined), which is the right way round for a lint
        // whose job is to trip over an accident.
        let body = code.filter { !$0.isWhitespace }
            .replacingOccurrences(of: ".init(", with: "(")

        guard let ownership = body.range(of: "store.key(forPath:") else {
            return .anchorsLost("the ownership guard is no longer recognizable")
        }
        // Every entry names the CALL — `(contentsOf` covers `Data`, `NSData`,
        // `String` and anything else initialized from a URL, `.contents`
        // covers not just `FileManager.default.contents(atPath:)` but also
        // `.contentsEqual(atPath:andPath:)`, which opens and reads the file at
        // `keyPath` just as surely to compare its bytes, and `copyItem` covers
        // `FileManager.default.copyItem(atPath:…)`/`.copyItem(at:…)`, which
        // reads the external file's bytes out to another path without ever
        // going through `Data` or `FileManager.contents`. The needles carry no
        // whitespace, matching the stripped body.
        return .reads([
            "(contentsOf", "contentsOfFile", ".contents",
            "FileHandle(", "InputStream(", ".resourceBytes", ".bytes(",
            "open(", "fopen", "mmap(", "copyItem",
        ].filter { needle in
            guard let read = body.range(of: needle) else { return false }
            return read.lowerBound < ownership.lowerBound
        })
    }

    /// A `managed_keys.json` entry outlives its file when the user deletes
    /// something under `keys/` by hand. A later caller embeds one key per
    /// login set, so this has to be a condition it can catch and report for
    /// THAT set ("key file missing") — a raw Cocoa error would abort the
    /// whole export over one orphaned entry. Dropping the key silently is not
    /// an option either: the user asked for it to be embedded.
    @Test func embedReportsAMissingKeyFileAsItsOwnCondition() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = makeStore(in: dir)
        let secrets = InMemorySecretStore()
        let key = try addManagedKey(to: store, secrets: secrets, name: "prod")
        let keyPath = path(of: key, in: store)
        try FileManager.default.removeItem(atPath: keyPath)

        #expect(throws: EmbeddedKeyPorter.PorterError.keyFileMissing(name: "prod")) {
            _ = try EmbeddedKeyPorter.embed(
                keyPath: keyPath, includePassphrase: false, store: store, secrets: secrets)
        }
    }

    /// Present but not readable as a file (here: a directory in its place).
    /// Also typed, and it carries the key's NAME rather than the underlying
    /// error, which would spell out the store path.
    @Test func embedReportsAnUnreadableKeyFileAsItsOwnCondition() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = makeStore(in: dir)
        let secrets = InMemorySecretStore()
        let key = try addManagedKey(to: store, secrets: secrets, name: "prod")
        let keyPath = path(of: key, in: store)
        try FileManager.default.removeItem(atPath: keyPath)
        try FileManager.default.createDirectory(
            atPath: keyPath, withIntermediateDirectories: false)

        #expect(throws: EmbeddedKeyPorter.PorterError.keyFileUnreadable(name: "prod")) {
            _ = try EmbeddedKeyPorter.embed(
                keyPath: keyPath, includePassphrase: false, store: store, secrets: secrets)
        }
    }

    /// A metadata entry whose `fileName` is not a single path component (only
    /// reachable by hand-editing `managed_keys.json`) resolves to no file at
    /// all, so it matches no path — and `embed` would have returned nil for it,
    /// i.e. "not ours, skip", silently leaving a key out of the export the user
    /// asked for. It is ours; it is just unusable, and that is what the
    /// `keyFileMissing` documentation promises.
    @Test func embedReportsATamperedFileNameAsAMissingKeyFile() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = makeStore(in: dir)
        let secrets = InMemorySecretStore()
        try store.add(ManagedKey(
            name: "prod", comment: "prod-key", type: .ed25519, fingerprint: "SHA256:x",
            publicKeyOpenSSH: "ssh-ed25519 AAAA prod-key", createdAt: Date(),
            hasPassphrase: false, fileName: "../outsider"))

        // The path such an entry names by the naive join — with a real file
        // planted there, so a matching-but-reading implementation would have
        // something to carry off.
        let outside = store.keyDirectory.deletingLastPathComponent()
            .appendingPathComponent("outsider")
        try Data("OUTSIDE PRIVATE KEY".utf8).write(to: outside)

        #expect(throws: EmbeddedKeyPorter.PorterError.keyFileMissing(name: "prod")) {
            _ = try EmbeddedKeyPorter.embed(
                keyPath: outside.path(percentEncoded: false), includePassphrase: true,
                store: store, secrets: secrets)
        }
        // The file outside the key directory is untouched, and a path that no
        // entry names at all is still a plain "not ours".
        #expect(try Data(contentsOf: outside) == Data("OUTSIDE PRIVATE KEY".utf8))
        #expect(try EmbeddedKeyPorter.embed(
            keyPath: dir.appendingPathComponent("elsewhere").path(percentEncoded: false),
            includePassphrase: true, store: store, secrets: secrets) == nil)
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
            embedded, store: target, secrets: targetSecrets).path

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
        let materialized = try EmbeddedKeyPorter.materialize(
            embedded, store: target, secrets: targetSecrets)
        let path = materialized.path

        // Reported to the caller, which holds the same value a second time
        // (a `.privateKey` login set's secret IS its key passphrase) and uses
        // this to NOT store it again under its own id (M19 review).
        #expect(materialized.storedPassphrase)
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

    /// The one failure that must NOT take the key with it. "Key present,
    /// passphrase missing" is a state the app handles end to end:
    /// `ManagedKeyPassphrase.resolve` falls back to the typed value, the
    /// connection form shows the passphrase row, connecting without one fails
    /// as `passphraseRequired`, and typing it once persists it. The opposite
    /// leftover — a Keychain slot under an id no store knows — is reachable
    /// from nowhere, because `SecretStore` cannot enumerate.
    @Test func materializeKeepsTheKeyWhenOnlyThePassphraseWriteFails() throws {
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
        let materialized = try EmbeddedKeyPorter.materialize(
            embedded, store: target, secrets: targetSecrets)

        // `false` is what makes the caller keep its OWN copy of the
        // passphrase (a `.privateKey` set's secret IS the key passphrase), so
        // the value is not lost even though the key's own slot has none.
        #expect(materialized.storedPassphrase == false)
        let imported = try #require(try target.key(forPath: materialized.path))
        #expect(imported.hasPassphrase)
        #expect(FileManager.default.fileExists(atPath: materialized.path))
        #expect(targetSecrets.stored.isEmpty)
        // No cleanup was attempted either: the fresh id belongs to a key that
        // now exists, so there is nothing orphaned to scrub.
        #expect(targetSecrets.deleted.isEmpty)
    }

    /// The import file's metadata is a claim, not a fact: the type and
    /// fingerprint that reach the store are derived from the key material.
    /// The payload has no `type` field to claim at all — `EmbeddedKey`'s v1
    /// shape carries none, precisely so nothing can be tempted to read it.
    @Test func materializeTakesTypeAndFingerprintFromTheKeyMaterial() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let source = makeStore(in: dir)
        let secrets = InMemorySecretStore()
        let key = try addManagedKey(to: source, secrets: secrets)
        let embedded = try #require(
            try EmbeddedKeyPorter.embed(
                keyPath: path(of: key, in: source), includePassphrase: false,
                store: source, secrets: secrets))

        let target = ManagedKeyStore(directory: dir.appendingPathComponent("imported"))
        let importedPath = try EmbeddedKeyPorter.materialize(
            embedded, store: target, secrets: InMemorySecretStore()).path

        let imported = try #require(try target.key(forPath: importedPath))
        #expect(imported.type == .ed25519)
        #expect(imported.fingerprint == key.fingerprint)
    }

    /// An encrypted key exported WITHOUT its passphrase cannot be opened on
    /// the import side, so nothing can be derived from the file — and the
    /// keys sheet enables "copy public key" unconditionally. Without the
    /// carried public key the button would hand out an empty string exactly
    /// when the user needs the line for `authorized_keys`.
    @Test func materializeKeepsThePublicKeyOfAnEncryptedKeyExportedWithoutItsPassphrase() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let source = makeStore(in: dir)
        let secrets = InMemorySecretStore()
        let key = try addManagedKey(to: source, secrets: secrets, passphrase: "s3cr3t")
        let embedded = try #require(
            try EmbeddedKeyPorter.embed(
                keyPath: path(of: key, in: source), includePassphrase: false,
                store: source, secrets: secrets))
        #expect(embedded.passphrase == nil)

        let target = ManagedKeyStore(directory: dir.appendingPathComponent("imported"))
        let importedPath = try EmbeddedKeyPorter.materialize(
            embedded, store: target, secrets: InMemorySecretStore()).path

        let imported = try #require(try target.key(forPath: importedPath))
        #expect(imported.publicKeyOpenSSH == key.publicKeyOpenSSH)
        #expect(imported.fingerprint == key.fingerprint)
        #expect(imported.type == .ed25519)
        #expect(imported.hasPassphrase == true)
    }

    /// …and the fingerprint check still bites in that case: the declared
    /// fingerprint is cross-checked against the carried public key line, the
    /// only thing left to check it against.
    @Test func materializeRejectsAForgedFingerprintWithoutThePassphrase() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let source = makeStore(in: dir)
        let secrets = InMemorySecretStore()
        let key = try addManagedKey(to: source, secrets: secrets, passphrase: "s3cr3t")
        var embedded = try #require(
            try EmbeddedKeyPorter.embed(
                keyPath: path(of: key, in: source), includePassphrase: false,
                store: source, secrets: secrets))
        let victim = try addManagedKey(to: source, secrets: secrets, name: "prod")
        embedded.fingerprint = victim.fingerprint

        let target = ManagedKeyStore(directory: dir.appendingPathComponent("imported"))
        #expect(throws: EmbeddedKeyPorter.PorterError.fingerprintMismatch) {
            _ = try EmbeddedKeyPorter.materialize(
                embedded, store: target, secrets: InMemorySecretStore())
        }
        let leftovers = (try? FileManager.default.contentsOfDirectory(
            atPath: target.keyDirectory.path(percentEncoded: false))) ?? []
        #expect(leftovers.isEmpty)
        #expect(try target.all().isEmpty)
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

    /// The payload must not get to pick which verification runs. `hasPassphrase`
    /// comes out of the same attacker-controlled bytes as `fingerprint`, so a
    /// payload that declares an encrypted key while carrying no passphrase used
    /// to route the import to the pure-parser fallback — where the carried
    /// public key line is checked against the carried fingerprint, both supplied
    /// by the same hand, so they always agree.
    ///
    /// Here the bytes are a PLAIN key that opens with no passphrase at all: the
    /// material is right there to be checked, and checking it must not depend on
    /// what the payload said about it.
    @Test func materializeRejectsAPlainKeyThatClaimsToBeEncrypted() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let source = makeStore(in: dir)
        let secrets = InMemorySecretStore()
        let attacker = try addManagedKey(to: source, secrets: secrets, name: "attacker")
        let victim = try addManagedKey(to: source, secrets: secrets, name: "prod")

        // Attacker's plain key bytes, the victim's identity, and the declaration
        // that steers the import away from the material.
        let payload = EmbeddedKey(
            fileContents: try Data(contentsOf: URL(fileURLWithPath: path(of: attacker, in: source))),
            name: "prod", comment: "prod-key",
            fingerprint: victim.fingerprint, publicKeyOpenSSH: victim.publicKeyOpenSSH,
            hasPassphrase: true, passphrase: nil)

        let target = ManagedKeyStore(directory: dir.appendingPathComponent("imported"))
        let targetSecrets = RecordingSecretStore()
        #expect(throws: EmbeddedKeyPorter.PorterError.fingerprintMismatch) {
            _ = try EmbeddedKeyPorter.materialize(payload, store: target, secrets: targetSecrets)
        }
        let leftovers = (try? FileManager.default.contentsOfDirectory(
            atPath: target.keyDirectory.path(percentEncoded: false))) ?? []
        #expect(leftovers.isEmpty)
        #expect(try target.all().isEmpty)
        #expect(targetSecrets.stored.isEmpty)
    }

    /// Same root cause one branch over: `try? SSHKeyImporter.inspect` swallowed
    /// every failure and silently downgraded to the declared values. When the
    /// payload itself says the key is NOT encrypted, a failure to open it means
    /// broken-or-forged — never "fall back to what the file claimed".
    @Test func materializeRejectsAPayloadWhoseKeyMaterialCannotBeOpened() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let source = makeStore(in: dir)
        let secrets = InMemorySecretStore()
        let victim = try addManagedKey(to: source, secrets: secrets, name: "prod")

        let payload = EmbeddedKey(
            fileContents: Data("NOT A KEY AT ALL".utf8),
            name: "prod", comment: "prod-key",
            fingerprint: victim.fingerprint, publicKeyOpenSSH: victim.publicKeyOpenSSH,
            hasPassphrase: false, passphrase: nil)

        let target = ManagedKeyStore(directory: dir.appendingPathComponent("imported"))
        let targetSecrets = RecordingSecretStore()
        #expect(throws: EmbeddedKeyPorter.PorterError.keyMaterialUnverifiable) {
            _ = try EmbeddedKeyPorter.materialize(payload, store: target, secrets: targetSecrets)
        }
        let leftovers = (try? FileManager.default.contentsOfDirectory(
            atPath: target.keyDirectory.path(percentEncoded: false))) ?? []
        #expect(leftovers.isEmpty)
        #expect(try target.all().isEmpty)
        #expect(targetSecrets.stored.isEmpty)
    }

    /// `hasPassphrase` is displayed (lock glyph) and decides whether the connect
    /// path looks for a Keychain passphrase at all — so it, too, has to follow
    /// what actually happened rather than what the payload declared. A file that
    /// opens with no passphrase is not encrypted, whatever it says, and the
    /// passphrase it carried is not written to the Keychain: a key with no slot
    /// must not claim to have one.
    @Test func materializeDerivesHasPassphraseFromTheKeyMaterial() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let source = makeStore(in: dir)
        let secrets = InMemorySecretStore()
        let plain = try addManagedKey(to: source, secrets: secrets, name: "plain")

        // A plain key declared as encrypted, with a passphrase to match the
        // story. `ssh-keygen -y` ignores `-P` for an unencrypted key, so the
        // material answers the question by itself.
        let payload = EmbeddedKey(
            fileContents: try Data(contentsOf: URL(fileURLWithPath: path(of: plain, in: source))),
            name: "plain", comment: "work-key",
            fingerprint: plain.fingerprint, publicKeyOpenSSH: plain.publicKeyOpenSSH,
            hasPassphrase: true, passphrase: "not-really-needed")

        let target = ManagedKeyStore(directory: dir.appendingPathComponent("imported"))
        let targetSecrets = RecordingSecretStore()
        let materialized = try EmbeddedKeyPorter.materialize(
            payload, store: target, secrets: targetSecrets)
        let importedPath = materialized.path

        let imported = try #require(try target.key(forPath: importedPath))
        #expect(imported.hasPassphrase == false)
        // Nothing was stored, so the caller must keep whatever secret IT
        // holds — the flag says so.
        #expect(materialized.storedPassphrase == false)
        #expect(targetSecrets.stored.isEmpty)
        #expect(targetSecrets.savedIDs.isEmpty)
        // The key itself is intact and usable without a passphrase.
        #expect(imported.fingerprint == plain.fingerprint)
        _ = try SSHPrivateKeyLoader.authentication(
            username: "t", keyPath: importedPath, passphrase: nil)
    }

    /// The third branch — "encrypted, and the passphrase stayed at home" —
    /// looked irreducible and is not. The `openssh-key-v1` format macSCP
    /// itself writes carries its PUBLIC key in CLEARTEXT even when the private
    /// half is encrypted, so `ssh-keygen -l -f <file>` reads the file's real
    /// identity with no passphrase and no secret in argv.
    ///
    /// Without that read, an attacker pairs their own ENCRYPTED key bytes with
    /// the victim's public key line and fingerprint, declares `hasPassphrase`
    /// and carries no passphrase — and the carried line is then checked only
    /// against the carried fingerprint, both from the same hand. The keys sheet
    /// would show a locked key named `prod` carrying the victim's genuine
    /// fingerprint next to foreign bytes.
    @Test func materializeRejectsAnEncryptedForeignKeyCarryingABorrowedFingerprint() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let source = makeStore(in: dir)
        let secrets = InMemorySecretStore()
        let attacker = try addManagedKey(
            to: source, secrets: secrets, name: "attacker", passphrase: "attacker-pass")
        let victim = try addManagedKey(to: source, secrets: secrets, name: "prod")

        let payload = EmbeddedKey(
            fileContents: try Data(contentsOf: URL(fileURLWithPath: path(of: attacker, in: source))),
            name: "prod", comment: "prod-key",
            fingerprint: victim.fingerprint, publicKeyOpenSSH: victim.publicKeyOpenSSH,
            hasPassphrase: true, passphrase: nil)

        let target = ManagedKeyStore(directory: dir.appendingPathComponent("imported"))
        let targetSecrets = RecordingSecretStore()
        #expect(throws: EmbeddedKeyPorter.PorterError.fingerprintMismatch) {
            _ = try EmbeddedKeyPorter.materialize(payload, store: target, secrets: targetSecrets)
        }
        let leftovers = (try? FileManager.default.contentsOfDirectory(
            atPath: target.keyDirectory.path(percentEncoded: false))) ?? []
        #expect(leftovers.isEmpty)
        #expect(try target.all().isEmpty)
        #expect(targetSecrets.stored.isEmpty)
    }

    /// Same branch, cruder payload: bytes that are not a key file at all
    /// (`ssh-keygen -l` exits 255 on them) used to import as a
    /// "passphrase-protected" key carrying the victim's fingerprint. Unable to
    /// read the file's own public part is not a licence to believe the payload.
    @Test func materializeRejectsNonKeyMaterialDeclaredAsPassphraseProtected() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let source = makeStore(in: dir)
        let secrets = InMemorySecretStore()
        let victim = try addManagedKey(to: source, secrets: secrets, name: "prod")

        let payload = EmbeddedKey(
            fileContents: Data("NOT A KEY AT ALL".utf8),
            name: "prod", comment: "prod-key",
            fingerprint: victim.fingerprint, publicKeyOpenSSH: victim.publicKeyOpenSSH,
            hasPassphrase: true, passphrase: nil)

        let target = ManagedKeyStore(directory: dir.appendingPathComponent("imported"))
        let targetSecrets = RecordingSecretStore()
        #expect(throws: EmbeddedKeyPorter.PorterError.keyMaterialUnverifiable) {
            _ = try EmbeddedKeyPorter.materialize(payload, store: target, secrets: targetSecrets)
        }
        let leftovers = (try? FileManager.default.contentsOfDirectory(
            atPath: target.keyDirectory.path(percentEncoded: false))) ?? []
        #expect(leftovers.isEmpty)
        #expect(try target.all().isEmpty)
        #expect(targetSecrets.stored.isEmpty)
    }

    /// A legacy PEM key (`Proc-Type: 4,ENCRYPTED` / `DEK-Info:`) encrypts the
    /// WHOLE file, public part included, so `ssh-keygen -l -f` cannot read it
    /// either ("is not a key file", exit 255). That case therefore fails
    /// closed — deliberately: nothing is left that ties the file to the
    /// declared identity, and accepting it on the payload's word would reopen
    /// exactly the hole the two tests above close. The PEM *format* is what
    /// blocks it, not the RSA/DSA/ECDSA *type* — `SSHPrivateKeyLoader` opens
    /// RSA and ECDSA (`KeyType.isConnectable`) in OpenSSH format, and refuses
    /// PEM for every type (`pemNotSupported`); the way to carry a PEM key here
    /// is to export WITH its passphrase, which lands in the strong
    /// `ssh-keygen -y -P` branch.
    @Test func materializeRejectsALegacyPEMEncryptedKeyExportedWithoutItsPassphrase() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let source = makeStore(in: dir)
        let secrets = InMemorySecretStore()
        let victim = try addManagedKey(to: source, secrets: secrets, name: "prod")

        let legacy = dir.appendingPathComponent("legacy")
        let keygenResult = try await SubprocessRunner.run(
            URL(fileURLWithPath: "/usr/bin/ssh-keygen"),
            arguments: [
                "-t", "rsa", "-b", "2048", "-m", "PEM", "-N", "s3cr3t", "-q",
                "-C", "legacy", "-f", legacy.path(percentEncoded: false),
            ])
        #expect(keygenResult.status == 0)

        let payload = EmbeddedKey(
            fileContents: try Data(contentsOf: legacy),
            name: "prod", comment: "prod-key",
            fingerprint: victim.fingerprint, publicKeyOpenSSH: victim.publicKeyOpenSSH,
            hasPassphrase: true, passphrase: nil)

        let target = ManagedKeyStore(directory: dir.appendingPathComponent("imported"))
        #expect(throws: EmbeddedKeyPorter.PorterError.keyMaterialUnverifiable) {
            _ = try EmbeddedKeyPorter.materialize(
                payload, store: target, secrets: InMemorySecretStore())
        }
        #expect(try target.all().isEmpty)
    }

    /// The carried public key line is the only source for the type and the
    /// `authorized_keys` line in that branch, so an unusable one is this
    /// porter's own failure — reported as `keyMaterialUnverifiable` rather
    /// than letting a raw `SSHKeyImportError` escape `PorterError`, and never
    /// as a registered key with an unverified fingerprint.
    @Test func materializeRejectsAnEncryptedKeyWhoseCarriedPublicKeyLineIsUnusable() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let source = makeStore(in: dir)
        let secrets = InMemorySecretStore()
        let key = try addManagedKey(to: source, secrets: secrets, passphrase: "s3cr3t")
        let bytes = try Data(contentsOf: URL(fileURLWithPath: path(of: key, in: source)))
        let blob = String(key.publicKeyOpenSSH.split(separator: " ")[1])

        for line in [
            "",                                     // nothing at all
            "ssh-ed25519",                          // no blob
            "ssh-ed25519 not-base64!! work-key",    // blob that is not a key
            "ssh-rsa \(blob) work-key",             // type contradicting the blob
        ] {
            let payload = EmbeddedKey(
                fileContents: bytes, name: "work", comment: "work-key",
                fingerprint: key.fingerprint, publicKeyOpenSSH: line,
                hasPassphrase: true, passphrase: nil)
            let target = ManagedKeyStore(
                directory: dir.appendingPathComponent("imported-\(UUID().uuidString)"))
            #expect(throws: EmbeddedKeyPorter.PorterError.keyMaterialUnverifiable) {
                _ = try EmbeddedKeyPorter.materialize(
                    payload, store: target, secrets: InMemorySecretStore())
            }
            #expect(try target.all().isEmpty)
        }
    }

    /// A file that is nothing but the victim's PUBLIC key line needs no
    /// assembly at all: a public key is public by definition, and
    /// `ssh-keygen -l -f` fingerprints a plain public key file exactly as
    /// readily as a private one. Without a check that the file actually IS an
    /// OpenSSH private key, this used to import cleanly and register an entry
    /// showing the victim's real fingerprint behind a lock glyph — no key
    /// material required, let alone a splice.
    @Test func materializeRejectsAFileThatIsOnlyAPublicKeyLine() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let source = makeStore(in: dir)
        let secrets = InMemorySecretStore()
        let victim = try addManagedKey(to: source, secrets: secrets, name: "prod")

        let payload = EmbeddedKey(
            fileContents: Data(victim.publicKeyOpenSSH.utf8),
            name: "prod", comment: "prod-key",
            fingerprint: victim.fingerprint, publicKeyOpenSSH: victim.publicKeyOpenSSH,
            hasPassphrase: true, passphrase: nil)

        let target = ManagedKeyStore(directory: dir.appendingPathComponent("imported"))
        let targetSecrets = RecordingSecretStore()
        #expect(throws: EmbeddedKeyPorter.PorterError.keyMaterialUnverifiable) {
            _ = try EmbeddedKeyPorter.materialize(payload, store: target, secrets: targetSecrets)
        }
        let leftovers = (try? FileManager.default.contentsOfDirectory(
            atPath: target.keyDirectory.path(percentEncoded: false))) ?? []
        #expect(leftovers.isEmpty)
        #expect(try target.all().isEmpty)
        #expect(targetSecrets.stored.isEmpty)
    }

    /// A carried passphrase that no longer opens the key (the source Keychain
    /// slot went stale out of band) must not fail the whole import: the file's
    /// own cleartext public part still establishes its identity, so the key
    /// lands as encrypted-without-a-slot, exactly as if it had been exported
    /// without secrets. Strictness here bought nothing — an attacker after that
    /// branch simply carries no passphrase — and only ever hit honest users.
    @Test func materializeImportsAnEncryptedKeyWhoseCarriedPassphraseWentStale() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let source = makeStore(in: dir)
        let secrets = InMemorySecretStore()
        let key = try addManagedKey(to: source, secrets: secrets, passphrase: "s3cr3t")
        var embedded = try #require(
            try EmbeddedKeyPorter.embed(
                keyPath: path(of: key, in: source), includePassphrase: true,
                store: source, secrets: secrets))
        embedded.passphrase = "no-longer-the-passphrase"

        let target = ManagedKeyStore(directory: dir.appendingPathComponent("imported"))
        let targetSecrets = RecordingSecretStore()
        let importedPath = try EmbeddedKeyPorter.materialize(
            embedded, store: target, secrets: targetSecrets).path

        let imported = try #require(try target.key(forPath: importedPath))
        #expect(imported.fingerprint == key.fingerprint)
        #expect(imported.hasPassphrase == true)
        // The stale string never reaches the Keychain: a slot must only ever
        // hold a passphrase that demonstrably opens the key.
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
        // Named, not the raw Cocoa error: that one spells out the local
        // `managed_keys.json` path, which is what the embed side's own error
        // cases exist to avoid.
        #expect(throws: EmbeddedKeyPorter.PorterError.keyStoreUnwritable) {
            _ = try EmbeddedKeyPorter.materialize(embedded, store: target, secrets: targetSecrets)
        }
        let leftovers = (try? FileManager.default.contentsOfDirectory(
            atPath: target.keyDirectory.path(percentEncoded: false))) ?? []
        #expect(leftovers.isEmpty)
        // A failed METADATA write still rolls everything back — there is no
        // key for a passphrase to belong to. And the slot was never created in
        // the first place: the metadata now goes first precisely so a failure
        // here cannot leave a Keychain entry under an id nothing knows.
        #expect(targetSecrets.stored.isEmpty)
        #expect(targetSecrets.savedIDs.isEmpty)
    }
}

/// Test double for the rollback legs: like `InMemorySecretStore`, but it
/// records which ids were written/deleted and can be told to fail every save.
/// (`FailingSecretStore` in `SessionListViewModelTests` covers the same
/// failure mode but is file-private there, and only a recording double can
/// say what happened to the FRESH id at all — that id never leaves
/// `materialize` unless the write succeeded.)
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
