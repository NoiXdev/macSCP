import Crypto
import Foundation
import MacSCPTestSupport
import NIOCore
import NIOPosix
// `@preconcurrency` for the reason `SSHForwardingConnectionTests.swift`
// gives: the NIOSSH fork this project pins carries no `Sendable`
// conformances, and the server below captures its host key in NIO's
// `@Sendable` child-channel initializer.
@preconcurrency import NIOSSH
import Synchronization
import Testing

@testable import macSCPCore

/// A tab's SFTP start against a server that never answers it — the backlog
/// row "A tab dial against a server without the SFTP subsystem never
/// returns".
///
/// Every deadline here is fired BY HAND through an injected sleeper: nothing
/// in this suite waits for the connect timeout, or for any wall-clock time.
/// `.timeLimit` is a hang bound only.
@Suite("SFTP start bound", .timeLimit(.minutes(1)))
struct SFTPStartBoundTests {
    // MARK: - The seam

    /// An open that never answers: once the deadline fires, the start throws
    /// `SFTPStartError.noResponse`, the client has been closed exactly once,
    /// and the open itself has ENDED by the time the start returns — no
    /// suspended task is left behind.
    @Test func anUnansweredOpenEndsWithItsOwnErrorOnceTheDeadlineFires() async throws {
        let deadline = HandFiredDeadline()
        let open = UnansweredOpen()
        let start = Task {
            try await SFTPStartBound.run(
                deadline: .seconds(30), sleeper: deadline.sleep,
                open: { try await open.open() }, closeClient: { open.closeClient() })
        }
        try await pollUntil("the deadline is armed") { deadline.requested.count == 1 }
        try await pollUntil("the open is waiting") { open.isWaiting }
        // Positive checks before the negative ones below: the start is really
        // parked on an open that has not ended and a client nobody closed.
        #expect(open.closeCount == 0)
        #expect(open.hasEnded == false)

        deadline.fire()
        let outcome = await start.result

        let raised: (any Error)?
        switch outcome {
        case .success: raised = nil
        case .failure(let error): raised = error
        }
        #expect(raised as? SFTPStartError == .noResponse)
        #expect(open.closeCount == 1)
        #expect(open.hasEnded)
        #expect(deadline.requested == [.seconds(30)])
    }

    /// The same seam answering: the session comes back, the client is left
    /// open, and the deadline was armed (so the "not closed" is a verdict on
    /// a race that ran, not on one that never started).
    @Test func anAnsweredOpenYieldsTheSessionAndLeavesTheClientOpen() async throws {
        let deadline = HandFiredDeadline()
        let open = UnansweredOpen()
        let start = Task {
            try await SFTPStartBound.run(
                deadline: .seconds(30), sleeper: deadline.sleep,
                open: { try await open.open() }, closeClient: { open.closeClient() })
        }
        try await pollUntil("the open is waiting") { open.isWaiting }
        open.answer()
        let session = try await start.value

        #expect(session == UnansweredOpen.session)
        #expect(open.closeCount == 0)
        #expect(deadline.requested == [.seconds(30)])
    }

    /// An open that fails on its own is that failure, not the start's own
    /// error, and closes nothing here — the dial's own `catch` closes the
    /// client, as it always has.
    @Test func anOpenThatFailsOnItsOwnKeepsItsError() async throws {
        let deadline = HandFiredDeadline()
        let open = UnansweredOpen()
        let start = Task {
            try await SFTPStartBound.run(
                deadline: .seconds(30), sleeper: deadline.sleep,
                open: { try await open.open() }, closeClient: { open.closeClient() })
        }
        try await pollUntil("the open is waiting") { open.isWaiting }
        open.refuse()
        let outcome = await start.result

        let raised: (any Error)?
        switch outcome {
        case .success: raised = nil
        case .failure(let error): raised = error
        }
        #expect(raised is UnansweredOpen.Refused)
        #expect(open.closeCount == 0)
    }

    /// Cancelling the dial's task ends a start parked on an unanswered open:
    /// the client is closed, the open has ended, and nothing is left
    /// suspended. Before the bound, a cancel abandoned such a dial instead.
    @Test func cancellingAParkedStartClosesTheClientAndEndsIt() async throws {
        let deadline = HandFiredDeadline()
        let open = UnansweredOpen()
        let start = Task {
            try await SFTPStartBound.run(
                deadline: .seconds(30), sleeper: deadline.sleep,
                open: { try await open.open() }, closeClient: { open.closeClient() })
        }
        try await pollUntil("the deadline is armed") { deadline.requested.count == 1 }
        try await pollUntil("the open is waiting") { open.isWaiting }
        #expect(open.closeCount == 0)

        start.cancel()
        let outcome = await start.result

        let raised: (any Error)?
        switch outcome {
        case .success: raised = nil
        case .failure(let error): raised = error
        }
        #expect(raised is CancellationError)
        #expect(open.closeCount == 1)
        #expect(open.hasEnded)
    }

    // MARK: - A real dial against an in-process server that never starts SFTP

    /// `CitadelFileSystem.connect` end to end, against a loopback SSH server
    /// that opens the session channel and then says nothing: the dial arms
    /// the SFTP deadline with ITS connect timeout, fails with
    /// `SFTPStartError.noResponse` when it fires, and the server sees the
    /// connection close.
    ///
    /// This is also the measurement behind the start's shape: the start
    /// returns only once Citadel's open has ended, and Citadel's open waits
    /// on an `EventLoopFuture` that only the client's close fails. A close
    /// that did not fail it would hang here, inside the hang bound.
    @Test func aTabDialAgainstAServerThatNeverStartsSFTPEndsWithItsOwnError() async throws {
        let server = try await SilentSFTPServer.start()
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-kh-sftpstart-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = KnownHostsStore(directory: directory)
        try store.upsert(KnownHostKey(
            host: "127.0.0.1", port: server.port,
            keyType: server.hostKey.keyType, publicKeyBase64: server.hostKey.publicKeyBase64))
        let config = try SSHConnectionConfig(
            host: "127.0.0.1", port: server.port, username: SilentSFTPServer.username,
            auth: .password(SilentSFTPServer.password))

        let deadline = HandFiredDeadline()
        let dial = SFTPStartBound.$sleeperOverride.withValue(deadline.sleep) {
            Task {
                let fileSystem = try await CitadelFileSystem.connect(
                    config: config, connectTimeout: .seconds(7), knownHosts: store,
                    onUnknownHostKey: .refusing)
                await fileSystem.disconnect()
            }
        }
        try await pollUntil("the SFTP deadline is armed") { deadline.requested.count == 1 }
        // The deadline and the open start together, so the channel reaches
        // the server on its own schedule: waited for, not assumed.
        try await pollUntil("the server accepts the SFTP session channel") {
            server.sessionChannels == 1
        }
        #expect(deadline.requested == [.seconds(7)])
        #expect(server.connectionsClosed == 0)

        deadline.fire()
        let outcome = await dial.result
        try await pollUntil("the server sees the connection close") { server.connectionsClosed == 1 }
        await server.close()

        let raised: (any Error)?
        switch outcome {
        case .success: raised = nil
        case .failure(let error): raised = error
        }
        #expect(raised as? SFTPStartError == .noResponse)
    }

    // MARK: - Every surface names it

    @MainActor
    @Test func theConnectFormShowsItsOwnMessageAndLetsARetryHappen() async {
        let vm = ConnectionViewModel(connector: { _, _ in throw SFTPStartError.noResponse })
        vm.host = "example.com"
        vm.port = "22"
        vm.username = "tim"
        vm.password = "unit-fixture"
        _ = await vm.connect()
        let state = vm.state
        let kind = vm.lastFailureKind
        #expect(state == .failed(message: CoreL10n.string("core.connect.sftpUnavailable"), field: nil))
        // The positive beside it: the catalogue key resolves to a sentence,
        // not to the key text `CoreL10n` falls back to.
        #expect(CoreL10n.string("core.connect.sftpUnavailable") != "core.connect.sftpUnavailable")
        #expect(kind == .other)
    }

    @Test func theDiagnosticSentenceIsFixed() {
        #expect(DialSupport.reason(for: SFTPStartError.noResponse)
            == "the server did not start the SFTP subsystem")
        #expect(DialSupport.failureKind(for: SFTPStartError.noResponse) == .unknown)
    }

    @Test func theCommandLineExitsAsARemoteRefusalWithAPlainMessage() {
        #expect(CLIErrorMapping.exitCode(for: SFTPStartError.noResponse) == .remote)
        #expect(CLIErrorMapping.message(for: SFTPStartError.noResponse)
            == "Error: the server did not start SFTP; it may not offer SFTP at all")
    }

    /// `mapConnectError` passes the typed error through instead of reducing
    /// it to `connectionFailed(reason:)` text.
    @Test func theConnectErrorMappingKeepsTheType() {
        #expect(CitadelFileSystem.mapStageAware(SFTPStartError.noResponse) as? SFTPStartError
            == .noResponse)
    }
}

/// A deadline the test fires by hand, recording every duration it was armed
/// with. Honours cancellation, as `Task.sleep` does.
private final class HandFiredDeadline: Sendable {
    private let signal = AsyncSignal()
    private let asked = Mutex<[Duration]>([])

    var requested: [Duration] { asked.withLock { $0 } }

    func fire() { signal.signal() }

    var sleep: SFTPStartBound.Sleeper {
        { [self] duration in
            asked.withLock { $0.append(duration) }
            guard await signal.wait() == .signalled else { throw CancellationError() }
        }
    }
}

/// An SFTP open that answers only when told to, and otherwise waits — the
/// shape of Citadel's `openSFTP` against a server that never sends its
/// version: it ignores cancellation, and the only thing that ends it is the
/// client's close.
private final class UnansweredOpen: Sendable {
    static let session = 42

    struct Closed: Error {}
    struct Refused: Error {}

    private enum Verdict: Sendable { case answered, refused, closed }

    private let released = AsyncSignal()
    private let verdict = Mutex<Verdict?>(nil)
    private let waiting = Mutex(false)
    private let ended = Mutex(false)
    private let closes = Mutex(0)

    var isWaiting: Bool { waiting.withLock { $0 } }
    var hasEnded: Bool { ended.withLock { $0 } }
    var closeCount: Int { closes.withLock { $0 } }

    func open() async throws -> Int {
        defer { ended.withLock { $0 = true } }
        waiting.withLock { $0 = true }
        // Detached, so the task's cancellation cannot end this wait — only a
        // verdict can.
        let signal = released
        _ = await Task.detached { await signal.wait() }.value
        switch verdict.withLock({ $0 }) {
        case .answered?: return Self.session
        case .refused?: throw Refused()
        case .closed?, nil: throw Closed()
        }
    }

    func answer() { settle(.answered) }
    func refuse() { settle(.refused) }

    func closeClient() {
        closes.withLock { $0 += 1 }
        settle(.closed)
    }

    private func settle(_ value: Verdict) {
        verdict.withLock { if $0 == nil { $0 = value } }
        released.signal()
    }
}

/// An SSH server on an ephemeral loopback port that authenticates one
/// username/password pair, accepts every session channel, and then says
/// nothing on it — no subsystem answer, no SFTP version. It counts the
/// channels it accepted and the TCP connections that closed.
///
/// The host key is generated per server and never written anywhere. The
/// password is a fixture for this in-process server, not a credential.
private final class SilentSFTPServer: @unchecked Sendable {
    static let username = "unit"
    static let password = "unit-fixture"

    let port: Int
    let hostKey: HostKeyCandidate
    private let channel: Channel
    private let counters: Counters

    var sessionChannels: Int { counters.channels.withLock { $0 } }
    var connectionsClosed: Int { counters.closed.withLock { $0 } }

    private final class Counters: Sendable {
        let channels = Mutex(0)
        let closed = Mutex(0)
    }

    private init(port: Int, hostKey: HostKeyCandidate, channel: Channel, counters: Counters) {
        self.port = port
        self.hostKey = hostKey
        self.channel = channel
        self.counters = counters
    }

    static func start() async throws -> SilentSFTPServer {
        let privateKey = NIOSSHPrivateKey(ed25519Key: Curve25519.Signing.PrivateKey())
        let counters = Counters()
        let channel = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .childChannelInitializer { child in
                child.closeFuture.whenComplete { _ in counters.closed.withLock { $0 += 1 } }
                return child.eventLoop.makeCompletedFuture {
                    let handler = NIOSSHHandler(
                        role: .server(SSHServerConfiguration(
                            hostKeys: [privateKey], userAuthDelegate: PasswordDelegate())),
                        allocator: child.allocator,
                        inboundChildChannelInitializer: { sshChild, _ in
                            counters.channels.withLock { $0 += 1 }
                            return sshChild.eventLoop.makeSucceededVoidFuture()
                        })
                    try child.pipeline.syncOperations.addHandler(handler)
                }
            }
            .bind(host: "127.0.0.1", port: 0)
            .get()
        guard let port = channel.localAddress?.port else {
            try await channel.close()
            throw NoPort()
        }
        let hostKey = HostKeyCandidate(host: "127.0.0.1", port: port, publicKey: privateKey.publicKey)
        return SilentSFTPServer(port: port, hostKey: hostKey, channel: channel, counters: counters)
    }

    func close() async {
        try? await channel.close()
    }

    private struct NoPort: Error {}

    private final class PasswordDelegate: NIOSSHServerUserAuthenticationDelegate, @unchecked Sendable {
        var supportedAuthenticationMethods: NIOSSHAvailableUserAuthenticationMethods { .password }

        func requestReceived(
            request: NIOSSHUserAuthenticationRequest,
            responsePromise: EventLoopPromise<NIOSSHUserAuthenticationOutcome>
        ) {
            guard request.username == SilentSFTPServer.username,
                case .password(let offered) = request.request,
                offered.password == SilentSFTPServer.password
            else {
                responsePromise.succeed(.failure)
                return
            }
            responsePromise.succeed(.success)
        }
    }
}
