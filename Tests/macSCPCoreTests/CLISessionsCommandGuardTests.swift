import Foundation
import Testing

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

    /// The APIs that would reach a secret or open a connection. Any one of
    /// these appearing in `SessionsCommand.swift` is the violation this
    /// guard exists to catch.
    private static let forbiddenIdentifiers = [
        "SecretStore", "SecretResolver", "secretSources(", "connect(",
        "withConnection(", "KnownHostsStore",
    ]

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

    /// The subset of `forbiddenIdentifiers` that appears anywhere in
    /// `source`, in the order the list itself is declared (not the order
    /// found in `source`) — so a caller comparing against a literal array
    /// gets a stable, predictable result regardless of where in the source
    /// each identifier happens to sit.
    private static func forbiddenMatches(in source: String) -> [String] {
        forbiddenIdentifiers.filter { source.contains($0) }
    }
}
