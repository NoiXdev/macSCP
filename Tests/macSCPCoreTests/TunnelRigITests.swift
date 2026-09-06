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
        let carrier = try await TunnelConnection.connect(
            session: session, secrets: [RigSecret()],
            knownHosts: KnownHostsStore(directory: carrierHosts),
            decider: .asking { _ in true })

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

            let throughTheTunnel = try await CitadelFileSystem.connect(
                config: try SSHConnectionConfig(
                    host: "127.0.0.1", port: port, username: "testuser",
                    auth: .password("testpass")),
                connectTimeout: .seconds(30),
                knownHosts: KnownHostsStore(directory: tunnelledHosts),
                onUnknownHostKey: .asking { _ in true })

            let items = try await throughTheTunnel.list(path: "/data/seed")
            #expect(items.map(\.name).contains("hello.txt"))
            #expect(seen.events.contains(.opened))

            await throughTheTunnel.disconnect()
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

    /// A dynamic forward (`-D`): a hand-written SOCKS5 client asks the
    /// listener to CONNECT to the rig's own sshd — `127.0.0.1:2222` as the
    /// SERVER sees it, the same target the local forward above uses — and
    /// then reads the SSH banner that comes back through the pump. The
    /// banner is the proof that the bytes are the far side's own and not the
    /// listener's: nothing in this process writes `SSH-2.0`.
    ///
    /// The payload is deliberately tiny (a banner is a few dozen bytes).
    /// `BytePump`'s backpressure resume turns `autoRead` back on without an
    /// explicit `read()`, which an SSH child channel needs; a transfer large
    /// enough to make the local socket unwritable would therefore stall.
    /// That is Task 2's to fix and is written down in this task's report.
    @Test func aDynamicForwardCarriesASOCKS5Connect() async throws {
        let carrierHosts = throwawayDirectory("socks-carrier")
        defer { try? FileManager.default.removeItem(at: carrierHosts) }

        let session = sshSession(
            name: "rig", host: "127.0.0.1", port: 2222, username: "testuser", authKind: .password)
        let carrier = try await TunnelConnection.connect(
            session: session, secrets: [RigSecret()],
            knownHosts: KnownHostsStore(directory: carrierHosts),
            decider: .asking { _ in true })

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
