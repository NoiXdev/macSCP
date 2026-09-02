import Citadel
import Foundation
import NIOCore
import Testing
@testable import MacSCPAppKit
@testable import macSCPCore

// MARK: - Rig access
//
// File-scope rather than nested in the suite: the suite is `@MainActor`, and
// none of this needs to be — a `Process` call and a `CitadelFileSystem
// .connect` are both perfectly happy off the main actor, and nesting them
// would only borrow an isolation they then have to hop out of.

/// Ports this suite talks to. 2222 is the shared rig's, READ ONLY here.
/// 2224 is the disposable server's own, deliberately clear of the rig's
/// 2222/2223 and of the WebDAV/MinIO mappings in `compose.yml`.
private let sharedRigPort = 2222
private let dropServerPort = 2224
/// The shell-teardown measurement's OWN disposable server. A third port
/// rather than a second use of 2224: `DisposableSSHServer.start` prunes
/// every container this file has ever created before it starts a new one,
/// so two tests sharing a port would still be two containers, and giving
/// each its own port keeps a leftover from one measurement out of the
/// other's bind. Clear of 2222/2223 and of every mapping in `compose.yml`
/// (checked against that file in this pass: 2222, 2223, 19000, 19001,
/// 18080, 18081, 18443, 18090).
private let shellDropServerPort = 2225
/// How long `teardownAgainstAStillFrozenPeerTerminates` waits for the
/// give-up path before calling it hung.
///
/// Derived from the production bounds it is measuring rather than spelled
/// out beside it (this project's rule about second copies of a name applies
/// to numbers in tests too), and derived from ALL of them: a give-up lap
/// runs `teardown`'s four stages, two of which are bounded by
/// `TeardownStage.boundSeconds` and a third by
/// `CitadelFileSystem.sftpCloseBoundSeconds` inside
/// `CitadelFileSystem.disconnect()`. Summing them is what makes this a
/// statement about the code rather than a guess: a lap that honours every
/// bound cannot spend more than the sum IN THE BOUNDED STAGES, so
/// exhausting this constant means a wait with no bound behind it, not a
/// slow one. The 10-second cushion is for the scheduling drift a
/// `Task.sleep`-based bound carries (measured at 0.5–2.0 seconds per bound
/// in the pass that added the stage bounds) and for the cheap work between
/// the stages. Moving any production bound moves this one with it;
/// removing one stops this file compiling, which is the point.
///
/// The fourth stage, `transferQueue.cancelAll(reason:)`, is deliberately
/// unbounded (see `ContentView.teardown(_:reason:)`), so it contributes
/// nothing to this sum and this constant is NOT an upper bound on a lap in
/// principle — it is an upper bound on the part of the lap the code
/// promises anything about. `cancelAll` is what the cushion is covering for
/// there, on the strength of a measurement: three runs out of three against
/// this very frozen-peer scenario returned inside 0.0056 s.
private let teardownBoundSeconds =
    TeardownStage.allCases.reduce(0) { $0 + $1.boundSeconds }
    + CitadelFileSystem.sftpCloseBoundSeconds + 10
private let seedFilePath = "/data/seed/hello.txt"
private let seedFileName = "hello.txt"

/// The two isolate-close() measurements' own disposable servers (bounded-
/// file-closes plan, Task 1). Two ports rather than a shared one, for
/// `DisposableSSHServer.start`'s own reason given above: each measurement's
/// leftover container must not be able to collide with another's bind.
/// Clear of every port named in the doc comment on `shellDropServerPort`.
/// Back the close()-alone measurements, which bypass `CitadelFileSystem`
/// but not macSCP's own SFTP session — see `connectBoundedSFTP`.
private let isolatedReadCloseServerPort = 2228
private let isolatedWriteCloseServerPort = 2229

/// Bound for every file-close measurement in this section: how long
/// `BoundedSFTPFile.closeBounded()` is given to return once it is racing a
/// peer that is STILL FROZEN.
///
/// Deliberately NOT derived from the production bound it measures, unlike
/// `teardownBoundSeconds` — and that is the point, not an oversight. The
/// production bound is `BoundedSFTPSession.closeBoundSeconds`; a test that
/// spelled the same number could only ever answer "did the bound fire at
/// exactly its own value", which is a tautology about `BoundedClose`. This
/// number is larger on purpose, so what it answers is the question the
/// measurement asked: does the close return AT ALL against a peer that has
/// stopped answering. It has to stay comfortably above the production bound
/// for that to keep working; at 10s against 5s it has a factor of two.
/// 10s, per the measurement plan
/// (`.superpowers/sdd/2026-09-02-unbounded-file-closes-measurement/task-1-brief.md`).
private let fileCloseBoundSeconds = 10

/// `#filePath` here is
/// `<repoRoot>/Tests/macSCPAppKitTests/LivenessProbeDropIntegrationTests.swift`;
/// three `deletingLastPathComponent()` calls recover the repo root
/// regardless of `swift test`'s working directory (same trick as
/// `LivenessProbeWiringGuardTests`).
private let repoRoot: URL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent()

/// Connects to an SSH server on `port` with the rig's own credentials,
/// pinning its host key in a throwaway directory. Same retry cushion as
/// `CitadelFileSystemIntegrationTests.connectWithRetry`, for the same
/// reason: the container throttles repeated connects.
private func connectToSSHServer(port: Int) async throws -> CitadelFileSystem {
    let config = try SSHConnectionConfig(
        host: "127.0.0.1", port: port, username: "testuser",
        auth: .password("testpass"))
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("macscp-liveness-kh-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let knownHosts = KnownHostsStore(directory: directory)
    func attempt() async throws -> CitadelFileSystem {
        try await CitadelFileSystem.connect(
            config: config, connectTimeout: .seconds(30),
            knownHosts: knownHosts, onUnknownHostKey: .asking { _ in true })
    }
    do {
        return try await attempt()
    } catch {
        try? await Task.sleep(for: .milliseconds(500))
        return try await attempt()
    }
}

/// Connects to an SSH server on `port` through Citadel DIRECTLY, bypassing
/// `CitadelFileSystem`, and opens macSCP's own SFTP session on it.
///
/// Needed for the isolate-close() measurements below
/// (`aReadHandleCloseAgainstAStillFrozenPeerReturnsInsideTheBound` and
/// `aWriteFileCloseAgainstAStillFrozenPeerReturnsInsideTheBound`): those
/// tests measure one file close alone, and
/// `CitadelFileSystem.readStream`/`.write` never hand their file handle
/// back to a caller — closing it happens only inside those methods' own
/// bodies, which is not a path either test can reach from outside it.
/// Retries past the disposable container's own startup, the same shape and
/// reason as `DisposableSSHServer.connect()`.
///
/// What is bypassed is `CitadelFileSystem`, and nothing below it: the
/// session handed back is a `BoundedSFTPSession`, so the file it opens is a
/// `BoundedSFTPFile` and the close these tests measure is
/// `closeBounded()` — the call the product makes. While the measurement was
/// being taken (Task 1) this returned Citadel's own `SFTPClient` and the
/// tests closed a raw `SFTPFile`, because there was then nothing else to
/// close; measuring that now would measure Citadel rather than macSCP, and
/// would go on passing if `BoundedSFTPFile` were deleted.
///
/// No host-key persistence, unlike `connectToSSHServer`: this dials a
/// throwaway disposable container once per test, so there is nothing
/// worth pinning past that single connection, and `.acceptAnything()` is
/// the same TOFU-bypass posture the rest of this file's raw fixture
/// connections use.
private func connectBoundedSFTP(
    port: Int
) async throws -> (client: SSHClient, sftp: BoundedSFTPSession) {
    let deadline = ContinuousClock.now.advanced(by: .seconds(90))
    var lastError: Error?
    while ContinuousClock.now < deadline {
        do {
            let client = try await SSHClient.connect(
                host: "127.0.0.1", port: port,
                authenticationMethod: .passwordBased(username: "testuser", password: "testpass"),
                hostKeyValidator: .acceptAnything(),
                reconnect: .never)
            let sftp = try await BoundedSFTPSession.open(on: client)
            return (client, sftp)
        } catch {
            lastError = error
            try? await Task.sleep(for: .milliseconds(500))
        }
    }
    throw DockerError.serverNeverAccepted(
        name: "bounded SFTP on port \(port)", underlying: String(describing: lastError))
}

/// Closes `client`, discarding any error.
private func closeIgnoringErrors(_ client: sending SSHClient) async {
    try? await client.close()
}

private enum DockerError: Error, CustomStringConvertible {
    case executableNotFound
    case imagePinNotFound(URL)
    case commandFailed(String, status: Int32, output: String)
    case serverNeverAccepted(name: String, underlying: String)
    case pruneFailed([String])

    var description: String {
        switch self {
        case .executableNotFound:
            return "no `docker` executable found — this suite needs the Docker CLI."
        case .imagePinNotFound(let url):
            return "no openssh-server image pin found in \(url.path(percentEncoded: false))."
        case .commandFailed(let command, let status, let output):
            return "`\(command)` exited \(status): \(output)"
        case .serverNeverAccepted(let name, let underlying):
            return "the disposable server \(name) never accepted a connection: \(underlying)"
        case .pruneFailed(let ids):
            return """
                containers from an earlier run of this suite could not be \
                removed and still hold port \(dropServerPort): \(ids.joined(separator: ", "))
                """
        }
    }
}

/// Somewhere for the background drain in `Docker.run` to put what it read.
/// `@unchecked Sendable` because the only handoff is a single write before
/// `DispatchGroup.wait()` returns and a single read after it, which is the
/// group's own ordering guarantee rather than a claim about this class.
private final class DataBox: @unchecked Sendable {
    var value = Data()
}

private enum Docker {
    /// `Process` inherits this test runner's environment, whose `PATH` is
    /// whatever launched `swift test` — not something to rely on, so the
    /// usual install locations are probed directly.
    static func executablePath() throws -> String {
        let candidates = [
            "/usr/local/bin/docker",
            "/opt/homebrew/bin/docker",
            "/usr/bin/docker",
        ]
        guard let found = candidates.first(where: {
            FileManager.default.isExecutableFile(atPath: $0)
        }) else {
            throw DockerError.executableNotFound
        }
        return found
    }

    /// One `docker` invocation, with the two streams kept APART (whole-branch
    /// final review, finding M-3). They used to share a pipe, and `output`
    /// was then split into container ids: any daemon chatter on stderr — a
    /// config-load warning, a context or deprecation notice — would have
    /// become a phantom "leftover" that `docker rm -f` could not remove, so
    /// `pruneLeftovers()` would spin to its deadline and throw. Nothing that
    /// is parsed may share a stream with something that is only ever read by
    /// a human.
    struct Result {
        let status: Int32
        /// Standard output alone. This is what gets parsed.
        let output: String
        /// Standard error alone. Never parsed; carried so a failure message
        /// can say what the daemon actually complained about.
        let errorOutput: String

        /// Both streams, for the failure messages — where losing stderr
        /// would throw away the only sentence that explains the exit code.
        var combinedOutput: String {
            [output, errorOutput]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
        }
    }

    static func run(_ arguments: [String]) throws -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: try executablePath())
        process.arguments = arguments
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        try process.run()
        // Both pipes drained BEFORE waiting, and CONCURRENTLY: a command
        // that writes more than a pipe's buffer holds would otherwise block
        // forever on a full pipe while this side waits for it to exit — and
        // with two pipes, draining one to the end before starting on the
        // other is the same deadlock with an extra step.
        let errorData = DataBox()
        let drained = DispatchGroup()
        drained.enter()
        DispatchQueue.global().async {
            errorData.value = errorPipe.fileHandleForReading.readDataToEndOfFile()
            drained.leave()
        }
        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        drained.wait()
        process.waitUntilExit()
        return Result(
            status: process.terminationStatus,
            output: String(decoding: outputData, as: UTF8.self),
            errorOutput: String(decoding: errorData.value, as: UTF8.self))
    }

    /// Reads the image tag out of `compose.yml` instead of repeating it
    /// here. A second copy of a pinned tag is a copy that drifts, and a
    /// disposable server running a different sshd build than the rig would
    /// be a difference nobody chose.
    static func pinnedSSHImage() throws -> String {
        let composeURL = repoRoot.appendingPathComponent("docker/test-server/compose.yml")
        let source = try String(contentsOf: composeURL, encoding: .utf8)
        for line in source.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("image:") else { continue }
            let value = trimmed.dropFirst("image:".count).trimmingCharacters(in: .whitespaces)
            if value.contains("openssh-server") { return value }
        }
        throw DockerError.imagePinNotFound(composeURL)
    }
}

/// An SSH server started and killed by the drop tests alone, so they never
/// touch the shared rig — see the suite's own doc comment for why that
/// separation is not optional. No volumes are mounted, so unlike the compose
/// rig it has no working-directory dependency; the probe only ever `stat`s
/// the login home directory.
private struct DisposableSSHServer {
    /// Every container this suite creates carries this prefix, followed by a
    /// per-run suffix. The prefix is what makes the leftovers of an EARLIER
    /// run findable; the suffix is what keeps two containers in one run from
    /// colliding.
    static let namePrefix = "macscp-liveness-drop-"

    let name: String
    let port: Int

    static func start(port: Int) throws -> DisposableSSHServer {
        // Prune FIRST, and by prefix: a leftover from an earlier run holds
        // port 2224, and its name carries that run's suffix, not this one's
        // — so removing "the name this run is about to use" could never have
        // found it. The first version of this code did exactly that, and a
        // container left paused by a hung run failed every later run with
        // `Bind for 0.0.0.0:2224 failed: port is already allocated`.
        try pruneLeftovers()
        let name = "\(namePrefix)\(UUID().uuidString.prefix(8))"
        // No `--rm`: an auto-removing container is removed by the daemon in
        // the BACKGROUND once it stops, which raced the prune — the second
        // drop test found the first one's id still listed and `docker rm -f`
        // answered "removal of container … is already in progress". An
        // explicit lifecycle has no such window: this suite is the only thing
        // that ever removes these containers.
        let image = try Docker.pinnedSSHImage()
        let started = try Docker.run([
            "run", "-d", "--name", name,
            "-p", "\(port):2222",
            "-e", "PUID=1000", "-e", "PGID=1000",
            "-e", "PASSWORD_ACCESS=true",
            "-e", "USER_NAME=testuser", "-e", "USER_PASSWORD=testpass",
            image,
        ])
        guard started.status == 0 else {
            throw DockerError.commandFailed(
                "docker run", status: started.status, output: started.combinedOutput)
        }
        return DisposableSSHServer(name: name, port: port)
    }

    /// Retries past the container's own startup (host-key generation and
    /// sshd launch take a moment on a cold container), so a slow start reads
    /// as a slow start rather than as a failed connect.
    func connect() async throws -> CitadelFileSystem {
        let deadline = ContinuousClock.now.advanced(by: .seconds(90))
        var lastError: Error?
        while ContinuousClock.now < deadline {
            do {
                return try await connectToSSHServer(port: port)
            } catch {
                lastError = error
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
        throw DockerError.serverNeverAccepted(
            name: name, underlying: String(describing: lastError))
    }

    /// SIGKILL with no grace period: a connection that goes away, not one
    /// that is shut down politely.
    func kill() throws {
        let stopped = try Docker.run(["stop", "-t", "0", name])
        guard stopped.status == 0 else {
            throw DockerError.commandFailed(
                "docker stop", status: stopped.status, output: stopped.combinedOutput)
        }
    }

    /// Freezes every process in the container without touching its sockets:
    /// the TCP connection stays established and the kernel keeps
    /// acknowledging, but sshd never answers again — the silent death a
    /// `kill()` cannot produce.
    func freeze() throws {
        let paused = try Docker.run(["pause", name])
        guard paused.status == 0 else {
            throw DockerError.commandFailed(
                "docker pause", status: paused.status, output: paused.combinedOutput)
        }
    }

    func thaw() throws {
        let unpaused = try Docker.run(["unpause", name])
        guard unpaused.status == 0 else {
            throw DockerError.commandFailed(
                "docker unpause", status: unpaused.status, output: unpaused.combinedOutput)
        }
    }

    func remove() {
        _ = try? Docker.run(["rm", "-f", name])
    }

    /// Removes every container this suite has ever created, whatever run it
    /// belongs to and whatever state it is in. `docker ps -a` lists paused
    /// containers like any other, and `docker rm -f` kills a paused one
    /// rather than refusing — which matters, because the leftover this
    /// exists to clear is precisely the paused one a hung freeze test
    /// abandons.
    ///
    /// What is checked is the STATE afterwards, not `docker rm -f`'s exit
    /// code. Removal can legitimately fail for a container the daemon is
    /// already removing, and that is not a leftover; the only question worth
    /// answering is whether anything carrying the prefix is still there when
    /// this returns. A prune that cannot reach that state throws, because
    /// the alternative is letting the next `docker run` fail on an allocated
    /// port and having to work backwards from a bind error.
    /// Cleanup that does not depend on the main actor.
    ///
    /// Every other cleanup path in this file — `defer { server.remove() }`
    /// included — runs on the test's own task, which is `@MainActor`. A
    /// measurement that BLOCKED the main actor rather than suspending on it
    /// would take those defers down with it and leave a PAUSED container
    /// behind, holding port 2224 against every later run. This one is
    /// detached, so it runs on the cooperative pool whatever the main actor
    /// is doing, and it force-removes by prefix — the same removal
    /// `pruneLeftovers` performs, just from somewhere a deadlock cannot
    /// reach. Cancelled by the test on a normal exit.
    static func pruneAfter(seconds: Int) -> Task<Void, Never> {
        Task.detached {
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            try? pruneLeftovers()
        }
    }

    static func pruneLeftovers() throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while true {
            let ids = try leftoverIDs()
            guard !ids.isEmpty else { return }
            _ = try? Docker.run(["rm", "-f"] + ids)
            let remaining = try leftoverIDs()
            guard !remaining.isEmpty else { return }
            guard ContinuousClock.now < deadline else {
                throw DockerError.pruneFailed(remaining)
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
    }

    /// The ids of this suite's own leftover containers, and only those.
    ///
    /// Docker's `name` filter is a REGEX MATCH ON A SUBSTRING, not an
    /// anchored prefix (whole-branch final review, finding M-4: an earlier
    /// version of this function and its own doc comment both called it a
    /// prefix, which it is not). It is still what narrows the listing —
    /// asking the daemon for less is cheaper than filtering everything it
    /// owns — but the prefix claim is now ENFORCED here, against the names
    /// the daemon reports, instead of being assumed of a filter that does
    /// not make it. A container merely CONTAINING the string, however it
    /// came to be named that, is not this suite's to remove.
    ///
    /// Anchoring the filter itself (`name=^macscp-liveness-drop-`) would
    /// leave the claim resting on how one Docker version happens to treat
    /// `^` against a name the API stores with a leading slash. Checking the
    /// name here rests on nothing but `hasPrefix`.
    private static func leftoverIDs() throws -> [String] {
        let listed = try Docker.run([
            "ps", "-a", "--filter", "name=\(namePrefix)", "--format", "{{.ID}}\t{{.Names}}",
        ])
        guard listed.status == 0 else {
            throw DockerError.commandFailed(
                "docker ps", status: listed.status, output: listed.combinedOutput)
        }
        return listed.output.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            guard fields.count == 2 else { return nil }
            // A container can carry several names; any one of them starting
            // with the prefix makes it ours.
            let names = fields[1].split(separator: ",").map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            guard names.contains(where: { $0.hasPrefix(namePrefix) }) else { return nil }
            return String(fields[0])
        }
    }
}

/// Forwards every call to a real `RemoteFileSystem` and counts the `stat`s
/// that reach it for ONE path: the probe's own target.
///
/// Counting the probe's DECISION to stat instead — which an earlier version
/// of this suite did — measures the wrong thing. A stubbed file system that
/// always answered "alive" without touching the wire would have satisfied
/// it, so the success case would have claimed a live round trip it never
/// made. This counts arrivals at the real connection.
///
/// Only the probe's target path is counted, because a transfer legitimately
/// `stat`s the file it is about to read, and that is real traffic rather
/// than a probe. Distinguishing them by path is what lets "a busy lap issued
/// no probe" be checked while a genuine download is in flight.
private final class ProbeTargetStatCounter: RemoteFileSystem, @unchecked Sendable {
    private let wrapped: any RemoteFileSystem
    private let countedPath: String
    private let lock = NSLock()
    private var arrivals = 0

    init(wrapping wrapped: any RemoteFileSystem, countingStatsOf countedPath: String) {
        self.wrapped = wrapped
        self.countedPath = countedPath
    }

    var probeStatsOnTheWire: Int { lock.withLock { arrivals } }

    func stat(path: String) async throws -> RemoteFileItem {
        if path == countedPath { lock.withLock { arrivals += 1 } }
        return try await wrapped.stat(path: path)
    }

    var supportsAppendResume: Bool { wrapped.supportsAppendResume }

    func list(path: String) async throws -> [RemoteFileItem] {
        try await wrapped.list(path: path)
    }

    func readStream(
        path: String, fromOffset offset: UInt64
    ) async throws -> AsyncThrowingStream<Data, Error> {
        try await wrapped.readStream(path: path, fromOffset: offset)
    }

    func write(
        path: String, mode: WriteMode, contents: AsyncThrowingStream<Data, Error>
    ) async throws {
        try await wrapped.write(path: path, mode: mode, contents: contents)
    }

    func delete(path: String) async throws {
        try await wrapped.delete(path: path)
    }

    func createDirectory(at path: String) async throws {
        try await wrapped.createDirectory(at: path)
    }

    func rename(from: String, to: String) async throws {
        try await wrapped.rename(from: from, to: to)
    }

    func setPermissions(path: String, permissions: UInt32) async throws {
        try await wrapped.setPermissions(path: path, permissions: permissions)
    }

    func deleteTree(at path: String) async throws {
        try await wrapped.deleteTree(at: path)
    }

    func homeDirectoryPath() async throws -> String {
        try await wrapped.homeDirectoryPath()
    }

    func disconnect() async {
        await wrapped.disconnect()
    }
}

/// Test double for `SecretStore`, local to this file for the same reason
/// `LivenessGiveUpOrderingTests`' own `NoOpSecretStore` is: `macSCPAppKitTests`
/// cannot import `macSCPCoreTests`, where `InMemorySecretStore` lives. Its
/// only job is to not be `KeychainSecretStore` — a test on this branch has
/// already written into the maintainer's real keychain once.
private struct InertSecretStore: SecretStore {
    func savePassword(_ password: String, for sessionID: UUID) throws {}
    func password(for sessionID: UUID) throws -> String? { nil }
    func deletePassword(for sessionID: UUID) throws {}
}

/// Forwards every call to a real `RemoteFileSystem` and timestamps the ONE
/// call this file's teardown measurement is about: `disconnect()`, entered
/// and returned.
///
/// Two instants rather than a duration, because the interesting case is the
/// one where there IS no duration yet — `enteredAt` set with `returnedAt`
/// still `nil` is what distinguishes "the teardown is sitting inside
/// `disconnect()`" from "the teardown never got that far", and no wrapper
/// that only measured completed calls could tell those apart.
private final class DisconnectTimingProbe: RemoteFileSystem, @unchecked Sendable {
    private let wrapped: any RemoteFileSystem
    private let lock = NSLock()
    private var entered: ContinuousClock.Instant?
    private var returned: ContinuousClock.Instant?

    init(wrapping wrapped: any RemoteFileSystem) {
        self.wrapped = wrapped
    }

    var enteredAt: ContinuousClock.Instant? { lock.withLock { entered } }
    var returnedAt: ContinuousClock.Instant? { lock.withLock { returned } }

    func disconnect() async {
        lock.withLock { entered = .now }
        await wrapped.disconnect()
        lock.withLock { returned = .now }
    }

    var supportsAppendResume: Bool { wrapped.supportsAppendResume }

    func stat(path: String) async throws -> RemoteFileItem {
        try await wrapped.stat(path: path)
    }

    func list(path: String) async throws -> [RemoteFileItem] {
        try await wrapped.list(path: path)
    }

    func readStream(
        path: String, fromOffset offset: UInt64
    ) async throws -> AsyncThrowingStream<Data, Error> {
        try await wrapped.readStream(path: path, fromOffset: offset)
    }

    func write(
        path: String, mode: WriteMode, contents: AsyncThrowingStream<Data, Error>
    ) async throws {
        try await wrapped.write(path: path, mode: mode, contents: contents)
    }

    func delete(path: String) async throws {
        try await wrapped.delete(path: path)
    }

    func createDirectory(at path: String) async throws {
        try await wrapped.createDirectory(at: path)
    }

    func rename(from: String, to: String) async throws {
        try await wrapped.rename(from: from, to: to)
    }

    func setPermissions(path: String, permissions: UInt32) async throws {
        try await wrapped.setPermissions(path: path, permissions: permissions)
    }

    func deleteTree(at path: String) async throws {
        try await wrapped.deleteTree(at: path)
    }

    func homeDirectoryPath() async throws -> String {
        try await wrapped.homeDirectoryPath()
    }
}

/// The two instants `ShellCloseTimingProbe` writes, held apart from the
/// probe itself because the probe is created INSIDE the shell-opening
/// closure — the test never gets a reference to it, only to this.
///
/// Two instants and not a duration, for `DisconnectTimingProbe`'s reason:
/// the case this measurement exists for is the one where there is no
/// duration yet.
private final class ShellCloseRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var entered: ContinuousClock.Instant?
    private var returned: ContinuousClock.Instant?

    var enteredAt: ContinuousClock.Instant? { lock.withLock { entered } }
    var returnedAt: ContinuousClock.Instant? { lock.withLock { returned } }

    func markEntered() { lock.withLock { entered = .now } }
    func markReturned() { lock.withLock { returned = .now } }
}

/// Forwards every call to a real `RemoteShell` and timestamps the ONE call
/// the shell-teardown measurement is about: `close()`, entered and returned.
///
/// `TerminalPanelViewModel` is a concrete class with no seam to wrap, so
/// `shutdown()` itself cannot be instrumented from outside. This sits one
/// level below it, at the only call in `shutdown()` that touches the wire —
/// which is what makes an answer attributable to `CitadelShell.close()`
/// rather than to the panel's teardown in general.
private final class ShellCloseTimingProbe: RemoteShell, @unchecked Sendable {
    private let wrapped: any RemoteShell
    private let recorder: ShellCloseRecorder

    init(wrapping wrapped: any RemoteShell, recording recorder: ShellCloseRecorder) {
        self.wrapped = wrapped
        self.recorder = recorder
    }

    var output: AsyncThrowingStream<[UInt8], Error> { wrapped.output }

    func send(_ bytes: [UInt8]) async throws { try await wrapped.send(bytes) }

    func resize(cols: Int, rows: Int) async throws {
        try await wrapped.resize(cols: cols, rows: rows)
    }

    func close() async {
        recorder.markEntered()
        await wrapped.close()
        recorder.markReturned()
    }
}

/// Records the instant an operation finished, from outside the scope that
/// awaited it — so a measurement whose bound expired can still find out
/// whether the operation it abandoned ever came back, and when.
private final class CompletionStamp: @unchecked Sendable {
    private let lock = NSLock()
    private var instant: ContinuousClock.Instant?

    var finishedAt: ContinuousClock.Instant? { lock.withLock { instant } }

    func stamp() { lock.withLock { instant = .now } }
}

/// Runs `operation` against a wall-clock bound and answers whether it
/// returned inside it — `LivenessProbeRace`'s shape, for
/// `LivenessProbeRace`'s reason: a structured child would be awaited by its
/// own scope, so an operation that never returns would hang the measurement
/// instead of being measured by it. Two unstructured tasks resolving one
/// continuation is the only shape that can outlive its own operation.
///
/// One deliberate difference from `LivenessProbeRace`: the loser is NOT
/// cancelled. This exists to observe an abandoned teardown, and cancelling
/// it would both destroy that observation and risk making an underlying
/// call fail early — which would read as "it returned" and be exactly the
/// wrong answer.
///
/// The bound is a claim about the main actor as much as about `operation`:
/// `timeoutTask` is `@MainActor`, so it can only fire if the main actor is
/// free. A teardown that BLOCKED the main actor rather than suspending on
/// it would take this bound down with it — which is what the out-of-process
/// watchdog in `pruneAfter(seconds:)` is for.
@MainActor
private enum BoundedRun {
    static func run(
        boundSeconds: Int, operation: @escaping @MainActor () async -> Void
    ) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let box = Box(continuation: continuation)
            Task { @MainActor in
                await operation()
                box.resume(with: true)
            }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(boundSeconds))
                box.resume(with: false)
            }
        }
    }

    @MainActor
    private final class Box {
        private var continuation: CheckedContinuation<Bool, Never>?

        init(continuation: CheckedContinuation<Bool, Never>) {
            self.continuation = continuation
        }

        func resume(with value: Bool) {
            guard let continuation else { return }
            self.continuation = nil
            continuation.resume(returning: value)
        }
    }
}

// MARK: - The suite

/// The only tests on this branch that let a REAL connection die
/// (connection-liveness plan, Task 10). Everything else about the probe is
/// proven against fakes: `LivenessProbeRaceTests` uses a `stat` that never
/// resumes, `LivenessGiveUpOrderingTests` uses a `LocalFileSystem` standing
/// in for a remote one, and `ConnectionLivenessTests` drives
/// `LivenessProbePolicy` as pure values. None of them can tell whether a
/// `stat` over a genuinely severed SSH connection fails at all, let alone
/// how long that takes — so without this suite the whole detection story is
/// asserted rather than demonstrated.
///
/// **Where it lives, and why not `macSCPCoreTests`.** The plan filed this
/// task under `Tests/macSCPCoreTests/`, next to the rest of the gated
/// suites. It is here instead because the mechanism under test is not in
/// Core: `LivenessProbeRace` (the deadline this whole task hinges on) and
/// `ContentView.handleLivenessGiveUp(_:)` (the give-up entry point) are both
/// `MacSCPAppKit` types, and `macSCPCoreTests` cannot see them. A Core suite
/// could only have called `stat` directly — which, against a connection that
/// dies silently, is precisely the call that does not return, so the test
/// itself would hang rather than fail. `MACSCP_ITEST=1` gates this suite
/// exactly as it gates the Core ones; it is the first gated suite in
/// `macSCPAppKitTests`.
///
/// **Which server dies.** Not the shared rig. `docker compose … stop sshd`
/// would sever port 2222 out from under five other gated suites, which Swift
/// Testing runs in parallel with this one: `CitadelFileSystemIntegrationTests`,
/// `CitadelShellIntegrationTests`, `CrossBackendTransferIntegrationTests`,
/// `CLIRoundtripITests`, and `WebDAVFileSystemIntegrationTests`, whose
/// `connectSSH` helper dials 2222 for its cross-backend cases. Counted by
/// searching every gated suite for that port, not recalled — a first pass
/// wrote three, and the two it forgot are the two whose names do not say
/// "Citadel". A suite that breaks
/// its neighbours nondeterministically proves nothing. The two tests that
/// need a peer to die start their OWN container instead, from the same
/// pinned image (read out of `compose.yml`, so the pin cannot drift) on its
/// own port, and kill or freeze that. The shared rig
/// is only ever read from, so this suite cannot leave it stopped however it
/// fails. `defer` removes the disposable container on every exit path an
/// `#expect` failure or a thrown `#require` can take, and `start`
/// force-removes a same-named leftover first, so even a hard crash cannot
/// block a re-run.
///
/// **What is still not exercised.** `LivenessProbeRunner`'s `.task(id:)`
/// body itself — this project has no SwiftUI rendering harness, so the loop
/// that composes these pieces can only be read, not run. `ProbeLoop` in this
/// file mirrors one lap of its inner `probing:` loop, minus the sleeps;
/// `LivenessProbeWiringGuardTests` is what pins the real loop to that same
/// shape (interval read every lap, decision through `LivenessProbePolicy
/// .decide`, `.giveUp` delegating to `onGiveUp`, the probe arm going
/// through `LivenessProbeStep.perform`), so the mirror cannot quietly
/// describe a loop that no longer exists.
///
/// Isolation, to the standard `ConnectAttemptHandoffTests` set for this
/// branch: every store handed to `ContentView` is a temp directory or an
/// in-memory double — `secretStore:` and `managedKeyStore:` included, which
/// the whole-branch final review found missing here (finding M-2), leaving
/// this fixture holding a real `KeychainSecretStore` and the real
/// Application Support directory, harmless only for as long as no test in
/// this suite called a function that reads them — and
/// `theRealSessionsFileIsNeverTouched` demonstrates that rather than
/// assuming it.
@Suite(
    "Liveness probe against a real connection",
    .enabled(if: ProcessInfo.processInfo.environment["MACSCP_ITEST"] == "1"),
    .serialized
)
@MainActor
struct LivenessProbeDropIntegrationTests {

    // MARK: - The demonstrations

    /// Step 1. A probe that only ever FAILED would prove nothing about the
    /// mechanism — a `stat` can fail for a wrong path, a closed SFTP
    /// subsystem or a typo in the fixture just as readily as for a dead
    /// socket. This pins the other half: against the live rig the very same
    /// call the probe makes, through the very same deadline, reaches the
    /// connection, comes back alive, and leaves the tab `.connected`.
    ///
    /// "Reaches the connection" is the load-bearing half, and it is counted
    /// at the wire rather than at the decision — an earlier version counted
    /// the probe's intent to `stat`, which a stub that always answered
    /// "alive" would have satisfied without ever dialling anything.
    @Test func theProbeSucceedsAgainstALivePeer() async throws {
        let fixture = makeFixture()
        defer { fixture.cleanup() }
        let fs = try await connectToSSHServer(port: sharedRigPort)
        defer { Task { await fs.disconnect() } }
        let home = try await fs.homeDirectoryPath()
        let tab = makeTab()
        let counter = attachSession(to: tab, remoteFS: fs, homePath: home)

        var loop = fixture.probeLoop(for: tab)
        let action = await loop.lap()

        #expect(action == .probe)
        #expect(counter.probeStatsOnTheWire == 1)
        #expect(loop.consecutiveFailures == 0)
        #expect(tab.liveness == .connected)
    }

    /// Step 2. Reachable at this layer, and driven by a transfer that really
    /// moves bytes over the rig rather than by a hand-set flag: `isActive`
    /// is true from the synchronous `enqueue` onward, so the probing lap runs
    /// while a genuine download is outstanding. What it demonstrates is that
    /// `decide` answers `.skip` for that real queue state and that the lap
    /// issues NO `stat` — the count taken at the connection is what
    /// separates "skipped" from "probed and happened to succeed", which an
    /// assertion on `tab.liveness` alone could not, since both outcomes
    /// leave it `.connected`.
    ///
    /// Two controls keep the result from being vacuous. The transfer is
    /// awaited to completion and its bytes checked, so a queue that was
    /// "busy" only because the job was broken would not pass; and a second
    /// lap runs once the queue is idle, which must probe. Without that
    /// second lap, a `decide` that answered `.skip` unconditionally would
    /// look identical.
    @Test func theProbeIsSkippedWhileTheQueueHasRealWork() async throws {
        let fixture = makeFixture()
        defer { fixture.cleanup() }
        let fs = try await connectToSSHServer(port: sharedRigPort)
        defer { Task { await fs.disconnect() } }
        let home = try await fs.homeDirectoryPath()
        let tab = makeTab()
        let counter = attachSession(to: tab, remoteFS: fs, homePath: home)

        let downloadDirectory = fixture.makeSubdirectory("downloads")
        let localFS = try #require(tab.session?.localFS)
        // Source is the session's own file system, not the bare connection:
        // the transfer must travel through the same instrument the probe
        // does, or "no probe `stat` arrived" would be a claim about an object
        // the transfer never touched.
        tab.transferQueue.enqueue(
            fileName: seedFileName, direction: .download,
            source: counter, sourcePath: seedFilePath,
            destination: localFS,
            destinationDirectory: downloadDirectory.path(percentEncoded: false),
            onCompleted: nil)

        // No `await` between `enqueue` and this lap: the item is still
        // `.queued`, so `isActive` reports the busy queue the probe defers
        // to.
        #expect(tab.transferQueue.isActive)
        var loop = fixture.probeLoop(for: tab)
        let busyAction = await loop.lap()

        #expect(busyAction == .skip)
        #expect(counter.probeStatsOnTheWire == 0)
        #expect(tab.liveness == .connected)

        await waitForIdleQueue(tab.transferQueue)
        let downloaded = try Data(
            contentsOf: downloadDirectory.appendingPathComponent(seedFileName))
        #expect(!downloaded.isEmpty, """
            the download that made the queue busy produced no bytes — the \
            `.skip` this test checks would then have been deferring to a \
            broken job rather than to real traffic.
            """)

        let idleAction = await loop.lap()
        #expect(idleAction == .probe)
        #expect(counter.probeStatsOnTheWire == 1)
        #expect(tab.liveness == .connected)
    }

    /// Step 3, the point of the task: a real peer is killed and the probe
    /// notices. The escalation is the real one — `.probe` fails, `decide`
    /// answers `.probeAgainNow`, that fails too, and the third lap gives up
    /// through `ContentView.handleLivenessGiveUp(_:)`, the same function
    /// `LivenessProbeRunner`'s `.giveUp` case calls.
    ///
    /// The upper bound is deliberately loose. What it separates is "noticed"
    /// from "hung forever" — the failure this whole task exists to rule out
    /// — not one timing from another; the measured figure is printed rather
    /// than asserted, because this suite is run by hand and a tight bound on
    /// a container kill would only produce flakes.
    @Test func aRealDropIsNoticedAndLeavesTheTabLost() async throws {
        let fixture = makeFixture()
        defer { fixture.cleanup() }
        let server = try DisposableSSHServer.start(port: dropServerPort)
        defer { server.remove() }
        let fs = try await server.connect()
        let home = try await fs.homeDirectoryPath()
        let tab = makeTab()
        attachSession(to: tab, remoteFS: fs, homePath: home)

        var loop = fixture.probeLoop(for: tab)
        let beforeDrop = await loop.lap()
        #expect(beforeDrop == .probe)
        #expect(tab.liveness == .connected, """
            the disposable server was not answering probes before it was \
            killed — the drop this test performs would prove nothing.
            """)

        try server.kill()
        let killedAt = ContinuousClock.now

        let firstAfterDrop = await loop.lap()
        #expect(firstAfterDrop == .probe)
        #expect(loop.consecutiveFailures == 1)
        #expect(tab.liveness == .degraded)

        let secondAfterDrop = await loop.lap()
        #expect(secondAfterDrop == .probeAgainNow)
        #expect(loop.consecutiveFailures == 2)
        #expect(tab.liveness == .degraded)

        let thirdAfterDrop = await loop.lap()
        let noticedAfter = killedAt.duration(to: .now)

        #expect(thirdAfterDrop == .giveUp)
        #expect(tab.liveness == .lost)
        #expect(tab.session == nil)
        #expect(tab.lostConnection?.reason == .probeGaveUp)
        #expect(noticedAfter < .seconds(120), """
            the probe took \(noticedAfter) to notice a killed peer — the \
            deadline in `LivenessProbeRace` is supposed to bound this \
            whether or not `stat` ever returns.
            """)
        // The measurement this task exists to produce. Printed, not
        // asserted: the gated suite is run by hand, and Swift Testing has no
        // other channel for a number a PASSING test measured.
        print("[liveness] a killed peer was noticed after \(noticedAfter)")
    }

    /// The other flavour of a drop, and the one the deadline in
    /// `LivenessProbeRace` was actually written for: a peer that stops
    /// answering without closing anything. `docker pause` freezes every
    /// process in the container while leaving its sockets established, so
    /// the probe's `stat` has nothing to fail on — it simply never comes back,
    /// which is the case Citadel's own path into NIO (a bare
    /// `EventLoopFuture.get()` with no cancellation handler) cannot shorten.
    ///
    /// `LivenessProbeRaceTests` makes this same claim against a fake whose
    /// `stat` is written never to resume; this makes it against the real
    /// Citadel stack over a real socket, which is the only way to know the
    /// fake was modelling anything.
    ///
    /// The container is thawed before the give-up lap on purpose. What this
    /// test is about is the two probe laps and the deadline that bounds
    /// them; `teardown(_:reason:)` against a connection that never answers
    /// is a DIFFERENT question, and not one this suite settles — see the
    /// task report. `aRealDropIsNoticedAndLeavesTheTabLost` does run
    /// teardown against a genuinely dead peer.
    @Test func aSilentlyFrozenPeerIsNoticedByTheDeadline() async throws {
        let fixture = makeFixture()
        defer { fixture.cleanup() }
        let server = try DisposableSSHServer.start(port: dropServerPort)
        defer { server.remove() }
        let fs = try await server.connect()
        let home = try await fs.homeDirectoryPath()
        let tab = makeTab()
        attachSession(to: tab, remoteFS: fs, homePath: home)

        var loop = fixture.probeLoop(for: tab)
        let beforeFreeze = await loop.lap()
        #expect(beforeFreeze == .probe)
        #expect(tab.liveness == .connected)

        try server.freeze()
        let frozenAt = ContinuousClock.now

        let firstWhileFrozen = await loop.lap()
        #expect(firstWhileFrozen == .probe)
        #expect(loop.consecutiveFailures == 1)
        #expect(tab.liveness == .degraded)

        let secondWhileFrozen = await loop.lap()
        #expect(secondWhileFrozen == .probeAgainNow)
        #expect(loop.consecutiveFailures == 2)
        #expect(tab.liveness == .degraded)
        let noticedAfter = frozenAt.duration(to: .now)

        try server.thaw()
        let giveUp = await loop.lap()
        #expect(giveUp == .giveUp)
        #expect(tab.liveness == .lost)
        #expect(tab.session == nil)

        // Lower bound: both laps really waited out a deadline rather than
        // getting an immediate error, which is what makes this a test of the
        // TIMEOUT and not a second copy of the killed-peer test. A small
        // margin under two full deadlines tolerates either one firing a hair
        // early on a busy scheduler.
        let deadlineSeconds = LivenessProbePolicy.probeTimeout(
            forInterval: fixture.settingsStore.keepAliveIntervalSeconds)
        #expect(noticedAfter >= .seconds(deadlineSeconds * 2) - .milliseconds(500), """
            two probes against a frozen peer took only \(noticedAfter), less \
            than the two \(deadlineSeconds)s deadlines they should each have \
            waited out — the probe is failing on something other than the \
            deadline, so this test is no longer about the deadline.
            """)
        // Upper bound, generous for the same reason `LivenessProbeRaceTests`
        // keeps its own loose: what it separates is "timed out as designed"
        // from "hung on the abandoned operation forever", not one timing
        // from another.
        #expect(noticedAfter < .seconds(60))
        print("[liveness] a frozen peer was noticed after \(noticedAfter)")
    }

    /// The question `aSilentlyFrozenPeerIsNoticedByTheDeadline` deliberately
    /// does not settle, and the one the backlog entry
    /// `docs/superpowers/specs/2026-08-25-backlog-teardown-with-frozen-peer.md`
    /// was filed to close: the same give-up lap, run against a peer that is
    /// STILL frozen.
    ///
    /// Why it is a different question. `handleLivenessGiveUp(_:)` reaches
    /// `.lost` only by going THROUGH `teardown(_:reason:)`, whose last
    /// session-facing step is `session.remote.disconnect()` — which for an
    /// SSH session is `CitadelFileSystem.disconnect()`, whose first line is
    /// `try? await sftp.close()`. `try?` swallows an error; it does not
    /// bound a wait. If that call does not return against a peer that never
    /// answers, detection is correct and the reaction never happens: the
    /// tab stays `.degraded` forever, with no session on it that anything
    /// can be done about.
    ///
    /// What is measured, and how the bound is honest. The give-up call runs
    /// through `BoundedRun`, which does not cancel what it abandons, so a
    /// hang is DEMONSTRATED — a stated bound that really elapsed — rather
    /// than inferred from a test runner that eventually gave up.
    /// `DisconnectTimingProbe` records when `disconnect()` was entered and
    /// whether it was ever left, which is what makes the answer attributable
    /// to that call rather than to teardown in general.
    ///
    /// Cleanup is three-deep on purpose, because a hang here is the expected
    /// outcome rather than the surprising one: `thaw` and `remove` on the
    /// test's own task, and `pruneAfter` detached from it (see that
    /// function). `docker rm -f` removes a paused container, so the last one
    /// suffices on its own.
    @Test func teardownAgainstAStillFrozenPeerTerminates() async throws {
        let fixture = makeFixture()
        defer { fixture.cleanup() }
        let server = try DisposableSSHServer.start(port: dropServerPort)
        let watchdog = DisposableSSHServer.pruneAfter(seconds: teardownBoundSeconds + 180)
        defer { watchdog.cancel() }
        defer { server.remove() }
        defer { try? server.thaw() }

        let fs = try await server.connect()
        let home = try await fs.homeDirectoryPath()
        let tab = makeTab()
        let timing = DisconnectTimingProbe(wrapping: fs)
        attachSession(to: tab, remoteFS: timing, homePath: home)

        var loop = fixture.probeLoop(for: tab)
        #expect(await loop.lap() == .probe)
        #expect(tab.liveness == .connected, """
            the disposable server was not answering probes before it was \
            frozen — the freeze this test performs would prove nothing.
            """)

        try server.freeze()

        // The same two laps the sibling test makes, for the same reason: the
        // give-up lap is only reachable after two consecutive failures, and
        // reaching it any other way would be measuring teardown from a state
        // the real loop never has.
        #expect(await loop.lap() == .probe)
        #expect(await loop.lap() == .probeAgainNow)
        #expect(tab.liveness == .degraded)

        let stamp = CompletionStamp()
        let startedAt = ContinuousClock.now
        let returned = await BoundedRun.run(boundSeconds: teardownBoundSeconds) {
            await fixture.view.handleLivenessGiveUp(tab)
            stamp.stamp()
        }
        let elapsed = startedAt.duration(to: .now)
        let enteredDisconnect = timing.enteredAt != nil
        let leftDisconnect = timing.returnedAt != nil

        print("""
            [teardown] give-up against a STILL-frozen peer: \
            returned=\(returned) after \(elapsed) \
            (bound \(teardownBoundSeconds)s); \
            disconnect entered=\(enteredDisconnect) returned=\(leftDisconnect); \
            liveness=\(String(describing: tab.liveness)) \
            session=\(tab.session == nil ? "nil" : "present")
            """)

        if !returned {
            // The abandoned teardown is still in flight. Thawing is the
            // cheapest question that can be asked of it: does the peer
            // answering again release it, or was the wait never going to end
            // whatever the peer did? Both answers are worth having, and the
            // container has to be thawed anyway.
            try? server.thaw()
            let thawedAt = ContinuousClock.now
            let releaseDeadline = thawedAt.advanced(by: .seconds(60))
            while stamp.finishedAt == nil, ContinuousClock.now < releaseDeadline {
                try? await Task.sleep(for: .milliseconds(200))
            }
            let releasedAfterThaw = stamp.finishedAt.map { thawedAt.duration(to: $0) }
            print("""
                [teardown] after thawing, the abandoned give-up \
                \(releasedAfterThaw.map { "returned after \($0)" } ?? "was still in flight 60s later"); \
                liveness=\(String(describing: tab.liveness))
                """)
        }

        #expect(returned, """
            `handleLivenessGiveUp` did not return within \
            \(teardownBoundSeconds)s against a peer that is still frozen \
            (`disconnect()` entered: \(enteredDisconnect), returned: \
            \(leftDisconnect)). The probe's detection is bounded by \
            `LivenessProbeRace`; the reaction it triggers is not, so the tab \
            never reaches `.lost`.
            """)
        #expect(tab.liveness == .lost)
        #expect(tab.session == nil)
    }

    /// The same give-up lap as the test above, with the one thing that test
    /// deliberately does not have: an OPEN TERMINAL SHELL.
    ///
    /// Why that is a different question. `teardown(_:reason:)` runs
    /// `cancelAll` → `editManager.stopAll()` → `session.terminal.shutdown()`
    /// → `session.remote.disconnect()`. Only the LAST of those four is
    /// bounded (by `CitadelFileSystem.sftpCloseBoundSeconds`). The third
    /// ends in `CitadelShell.close()`, which is `pump.cancel()` followed by
    /// an unbounded `await pump.value` — and the pump's last act, inside
    /// Citadel's `withPTY`, is `try await channel.close()` on the shell's
    /// own SSH child channel. That is the SAME kind of call the previous
    /// measurement found not returning against a frozen peer
    /// (`.superpowers/sdd/frozen-peer-measurement.md`, section B:
    /// `SFTPClient.close()` is also a child-channel close). If it does not
    /// return here either, the bound one after it is never reached and the
    /// bound is ineffective for every session with a terminal open.
    ///
    /// Why the sibling test cannot see this. Its `attachSession` hands
    /// `TerminalPanelViewModel` a stand-in opener that throws — so
    /// `shutdown()` finds `shell == nil` and returns without touching the
    /// wire. That is a deliberate choice (the shape `LivenessGiveUpOrdering
    /// Tests` uses, where no connection exists at all), not an environment
    /// gap: the rig can open a real shell, and this test does.
    ///
    /// Instrumentation. `ShellCloseTimingProbe` sits between the panel and
    /// the real `CitadelShell`, so "entered `close()`, never returned" is
    /// attributable to that call; `DisconnectTimingProbe.enteredAt` is the
    /// proxy for "`terminal.shutdown()` returned", because `disconnect()` is
    /// the statement immediately after it in `teardown(_:reason:)` and
    /// nothing between them can suspend.
    ///
    /// Cleanup is the same three-deep discipline as the sibling, for the
    /// same reason: a hang is the expected outcome here, not the surprise.
    @Test func teardownWithAnOpenShellAgainstAStillFrozenPeerTerminates() async throws {
        let fixture = makeFixture()
        defer { fixture.cleanup() }
        let server = try DisposableSSHServer.start(port: shellDropServerPort)
        let watchdog = DisposableSSHServer.pruneAfter(seconds: teardownBoundSeconds + 180)
        defer { watchdog.cancel() }
        defer { server.remove() }
        defer { try? server.thaw() }

        let fs = try await server.connect()
        let home = try await fs.homeDirectoryPath()
        let tab = makeTab()
        let timing = DisconnectTimingProbe(wrapping: fs)
        let shellClose = ShellCloseRecorder()
        // The shell is opened on `fs` itself, not on `timing`: the real app
        // reaches the shell through `remoteFS as? RemoteShellProvider`, and
        // the timing wrapper is not one — same connection either way.
        attachSession(
            to: tab, remoteFS: timing, homePath: home,
            shellOpener: { terminal, cols, rows in
                ShellCloseTimingProbe(
                    wrapping: try await fs.openShell(
                        terminal: terminal, cols: cols, rows: rows),
                    recording: shellClose)
            })

        let terminal = try #require(tab.session?.terminal)
        terminal.openIfNeeded()
        let openDeadline = ContinuousClock.now.advanced(by: .seconds(30))
        while terminal.state != .running, ContinuousClock.now < openDeadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        #expect(terminal.state == .running, """
            no shell was running before the freeze (state \
            \(String(describing: terminal.state))) — the measurement this \
            test exists for would be the sibling test's measurement again.
            """)

        var loop = fixture.probeLoop(for: tab)
        #expect(await loop.lap() == .probe)
        #expect(tab.liveness == .connected)

        try server.freeze()

        #expect(await loop.lap() == .probe)
        #expect(await loop.lap() == .probeAgainNow)
        #expect(tab.liveness == .degraded)

        let stamp = CompletionStamp()
        let startedAt = ContinuousClock.now
        let returned = await BoundedRun.run(boundSeconds: teardownBoundSeconds) {
            await fixture.view.handleLivenessGiveUp(tab)
            stamp.stamp()
        }
        let elapsed = startedAt.duration(to: .now)
        // Every fact this test asserts on is snapshotted HERE, before the
        // thaw below. Measured the first time this test ran: thawing
        // released the abandoned teardown in 0.0022 s, and it then ran to
        // completion — so an assertion reading `timing.enteredAt` or
        // `tab.liveness` AFTER that block would be describing a peer that
        // is answering again, and would pass while the defect it names is
        // present. Only `returned` was red in that run for exactly this
        // reason.
        let shellCloseEntered = shellClose.enteredAt
        let shellCloseReturned = shellClose.returnedAt
        let disconnectEntered = timing.enteredAt != nil
        let livenessAtBound = tab.liveness
        let sessionAtBound = tab.session

        print("""
            [teardown+shell] give-up against a STILL-frozen peer WITH AN OPEN \
            SHELL: returned=\(returned) after \(elapsed) \
            (bound \(teardownBoundSeconds)s); \
            shell.close entered=\(shellCloseEntered != nil) \
            returned=\(shellCloseReturned != nil) \
            \(shellCloseEntered.flatMap { entered in
                shellCloseReturned.map { "after \(entered.duration(to: $0))" }
            } ?? ""); \
            disconnect entered=\(timing.enteredAt != nil) \
            returned=\(timing.returnedAt != nil); \
            liveness=\(String(describing: tab.liveness)) \
            session=\(tab.session == nil ? "nil" : "present")
            """)

        if !returned {
            try? server.thaw()
            let thawedAt = ContinuousClock.now
            let releaseDeadline = thawedAt.advanced(by: .seconds(60))
            while stamp.finishedAt == nil, ContinuousClock.now < releaseDeadline {
                try? await Task.sleep(for: .milliseconds(200))
            }
            let releasedAfterThaw = stamp.finishedAt.map { thawedAt.duration(to: $0) }
            print("""
                [teardown+shell] after thawing, the abandoned give-up \
                \(releasedAfterThaw.map { "returned after \($0)" } ?? "was still in flight 60s later"); \
                shell.close returned=\(shellClose.returnedAt != nil); \
                disconnect entered=\(timing.enteredAt != nil) \
                returned=\(timing.returnedAt != nil); \
                liveness=\(String(describing: tab.liveness))
                """)
        }

        #expect(returned, """
            `handleLivenessGiveUp` did not return within \
            \(teardownBoundSeconds)s against a still-frozen peer WITH AN \
            OPEN SHELL (shell.close entered: \(shellCloseEntered != nil), \
            returned: \(shellCloseReturned != nil); disconnect entered: \
            \(disconnectEntered)). The bound in `disconnect()` only \
            helps a session that reaches it.
            """)
        #expect(disconnectEntered, """
            `terminal.shutdown()` never returned, so the bounded \
            `disconnect()` the previous fix installed was never reached.
            """)
        #expect(livenessAtBound == .lost)
        #expect(sessionAtBound == nil)
    }

    // MARK: - Bounded file closes

    /// Isolates one read-handle close on its own, with nothing else in
    /// flight, against a peer that is STILL FROZEN.
    ///
    /// Reaches a `BoundedSFTPFile` through `connectBoundedSFTP`, bypassing
    /// `CitadelFileSystem.readStream` — that method never hands its handle
    /// back to a caller, so there is no way to isolate its close from
    /// outside it. The connection underneath is opened through Citadel
    /// directly, the same Citadel this project already depends on
    /// (`Package.swift`'s `Citadel` product), the way `connectToSSHServer`
    /// connects through `CitadelFileSystem` for every other test in this
    /// file; what is measured on top of it is macSCP's own
    /// `closeBounded()`, not Citadel's `close()`.
    ///
    /// Shape: upload the fixture through the normal path (so the server
    /// answering is proven before anything freezes), open a SECOND,
    /// independent handle on it, read ONE chunk and await its return —
    /// proof the handle is real and nothing is left in flight — freeze the
    /// peer, then call `closeBounded()` on that idle handle and measure it
    /// alone against the bound, the same before-thaw-capture discipline as
    /// every other test in this file.
    @Test func aReadHandleCloseAgainstAStillFrozenPeerReturnsInsideTheBound() async throws {
        let server = try DisposableSSHServer.start(port: isolatedReadCloseServerPort)
        let watchdog = DisposableSSHServer.pruneAfter(seconds: fileCloseBoundSeconds + 180)
        defer { watchdog.cancel() }
        defer { server.remove() }
        defer { try? server.thaw() }

        let fs = try await server.connect()
        let remotePath = "/config/macscp-isolated-read-close-\(UUID().uuidString).bin"
        try await uploadCloseFixtureFile(to: fs, path: remotePath)

        let (rawClient, sftp) = try await connectBoundedSFTP(port: isolatedReadCloseServerPort)
        let handle = try await sftp.openFile(filePath: remotePath, flags: .read)

        // ONE read, awaited to completion against the STILL-LIVE peer:
        // proof the handle actually works, with the request it made
        // already finished by the time the peer freezes below — nothing
        // left in flight for `close()` to compete with.
        let firstRead = try await handle.read(from: 0, length: UInt32(TransferChunk.size))
        #expect(firstRead.readableBytes > 0, """
            the live-peer read that was meant to prove this handle works \
            returned no bytes — the close measured below would then not \
            be a close of a handle that had ever done anything.
            """)

        try server.freeze()
        // No request is in flight here: the read above already returned,
        // and nothing else has been issued on this handle since. What
        // races the bound below is `closeBounded()` alone.

        // Captured straight into the escaping closure, where the
        // measurement had to route it through an `UncheckedBox` and a
        // `Task`: `BoundedSFTPFile` is `Sendable`, which the raw `SFTPFile`
        // it replaced is not. The box and its two uses went with the raw
        // handle.
        //
        // `closeFinishedInsideItsOwnBound` is what `closeBounded()` itself
        // answers — false when the production bound fired and the close was
        // abandoned, which is the expected outcome against a frozen peer.
        // Recorded and printed, deliberately not asserted: the property
        // this test is named for is that the CALL returns, and a peer that
        // somehow answered would satisfy that too.
        var closeFinishedInsideItsOwnBound: Bool?
        let startedAt = ContinuousClock.now
        let returned = await BoundedRun.run(boundSeconds: fileCloseBoundSeconds) {
            closeFinishedInsideItsOwnBound = await handle.closeBounded()
        }
        let elapsed = startedAt.duration(to: .now)
        let returnedBeforeThaw = returned
        let innerAnswerBeforeThaw = closeFinishedInsideItsOwnBound

        print("""
            [close-alone] read handle closeBounded against a STILL-frozen \
            peer, no request in flight: returned=\(returnedBeforeThaw) after \
            \(elapsed) (bound \(fileCloseBoundSeconds)s); the close itself \
            answered \(String(describing: innerAnswerBeforeThaw))
            """)

        try? server.thaw()
        // Best-effort, not deferred: leaving this unclosed on an early
        // throw is harmless (the container is force-removed regardless by
        // the defers above), and closing it earlier would race the very
        // `close()` this test measures.
        await closeIgnoringErrors(rawClient)

        #expect(returnedBeforeThaw, """
            `BoundedSFTPFile.closeBounded()` (read handle) did not return \
            within \(fileCloseBoundSeconds)s against a peer that is still \
            frozen, with no other request in flight on this handle.
            """)
    }

    /// The write-path sibling of `aReadHandleCloseAgainstAStillFrozenPeerReturnsInsideTheBound`:
    /// isolates one write-handle close on its own, against a peer that is
    /// STILL FROZEN, with nothing else in flight.
    ///
    /// Shape: open a handle on a bare connection (`connectBoundedSFTP`,
    /// same reasoning as the read-path sibling), write ONE 1 MB chunk and
    /// await its return — proof the handle works and the write is no
    /// longer in flight — freeze the peer, then call `closeBounded()`
    /// alone and measure it against the bound.
    @Test func aWriteFileCloseAgainstAStillFrozenPeerReturnsInsideTheBound() async throws {
        let server = try DisposableSSHServer.start(port: isolatedWriteCloseServerPort)
        let watchdog = DisposableSSHServer.pruneAfter(seconds: fileCloseBoundSeconds + 180)
        defer { watchdog.cancel() }
        defer { server.remove() }
        defer { try? server.thaw() }

        // Not through `server.connect()` this time: nothing about this
        // test needs `CitadelFileSystem` at all, unlike the read-path
        // sibling, which still uploads its fixture through the normal
        // path. The write handle IS opened, written to, and closed
        // entirely through the bare connection below.
        let (rawClient, sftp) = try await connectBoundedSFTP(port: isolatedWriteCloseServerPort)
        let remotePath = "/config/macscp-isolated-write-close-\(UUID().uuidString).bin"
        let handle = try await sftp.openFile(
            filePath: remotePath, flags: [.create, .write, .truncate])

        // ONE write, awaited to completion against the STILL-LIVE peer:
        // proof the handle works, with the request already finished by
        // the time the peer freezes below.
        try await handle.write(ByteBuffer(bytes: Data(repeating: 0x5A, count: 1 << 20)), at: 0)

        try server.freeze()
        // No request is in flight here: the write above already returned.
        // What races the bound below is `closeBounded()` alone.

        // Same reasoning as the read-path sibling: captured straight into
        // the escaping closure now that `BoundedSFTPFile` is `Sendable`,
        // and the close's own answer recorded before the thaw below.
        var closeFinishedInsideItsOwnBound: Bool?
        let startedAt = ContinuousClock.now
        let returned = await BoundedRun.run(boundSeconds: fileCloseBoundSeconds) {
            closeFinishedInsideItsOwnBound = await handle.closeBounded()
        }
        let elapsed = startedAt.duration(to: .now)
        let returnedBeforeThaw = returned
        let innerAnswerBeforeThaw = closeFinishedInsideItsOwnBound

        print("""
            [close-alone] write handle closeBounded against a STILL-frozen \
            peer, no request in flight: returned=\(returnedBeforeThaw) after \
            \(elapsed) (bound \(fileCloseBoundSeconds)s); the close itself \
            answered \(String(describing: innerAnswerBeforeThaw))
            """)

        try? server.thaw()
        // Best-effort, not deferred — same reasoning as the read-path
        // sibling.
        await closeIgnoringErrors(rawClient)

        #expect(returnedBeforeThaw, """
            `BoundedSFTPFile.closeBounded()` (write handle) did not return \
            within \(fileCloseBoundSeconds)s against a peer that is still \
            frozen, with no other request in flight on this handle.
            """)
    }

    /// Demonstrated, not assumed — the standard `ConnectAttemptHandoffTests`
    /// set for any suite on this branch that builds a real `ContentView`.
    /// This suite drives `handleLivenessGiveUp(_:)` with a live connection
    /// attached, the widest path it has; the byte comparison (including "no
    /// file, both times") is what would catch a future `teardown(_:reason:)`
    /// that started writing to a developer's real data.
    @Test func theRealSessionsFileIsNeverTouched() async throws {
        let before = Self.snapshotRealSessionsFile()
        let fixture = makeFixture()
        defer { fixture.cleanup() }
        let fs = try await connectToSSHServer(port: sharedRigPort)
        let home = try await fs.homeDirectoryPath()
        let tab = makeTab()
        attachSession(to: tab, remoteFS: fs, homePath: home)

        await fixture.view.handleLivenessGiveUp(tab)

        #expect(tab.liveness == .lost)
        let after = Self.snapshotRealSessionsFile()
        #expect(before == after, """
            the real on-disk session store changed while this suite ran. \
            `before` had \(before?.count.description ?? "no file"), \
            `after` had \(after?.count.description ?? "no file").
            """)
    }

    // MARK: - One lap of the real probe loop

    /// Mirrors the inner `probing:` loop of `LivenessProbeRunner`, minus its
    /// sleeps: read the interval, ask `LivenessProbePolicy.decide`, act on
    /// the answer with the same three effects the real loop has. The sleeps
    /// are what this cannot reproduce (and what makes the real loop
    /// unrunnable without a rendering harness); the decision and its effects
    /// are exactly what a real drop has to travel through.
    ///
    /// Whether a lap actually probed is not tracked here but counted at the
    /// connection, by `ProbeTargetStatCounter` — see that type for why the
    /// decision is the wrong thing to count.
    @MainActor
    struct ProbeLoop {
        let tab: SessionTab
        let settingsStore: SettingsStore
        let onGiveUp: (SessionTab) async -> Void
        private(set) var consecutiveFailures = 0

        mutating func lap() async -> LivenessProbeAction {
            let interval = settingsStore.keepAliveIntervalSeconds
            let action = LivenessProbePolicy.decide(
                queueIsBusy: tab.transferQueue.isActive,
                consecutiveFailures: consecutiveFailures)
            switch action {
            case .skip:
                consecutiveFailures = 0
                tab.liveness = .connected
            case .probe, .probeAgainNow:
                let timeoutSeconds = LivenessProbePolicy.probeTimeout(forInterval: interval)
                // Through `LivenessProbeStep.perform`, exactly as the real
                // loop reaches the race: the race and the write of its
                // answer live behind that one function now (whole-branch
                // final review, finding I-1), so a mirror that raced and
                // wrote here would be mirroring a loop that no longer
                // exists — and would be probing without the guard the real
                // path has.
                switch await LivenessProbeStep.perform(on: tab, timeoutSeconds: timeoutSeconds) {
                case .alive:
                    consecutiveFailures = 0
                case .failed:
                    consecutiveFailures += 1
                case .abandoned:
                    break
                }
            case .giveUp:
                await onGiveUp(tab)
            }
            return action
        }
    }

    /// Polls rather than awaiting a completion callback: the callback would
    /// fire on the queue's own worker, and this wants the main actor free in
    /// between so the queue can actually make progress.
    private func waitForIdleQueue(_ queue: TransferQueueViewModel) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(60))
        while queue.isActive {
            guard ContinuousClock.now < deadline else {
                Issue.record("the seed download never finished within 60s")
                return
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    // MARK: - Fixtures

    /// Step 1 of the unbounded-file-closes measurement: uploads an 8 MB
    /// fixture file to `fs` at `path` through `fs.write(...)` — the same
    /// call the app itself uses — so
    /// `aReadHandleCloseAgainstAStillFrozenPeerReturnsInsideTheBound` has a
    /// real remote file to read, not a stand-in. Confirmed with `fs.stat`,
    /// not merely assumed from a write that
    /// returned without throwing.
    private func uploadCloseFixtureFile(
        to fs: CitadelFileSystem, path: String, size: Int = 8 << 20
    ) async throws {
        let payload = Data(repeating: 0x5A, count: size)
        let (stream, continuation) = AsyncThrowingStream<Data, Error>.makeStream()
        continuation.yield(payload)
        continuation.finish()
        try await fs.write(path: path, mode: .overwrite, contents: stream)
        let uploaded = try await fs.stat(path: path)
        guard uploaded.size == UInt64(size) else {
            Issue.record("""
                the close-path fixture upload at \(path) reports size \
                \(String(describing: uploaded.size)), not the expected \
                \(size) — the freeze the calling test performs would then \
                be racing a smaller (or absent) file than intended.
                """)
            return
        }
    }

    private static var realSessionsFileURL: URL {
        SessionStore.defaultDirectory.appendingPathComponent("sessions-v2.json")
    }

    /// Read as raw bytes, not parsed — see `ConnectAttemptHandoffTests
    /// .snapshotRealSessionsFile()` for why a byte-for-byte comparison
    /// (including "the file does not exist, in both snapshots") is the right
    /// shape here.
    private static func snapshotRealSessionsFile() -> Data? {
        try? Data(contentsOf: realSessionsFileURL)
    }

    /// A real `ContentView` built the way a window builds one, but with
    /// every store pointed at a temp directory and the secret store replaced
    /// — same seam and same reasoning as `LivenessGiveUpOrderingTests
    /// .makeContentView()`.
    @MainActor
    private struct Fixture {
        let view: ContentView
        let settingsStore: SettingsStore
        let workDirectory: URL
        let temporaryDirectories: [URL]

        func probeLoop(for tab: SessionTab) -> ProbeLoop {
            ProbeLoop(
                tab: tab, settingsStore: settingsStore,
                onGiveUp: { [view] in await view.handleLivenessGiveUp($0) })
        }

        func makeSubdirectory(_ label: String) -> URL {
            let url = workDirectory.appendingPathComponent(label)
            try? FileManager.default.createDirectory(
                at: url, withIntermediateDirectories: true)
            return url
        }

        func cleanup() {
            for directory in temporaryDirectories {
                try? FileManager.default.removeItem(at: directory)
            }
        }
    }

    private func makeTempDirectory(_ label: String) -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-\(label)-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeFixture() -> Fixture {
        let workDirectory = makeTempDirectory("liveness-work")
        let settingsDirectory = makeTempDirectory("liveness-settings")
        let auditDirectory = makeTempDirectory("liveness-audit")
        let settingsStore = SettingsStore(directory: settingsDirectory)
        // The SHORTEST interval the store accepts: `SettingsStore` clamps
        // anything non-zero up to 15, so a smaller number written here would
        // silently read back as this one anyway. It matters because
        // `probeTimeout(forInterval: 15)` is 7 seconds, and the frozen-peer
        // test waits out two of those — the shipped default of 60 would make
        // it a minute-long test for no added evidence.
        settingsStore.keepAliveIntervalSeconds = 15
        let sessionListViewModel = SessionListViewModel(
            store: SessionStore(directory: workDirectory),
            secrets: InertSecretStore(),
            auditStore: AuditLogStore(
                directory: workDirectory.appendingPathComponent("audit")),
            loginSetStore: LoginSetStore(directory: workDirectory),
            keys: ManagedKeyStore(directory: workDirectory))
        let view = ContentView(
            settingsStore: settingsStore,
            bandwidthLimiter: BandwidthLimiter(),
            auditStore: AuditLogStore(directory: auditDirectory),
            tabCommands: TabCommands(),
            updateModel: UpdateCheckModel(),
            menuBarModel: MenuBarStatusModel(),
            sessionListViewModel: sessionListViewModel,
            secretStore: InertSecretStore(),
            managedKeyStore: ManagedKeyStore(directory: workDirectory))
        return Fixture(
            view: view, settingsStore: settingsStore, workDirectory: workDirectory,
            temporaryDirectories: [workDirectory, settingsDirectory, auditDirectory])
    }

    /// Same shape as `LivenessGiveUpOrderingTests.makeTab()`.
    private func makeTab() -> SessionTab {
        SessionTab(
            connectionViewModel: ConnectionViewModel(connector: { _, _ in
                throw CancellationError()
            }),
            certificateBridge: CertificatePromptBridge(),
            limiter: BandwidthLimiter(),
            maxConcurrent: 2)
    }

    /// Same shape as `LivenessGiveUpOrderingTests.attachSession(to:)`, except
    /// that `remoteFS` is a live SSH connection rather than a stand-in — the
    /// whole difference this suite exists to make. The connection is handed
    /// to the session through `ProbeTargetStatCounter`, so every test in this
    /// suite probes through the same instrument whether it reads the count or
    /// not.
    /// `shellOpener` defaults to the throwing stand-in every test in this
    /// suite used before the shell measurement existed, so no existing call
    /// site changes. See `teardownWithAnOpenShellAgainstAStillFrozenPeerTerminates`
    /// for why the default is a deliberate choice rather than a gap, and
    /// what passing a real opener buys.
    @discardableResult
    private func attachSession(
        to tab: SessionTab, remoteFS: any RemoteFileSystem, homePath: String,
        shellOpener: @escaping TerminalPanelViewModel.ShellOpener = { _, _, _ in
            throw CancellationError()
        }
    ) -> ProbeTargetStatCounter {
        let sessionID = UUID()
        let counted = ProbeTargetStatCounter(
            wrapping: remoteFS, countingStatsOf: homePath)
        tab.session = BrowserSession(
            id: sessionID,
            localFS: LocalFileSystem(),
            remoteFS: counted,
            local: RemoteBrowserViewModel(
                fs: LocalFileSystem(), startPath: NSTemporaryDirectory()),
            remote: RemoteBrowserViewModel(fs: counted, startPath: homePath),
            terminal: TerminalPanelViewModel(openShell: shellOpener),
            editManager: EditSessionManager(sessionID: sessionID, queue: tab.transferQueue),
            homePath: homePath)
        tab.liveness = .connected
        return counted
    }
}
