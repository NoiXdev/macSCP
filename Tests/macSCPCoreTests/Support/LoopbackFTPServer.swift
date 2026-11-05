import Foundation
import MacSCPTestSupport
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import NIOSSL
import NIOTLS
import macSCPCore

// MARK: - Credentials

/// The login a `LoopbackFTPServer` accepts. Generated per server instance, so
/// there is no literal in the tree that could be mistaken for a real secret,
/// and printing one shows nothing: a failed `#expect` prints the value of
/// every operand it touched, and this is a value that must not reach a log.
struct LoopbackFTPCredentials: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let username: String
    let password: String

    init() {
        username = "user-\(UUID().uuidString.prefix(8))"
        password = UUID().uuidString
    }

    var description: String { "LoopbackFTPCredentials(<redacted>)" }
    var debugDescription: String { description }
}

// MARK: - What the server records

/// One command line the server received, as the server saw it.
///
/// `argument` of `PASS` is never stored: the log exists so a test can ask
/// "did a credential cross the network before TLS?", and answering that needs
/// the verb and `overTLS`, not the secret.
struct LoopbackFTPReceivedCommand: Sendable, Equatable {
    let verb: String
    let argument: String
    /// The control connection was inside TLS when the line arrived.
    let overTLS: Bool

    static let redactedArgument = "<redacted>"
}

/// One completed TLS handshake the server took part in, and whether it
/// resumed an earlier session (read off the wire, see
/// `TLSResumptionInspector`).
struct LoopbackFTPHandshake: Sendable, Equatable {
    enum Connection: Sendable, Equatable {
        case control
        case data
    }

    let connection: Connection
    let resumed: Bool
}

/// Shared, lock-protected state: written by the actor's seams and by NIO event
/// loops, read by the control sessions. A class rather than actor state
/// because event-loop code records a handshake synchronously, in the very
/// callback that learns of it, and an actor hop there would let a test read
/// the journal before the entry was in it.
final class LoopbackFTPState: Sendable {
    struct Inner: Sendable {
        var refuseNextAcquire = false
        var desynchroniseNextReply = false
        var pasvHost: String?
        var dropNextTransfer = false

        var commands: [LoopbackFTPReceivedCommand] = []
        var handshakes: [LoopbackFTPHandshake] = []
        var controlConnections = 0
        var refusedDataConnections = 0

        /// Absolute path to contents. Directories are a separate set so an
        /// empty one exists.
        var files: [String: Data] = [:]
        var directories: Set<String> = ["/"]

        /// Every channel this server opened or accepted and that has not
        /// closed yet, so `stop()` can close them itself.
        var liveChannels: [ObjectIdentifier: Channel] = [:]

        /// Set, under the same lock as the snapshot of `liveChannels`, by
        /// `beginStopping()`. From then on `track(_:)` closes what it is given.
        /// Cleared by `reset()`, which `start()` calls: see there.
        var stopping = false

        /// The tasks that close channels nobody could be handed (see
        /// `LoopbackFTPServer.hand`), kept so `stop()` can await them before it
        /// takes the event loops down.
        var reapers: [Task<Void, Never>] = []
    }

    let box = NIOLockedValueBox(Inner())

    /// Remembers `channel` until it closes -- or, once `beginStopping()` has
    /// run, closes it at once.
    ///
    /// **Why the flag lives here.** `stop()` used to snapshot `liveChannels`
    /// once, and a passive listener is tracked only after its `bind` resolves,
    /// on a session task: one bound inside the window between the snapshot and
    /// the end of `stop()` was never closed, its connection stream never
    /// finished, and the session parked in `handleTransfer` on a connection
    /// that could not arrive -- so `stop()` never reached the event-loop
    /// shutdown. Reasoned from the code, not reproduced (a client pipelining
    /// `PASV` and `RETR` against a `stop()`); the same class as the three
    /// races measured on 2026-11-05. The invariant is local to the box that
    /// owns the set: a channel is either in the snapshot `beginStopping()`
    /// returns, or arrives after the flag and is closed by the call that
    /// registers it. There is no window, so there is nothing to widen.
    @discardableResult
    func track(_ channel: Channel) -> Bool {
        let key = ObjectIdentifier(channel)
        let refused = box.withLockedValue { inner -> Bool in
            if inner.stopping { return true }
            inner.liveChannels[key] = channel
            return false
        }
        if refused {
            channel.close(promise: nil)
            return false
        }
        channel.closeFuture.whenComplete { [box] _ in
            box.withLockedValue { _ = $0.liveChannels.removeValue(forKey: key) }
        }
        return true
    }

    /// Marks the state stopping and returns everything live at that instant.
    func beginStopping() -> [Channel] {
        box.withLockedValue { inner in
            inner.stopping = true
            return Array(inner.liveChannels.values)
        }
    }

    /// Ends the stopping state, so a server can be started again. `stopping` was
    /// irreversible and `start()` did not clear it: start, stop, start would
    /// have closed every connection of the second run on arrival, silently.
    /// What the first run recorded (commands, handshakes, files) is kept on
    /// purpose; only the flag is a lifecycle fact.
    func reset() {
        box.withLockedValue { $0.stopping = false }
    }

    func addReaper(_ task: Task<Void, Never>) {
        box.withLockedValue { $0.reapers.append(task) }
    }

    func takeReapers() -> [Task<Void, Never>] {
        box.withLockedValue { inner in
            let taken = inner.reapers
            inner.reapers = []
            return taken
        }
    }
}

// MARK: - The server

/// An in-process FTP / FTPS server on the loopback interface, for the FTP
/// backend's tests: protocol behaviour, the three security modes, and the
/// hostile cases a well-behaved daemon never produces (a `421` on connect, a
/// desynchronised reply stream, a `PASV` reply naming another host, a control
/// connection that dies mid-transfer, a server that insists on TLS session
/// reuse).
///
/// **Built on NIO and `NIOSSLServerHandler`, not on Network.framework**, which
/// is what `LoopbackTLSStub` is built on. Two things decided it, both measured
/// on 2026-11-05 and recorded in
/// docs/superpowers/specs/2026-08-20-backlog-dependencies.md ("swift-nio-ssl"):
/// an `NWListener` cannot upgrade an established connection to TLS, which is
/// what `AUTH TLS` is, and its TLS metadata has no accessor for "this
/// connection resumed a session", which the `require_ssl_reuse` seam has to
/// answer. What this keeps from the stub is the certificate discipline: the
/// key pair is minted at runtime, held in memory, and nothing is ever
/// committed as key material.
///
/// Credentials are generated per instance (`credentials`).
actor LoopbackFTPServer {
    let credentials = LoopbackFTPCredentials()

    private let security: FTPSecurityMode
    private let advertisesMLSD: Bool
    private let requiresTLSSessionReuse: Bool
    private let maximumTLSVersion: TLSVersion
    private let state = LoopbackFTPState()

    /// `idle` before the first `start()` and after a finished `stop()`; the only
    /// state `start()` accepts. An actor is re-entrant at every `await`, so a
    /// second `start()` or a `stop()` can arrive while a first call is
    /// suspended; `starting` and `stopping` exist so those are REFUSED LOUDLY
    /// (both trap, with a message) instead of racing, or worse, doing nothing.
    /// `starting` is entered before the first `await` of `start()`: it used to be
    /// `running` only AFTER them, so two overlapping `start()` calls both passed
    /// the check, and a `stop()` in that window found nothing running and
    /// returned without a word.
    private enum Lifecycle { case idle, starting, running, stopping }
    private var lifecycle = Lifecycle.idle

    /// `start()` is in flight. For the tests that overlap a call with it.
    var isStarting: Bool { lifecycle == .starting }

    private var group: MultiThreadedEventLoopGroup?
    private var listener: Channel?
    private var acceptLoop: Task<Void, Never>?
    private var context: NIOSSLContext?
    private var leafCertificateDERStorage: Data?

    /// - Parameter requiresTLSSessionReuse: the `require_ssl_reuse` seam. When
    ///   on, a transfer is served only over a data connection that is BOTH
    ///   protected (`PROT P` was issued) AND whose handshake resumed a session
    ///   this server issued. A session that never issued `PROT P` is refused
    ///   with `522` before a data connection is used, and a protected data
    ///   handshake that was a full one is refused with `522` after it. The
    ///   first half is what a real server does: vsftpd's `require_ssl_reuse`
    ///   is paired with `force_local_data_ssl`, which defaults on, so clear
    ///   data is refused there too. Without that half the flag would be inert
    ///   for a client that simply skips `PROT P` -- a fail-open seam, and a
    ///   "pass" in a test against it would mean nothing. One more thing to
    ///   know when reading a result: whether data is protected is decided when
    ///   `PASV` or `EPSV` is issued (the listener is built then), not when the
    ///   data connection arrives, so `PROT` must precede the passive command.
    ///   The check is "resumed SOME session this server issued", not "the
    ///   control connection's own": that is all the wire shows.
    /// - Parameter maximumTLSVersion: exists so a test can pin TLS 1.2, whose
    ///   abbreviated handshake is the one `openssl s_client -reconnect` of the
    ///   LibreSSL on macOS completes reliably; the default is the library's.
    init(
        security: FTPSecurityMode,
        advertisesMLSD: Bool,
        requiresTLSSessionReuse: Bool,
        maximumTLSVersion: TLSVersion = .tlsv13
    ) {
        self.security = security
        self.advertisesMLSD = advertisesMLSD
        self.requiresTLSSessionReuse = requiresTLSSessionReuse
        self.maximumTLSVersion = maximumTLSVersion
    }

    // MARK: Lifecycle

    /// Binds `127.0.0.1` on a port the kernel picks and starts accepting.
    ///
    /// **A server may be started again after `stop()`**, on a new port with a new
    /// certificate; what it recorded and the files it holds carry over. Calling
    /// it on a running or stopping server is a programmer error and traps with
    /// a message that says so: a restart that silently refused every connection
    /// was the alternative, and is the polarity-reversed shape of the fail-open
    /// seam `requiresTLSSessionReuse` was changed to avoid.
    func start() async throws -> (host: String, port: Int) {
        precondition(
            lifecycle == .idle, "start() on a server that is not idle (starting, running or stopping)")
        lifecycle = .starting
        state.reset()

        if security != .plain {
            do {
                let minted = try await Self.mintContext(maximumTLSVersion: maximumTLSVersion)
                context = minted.context
                leafCertificateDERStorage = minted.certificateDER
            } catch {
                lifecycle = .idle
                throw error
            }
        }

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        let configuration = Configuration(
            security: security, advertisesMLSD: advertisesMLSD,
            requiresTLSSessionReuse: requiresTLSSessionReuse, credentials: credentials)
        let state = self.state
        let context = self.context
        let (accepted, acceptedContinuation) = AsyncStream.makeStream(
            of: NIOAsyncChannel<ByteBuffer, ByteBuffer>.self)

        let bound: Channel
        do {
            bound = try await awaitCancellably(
                ServerBootstrap(group: group)
                    .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                    .childChannelInitializer { channel in
                        channel.eventLoop.makeCompletedFuture {
                            // Refused (the server is stopping): do not wrap it. A
                            // `NIOAsyncChannel` that nothing ever consumes traps
                            // in its writer's deinit.
                            guard state.track(channel) else { return }
                            let pipeline = channel.pipeline.syncOperations
                            if configuration.security == .implicitTLS, let context {
                                let tls = LoopbackTLSHandlers(
                                    context: context, eventLoop: channel.eventLoop,
                                    onHandshake: { resumed in
                                        state.box.withLockedValue {
                                            $0.handshakes.append(.init(connection: .control, resumed: resumed))
                                        }
                                    })
                                try pipeline.addHandlers(tls.handlers)
                            }
                            try pipeline.addHandler(ByteToMessageHandler(CRLFLineDecoder()))
                            let wrapped = try NIOAsyncChannel<ByteBuffer, ByteBuffer>(
                                wrappingChannelSynchronously: channel)
                            // After the `NIOAsyncChannel` handler, on purpose:
                            // `channelActive` reaches the async handler first,
                            // which detaches its writer reference there and
                            // forwards the event, so by the time this fires
                            // the wrapper is fully armed. Before it, the
                            // consumer could be handed a channel whose wrapper
                            // had not yet seen the event.
                            try pipeline.addHandler(
                                LoopbackActivationAnnouncer {
                                    Self.hand(wrapped, to: acceptedContinuation, state: state)
                                })
                        }
                    }
                    .bind(host: "127.0.0.1", port: 0))
        } catch {
            acceptedContinuation.finish()
            try? await group.shutdownGracefully()
            lifecycle = .idle
            throw error
        }
        bound.closeFuture.whenComplete { _ in acceptedContinuation.finish() }

        self.group = group
        self.listener = bound
        lifecycle = .running
        self.acceptLoop = Task {
            await Self.serve(
                accepted: accepted, configuration: configuration, state: state,
                context: context, group: group)
        }

        guard let port = bound.localAddress?.port else {
            await stop()
            throw LoopbackFTPServerError.noLocalPort
        }
        return ("127.0.0.1", port)
    }

    /// Idempotent on an idle or already-stopping server. Closes the listener and
    /// every connection, waits for every session to finish, and only then takes
    /// the event loops down. Called while `start()` is in flight it traps: there
    /// is nothing yet to stop, and returning would leave a server running that
    /// the caller believes is stopped.
    ///
    /// The order is load-bearing, and was found by a hang: shutting the group
    /// down first closes the channels, the sessions notice and wind up, and
    /// `executeThenClose` then asks an event loop that has already been shut
    /// down to close the channel it is holding -- a task that never runs, so
    /// the session, and with it `stop()`, never returned. Measured by planting
    /// a log line at each step: "session run returned" printed, "executeThenClose
    /// returned" never did.
    func stop() async {
        precondition(lifecycle != .starting, "stop() while start() is in flight")
        guard lifecycle == .running, let group else { return }
        lifecycle = .stopping
        self.group = nil
        if let listener {
            self.listener = nil
            _ = try? await awaitCancellably(listener.close())
        }
        for channel in state.beginStopping() { _ = try? await awaitCancellably(channel.close()) }
        await acceptLoop?.value
        acceptLoop = nil
        // The closers of channels that could not be handed to a session (see
        // `hand`). By now every tracked channel has been closed and its
        // handlers removed -- the announcer registers a closer from
        // `handlerRemoved`, before the close future completes -- so none can
        // be added after this drain; and it runs BEFORE the loops go down,
        // because closing a channel through `executeThenClose` needs its loop.
        for reaper in state.takeReapers() { await reaper.value }
        try? await group.shutdownGracefully()
        lifecycle = .idle
    }

    // MARK: Seams

    /// The next control connection is answered `421` instead of `220` and
    /// closed. One shot: the connection after it is served normally.
    func refuseNextAcquireWith421() {
        state.box.withLockedValue { $0.refuseNextAcquire = true }
    }

    /// The reply to the next command is followed by one more reply, for a
    /// command that was never sent: the stream is one reply ahead of the
    /// client from then on. One shot.
    func desynchroniseNextReply() {
        state.box.withLockedValue { $0.desynchroniseNextReply = true }
    }

    /// Every `PASV` reply from now on names `host` as the address to connect
    /// to, while the data listener stays on the loopback interface. `EPSV`
    /// carries no address and is unaffected.
    func answerPASVWith(host: String) {
        state.box.withLockedValue { $0.pasvHost = host }
    }

    /// The next data transfer sends half of its payload and then drops the
    /// control connection (and the data connection) without a word. One shot.
    func dropControlConnectionMidTransfer() {
        state.box.withLockedValue { $0.dropNextTransfer = true }
    }

    // MARK: Content and observations

    /// Registers `task` as a closer `stop()` must await, as `hand(...)` does for a
    /// channel it cannot deliver. A seam for the test that `stop()` waits for
    /// registered closers before it takes the event loops down.
    func adoptCloser(_ task: Task<Void, Never>) {
        state.addReaper(task)
    }

    /// Creates `path` (and its parent directories) with `contents`.
    func seedFile(_ path: String, contents: Data) {
        state.box.withLockedValue { inner in
            inner.files[path] = contents
            var parent = (path as NSString).deletingLastPathComponent
            while parent != "/", !parent.isEmpty {
                inner.directories.insert(parent)
                parent = (parent as NSString).deletingLastPathComponent
            }
        }
    }

    func contents(of path: String) -> Data? {
        state.box.withLockedValue { $0.files[path] }
    }

    var receivedCommands: [LoopbackFTPReceivedCommand] {
        state.box.withLockedValue { $0.commands }
    }

    /// Every TLS handshake completed so far, control and data, in the order
    /// they completed.
    var handshakes: [LoopbackFTPHandshake] {
        state.box.withLockedValue { $0.handshakes }
    }

    var controlConnectionCount: Int {
        state.box.withLockedValue { $0.controlConnections }
    }

    /// Data connections that were refused because `requiresTLSSessionReuse`
    /// is on and their handshake was a full one.
    var refusedDataConnectionCount: Int {
        state.box.withLockedValue { $0.refusedDataConnections }
    }

    /// The DER of the certificate this server presents; nil for a plain
    /// server, which has none.
    var leafCertificateDER: Data? { leafCertificateDERStorage }

    // MARK: Internals

    struct Configuration: Sendable {
        let security: FTPSecurityMode
        let advertisesMLSD: Bool
        let requiresTLSSessionReuse: Bool
        let credentials: LoopbackFTPCredentials
    }

    /// Delivers a control channel to the accept loop, or, if the loop's stream has
    /// already ended, consumes and closes it. A `NIOAsyncChannel` that is
    /// neither consumed nor closed through `executeThenClose` aborts the process
    /// when it deinitialises ("Deinited NIOAsyncWriter without calling
    /// finish()"); measured on 2026-11-05 as a crash in 10 of 130 runs of the
    /// server suite (9 of 100, then 1 of 30) once `stop()` began closing
    /// channels still waiting to be announced, and in 0 of 120 runs after the
    /// fix.
    ///
    /// **The closer is registered, not detached.** It is a `Task`, and a bare one
    /// holds the channel, its descriptor and a reference to one loop of this
    /// server's own group for as long as it lives; if it runs after
    /// `group.shutdownGracefully()` it is the "task that never runs" that
    /// `stop()`'s own comment describes, and it never ends. `state` keeps it so
    /// `stop()` awaits it after the sessions and before the loops go down.
    static func hand(
        _ channel: NIOAsyncChannel<ByteBuffer, ByteBuffer>,
        to continuation: AsyncStream<NIOAsyncChannel<ByteBuffer, ByteBuffer>>.Continuation,
        state: LoopbackFTPState
    ) {
        if case .enqueued = continuation.yield(channel) { return }
        state.addReaper(Task { try? await channel.executeThenClose { _, _ in } })
    }

    /// The same for a data connection.
    static func hand(
        _ connection: LoopbackFTPDataConnection,
        to continuation: AsyncStream<LoopbackFTPDataConnection>.Continuation,
        state: LoopbackFTPState
    ) {
        if case .enqueued = continuation.yield(connection) { return }
        state.addReaper(Task { try? await connection.channel.executeThenClose { _, _ in } })
    }

    private static func serve(
        accepted: AsyncStream<NIOAsyncChannel<ByteBuffer, ByteBuffer>>,
        configuration: Configuration,
        state: LoopbackFTPState,
        context: NIOSSLContext?,
        group: MultiThreadedEventLoopGroup
    ) async {
        await withDiscardingTaskGroup { tasks in
            for await control in accepted {
                tasks.addTask {
                    let session = LoopbackFTPSession(
                        configuration: configuration, state: state, context: context,
                        group: group, control: control.channel)
                    do {
                        try await control.executeThenClose { inbound, _ in
                            try await session.run(inbound: inbound)
                        }
                    } catch {
                        // A client that vanishes mid-line is the ordinary end
                        // of a test, not a failure of the server.
                    }
                    await session.releasePassiveListener()
                }
            }
        }
    }

    /// Mints a self-signed certificate and key with `openssl` in a temporary
    /// directory that is removed as soon as the bytes are read, and keeps them
    /// in memory only. `LoopbackTLSStub` does the same and imports the result
    /// with `kSecImportToMemoryOnly`; NIOSSL takes PEM, so there is no
    /// keychain to avoid here, and the files still live only for the length of
    /// two `openssl` calls.
    private static func mintContext(
        maximumTLSVersion: TLSVersion
    ) async throws -> (context: NIOSSLContext, certificateDER: Data) {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-ftp-loopback-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let keyURL = directory.appendingPathComponent("key.pem")
        let certURL = directory.appendingPathComponent("cert.pem")
        let result = try await SubprocessRunner.run(
            URL(fileURLWithPath: "/usr/bin/openssl"),
            arguments: [
                "req", "-x509", "-newkey", "rsa:2048", "-nodes",
                "-keyout", keyURL.path(percentEncoded: false),
                "-out", certURL.path(percentEncoded: false),
                "-days", "1", "-subj", "/CN=127.0.0.1",
            ])
        guard result.status == 0 else {
            throw LoopbackFTPServerError.opensslFailed(result.status)
        }

        let certificate = try NIOSSLCertificate(
            bytes: Array(try Data(contentsOf: certURL)), format: .pem)
        let key = try NIOSSLPrivateKey(bytes: Array(try Data(contentsOf: keyURL)), format: .pem)
        var configuration = TLSConfiguration.makeServerConfiguration(
            certificateChain: [.certificate(certificate)], privateKey: .privateKey(key))
        configuration.minimumTLSVersion = .tlsv12
        configuration.maximumTLSVersion = maximumTLSVersion
        return (try NIOSSLContext(configuration: configuration), Data(try certificate.toDERBytes()))
    }
}

enum LoopbackFTPServerError: Error, Equatable {
    case noLocalPort
    case opensslFailed(Int32)
}

// MARK: - TLS plumbing

/// The three handlers a TLS-protected connection carries, in pipeline order:
/// the tap nearest the socket, the TLS handler, and the gate that learns when
/// the handshake is over.
final class LoopbackTLSHandlers: @unchecked Sendable {
    let tap = LoopbackTLSTap()
    let gate: LoopbackHandshakeGate
    private let tls: NIOSSLServerHandler

    var handlers: [ChannelHandler] { [tap, tls, gate] }

    /// Completes with whether the handshake resumed a session, or fails if the
    /// connection ends first.
    var verdict: EventLoopFuture<Bool> { gate.verdict }

    init(
        context: NIOSSLContext, eventLoop: EventLoop,
        onHandshake: @escaping @Sendable (Bool) -> Void
    ) {
        tls = NIOSSLServerHandler(context: context)
        gate = LoopbackHandshakeGate(
            tap: tap, promise: eventLoop.makePromise(of: Bool.self), onHandshake: onHandshake)
    }
}

/// Sits between the TLS handler and the socket and feeds everything the server
/// writes to `TLSResumptionInspector`. Outbound only; it never alters a byte.
final class LoopbackTLSTap: ChannelOutboundHandler, @unchecked Sendable {
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private(set) var inspector = TLSResumptionInspector()

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let buffer = unwrapOutboundIn(data)
        inspector.feed(Array(buffer.readableBytesView))
        context.write(data, promise: promise)
    }
}

/// Turns `TLSUserEvent.handshakeCompleted` into a future and a callback, with
/// the tap's reading of that handshake attached.
final class LoopbackHandshakeGate: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    private let tap: LoopbackTLSTap
    private let promise: EventLoopPromise<Bool>
    private let onHandshake: @Sendable (Bool) -> Void
    private var finished = false

    var verdict: EventLoopFuture<Bool> { promise.futureResult }

    init(
        tap: LoopbackTLSTap, promise: EventLoopPromise<Bool>,
        onHandshake: @escaping @Sendable (Bool) -> Void
    ) {
        self.tap = tap
        self.promise = promise
        self.onHandshake = onHandshake
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let tls = event as? TLSUserEvent, case .handshakeCompleted = tls, !finished {
            finished = true
            let resumed = tap.inspector.verdict == .resumed
            onHandshake(resumed)
            promise.succeed(resumed)
        }
        context.fireUserInboundEventTriggered(event)
    }

    func channelInactive(context: ChannelHandlerContext) {
        fail()
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        fail()
        context.fireErrorCaught(error)
    }

    private func fail() {
        guard !finished else { return }
        finished = true
        promise.fail(ChannelError.ioOnClosedChannel)
    }
}

/// Runs `announce` when the channel becomes active, and not before -- or, if the
/// channel is closed without ever becoming active, when the handler is removed,
/// so whatever the closure hands over is always handed over exactly once.
///
/// A child channel's initializer runs BEFORE the channel is registered with
/// its event loop and active, so a `NIOAsyncChannel` handed to a consumer from
/// inside the initializer can be written to while it is still closed. Measured
/// on 2026-11-05: about 1 data transfer in 30 failed with "I/O on closed
/// channel" on the server's first write (6 failures in 200 runs of the suite),
/// every one on a command whose data connection had only just been accepted.
/// `NIOAsyncChannel`'s own server wrapper yields its children after
/// registration for this reason; this handler is the same ordering for the
/// hand-rolled streams used here, where a listener's connections must outlive
/// one `executeThenClose` scope.
final class LoopbackActivationAnnouncer: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    private var announce: (@Sendable () -> Void)?

    init(_ announce: @escaping @Sendable () -> Void) {
        self.announce = announce
    }

    func channelActive(context: ChannelHandlerContext) {
        runOnce()
        context.fireChannelActive()
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        runOnce()
    }

    private func runOnce() {
        let pending = announce
        announce = nil
        pending?()
    }
}

/// Splits a byte stream into lines at LF and drops the CR before it. A
/// trailing partial line at end of input is discarded, which is what an FTP
/// server does with a command that never ended.
struct CRLFLineDecoder: ByteToMessageDecoder {
    typealias InboundOut = ByteBuffer

    mutating func decode(context: ChannelHandlerContext, buffer: inout ByteBuffer) throws -> DecodingState {
        guard let lineFeed = buffer.readableBytesView.firstIndex(of: 0x0A) else {
            return .needMoreData
        }
        let length = lineFeed - buffer.readerIndex
        guard var line = buffer.readSlice(length: length) else { return .needMoreData }
        buffer.moveReaderIndex(forwardBy: 1)
        if line.readableBytesView.last == 0x0D { line.moveWriterIndex(to: line.writerIndex - 1) }
        context.fireChannelRead(wrapInboundOut(line))
        return .continue
    }

    mutating func decodeLast(
        context: ChannelHandlerContext, buffer: inout ByteBuffer, seenEOF: Bool
    ) throws -> DecodingState {
        .needMoreData
    }
}

// MARK: - One control connection

/// A data connection the server has accepted, and, when the connection is
/// protected, the future that says whether its handshake resumed a session.
struct LoopbackFTPDataConnection: Sendable {
    let channel: NIOAsyncChannel<ByteBuffer, ByteBuffer>
    let handshake: EventLoopFuture<Bool>?
}

/// Traps, with a message that names the cause, when two reads of a
/// single-consumer `AsyncStream` iterator overlap. The iterator types are not
/// `Sendable`, so each reader class below holds one behind `@unchecked
/// Sendable`; this guard is what makes that sound instead of merely
/// compiling (see each class).
final class LoopbackSingleReaderGuard: Sendable {
    private let busy = NIOLockedValueBox(false)

    func enter(_ owner: String) {
        let overlapped = busy.withLockedValue { flag -> Bool in
            let was = flag
            flag = true
            return was
        }
        precondition(!overlapped, "\(owner): two reads overlapped on a single-consumer stream")
    }

    func leave() {
        busy.withLockedValue { $0 = false }
    }

    /// A read is in flight. For the tests that drive an overlap on purpose.
    var isBusy: Bool { busy.withLockedValue { $0 } }
}

/// The listener a `PASV` or `EPSV` opened: one connection is accepted from it.
///
/// **One iterator, owned here.** The connections arrive on an `AsyncStream`,
/// which has a single consumer; `next()` and `discard()` used to each make their
/// own iterator over it, which is the documented way to a runtime trap if the
/// two ever overlap. Both now go through the one stored iterator.
///
/// **Why `@unchecked Sendable` is sound here, and not just needed.** The
/// iterator is the only mutable state, and every access to it is bracketed by
/// `reader`, which traps on overlap. Without it the guarantee would be a
/// convention ("the owning session calls these one after the other"); with it a
/// violation is a named trap instead of a data race on the iterator. The
/// convention still holds: the session that owns the listener is a single task.
final class LoopbackFTPPassiveListener: @unchecked Sendable {
    let channel: Channel
    let port: Int
    private var connections: AsyncStream<LoopbackFTPDataConnection>.Iterator
    private let reader = LoopbackSingleReaderGuard()

    init(channel: Channel, connections: AsyncStream<LoopbackFTPDataConnection>, port: Int) {
        self.channel = channel
        self.connections = connections.makeAsyncIterator()
        self.port = port
    }

    /// A read is in flight. For the tests that drive an overlap on purpose.
    var isReading: Bool { reader.isBusy }

    /// The next connection, or nil once the listener has closed.
    func next() async -> LoopbackFTPDataConnection? {
        reader.enter("passive listener")
        defer { reader.leave() }
        return await connections.next()
    }

    /// Closes the listener and any connection that arrived and was never used.
    func discard() async {
        reader.enter("passive listener")
        defer { reader.leave() }
        _ = try? await awaitCancellably(channel.close())
        while let connection = await connections.next() {
            // Through `executeThenClose`, like every other wrapper: a
            // `NIOAsyncChannel` is consumed that way or it can trap.
            try? await connection.channel.executeThenClose { _, _ in }
        }
    }
}

/// The conversation on one control connection. Confined to the task that
/// serves it; it is a class only so the helper methods can share its state.
final class LoopbackFTPSession: @unchecked Sendable {
    private let configuration: LoopbackFTPServer.Configuration
    private let state: LoopbackFTPState
    private let context: NIOSSLContext?
    private let group: MultiThreadedEventLoopGroup
    private let control: Channel

    private var tlsActive = false
    private var dataProtected = false
    private var username: String?
    private var authenticated = false
    private var workingDirectory = "/"
    private var passive: LoopbackFTPPassiveListener?

    init(
        configuration: LoopbackFTPServer.Configuration, state: LoopbackFTPState,
        context: NIOSSLContext?, group: MultiThreadedEventLoopGroup, control: Channel
    ) {
        self.configuration = configuration
        self.state = state
        self.context = context
        self.group = group
        self.control = control
    }

    func releasePassiveListener() async {
        let listener = passive
        passive = nil
        await listener?.discard()
    }

    private enum Outcome { case keepGoing, end }

    func run(inbound: NIOAsyncChannelInboundStream<ByteBuffer>) async throws {
        tlsActive = configuration.security == .implicitTLS

        let refused = state.box.withLockedValue { inner -> Bool in
            inner.controlConnections += 1
            let armed = inner.refuseNextAcquire
            inner.refuseNextAcquire = false
            return armed
        }
        if refused {
            try await send(421, "Too many connections from this account.")
            return
        }
        try await send(220, "macSCP loopback FTP server ready.")

        var lines = inbound.makeAsyncIterator()
        while let buffer = try await lines.next() {
            let desynchronise = state.box.withLockedValue { inner -> Bool in
                let armed = inner.desynchroniseNextReply
                inner.desynchroniseNextReply = false
                return armed
            }
            let outcome = try await handle(String(buffer: buffer))
            if outcome == .end { return }
            if desynchronise { try await send(200, "Stray reply that answers no command.") }
        }
    }

    // MARK: Writing replies

    private func send(_ code: Int, _ text: String) async throws {
        try await write("\(code) \(text)\r\n")
    }

    private func sendMultiline(_ code: Int, head: String, lines: [String], tail: String) async throws {
        var text = "\(code)-\(head)\r\n"
        for line in lines { text += " \(line)\r\n" }
        text += "\(code) \(tail)\r\n"
        try await write(text)
    }

    /// Writes straight to the channel and waits for the write to leave the
    /// socket buffer. Not through `NIOAsyncChannelOutboundWriter`, whose
    /// `write` returns once the bytes are queued: a reply followed at once by
    /// the end of the session (`421`, `221`) was closed out from under its own
    /// write and the client saw a bare end of stream. Measured: 1 failure in 6
    /// runs of the `421` test before this, 0 in the runs after.
    private func write(_ text: String) async throws {
        try await awaitCancellably(control.writeAndFlush(ByteBuffer(string: text)))
    }

    // MARK: Commands

    private func handle(_ line: String) async throws -> Outcome {
        let split = line.firstIndex(of: " ")
        let verb = String((split.map { line[..<$0] } ?? line[...])).uppercased()
        let argument = split.map { String(line[line.index(after: $0)...]) } ?? ""
        let overTLS = tlsActive
        state.box.withLockedValue {
            $0.commands.append(
                .init(
                    verb: verb,
                    argument: verb == "PASS" ? LoopbackFTPReceivedCommand.redactedArgument : argument,
                    overTLS: overTLS))
        }

        let loginExempt: Set<String> = [
            "USER", "PASS", "AUTH", "PBSZ", "PROT", "FEAT", "OPTS", "SYST", "NOOP", "QUIT",
        ]
        if !authenticated, !loginExempt.contains(verb) {
            try await send(530, "Please login with USER and PASS.")
            return .keepGoing
        }

        switch verb {
        case "USER":
            if configuration.security == .explicitTLS, !tlsActive {
                try await send(530, "Login requires TLS: issue AUTH TLS first.")
            } else {
                username = argument
                try await send(331, "Password required.")
            }
        case "PASS":
            try await handlePassword(argument)
        case "AUTH":
            try await handleAuth(argument)
        case "PBSZ":
            if tlsActive {
                try await send(200, "PBSZ=0")
            } else {
                try await send(503, "PBSZ needs a protected control connection.")
            }
        case "PROT":
            try await handleProtection(argument)
        case "FEAT":
            try await sendMultiline(211, head: "Features:", lines: featureLines(), tail: "End")
        case "OPTS":
            if argument.uppercased() == "UTF8 ON" {
                try await send(200, "UTF8 mode on.")
            } else {
                try await send(501, "Option not understood.")
            }
        case "SYST":
            try await send(215, "UNIX Type: L8")
        case "TYPE":
            try await send(200, "Type set.")
        case "NOOP":
            try await send(200, "NOOP ok.")
        case "QUIT":
            try await send(221, "Goodbye.")
            return .end
        case "PWD", "XPWD":
            try await send(257, "\"\(workingDirectory)\" is the current directory.")
        case "CWD", "XCWD":
            let target = resolve(argument)
            if state.box.withLockedValue({ $0.directories.contains(target) }) {
                workingDirectory = target
                try await send(250, "Directory changed.")
            } else {
                try await send(550, "No such directory.")
            }
        case "CDUP":
            workingDirectory = resolve("..")
            try await send(250, "Directory changed.")
        case "SIZE":
            if let size = state.box.withLockedValue({ $0.files[resolve(argument)]?.count }) {
                try await send(213, "\(size)")
            } else {
                try await send(550, "No such file.")
            }
        case "DELE":
            let removed = state.box.withLockedValue { $0.files.removeValue(forKey: resolve(argument)) != nil }
            try await send(removed ? 250 : 550, removed ? "File removed." : "No such file.")
        case "MKD", "XMKD":
            let path = resolve(argument)
            let created = state.box.withLockedValue { inner -> Bool in
                guard !inner.directories.contains(path), inner.files[path] == nil,
                    inner.directories.contains((path as NSString).deletingLastPathComponent)
                else { return false }
                inner.directories.insert(path)
                return true
            }
            try await send(created ? 257 : 550, created ? "\"\(path)\" created." : "Cannot create directory.")
        case "RMD", "XRMD":
            let path = resolve(argument)
            let removed = state.box.withLockedValue { inner -> Bool in
                guard path != "/", inner.directories.contains(path) else { return false }
                let prefix = path + "/"
                guard !inner.files.keys.contains(where: { $0.hasPrefix(prefix) }),
                    !inner.directories.contains(where: { $0.hasPrefix(prefix) })
                else { return false }
                inner.directories.remove(path)
                return true
            }
            try await send(removed ? 250 : 550, removed ? "Directory removed." : "Cannot remove directory.")
        case "PASV":
            try await handlePassive(extended: false)
        case "EPSV":
            try await handlePassive(extended: true)
        case "LIST", "NLST", "RETR", "STOR":
            return try await handleTransfer(verb: verb, argument: argument)
        case "MLSD" where configuration.advertisesMLSD:
            return try await handleTransfer(verb: verb, argument: argument)
        default:
            try await send(500, "Unknown command.")
        }
        return .keepGoing
    }

    private func featureLines() -> [String] {
        var lines = ["UTF8", "SIZE"]
        if configuration.advertisesMLSD {
            lines.append("MLST type*;size*;modify*;")
            lines.append("MLSD")
        }
        switch configuration.security {
        case .plain: break
        case .explicitTLS: lines += ["AUTH TLS", "PBSZ", "PROT"]
        case .implicitTLS: lines += ["PBSZ", "PROT"]
        }
        return lines
    }

    private func handlePassword(_ argument: String) async throws {
        if configuration.security == .explicitTLS, !tlsActive {
            try await send(530, "Login requires TLS: issue AUTH TLS first.")
            return
        }
        guard let username else {
            try await send(503, "Login with USER first.")
            return
        }
        let accepted =
            username == configuration.credentials.username
            && argument == configuration.credentials.password
        authenticated = accepted
        if accepted {
            try await send(230, "Login successful.")
        } else {
            try await send(530, "Login incorrect.")
        }
    }

    private func handleProtection(_ level: String) async throws {
        guard tlsActive else {
            try await send(503, "PROT needs a protected control connection.")
            return
        }
        switch level.uppercased() {
        case "P":
            dataProtected = true
            try await send(200, "Data connections will be protected.")
        case "C":
            dataProtected = false
            try await send(200, "Data connections will be clear.")
        default:
            try await send(504, "Protection level not supported.")
        }
    }

    // MARK: TLS upgrade

    private func handleAuth(_ mechanism: String) async throws {
        let wanted = mechanism.uppercased()
        guard configuration.security == .explicitTLS, wanted == "TLS" || wanted == "TLS-C" else {
            try await send(configuration.security == .plain ? 502 : 504, "AUTH not available.")
            return
        }
        guard !tlsActive, let context else {
            try await send(503, "Already protected.")
            return
        }

        let state = self.state
        let tls = LoopbackTLSHandlers(
            context: context, eventLoop: control.eventLoop,
            onHandshake: { resumed in
                state.box.withLockedValue {
                    $0.handshakes.append(.init(connection: .control, resumed: resumed))
                }
            })
        let channel = control
        let acknowledgement = ByteBuffer(string: "234 Proceed with the TLS handshake.\r\n")
        // The reply must leave the socket in the clear and the TLS handler
        // must already be in the pipeline when the client's first handshake
        // bytes arrive. Adding the handler from the write's own completion
        // callback does both on the event loop, in one step; adding it after
        // an `await` could let the ClientHello reach the line decoder first.
        try await awaitCancellably(
            channel.eventLoop.flatSubmit {
                channel.writeAndFlush(acknowledgement).flatMapThrowing {
                    try channel.pipeline.syncOperations.addHandlers(tls.handlers, position: .first)
                }
            })
        tlsActive = true
    }

    // MARK: Passive mode

    private func handlePassive(extended: Bool) async throws {
        await releasePassiveListener()
        let listener = try await openPassiveListener()
        passive = listener
        if extended {
            try await send(229, "Entering Extended Passive Mode (|||\(listener.port)|)")
        } else {
            let host = state.box.withLockedValue { $0.pasvHost } ?? "127.0.0.1"
            let address = host.replacingOccurrences(of: ".", with: ",")
            try await send(
                227,
                "Entering Passive Mode (\(address),\(listener.port >> 8),\(listener.port & 0xFF)).")
        }
    }

    private func openPassiveListener() async throws -> LoopbackFTPPassiveListener {
        let (connections, continuation) = AsyncStream.makeStream(of: LoopbackFTPDataConnection.self)
        let context = dataProtected ? self.context : nil
        let state = self.state
        let channel = try await awaitCancellably(
            ServerBootstrap(group: group)
                .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                .childChannelInitializer { channel in
                    channel.eventLoop.makeCompletedFuture {
                        guard state.track(channel) else { return }
                        var handshake: EventLoopFuture<Bool>?
                        if let context {
                            let tls = LoopbackTLSHandlers(
                                context: context, eventLoop: channel.eventLoop,
                                onHandshake: { resumed in
                                    state.box.withLockedValue {
                                        $0.handshakes.append(.init(connection: .data, resumed: resumed))
                                    }
                                })
                            try channel.pipeline.syncOperations.addHandlers(tls.handlers)
                            handshake = tls.verdict
                        }
                        let wrapped = try NIOAsyncChannel<ByteBuffer, ByteBuffer>(
                            wrappingChannelSynchronously: channel)
                        let connection = LoopbackFTPDataConnection(channel: wrapped, handshake: handshake)
                        try channel.pipeline.syncOperations.addHandler(
                            LoopbackActivationAnnouncer {
                                LoopbackFTPServer.hand(connection, to: continuation, state: state)
                            })
                    }
                }
                .bind(host: "127.0.0.1", port: 0))
        state.track(channel)
        channel.closeFuture.whenComplete { _ in continuation.finish() }
        guard let port = channel.localAddress?.port else {
            _ = try? await awaitCancellably(channel.close())
            throw LoopbackFTPServerError.noLocalPort
        }
        return LoopbackFTPPassiveListener(channel: channel, connections: connections, port: port)
    }

    // MARK: Transfers

    private func handleTransfer(verb: String, argument: String) async throws -> Outcome {
        guard let listener = passive else {
            try await send(425, "Use PASV or EPSV first.")
            return .keepGoing
        }
        passive = nil

        // `require_ssl_reuse` is paired with protected data (see the
        // `requiresTLSSessionReuse` parameter): clear data is refused, so the
        // seam cannot be skipped by never issuing `PROT P`.
        if configuration.requiresTLSSessionReuse, !dataProtected {
            await listener.discard()
            try await send(522, "Data connections must be encrypted.")
            return .keepGoing
        }

        // Everything that can be refused is refused before the data
        // connection is used, so a refused command never sends `150`.
        let path = resolve(argument)
        var payload = Data()
        switch verb {
        case "RETR":
            guard let content = state.box.withLockedValue({ $0.files[path] }) else {
                await listener.discard()
                try await send(550, "No such file.")
                return .keepGoing
            }
            payload = content
        case "STOR":
            let parent = (path as NSString).deletingLastPathComponent
            guard state.box.withLockedValue({ $0.directories.contains(parent) }) else {
                await listener.discard()
                try await send(550, "No such directory.")
                return .keepGoing
            }
        default:
            let directory = argument.isEmpty || argument.hasPrefix("-") ? workingDirectory : path
            guard state.box.withLockedValue({ $0.directories.contains(directory) }) else {
                await listener.discard()
                try await send(550, "No such directory.")
                return .keepGoing
            }
            payload = listing(of: directory, verb: verb)
        }

        let arrived = await listener.next()
        await listener.discard()
        guard let data = arrived else {
            try await send(425, "Cannot open the data connection.")
            return .keepGoing
        }

        if let handshake = data.handshake {
            let resumed: Bool
            do {
                resumed = try await awaitCancellably(handshake)
            } catch {
                try? await data.channel.executeThenClose { _, _ in }
                try await send(425, "The TLS handshake on the data connection failed.")
                return .keepGoing
            }
            if configuration.requiresTLSSessionReuse, !resumed {
                state.box.withLockedValue { $0.refusedDataConnections += 1 }
                try? await data.channel.executeThenClose { _, _ in }
                try await send(522, "SSL connection failed; session reuse required.")
                return .keepGoing
            }
        }

        try await send(150, "Opening the data connection.")

        let drop = state.box.withLockedValue { inner -> Bool in
            let armed = inner.dropNextTransfer
            inner.dropNextTransfer = false
            return armed
        }
        let control = self.control

        if verb == "STOR" {
            var received = Data()
            try await data.channel.executeThenClose { inbound, _ in
                for try await chunk in inbound {
                    received.append(contentsOf: chunk.readableBytesView)
                    if drop { break }
                }
            }
            if drop {
                _ = try? await awaitCancellably(control.close())
                return .end
            }
            state.box.withLockedValue { $0.files[path] = received }
        } else {
            let dataChannel = data.channel.channel
            try await data.channel.executeThenClose { _, _ in
                // Waits for the bytes to leave the socket buffer before the
                // scope closes the channel, for the reason `write(_:)` gives.
                if drop {
                    try await awaitCancellably(
                        dataChannel.writeAndFlush(ByteBuffer(bytes: payload.prefix(payload.count / 2))))
                    _ = try? await awaitCancellably(control.close())
                } else {
                    try await awaitCancellably(dataChannel.writeAndFlush(ByteBuffer(bytes: payload)))
                }
            }
            if drop { return .end }
        }
        try await send(226, "Transfer complete.")
        return .keepGoing
    }

    // MARK: Paths and listings

    private func resolve(_ argument: String) -> String {
        let combined = argument.hasPrefix("/") ? argument : workingDirectory + "/" + argument
        var parts: [Substring] = []
        for part in combined.split(separator: "/", omittingEmptySubsequences: true) {
            if part == "." { continue }
            if part == ".." {
                _ = parts.popLast()
            } else {
                parts.append(part)
            }
        }
        return "/" + parts.joined(separator: "/")
    }

    /// The entries directly inside `directory`, as `LIST`, `NLST` or `MLSD`
    /// would write them. Bytes, not a `String`, because that is what a data
    /// connection carries and what `FTPListParser` takes.
    private func listing(of directory: String, verb: String) -> Data {
        let prefix = directory == "/" ? "/" : directory + "/"
        let entries = state.box.withLockedValue { inner -> [(name: String, size: Int?)] in
            var result: [(String, Int?)] = []
            for path in inner.directories where path != directory && path.hasPrefix(prefix) {
                let rest = path.dropFirst(prefix.count)
                if !rest.contains("/") { result.append((String(rest), nil)) }
            }
            for (path, content) in inner.files where path.hasPrefix(prefix) {
                let rest = path.dropFirst(prefix.count)
                if !rest.contains("/") { result.append((String(rest), content.count)) }
            }
            return result.sorted { $0.0 < $1.0 }
        }
        var text = ""
        for entry in entries {
            switch verb {
            case "NLST":
                text += "\(entry.name)\r\n"
            case "MLSD":
                if let size = entry.size {
                    text += "type=file;size=\(size);modify=20260101000000; \(entry.name)\r\n"
                } else {
                    text += "type=dir;modify=20260101000000; \(entry.name)\r\n"
                }
            default:
                if let size = entry.size {
                    text += "-rw-r--r--   1 ftp      ftp      \(size) Jan  1  2026 \(entry.name)\r\n"
                } else {
                    text += "drwxr-xr-x   2 ftp      ftp         4096 Jan  1  2026 \(entry.name)\r\n"
                }
            }
        }
        return Data(text.utf8)
    }
}
