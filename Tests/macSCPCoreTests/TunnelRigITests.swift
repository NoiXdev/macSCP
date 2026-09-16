import Foundation
import MacSCPTestSupport
import NIOCore
import NIOPosix
import Testing

@testable import macSCPCore

/// End to end, against the Docker rig
/// (`docker compose -f docker/test-server/compose.yml up -d`): a tunnel's own
/// SSH connection is built from a STORED session the way the app will build
/// it, a local forward is bound on an ephemeral loopback port, and a SECOND,
/// completely independent SFTP connection is dialled THROUGH that port and
/// lists a directory.
///
/// The forward's target is `127.0.0.1:2222` **as the server sees it** — the
/// container's sshd listens on 2222 internally (`docker/test-server/
/// compose.yml` maps `"2222:2222"`, and the jump-host tests in
/// `CitadelFileSystemIntegrationTests` reach the second container on its
/// internal 2222 the same way). The rig's `sshd_config.d` sets
/// `AllowTcpForwarding yes`, without which the `direct-tcpip` channel is
/// refused before any of this can be measured.
@Suite(
    "Tunnels against the Docker SSH server",
    .enabled(if: ProcessInfo.processInfo.environment["MACSCP_ITEST"] == "1"),
    .serialized,
    .timeLimit(.minutes(5))
)
struct TunnelRigITests {

    @Test func aLocalForwardCarriesASecondSFTPConnection() async throws {
        let seen = RigEventRecorder()
        try await withRigTeardown { teardown in
            let carrierHosts = throwawayDirectory("carrier")
            let tunnelledHosts = throwawayDirectory("tunnelled")
            teardown.add {
                try? FileManager.default.removeItem(at: carrierHosts)
                try? FileManager.default.removeItem(at: tunnelledHosts)
            }

            let session = sshSession(
                name: "rig", host: "127.0.0.1", port: 2222, username: "testuser",
                authKind: .password)
            let carrier = try await connectWithRetry {
                try await TunnelConnection.connect(
                    session: session, secrets: [RigSecret()],
                    knownHosts: KnownHostsStore(directory: carrierHosts),
                    decider: .asking { _ in true })
            }
            teardown.add { await carrier.disconnect() }

            let listener = LocalForwardListener()
            teardown.add { await listener.stop() }
            let port = try await listener.start(
                bind: "127.0.0.1", localPort: 0, host: "127.0.0.1", remotePort: 2222,
                directTCPIPFactory: { host, port in
                    try await carrier.openDirectTCPIP(host: host, port: port)
                },
                observer: { seen.record($0) })
            #expect(port > 0)

            let throughTheTunnel = try await connectWithRetry {
                try await CitadelFileSystem.connect(
                    config: try SSHConnectionConfig(
                        host: "127.0.0.1", port: port, username: "testuser",
                        auth: .password("testpass")),
                    connectTimeout: .seconds(30),
                    knownHosts: KnownHostsStore(directory: tunnelledHosts),
                    onUnknownHostKey: .asking { _ in true })
            }
            teardown.add { await throughTheTunnel.disconnect() }

            let items = try await throughTheTunnel.list(path: "/data/seed")
            #expect(items.map(\.name).contains("hello.txt"))
            #expect(seen.events.contains(.opened))
        }

        // Read AFTER the teardown on purpose: `closed` is reported when both
        // channels of a pair are gone, which is what stopping the listener
        // and disconnecting does.
        let closed = seen.events.contains { event in
            if case .closed = event { return true }
            return false
        }
        #expect(closed)
    }

    /// Bulk, past the 64 KiB high-water mark: half a megabyte written
    /// through the tunnel and read back through a SECOND connection over the
    /// same forward, byte for byte.
    ///
    /// This is the case the backpressure resume exists for. When the local
    /// socket's pending writes cross `ChannelOptions.writeBufferWaterMark`'s
    /// 64 KiB default the pump throttles the SSH child channel, and until
    /// fix round 1 it turned `autoRead` back on WITHOUT a `read()` — which
    /// an `SSHChildChannel` ignores, so server→local never resumed.
    ///
    /// Honest about what this measures, because it was measured: with the
    /// `read()` removed again this test still passed, in 0.244 s. It is NOT
    /// a detector for that defect, and the reason is structural rather than
    /// a matter of payload size — SFTP is request/response, so the tunnelled
    /// client's own flow control keeps the accepted socket's PENDING writes
    /// far below the 64 KiB high-water mark and the throttle never engages.
    /// A test that would engage it needs a far side that pushes unsolicited
    /// bulk, which nothing in this rig does. The deterministic pin is
    /// `BytePumpTests.anUnwritablePeerStopsTheOtherSideFromReading`, which
    /// drives the writability change by hand.
    ///
    /// What this test does prove, on every run, is that a transfer far
    /// larger than any single window or socket buffer survives the pump
    /// intact, over two separate connections through one forward.
    ///
    /// `/config` is the writable home of `testuser` in the linuxserver
    /// image — the same path `CitadelFileSystemIntegrationTests
    /// .writeUploadsAndReadsBackRoundtrip` uses — and the file is deleted
    /// again, through the tunnel, before the test returns.
    @Test func aLocalForwardCarriesABulkTransferPastTheHighWaterMark() async throws {
        try await withRigTeardown { teardown in
            let carrierHosts = throwawayDirectory("bulk-carrier")
            let writerHosts = throwawayDirectory("bulk-writer")
            let readerHosts = throwawayDirectory("bulk-reader")
            teardown.add {
                for directory in [carrierHosts, writerHosts, readerHosts] {
                    try? FileManager.default.removeItem(at: directory)
                }
            }

            let session = sshSession(
                name: "rig", host: "127.0.0.1", port: 2222, username: "testuser",
                authKind: .password)
            let carrier = try await connectWithRetry {
                try await TunnelConnection.connect(
                    session: session, secrets: [RigSecret()],
                    knownHosts: KnownHostsStore(directory: carrierHosts),
                    decider: .asking { _ in true })
            }
            teardown.add { await carrier.disconnect() }

            let listener = LocalForwardListener()
            teardown.add { await listener.stop() }
            let port = try await listener.start(
                bind: "127.0.0.1", localPort: 0, host: "127.0.0.1", remotePort: 2222,
                directTCPIPFactory: { host, port in
                    try await carrier.openDirectTCPIP(host: host, port: port)
                })

            // 512 KiB — eight times the high-water mark, and unmistakably
            // more than one SSH channel window.
            let payload = Data((0..<(512 * 1024)).map { UInt8($0 % 251) })
            let remotePath = "/config/macscp-tunnel-bulk-\(UUID().uuidString).bin"

            let writer = try await connectWithRetry {
                try await tunnelledConnection(port: port, knownHosts: writerHosts)
            }
            teardown.add { await writer.disconnect() }
            let (stream, continuation) = AsyncThrowingStream<Data, Error>.makeStream()
            continuation.yield(payload)
            continuation.finish()
            try await writer.write(path: remotePath, contents: stream)

            let reader = try await connectWithRetry {
                try await tunnelledConnection(port: port, knownHosts: readerHosts)
            }
            teardown.add { await reader.disconnect() }
            var readBack = Data()
            for try await chunk in try await reader.readStream(path: remotePath) {
                readBack.append(chunk)
            }
            #expect(readBack.count == payload.count)
            #expect(readBack == payload)

            // Registered as well as called: a failing expectation above skips
            // this line, and the rig must not keep half a megabyte per red
            // run. Deleting twice is harmless — the second `try?` finds it
            // gone.
            teardown.add { try? await reader.delete(path: remotePath) }
            try await reader.delete(path: remotePath)
        }
    }

    /// A dynamic forward (`-D`): a hand-written SOCKS5 client asks the
    /// listener to CONNECT to the rig's own sshd — `127.0.0.1:2222` as the
    /// SERVER sees it, the same target the local forward above uses — and
    /// then reads the SSH banner that comes back through the pump. The
    /// banner is the proof that the bytes are the far side's own and not the
    /// listener's: nothing in this process writes `SSH-2.0`.
    ///
    /// The payload is deliberately tiny (a banner is a few dozen bytes).
    /// Task 3 wrote here that a transfer large enough to make the local
    /// socket unwritable would stall, because `BytePump`'s backpressure
    /// resume turned `autoRead` back on without an explicit `read()`. That
    /// defect is fixed (Task 2, fix round 1); the bulk case is measured by
    /// `aLocalForwardCarriesABulkTransferPastTheHighWaterMark` below rather
    /// than here, because this test's subject is the SOCKS5 conversation.
    @Test func aDynamicForwardCarriesASOCKS5Connect() async throws {
        try await withRigTeardown { teardown in
            let carrierHosts = throwawayDirectory("socks-carrier")
            teardown.add { try? FileManager.default.removeItem(at: carrierHosts) }

            let session = sshSession(
                name: "rig", host: "127.0.0.1", port: 2222, username: "testuser",
                authKind: .password)
            let carrier = try await connectWithRetry {
                try await TunnelConnection.connect(
                    session: session, secrets: [RigSecret()],
                    knownHosts: KnownHostsStore(directory: carrierHosts),
                    decider: .asking { _ in true })
            }
            teardown.add { await carrier.disconnect() }

            let listener = SOCKS5Listener()
            teardown.add { await listener.stop() }
            let seen = RigEventRecorder()
            let port = try await listener.start(
                bind: "127.0.0.1", localPort: 0,
                directTCPIPFactory: { host, port in
                    try await carrier.openDirectTCPIP(host: host, port: port)
                },
                observer: { seen.record($0) })
            #expect(port > 0)

            let inbox = RigByteInbox()
            let client = try await awaitCancellably(
                ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
                    .channelInitializer { channel in
                        channel.pipeline.addHandler(RigByteCollector(inbox: inbox))
                    }
                    .connect(host: "127.0.0.1", port: port))
            teardown.add {
                client.close(promise: nil)
                try? await awaitCancellably(client.closeFuture)
            }

            try await awaitCancellably(client.writeAndFlush(ByteBuffer(bytes: [0x05, 0x01, 0x00])))
            try await pollUntil("the SOCKS5 method selection") { inbox.bytes.count >= 2 }
            #expect(Array(inbox.bytes.prefix(2)) == [0x05, 0x00])

            // `05 01 00 01 7f 00 00 01 08 ae` — CONNECT 127.0.0.1:2222.
            try await awaitCancellably(
                client.writeAndFlush(
                    ByteBuffer(bytes: [0x05, 0x01, 0x00, 0x01, 127, 0, 0, 1, 0x08, 0xAE])))
            try await pollUntil("the SOCKS5 success reply") { inbox.bytes.count >= 12 }
            // sshd greets first, so these four bytes are the ordering this
            // round's gate exists for: before it, the banner could arrive
            // here instead, and this assertion passed by winning a race.
            #expect(Array(inbox.bytes[2..<4]) == [0x05, 0x00])

            try await pollUntil("the SSH banner through the dynamic forward") {
                inbox.bytes.count >= 12 + 7
            }
            let banner = String(decoding: inbox.bytes[12..<19], as: UTF8.self)
            #expect(banner == "SSH-2.0")
            #expect(seen.events.contains(.opened))
        }
    }

    /// A remote forward (`-R`) driven from INSIDE the container: the rig's
    /// sshd is asked to listen on `127.0.0.1:45321`, it confirms the port
    /// through `onOpen`, and `docker exec` then opens a connection to that
    /// port in the container's own network namespace. The bytes arrive on a
    /// loopback listener this test owns, on this Mac.
    ///
    /// **The port is named rather than left to the server**, which the brief
    /// asked for the other way round, and the reason is measured rather than
    /// preferred: `port: 0` binds on the server, reports its port through
    /// `onOpen`, and then delivers nothing at all — the pinned Citadel keys
    /// its inbound handler on the REQUESTED `(host, port)` and looks it up
    /// under the BOUND one. The first run of this test with `remotePort: 0`
    /// failed with `(sent.stdoutText → "") == "ho"` and then ran into the
    /// suite's five-minute limit waiting for bytes that could not come;
    /// changing only that number to a named port made it pass in 0.104 s.
    /// `CitadelFileSystem.withRemotePortForward` now refuses port 0 outright,
    /// with the line numbers of the mismatch, and
    /// `aRemoteForwardOnPortZeroIsRefused` below pins that refusal.
    ///
    /// The number is drawn at RANDOM from 40000–60000 rather than fixed. A
    /// fixed one is a shared resource inside the container, and two rig runs
    /// on one machine — two checkouts, or a rerun overlapping its
    /// predecessor's teardown — would collide on it and fail with a
    /// `remoteBindRefused` that says nothing about this code. One retry covers a
    /// collision; a second failure is reported rather than papered over,
    /// because two collisions in a row is evidence of something other than
    /// bad luck. A fresh `RemoteForward` per attempt, since one forward
    /// starts once.
    ///
    /// `127.0.0.1` deliberately: `GatewayPorts` is off in the rig (nothing
    /// sets it, and OpenSSH's default is `no`), so a `0.0.0.0` bind would be
    /// silently narrowed to loopback anyway. `AllowTcpForwarding yes` in
    /// `docker/test-server/sshd_config.d/99-macscp-testrig.conf` covers this
    /// direction as well as the `direct-tcpip` one — `yes` allows both, and
    /// the file needed no change for this test.
    ///
    /// The client inside the container is OpenBSD `nc`, which
    /// `lscr.io/linuxserver/openssh-server:10.3_p1-r0-ls230` ships at
    /// `/usr/bin/nc` (checked on the running rig, 2026-09-06; `/bin/bash` is
    /// there too, so the `/dev/tcp` fallback was available and not needed).
    /// It exits on its own because the local target answers and then closes,
    /// which the pump carries back through the SSH channel — so this waits
    /// for a process to end rather than for a clock.
    ///
    /// Both directions are asserted: `hi` reaching the listener proves the
    /// server→Mac leg, and `ho` in `nc`'s standard output proves the Mac→
    /// server leg. Nothing inside the container writes `ho`.
    @Test func aRemoteForwardCarriesAConnectionFromInsideTheContainer() async throws {
        try await withRigTeardown { teardown in
            let carrierHosts = throwawayDirectory("remote-carrier")
            teardown.add { try? FileManager.default.removeItem(at: carrierHosts) }

            let session = sshSession(
                name: "rig", host: "127.0.0.1", port: 2222, username: "testuser",
                authKind: .password)
            let carrier = try await connectWithRetry {
                try await TunnelConnection.connect(
                    session: session, secrets: [RigSecret()],
                    knownHosts: KnownHostsStore(directory: carrierHosts),
                    decider: .asking { _ in true })
            }
            teardown.add { await carrier.disconnect() }

            let inbox = RigByteInbox()
            let target = try await awaitCancellably(
                ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
                    .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                    .childChannelInitializer { channel in
                        channel.pipeline.addHandler(RigAnswerAndClose(inbox: inbox, answer: "ho"))
                    }
                    .bind(host: "127.0.0.1", port: 0))
            teardown.add {
                target.close(promise: nil)
                try? await awaitCancellably(target.closeFuture)
            }
            let targetPort = target.localAddress?.port ?? 0
            #expect(targetPort > 0)

            let seen = RigEventRecorder()
            let (forward, boundPort) = try await forwardOnAFreeRemotePort(
                carrier: carrier, targetPort: targetPort, observer: { seen.record($0) })
            teardown.add { await forward.stop() }
            #expect(boundPort > 0)

            let sent = try await SubprocessRunner.run(
                URL(fileURLWithPath: "/usr/bin/env"),
                arguments: [
                    "docker", "exec", "macscp-test-sshd", "sh", "-c",
                    "printf hi | nc 127.0.0.1 \(boundPort)",
                ],
                timeout: .seconds(60))
            #expect(sent.status == 0)
            #expect(sent.stdoutText == "ho")

            try await pollUntil("the bytes to arrive from inside the container") {
                String(decoding: inbox.bytes, as: UTF8.self) == "hi"
            }
            #expect(seen.events.contains(.opened))
        }
    }

    /// Port 0 — "let the server choose" — is refused before anything is sent
    /// to the server, and the reason says what the caller has to do instead.
    ///
    /// **This test cannot announce the fix, and does not claim to.** It pins
    /// OUR guard, not Citadel's behaviour: it would stay green against a
    /// fixed Citadel, because the guard would still refuse before anything
    /// reached the library. It must be REMOVED together with the guard —
    /// both are one change, recorded as a debt in
    /// `docs/superpowers/specs/2026-08-20-backlog-dependencies.md` with what
    /// the fork would have to do. The measurement that put the guard there
    /// is in `CitadelFileSystem.withRemotePortForward`'s doc comment and in
    /// the case above.
    ///
    /// It runs against the rig rather than in the unit suite because the
    /// accessor it measures belongs to a connected `CitadelFileSystem`, and
    /// there is no such thing without a server.
    @Test func aRemoteForwardOnPortZeroIsRefused() async throws {
        try await withRigTeardown { teardown in
            let carrierHosts = throwawayDirectory("remote-zero")
            teardown.add { try? FileManager.default.removeItem(at: carrierHosts) }

            let session = sshSession(
                name: "rig", host: "127.0.0.1", port: 2222, username: "testuser",
                authKind: .password)
            let carrier = try await connectWithRetry {
                try await TunnelConnection.connect(
                    session: session, secrets: [RigSecret()],
                    knownHosts: KnownHostsStore(directory: carrierHosts),
                    decider: .asking { _ in true })
            }
            teardown.add { await carrier.disconnect() }

            let raised: (any Error)?
            do {
                try await carrier.withRemotePortForward(
                    bind: "127.0.0.1", port: 0, onOpen: { _ in }, handleChannel: { _ in })
                raised = nil
            } catch {
                raised = error
            }

            #expect(raised as? TunnelFailure == .remotePortZeroRefused)
        }
    }

    /// `TunnelRunner` end to end, with the LIVE runtime factory: the runner
    /// dials the rig for itself, binds an ephemeral local forward, reports
    /// `active`, carries a second, independent SFTP connection through that
    /// port, and gives everything back on `stop()`.
    ///
    /// The unit suite (`TunnelRunnerTests`) drives the same lifecycle
    /// against doubles; what only the rig can prove is that
    /// `LiveTunnelRuntimeFactory` wires the real `LocalForwardListener` to
    /// the real connection's `openDirectTCPIP` — a mis-wiring there is
    /// invisible to every fake.
    ///
    /// `localPort: 0` so nothing on this machine is claimed twice; the
    /// runner's `boundPort` is the answer, read from the runtime through the
    /// state stream's `active` rather than guessed.
    @Test func theRunnerCarriesALocalForwardEndToEnd() async throws {
        try await withRigTeardown { teardown in
            let carrierHosts = throwawayDirectory("runner-carrier")
            let tunnelledHosts = throwawayDirectory("runner-tunnelled")
            teardown.add {
                try? FileManager.default.removeItem(at: carrierHosts)
                try? FileManager.default.removeItem(at: tunnelledHosts)
            }

            let session = sshSession(
                name: "rig", host: "127.0.0.1", port: 2222, username: "testuser",
                authKind: .password)
            let profile = TunnelProfile(
                sessionID: session.id, name: "rig-runner",
                kind: .local(
                    bind: "127.0.0.1", localPort: 0, host: "127.0.0.1", remotePort: 2222))
            let runner = TunnelRunner(
                profile: profile,
                connect: { decider in
                    try await TunnelConnection.connect(
                        session: session, secrets: [RigSecret()],
                        knownHosts: KnownHostsStore(directory: carrierHosts), decider: decider)
                })
            let states = TunnelStateCollector(runner.states)
            teardown.add { await runner.stop() }

            await runner.start(decider: .asking { _ in true })
            try await states.waitFor(.active(connections: 0))

            let port = try #require(await runner.boundPort)
            #expect(port > 0)
            let throughTheTunnel = try await connectWithRetry {
                try await tunnelledConnection(port: port, knownHosts: tunnelledHosts)
            }
            teardown.add { await throughTheTunnel.disconnect() }
            let items = try await throughTheTunnel.list(path: "/data/seed")
            #expect(items.map(\.name).contains("hello.txt"))

            await runner.stop()
            #expect(await runner.state == .stopped)
        }
    }

    /// A `-L` whose target has nothing listening, as the SERVER sees it: sshd
    /// refuses the `direct-tcpip` channel, the client's connection is
    /// closed, and the tunnel stays `active` with that connection counted.
    /// Then a listener is started at the same port inside the container,
    /// and the next connection through the tunnel opens and resets the
    /// count — the same forward, not a new one.
    ///
    /// The port is drawn at random from 40000–60000, for the reason
    /// `aRemoteForwardCarriesAConnectionFromInsideTheContainer` gives about
    /// shared ports inside the container. OpenBSD `nc -lk` keeps listening
    /// across connections, so the probe that waits for it to be up does not
    /// use the one accept the tunnel needs; `-d` detaches it and the
    /// teardown kills it by its full command line. Every wait is on a
    /// process ending or a published state, never a clock.
    @Test func aFailedConnectionIsCountedWhileTheForwardStaysUp() async throws {
        try await withRigTeardown { teardown in
            let carrierHosts = throwawayDirectory("failure-carrier")
            teardown.add { try? FileManager.default.removeItem(at: carrierHosts) }

            let targetPort = Int.random(in: 40_000...60_000)
            let session = sshSession(
                name: "rig", host: "127.0.0.1", port: 2222, username: "testuser",
                authKind: .password)
            let profile = TunnelProfile(
                sessionID: session.id, name: "rig-failures",
                kind: .local(
                    bind: "127.0.0.1", localPort: 0, host: "127.0.0.1", remotePort: targetPort))
            let runner = TunnelRunner(
                profile: profile,
                connect: { decider in
                    try await TunnelConnection.connect(
                        session: session, secrets: [RigSecret()],
                        knownHosts: KnownHostsStore(directory: carrierHosts), decider: decider)
                })
            let states = TunnelStateCollector(runner.states)
            teardown.add { await runner.stop() }

            await runner.start(decider: .asking { _ in true })
            try await states.waitFor(.active(connections: 0))
            let port = try #require(await runner.boundPort)

            let refused = try await awaitCancellably(
                ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
                    .connect(host: "127.0.0.1", port: port))
            try await awaitCancellably(refused.closeFuture)
            try await states.waitFor("one failed connection") { state in
                guard case .active(0, 1, .some) = state else { return false }
                return true
            }
            let counted = await runner.state
            guard case .active(_, 1, let kind) = counted else {
                Issue.record("the tunnel left active: \(counted)")
                return
            }
            #expect(kind == .channelOpenFailed)

            let listen = "nc -lk 127.0.0.1 \(targetPort)"
            let started = try await SubprocessRunner.run(
                URL(fileURLWithPath: "/usr/bin/env"),
                arguments: ["docker", "exec", "-d", "macscp-test-sshd", "sh", "-c", listen],
                timeout: .seconds(60))
            #expect(started.status == 0)
            teardown.add {
                _ = try? await SubprocessRunner.run(
                    URL(fileURLWithPath: "/usr/bin/env"),
                    arguments: ["docker", "exec", "macscp-test-sshd", "pkill", "-f", listen],
                    timeout: .seconds(60))
            }
            try await pollUntil("the listener inside the container is up") {
                let probe = try? await SubprocessRunner.run(
                    URL(fileURLWithPath: "/usr/bin/env"),
                    arguments: [
                        "docker", "exec", "macscp-test-sshd", "nc", "-z", "127.0.0.1",
                        String(targetPort),
                    ],
                    timeout: .seconds(60))
                return probe?.status == 0
            }

            let carried = try await awaitCancellably(
                ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
                    .connect(host: "127.0.0.1", port: port))
            teardown.add {
                carried.close(promise: nil)
                try? await awaitCancellably(carried.closeFuture)
            }
            try await states.waitFor(.active(connections: 1))
            #expect(await runner.state == .active(connections: 1, failedConnections: 0, lastFailure: nil))
        }
    }
}

// MARK: - Helpers
/// Runs `body` and then every registered clean-up, in reverse, on EVERY exit
/// — including a thrown expectation.
///
/// Swift has no `async defer`, and the shape this replaces —
/// `defer { Task { await …} }` — is fire-and-forget: the test returns, the
/// rig connection is disconnected some time later or not at all, and a
/// failing expectation leaves an SFTP session and a remote listener behind on
/// the container. Registering into a list that one `await` drains keeps the
/// "clean up next to where you allocated" reading of a `defer` while actually
/// waiting for each step.
///
/// Reverse order because the resources nest: the forward is stopped before
/// the connection carrying it is disconnected.
private func withRigTeardown(
    _ body: (RigTeardown) async throws -> Void
) async throws {
    let teardown = RigTeardown()
    do {
        try await body(teardown)
    } catch {
        await teardown.run()
        throw error
    }
    await teardown.run()
}

/// The clean-up list `withRigTeardown` drains. Not `Sendable` and not meant
/// to be: it is only ever touched from the test's own task.
private final class RigTeardown {
    private var steps: [() async -> Void] = []

    func add(_ step: @escaping () async -> Void) {
        steps.append(step)
    }

    /// Drains the list, so a second call is a no-op rather than a second
    /// teardown.
    func run() async {
        let taken = steps
        steps = []
        for step in taken.reversed() {
            await step()
        }
    }
}

/// Starts a remote forward on a random port in 40000–60000, with one retry if
/// the server refuses the bind.
///
/// A fresh `RemoteForward` per attempt: one forward starts once, and `start`
/// consumes that use even when it fails. A second `remoteBindRefused` is thrown
/// rather than retried — see the calling test's doc comment.
private func forwardOnAFreeRemotePort(
    carrier: CitadelFileSystem, targetPort: Int,
    observer: @escaping TunnelConnectionObserver
) async throws -> (RemoteForward, Int) {
    var lastFailure: (any Error)?
    for _ in 1...2 {
        let forward = RemoteForward(transport: carrier)
        do {
            let port = try await forward.start(
                bind: "127.0.0.1", remotePort: Int.random(in: 40_000...60_000),
                localHost: "127.0.0.1", localPort: targetPort,
                observer: observer)
            return (forward, port)
        } catch let failure as TunnelFailure {
            guard case .remoteBindRefused = failure else { throw failure }
            lastFailure = failure
        }
    }
    throw lastFailure ?? TunnelFailure.bindFailed(reason: "no remote port could be bound")
}


/// The rig's password, as a `SecretSource` — the same seam the app's Keychain
/// source plugs into, so `TunnelConnection.connect` is exercised through its
/// real resolution path rather than around it.
private struct RigSecret: SecretSource {
    let label = "rig"

    func secret(for sessionID: UUID) throws -> String? { "testpass" }
}

/// One SFTP connection dialled THROUGH the forward on `port`. A fresh
/// known-hosts directory per caller, so each dial is its own first contact
/// and no test depends on another's pinning.
private func tunnelledConnection(port: Int, knownHosts: URL) async throws -> CitadelFileSystem {
    try await CitadelFileSystem.connect(
        config: try SSHConnectionConfig(
            host: "127.0.0.1", port: port, username: "testuser", auth: .password("testpass")),
        connectTimeout: .seconds(30),
        knownHosts: KnownHostsStore(directory: knownHosts),
        onUnknownHostKey: .asking { _ in true })
}

private func throwawayDirectory(_ role: String) -> URL {
    URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("macscp-kh-tunnel-\(role)-\(UUID().uuidString)")
}

private final class RigEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [TunnelConnectionEvent] = []

    var events: [TunnelConnectionEvent] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func record(_ event: TunnelConnectionEvent) {
        lock.lock()
        recorded.append(event)
        lock.unlock()
    }
}

private final class RigByteInbox: @unchecked Sendable {
    private let lock = NSLock()
    private var collected: [UInt8] = []

    var bytes: [UInt8] {
        lock.lock()
        defer { lock.unlock() }
        return collected
    }

    func append(_ chunk: [UInt8]) {
        lock.lock()
        collected += chunk
        lock.unlock()
    }
}

/// The local target of the remote-forward case: it records what arrives,
/// answers once, and closes. Closing is what lets `nc` inside the container
/// exit on its own — the pump carries the close back through the SSH channel
/// — so the test waits for a process to end rather than for a timeout.
private final class RigAnswerAndClose: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private let inbox: RigByteInbox
    private let answer: String
    private var answered = false

    init(inbox: RigByteInbox, answer: String) {
        self.inbox = inbox
        self.answer = answer
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        inbox.append(buffer.readBytes(length: buffer.readableBytes) ?? [])
        guard !answered else { return }
        answered = true
        context.writeAndFlush(wrapOutboundOut(ByteBuffer(string: answer)), promise: nil)
        context.close(promise: nil)
    }
}

private final class RigByteCollector: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    private let inbox: RigByteInbox

    init(inbox: RigByteInbox) { self.inbox = inbox }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        inbox.append(buffer.readBytes(length: buffer.readableBytes) ?? [])
    }
}
