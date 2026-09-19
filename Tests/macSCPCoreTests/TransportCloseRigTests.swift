import Foundation
import Testing
@testable import macSCPCore

/// The close report against a real server (lost-connection cause,
/// 2026-09-19): a connection whose sshd session is killed on the server must
/// report "closed by the peer or the network", and one macSCP disconnects
/// must report "closed by the app".
///
/// Runs only with MACSCP_ITEST=1 and the Docker rig up (`docker compose -f
/// docker/test-server/compose.yml up -d`, from the main checkout).
///
/// Kills only the sessions that appeared while THIS test connected: the
/// server's session processes are listed before and after the connect, and
/// only the difference is signalled. Another suite dialling the same
/// container in that window could still lose a session to it; the rig
/// offers no narrower handle on one connection from the outside.
///
/// What this suite does NOT pin, measured 2026-09-19 against this rig and
/// written into the report of that day: a TARGET session killed behind a
/// jump host produces no close at all. The jump's sshd answers the dead
/// forwarded socket with an EOF on the forwarding channel, Citadel opens
/// that channel with remote half-closure allowed, and the channel stays
/// open — no close report within 2 minutes, and a `stat` on it hung past
/// 35 s. The probe sees a timeout there, not a closed connection.
///
/// Every wait is an `await` on the report stream — no clock bound of its
/// own; a report that never comes ends the run through `.timeLimit`.
@Suite(
    "Transport close report against the Docker SSH rig",
    .enabled(if: ProcessInfo.processInfo.environment["MACSCP_ITEST"] == "1"),
    .serialized,
    .timeLimit(.minutes(2))
)
struct TransportCloseRigTests {
    private static let docker = URL(fileURLWithPath: "/usr/local/bin/docker")
    /// The per-connection process OpenSSH 10 forks for every session. The
    /// listener's own command line does not contain it, so killing these
    /// leaves the server accepting.
    private static let sessionProcess = "sshd-session"

    private static func sessionPIDs(in container: String) async throws -> Set<String> {
        let result = try await SubprocessRunner.run(
            docker, arguments: ["exec", container, "pgrep", "-f", sessionProcess])
        return Set(result.stdoutText.split(whereSeparator: \.isNewline).map(String.init))
    }

    private static func connect(_ config: SSHConnectionConfig, knownHostsIn dir: URL) async throws
        -> CitadelFileSystem
    {
        try await connectWithRetry {
            try await CitadelFileSystem.connect(
                config: config, connectTimeout: .seconds(30),
                knownHosts: KnownHostsStore(directory: dir), onUnknownHostKey: .asking { _ in true })
        }
    }

    private static func freshDirectory() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-kh-close-\(UUID().uuidString)")
    }

    private struct Watched {
        let fs: CitadelFileSystem
        var next: AsyncStream<TransportCloseEvent>.Iterator
        let continuation: AsyncStream<TransportCloseEvent>.Continuation
    }

    private static func watch(_ fs: CitadelFileSystem) -> Watched {
        let (reports, continuation) = AsyncStream<TransportCloseEvent>.makeStream()
        fs.onTransportClose { continuation.yield($0) }
        return Watched(fs: fs, next: reports.makeAsyncIterator(), continuation: continuation)
    }

    /// Connects, proves the connection with a `stat`, and kills the sessions
    /// the connect added to `container`.
    private static func connectAndKill(
        _ config: SSHConnectionConfig, killingIn container: String, knownHostsIn dir: URL
    ) async throws -> Watched {
        let before = try await sessionPIDs(in: container)
        let watched = watch(try await connect(config, knownHostsIn: dir))
        _ = try await watched.fs.stat(path: "/")
        let ours = try await sessionPIDs(in: container).subtracting(before)
        #expect(!ours.isEmpty, "no new sshd session appeared in \(container) for this connect")
        try await SubprocessRunner.run(docker, arguments: ["exec", container, "kill"] + ours.sorted())
        return watched
    }

    @Test func aDirectConnectionKilledOnTheServerIsReportedAsThePeers() async throws {
        let dir = Self.freshDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let config = try SSHConnectionConfig(
            host: "127.0.0.1", port: 2223, username: "testuser", auth: .password("testpass"))
        var watched = try await Self.connectAndKill(
            config, killingIn: "macscp-test-sshd-2", knownHostsIn: dir)

        let first = await watched.next.next()
        #expect(first == TransportCloseEvent(hop: .target, initiator: .peerOrNetwork))

        // What the probe sees on that connection now: a closed one, by kind.
        do {
            _ = try await watched.fs.stat(path: "/")
            Issue.record("stat succeeded on a connection whose session was killed")
        } catch {
            #expect(LivenessProbeFailure.classify(error, probedPath: "/").kind == .connectionClosed)
        }
        await watched.fs.disconnect()
        watched.continuation.finish()
        // Reported once: the disconnect after the close adds nothing.
        #expect(await watched.next.next() == nil)
    }

    /// The jump's own session killed: the jump closes, and the target — a
    /// channel inside it — closes with it. Both by the peer.
    @Test func aJumpKilledOnTheServerTakesTheTargetWithItBothAsThePeers() async throws {
        let dir = Self.freshDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let config = try SSHConnectionConfig(
            host: "sshd2", port: 2222, username: "testuser", auth: .password("testpass"),
            jump: .init(host: "127.0.0.1", port: 2222, username: "testuser", auth: .password("testpass")))
        var watched = try await Self.connectAndKill(
            config, killingIn: "macscp-test-sshd", knownHostsIn: dir)

        var reports: [TransportCloseEvent] = []
        for _ in 0..<2 {
            if let report = await watched.next.next() { reports.append(report) }
        }
        #expect(Set(reports.map(\.hop)) == [.target, .jump])
        #expect(reports.allSatisfy { $0.initiator == .peerOrNetwork })
        await watched.fs.disconnect()
        watched.continuation.finish()
    }

    /// A direct connection closed by the app reports exactly one close, the
    /// target's, as the app's.
    @Test func aDirectDisconnectIsReportedOnceAsTheApps() async throws {
        let dir = Self.freshDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let config = try SSHConnectionConfig(
            host: "127.0.0.1", port: 2222, username: "testuser", auth: .password("testpass"))
        var watched = Self.watch(try await Self.connect(config, knownHostsIn: dir))

        await watched.fs.disconnect()
        let first = await watched.next.next()
        #expect(first == TransportCloseEvent(hop: .target, initiator: .app))
        watched.continuation.finish()
        #expect(await watched.next.next() == nil)
    }

    /// Through a jump, the app's disconnect reports both hops as its own.
    @Test func aJumpDisconnectIsReportedForBothHopsAsTheApps() async throws {
        let dir = Self.freshDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let config = try SSHConnectionConfig(
            host: "sshd2", port: 2222, username: "testuser", auth: .password("testpass"),
            jump: .init(host: "127.0.0.1", port: 2222, username: "testuser", auth: .password("testpass")))
        var watched = Self.watch(try await Self.connect(config, knownHostsIn: dir))

        await watched.fs.disconnect()
        var seen: [TransportCloseEvent] = []
        for _ in 0..<2 {
            if let report = await watched.next.next() { seen.append(report) }
        }
        #expect(Set(seen.map(\.hop)) == [.target, .jump])
        #expect(seen.allSatisfy { $0.initiator == .app })
        watched.continuation.finish()
    }
}
