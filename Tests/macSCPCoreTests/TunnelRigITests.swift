import Foundation
import MacSCPTestSupport
import NIOCore
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
