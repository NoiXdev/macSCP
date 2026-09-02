import Foundation
import Testing
import macSCPCore

/// Pins the security constraint `SessionsCommand` exists for: listing saved
/// sessions must never touch the keychain, resolve a login set, or open a
/// connection (2026-09-02 CLI-sessions-list plan, "No secret, no keychain,
/// no connection").
///
/// A NEGATIVE check alone — "the file names none of these secret/connection
/// APIs" — goes stale in silence the moment the file it scans stops
/// existing or is renamed out from under it: a scan that finds nothing to
/// scan finds no violations either, and reads exactly like a scan that
/// passed (CLAUDE.md, "Guards that name what they watch"). So this suite
/// pairs the negative check with two positive ones: the file must exist,
/// and it must actually contain the two constructors
/// (`SessionStore(`/`SessionCatalog(`) that a listing command has no way to
/// work without — proof the scanner is reading a real implementation, not
/// an empty or missing file that vacuously satisfies "contains none of the
/// forbidden strings".
///
/// A synthetic self-test (`scannerFlagsAPlantedSecretSourcesCall`) exercises
/// the same scanning function against a fixture string that plants exactly
/// one of the forbidden calls, so the scanner's sensitivity is proven
/// independent of whatever the real file happens to say today.
///
/// Same boundary as the project's other wiring guards (see
/// `CitadelFileSystemConnectTimeoutWiringGuardTests`'s doc comment): a
/// SOURCE-TEXT scan, not a behavioral test.
@Suite("CLI sessions command guard")
struct CLISessionsCommandGuardTests {
    /// `#filePath` here is
    /// `<repoRoot>/Tests/macSCPCoreTests/CLISessionsCommandGuardTests.swift`;
    /// three `deletingLastPathComponent()` calls recover the repo root
    /// regardless of `swift test`'s working directory (same trick as
    /// `CitadelFileSystemConnectTimeoutWiringGuardTests`).
    private static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    private static let sessionsCommandFile = repoRoot
        .appendingPathComponent("Sources/MacSCPCLI/SessionsCommand.swift")

    /// The completer wired onto every `name:/path` target's `@Argument`
    /// (2026-09-02 CLI-completion plan, Task 1) — pinned by the same "no
    /// secret, no keychain, no connection" constraint as `SessionsCommand`,
    /// plus its own: it runs silently in a subprocess a shell spawns, so it
    /// must never write to stdout or stderr on its own (see
    /// `completionForbiddenIdentifiers` below).
    private static let completionCommandFile = repoRoot
        .appendingPathComponent("Sources/MacSCPCLI/SessionNameCompletion.swift")

    /// The APIs that would reach a secret or open a connection. Any one of
    /// these appearing in `SessionsCommand.swift` is the violation this
    /// guard exists to catch.
    ///
    /// `openConnection(`, `StoredSessionConnectionConfig` and
    /// `RemoteFileSystem` joined the original six on 2026-09-02: `"connect("`
    /// alone does not catch a connection opened through the backend layer —
    /// `StoredSessionConnectionConfig.build(for:secret:)` +
    /// `BackendDescriptor.openConnection(…)` dials out without ever writing
    /// the substring `connect(`, and agent-auth SSH needs no secret at all —
    /// see `scannerFlagsAPlantedOpenConnectionCall` for the fixture that was
    /// red against the original six.
    private static let forbiddenIdentifiers = [
        "SecretStore", "SecretResolver", "secretSources(", "connect(",
        "withConnection(", "KnownHostsStore", "openConnection(",
        "StoredSessionConnectionConfig", "RemoteFileSystem",
    ]

    /// The completer's own list: everything `SessionsCommand.swift` is
    /// forbidden from, PLUS the two calls that would break its silence —
    /// `print(` and `FileHandle.standardError` — neither of which belongs
    /// in `forbiddenIdentifiers` above, since `SessionsCommand` legitimately
    /// prints its rows (`OutputFormatter.print(rows:asJSON:)`, which
    /// contains the substring `print(`) where the completer must never
    /// print anything of its own (2026-09-02 CLI-completion plan, Task 1,
    /// "Silent and fast").
    private static let completionForbiddenIdentifiers =
        forbiddenIdentifiers + ["print(", "FileHandle.standardError"]

    // MARK: - Positive: the file exists and does the real work

    @Test func theFileExists() {
        #expect(FileManager.default.fileExists(atPath: Self.sessionsCommandFile.path))
    }

    @Test func theFileBuildsItsRowsFromTheStoreAndTheCatalog() throws {
        let source = try String(contentsOf: Self.sessionsCommandFile, encoding: .utf8)
        #expect(source.contains("SessionStore("), """
            SessionsCommand.swift no longer constructs a SessionStore( — the \
            positive anchor beside the negative check below has nothing to \
            confirm the scanner is reading a real implementation.
            """)
        #expect(source.contains("SessionCatalog("), """
            SessionsCommand.swift no longer constructs a SessionCatalog( — same \
            concern as SessionStore( above.
            """)
    }

    // MARK: - Negative: none of secret, keychain or connection

    @Test func theFileNamesNoSecretKeychainOrConnectionAPI() throws {
        let source = try String(contentsOf: Self.sessionsCommandFile, encoding: .utf8)
        let found = Self.forbiddenMatches(in: source)
        #expect(found.isEmpty, """
            SessionsCommand.swift names \(found) — listing saved sessions must \
            never touch the keychain, resolve a login set, or open a \
            connection (no secret, no keychain, no connection).
            """)
    }

    // MARK: - Scanner self-test (synthetic source, independent of whether
    // the real file currently passes)

    @Test func scannerFlagsAPlantedSecretSourcesCall() {
        let fixture = """
            struct FixtureCommand {
                func run() async throws {
                    let store = SessionStore(directory: SessionStore.defaultDirectory)
                    let catalog = SessionCatalog(sessions: [], groups: [])
                    let sources = secretSources(for: session, passwordCommand: nil)
                }
            }
            """
        let found = Self.forbiddenMatches(in: fixture)
        #expect(found == ["secretSources("], """
            expected the scanner to flag exactly the planted secretSources( \
            call, found \(found) instead.
            """)
    }

    /// `"connect("` alone does not catch a connection opened through the
    /// backend layer: `StoredSessionConnectionConfig.build(for:secret:)` +
    /// `BackendDescriptor.openConnection(…)` dials out without ever writing
    /// the substring `connect(` (case-sensitive, and `openConnection(` does
    /// not contain it as a substring), and agent-auth SSH needs no secret at
    /// all — so a command built that way would sail past the original list
    /// untouched (final-branch-review finding, 2026-09-02). This fixture
    /// plants exactly that call and nothing else the original list would
    /// have caught, so it is red until `openConnection(` (and its two
    /// siblings, `StoredSessionConnectionConfig` and `RemoteFileSystem`)
    /// join `forbiddenIdentifiers`.
    @Test func scannerFlagsAPlantedOpenConnectionCall() {
        let fixture = """
            struct FixtureCommand {
                func run() async throws {
                    let store = SessionStore(directory: SessionStore.defaultDirectory)
                    let catalog = SessionCatalog(sessions: [], groups: [])
                    let config = try StoredSessionConnectionConfig.build(for: session, secret: nil)
                    let fs: any RemoteFileSystem = try await BackendDescriptor.openConnection(
                        config, hostKey: decider, certificate: .refusing, timeoutSeconds: 5)
                }
            }
            """
        let found = Self.forbiddenMatches(in: fixture)
        #expect(found == ["openConnection(", "StoredSessionConnectionConfig", "RemoteFileSystem"], """
            expected the scanner to flag the planted openConnection(/
            StoredSessionConnectionConfig/RemoteFileSystem call, found \(found) \
            instead.
            """)
    }

    @Test func scannerAcceptsAFixtureNamingNoneOfTheForbiddenIdentifiers() {
        let fixture = """
            struct FixtureCommand {
                func run() async throws {
                    let store = SessionStore(directory: SessionStore.defaultDirectory)
                    let catalog = SessionCatalog(sessions: try store.all(), groups: try store.allGroups())
                }
            }
            """
        #expect(Self.forbiddenMatches(in: fixture).isEmpty)
    }

    // MARK: - Scanner

    /// The subset of `identifiers` that appears anywhere in `source`, in the
    /// order the list itself is declared (not the order found in `source`)
    /// — so a caller comparing against a literal array gets a stable,
    /// predictable result regardless of where in the source each identifier
    /// happens to sit. Defaults to `forbiddenIdentifiers` so every existing
    /// call site (all against `SessionsCommand.swift`) is unchanged;
    /// `completionForbiddenIdentifiers` below passes its own list.
    private static func forbiddenMatches(
        in source: String, identifiers: [String] = forbiddenIdentifiers
    ) -> [String] {
        identifiers.filter { source.contains($0) }
    }

    // MARK: - The completer: same shape, plus silence

    @Test func theCompletionFileExists() {
        #expect(FileManager.default.fileExists(atPath: Self.completionCommandFile.path))
    }

    @Test func theCompletionFileBuildsItsListFromTheCatalog() throws {
        let source = try String(contentsOf: Self.completionCommandFile, encoding: .utf8)
        #expect(source.contains("SessionCatalog("), """
            SessionNameCompletion.swift no longer constructs a SessionCatalog( \
            — the positive anchor beside the negative check below has \
            nothing to confirm the scanner is reading a real implementation.
            """)
    }

    @Test func theCompletionFileNamesNoForbiddenAPI() throws {
        let source = try String(contentsOf: Self.completionCommandFile, encoding: .utf8)
        let found = Self.forbiddenMatches(
            in: source, identifiers: Self.completionForbiddenIdentifiers)
        #expect(found.isEmpty, """
            SessionNameCompletion.swift names \(found) — the completer reads \
            the session store and nothing else, and must stay silent (no \
            secret, no keychain, no connection, no stdout, no stderr).
            """)
    }

    @Test func scannerFlagsAPlantedPrintCall() {
        let fixture = """
            enum FixtureCompletion {
                static func complete(prefix: String) -> [String] {
                    let store = SessionStore(directory: SessionStore.defaultDirectory)
                    print("completing: \\(prefix)")
                    return []
                }
            }
            """
        let found = Self.forbiddenMatches(
            in: fixture, identifiers: Self.completionForbiddenIdentifiers)
        #expect(found == ["print("], """
            expected the scanner to flag exactly the planted print( call, \
            found \(found) instead.
            """)
    }

    @Test func scannerFlagsAPlantedStandardErrorWrite() {
        let fixture = """
            enum FixtureCompletion {
                static func complete(prefix: String) -> [String] {
                    FileHandle.standardError.write(Data("oops".utf8))
                    return []
                }
            }
            """
        let found = Self.forbiddenMatches(
            in: fixture, identifiers: Self.completionForbiddenIdentifiers)
        #expect(found == ["FileHandle.standardError"], """
            expected the scanner to flag exactly the planted \
            FileHandle.standardError write, found \(found) instead.
            """)
    }

    @Test func scannerAcceptsACompletionFixtureNamingNoneOfTheForbiddenIdentifiers() {
        let fixture = """
            enum FixtureCompletion {
                static func complete(prefix: String) -> [String] {
                    let store = SessionStore(directory: SessionStore.defaultDirectory)
                    let catalog = SessionCatalog(sessions: try! store.all(), groups: try! store.allGroups())
                    return catalog.rows(matching: .init()).map { "\\($0.name):" }
                }
            }
            """
        #expect(Self.forbiddenMatches(
            in: fixture, identifiers: Self.completionForbiddenIdentifiers).isEmpty)
    }

    // MARK: - Every session-target argument carries the completer

    /// "Every command that parses a `name:/path` target wires
    /// `SessionNameCompletion.kind` onto that argument" restated as
    /// something a scanner can check, WITHOUT spelling out the five command
    /// file names as a second copy of a list this suite does not otherwise
    /// keep (CLAUDE.md, "Guards that name what they watch" — a guard that
    /// spells a symbol it could read instead is waiting for a rename): a
    /// command file "takes a session target" exactly when it calls
    /// `SessionReference.parse(` (every one of `LsCommand`, `GetCommand`,
    /// `PutCommand`, `RmCommand`, `MkdirCommand` does, and no other file
    /// under `Sources/MacSCPCLI` does), and each such file is expected to
    /// carry exactly ONE `completion: SessionNameCompletion.kind` — one
    /// target argument gets the completer, even in `get`/`put`, which each
    /// have TWO `@Argument`s but only one of them names a session (`put`'s
    /// SOURCE is always a local path).
    ///
    /// A POSITIVE check throughout: the file set must be non-empty (proof
    /// the scanner found real files, not zero), the per-file count must be
    /// exactly one (not merely "at least one" — a stray second wiring would
    /// be as wrong as a missing one), and the sum is asserted against the
    /// file count rather than a hardcoded number, so this stays correct
    /// when a sixth command joins `SessionReference.parse(`'s callers: it
    /// turns red the moment that new command's file exists without also
    /// carrying the completer.
    @Test func everySessionTargetCommandCarriesTheCompletion() throws {
        let cliDirectory = Self.repoRoot.appendingPathComponent("Sources/MacSCPCLI")
        let swiftFiles = try FileManager.default.contentsOfDirectory(
            at: cliDirectory, includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "swift" }
        #expect(!swiftFiles.isEmpty, "found no .swift files under Sources/MacSCPCLI to scan")

        let targetCommandFiles = try swiftFiles.filter {
            try String(contentsOf: $0, encoding: .utf8).contains("SessionReference.parse(")
        }
        // Counted 2026-09-02, alongside this task: `ls`, `get`, `put`, `rm`,
        // `mkdir` — `sessions` is deliberately not among them (it lists
        // sessions by filter, not by a `name:/path` target).
        #expect(targetCommandFiles.count == 5, """
            expected exactly 5 command files calling SessionReference.parse(, \
            found \(targetCommandFiles.count): \
            \(targetCommandFiles.map(\.lastPathComponent).sorted())
            """)

        for file in targetCommandFiles {
            let source = try String(contentsOf: file, encoding: .utf8)
            let count = source.components(separatedBy: "completion: SessionNameCompletion.kind").count - 1
            #expect(count == 1, """
                \(file.lastPathComponent) takes a session target but carries \
                \(count) occurrences of "completion: SessionNameCompletion.kind" \
                (expected exactly 1).
                """)
        }
    }
}

