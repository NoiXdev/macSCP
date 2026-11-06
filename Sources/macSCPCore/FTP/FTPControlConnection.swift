import Foundation
import NIOCore
import NIOPosix
import NIOSSL
import NIOTLS
import Security
import Synchronization
import os

/// The decider an unknown server certificate is put to.
///
/// WebDAV's type, aliased rather than re-declared: it is the same question —
/// a fingerprint a person compares against the server's own admin page — and
/// the app already composes one for the certificate prompt. A second type
/// would mean a second prompt wiring for the same decision.
typealias CertificateDecider = WebDAVSessionDelegate.CertificateDecider

/// Why an FTP control or data connection could not be opened, or could not
/// carry on.
///
/// **No case carries server text, a path or a credential.** A reply code is
/// the most any of them holds. The control channel this travels beside
/// carries `PASS`, some servers quote the client's command line back in their
/// replies, and the default description of an error prints its payload
/// verbatim — so what is not in the value cannot leak from it. The sentence a
/// user reads comes from `message`, which is this project's own text, in four
/// languages.
enum FTPConnectionFailure: Error, Equatable, Sendable {
    /// The greeting was not a positive reply — a `421` from a server that is
    /// full, or out of hours. `code` is the reply code.
    case greetingRefused(code: Int)
    /// Nothing that would end a wait arrived within the dial's own timeout.
    case timedOut
    /// The peer closed, or the transport failed, before the exchange
    /// finished. The two are one case on purpose: at FTP level both mean the
    /// control connection has ended, and telling them apart would mean
    /// carrying the transport's own words.
    case connectionClosed
    /// A line arrived that cannot be part of a reply, so the stream can no
    /// longer be read against the commands sent.
    case protocolViolation
    /// `AUTH TLS`, or the `PROT P` that follows it, was refused. There is no
    /// plaintext fallback: a connection the user asked to protect is not
    /// continued in the clear.
    case tlsUpgradeRefused(code: Int)
    /// The TLS handshake did not complete, for a reason that is not one of
    /// the certificate cases below.
    case tlsHandshakeFailed
    /// The login was refused.
    case loginRefused
    /// The certificate was declined — by the decider, or because the chain
    /// could not be read at all.
    case certificateRejected
    /// A remembered certificate and the presented one differ. A hard stop
    /// with no override, the same contract `HostKeyError.mismatch` has.
    case certificateMismatch
    /// The trusted-certificate store could not be read. Distinct from
    /// `certificateRejected` so nothing reports a refusal the user never
    /// made.
    case trustStoreUnreadable
    /// A data connection performing a FULL handshake presented certificate
    /// material that is not its control connection's, byte for byte
    /// (Ruling T5.1).
    case dataCertificateDiffers
    /// A TLS session was offered to a connection that does not belong to the
    /// control connection that established it. macSCP's own guard: the TLS
    /// library cannot make this comparison for a peer named by address.
    case sessionFromAnotherConnection
    /// The TLS library refused the session this connection offered.
    ///
    /// **Mapped, never surfaced.** `NIOSSLExtraError`'s own description for
    /// `cannotResumeSessionForDifferentServerHostname` embeds BOTH peer
    /// hostnames, and the type is `CustomStringConvertible`, so anything that
    /// logged or displayed it would print two peer-identifying strings. Four
    /// existing upstream descriptions do the same, which is why this mapping
    /// is macSCP's obligation rather than the fork's bug.
    case sessionRefusedByTLS

    /// This failure's catalog key, DERIVED from the case. A case added
    /// without its four catalog entries is caught by
    /// `everyConnectionFailureHasItsOwnSentence`; the lookup itself cannot
    /// fail loudly, since `CoreL10n.string` falls back to the key text.
    var messageKey: String {
        switch self {
        case .greetingRefused: "core.connect.ftpGreetingRefused"
        case .timedOut: "core.connect.ftpTimedOut"
        case .connectionClosed: "core.connect.ftpConnectionClosed"
        case .protocolViolation: "core.connect.ftpProtocolViolation"
        case .tlsUpgradeRefused: "core.connect.ftpTLSRequired"
        case .tlsHandshakeFailed: "core.connect.ftpTLSHandshakeFailed"
        // Not an FTP-specific sentence: a refused login reads the same
        // whichever protocol carried it, and this key already says it.
        case .loginRefused: "core.connect.authFailed"
        case .certificateRejected: "core.connect.ftpCertificateRejected"
        case .certificateMismatch: "core.connect.ftpCertificateMismatch"
        case .trustStoreUnreadable: "core.connect.ftpTrustStoreUnreadable"
        case .dataCertificateDiffers: "core.connect.ftpDataCertificateDiffers"
        case .sessionFromAnotherConnection: "core.connect.ftpSessionScope"
        case .sessionRefusedByTLS: "core.connect.ftpSessionRefused"
        }
    }

    /// The localized sentence for this failure.
    var message: String { CoreL10n.string(messageKey) }
}

/// One FTP control connection: the socket, the greeting, the login, `FEAT`,
/// `TYPE I`, both TLS forms, and the `NOOP` that keeps an idle session from
/// being reaped.
///
/// **Commands are serialised, and there is one place that writes one.**
/// `send(_:argument:)` takes a turn before it writes and gives it up after
/// its reply, so a reply can never be read against the wrong command — an
/// actor alone does not buy that, since it is re-entrant at every `await`.
/// The line itself is built by `commandLine(_:argument:)`, the only function
/// here that spells a command terminator, and it takes both the verb and the
/// argument through `FTPPath.validated(_:)`
/// (`FTPControlConnectionTests.exactlyOnePlaceWritesACommandLine`).
///
/// **The password is one of those arguments**, which is deliberate: a
/// credential carrying CR LF would inject a command exactly as a file name
/// would, and it is refused by the same check, with the same refusal, which
/// names a character class and never the text.
actor FTPControlConnection {
    /// Which control connection this is. The scope a TLS session belongs to:
    /// a session established here is offered only to data connections opened
    /// for THIS identity (see `openDataConnection(host:port:protection:owner:timeout:)`).
    struct Identity: Hashable, Sendable {
        private let raw = UUID()
    }

    /// The dial's dials. Separate from `FTPConnectionConfig`, which is the
    /// user's configuration; these are this layer's own numbers, and they
    /// exist as a parameter so a test can shorten one without a clock.
    struct Tuning: Sendable {
        /// How long a connection may be idle before `NOOP` is sent. Zero or
        /// less switches the keepalive off.
        var keepaliveInterval: Duration

        init(keepaliveInterval: Duration = .seconds(30)) {
            self.keepaliveInterval = keepaliveInterval
        }

        static let `default` = Tuning()
    }

    /// Everything ONE control connection's data connections need in order to
    /// protect themselves, and nothing another control connection could use.
    ///
    /// Ruling T5.1: a data connection that resumes `session` inherits the
    /// trust decision of the handshake that established it, which is correct
    /// — it is the same peer, vouched for once. A data connection that
    /// performs a FULL handshake has to present `controlCertificateDER` byte
    /// for byte, and asks nobody if it does not.
    struct DataProtection: Sendable {
        let owner: Identity
        /// The very context that established `session`. The library refuses
        /// a session offered on any other.
        let context: NIOSSLContext
        /// The SNI name the control connection sent — `nil` for a peer named
        /// by address, since an IP literal may not go in SNI.
        let serverHostname: String?
        /// The DER the control connection's own handshake accepted.
        let controlCertificateDER: [UInt8]
        /// A session to offer, or `nil` — then the handshake is a full one
        /// and the comparison above is what guards it.
        let session: NIOSSLSession?
        /// Where `session` is returned once the connection holding it has
        /// closed, so the next data connection of this control connection can
        /// be offered it. `nil` when no session is offered.
        let vault: FTPSessionVault?
    }

    nonisolated let identity = Identity()

    private let channel: Channel
    private let lines: FTPLineSource
    private let deliver: AsyncStream<ByteBuffer>.Continuation
    private let events: FTPChannelEvents
    private let trust: FTPTrustDecision
    private let tlsContext: NIOSSLContext?
    private let serverHostname: String?
    private let timeout: Duration
    private let replyBound: TimeAmount

    /// This control connection's TLS sessions, and which of them a data
    /// connection is holding right now. Scoped to this connection: see
    /// `openDataConnection(host:port:protection:owner:timeout:)`.
    private let vault = FTPSessionVault()

    private var featureSet: Set<String> = []
    private var dataProtected = false
    private var commandInFlight = false
    private var waitingOrder: [UUID] = []
    private var waiting: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var keepalive: Task<Void, Never>?
    private var lastActivity = ContinuousClock.now
    private var isClosed = false

    private static let logger = Logger(subsystem: "dev.noix.macscp", category: "FTPControlConnection")

    private init(
        channel: Channel, lines: FTPLineSource, deliver: AsyncStream<ByteBuffer>.Continuation,
        events: FTPChannelEvents, trust: FTPTrustDecision, tlsContext: NIOSSLContext?,
        serverHostname: String?, timeout: Duration
    ) {
        self.channel = channel
        self.lines = lines
        self.deliver = deliver
        self.events = events
        self.trust = trust
        self.tlsContext = tlsContext
        self.serverHostname = serverHostname
        self.timeout = timeout
        self.replyBound = Self.timeAmount(timeout)
    }

    // MARK: - Dialling

    /// Opens a control connection, protects it as `config.security` asks,
    /// logs in, reads `FEAT` and sets binary mode.
    ///
    /// **`password` is the credential that is sent, and `config.password` is
    /// not read.** The two exist because the plan's interface says so; a
    /// caller that fills in only one fills in this one. A config built with
    /// an empty password and a real `password` argument is the shape the
    /// tests use, and it is the shape to prefer: a value type that never held
    /// the secret cannot print it.
    ///
    /// `timeout` bounds every wait the dial performs — the TCP connect, each
    /// reply, and each TLS handshake — rather than the dial as a whole, so
    /// nothing here can park past it waiting on a future that answers no
    /// cancellation.
    ///
    /// `trustStore` is where a certificate is looked up and remembered.
    /// Without one, every certificate is unknown to this layer and the
    /// decider is asked every time: `.mismatch`, this project's hard stop,
    /// cannot fire for a host nothing was ever pinned for.
    static func connect(
        _ config: FTPConnectionConfig,
        password: String,
        certificateDecider: CertificateDecider,
        timeout: Duration,
        trustStore: TrustedCertificateStore? = nil,
        tuning: Tuning = .default
    ) async throws -> FTPControlConnection {
        let host = config.host
        let port = config.port > 0 ? config.port : config.security.defaultPort
        let serverHostname = Self.sniName(for: host)
        let events = FTPChannelEvents()
        let (stream, continuation) = AsyncStream.makeStream(of: ByteBuffer.self)
        let trust = FTPTrustDecision(
            host: host, port: port, decider: certificateDecider, trustStore: trustStore)
        let tlsContext = config.security == .plain ? nil : try Self.clientContext()
        let wrapImmediately = config.security == .implicitTLS
        let verify = trust.verification

        let channel: Channel
        do {
            channel = try await ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
                .connectTimeout(Self.timeAmount(timeout))
                .channelInitializer { channel in
                    channel.eventLoop.makeCompletedFuture {
                        let pipeline = channel.pipeline.syncOperations
                        if wrapImmediately, let tlsContext {
                            try pipeline.addHandler(
                                NIOSSLClientHandler(
                                    context: tlsContext, serverHostname: serverHostname,
                                    customVerificationCallback: verify.callback))
                        }
                        try pipeline.addHandler(ByteToMessageHandler(FTPLineDecoder()))
                        try pipeline.addHandler(
                            FTPChannelSink(deliver: continuation, events: events))
                    }
                }
                .connect(host: host, port: port).get()
        } catch {
            continuation.finish()
            throw Self.dialFailure(error)
        }

        let connection = FTPControlConnection(
            channel: channel, lines: FTPLineSource(stream), deliver: continuation, events: events,
            trust: trust, tlsContext: tlsContext, serverHostname: serverHostname, timeout: timeout)
        do {
            try await connection.handshakeAndLogin(
                security: config.security, username: config.username, password: password,
                tuning: tuning)
        } catch {
            await connection.close()
            throw error
        }
        return connection
    }

    /// The conversation `connect` is: wrap, greet, upgrade, log in, ask.
    private func handshakeAndLogin(
        security: FTPSecurityMode, username: String, password: String, tuning: Tuning
    ) async throws {
        if security == .implicitTLS { try await awaitHandshake() }

        let greeting = try await readReply()
        guard greeting.isPositive else {
            throw FTPConnectionFailure.greetingRefused(code: greeting.code)
        }

        if security == .explicitTLS {
            let auth = try await send("AUTH", argument: "TLS")
            guard auth.isPositive else {
                throw FTPConnectionFailure.tlsUpgradeRefused(code: auth.code)
            }
            try await startTLS()
            try await awaitHandshake()
        }

        if security != .plain {
            // `PBSZ 0` then `PROT P`, in that order (RFC 4217 section 9): the
            // buffer size is negotiated before the protection level, and a
            // server that refuses either leaves the data connections in the
            // clear, which is not what the user asked for.
            _ = try await send("PBSZ", argument: "0")
            let protection = try await send("PROT", argument: "P")
            guard protection.isPositive else {
                throw FTPConnectionFailure.tlsUpgradeRefused(code: protection.code)
            }
            dataProtected = true
        }

        let user = try await send("USER", argument: username)
        guard user.isPositive else { throw FTPConnectionFailure.loginRefused }
        // `230` is "logged in already" — an anonymous server that wants no
        // password. Anything else positive is a request for one.
        if user.code != 230 {
            let accepted = try await send("PASS", argument: password)
            guard accepted.isPositive else { throw FTPConnectionFailure.loginRefused }
        }

        featureSet = Self.features(of: try await send("FEAT", argument: nil))
        // Binary, once, and never `TYPE A`: a text-mode transfer rewrites
        // line endings, which corrupts every file that is not text.
        _ = try await send("TYPE", argument: "I")

        startKeepalive(tuning.keepaliveInterval)
    }

    // MARK: - Commands

    /// What `FEAT` advertised, or an empty set before the dial has asked.
    var features: Set<String> { featureSet }

    /// Sends one command and returns its reply.
    ///
    /// Serialised: the caller takes a turn, writes, reads one reply and gives
    /// the turn up. Waiters are released in arrival order, each exactly once.
    ///
    /// `argument` crosses `FTPPath.validated(_:)` and so does `command`;
    /// a refusal is thrown as `FTPPathRefusal` before anything is written, so
    /// the wire never sees it.
    func send(_ command: String, argument: String? = nil) async throws -> FTPReply {
        let line = try Self.commandLine(command, argument: argument)
        await acquire()
        defer { release() }
        lastActivity = .now
        do {
            try await channel.writeAndFlush(ByteBuffer(string: line)).get()
        } catch {
            throw FTPConnectionFailure.connectionClosed
        }
        let reply = try await readReply()
        lastActivity = .now
        return reply
    }

    /// The SECOND reply of a transfer command: `LIST`, `RETR` and `STOR`
    /// answer `150` when the data connection opens and `226` when it has
    /// closed, and the bytes move in between.
    ///
    /// Its own method rather than a flag on `send`, because the two replies
    /// are separated by work the caller does (draining the data connection),
    /// and a `send` that waited for both would hold the turn across it.
    func readFurtherReply() async throws -> FTPReply {
        await acquire()
        defer { release() }
        let reply = try await readReply()
        lastActivity = .now
        return reply
    }

    /// The ONE place a command line is built, and the only function here that
    /// spells a command terminator.
    ///
    /// Both halves go through `FTPPath.validated(_:)`. The verb is this
    /// file's own text today, and it is validated anyway: a choke point that
    /// only checks the arguments is a choke point with a second entrance.
    private static func commandLine(_ command: String, argument: String?) throws -> String {
        var line = try FTPPath.validated(command)
        if let argument { line += " " + (try FTPPath.validated(argument)) }
        return line + "\r\n"
    }

    /// Reads one complete reply, joining a multiline one.
    ///
    /// Bounded by a task on the channel's own event loop that finishes the
    /// line stream, not by a clock this function watches: a wait that outlasts
    /// the dial's timeout ends as `timedOut` instead of parking whoever is
    /// awaiting it.
    private func readReply() async throws -> FTPReply {
        let events = self.events
        let deliver = self.deliver
        let timer = channel.eventLoop.scheduleTask(in: replyBound) {
            events.noteEnd(.timedOut)
            deliver.finish()
        }
        defer { timer.cancel() }

        var partial: [String] = []
        while let buffer = await lines.next() {
            do {
                if let reply = try FTPReplyAccumulator.feed(String(buffer: buffer), into: &partial) {
                    return reply
                }
            } catch {
                throw FTPConnectionFailure.protocolViolation
            }
        }
        throw events.end == .timedOut
            ? FTPConnectionFailure.timedOut : FTPConnectionFailure.connectionClosed
    }

    /// The features of a `FEAT` reply.
    ///
    /// Keyed twice on purpose: by the whole line and by its first word, so
    /// both questions a caller asks are answerable — `features.contains("MLSD")`
    /// and `features.contains("AUTH TLS")`. Uppercased, because RFC 2389
    /// section 3 makes feature names case-insensitive. The first and last
    /// lines of the reply are the human text around the list ("Features:",
    /// "End") and are not features.
    private static func features(of reply: FTPReply) -> Set<String> {
        var found: Set<String> = []
        for line in reply.lines.dropFirst().dropLast() {
            let text = line.trimmingCharacters(in: .whitespaces).uppercased()
            guard !text.isEmpty else { continue }
            found.insert(text)
            if let verb = text.split(separator: " ").first { found.insert(String(verb)) }
        }
        return found
    }

    // MARK: - The turn

    private func acquire() async {
        if !commandInFlight {
            commandInFlight = true
            return
        }
        let identifier = UUID()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            waiting[identifier] = continuation
            waitingOrder.append(identifier)
        }
    }

    private func release() {
        guard let next = waitingOrder.first else {
            commandInFlight = false
            return
        }
        waitingOrder.removeFirst()
        waiting.removeValue(forKey: next)?.resume()
    }

    // MARK: - TLS

    /// Adds the TLS handler to an established, cleartext pipeline — what
    /// `AUTH TLS` is, and the reason this backend is on NIO at all.
    ///
    /// The handler goes at the head, nearest the socket, so the line decoder
    /// above it sees decrypted bytes. It is built inside the event loop's own
    /// submission: a `ChannelHandler` is not `Sendable`, and this is the
    /// shape that hands one to a pipeline without carrying it across a
    /// concurrency boundary.
    private func startTLS() async throws {
        guard let tlsContext else { throw FTPConnectionFailure.tlsHandshakeFailed }
        let channel = self.channel
        let serverHostname = self.serverHostname
        let verify = trust.verification
        do {
            try await channel.eventLoop.submit {
                let handler = try NIOSSLClientHandler(
                    context: tlsContext, serverHostname: serverHostname,
                    customVerificationCallback: verify.callback)
                try channel.pipeline.syncOperations.addHandler(handler, position: .first)
            }.get()
        } catch {
            throw Self.dialFailure(error)
        }
    }

    /// Waits for the handshake this connection is in the middle of, and
    /// reports the precise reason when it does not complete: a refused or
    /// mismatched certificate is the trust decision's answer, not a generic
    /// handshake failure.
    private func awaitHandshake() async throws {
        switch await events.awaitHandshake(timeout: timeout) {
        case .some(true):
            return
        case .some(false):
            if let failure = trust.failure { throw failure }
            throw FTPConnectionFailure.tlsHandshakeFailed
        case .none:
            if let failure = trust.failure { throw failure }
            throw FTPConnectionFailure.timedOut
        }
    }

    /// A client context for FTPS.
    ///
    /// `certificateVerification` is `.noHostnameVerification`, and the two
    /// halves of that are separate decisions.
    ///
    /// It is not `.none`: the custom verification callback is NOT used when
    /// verification is off, so turning verification "off" would turn the
    /// trust decision off with it.
    ///
    /// It is not `.fullVerification` either, because that one re-checks the
    /// hostname AFTER the callback has accepted the certificate, and a peer
    /// named by address has no name to check: measured 2026-11-06 against the
    /// loopback server, where the dial failed with
    /// `NIOSSLExtraError.failedToValidateHostname: Couldn't find <none> in
    /// certificate from peer` while the decider had already said yes. An IP
    /// literal cannot be sent in SNI, so `serverHostname` is `nil` for every
    /// FTPS server reached by address, and under full verification none of
    /// them could connect.
    ///
    /// What the trust decision rests on instead is the fingerprint, which is
    /// the identity TOFU compares — the same one `HostKeyValidation` uses for
    /// a host key, and a stronger statement about this peer than a name in a
    /// certificate it also chose.
    ///
    /// **What this does not do, named rather than left for a reader to
    /// discover:** the callback replaces the chain check outright, so a
    /// publicly-trusted FTPS certificate is treated exactly like a
    /// self-signed one — unknown, and put to the decider. WebDAV's path
    /// differs here, because `URLSession` validates the chain first and only
    /// asks when that fails.
    private static func clientContext() throws -> NIOSSLContext {
        var configuration = TLSConfiguration.makeClientConfiguration()
        configuration.minimumTLSVersion = .tlsv12
        configuration.certificateVerification = .noHostnameVerification
        return try NIOSSLContext(configuration: configuration)
    }

    // MARK: - Data connections

    /// The protection this control connection's next data connection must
    /// use, or `nil` when the data connections are in the clear (`PROT P` was
    /// never issued, or this is plain FTP).
    ///
    /// **The sessions are read HERE and not at handshake completion.** Under
    /// TLS 1.3 the peer issues them in `NewSessionTicket` messages after the
    /// handshake, so `establishedTLSSessions` is normally empty when the
    /// handshake-completed event fires and fills in as those messages are
    /// read. By the time a data connection is wanted, at least one reply has
    /// been read since the handshake, and TLS records are processed in order.
    ///
    /// Which session, and why one can come round again, is
    /// `FTPSessionVault`'s: a session is held by at most one data connection
    /// at a time, and is offered again once that connection has closed.
    func dataProtection() async -> DataProtection? {
        guard dataProtected, let tlsContext,
            let accepted = trust.acceptedCertificateDER
        else { return nil }
        let sessions = (try? await channel.nioSSL_establishedTLSSessions().get()) ?? []
        let offer = vault.checkOut(from: sessions)
        return DataProtection(
            owner: identity, context: tlsContext, serverHostname: serverHostname,
            controlCertificateDER: accepted, session: offer,
            vault: offer == nil ? nil : vault)
    }

    /// Opens a data connection for THIS control connection, with this
    /// connection's own protection.
    func openDataConnection(host: String, port: Int) async throws -> FTPDataChannel {
        try await Self.openDataConnection(
            host: host, port: port, protection: await dataProtection(), owner: identity,
            timeout: timeout)
    }

    /// Opens a data connection, refusing a protection that belongs to another
    /// control connection.
    ///
    /// **This refusal is macSCP's, because the library cannot make it.** The
    /// fork compares the originating `NIOSSLContext` and the SNI server name;
    /// for a peer named by address both names are `nil` — an IP literal may
    /// not go in the SNI extension — so a session established against one
    /// address passes its check when offered to another. The peer's address is
    /// not reachable where that check runs: it sits in
    /// `NIOSSLClientHandler`'s designated initializer, before the handler is
    /// in a pipeline and before the channel has connected. macSCP knows which
    /// control connection a data connection belongs to, so the comparison is
    /// here, on the identity that owns the session.
    ///
    /// Ruling T5.1 also lives here, in `verify`: a FULL handshake must
    /// present the control connection's certificate material byte for byte,
    /// and a data connection never asks the user — the question was answered
    /// once, on the control connection, and asking it per transfer is how a
    /// person is trained to click yes.
    static func openDataConnection(
        host: String, port: Int, protection: DataProtection?, owner: Identity, timeout: Duration
    ) async throws -> FTPDataChannel {
        if let protection, protection.owner != owner {
            throw FTPConnectionFailure.sessionFromAnotherConnection
        }
        let events = FTPChannelEvents()
        let (stream, continuation) = AsyncStream.makeStream(of: ByteBuffer.self)
        let expected = protection?.controlCertificateDER
        let outcome = FTPDataTrustOutcome()
        // Read from the verification callback's own argument, which on a
        // session-offering connection is the ONLY source: that initializer
        // takes a plain `NIOSSLCustomVerificationCallback`, so
        // `peerValidatedCertificateChain` can never be non-nil there, and
        // `NIOSSLHandler.peerCertificate` returns the SESSION's cached leaf —
        // non-nil for a resumed peer that presented nothing at all, which
        // would make this comparison pass on any resumed connection.
        let verify = FTPVerification { certificates, promise in
            guard let leaf = certificates.first, let der = try? leaf.toDERBytes(),
                let expected, der == expected
            else {
                outcome.noteDiffers()
                promise.succeed(.failed)
                return
            }
            promise.succeed(.certificateVerified)
        }

        let channel: Channel
        do {
            channel = try await ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
                .connectTimeout(Self.timeAmount(timeout))
                .channelInitializer { channel in
                    channel.eventLoop.makeCompletedFuture {
                        let pipeline = channel.pipeline.syncOperations
                        if let protection {
                            let handler: NIOSSLClientHandler
                            if let session = protection.session {
                                handler = try NIOSSLClientHandler(
                                    context: protection.context,
                                    serverHostname: protection.serverHostname,
                                    sessionToResume: session,
                                    customVerificationCallback: verify.callback)
                            } else {
                                handler = try NIOSSLClientHandler(
                                    context: protection.context,
                                    serverHostname: protection.serverHostname,
                                    customVerificationCallback: verify.callback)
                            }
                            try pipeline.addHandler(handler)
                        }
                        try pipeline.addHandler(
                            FTPChannelSink(deliver: continuation, events: events))
                    }
                }
                .connect(host: host, port: port).get()
        } catch {
            continuation.finish()
            if let session = protection?.session { protection?.vault?.checkIn(session) }
            throw Self.dialFailure(error)
        }

        var resumed = false
        if protection != nil {
            switch await events.awaitHandshake(timeout: timeout) {
            case .some(true):
                resumed = (try? await channel.nioSSL_tlsSessionWasResumed().get()) ?? false
            case .some(false):
                continuation.finish()
                _ = try? await channel.close().get()
                // The session goes back whatever ended the handshake: a
                // connection that never opened is not holding it.
                if let session = protection?.session { protection?.vault?.checkIn(session) }
                throw outcome.differs
                    ? FTPConnectionFailure.dataCertificateDiffers
                    : FTPConnectionFailure.tlsHandshakeFailed
            case .none:
                continuation.finish()
                _ = try? await channel.close().get()
                if let session = protection?.session { protection?.vault?.checkIn(session) }
                throw FTPConnectionFailure.timedOut
            }
        }
        return FTPDataChannel(
            channel: channel, chunks: FTPLineSource(stream), deliver: continuation, events: events,
            didResumeTLSSession: resumed, bound: Self.timeAmount(timeout),
            session: protection?.session, vault: protection?.vault)
    }

    // MARK: - Keepalive

    /// Sends `NOOP` once the connection has been idle for `interval`.
    ///
    /// Many FTP servers reap an idle control connection (vsftpd's
    /// `idle_session_timeout` defaults to 300 s), and a pooled connection
    /// spends most of its life idle.
    private func startKeepalive(_ interval: Duration) {
        guard interval > .zero else { return }
        keepalive = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: interval)
                } catch {
                    return
                }
                guard let self else { return }
                await self.sendKeepaliveIfIdle(interval)
            }
        }
    }

    private func sendKeepaliveIfIdle(_ interval: Duration) async {
        guard !isClosed, ContinuousClock.now - lastActivity >= interval else { return }
        // A keepalive that fails is not this connection's error to report:
        // whatever ended the connection will be reported by the next real
        // command, with its own context.
        _ = try? await send("NOOP", argument: nil)
    }

    // MARK: - Closing

    /// Ends the connection. Idempotent, and it cannot throw: a caller closing
    /// a connection has nothing left to do about a failure.
    ///
    /// No `QUIT`. A graceful goodbye would mean one more write and one more
    /// reply to wait for on a connection the caller has already finished
    /// with, and a server that has stopped answering would hold the close
    /// open; the UI owns lifecycles here, and what it asks for is that the
    /// connection be gone when this returns.
    func close() async {
        guard !isClosed else { return }
        isClosed = true
        keepalive?.cancel()
        keepalive = nil
        deliver.finish()
        _ = try? await channel.close().get()
    }

    // MARK: - Odds and ends

    /// The name to send in SNI, or `nil` for a peer named by address.
    ///
    /// An IP literal in the SNI extension is refused by the library
    /// (`NIOSSLExtraError.cannotUseIPAddressInSNI`), so an address peer has
    /// no SNI name — which is also why the library's session-hostname check
    /// compares `nil` with `nil` and why the scoping guard above exists.
    private static func sniName(for host: String) -> String? {
        (try? SocketAddress(ipAddress: host, port: 0)) == nil ? host : nil
    }

    /// `timeout` as NIO's own unit, clamped at zero — a negative bound would
    /// be a timer that has already fired.
    private static func timeAmount(_ timeout: Duration) -> TimeAmount {
        let components = timeout.components
        let nanoseconds =
            components.seconds * 1_000_000_000 + components.attoseconds / 1_000_000_000
        return .nanoseconds(max(0, nanoseconds))
    }

    /// What a failure from the TLS or transport layer is reported as.
    ///
    /// The two session errors are MAPPED and never surfaced: their
    /// descriptions embed both peer hostnames (see
    /// `FTPConnectionFailure.sessionRefusedByTLS`).
    private static func dialFailure(_ error: any Error) -> FTPConnectionFailure {
        if let failure = error as? FTPConnectionFailure { return failure }
        if let extra = error as? NIOSSLExtraError {
            if extra == .cannotResumeSessionFromDifferentContext
                || extra == .cannotResumeSessionForDifferentServerHostname
            {
                return .sessionRefusedByTLS
            }
            return .tlsHandshakeFailed
        }
        return .connectionClosed
    }
}

// MARK: - One data connection

/// The client end of one FTP data connection: it carries bytes and nothing
/// else, and it is opened only through
/// `FTPControlConnection.openDataConnection(host:port:protection:owner:timeout:)`.
actor FTPDataChannel {
    private let channel: Channel
    private let chunks: FTPLineSource
    private let deliver: AsyncStream<ByteBuffer>.Continuation
    private let events: FTPChannelEvents
    private let bound: TimeAmount
    /// The session this connection offered, and where it goes back to. Held
    /// until `close()`, so no other data connection is offered it in the
    /// meantime (`FTPSessionVault`).
    private let session: NIOSSLSession?
    private let vault: FTPSessionVault?

    /// Whether this connection's handshake resumed its control connection's
    /// TLS session instead of performing a full one. `false` on a clear data
    /// connection, which has no handshake to resume.
    ///
    /// This is the CLIENT's reading, from the TLS library. A test that wants
    /// to know whether a resumption really happened asks the server, which
    /// reads it off the wire — a client and a server asking the same library
    /// the same question would agree even when the library is wrong.
    nonisolated let didResumeTLSSession: Bool

    init(
        channel: Channel, chunks: FTPLineSource, deliver: AsyncStream<ByteBuffer>.Continuation,
        events: FTPChannelEvents, didResumeTLSSession: Bool, bound: TimeAmount,
        session: NIOSSLSession?, vault: FTPSessionVault?
    ) {
        self.channel = channel
        self.chunks = chunks
        self.deliver = deliver
        self.events = events
        self.didResumeTLSSession = didResumeTLSSession
        self.bound = bound
        self.session = session
        self.vault = vault
    }

    /// Everything the server sends until it closes the connection.
    func readToEnd() async throws -> Data {
        let events = self.events
        let deliver = self.deliver
        let timer = channel.eventLoop.scheduleTask(in: bound) {
            events.noteEnd(.timedOut)
            deliver.finish()
        }
        defer { timer.cancel() }

        var data = Data()
        while let chunk = await chunks.next() { data.append(contentsOf: chunk.readableBytesView) }
        if events.end == .timedOut { throw FTPConnectionFailure.timedOut }
        return data
    }

    func write(_ data: Data) async throws {
        do {
            try await channel.writeAndFlush(ByteBuffer(bytes: data)).get()
        } catch {
            throw FTPConnectionFailure.connectionClosed
        }
    }

    func close() async {
        deliver.finish()
        _ = try? await channel.close().get()
        // Returned after the channel is closed, not before: while this
        // connection is open it is the one holding the session.
        if let session, let vault { vault.checkIn(session) }
    }
}

/// The TLS sessions ONE control connection has, and which of them a data
/// connection is holding right now.
///
/// **Why a session comes round again, and why never to two connections at
/// once.** Under TLS 1.3 a session is nominally single-use: RFC 8446 appendix
/// C.4 asks a client not to offer one ticket for several connections, so that
/// a passive observer cannot correlate them, and `NIOSSLSession` reports the
/// requirement (`shouldBeSingleUse`) while enforcing nothing. Handing each
/// session out exactly once is what that reads as — and it does not work.
///
/// Measured 2026-11-06 against `LoopbackFTPServer` with
/// `requiresTLSSessionReuse: true`, four data connections in a row on one
/// control connection, printing whether a session was offered, whether the
/// handshake resumed, and the reply to `LIST`:
///
///     1: offered=true  resumed=true  reply=150
///     2: offered=true  resumed=true  reply=150
///     3: offered=false resumed=false reply=522
///     4: offered=false resumed=false reply=522
///
/// with `refusedDataConnectionCount` at 2 and the server's own handshake
/// journal reading `control/false, data/true, data/true, data/false,
/// data/false`. BoringSSL issues two tickets per handshake as a server and
/// the fixture renews none, so one control connection has exactly two
/// resumptions in it. vsftpd defaults `require_ssl_reuse` to on: that is a
/// backend that stops transferring after the second file.
///
/// Harvesting new sessions from the data connections is not an answer here.
/// The same measurement read `establishedTLSSessions` on each data channel
/// after its transfer and got **0** every time — the server closes a data
/// connection as soon as the transfer ends, and no ticket of its own is
/// processed before it does.
///
/// So a session is offered again once the connection holding it has closed.
/// Re-measured with exactly that change: **4 of 4** data connections resumed,
/// `refusedDataConnectionCount` 0, the journal `control/false` then four
/// `data/true`. What it costs is the correlation C.4 is about, and only
/// between the data connections of ONE control connection to ONE server —
/// connections a passive observer already watches opening to the address that
/// server's own `PASV` replies named.
///
/// A session whose holder is never closed stays checked out. That degrades to
/// a full handshake, which is the direction this fails in anyway, and the UI
/// owning lifecycles explicitly is this project's standing answer to it.
final class FTPSessionVault: Sendable {
    private let heldSessions = Mutex(Set<ObjectIdentifier>())

    /// The oldest resumable session nothing is holding, marked as held if it
    /// is single-use. `nil` when the peer has issued none yet, or every one
    /// it issued is in use.
    ///
    /// Oldest first, which is the order `establishedTLSSessions` hands them
    /// out in: a session expires, so spending the oldest first is what keeps
    /// the supply from aging out underneath the connection.
    func checkOut(from sessions: [NIOSSLSession]) -> NIOSSLSession? {
        heldSessions.withLock { held in
            for session in sessions where session.isResumable {
                let key = ObjectIdentifier(session)
                guard !held.contains(key) else { continue }
                if session.shouldBeSingleUse { held.insert(key) }
                return session
            }
            return nil
        }
    }

    /// Gives a session back. Idempotent: a caller that closes twice, or that
    /// hands back a session which was never single-use and so never held,
    /// changes nothing.
    func checkIn(_ session: NIOSSLSession) {
        heldSessions.withLock { _ = $0.remove(ObjectIdentifier(session)) }
    }
}

// MARK: - Channel plumbing

/// The inbound end of a channel, read by an actor.
///
/// A class because an actor cannot call a mutating `async` method on a stored
/// property, and `@unchecked Sendable` because the iterator is the only
/// mutable state and every read is serialised by the owner: on a control
/// connection by the command turn, on a data connection by its being one
/// actor's own stream. An `AsyncStream` has a single consumer, and two
/// overlapping `next()` calls on one iterator are undefined behaviour that
/// stays silent, so `reader` turns a violation into a named trap.
final class FTPLineSource: @unchecked Sendable {
    private var iterator: AsyncStream<ByteBuffer>.Iterator
    private let reader = Mutex(false)

    init(_ stream: AsyncStream<ByteBuffer>) {
        iterator = stream.makeAsyncIterator()
    }

    func next() async -> ByteBuffer? {
        let overlapped = reader.withLock { busy -> Bool in
            let was = busy
            busy = true
            return was
        }
        precondition(!overlapped, "two reads overlapped on one FTP channel's stream")
        defer { reader.withLock { $0 = false } }
        return await iterator.next()
    }
}

/// What a channel's tail learns and the awaiting side needs: whether the TLS
/// handshake completed, and why a stream ended.
///
/// Written from event-loop callbacks, read by an actor. Without the recorded
/// end, a bound that fired and a peer that closed are the same empty stream
/// from where the read is waiting.
final class FTPChannelEvents: Sendable {
    enum End: Sendable, Equatable {
        case none
        case closed
        case timedOut
    }

    private let end_ = Mutex(End.none)
    private let handshakeOutcome = Mutex<Bool?>(nil)
    private let handshakeSignal = AsyncSignal()

    var end: End { end_.withLock { $0 } }

    /// First end wins: the one that stopped the stream explains the ones that
    /// follow it.
    func noteEnd(_ reason: End) {
        end_.withLock { if $0 == .none { $0 = reason } }
    }

    /// Settles the handshake once, with whether it completed.
    func noteHandshake(_ completed: Bool) {
        let first = handshakeOutcome.withLock { outcome -> Bool in
            guard outcome == nil else { return false }
            outcome = completed
            return true
        }
        if first { handshakeSignal.signal() }
    }

    /// Whether the handshake completed, or `nil` if `timeout` elapsed or the
    /// waiting task was cancelled before it settled.
    func awaitHandshake(timeout: Duration) async -> Bool? {
        guard await handshakeSignal.wait(timeout: timeout) == .signalled else { return nil }
        return handshakeOutcome.withLock { $0 }
    }
}

/// Whether a data connection's full handshake presented certificate material
/// that is not its control connection's — recorded in the verification
/// callback, read after the handshake has failed, so the refusal can say
/// WHICH rule it was.
final class FTPDataTrustOutcome: Sendable {
    private let state = Mutex(false)

    var differs: Bool { state.withLock { $0 } }

    func noteDiffers() {
        state.withLock { $0 = true }
    }
}

/// Hands whatever reaches the end of the pipeline to a stream, and reports
/// the TLS handshake and the end of the connection.
final class FTPChannelSink: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    private let deliver: AsyncStream<ByteBuffer>.Continuation
    private let events: FTPChannelEvents

    init(deliver: AsyncStream<ByteBuffer>.Continuation, events: FTPChannelEvents) {
        self.deliver = deliver
        self.events = events
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        deliver.yield(unwrapInboundIn(data))
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let tls = event as? TLSUserEvent, case .handshakeCompleted = tls {
            events.noteHandshake(true)
        }
        context.fireUserInboundEventTriggered(event)
    }

    func channelInactive(context: ChannelHandlerContext) {
        events.noteHandshake(false)
        events.noteEnd(.closed)
        deliver.finish()
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        events.noteHandshake(false)
        events.noteEnd(.closed)
        deliver.finish()
        context.close(promise: nil)
    }
}

/// Splits the control stream into lines at LF and drops the CR before it.
///
/// Bytes, not text: the terminator is `0x0D 0x0A` on the wire, and a decoder
/// written over `String` would have to decode a partial line to find its end.
/// A trailing partial line at end of input is discarded, which is what a
/// server does with a command that never ended.
struct FTPLineDecoder: ByteToMessageDecoder {
    typealias InboundOut = ByteBuffer

    mutating func decode(
        context: ChannelHandlerContext, buffer: inout ByteBuffer
    ) throws -> DecodingState {
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

// MARK: - The trust decision

/// A verification callback that may cross a concurrency boundary.
///
/// `NIOSSLCustomVerificationCallback` is a plain function type with no
/// `@Sendable` on it, and a `channelInitializer` is `@Sendable`, so a bare
/// callback cannot be handed to one. The two callbacks built in this file
/// capture only `Sendable` state — `FTPTrustDecision` and
/// `FTPDataTrustOutcome`, both `Sendable` classes whose own state is behind a
/// `Mutex` — which is what makes this box sound and not merely sufficient to
/// compile.
struct FTPVerification: @unchecked Sendable {
    let callback: NIOSSLCustomVerificationCallback
}

/// The control connection's certificate decision, and the certificate it
/// accepted.
///
/// A class rather than actor state: the verification callback runs on the
/// event loop, in the middle of a handshake, and the actor reads the result
/// afterwards. The decision itself is taken OFF the event loop — it may ask a
/// person — because NIOSSL forbids re-entering its handler from the callback.
final class FTPTrustDecision: Sendable {
    private let host: String
    private let port: Int
    private let decider: CertificateDecider
    private let trustStore: TrustedCertificateStore?

    private struct Inner {
        var acceptedDER: [UInt8]?
        var failure: FTPConnectionFailure?
    }

    private let state = Mutex(Inner())

    private static let logger = Logger(subsystem: "dev.noix.macscp", category: "FTPTrustDecision")

    init(
        host: String, port: Int, decider: CertificateDecider,
        trustStore: TrustedCertificateStore?
    ) {
        self.host = host
        self.port = port
        self.decider = decider
        self.trustStore = trustStore
    }

    /// The DER of the certificate this connection's handshake accepted —
    /// what the peer PRESENTED, taken from the verification callback's own
    /// argument. Ruling T5.1 compares a data connection's full handshake
    /// against exactly these bytes.
    var acceptedCertificateDER: [UInt8]? { state.withLock { $0.acceptedDER } }

    /// Why the decision refused, when it did.
    var failure: FTPConnectionFailure? { state.withLock { $0.failure } }

    var verification: FTPVerification {
        FTPVerification { [self] certificates, promise in
            guard let leaf = certificates.first, let der = try? leaf.toDERBytes() else {
                record(.certificateRejected)
                promise.succeed(.failed)
                return
            }
            let notAfter = leaf.notValidAfter
            Task { [self] in
                let accepted = await decide(der: der, notAfter: notAfter)
                promise.succeed(accepted ? .certificateVerified : .failed)
            }
        }
    }


    /// TOFU, the same three outcomes WebDAV's path has: a remembered and
    /// identical certificate is accepted in silence, a remembered and
    /// different one is a hard stop that asks nobody, and an unknown one is
    /// put to the decider and remembered if it is accepted.
    private func decide(der: [UInt8], notAfter: time_t) async -> Bool {
        let summary = Self.subjectSummary(of: der)
        let candidate = ServerCertificateCandidate(
            host: host, port: port, derBase64: Data(der).base64EncodedString(),
            subject: summary, issuer: summary,
            notAfter: notAfter > 0 ? Date(timeIntervalSince1970: TimeInterval(notAfter)) : nil)

        let known: TrustedCertificate?
        if let trustStore {
            do {
                known = try trustStore.find(host: host, port: port)
            } catch {
                // Fail closed. Treating an unreadable store as "unknown"
                // would re-TOFU and overwrite a remembered certificate, and
                // it is not a user refusal — keep the two distinguishable.
                record(.trustStoreUnreadable)
                return false
            }
        } else {
            known = nil
        }

        switch ServerCertificateValidation.evaluate(candidate: candidate, known: known) {
        case .accept:
            accept(der)
            return true
        case .mismatch:
            record(.certificateMismatch)
            return false
        case .askUser:
            guard await decider(candidate) else {
                record(.certificateRejected)
                return false
            }
            if let trustStore {
                do {
                    try trustStore.upsert(
                        TrustedCertificate(
                            host: host, port: port, derBase64: candidate.derBase64,
                            subject: candidate.subject, issuer: candidate.issuer,
                            notAfter: candidate.notAfter))
                } catch {
                    // Recorded in the log and not thrown: the handshake
                    // continues with the certificate the user just approved,
                    // which is exactly as trustworthy as they said it was.
                    // What is lost is TOFU for this host — nothing was
                    // pinned, so the hard stop above can never fire for a
                    // substituted certificate here. Too quiet to leave to a
                    // `try?`. The host is named `.public` so the line is
                    // findable; the error's own text names the store's path
                    // and with it the account name, so it stays `.private`.
                    Self.logger.error(
                        """
                        trusted-certificate store not writable; the accepted certificate for \
                        \(self.host, privacy: .public):\(self.port, privacy: .public) was not \
                        pinned and this host stays unpinned: \
                        \(error.localizedDescription, privacy: .private)
                        """)
                }
            }
            accept(der)
            return true
        }
    }

    private func accept(_ der: [UInt8]) {
        state.withLock { $0.acceptedDER = der }
    }

    private func record(_ failure: FTPConnectionFailure) {
        state.withLock { if $0.failure == nil { $0.failure = failure } }
    }

    /// The certificate's subject, as the prompt shows it.
    ///
    /// Through `SecCertificate`, as `WebDAVSessionDelegate.candidate(from:…)`
    /// does, and with the issuer set to the same text for the same reason:
    /// `NIOSSLCertificate` exposes no name accessors, and the fingerprint is
    /// what the decision rests on either way.
    private static func subjectSummary(of der: [UInt8]) -> String {
        guard let certificate = SecCertificateCreateWithData(nil, Data(der) as CFData),
            let summary = SecCertificateCopySubjectSummary(certificate) as String?
        else { return "?" }
        return summary
    }
}
