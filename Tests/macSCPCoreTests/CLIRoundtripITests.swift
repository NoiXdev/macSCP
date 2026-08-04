import Foundation
import Testing
@testable import macSCPCore

/// Gated behind MACSCP_ITEST: needs the Docker SSH rig (127.0.0.1:2222).
/// Start the rig from the MAIN checkout, never a worktree — the seed mount
/// is relative to the compose file.
///
/// Both tests drive the BUILT `macscp-cli` BINARY as a subprocess (not the
/// Swift API underneath it) — the same entry point a user invokes, flags and
/// exit codes included. `.serialized` because both drive the same rig against
/// overlapping remote paths, and concurrent runs would see each other's files.
@Suite(
    "CLIRoundtrip",
    .enabled(if: ProcessInfo.processInfo.environment["MACSCP_ITEST"] == "1"),
    .serialized
)
struct CLIRoundtripITests {
    private static let rigHost = "127.0.0.1"
    private static let rigPort = 2222
    private static let rigUsername = "testuser"
    private static let rigPassword = "testpass"

    /// put → ls → get → rm against the real rig, comparing contents. Proves
    /// the pieces work together, which no unit test can: it puts a payload
    /// with a unique, freshly generated name onto the rig, confirms `ls`
    /// reports it, downloads it back, and asserts the downloaded bytes are
    /// EXACTLY the bytes that were uploaded — not merely that both commands
    /// exited zero.
    @Test func sshRoundtripMovesTheBytesBackAndForth() async throws {
        let binary = try Self.locateCLIBinary()
        let storageDirectory = try Self.makeTempDirectory(prefix: "macscp-cli-roundtrip-storage")
        defer { try? FileManager.default.removeItem(at: storageDirectory) }
        let localDirectory = try Self.makeTempDirectory(prefix: "macscp-cli-roundtrip-local")
        defer { try? FileManager.default.removeItem(at: localDirectory) }

        let session = StoredSession(
            name: "m20-roundtrip", host: Self.rigHost, port: Self.rigPort,
            username: Self.rigUsername, authKind: .password)
        try SessionStore(directory: storageDirectory).upsert(session)

        // A fresh name AND a fresh payload per run, so re-runs (or a run that
        // crashed before its own `rm` cleanup) can never collide with a
        // leftover file from a previous run.
        let remoteFileName = "cli-roundtrip-\(UUID().uuidString).txt"
        let payload = "m20-roundtrip-\(UUID().uuidString)"
        let localSourceFile = localDirectory.appendingPathComponent(remoteFileName)
        try Data(payload.utf8).write(to: localSourceFile)
        let downloadDirectory = localDirectory.appendingPathComponent("download", isDirectory: true)
        try FileManager.default.createDirectory(at: downloadDirectory, withIntermediateDirectories: true)

        let remoteDirectory = "\(session.name):/config"

        // `rm` is both a subject of this test (the CLI's own delete command)
        // and this test's cleanup — the rig has no other way to remove what
        // this run uploads. It's fine for it to run even if an earlier step
        // already failed the test.
        defer {
            _ = try? Self.runCLI(
                binary, ["rm", "--accept-new", "\(remoteDirectory)/\(remoteFileName)"],
                storageDirectory: storageDirectory)
        }

        let putResult = try Self.runCLI(
            binary,
            ["put", "--accept-new", localSourceFile.path(percentEncoded: false), remoteDirectory + "/"],
            storageDirectory: storageDirectory)
        #expect(putResult.status == 0, "put failed: \(putResult.stderr)")

        let lsResult = try Self.runCLI(
            binary, ["ls", "--accept-new", "--json", remoteDirectory],
            storageDirectory: storageDirectory)
        #expect(lsResult.status == 0, "ls failed: \(lsResult.stderr)")
        let listedNames = lsResult.stdout
            .split(separator: "\n")
            .compactMap { line -> String? in
                guard let data = line.data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else { return nil }
                return object["name"] as? String
            }
        #expect(listedNames.contains(remoteFileName), "ls did not report the uploaded file")

        let getResult = try Self.runCLI(
            binary,
            ["get", "--accept-new", "\(remoteDirectory)/\(remoteFileName)",
             downloadDirectory.path(percentEncoded: false)],
            storageDirectory: storageDirectory)
        #expect(getResult.status == 0, "get failed: \(getResult.stderr)")
        let downloadedFile = downloadDirectory.appendingPathComponent(remoteFileName)
        let downloadedContent = try String(contentsOf: downloadedFile, encoding: .utf8)
        #expect(downloadedContent == payload, "downloaded bytes do not match the uploaded payload")

        let rmResult = try Self.runCLI(
            binary, ["rm", "--accept-new", "\(remoteDirectory)/\(remoteFileName)"],
            storageDirectory: storageDirectory)
        #expect(rmResult.status == 0, "rm failed: \(rmResult.stderr)")

        // Confirms `rm` actually removed it, rather than merely exiting 0.
        let lsAfterRemoval = try Self.runCLI(
            binary, ["ls", "--accept-new", "--json", remoteDirectory],
            storageDirectory: storageDirectory)
        #expect(lsAfterRemoval.status == 0, "ls after rm failed: \(lsAfterRemoval.stderr)")
        let namesAfterRemoval = lsAfterRemoval.stdout
            .split(separator: "\n")
            .compactMap { line -> String? in
                guard let data = line.data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else { return nil }
                return object["name"] as? String
            }
        #expect(!namesAfterRemoval.contains(remoteFileName), "rm did not actually remove the file")
    }

    /// The promise every automation relies on: no terminal, unknown host,
    /// and the CLI refuses instead of asking — with exit code 11, not 0 —
    /// and without silently trusting (and persisting) the very key it just
    /// refused. Uses its OWN storage directory, separate from the roundtrip
    /// test above and from the developer's real
    /// `~/Library/Application Support/macSCP/known_hosts.json`: this test's
    /// entire point is an UNKNOWN host key, which the developer's own
    /// known-hosts file for this same rig is not.
    @Test func nonInteractiveRefusesAnUnknownHostKey() async throws {
        let binary = try Self.locateCLIBinary()
        let storageDirectory = try Self.makeTempDirectory(prefix: "macscp-cli-refusal-storage")
        defer { try? FileManager.default.removeItem(at: storageDirectory) }

        let session = StoredSession(
            name: "m20-refusal", host: Self.rigHost, port: Self.rigPort,
            username: Self.rigUsername, authKind: .password)
        try SessionStore(directory: storageDirectory).upsert(session)

        // No `--accept-new`: the default policy is `.ask`, and `runCLI`
        // below gives the child process no terminal on stdin, so
        // `HostKeyPolicy.decision(for: .ask, hasTTY: false)` resolves to
        // `.reject` — the exact "nobody is here to say yes" case this test
        // exists to pin. `--non-interactive` is passed too so the same
        // refusal is exercised via the documented flag, not only via the
        // absence of a TTY.
        let result = try Self.runCLI(
            binary, ["ls", "--non-interactive", "\(session.name):/"],
            storageDirectory: storageDirectory)

        #expect(result.status == CLIExitCode.hostKeyUnknown.rawValue)
        #expect(result.status == 11)

        // The actual security promise: refusing must not ALSO silently
        // record the very key it refused. If it had, the next connection
        // attempt — even a careless one — would trust an unverified key.
        let knownHosts = try KnownHostsStore(directory: storageDirectory).allKeys()
        #expect(knownHosts.isEmpty, "an unknown host key was written despite being rejected")
    }

    // MARK: - Test harness

    /// Creates the directory, rather than only naming it. The earlier version
    /// returned a path and left the directory uncreated — which went unnoticed
    /// for the storage directory (`SessionStore` creates its own on write) but
    /// broke the local one, where nothing else does: writing the payload file
    /// failed with "no such file or directory" before the test reached the CLI
    /// at all.
    private static func makeTempDirectory(prefix: String) throws -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// Locates the already-built `macscp-cli` binary.
    ///
    /// It deliberately does NOT run `swift build`. A test running under
    /// `swift test` is inside a process that holds SwiftPM's lock on
    /// `.build`; a nested `swift build` waits for that lock, which waits for
    /// the test — a deadlock with no timeout, which is exactly how this suite
    /// first hung. SwiftPM says so plainly if you try:
    /// "Another instance of SwiftPM is already running using '.build',
    /// waiting until that process has finished execution..."
    ///
    /// So the binary is located, not produced: `swift test` has already built
    /// every product into the same directory the test bundle lives in, so the
    /// sibling next to the bundle IS the current source tree's output.
    /// `MACSCP_CLI_BINARY` overrides for anyone running the bundle from
    /// somewhere unusual.
    private static func locateCLIBinary() throws -> String {
        if let override = ProcessInfo.processInfo.environment["MACSCP_CLI_BINARY"],
           !override.isEmpty {
            guard FileManager.default.isExecutableFile(atPath: override) else {
                throw HarnessError("MACSCP_CLI_BINARY is set to \(override), which is not executable")
            }
            return override
        }
        // `Bundle.main` is NOT usable here: under `swift test` it resolves to
        // swiftpm-testing-helper inside the toolchain, not to the test bundle.
        // So derive the repo root from this file's path — the same trick
        // `LocalizableStringsTests` and `IconTooltipLintTests` use — and read
        // `.build/debug`, the symlink SwiftPM maintains to the current
        // triple's debug products.
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let binaryPath = repoRoot
            .appendingPathComponent(".build/debug/macscp-cli")
            .path(percentEncoded: false)
        guard FileManager.default.isExecutableFile(atPath: binaryPath) else {
            throw HarnessError("""
                macscp-cli not found at \(binaryPath).
                Build it before running the gated suite:
                  swift build --product macscp-cli
                or point MACSCP_CLI_BINARY at an existing binary.
                """)
        }
        return binaryPath
    }

    /// Runs the built CLI binary as a subprocess with an isolated storage
    /// directory and rig credentials, and no controlling terminal (stdin is
    /// the null device) — so a test never depends on whether the process
    /// running `swift test` happens to have one attached.
    private static func runCLI(
        _ binary: String, _ arguments: [String], storageDirectory: URL
    ) throws -> (status: Int32, stdout: String, stderr: String) {
        var environment = ProcessInfo.processInfo.environment
        environment["MACSCP_STORAGE_DIRECTORY"] = storageDirectory.path(percentEncoded: false)
        environment["MACSCP_PASSWORD"] = rigPassword
        return try runProcess(binary, arguments, environment: environment, stdinIsNullDevice: true)
    }

    /// Thrown when a child outlives `timeout`. Carries the argument list so a
    /// failure names WHICH invocation stalled — without it the suite just sits
    /// there and the log says nothing about where.
    struct CLIProcessTimeout: Error, CustomStringConvertible {
        let arguments: [String]
        let seconds: TimeInterval
        let stderrSoFar: String

        var description: String {
            """
            macscp-cli did not exit within \(Int(seconds))s: \
            \(arguments.joined(separator: " "))
            stderr so far: \(stderrSoFar.isEmpty ? "(empty)" : stderrSoFar)
            """
        }
    }

    @discardableResult
    private static func runProcess(
        _ executable: String, _ arguments: [String],
        environment: [String: String]? = nil,
        stdinIsNullDevice: Bool = false,
        timeout: TimeInterval = 60
    ) throws -> (status: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment { process.environment = environment }
        if stdinIsNullDevice { process.standardInput = FileHandle.nullDevice }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        try process.run()

        // Drain both pipes concurrently rather than sequentially: reading
        // stdout to EOF before touching stderr can deadlock if the child
        // fills the stderr pipe's kernel buffer while blocked writing to
        // it — the same hazard `PasswordCommandSecretSource` guards against
        // (`Sources/macSCPCore/Sessions/CLISecretSources.swift`).
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
        // Bounded, because an unbounded wait turns "the CLI stalled" into "the
        // suite hangs forever with no clue which call did it". On expiry the
        // child is killed so the pipes reach EOF and the readers finish.
        if group.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            if group.wait(timeout: .now() + 5) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = group.wait(timeout: .now() + 5)
            }
            process.waitUntilExit()
            throw CLIProcessTimeout(
                arguments: arguments,
                seconds: timeout,
                stderrSoFar: String(data: stderrBox.data, encoding: .utf8) ?? "")
        }
        process.waitUntilExit()

        return (
            process.terminationStatus,
            String(data: stdoutBox.data, encoding: .utf8) ?? "",
            String(data: stderrBox.data, encoding: .utf8) ?? ""
        )
    }

    /// Plain reference-type box for a background pipe-read result. Written
    /// once from a background queue, read once afterward from the calling
    /// thread once `group.wait()` has returned — that establishes the
    /// happens-before edge, so the lack of a lock is safe.
    private final class CollectedOutput: @unchecked Sendable {
        var data = Data()
    }

    private struct HarnessError: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }
}
