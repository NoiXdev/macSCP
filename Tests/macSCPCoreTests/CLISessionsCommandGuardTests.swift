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

/// Pins that `--kind`'s help text is DERIVED from `ConnectionKind.allCases`
/// rather than a second, hand-typed copy of its cases (review of this
/// task's first version: the help string hardcoded "ssh, s3 or webdav" —
/// `ConnectionKind`'s own doc comment calls it "open for future
/// protocols", so a fourth case is exactly the drift that copy invites).
///
/// This is deliberately NOT a source-text scan like the suite above: a scan
/// can only confirm what the SOURCE says, and the fix here specifically
/// makes the source say nothing about the case list any more (it reads
/// `ConnectionKind.allCases` at runtime instead) — so the only way to prove
/// the live help text actually lists every case is to produce that text and
/// look at it. `SessionsCommand`'s help construction is `fileprivate` to the
/// `MacSCPCLI` target, which `macSCPCoreTests` does not depend on, so the
/// text is produced by running the BUILT `macscp-cli` binary as a
/// subprocess and reading its own `--help` output — the same technique
/// `CLIRoundtripITests` uses for the same reason (no unit test target
/// exists for `MacSCPCLI` at all). Ungated (no `MACSCP_ITEST`): `--help`
/// touches no rig, no store, no network.
///
/// A POSITIVE check throughout: it asserts every current
/// `ConnectionKind.allCases` raw value IS present in the `--kind` line,
/// rather than asserting an old value is absent — so adding a case without
/// updating the derivation (or reverting to a hardcoded copy that omits the
/// new case) turns this red, instead of a stale negative check quietly
/// matching nothing (CLAUDE.md, "Guards that name what they watch").
@Suite("CLI sessions --kind help text names every ConnectionKind")
struct CLISessionsKindHelpTextTests {
    private static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    @Test func kindHelpLineNamesEveryConnectionKindCase() throws {
        let binary = try Self.locateCLIBinary()
        let output = try Self.runHelp(binary)

        guard let kindLine = output.split(separator: "\n", omittingEmptySubsequences: false)
            .first(where: { $0.contains("--kind") && $0.contains("Only this backend") })
        else {
            Issue.record("no --kind line found in `sessions --help` output:\n\(output)")
            return
        }

        // Live values from the actual enum, not a copy — this is exactly
        // what makes the check unable to go stale the way a hardcoded list
        // in the test itself would.
        let expectedCases = ConnectionKind.allCases.map(\.rawValue)
        #expect(!expectedCases.isEmpty, "ConnectionKind.allCases is empty — nothing to pin")
        for rawValue in expectedCases {
            #expect(kindLine.contains(rawValue), """
                `--kind`'s help line does not name "\(rawValue)": \(kindLine) — \
                either a ConnectionKind case was added without updating the \
                derivation in SessionsCommand.swift, or the help text \
                reverted to a hardcoded copy that missed it.
                """)
        }
    }

    // MARK: - Harness (binary already built by `swift test`'s own package
    // build; located, not produced — see `CLIRoundtripITests.locateCLIBinary`
    // for why building here would deadlock on SwiftPM's `.build` lock).

    private static func locateCLIBinary() throws -> String {
        if let override = ProcessInfo.processInfo.environment["MACSCP_CLI_BINARY"],
           !override.isEmpty {
            guard FileManager.default.isExecutableFile(atPath: override) else {
                throw HarnessError("MACSCP_CLI_BINARY is set to \(override), which is not executable")
            }
            return override
        }
        let binaryPath = repoRoot
            .appendingPathComponent(".build/debug/macscp-cli")
            .path(percentEncoded: false)
        guard FileManager.default.isExecutableFile(atPath: binaryPath) else {
            throw HarnessError("""
                macscp-cli not found at \(binaryPath).
                Build it before running this test:
                  swift build --product macscp-cli
                or point MACSCP_CLI_BINARY at an existing binary.
                """)
        }
        return binaryPath
    }

    private static func runHelp(_ binary: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["sessions", "--help"]
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let stdoutPipe = Pipe()
        process.standardOutput = stdoutPipe
        try process.run()
        // `--help` output is a few hundred bytes — well under a pipe's
        // kernel buffer, so reading to EOF before `waitUntilExit()` cannot
        // deadlock the way a large, unbounded stream could.
        let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }

    private struct HarnessError: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }
}
