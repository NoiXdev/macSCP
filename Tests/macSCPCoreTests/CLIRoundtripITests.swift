import Foundation
import Testing
@testable import macSCPCore

/// Gated behind MACSCP_ITEST: needs the Docker SSH rig (127.0.0.1:2222).
/// Start the rig from the MAIN checkout, never a worktree — the seed mount
/// is relative to the compose file.
///
/// Every test here drives the BUILT `macscp-cli` BINARY as a subprocess (not
/// the Swift API underneath it) — the same entry point a user invokes, flags
/// and exit codes included. `.serialized` because they drive the same rig
/// against overlapping remote paths, and concurrent runs would see each
/// other's files. (The `sessions --json` roundtrip moved out to
/// `CLISessionsJSONRoundtripTests` on 2026-09-02: it never touches the rig,
/// so gating it here was wider than the guarantee it needs.)
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
        let binary = try CLIMatrix.binaryURL()
        let storageDirectory = try Self.makeTempDirectory(prefix: "macscp-cli-roundtrip-storage")
        defer { try? FileManager.default.removeItem(at: storageDirectory) }
        let localDirectory = try Self.makeTempDirectory(prefix: "macscp-cli-roundtrip-local")
        defer { try? FileManager.default.removeItem(at: localDirectory) }

        let session = sshSession(
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
        // `defer` bodies cannot `await` — the compiler rejects it — so the
        // cleanup that used to sit in one is a closure both exits call, the
        // throwing one included, which is the whole reason it was a `defer`.
        let removeUploadedFile: @Sendable () async -> Void = {
            _ = try? await Self.runCLI(
                binary, ["rm", "--accept-new", "\(remoteDirectory)/\(remoteFileName)"],
                storageDirectory: storageDirectory)
        }

        do {
            let putResult = try await Self.runCLI(
                binary,
                ["put", "--accept-new", localSourceFile.path(percentEncoded: false), remoteDirectory + "/"],
                storageDirectory: storageDirectory)
            #expect(putResult.status == 0, "put failed: \(putResult.stderr)")

            let lsResult = try await Self.runCLI(
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

            let getResult = try await Self.runCLI(
                binary,
                ["get", "--accept-new", "\(remoteDirectory)/\(remoteFileName)",
                 downloadDirectory.path(percentEncoded: false)],
                storageDirectory: storageDirectory)
            #expect(getResult.status == 0, "get failed: \(getResult.stderr)")
            let downloadedFile = downloadDirectory.appendingPathComponent(remoteFileName)
            let downloadedContent = try String(contentsOf: downloadedFile, encoding: .utf8)
            #expect(downloadedContent == payload, "downloaded bytes do not match the uploaded payload")

            let rmResult = try await Self.runCLI(
                binary, ["rm", "--accept-new", "\(remoteDirectory)/\(remoteFileName)"],
                storageDirectory: storageDirectory)
            #expect(rmResult.status == 0, "rm failed: \(rmResult.stderr)")

            // Confirms `rm` actually removed it, rather than merely exiting 0.
            let lsAfterRemoval = try await Self.runCLI(
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
        } catch {
            await removeUploadedFile()
            throw error
        }
        await removeUploadedFile()
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
        let binary = try CLIMatrix.binaryURL()
        let storageDirectory = try Self.makeTempDirectory(prefix: "macscp-cli-refusal-storage")
        defer { try? FileManager.default.removeItem(at: storageDirectory) }

        let session = sshSession(
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
        let result = try await Self.runCLI(
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

    /// Pins the actual DEFAULT of `--on-conflict` on `put` — not merely what
    /// `.fail` does once selected. `TransferPlanTests
    /// .anExistingDestinationFailsByDefault` passes `action: .fail`
    /// EXPLICITLY, so it proves nothing about `PutCommand`'s own `@Option
    /// var onConflict: ConflictAction = .fail` declaration; that default
    /// lives in the CLI target, which has no unit test target at all, so
    /// only a subprocess run of the real binary can pin it (M20 final-review
    /// Finding B). `put`s the same file twice with NO `--on-conflict` flag
    /// on either invocation and asserts the second exits `CLIExitCode
    /// .conflict` (15) — the exit code a script would branch on — AND that
    /// the remote content is still the FIRST upload's bytes, not merely that
    /// the command failed.
    @Test func putWithNoConflictFlagRefusesAnExistingDestinationByDefault() async throws {
        let binary = try CLIMatrix.binaryURL()
        let storageDirectory = try Self.makeTempDirectory(prefix: "macscp-cli-conflict-storage")
        defer { try? FileManager.default.removeItem(at: storageDirectory) }
        let localDirectory = try Self.makeTempDirectory(prefix: "macscp-cli-conflict-local")
        defer { try? FileManager.default.removeItem(at: localDirectory) }

        let session = sshSession(
            name: "m20-conflict", host: Self.rigHost, port: Self.rigPort,
            username: Self.rigUsername, authKind: .password)
        try SessionStore(directory: storageDirectory).upsert(session)

        let remoteFileName = "cli-conflict-\(UUID().uuidString).txt"
        let originalPayload = "m20-conflict-original-\(UUID().uuidString)"
        let secondPayload = "m20-conflict-second-\(UUID().uuidString)"
        let localSourceFile = localDirectory.appendingPathComponent(remoteFileName)
        try Data(originalPayload.utf8).write(to: localSourceFile)

        let remoteDirectory = "\(session.name):/config"

        // `defer` bodies cannot `await` — the compiler rejects it — so the
        // cleanup that used to sit in one is a closure both exits call, the
        // throwing one included, which is the whole reason it was a `defer`.
        let removeUploadedFile: @Sendable () async -> Void = {
            _ = try? await Self.runCLI(
                binary, ["rm", "--accept-new", "\(remoteDirectory)/\(remoteFileName)"],
                storageDirectory: storageDirectory)
        }

        do {
            let firstPut = try await Self.runCLI(
                binary,
                ["put", "--accept-new", localSourceFile.path(percentEncoded: false), remoteDirectory + "/"],
                storageDirectory: storageDirectory)
            #expect(firstPut.status == 0, "first put failed: \(firstPut.stderr)")

            // Overwrite the LOCAL file's content: if `.fail` were not actually
            // the default (e.g. it silently regressed to `.overwrite`), the
            // second `put` below would clobber the remote copy with THIS
            // content instead of refusing — which is exactly what the final
            // assertion below would catch.
            try Data(secondPayload.utf8).write(to: localSourceFile)

            let secondPut = try await Self.runCLI(
                binary,
                ["put", "--accept-new", localSourceFile.path(percentEncoded: false), remoteDirectory + "/"],
                storageDirectory: storageDirectory)
            let conflictMessage = "put with no --on-conflict flag must refuse an existing destination "
                + "by default; stderr: \(secondPut.stderr)"
            #expect(secondPut.status == CLIExitCode.conflict.rawValue, "\(conflictMessage)")
            #expect(secondPut.status == 15)

            let downloadDirectory = localDirectory.appendingPathComponent("download", isDirectory: true)
            try FileManager.default.createDirectory(
                at: downloadDirectory, withIntermediateDirectories: true)
            let getResult = try await Self.runCLI(
                binary,
                ["get", "--accept-new", "\(remoteDirectory)/\(remoteFileName)",
                 downloadDirectory.path(percentEncoded: false)],
                storageDirectory: storageDirectory)
            #expect(getResult.status == 0, "get failed: \(getResult.stderr)")
            let downloadedFile = downloadDirectory.appendingPathComponent(remoteFileName)
            let downloadedContent = try String(contentsOf: downloadedFile, encoding: .utf8)
            #expect(
                downloadedContent == originalPayload,
                "remote content changed despite the conflicting put being refused")
        } catch {
            await removeUploadedFile()
            throw error
        }
        await removeUploadedFile()
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

    /// Runs the built CLI binary as a subprocess with an isolated storage
    /// directory and rig credentials, and no controlling terminal (stdin is
    /// the null device) — so a test never depends on whether the process
    /// running `swift test` happens to have one attached.
    ///
    /// Draining, the bound and the kill escalation all live in
    /// `SubprocessRunner`, which awaits the child instead of parking a
    /// cooperative-pool thread on it — see that type's doc comment, and
    /// CLAUDE.md's "Tests never block the cooperative pool". Its
    /// `SubprocessTimeout` names the executable, the argument COUNT, each
    /// reader's state, what the escalation cost and what the child had
    /// written — but never an argument value.
    ///
    /// Not because of anything in THIS suite: the credential here travels in
    /// the environment (`MACSCP_PASSWORD` below), and no `runCLI` call in this
    /// file passes a secret in argv. The withholding is for the suites in this
    /// target that run `ssh-keygen -N <passphrase>`, where an argument IS the
    /// secret — so it is not defensive noise on this path, and restoring the
    /// argument list here would restore it for them.
    private static func runCLI(
        _ binary: URL, _ arguments: [String], storageDirectory: URL
    ) async throws -> (status: Int32, stdout: String, stderr: String) {
        var environment = ProcessInfo.processInfo.environment
        environment["MACSCP_STORAGE_DIRECTORY"] = storageDirectory.path(percentEncoded: false)
        environment["MACSCP_PASSWORD"] = rigPassword
        let result = try await SubprocessRunner.run(
            binary, arguments: arguments, environment: environment)
        return (result.status, result.stdoutText, result.stderrText)
    }
}
