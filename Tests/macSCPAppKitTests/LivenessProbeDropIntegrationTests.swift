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
private let seedFilePath = "/data/seed/hello.txt"
private let seedFileName = "hello.txt"

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
            knownHosts: knownHosts, onUnknownHostKey: { _ in true })
    }
    do {
        return try await attempt()
    } catch {
        try? await Task.sleep(for: .milliseconds(500))
        return try await attempt()
    }
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

    static func run(_ arguments: [String]) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: try executablePath())
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        // Drained BEFORE waiting: a command that writes more than the pipe
        // buffer holds would otherwise block forever on a full pipe while
        // this side waits for it to exit.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
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
                "docker run", status: started.status, output: started.output)
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
                "docker stop", status: stopped.status, output: stopped.output)
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
                "docker pause", status: paused.status, output: paused.output)
        }
    }

    func thaw() throws {
        let unpaused = try Docker.run(["unpause", name])
        guard unpaused.status == 0 else {
            throw DockerError.commandFailed(
                "docker unpause", status: unpaused.status, output: unpaused.output)
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

    private static func leftoverIDs() throws -> [String] {
        let listed = try Docker.run(["ps", "-aq", "--filter", "name=\(namePrefix)"])
        guard listed.status == 0 else {
            throw DockerError.commandFailed(
                "docker ps", status: listed.status, output: listed.output)
        }
        return listed.output.split(whereSeparator: \.isNewline).map(String.init)
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
/// .decide`, `.giveUp` delegating to `onGiveUp`), so the mirror cannot
/// quietly describe a loop that no longer exists.
///
/// Isolation, to the standard `ConnectAttemptHandoffTests` set for this
/// branch: every store handed to `ContentView` is a temp directory or an
/// in-memory double, and `theRealSessionsFileIsNeverTouched` demonstrates
/// that rather than assuming it.
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
                guard let session = tab.session else { break }
                let timeoutSeconds = LivenessProbePolicy.probeTimeout(forInterval: interval)
                let alive = await LivenessProbeRace.run(timeoutSeconds: timeoutSeconds) {
                    (try? await session.remoteFS.stat(path: session.homePath)) != nil
                }
                if alive {
                    consecutiveFailures = 0
                    tab.liveness = .connected
                } else {
                    consecutiveFailures += 1
                    tab.liveness = .degraded
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
            sessionListViewModel: sessionListViewModel)
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
    @discardableResult
    private func attachSession(
        to tab: SessionTab, remoteFS: any RemoteFileSystem, homePath: String
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
            terminal: TerminalPanelViewModel(openShell: { _, _, _ in
                throw CancellationError()
            }),
            editManager: EditSessionManager(sessionID: sessionID, queue: tab.transferQueue),
            homePath: homePath)
        tab.liveness = .connected
        return counted
    }
}
