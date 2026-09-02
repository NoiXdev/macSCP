import Foundation
import Testing
@testable import MacSCPCLI
@testable import macSCPCore

/// `SessionNameCompletion.complete(prefix:)` — the CLI's shell-completion
/// source for the `name:` half of a `name:/path` target. Ungated: it drives
/// a temp `SessionStore` in-process, the same way `SessionsCommand` does,
/// through the real `MACSCP_STORAGE_DIRECTORY` injection point rather than
/// through a subprocess (`SessionStore.defaultDirectory`'s doc comment
/// names what that variable is for and why it exists).
///
/// `.serialized`: every test here overwrites the real process environment
/// variable `MACSCP_STORAGE_DIRECTORY` for the span of one call.
/// `@Suite(.serialized)` only serializes WITHIN this suite (see
/// `AgentEnvLock`'s doc comment for the cross-suite shape of this same
/// problem) — sufficient here because no other suite touches this variable
/// on the real process: every other CLI test hands it to a CHILD process's
/// own environment dictionary instead
/// (`CLISessionsJSONRoundtripTests.runCLI`), which never reaches this
/// process's real environment at all.
@Suite("CLI session name completion", .serialized)
struct CLISessionNameCompletionTests {
    // MARK: - Fixture

    /// Seeds a temp `SessionStore` with one SSH session per name in
    /// `sessionNames`, points `MACSCP_STORAGE_DIRECTORY` at it for the
    /// duration of `body`, then restores both the environment variable and
    /// the temp directory's permissions before removing it — regardless of
    /// how `body` returns.
    private func withTempStore(
        sessionNames: [String], unreadable: Bool = false,
        _ body: () throws -> Void
    ) throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(
                "macscp-cli-completion-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("sessions-v2.json")
        defer {
            // Permission bits are restored before removal: `chmod` itself
            // needs no read permission on the target (only ownership), but
            // `removeItem` on a directory whose file is unreadable can still
            // leave debris if this is skipped.
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o644], ofItemAtPath: fileURL.path(percentEncoded: false))
            try? FileManager.default.removeItem(at: directory)
        }

        let store = SessionStore(directory: directory)
        for name in sessionNames {
            try store.upsert(sshSession(name: name))
        }

        if unreadable {
            // Mode 0000 on the store's own file — not the directory — so
            // `SessionStore.load()` actually reaches `Data(contentsOf:)` and
            // throws, rather than failing an earlier `fileExists` check and
            // silently returning an empty store: the point of this test is
            // that `complete(prefix:)` catches a real thrown error, not that
            // an empty catalog happens to answer `[]` too (same idiom as
            // `EmbeddedKeyPorterTests`'s "locked_key" fixture).
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o000], ofItemAtPath: fileURL.path(percentEncoded: false))
        }

        let previous = ProcessInfo.processInfo.environment["MACSCP_STORAGE_DIRECTORY"]
        setenv("MACSCP_STORAGE_DIRECTORY", directory.path(percentEncoded: false), 1)
        defer {
            if let previous {
                setenv("MACSCP_STORAGE_DIRECTORY", previous, 1)
            } else {
                unsetenv("MACSCP_STORAGE_DIRECTORY")
            }
        }

        try body()
    }

    // MARK: - Tests

    @Test func matchesByPrefixSortedWithATrailingColon() throws {
        try withTempStore(sessionNames: ["Work", "Web-01", "Prod / DB"]) {
            #expect(SessionNameCompletion.complete(prefix: "W") == ["Web-01:", "Work:"])
        }
    }

    @Test func anEmptyPrefixListsEveryStoredName() throws {
        try withTempStore(sessionNames: ["Work", "Web-01", "Prod / DB"]) {
            #expect(
                SessionNameCompletion.complete(prefix: "")
                    == ["Prod / DB:", "Web-01:", "Work:"])
        }
    }

    @Test func onceThePathHasStartedThereIsNothingToOffer() throws {
        try withTempStore(sessionNames: ["Work", "Web-01", "Prod / DB"]) {
            #expect(SessionNameCompletion.complete(prefix: "Web-01:/") == [])
        }
    }

    @Test func anUnreadableStoreAnswersEmptyRatherThanThrowing() throws {
        try withTempStore(sessionNames: ["Work"], unreadable: true) {
            #expect(SessionNameCompletion.complete(prefix: "") == [])
        }
    }

    // MARK: - Binary-level: the generated script names every subcommand

    /// `swift-argument-parser`'s generator writes the static half of
    /// completion (subcommands and flags) straight from the command tree —
    /// nothing in this task touches it — so this is a smoke test that the
    /// build actually wires all six subcommands into `MacSCPCLI`, run
    /// against the real built binary the same way
    /// `CLISessionsJSONRoundtripTests` does (bundle-relative lookup, no
    /// dependency on a `swift build` this test would trigger itself).
    @Test func theGeneratedZshScriptNamesEverySubcommand() throws {
        let binary = try Self.locateCLIBinary()
        let result = try Self.runProcess(binary, ["--generate-completion-script", "zsh"])
        #expect(result.status == 0, "--generate-completion-script zsh failed: \(result.stderr)")
        for name in ["sessions", "ls", "get", "put", "rm", "mkdir"] {
            #expect(result.stdout.contains(name), "zsh completion script does not name '\(name)'")
        }
    }

    // MARK: - Binary-level harness (self-contained rather than shared —
    // see `CLISessionsJSONRoundtripTests`'s doc comment for why each
    // gated/ungated suite here carries its own small copy)

    /// Exists only so `locateCLIBinary()` has a class defined in THIS file
    /// to hand `Bundle(for:)`.
    private final class TestBundleAnchor {}

    /// Locates the already-built `macscp-cli` binary, bundle-relative — see
    /// `CLISessionsJSONRoundtripTests.locateCLIBinary` for why: it
    /// deliberately does not run `swift build` (that would deadlock on
    /// SwiftPM's `.build` lock), and reading a repo-root-relative
    /// `.build/debug` path instead of the test bundle's own sibling breaks
    /// under `--scratch-path` and `-c release`.
    private static func locateCLIBinary() throws -> String {
        if let override = ProcessInfo.processInfo.environment["MACSCP_CLI_BINARY"],
           !override.isEmpty {
            guard FileManager.default.isExecutableFile(atPath: override) else {
                throw HarnessError(
                    "MACSCP_CLI_BINARY is set to \(override), which is not executable")
            }
            return override
        }
        let productsDirectory = Bundle(for: TestBundleAnchor.self).bundleURL
            .deletingLastPathComponent()
        let binaryPath = productsDirectory
            .appendingPathComponent("macscp-cli")
            .path(percentEncoded: false)
        guard FileManager.default.isExecutableFile(atPath: binaryPath) else {
            throw HarnessError("""
                macscp-cli not found at \(binaryPath).
                Build it before running this suite:
                  swift build --product macscp-cli
                or point MACSCP_CLI_BINARY at an existing binary.
                """)
        }
        return binaryPath
    }

    private static func runProcess(
        _ executable: String, _ arguments: [String]
    ) throws -> (status: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        try process.run()

        // Drain both pipes concurrently rather than sequentially — reading
        // stdout to EOF before touching stderr can deadlock if the child
        // fills the stderr pipe's kernel buffer while blocked writing to it
        // (same hazard `CLISessionsJSONRoundtripTests.runProcess` guards
        // against).
        let stdoutBox = CollectedOutput()
        let stderrBox = CollectedOutput()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            stdoutBox.data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        group.enter()
        DispatchQueue.global().async {
            stderrBox.data = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        _ = group.wait(timeout: .now() + 60)
        process.waitUntilExit()

        return (
            process.terminationStatus,
            String(data: stdoutBox.data, encoding: .utf8) ?? "",
            String(data: stderrBox.data, encoding: .utf8) ?? ""
        )
    }

    private final class CollectedOutput: @unchecked Sendable {
        var data = Data()
    }

    private struct HarnessError: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }
}
