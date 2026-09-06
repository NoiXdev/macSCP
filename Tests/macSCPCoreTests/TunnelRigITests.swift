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
        let carrierHosts = throwawayDirectory("carrier")
        let tunnelledHosts = throwawayDirectory("tunnelled")
        defer {
            try? FileManager.default.removeItem(at: carrierHosts)
            try? FileManager.default.removeItem(at: tunnelledHosts)
        }

        let session = sshSession(
            name: "rig", host: "127.0.0.1", port: 2222, username: "testuser", authKind: .password)
        let carrier = try await connectWithRetry {
            try await TunnelConnection.connect(
                session: session, secrets: [RigSecret()],
                knownHosts: KnownHostsStore(directory: carrierHosts),
                decider: .asking { _ in true })
        }

        let listener = LocalForwardListener()
        let seen = RigEventRecorder()
        do {
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
            // The tunnelled connection is disconnected on EVERY exit from
            // here, including a failing expectation below: without this, a
            // red test leaves an SFTP session open on the rig.
            defer { Task { await throughTheTunnel.disconnect() } }

            let items = try await throughTheTunnel.list(path: "/data/seed")
            #expect(items.map(\.name).contains("hello.txt"))
            #expect(seen.events.contains(.opened))
        } catch {
            await listener.stop()
            await carrier.disconnect()
            throw error
        }
        await listener.stop()
        await carrier.disconnect()

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
        let carrierHosts = throwawayDirectory("bulk-carrier")
        let writerHosts = throwawayDirectory("bulk-writer")
        let readerHosts = throwawayDirectory("bulk-reader")
        defer {
            for directory in [carrierHosts, writerHosts, readerHosts] {
                try? FileManager.default.removeItem(at: directory)
            }
        }

        let session = sshSession(
            name: "rig", host: "127.0.0.1", port: 2222, username: "testuser", authKind: .password)
        let carrier = try await connectWithRetry {
            try await TunnelConnection.connect(
                session: session, secrets: [RigSecret()],
                knownHosts: KnownHostsStore(directory: carrierHosts),
                decider: .asking { _ in true })
        }

        let listener = LocalForwardListener()
        do {
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
            defer { Task { await writer.disconnect() } }
            let (stream, continuation) = AsyncThrowingStream<Data, Error>.makeStream()
            continuation.yield(payload)
            continuation.finish()
            try await writer.write(path: remotePath, contents: stream)

            let reader = try await connectWithRetry {
                try await tunnelledConnection(port: port, knownHosts: readerHosts)
            }
            defer { Task { await reader.disconnect() } }
            var readBack = Data()
            for try await chunk in try await reader.readStream(path: remotePath) {
                readBack.append(chunk)
            }
            #expect(readBack.count == payload.count)
            #expect(readBack == payload)

            try await reader.delete(path: remotePath)
        } catch {
            await listener.stop()
            await carrier.disconnect()
            throw error
        }
        await listener.stop()
        await carrier.disconnect()
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
        let carrierHosts = throwawayDirectory("socks-carrier")
        defer { try? FileManager.default.removeItem(at: carrierHosts) }

        let session = sshSession(
            name: "rig", host: "127.0.0.1", port: 2222, username: "testuser", authKind: .password)
        let carrier = try await connectWithRetry {
            try await TunnelConnection.connect(
                session: session, secrets: [RigSecret()],
                knownHosts: KnownHostsStore(directory: carrierHosts),
                decider: .asking { _ in true })
        }

        let listener = SOCKS5Listener()
        let seen = RigEventRecorder()
        do {
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

            try await awaitCancellably(client.writeAndFlush(ByteBuffer(bytes: [0x05, 0x01, 0x00])))
            try await pollUntil("the SOCKS5 method selection") { inbox.bytes.count >= 2 }
            #expect(Array(inbox.bytes.prefix(2)) == [0x05, 0x00])

            // `05 01 00 01 7f 00 00 01 08 ae` — CONNECT 127.0.0.1:2222.
            try await awaitCancellably(
                client.writeAndFlush(
                    ByteBuffer(bytes: [0x05, 0x01, 0x00, 0x01, 127, 0, 0, 1, 0x08, 0xAE])))
            try await pollUntil("the SOCKS5 success reply") { inbox.bytes.count >= 12 }
            #expect(Array(inbox.bytes[2..<4]) == [0x05, 0x00])

            try await pollUntil("the SSH banner through the dynamic forward") {
                inbox.bytes.count >= 12 + 7
            }
            let banner = String(decoding: inbox.bytes[12..<19], as: UTF8.self)
            #expect(banner == "SSH-2.0")
            #expect(seen.events.contains(.opened))

            client.close(promise: nil)
            try await awaitCancellably(client.closeFuture)
        } catch {
            await listener.stop()
            await carrier.disconnect()
            throw error
        }
        await listener.stop()
        await carrier.disconnect()
    }
}

// MARK: - Helpers

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

private final class RigByteCollector: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    private let inbox: RigByteInbox

    init(inbox: RigByteInbox) { self.inbox = inbox }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        inbox.append(buffer.readBytes(length: buffer.readableBytes) ?? [])
    }
}
