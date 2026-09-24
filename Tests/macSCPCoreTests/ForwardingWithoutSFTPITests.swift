import Foundation
import MacSCPTestSupport
import NIOCore
import NIOPosix
import NIOSSH
import Testing

@testable import macSCPCore

/// A port forwarding against a server that has NO SFTP subsystem — the rig's
/// `sshd-nosftp` on `127.0.0.1:2236` (`docker/test-server/README.md`, "An
/// OpenSSH server without SFTP"). Brought up with
/// `docker compose -f docker/test-server/compose.yml up -d sshd-nosftp`,
/// from the main checkout.
///
/// A forwarding needs an authenticated SSH connection and nothing more, so
/// it has to work here. A tab's dial opens SFTP, and the server has to refuse
/// it here: that control is what makes the forwarding cases worth anything,
/// since a server that quietly still served SFTP would let them pass for the
/// wrong reason.
///
/// **A tab's dial against this server used to never return** (measured
/// 2026-09-17): sshd logs `subsystem request for sftp by user testuser
/// failed, subsystem not found`, and Citadel's `openSFTP` waited on a version
/// reply that never came, in an `EventLoopFuture` that does not answer
/// cancellation — past this suite's five-minute limit. `SFTPStartBound` now
/// ends that dial with `SFTPStartError.noResponse` once its connect timeout
/// has passed, and the control case below awaits it directly.
///
/// The FORWARDING cases still race their dial against the server's refusal
/// log line rather than await it: a forwarding never reaches that bound, so
/// a forwarding that regressed into asking for SFTP would have no timer of
/// its own to end it. Such a dial runs in an unstructured task, and the test
/// waits for whichever comes first: the dial returning, or the server's own
/// log counting one more SFTP refusal.
///
/// The target inside the container is a fixed PRIVILEGED port, `998`, for
/// the reason `TunnelRigITests.aFailedConnectionIsCountedWhileTheForwardStaysUp`
/// gives for its `999`: `docker exec` runs as uid 0, `testuser` cannot bind
/// below 1024, so nothing but this test's own listener can ever answer
/// there. Readiness is read from `netstat` rather than probed with a
/// connection, because the listener is a one-shot `nc -l` and a probe would
/// spend its only accept.
@Suite(
    "Forwardings against the Docker SSH server without SFTP",
    .enabled(if: ProcessInfo.processInfo.environment["MACSCP_ITEST"] == "1"),
    .serialized,
    .timeLimit(.minutes(5))
)
struct ForwardingWithoutSFTPITests {
    private static let host = "127.0.0.1"
    private static let port = 2236
    private static let targetPort = 998

    /// The tunnel's own dial, straight: it connects to a server without SFTP,
    /// and the server records no SFTP request from it.
    @Test func aForwardingDialConnectsWithoutAskingForSFTP() async throws {
        let knownHosts = throwawayDirectory("dial")
        defer { try? FileManager.default.removeItem(at: knownHosts) }

        let session = Self.session()
        let race = try await raceAgainstSFTPRefusal {
            let connection = try await TunnelConnection.connect(
                session: session, secrets: SecretChain(sources: [NoSFTPRigSecret()]),
                knownHosts: KnownHostsStore(directory: knownHosts),
                decider: .asking { _ in true })
            await connection.disconnect()
        }

        #expect(!race.refusedSFTP, "the forwarding dial asked the server for SFTP")
        switch race.outcome {
        case .success?:
            break
        case .failure(let error)?:
            Issue.record("the forwarding dial failed against a server without SFTP: \(error)")
        case nil:
            Issue.record("the forwarding dial had not returned when the server refused SFTP")
        }
    }

    /// `TunnelRunner` with the live runtime factory: a `-L` to a listener
    /// inside the container reaches `active` and carries that listener's
    /// line back to this Mac.
    ///
    /// The first wait also ends on a failure, a reconnect, or an SFTP refusal
    /// in the server's log, so a dial that cannot connect is a red with its
    /// reason rather than a wait only the time limit ends. On that red the
    /// runner is NOT stopped: `stop()` awaits the run task, and a forwarding
    /// dial that asked for SFTP would hold that task with no bound of its own
    /// (see the suite's comment).
    @Test func aLocalForwardReachesActiveAndCarriesBytesFromInsideTheContainer() async throws {
        let knownHosts = throwawayDirectory("runner")
        defer { try? FileManager.default.removeItem(at: knownHosts) }

        let marker = "carried-without-sftp-\(UUID().uuidString)"
        // `-q 0`: quit once standard input is exhausted, which closes the
        // connection after the marker — the end the client below waits for.
        let listen = "nc -q 0 -l 127.0.0.1 \(Self.targetPort)"
        let started = try await docker([
            "exec", "-d", noSFTPContainer, "sh", "-c", "printf '\(marker)' | \(listen)",
        ])
        #expect(started.status == 0)
        try await pollUntil("the listener inside the container is up") {
            let probe = try? await docker([
                "exec", noSFTPContainer, "sh", "-c",
                "netstat -tln | grep -q '127.0.0.1:\(Self.targetPort) '",
            ])
            return probe?.status == 0
        }

        let session = Self.session()
        let profile = TunnelProfile(
            sessionID: session.id, name: "nosftp-runner",
            kind: .local(
                bind: "127.0.0.1", localPort: 0, host: "127.0.0.1", remotePort: Self.targetPort))
        let runner = TunnelRunner(
            profile: profile,
            connect: { decider in
                try await TunnelConnection.connect(
                    session: session, secrets: SecretChain(sources: [NoSFTPRigSecret()]),
                    knownHosts: KnownHostsStore(directory: knownHosts), decider: decider)
            })
        let states = TunnelStateCollector(runner.states)

        let refusalsBefore = try await sftpRefusals()
        await runner.start(decider: .asking { _ in true })
        var refusedSFTP = false
        try await pollUntil("active, a failure, or an SFTP refusal") {
            if (try? await sftpRefusals()).map({ $0 > refusalsBefore }) == true {
                refusedSFTP = true
                return true
            }
            return states.recorded.contains { state in
                switch state {
                case .active, .failed, .reconnecting: return true
                default: return false
                }
            }
        }
        guard !refusedSFTP else {
            Issue.record("the forwarding's dial asked the server for SFTP and was refused")
            _ = try? await docker(["exec", noSFTPContainer, "pkill", "-f", listen])
            return
        }
        let reached = await runner.state
        guard case .active = reached else {
            let reason = await runner.failureReason
            Issue.record("the forwarding did not become active: \(reached), reason: \(reason ?? "-")")
            await runner.stop()
            _ = try? await docker(["exec", noSFTPContainer, "pkill", "-f", listen])
            return
        }

        let inbox = NoSFTPByteInbox()
        do {
            let port = try #require(await runner.boundPort)
            let client = try await awaitCancellably(
                ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
                    .channelInitializer { channel in
                        channel.pipeline.addHandler(NoSFTPByteCollector(inbox: inbox))
                    }
                    .connect(host: "127.0.0.1", port: port))
            // The listener writes its line and `nc` closes; the pump carries
            // that close back, so this waits for an end rather than a clock.
            try await awaitCancellably(client.closeFuture)
        } catch {
            await runner.stop()
            _ = try? await docker(["exec", noSFTPContainer, "pkill", "-f", listen])
            throw error
        }

        #expect(String(decoding: inbox.bytes, as: UTF8.self) == marker)
        await runner.stop()
        #expect(await runner.state == .stopped)
        _ = try? await docker(["exec", noSFTPContainer, "pkill", "-f", listen])
    }

    /// The control: a tab's dial against the same server, with the same
    /// credentials, asks for SFTP and the server refuses it — read from the
    /// server's own log, so the rig really has no SFTP and the cases above
    /// measure what they claim. The dial is awaited: it ends with
    /// `SFTPStartError.noResponse` once its connect timeout has passed.
    ///
    /// Five seconds rather than the thirty the other dials here carry, only
    /// so the run does not sit out a longer bound; it is not asserted on.
    @Test func aTabsDialAgainstTheSameServerEndsWithTheSFTPStartError() async throws {
        let knownHosts = throwawayDirectory("tab")
        defer { try? FileManager.default.removeItem(at: knownHosts) }

        let config = try SSHConnectionConfig(
            host: Self.host, port: Self.port, username: "testuser", auth: .password("testpass"))
        let refusalsBefore = try await sftpRefusals()
        let raised: (any Error)?
        do {
            let fileSystem = try await CitadelFileSystem.connect(
                config: config,
                connectTimeout: .seconds(5),
                knownHosts: KnownHostsStore(directory: knownHosts),
                onUnknownHostKey: .asking { _ in true })
            await fileSystem.disconnect()
            raised = nil
        } catch {
            raised = error
        }

        #expect(raised as? SFTPStartError == .noResponse)
        // The server wrote its refusal before the dial's bound ran out; the
        // log is read until it shows, not against a clock.
        try await pollUntil("the server logs its SFTP refusal") {
            (try? await sftpRefusals()).map { $0 > refusalsBefore } == true
        }
    }

    /// TOFU on the forwarding path, behaviourally: a pinned key that differs
    /// from the server's is a hard stop with `HostKeyError.mismatch`, and the
    /// decider is never consulted — the same verdict the tab path gives
    /// (`CitadelFileSystemIntegrationTests`), from the same validator.
    @Test func aMismatchedHostKeyStopsTheForwardingDial() async throws {
        let knownHosts = throwawayDirectory("mismatch")
        defer { try? FileManager.default.removeItem(at: knownHosts) }

        let otherKey = NIOSSHPrivateKey(ed25519Key: .init()).publicKey
        let pinned = HostKeyCandidate(host: Self.host, port: Self.port, publicKey: otherKey)
        let store = KnownHostsStore(directory: knownHosts)
        try store.upsert(KnownHostKey(
            host: pinned.host, port: pinned.port,
            keyType: pinned.keyType, publicKeyBase64: pinned.publicKeyBase64))

        let asked = NoSFTPAskCounter()
        let raised: (any Error)?
        do {
            let connection = try await TunnelConnection.connect(
                session: Self.session(), secrets: SecretChain(sources: [NoSFTPRigSecret()]),
                knownHosts: store,
                decider: .asking { _ in
                    asked.increment()
                    return true
                })
            await connection.disconnect()
            raised = nil
        } catch {
            raised = error
        }

        guard case .mismatch(let host, let expected, _) = raised as? HostKeyError else {
            Issue.record("expected HostKeyError.mismatch, got \(String(describing: raised))")
            return
        }
        #expect(host == Self.host)
        #expect(expected == pinned.fingerprintSHA256)
        #expect(asked.count == 0)
    }

    private static func session() -> StoredSession {
        sshSession(
            name: "nosftp", host: host, port: port, username: "testuser", authKind: .password)
    }
}

private let noSFTPContainer = "macscp-test-sshd-nosftp"

/// How many SFTP subsystem requests the server has refused so far, counted
/// in its own log. The line is OpenSSH's, as the container wrote it on
/// 2026-09-17: `subsystem request for sftp by user testuser failed,
/// subsystem not found`. `|| true` because `grep -c` exits 1 on a count of
/// zero, which is an answer here, not a failure.
private func sftpRefusals() async throws -> Int {
    let result = try await docker([
        "exec", noSFTPContainer, "sh", "-c",
        "grep -c 'subsystem request for sftp by user testuser failed' "
            + "/config/logs/openssh/current || true",
    ])
    let text = result.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let count = Int(text) else {
        throw NoSFTPLogUnreadable(output: text)
    }
    return count
}

private struct NoSFTPLogUnreadable: Error {
    let output: String
}

/// Starts `dial` in an unstructured task and waits until it has returned, or
/// until the server's log counts one more SFTP refusal than before it
/// started — whichever comes first. The suite's comment says why the dial
/// itself is never awaited.
///
/// `refusedSFTP` is read once more after the wait, so a dial that returned
/// AND was refused on the way reports both.
private func raceAgainstSFTPRefusal(
    _ dial: @escaping @Sendable () async throws -> Void
) async throws -> (outcome: Result<Void, any Error>?, refusedSFTP: Bool) {
    let before = try await sftpRefusals()
    let outcome = NoSFTPDialOutcome()
    Task {
        do {
            try await dial()
            outcome.set(.success(()))
        } catch {
            outcome.set(.failure(error))
        }
    }
    try await pollUntil("the dial to return or the server to refuse SFTP") {
        if outcome.result != nil { return true }
        return (try? await sftpRefusals()).map { $0 > before } == true
    }
    let refused = try await sftpRefusals() > before
    return (outcome.result, refused)
}

private final class NoSFTPDialOutcome: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Result<Void, any Error>?

    var result: Result<Void, any Error>? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func set(_ value: Result<Void, any Error>) {
        lock.lock()
        stored = value
        lock.unlock()
    }
}

private func docker(_ arguments: [String]) async throws -> SubprocessResult {
    try await SubprocessRunner.run(
        URL(fileURLWithPath: "/usr/bin/env"), arguments: ["docker"] + arguments,
        timeout: .seconds(60))
}

private func throwawayDirectory(_ role: String) -> URL {
    URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("macscp-kh-nosftp-\(role)-\(UUID().uuidString)")
}

/// The rig's password as a `SecretSource`, so `TunnelConnection.connect` is
/// exercised through its real resolution path.
private struct NoSFTPRigSecret: SecretSource {
    let label = "rig"

    func secret(for sessionID: UUID) throws -> String? { "testpass" }
}

private final class NoSFTPAskCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var asked = 0

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return asked
    }

    func increment() {
        lock.lock()
        asked += 1
        lock.unlock()
    }
}

private final class NoSFTPByteInbox: @unchecked Sendable {
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

private final class NoSFTPByteCollector: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    private let inbox: NoSFTPByteInbox

    init(inbox: NoSFTPByteInbox) { self.inbox = inbox }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        inbox.append(buffer.readBytes(length: buffer.readableBytes) ?? [])
    }
}
