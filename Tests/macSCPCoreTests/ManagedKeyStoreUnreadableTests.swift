import Foundation
import MacSCPTestSupport
import Testing

@testable import macSCPCore

/// An unreadable `managed_keys.json` is named when it costs a connection
/// (review follow-ups of 2026-09-18, Task 6; BACKLOG row "A corrupt
/// `managed_keys.json` surfaces only as a missing passphrase").
///
/// The deliberate behaviour stays: the managed-key link still answers nil
/// over an unreadable store, so a session whose key the store does not
/// manage is not stopped (`CLISecretSourcesTests
/// .anUnreadableKeyStoreAnswersNotManaged` holds that). What is new is that
/// the link remembers what it saw, and a dial that then fails for a missing
/// passphrase of a key in the managed key directory says the store could not
/// be read — on a forwarding's dial, the command line's, and a diagnosis's.
///
/// The store is a temporary directory, never the real Application Support
/// path, the way `CLISecretSourcesTests.Rig` redirects it. Its content is a
/// named constant that no expectation spells (CLAUDE.md, "A value a test
/// must not leak has two exits"): every check that the content does not
/// leak computes its `Bool` first.
@Suite("An unreadable managed key store", .timeLimit(.minutes(1)))
struct ManagedKeyStoreUnreadableTests {
    // MARK: - The link remembers what it saw

    @Test func aManagedKeyBehindAnUnreadableStoreIsRecordedAndStillAnswersNothing() throws {
        let rig = try CorruptManagedKeyStoreRig()
        defer { rig.tearDown() }
        let source = rig.managedLink(keyPath: rig.managedKeyPath)

        let answeredNothing = try source.secret(for: UUID()) == nil
        #expect(answeredNothing, "an unreadable key store did not answer nil")
        #expect(source.unreadableStoreHidItsKey)
    }

    /// A key outside the managed key directory is not one the store could
    /// have held: the store being unreadable costs it nothing, and the link
    /// records nothing against it.
    @Test func anUnmanagedKeyBehindAnUnreadableStoreIsNotRecorded() throws {
        let rig = try CorruptManagedKeyStoreRig()
        defer { rig.tearDown() }
        let source = rig.managedLink(keyPath: rig.unmanagedKeyPath)

        let answeredNothing = try source.secret(for: UUID()) == nil
        #expect(answeredNothing)
        #expect(source.unreadableStoreHidItsKey == false)
    }

    /// The record is the LAST read's: a store repaired between two reads is
    /// not reported as unreadable by the second.
    @Test func theRecordIsTheLastReadsOwn() throws {
        let rig = try CorruptManagedKeyStoreRig()
        defer { rig.tearDown() }
        let source = rig.managedLink(keyPath: rig.managedKeyPath)
        _ = try source.secret(for: UUID())
        #expect(source.unreadableStoreHidItsKey)

        try rig.repairStore()
        _ = try source.secret(for: UUID())
        #expect(source.unreadableStoreHidItsKey == false)
    }

    /// A source that was never asked has seen nothing.
    @Test func aLinkThatWasNeverAskedHasRecordedNothing() throws {
        let rig = try CorruptManagedKeyStoreRig()
        defer { rig.tearDown() }
        #expect(rig.managedLink(keyPath: rig.managedKeyPath).unreadableStoreHidItsKey == false)
    }

    // MARK: - The join

    /// `passphraseRequired` becomes `managedKeyStoreUnreadable` exactly when
    /// the chain's managed-key link saw the store hide its key — and every
    /// other error, and every other chain, is handed back unchanged.
    @Test func onlyAMissingPassphraseBehindTheRecordedStoreIsRenamed() throws {
        let rig = try CorruptManagedKeyStoreRig()
        defer { rig.tearDown() }
        let managed = rig.chain(keyPath: rig.managedKeyPath)
        let unmanaged = rig.chain(keyPath: rig.unmanagedKeyPath)
        _ = try SecretResolver(sources: managed).resolve(for: UUID())
        _ = try SecretResolver(sources: unmanaged).resolve(for: UUID())

        #expect(
            Self.renamed(SSHKeyError.passphraseRequired, in: managed)
                == .managedKeyStoreUnreadable)
        #expect(Self.renamed(SSHKeyError.passphraseRequired, in: unmanaged) == .passphraseRequired)
        #expect(Self.renamed(SSHKeyError.wrongPassphrase, in: managed) == .wrongPassphrase)
        #expect(Self.renamed(SSHKeyError.passphraseRequired, in: []) == .passphraseRequired)
        let foreign = ManagedKeyPassphraseSecretSource.namingUnreadableStore(
            RemoteFSError.authenticationFailed, in: managed)
        #expect(foreign as? RemoteFSError == .authenticationFailed)
    }

    /// A readable store that simply does not list the key is the ordinary
    /// "no passphrase" — not a store problem.
    @Test func aReadableStoreThatDoesNotListTheKeyIsAnOrdinaryMissingPassphrase() throws {
        let rig = try CorruptManagedKeyStoreRig()
        defer { rig.tearDown() }
        try rig.repairStore()
        let chain = rig.chain(keyPath: rig.managedKeyPath)
        _ = try SecretResolver(sources: chain).resolve(for: UUID())

        #expect(Self.renamed(SSHKeyError.passphraseRequired, in: chain) == .passphraseRequired)
    }

    /// A diagnosis holds the chain as one `ChainedSecretSource`; the fact is
    /// found through it.
    @Test func theFactIsFoundThroughAChainedSource() throws {
        let rig = try CorruptManagedKeyStoreRig()
        defer { rig.tearDown() }
        let chained = ChainedSecretSource(rig.chain(keyPath: rig.managedKeyPath))
        _ = try chained.secret(for: UUID())

        #expect(ManagedKeyPassphraseSecretSource.unreadableStoreHidAKey(in: [chained]))
        #expect(
            Self.renamed(SSHKeyError.passphraseRequired, in: [chained])
                == .managedKeyStoreUnreadable)
    }

    // MARK: - A forwarding's dial, end to end

    /// The dial a forwarding makes (`TunnelConnection.connect`), with a real
    /// encrypted key in the managed key directory and no passphrase anywhere:
    /// the key loads before anything is dialled, so nothing leaves the
    /// process. The failure names the store — as an error, as the kind the
    /// App translates, and as the log's and the command line's sentence.
    @Test func aForwardingsDialOverACorruptStoreNamesTheStore() async throws {
        let rig = try CorruptManagedKeyStoreRig()
        defer { rig.tearDown() }
        try await rig.writeEncryptedKey(at: rig.managedKeyPath)

        let thrown = await #expect(throws: SSHKeyError.self) {
            _ = try await TunnelConnection.connect(
                session: rig.session(keyPath: rig.managedKeyPath),
                secrets: rig.chain(keyPath: rig.managedKeyPath),
                knownHosts: rig.knownHosts, decider: .refusing)
        }
        #expect(thrown == .managedKeyStoreUnreadable)
        let error = try #require(thrown)
        #expect(DialSupport.failureKind(for: error) == .managedKeyStoreUnreadable)
        #expect(DialSupport.reason(for: error) == TunnelFailureKind.managedKeyStoreUnreadable.sentence)
        #expect(DialSupport.reason(for: error).contains("managed_keys.json"))
        let sentenceLeaksTheFile = DialSupport.reason(for: error).contains(
            CorruptManagedKeyStoreRig.storeContent)
        #expect(sentenceLeaksTheFile == false)
    }

    /// The same corrupt store, and a key it could never have held: the
    /// failure is the missing passphrase it always was.
    @Test func anUnmanagedKeyOverTheSameCorruptStoreFailsAsBefore() async throws {
        let rig = try CorruptManagedKeyStoreRig()
        defer { rig.tearDown() }
        try await rig.writeEncryptedKey(at: rig.unmanagedKeyPath)

        await #expect(throws: SSHKeyError.passphraseRequired) {
            _ = try await TunnelConnection.connect(
                session: rig.session(keyPath: rig.unmanagedKeyPath),
                secrets: rig.chain(keyPath: rig.unmanagedKeyPath),
                knownHosts: rig.knownHosts, decider: .refusing)
        }
    }

    // MARK: - The command line's line

    /// The command line prints the log's sentence and exits as it does for
    /// every other store on this machine that could not be used — the code
    /// a missing passphrase already exited with, so no script's branch moves.
    @Test func theCommandLineNamesTheStore() {
        let error = SSHKeyError.managedKeyStoreUnreadable
        #expect(
            CLIErrorMapping.message(for: error)
                == "Error: " + TunnelFailureKind.managedKeyStoreUnreadable.sentence)
        #expect(CLIErrorMapping.exitCode(for: error) == .connection)
        #expect(CLIErrorMapping.exitCode(for: error) == CLIErrorMapping.exitCode(for: SSHKeyError.passphraseRequired))
    }

    /// The command line's own dial (`connect(to:options:)`) lives in a
    /// target with no test target, so its join is pinned by reading it: the
    /// call is there, once, inside that function, handed the chain the
    /// function resolved. A POSITIVE check — it goes red when the call moves
    /// or is renamed, never quiet. Comments and strings blanked first, so
    /// this doc comment and the call's own comment cannot satisfy it.
    @Test func theCommandLinesDialRenamesThroughTheSameJoin() throws {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/MacSCPCLI/SessionConnecting.swift")
        let code = try SwiftSource.blankingCommentsAndStrings(
            String(contentsOf: file, encoding: .utf8))
        let join = "\(String(describing: ManagedKeyPassphraseSecretSource.self))"
            + ".namingUnreadableStore(error, in: sources)"
        let start = try #require(code.range(of: "func connect("))
        let end = try #require(code.range(of: "func withConnection(", range: start.upperBound..<code.endIndex))
        let body = code[start.upperBound..<end.lowerBound]
        #expect(body.components(separatedBy: join).count - 1 == 1)
        #expect(code.components(separatedBy: join).count - 1 == 1)
    }

    // MARK: - A diagnosis's dial

    /// The session's dial in a diagnosis looks its secret up before dialling
    /// and reports `skipped` when there is none — with the store's sentence
    /// when that is why.
    @Test func aDiagnosisOfAManagedKeyOverACorruptStoreNamesTheStore() async throws {
        let rig = try CorruptManagedKeyStoreRig()
        defer { rig.tearDown() }
        let step = await DiagnosticContribution.sshConnect.run(
            rig.values(keyPath: rig.managedKeyPath),
            DiagnosticContext(
                secrets: ChainedSecretSource(rig.chain(keyPath: rig.managedKeyPath)),
                sessionID: UUID(), timeout: .seconds(5)))

        #expect(step.outcome == .skipped(DiagnosticReason.managedKeyStoreUnreadable))
        #expect(
            DiagnosticReason.key(for: DiagnosticReason.managedKeyStoreUnreadable)
                == "diagnostics.reason.managedKeyStoreUnreadable")
    }

    @Test func aDiagnosisOfAnUnmanagedKeyOverTheSameStoreSaysNoSecretAsBefore() async throws {
        let rig = try CorruptManagedKeyStoreRig()
        defer { rig.tearDown() }
        let step = await DiagnosticContribution.sshConnect.run(
            rig.values(keyPath: rig.unmanagedKeyPath),
            DiagnosticContext(
                secrets: ChainedSecretSource(rig.chain(keyPath: rig.unmanagedKeyPath)),
                sessionID: UUID(), timeout: .seconds(5)))

        #expect(step.outcome == .skipped(DiagnosticReason.noSecret))
    }

    // MARK: - Helpers

    private static func renamed(_ error: SSHKeyError, in sources: [any SecretSource]) -> SSHKeyError? {
        ManagedKeyPassphraseSecretSource.namingUnreadableStore(error, in: sources) as? SSHKeyError
    }
}

/// A managed key store in a temporary directory whose `managed_keys.json`
/// cannot be decoded, and two key paths: one inside its key directory (a key
/// it would manage) and one beside it (a key it never could).
///
/// Internal, not private: `ConnectionDiagnosticsJumpTests` and
/// `DiagnosticLogSharedSinkTests` build their chains from it too.
struct CorruptManagedKeyStoreRig {
    /// What the corrupt store file holds — not JSON. Named so that no
    /// expectation spells it: a check that it did not leak computes its
    /// `Bool` first.
    static let storeContent = "corrupt-managed-key-store-content-7f3a"
    /// The encrypted test key's passphrase. Stored nowhere the chain looks.
    static let keyPassphrase = "managed-key-store-test-passphrase"

    let directory: URL
    let keys: ManagedKeyStore
    let secrets = InMemorySecretStore()
    let managedKeyPath: String
    let unmanagedKeyPath: String
    let knownHosts: KnownHostsStore

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("managed-key-store-unreadable-\(UUID().uuidString)")
        keys = ManagedKeyStore(directory: directory)
        try FileManager.default.createDirectory(
            at: keys.keyDirectory, withIntermediateDirectories: true)
        let elsewhere = directory.appendingPathComponent("elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        managedKeyPath = keys.keyDirectory.appendingPathComponent(UUID().uuidString)
            .path(percentEncoded: false)
        unmanagedKeyPath = elsewhere.appendingPathComponent("id_ed25519").path(percentEncoded: false)
        knownHosts = KnownHostsStore(directory: directory)
        try Data(Self.storeContent.utf8).write(to: storeURL)
    }

    var storeURL: URL { directory.appendingPathComponent("managed_keys.json") }

    func tearDown() { try? FileManager.default.removeItem(at: directory) }

    /// Makes the store readable again: an empty key list.
    func repairStore() throws {
        try Data("[]".utf8).write(to: storeURL)
    }

    func managedLink(keyPath: String) -> ManagedKeyPassphraseSecretSource {
        ManagedKeyPassphraseSecretSource(keyPath: keyPath, keys: keys, secrets: secrets)
    }

    /// The forwarding's chain shape: the session's own slot, then the
    /// managed key's.
    func chain(keyPath: String) -> [any SecretSource] {
        [KeychainSecretSource(store: secrets), managedLink(keyPath: keyPath)]
    }

    /// A private-key session on loopback. The port is never reached: the key
    /// is loaded before anything is dialled.
    func session(keyPath: String) -> StoredSession {
        sshSession(
            name: "managed", host: "127.0.0.1", port: 1, username: "tester",
            authKind: .privateKey, keyPath: keyPath)
    }

    func values(keyPath: String) -> FieldValues {
        sshValues(
            host: "127.0.0.1", port: 1, username: "tester", authKind: .privateKey,
            keyPath: keyPath)
    }

    /// An encrypted ed25519 key at `path`, generated at run time.
    func writeEncryptedKey(at path: String) async throws {
        let result = try await SubprocessRunner.run(
            URL(fileURLWithPath: "/usr/bin/ssh-keygen"),
            arguments: [
                "-t", "ed25519", "-f", path, "-N", Self.keyPassphrase, "-q", "-C", "macscp-test",
            ])
        #expect(result.status == 0)
    }
}
