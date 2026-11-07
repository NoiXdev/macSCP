import Foundation
import MacSCPTestSupport
import NIOCore
import NIOEmbedded
import Synchronization
import Testing

@testable import macSCPCore

/// The production FTP control connection against the loopback server: the
/// greeting, the login, `FEAT`, `TYPE I`, both TLS forms, the one validated
/// command path, and a data connection that resumes the control connection's
/// TLS session.
///
/// **Nothing here puts a credential where a reader can reach it.** `#expect`
/// prints the source text of its expression AND what its subexpressions
/// evaluated to, and two values in these tests are carriers: the generated
/// password, and `FTPConnectionConfig`, which holds it in a stored property
/// whose default `String(describing:)` would print it. So no expectation
/// below takes either as an operand — the dials go through `Self.dial`, which
/// answers a `DialOutcome` carrying neither, and what the server recorded is
/// read through `LoopbackFTPReceivedCommand`, whose `PASS` argument the
/// server never stores.
@Suite("FTP control connection", .timeLimit(.minutes(5)))
struct FTPControlConnectionTests {
    // MARK: - Helpers

    /// Starts `server`, runs `body` against it and always stops it. The same
    /// shape `LoopbackFTPServerTests` uses; what the server recorded survives
    /// the stop, so the expectations read it afterwards.
    private static func running<T: Sendable>(
        _ server: LoopbackFTPServer,
        _ body: (_ host: String, _ port: Int) async throws -> T
    ) async throws -> T {
        let endpoint = try await server.start()
        do {
            let result = try await body(endpoint.host, endpoint.port)
            await server.stop()
            return result
        } catch {
            await server.stop()
            throw error
        }
    }

    /// An `FTPIdleWatchdog` whose whole notion of time this test owns: the
    /// loop's manual clock drives the timer and `instant` drives the elapsed
    /// span, and `advance(_:)` moves both by the same amount so they cannot
    /// disagree. Advancing one and not the other is the half-injected shape
    /// the watchdog's own comment records measuring.
    private final class WatchdogRig: Sendable {
        /// The fake clock and the firing count, in a class because a `Mutex`
        /// is noncopyable and cannot be captured by the two escaping closures
        /// the watchdog holds.
        private final class State: Sendable {
            private struct Inner {
                var instant: ContinuousClock.Instant
                var firings = 0
            }

            private let box: Mutex<Inner>

            init() {
                box = Mutex(Inner(instant: ContinuousClock.now))
            }

            var now: ContinuousClock.Instant { box.withLock { $0.instant } }
            /// How many times the watchdog has given up. A count rather than
            /// a flag, so a watchdog that fired twice does not read as one
            /// that fired once.
            var firings: Int { box.withLock { $0.firings } }

            func advance(_ span: Duration) {
                box.withLock { $0.instant = $0.instant.advanced(by: span) }
            }

            func noteFiring() {
                box.withLock { $0.firings += 1 }
            }
        }

        let watchdog: FTPIdleWatchdog
        private let loop = EmbeddedEventLoop()
        private let state = State()

        /// How many times the watchdog gave up. A count and not a flag,
        /// so a watchdog that fires twice does not read as one that fired
        /// once.
        var firings: Int { state.firings }

        init(bound: Duration) {
            let state = self.state
            watchdog = FTPIdleWatchdog(
                bound: Self.amount(bound), loop: loop,
                now: { state.now },
                onIdle: { state.noteFiring() })
        }

        /// Moves the fake clock and the loop's timer wheel by the same span,
        /// so the two cannot disagree.
        func advance(_ span: Duration) {
            state.advance(span)
            loop.advanceTime(by: Self.amount(span))
        }

        private static func amount(_ span: Duration) -> TimeAmount {
            .nanoseconds(
                span.components.seconds * 1_000_000_000
                    + span.components.attoseconds / 1_000_000_000)
        }
    }

    /// One `Bool` read from inside a transfer's drain, in a reference a
    /// `@Sendable` closure can hold.
    ///
    /// `transferCommand`'s drain crosses into the actor, so it cannot
    /// capture a mutable local — the same constraint `FTPByteSink` exists
    /// for. Optional, so "never recorded" is distinguishable from `false`:
    /// a drain that did not run must not read as a dropped turn.
    private final class FTPTurnReading: Sendable {
        private let box = Mutex<Bool?>(nil)

        func record(_ held: Bool) {
            box.withLock { $0 = held }
        }

        var value: Bool? { box.withLock { $0 } }
    }

    /// A stand-in for `NIOSSLSession` in the vault's own tests.
    ///
    /// The vault's order is only visible with THREE sessions, and a
    /// `NIOSSLSession` cannot be made in a test: its initializer takes
    /// ownership of a BoringSSL `SSL_SESSION` that only a handshake produces,
    /// and the loopback peer issues exactly two. So the vault is generic over
    /// `FTPResumableSession` — the two properties it actually reads — and this
    /// is the third session.
    private final class FakeResumableSession: FTPResumableSession {
        let isResumable: Bool
        let shouldBeSingleUse: Bool

        init(resumable: Bool = true, singleUse: Bool = true) {
            isResumable = resumable
            shouldBeSingleUse = singleUse
        }
    }

    /// Counts what a certificate decider was asked, without holding a
    /// certificate: the count is all any test here reads.
    private final class DeciderLog: Sendable {
        private let asked = Mutex(0)
        var askCount: Int { asked.withLock { $0 } }
        func noteAsked() { asked.withLock { $0 += 1 } }
    }

    private static func decider(_ log: DeciderLog, answering answer: Bool) -> CertificateDecider {
        .asking { _ in
            log.noteAsked()
            return answer
        }
    }

    /// How a dial ended, as a value that carries no credential — see the
    /// suite's own comment. An error that is not an `FTPConnectionFailure`
    /// comes back as its TYPE name and not its text, so a wrong error type
    /// fails loudly instead of reading as "no failure", and nothing an error
    /// interpolated can reach the output.
    private enum DialOutcome: Equatable, CustomStringConvertible {
        case connected
        case failed(FTPConnectionFailure)
        case otherError(String)

        var description: String {
            switch self {
            case .connected: "connected"
            case .failed(let failure): "failed(\(failure))"
            case .otherError(let type): "otherError(\(type))"
            }
        }
    }

    /// Dials and closes again, reporting only how it ended.
    private static func dial(
        _ server: LoopbackFTPServer, host: String, port: Int, security: FTPSecurityMode,
        decider: CertificateDecider = .refusing, timeout: Duration = .seconds(30),
        trustStore: TrustedCertificateStore? = nil, password: String? = nil,
        username: String? = nil
    ) async -> DialOutcome {
        let credentials = server.credentials
        do {
            let connection = try await FTPControlConnection.connect(
                Self.config(
                    host: host, port: port, security: security,
                    username: username ?? credentials.username),
                password: password ?? credentials.password,
                certificateDecider: decider,
                timeout: timeout,
                trustStore: trustStore)
            await connection.close()
            return .connected
        } catch let failure as FTPConnectionFailure {
            return .failed(failure)
        } catch {
            return .otherError(String(describing: type(of: error)))
        }
    }

    /// The config a dial uses. Built here, never inside an expectation: it
    /// holds the password.
    private static func config(
        host: String, port: Int, security: FTPSecurityMode, username: String
    ) -> FTPConnectionConfig {
        FTPConnectionConfig(
            host: host, port: port, username: username, security: security, password: "")
    }

    /// An open connection, or the failure that stopped it from opening. For
    /// the tests that need the connection itself rather than the outcome.
    private static func connect(
        _ server: LoopbackFTPServer, host: String, port: Int, security: FTPSecurityMode,
        decider: CertificateDecider = .refusing, timeout: Duration = .seconds(30),
        tuning: FTPControlConnection.Tuning = .default
    ) async throws -> FTPControlConnection {
        let credentials = server.credentials
        return try await FTPControlConnection.connect(
            Self.config(host: host, port: port, security: security, username: credentials.username),
            password: credentials.password,
            certificateDecider: decider,
            timeout: timeout,
            // Named out loud, with no default to fall through: a dial that
            // remembers nothing says so (Ruling T5.7).
            trustStore: nil,
            tuning: tuning)
    }

    /// `(host, port)` out of a `227` reply.
    private static func passiveEndpoint(_ reply: FTPReply) throws -> (host: String, port: Int) {
        let text = reply.lines.joined(separator: " ")
        let open = try #require(text.firstIndex(of: "("))
        let close = try #require(text.firstIndex(of: ")"))
        let numbers = text[text.index(after: open)..<close].split(separator: ",").compactMap { Int($0) }
        try #require(numbers.count == 6)
        return (numbers[0..<4].map(String.init).joined(separator: "."), numbers[4] * 256 + numbers[5])
    }

    // MARK: - The greeting

    @Test func theGreetingIsReadBeforeAnyCommandIsSent() async throws {
        let refusing = LoopbackFTPServer(
            security: .plain, advertisesMLSD: true, requiresTLSSessionReuse: false)
        let refused = try await Self.running(refusing) { host, port in
            await refusing.refuseNextAcquireWith421()
            return await Self.dial(refusing, host: host, port: port, security: .plain)
        }
        #expect(refused == .failed(.greetingRefused(code: 421)))
        // The negative: a greeting that refuses the connection is answered by
        // sending NOTHING. A dial that wrote `USER` before reading would have
        // left a command here.
        #expect(await refusing.receivedCommands.isEmpty)

        // The positive beside it, same dial against a server that greets:
        // commands DO reach this server, so the empty log above is a dial that
        // held its tongue and not a server that records nothing.
        let greeting = LoopbackFTPServer(
            security: .plain, advertisesMLSD: true, requiresTLSSessionReuse: false)
        let connected = try await Self.running(greeting) { host, port in
            await Self.dial(greeting, host: host, port: port, security: .plain)
        }
        #expect(connected == .connected)
        #expect(await greeting.receivedCommands.map(\.verb).first == "USER")
    }

    // MARK: - The reply codes a well-behaved server does not send

    /// Dials a scripted server in plain mode and reports how it ended.
    private static func dialScript(
        _ server: ScriptedFTPServer, host: String, port: Int,
        security: FTPSecurityMode = .plain, timeout: Duration = .seconds(30),
        tuning: FTPControlConnection.Tuning = .default
    ) async -> (outcome: DialOutcome, features: Set<String>) {
        do {
            let connection = try await FTPControlConnection.connect(
                FTPConnectionConfig(
                    host: host, port: port, username: "scripted", security: security,
                    password: ""),
                password: "unused-by-a-script", certificateDecider: .refusing,
                timeout: timeout, trustStore: nil, tuning: tuning)
            let features = await connection.features
            await connection.close()
            return (.connected, features)
        } catch let failure as FTPConnectionFailure {
            return (.failed(failure), [])
        } catch {
            return (.otherError(String(describing: type(of: error))), [])
        }
    }

    private static func runningScript<T: Sendable>(
        _ server: ScriptedFTPServer,
        _ body: (_ host: String, _ port: Int) async throws -> T
    ) async throws -> T {
        let endpoint = try await server.start()
        do {
            let result = try await body(endpoint.host, endpoint.port)
            await server.stop()
            return result
        } catch {
            await server.stop()
            throw error
        }
    }

    /// A `120` in front of the greeting is read through, not taken for the
    /// greeting.
    ///
    /// RFC 959 section 5.4 permits it. Taking it for the greeting is not a
    /// refusal: every reply after it then answers the command before it, and
    /// `FTPReplyAccumulator` cannot notice, because each line is a
    /// well-formed reply. The script below makes the desynchronisation
    /// VISIBLE — `FEAT`'s reply would be the one-line `230` and the feature
    /// set would come back empty — because a dial that is one reply behind
    /// still reports success.
    @Test func a120BeforeTheGreetingIsReadThroughToThe220() async throws {
        let server = ScriptedFTPServer(
            greeting: [["120 Service ready in 1 minute."], ["220 Scripted server ready."]],
            replies: [
                ["331 Password required."],
                ["230 Login successful."],
                ["211-Features:", " UTF8", " SIZE", " MLSD", "211 End"],
                ["200 Type set."],
            ])
        let result = try await Self.runningScript(server) { host, port in
            await Self.dialScript(server, host: host, port: port)
        }
        #expect(result.outcome == .connected)
        // The positive that a desynchronised dial cannot produce: `FEAT`'s
        // own reply was read against `FEAT`.
        #expect(result.features.contains("UTF8"))
        #expect(result.features.contains("MLSD"))
        #expect(await server.receivedCommands == ["USER scripted", "PASS", "FEAT", "TYPE I"])
    }

    /// `332 Need account for login` is not a successful login.
    ///
    /// It is a server asking for an `ACCT` this backend does not send. It is
    /// a 3xx, so the predicate that admits `331` admitted it too, and the
    /// dial carried on against a session that is not logged in.
    @Test func aPASSAnsweredWithAnAccountRequestIsNotALogin() async throws {
        let server = ScriptedFTPServer(
            greeting: [["220 Scripted server ready."]],
            replies: [["331 Password required."], ["332 Need account for login."]])
        let result = try await Self.runningScript(server) { host, port in
            await Self.dialScript(server, host: host, port: port)
        }
        #expect(result.outcome == .failed(.loginRefused))
        // The negative beside it: the dial stopped there. No `FEAT`, no
        // `TYPE` against a session that is not logged in.
        #expect(await server.receivedCommands == ["USER scripted", "PASS"])
    }

    /// `AUTH TLS` answered with anything but a 2xx does not start a
    /// handshake.
    ///
    /// `334` is the "continue the exchange" of the Kerberos-style mechanisms.
    /// Reading it as success sent a ClientHello to a peer that was not
    /// expecting one, and the dial then waited for a handshake that could
    /// never complete.
    @Test func anAUTHAnsweredWithoutA2xxDoesNotStartAHandshake() async throws {
        let server = ScriptedFTPServer(
            greeting: [["220 Scripted server ready."]],
            replies: [["334 Adat must follow."]])
        let result = try await Self.runningScript(server) { host, port in
            await Self.dialScript(
                server, host: host, port: port, security: .explicitTLS, timeout: .seconds(2))
        }
        #expect(result.outcome == .failed(.tlsUpgradeRefused(code: 334)))
        #expect(await server.receivedCommands == ["AUTH TLS"])
    }

    /// A PRELIMINARY reply to `USER` is not a login.
    ///
    /// RFC 959 section 4.2 lists `230`, `331`, `332`, `530` and
    /// `500`/`501`/`421` for `USER`, and no 1xx. The predicate here was the
    /// 1xx ∪ 2xx ∪ 3xx union until fix round 2 (F3), so a `150` read as the
    /// login going well and the dial carried on with every later reply
    /// answering the command before it — the same desynchronisation the `120`
    /// greeting produced.
    @Test func aPreliminaryReplyToUSERIsNotALogin() async throws {
        let server = ScriptedFTPServer(
            greeting: [["220 Scripted server ready."]],
            replies: [["150 File status okay; about to open data connection."]])
        let result = try await Self.runningScript(server) { host, port in
            await Self.dialScript(server, host: host, port: port)
        }
        #expect(result.outcome == .failed(.loginRefused))
        // The negative beside it: the dial stopped at `USER`. No `PASS` was
        // sent against a reply that promised a second one.
        #expect(await server.receivedCommands == ["USER scripted"])
    }

    /// A PRELIMINARY reply to `FEAT` is refused rather than parsed.
    ///
    /// RFC 2389 section 3 answers `FEAT` with `211` and the list, or with
    /// `500`/`502` from a server that does not implement it — and an
    /// unimplemented `FEAT` is a dial that carries on with no features, which
    /// `featIsReadOnceAndItsFeaturesAreQueryable` is the other half of. A
    /// `150` is the reply this cannot take: `FEAT`'s reply code was not
    /// looked at at all until fix round 2 (F3), so the promised second reply
    /// was left to answer `TYPE`.
    @Test func aPreliminaryReplyToFEATIsRefused() async throws {
        let server = ScriptedFTPServer(
            greeting: [["220 Scripted server ready."]],
            replies: [
                ["331 Password required."],
                ["230 Login successful."],
                ["150 File status okay; about to open data connection."],
            ])
        let result = try await Self.runningScript(server) { host, port in
            await Self.dialScript(server, host: host, port: port)
        }
        #expect(result.outcome == .failed(.protocolViolation))
        #expect(await server.receivedCommands == ["USER scripted", "PASS", "FEAT"])
    }

    /// A refused `TYPE I` ends the dial instead of leaving it in text mode.
    ///
    /// `TYPE` is answered `200`, or `500`/`501`/`504`/`421`/`530` (RFC 959
    /// section 4.2). Its reply was discarded with `_ =` until fix round 2
    /// (F3), so a server that refused binary mode was connected to anyway —
    /// and a text-mode transfer rewrites line endings, which corrupts every
    /// file that is not text. There is no fallback worth having, so the dial
    /// fails.
    @Test func aRefusedTYPEIEndsTheDial() async throws {
        let server = ScriptedFTPServer(
            greeting: [["220 Scripted server ready."]],
            replies: [
                ["331 Password required."],
                ["230 Login successful."],
                ["211-Features:", " UTF8", "211 End"],
                ["504 Type not implemented for this parameter."],
            ])
        let result = try await Self.runningScript(server) { host, port in
            await Self.dialScript(server, host: host, port: port)
        }
        #expect(result.outcome == .failed(.binaryModeRefused(code: 504)))
        #expect(await server.receivedCommands == ["USER scripted", "PASS", "FEAT", "TYPE I"])
    }

    /// A reply bound that fires takes the connection down.
    ///
    /// Ending the line stream alone blinded the connection: every later read
    /// failed on a stream that could never deliver, while the socket stayed
    /// open and the keepalive went on writing `NOOP` into it. The script
    /// answers everything the dial needs and then goes silent, so the
    /// timeout happens on a command AFTER the dial — which is where the
    /// defect lived, since a dial that fails closes the connection on its own
    /// error path.
    @Test func aReplyBoundThatFiresClosesTheConnection() async throws {
        let server = ScriptedFTPServer(
            greeting: [["220 Scripted server ready."]],
            replies: [
                ["331 Password required."],
                ["230 Login successful."],
                ["211-Features:", " UTF8", "211 End"],
                ["200 Type set."],
                // `PWD` is answered with nothing at all.
            ])
        let outcome = try await Self.runningScript(server) { host, port in
            let connection = try await FTPControlConnection.connect(
                FTPConnectionConfig(
                    host: host, port: port, username: "scripted", security: .plain, password: ""),
                password: "unused-by-a-script", certificateDecider: .refusing,
                timeout: .seconds(30), trustStore: nil,
                tuning: FTPControlConnection.Tuning(
                    keepaliveInterval: .milliseconds(20), replyIdleTimeout: .milliseconds(200)))
            var failure: FTPConnectionFailure?
            do {
                _ = try await connection.send("PWD", argument: nil)
            } catch let caught as FTPConnectionFailure {
                failure = caught
            }
            // The connection took itself down, so the socket is closed. Waited
            // on state and not on a clock.
            try await pollUntil("the timed-out connection to close its socket") {
                await server.peerClosed
            }
            await connection.close()
            return failure
        }
        #expect(outcome == .timedOut)
        // The positive the wait rests on: the dial really did complete, so
        // what timed out was a command and not the greeting.
        #expect(await server.receivedCommands.prefix(4) == ["USER scripted", "PASS", "FEAT", "TYPE I"])
    }

    // MARK: - Login

    @Test func loginSendsUSERThenPASSAndReportsTheOutcome() async throws {
        let accepting = LoopbackFTPServer(
            security: .plain, advertisesMLSD: true, requiresTLSSessionReuse: false)
        let accepted = try await Self.running(accepting) { host, port in
            await Self.dial(accepting, host: host, port: port, security: .plain)
        }
        #expect(accepted == .connected)
        let commands = await accepting.receivedCommands
        #expect(commands.map(\.verb).prefix(2) == ["USER", "PASS"])
        // The password crossed the wire and is NOT in the log: the server
        // stores a placeholder for `PASS`, so this expectation can print its
        // operands without printing a credential.
        let passArgument = commands.first { $0.verb == "PASS" }?.argument
        #expect(passArgument == LoopbackFTPReceivedCommand.redactedArgument)

        // The other outcome: a wrong password is reported as an
        // authentication failure and not as a transport one.
        let refusing = LoopbackFTPServer(
            security: .plain, advertisesMLSD: true, requiresTLSSessionReuse: false)
        let refused = try await Self.running(refusing) { host, port in
            await Self.dial(
                refusing, host: host, port: port, security: .plain,
                password: "not-the-generated-one")
        }
        #expect(refused == .failed(.loginRefused))
    }

    // MARK: - The turn

    /// Two commands issued at once each get the reply to ITS OWN command.
    ///
    /// An actor does not buy this: it is re-entrant at every `await`, so
    /// without the turn both `send`s would write and then both read from one
    /// line stream. The two codes are distinct, so a crossed pair shows up as
    /// a swap rather than as two equal values that happen to match.
    ///
    /// **Unmeasured by a plant, deliberately.** Removing the turn does not
    /// produce a red here but a `precondition` trap in `FTPLineSource` — the
    /// overlap guard that makes its `@unchecked Sendable` sound — and a run
    /// that aborts is not a verdict (CLAUDE.md on planting). The trap is the
    /// stronger protection of the two; this case pins the behaviour the turn
    /// is there to produce.
    @Test func twoConcurrentCommandsEachGetTheirOwnReply() async throws {
        let server = LoopbackFTPServer(
            security: .plain, advertisesMLSD: true, requiresTLSSessionReuse: false)
        let replies = try await Self.running(server) { host, port in
            let connection = try await Self.connect(
                server, host: host, port: port, security: .plain)
            async let directory = connection.send("PWD", argument: nil)
            async let size = connection.send("SIZE", argument: "/absent.txt")
            let replies = try await (directory: directory, size: size)
            await connection.close()
            return replies
        }
        #expect(replies.directory.code == 257)
        #expect(replies.size.code == 550)
    }

    /// A transfer command owns both of its replies, so the next command gets
    /// its own.
    ///
    /// The red this case was written against, with the two replies read by
    /// two separate turns (`send` releasing after the `150`, then a
    /// `readFurtherReply()`): a `PWD` issued between them came back **226**
    /// where 257 was due, after which every reply is one behind. The
    /// expectation below is the same one; `transferCommand` is what makes it
    /// hold, because there is no longer a point between the two replies at
    /// which another command can be issued on this connection.
    ///
    /// **THIS case's codes do not pin the span, which was measured** (fix
    /// round 2, F2): the re-review of fix round 1 planted the pre-fix shape —
    /// `release()` before the drain, `await acquire()` after it — and this
    /// case came back GREEN with 32 tests run, because the `PWD` below is
    /// issued *after* `transferCommand` returns and 150/226/257 then arrive in
    /// order whether the turn was held or not. That measurement stands. So
    /// does the reading of it: the span shows in the codes only when a second
    /// command is on the wire while the pair is open, which this case never
    /// puts there.
    ///
    /// **What is withdrawn is the conclusion drawn from it** (fix round 3,
    /// G1). The wording that stood here, verbatim: "Making it visible through
    /// the codes needs a second command on the wire while the pair is open,
    /// and that is a race: the plant releases the turn but still re-acquires
    /// it for the completion reply, so the turn serialises the two readers
    /// either way and which of them reads the `226` is scheduling. A deadline
    /// on the race would be the wall-clock ceiling this project forbids."
    /// It is false of the last step: the concurrent command's START can be
    /// sequenced against the drain with an `AsyncSignal`, and then which
    /// reader gets the `226` is the property and not scheduling, with no
    /// clock anywhere. `aCommandIssuedDuringATransferCannotReadItsCompletionReply`
    /// below is that case, measured 20/20 red against the span plant. So the
    /// span is pinned twice: here, where only a held turn answers `true`, and
    /// there, on the wire.
    @Test func aTransferHoldsTheTurnAcrossBothOfItsReplies() async throws {
        let server = LoopbackFTPServer(
            security: .plain, advertisesMLSD: true, requiresTLSSessionReuse: false)
        let codes = try await Self.running(server) { host, port in
            let connection = try await Self.connect(
                server, host: host, port: port, security: .plain)
            let passive = try Self.passiveEndpoint(try await connection.send("PASV", argument: nil))
            let data = try await connection.openDataConnection(host: passive.host, port: passive.port)
            var heldDuringTheDrain = false
            let transfer = try await connection.transferCommand("LIST") {
                // Between the `150` and the `226`, which is the whole span
                // the method exists for.
                heldDuringTheDrain = await connection.turnIsHeld
                _ = try await data.readToEnd()
            }
            let pwd = try await connection.send("PWD", argument: nil)
            // The positive beside it: the turn is a span and not a latch, so
            // it is gone again once the pair is closed. A connection that
            // answered `true` to both would be one that never releases.
            let heldAfterwards = await connection.turnIsHeld
            await data.close()
            await connection.close()
            return (
                opening: transfer.opening.code, completion: transfer.completion?.code,
                pwd: pwd.code, heldDuringTheDrain: heldDuringTheDrain,
                heldAfterwards: heldAfterwards
            )
        }
        #expect(codes.opening == 150)
        #expect(codes.completion == 226)
        #expect(codes.pwd == 257)
        #expect(codes.heldDuringTheDrain)
        #expect(!codes.heldAfterwards)
    }

    /// The same span, read on the WIRE: a command issued while the pair is
    /// open cannot reach it, so neither reply can go to the wrong command.
    ///
    /// **This case exists because fix round 2 said it could not.** The
    /// sentence it withdraws is quoted in the case above, which keeps the
    /// measurement that really was taken — a `PWD` issued AFTER
    /// `transferCommand` returns cannot see the span — while this one takes
    /// the race the round declared out of reach.
    ///
    /// How the sequencing works. `aboutToSend` is raised by the concurrent
    /// task immediately before it calls `send`, and the drain awaits it as its
    /// first statement. On the committed tree the case cannot fail however
    /// late or early that task is scheduled: `send` opens with `acquire()`,
    /// and while `transferCommand` holds the turn `acquire()` parks on a
    /// continuation, so the `PWD` cannot reach the wire before the `226` has
    /// been read — structurally, not by scheduling. That half is exact, and it
    /// is why this case cannot flake: on a correct tree it passes in every
    /// interleaving.
    ///
    /// The PLANTED side is NOT structural, and this comment first said it was.
    /// Withdrawn verbatim: "With the span removed the turn is free when the
    /// signal resumes the drain, so the `PWD` is written during the drain,
    /// reads the `226` as its own, and `transferCommand` re-acquires and reads
    /// the `257`: both expectations below fail." Nothing sequences
    /// `transferCommand`'s own `acquire()` ahead of the concurrent task, so a
    /// planted tree has two interleavings, not one. The intended one: the
    /// `PWD` parks in `acquire()`, is resumed inside the span, and reads the
    /// `226`. The blind one: the task takes the turn FIRST, is answered `257`
    /// and releases before `LIST` is ever sent — the latch then returns at
    /// once in the drain, the two commands never overlap, and both
    /// expectations hold on the plant. The blind order is undetectable by this
    /// case by construction, not by bad luck.
    ///
    /// Measured 20/20 red against the plant and 20/20 green without it (fix
    /// round 3, G1), as ten copies of this body so the probe's catcher list
    /// was itself the count; the re-review of that round raised it to 80/80
    /// each over four rounds of twenty. The ORDER was then counted on its own,
    /// twenty copies reading `receivedCommands.map(\.verb)` on the fixed tree
    /// over three rounds: 59 x `PASV,LIST,PWD` against 1 x `PASV,PWD,LIST`.
    /// About 1 run in 60, which is what 80/80 is consistent with rather than
    /// evidence against — no blind trial in eighty draws has probability
    /// around 0.26.
    ///
    /// The case is deliberately NOT rebuilt around that. Having the drain
    /// signal and the concurrent task wait would close the blind order and
    /// open its mirror, unmeasured. What covers it is the flag case above,
    /// which reads the span where it lives and cannot be raced at all. The two
    /// together are the guard: this one would see a turn whose replies go to
    /// the wrong command, that one sees a turn that is held and wrong.
    ///
    /// No reader ever overlaps, because the plant still serialises the two
    /// readers through the turn, so `FTPLineSource`'s overlap `precondition`
    /// is not reached and the probe reports RED rather than a trap. And no
    /// `Task.yield()`: a first variant of this shape carried 200 on either
    /// side of the drain and they were measured unnecessary.
    @Test func aCommandIssuedDuringATransferCannotReadItsCompletionReply() async throws {
        let server = LoopbackFTPServer(
            security: .plain, advertisesMLSD: true, requiresTLSSessionReuse: false)
        let codes = try await Self.running(server) { host, port in
            let connection = try await Self.connect(
                server, host: host, port: port, security: .plain)
            let passive = try Self.passiveEndpoint(try await connection.send("PASV", argument: nil))
            let data = try await connection.openDataConnection(host: passive.host, port: passive.port)
            let aboutToSend = AsyncSignal()
            let pwdTask = Task { () async throws -> Int in
                aboutToSend.signal()
                return try await connection.send("PWD", argument: nil).code
            }
            // The task is awaited below on every path this closure takes, but
            // `transferCommand` can throw before that line is reached, and a
            // task nobody awaits is a task nobody ends.
            defer { pwdTask.cancel() }
            let transfer = try await connection.transferCommand("LIST") {
                _ = await aboutToSend.wait()
                _ = try await data.readToEnd()
            }
            let pwd = try await pwdTask.value
            await data.close()
            await connection.close()
            return (completion: transfer.completion?.code, pwd: pwd)
        }
        #expect(codes.completion == 226)
        #expect(codes.pwd == 257)
    }

    /// A drain that THROWS still owes the completion reply, and the
    /// connection is in step afterwards.
    ///
    /// The `150` promised a `226`, and `defer { release() }` hands the turn on
    /// as the error leaves `transferCommand`, so an unguarded drain left that
    /// `226` inbound for the next command to read as its own. Measured before
    /// the fix, and it is the same wrong reply R3 exists to prevent, reached
    /// through a throwing body instead of through an interleaving command:
    /// the `PWD` below came back **226** where `257` was due (fix round 2,
    /// F1).
    ///
    /// The path is an ordinary one. A `readToEnd()` that hits its own idle
    /// bound throws `timedOut`, and a Task 6 caller's drain is exactly that
    /// read — so this is the common failure of a transfer, not a corner of it.
    @Test func aDrainThatThrowsStillOwesItsCompletionReply() async throws {
        struct DrainFailed: Error {}

        let server = LoopbackFTPServer(
            security: .plain, advertisesMLSD: true, requiresTLSSessionReuse: false)
        let outcome = try await Self.running(server) { host, port in
            let connection = try await Self.connect(
                server, host: host, port: port, security: .plain)
            let passive = try Self.passiveEndpoint(try await connection.send("PASV", argument: nil))
            let data = try await connection.openDataConnection(host: passive.host, port: passive.port)
            var threw = false
            do {
                // The drain reads the payload to its end first, so the `226`
                // is on its way when the body throws: what is measured is
                // which command reads it, not whether the server sent it.
                _ = try await connection.transferCommand("LIST") {
                    _ = try await data.readToEnd()
                    throw DrainFailed()
                }
            } catch is DrainFailed {
                threw = true
            }
            // The next command on this connection, and the reply that
            // belongs to it.
            let pwd = try await connection.send("PWD", argument: nil)
            await data.close()
            await connection.close()
            return (threw: threw, pwd: pwd.code)
        }
        // The drain's own error reaches the caller unchanged: reading the
        // owed reply must not replace the reason the transfer failed.
        #expect(outcome.threw)
        #expect(outcome.pwd == 257)
    }

    /// And when the OWED reply cannot be read either, the connection is
    /// closed and the drain's own error still reaches the caller.
    ///
    /// The other half of the ruled shape (T5.11), and until fix round 3 the
    /// untested one: the re-review planted
    /// `throw FTPConnectionFailure.connectionClosed` after the `await close()`
    /// on that path, and planted the `await close()` away, and **both were
    /// GREEN across 37 tests** at `c65937c5` (fix round 3, G2). The code was
    /// right and nothing held it there.
    ///
    /// `garbleNextTransferCompletion()` is what reaches the branch, with no
    /// clock in it: the payload is served in full, so `readToEnd()` returns
    /// and the drain throws of its own accord, and the line that should have
    /// been the `226` has no reply code in front of it, so the bounded read
    /// of the owed reply throws `protocolViolation`. The seam's own comment
    /// says why a silent server would be the wrong fixture here — a read
    /// that ends on `readReply`'s timeout closes the connection inside
    /// `readReply`, which would leave the `await close()` this case is about
    /// pinning nothing.
    ///
    /// Both properties are asserted, because neither implies the other: the
    /// connection is closed — read through the next command on it, which is
    /// the behaviour and not a flag — and the error the caller sees is still
    /// the drain's, not `protocolViolation` and not `connectionClosed`.
    @Test func anOwedReplyThatCannotBeReadClosesTheConnectionAndKeepsTheError() async throws {
        struct DrainFailed: Error {}

        let server = LoopbackFTPServer(
            security: .plain, advertisesMLSD: true, requiresTLSSessionReuse: false)
        let outcome = try await Self.running(server) { host, port in
            await server.garbleNextTransferCompletion()
            let connection = try await Self.connect(
                server, host: host, port: port, security: .plain)
            let passive = try Self.passiveEndpoint(try await connection.send("PASV", argument: nil))
            let data = try await connection.openDataConnection(host: passive.host, port: passive.port)
            var fromTheDrain = false
            do {
                _ = try await connection.transferCommand("LIST") {
                    _ = try await data.readToEnd()
                    throw DrainFailed()
                }
            } catch is DrainFailed {
                fromTheDrain = true
            }
            // What the connection does next IS whether it was closed. A
            // closed connection cannot write, and its line stream has ended,
            // so both ways this can end are `connectionClosed`; a connection
            // still open gets a `257` from a server that is still answering.
            var afterwards = "no answer"
            do {
                afterwards = "answered(\(try await connection.send("PWD", argument: nil).code))"
            } catch let failure as FTPConnectionFailure {
                afterwards = "failed(\(failure))"
            } catch {
                afterwards = "otherError(\(String(describing: type(of: error))))"
            }
            await data.close()
            await connection.close()
            return (fromTheDrain: fromTheDrain, afterwards: afterwards)
        }
        #expect(outcome.fromTheDrain)
        #expect(outcome.afterwards == "failed(connectionClosed)")
    }

    /// A refused transfer has ONE reply, and nothing waits for a second.
    ///
    /// `522`, `425` and `550` are the whole answer. A `transferCommand` that
    /// waited for a completion reply after a refusal would park until the
    /// reply idle bound, which is the shape of hang this API exists to
    /// prevent rather than cause.
    @Test func aRefusedTransferCarriesNoCompletionReply() async throws {
        let server = LoopbackFTPServer(
            security: .plain, advertisesMLSD: true, requiresTLSSessionReuse: false)
        let outcome = try await Self.running(server) { host, port in
            let connection = try await Self.connect(
                server, host: host, port: port, security: .plain)
            // `RETR` of a file that is not there: refused with `550` before
            // the data connection is used, so there is no `226` to come.
            let passive = try Self.passiveEndpoint(try await connection.send("PASV", argument: nil))
            let data = try await connection.openDataConnection(host: passive.host, port: passive.port)
            var drained = false
            let transfer = try await connection.transferCommand("RETR", argument: "/absent.txt") {
                drained = true
                _ = try await data.readToEnd()
            }
            // And the connection is still usable afterwards: the turn was
            // given up, and no reply is owed.
            let pwd = try await connection.send("PWD", argument: nil)
            await data.close()
            await connection.close()
            return (
                opening: transfer.opening.code, completion: transfer.completion?.code,
                drained: drained, pwd: pwd.code
            )
        }
        #expect(outcome.opening == 550)
        #expect(outcome.completion == nil)
        // The body is for the bytes between two replies, so a refusal does
        // not run it.
        #expect(!outcome.drained)
        #expect(outcome.pwd == 257)
    }

    /// A data read is bounded by SILENCE on the data connection, and not by
    /// the dial's own timeout.
    ///
    /// Until fix round 1 the data channel was built with the dial's figure as
    /// a TOTAL read budget, so a 30-second connect timeout capped every
    /// download at 30 seconds and then killed the control stream with it
    /// (R2). The dial bound here is 600 seconds — longer than this suite's
    /// whole time limit, so a read bounded by it could not finish at all —
    /// while the read's own bound is 50 ms. Nothing below asserts an upper
    /// bound on anything: the 600 seconds is a parameter, and the only timing
    /// assertion is a floor.
    @Test func aDataReadIsBoundedByItsOwnIdleTimeoutAndNotByTheDialsTimeout() async throws {
        let server = LoopbackFTPServer(
            security: .plain, advertisesMLSD: true, requiresTLSSessionReuse: false)
        let idleBound = Duration.milliseconds(50)
        let outcome = try await Self.running(server) { host, port in
            let connection = try await Self.connect(
                server, host: host, port: port, security: .plain, timeout: .seconds(600),
                tuning: FTPControlConnection.Tuning(dataIdleTimeout: idleBound))
            let passive = try Self.passiveEndpoint(try await connection.send("PASV", argument: nil))
            // No transfer command, so the server never writes to this
            // connection and never closes it: the read has nothing to wait
            // for but the bound.
            let data = try await connection.openDataConnection(host: passive.host, port: passive.port)
            let started = ContinuousClock.now
            var failure: FTPConnectionFailure?
            do {
                _ = try await data.readToEnd()
            } catch let caught as FTPConnectionFailure {
                failure = caught
            }
            let elapsed = ContinuousClock.now - started
            await data.close()
            await connection.close()
            return (failure: failure, elapsed: elapsed)
        }
        #expect(outcome.failure == .timedOut)
        #expect(outcome.elapsed >= idleBound)
    }

    /// The watchdog R2's reads are bounded by: progress inside the bound
    /// rearms it, and silence past the bound fires it.
    ///
    /// **No wall clock and no ceiling anywhere.** Both halves of the
    /// watchdog's time are driven here — the timer by an
    /// `EmbeddedEventLoop`'s manual time and the elapsed span by a clock this
    /// case advances — so every figure below is one the test chose, and the
    /// shape CLAUDE.md forbids (an assertion about the gap between the test's
    /// own calls, which a starved runner widens) never arises.
    ///
    /// **Driving only the loop gives a test that passes for the wrong
    /// reason**, which was measured before the clock was injectable: the tick
    /// then runs on the loop's manual time but measures the REAL span since
    /// the last progress, which is roughly zero, so it rearms every time and
    /// the watchdog can never fire. The first half below passed and the
    /// second failed —
    /// `✘ Expectation failed: firedOnSilence.withLock { $0 }` — and "did not
    /// fire" is exactly what the first half asserts. That is why the positive
    /// check is not optional here.
    @Test func theIdleWatchdogRearmsOnProgressAndFiresOnSilence() {
        let bound = Duration.seconds(10)
        let step = Duration.seconds(6)

        // Progress inside the bound: four steps of 6 s, with a progress
        // report after each, is 24 s of a 10 s bound and never 10 s of
        // silence.
        let withProgress = WatchdogRig(bound: bound)
        withProgress.watchdog.start()
        for _ in 1...4 {
            withProgress.advance(step)
            withProgress.watchdog.noteProgress()
        }
        #expect(withProgress.firings == 0)
        withProgress.watchdog.stop()

        // The positive beside it: the same bound, the same steps, no progress
        // reported. A watchdog that could never fire would pass the check
        // above and fail this one.
        let silent = WatchdogRig(bound: bound)
        silent.watchdog.start()
        silent.advance(step)
        #expect(silent.firings == 0)
        silent.advance(step)
        #expect(silent.firings == 1)
        silent.watchdog.stop()
    }

    // MARK: - FEAT

    @Test func featIsReadOnceAndItsFeaturesAreQueryable() async throws {
        let server = LoopbackFTPServer(
            security: .plain, advertisesMLSD: true, requiresTLSSessionReuse: false)
        let features = try await Self.running(server) { host, port in
            let connection = try await Self.connect(
                server, host: host, port: port, security: .plain)
            let features = await connection.features
            await connection.close()
            return features
        }
        #expect(features.contains("MLSD"))
        #expect(features.contains("UTF8"))
        #expect(features.contains("SIZE"))
        // A feature line with parameters is keyed by its verb as well as by
        // its whole text, because that is how a caller asks either question.
        #expect(features.contains("MLST"))
        #expect(features.contains("MLST TYPE*;SIZE*;MODIFY*;"))
        // Neither end of the multiline reply is a feature.
        #expect(!features.contains("FEATURES:"))
        #expect(!features.contains("END"))
        let featCount = await server.receivedCommands.filter { $0.verb == "FEAT" }.count
        #expect(featCount == 1)
    }

    // MARK: - TYPE

    @Test func typeIIsIssuedAndTypeAIsNeverSent() async throws {
        let server = LoopbackFTPServer(
            security: .plain, advertisesMLSD: true, requiresTLSSessionReuse: false)
        let outcome = try await Self.running(server) { host, port in
            await Self.dial(server, host: host, port: port, security: .plain)
        }
        #expect(outcome == .connected)
        // One assertion carrying both halves: exactly one `TYPE` crossed the
        // wire, and its argument is `I`. An empty list would fail it as
        // loudly as a `TYPE A` would.
        let typeArguments = await server.receivedCommands.filter { $0.verb == "TYPE" }.map(\.argument)
        #expect(typeArguments == ["I"])

        // And the source half. The scan is for the SEND SITE and not for the
        // text `TYPE A`, because the realistic violation cannot be written
        // that way: commands go out as `send("TYPE", argument: …)`, so a
        // scan for the two words together could not have matched one — a
        // check pointed at a region the violation cannot be expressed in
        // (CLAUDE.md, "Source-scanning guards read comments too", point 2).
        let sources = try Self.ftpSources()
        #expect(sources.count >= 2, "the FTP source directory was not found")
        let sites = sources.map { (name: $0.name, count: Self.occurrences(of: "\"TYPE\"", in: $0.text)) }
        // Positive: exactly one file names the command, once.
        #expect(sites.filter { $0.count > 0 }.map(\.name) == ["FTPControlConnection.swift"])
        #expect(sites.first { $0.name == "FTPControlConnection.swift" }?.count == 1)
        // And that one site issues `I`.
        let control = try #require(sources.first { $0.name == "FTPControlConnection.swift" }).text
        #expect(Self.occurrences(of: "send(\"TYPE\", argument: \"I\")", in: control) == 1)
        // Negative, with the spelling a violation would actually have, plus
        // the hand-written line a second command path could carry.
        let offenders = sources.filter {
            $0.text.contains("send(\"TYPE\", argument: \"A\")") || $0.text.contains("TYPE A")
        }.map(\.name)
        #expect(offenders.isEmpty, "\(offenders)")
        // Positive controls for both patterns, so neither zero is a scan that
        // can no longer match anything.
        #expect("_ = try await send(\"TYPE\", argument: \"A\")".contains("send(\"TYPE\", argument: \"A\")"))
        #expect("line = \"TYPE A\"".contains("TYPE A"))
    }

    // MARK: - The two TLS forms

    @Test func explicitModeIssuesAUTHTLSThenPBSZ0ThenPROTP() async throws {
        let server = LoopbackFTPServer(
            security: .explicitTLS, advertisesMLSD: true, requiresTLSSessionReuse: false)
        let log = DeciderLog()
        let outcome = try await Self.running(server) { host, port in
            await Self.dial(
                server, host: host, port: port, security: .explicitTLS,
                decider: Self.decider(log, answering: true))
        }
        #expect(outcome == .connected)
        let commands = await server.receivedCommands
        #expect(commands.map(\.verb).prefix(3) == ["AUTH", "PBSZ", "PROT"])
        #expect(commands.prefix(3).map(\.argument) == ["TLS", "0", "P"])
        // The boundary: `AUTH TLS` is the one command in the clear, and the
        // login is on the other side of it.
        #expect(commands.first?.overTLS == false)
        let everythingAfterAUTHIsProtected = commands.dropFirst().allSatisfy(\.overTLS)
        #expect(everythingAfterAUTHIsProtected)
        #expect(commands.count > 1)
        // The certificate is self-signed and nothing is pinned, so the dial
        // asked once.
        #expect(log.askCount == 1)
    }

    /// A refused `PBSZ` or `PROT` ends the dial, with no data connection left
    /// in the clear.
    ///
    /// RFC 4217 section 9 is the order — the buffer size first, then the
    /// protection level — and a server may refuse either (`503` for `PBSZ`,
    /// `534 Request denied for policy reasons` for `PROT`, RFC 2228 section
    /// 5). Both replies were checked by fix round 1 and NEITHER check was
    /// tested: planting `PROT`'s guard away came back GREEN in the re-review,
    /// with 32 tests run. The fixture had no seam for it, which reads as
    /// "this cannot happen" and is only "nothing here produces it" (fix round
    /// 2, F6).
    @Test func aRefusedPBSZOrPROTEndsTheDialWithNoClearDataConnection() async throws {
        let log = DeciderLog()

        let refusingPBSZ = LoopbackFTPServer(
            security: .explicitTLS, advertisesMLSD: true, requiresTLSSessionReuse: false)
        let pbszOutcome = try await Self.running(refusingPBSZ) { host, port in
            await refusingPBSZ.refuseNextPBSZWith503()
            return await Self.dial(
                refusingPBSZ, host: host, port: port, security: .explicitTLS,
                decider: Self.decider(log, answering: true))
        }
        #expect(pbszOutcome == .failed(.tlsUpgradeRefused(code: 503)))
        // The negative: the dial stopped at the refusal. `PROT` was never
        // sent, and no login crossed a connection whose data channels would
        // have been in the clear.
        let afterPBSZ = await refusingPBSZ.receivedCommands.map(\.verb)
        #expect(afterPBSZ == ["AUTH", "PBSZ"])

        let refusingPROT = LoopbackFTPServer(
            security: .explicitTLS, advertisesMLSD: true, requiresTLSSessionReuse: false)
        let protOutcome = try await Self.running(refusingPROT) { host, port in
            await refusingPROT.refuseNextPROTWith534()
            return await Self.dial(
                refusingPROT, host: host, port: port, security: .explicitTLS,
                decider: Self.decider(log, answering: true))
        }
        #expect(protOutcome == .failed(.tlsUpgradeRefused(code: 534)))
        let afterPROT = await refusingPROT.receivedCommands.map(\.verb)
        #expect(afterPROT == ["AUTH", "PBSZ", "PROT"])

        // The positive beside both: the seams are one-shot and the same dial
        // against the same kind of server connects, so the two failures above
        // are refusals the client acted on and not a fixture that cannot
        // complete a dial at all.
        let serving = LoopbackFTPServer(
            security: .explicitTLS, advertisesMLSD: true, requiresTLSSessionReuse: false)
        let served = try await Self.running(serving) { host, port in
            await Self.dial(
                serving, host: host, port: port, security: .explicitTLS,
                decider: Self.decider(log, answering: true))
        }
        #expect(served == .connected)
    }

    @Test func implicitModeWrapsTheSocketBeforeTheGreeting() async throws {
        let server = LoopbackFTPServer(
            security: .implicitTLS, advertisesMLSD: true, requiresTLSSessionReuse: false)
        let log = DeciderLog()
        let outcome = try await Self.running(server) { host, port in
            await Self.dial(
                server, host: host, port: port, security: .implicitTLS,
                decider: Self.decider(log, answering: true))
        }
        #expect(outcome == .connected)
        let commands = await server.receivedCommands
        // Positive: commands arrived at all. Negative: not one of them was in
        // the clear, which is what "before the greeting" buys — the first
        // thing the socket carried was a handshake.
        #expect(!commands.isEmpty)
        let everythingIsProtected = commands.allSatisfy(\.overTLS)
        #expect(everythingIsProtected)
        #expect(!commands.contains { $0.verb == "AUTH" })
        #expect(await server.handshakes.first == .init(connection: .control, resumed: false))
        #expect(log.askCount == 1)
    }

    @Test func aRefusedAUTHTLSFailsTheConnectionWithNoPlaintextFallback() async throws {
        // A plain server answers `502 AUTH not available` — the case a
        // misconfigured explicit-FTPS session meets.
        let server = LoopbackFTPServer(
            security: .plain, advertisesMLSD: true, requiresTLSSessionReuse: false)
        let log = DeciderLog()
        let outcome = try await Self.running(server) { host, port in
            await Self.dial(
                server, host: host, port: port, security: .explicitTLS,
                decider: Self.decider(log, answering: true))
        }
        #expect(outcome == .failed(.tlsUpgradeRefused(code: 502)))
        // Positive and negative in one list: `AUTH` was sent, and nothing
        // else was. No `USER`, no `PASS` — there is no path from a refused
        // upgrade to a credential in the clear.
        #expect(await server.receivedCommands.map(\.verb) == ["AUTH"])
        #expect(log.askCount == 0)
    }

    // MARK: - Data-connection TLS session resumption (Review Focus 2)

    @Test func aDataConnectionResumesTheControlSessionWhenTheServerRequiresIt() async throws {
        let server = LoopbackFTPServer(
            security: .explicitTLS, advertisesMLSD: true, requiresTLSSessionReuse: true)
        let log = DeciderLog()
        let outcome = try await Self.running(server) { host, port in
            let connection = try await Self.connect(
                server, host: host, port: port, security: .explicitTLS,
                decider: Self.decider(log, answering: true))
            let passive = try Self.passiveEndpoint(try await connection.send("PASV", argument: nil))
            let data = try await connection.openDataConnection(host: passive.host, port: passive.port)
            let transfer = try await connection.transferCommand("LIST") {
                _ = try await data.readToEnd()
            }
            await data.close()
            let resumed = data.didResumeTLSSession
            await connection.close()
            return (reply: transfer.opening, resumed: resumed)
        }
        // The server required reuse and served the transfer: `150`, not the
        // `522 SSL connection failed; session reuse required.` it answers an
        // unresumed data connection with.
        #expect(outcome.reply.code == 150)
        #expect(await server.refusedDataConnectionCount == 0)
        // The independent verdict: the loopback server reads "did this
        // handshake resume?" off its own outbound bytes
        // (`TLSResumptionInspector`), never from the TLS library, so this is
        // not the client's claim repeated back.
        #expect(await server.handshakes.last == .init(connection: .data, resumed: true))
        // The client's own claim, beside it rather than instead of it.
        #expect(outcome.resumed)
        // One handshake, one question: the data connection never asked.
        #expect(log.askCount == 1)
    }

    /// A server that requires reuse keeps being served past the second
    /// transfer, and no two data connections hold one session at a time.
    ///
    /// The case this exists for is measured on `FTPSessionVault`: handing
    /// each session out exactly once leaves a control connection with two
    /// resumptions, because BoringSSL issues two tickets per handshake, and
    /// the third data connection is then answered `522`. Four in a row here,
    /// which is past that edge.
    @Test func dataConnectionsPastTheSecondStillResume() async throws {
        let server = LoopbackFTPServer(
            security: .explicitTLS, advertisesMLSD: true, requiresTLSSessionReuse: true)
        let log = DeciderLog()
        let codes = try await Self.running(server) { host, port in
            let connection = try await Self.connect(
                server, host: host, port: port, security: .explicitTLS,
                decider: Self.decider(log, answering: true))
            var codes: [Int] = []
            var resumptions: [Bool] = []
            for _ in 1...4 {
                let passive = try Self.passiveEndpoint(
                    try await connection.send("PASV", argument: nil))
                let data = try await connection.openDataConnection(
                    host: passive.host, port: passive.port)
                let transfer = try await connection.transferCommand("LIST") {
                    _ = try await data.readToEnd()
                }
                codes.append(transfer.opening.code)
                resumptions.append(data.didResumeTLSSession)
                // Closing is what returns the session, so the next one has
                // something to offer.
                await data.close()
            }
            await connection.close()
            return (codes: codes, resumptions: resumptions)
        }
        #expect(codes.codes == [150, 150, 150, 150])
        #expect(codes.resumptions == [true, true, true, true])
        #expect(await server.refusedDataConnectionCount == 0)
        // The server's own reading of all five handshakes, off the wire.
        #expect(
            await server.handshakes == [
                .init(connection: .control, resumed: false),
                .init(connection: .data, resumed: true),
                .init(connection: .data, resumed: true),
                .init(connection: .data, resumed: true),
                .init(connection: .data, resumed: true),
            ])
        #expect(log.askCount == 1)
    }

    /// Two protections outstanding at once carry DIFFERENT sessions: the
    /// second is not handed the first's while the first is still out.
    ///
    /// This is the half of RFC 8446 appendix C.4 the vault keeps — a session
    /// comes round again, but never to two holders at the same time — and it
    /// is asked at the checkout, which is where the decision is made: a
    /// protection is handed out before its data connection exists, and it is
    /// closing that connection which returns the session.
    @Test func twoProtectionsOutstandingAtOnceCarryDifferentSessions() async throws {
        let server = LoopbackFTPServer(
            security: .explicitTLS, advertisesMLSD: true, requiresTLSSessionReuse: true)
        let log = DeciderLog()
        let outcome = try await Self.running(server) { host, port in
            let connection = try await Self.connect(
                server, host: host, port: port, security: .explicitTLS,
                decider: Self.decider(log, answering: true))
            let first = try #require(await connection.dataProtection())
            let second = try #require(await connection.dataProtection())
            let third = await connection.dataProtection()
            let firstSession = try #require(first.session)
            let secondSession = try #require(second.session)
            await connection.close()
            return (
                same: firstSession === secondSession,
                exhausted: third?.session == nil,
                thirdExists: third != nil
            )
        }
        #expect(!outcome.same)
        // And what the measurement on `FTPSessionVault` says: the peer issued
        // two, so a third protection asked for while both are out carries no
        // session at all rather than one of theirs.
        #expect(outcome.thirdExists)
        #expect(outcome.exhausted)
    }

    /// A data channel closed twice does not hand its session to a second
    /// holder.
    ///
    /// `checkIn` is a set removal, so returning the SAME session twice is
    /// harmless on its own. What is not harmless is the second return landing
    /// after another holder has taken that session out again: the mark it
    /// clears is then somebody else's, and the next checkout hands a held
    /// session to a second connection — the one RFC 8446 appendix C.4
    /// property the vault still keeps after Ruling T5.2. A
    /// `defer { await data.close() }` beside an explicit close on an error
    /// path is how that double call arrives.
    @Test func aDataChannelClosedTwiceDoesNotReissueAHeldSession() async throws {
        let server = LoopbackFTPServer(
            security: .explicitTLS, advertisesMLSD: true, requiresTLSSessionReuse: true)
        let log = DeciderLog()
        let outcome = try await Self.running(server) { host, port in
            let connection = try await Self.connect(
                server, host: host, port: port, security: .explicitTLS,
                decider: Self.decider(log, answering: true))
            let passive = try Self.passiveEndpoint(try await connection.send("PASV", argument: nil))
            // The channel takes the first session; a second protection takes
            // the other one the peer issued, so the supply is exhausted and a
            // later checkout has to fall back to whatever came back.
            let data = try await connection.openDataConnection(host: passive.host, port: passive.port)
            let second = try #require(await connection.dataProtection())
            await data.close()
            let third = try #require(await connection.dataProtection())
            // The second close is the one under test.
            await data.close()
            let fourth = await connection.dataProtection()
            await connection.close()
            return (
                secondHasSession: second.session != nil,
                thirdHasSession: third.session != nil,
                handedOutWhileHeld: fourth?.session === third.session
            )
        }
        // Positive beside the negative: the sequence really did hand out two
        // sessions and then a third, so the check below is about a double
        // close and not about a vault that hands nothing out.
        #expect(outcome.secondHasSession)
        #expect(outcome.thirdHasSession)
        #expect(!outcome.handedOutWhileHeld)
    }

    /// A data connection refused for a foreign owner returns the session it
    /// was offered.
    ///
    /// Every other failure path in `openDataConnection` checks the session
    /// back in; the owner comparison throws before that plumbing, so a
    /// refusal used to strand a session marked held with no holder that would
    /// ever return it.
    @Test func aRefusedOwnerReturnsTheSessionItWasOffered() async throws {
        let server = LoopbackFTPServer(
            security: .explicitTLS, advertisesMLSD: true, requiresTLSSessionReuse: true)
        let log = DeciderLog()
        let outcome = try await Self.running(server) { host, port in
            let mine = try await Self.connect(
                server, host: host, port: port, security: .explicitTLS,
                decider: Self.decider(log, answering: true))
            let other = try await Self.connect(
                server, host: host, port: port, security: .explicitTLS,
                decider: Self.decider(log, answering: true))
            let passive = try Self.passiveEndpoint(try await mine.send("PASV", argument: nil))
            // Both sessions out, so the next checkout can only come from what
            // the refusal gives back.
            let offered = try #require(await mine.dataProtection())
            let alsoOut = try #require(await mine.dataProtection())
            var refusal: FTPConnectionFailure?
            do {
                let stolen = try await FTPControlConnection.openDataConnection(
                    host: passive.host, port: passive.port, protection: offered,
                    owner: other.identity, timeout: .seconds(30), idleTimeout: .seconds(30))
                await stolen.close()
            } catch let failure as FTPConnectionFailure {
                refusal = failure
            }
            let afterRefusal = await mine.dataProtection()
            await mine.close()
            await other.close()
            return (
                refusal: refusal,
                bothWereOut: offered.session != nil && alsoOut.session != nil,
                returned: afterRefusal?.session === offered.session
            )
        }
        #expect(outcome.refusal == .sessionFromAnotherConnection)
        #expect(outcome.bothWereOut)
        #expect(outcome.returned)
    }

    /// The vault hands out a session nobody has used before preferring one
    /// that came back.
    ///
    /// **Load-bearing, not tidiness.** Handing back the oldest unheld session
    /// means data connection 2 re-offers the ticket connection 1 has just
    /// returned instead of the untouched second one. A server that enforces
    /// single-use consumption — which is what RFC 8446 asks a client to
    /// assume, and what any anti-replay implementation does — refuses that
    /// re-offer, falls back to a full handshake, and `require_ssl_reuse`
    /// turns it into `522`: the policy would fail at connection 2 where
    /// strict single-use reached 3. A policy adopted to raise a cap must not
    /// lower it.
    ///
    /// Three sessions, because two cannot show it: with two, the fallback and
    /// the preference name the same session. The loopback peer issues exactly
    /// two, which is why `FakeResumableSession` exists rather than a server
    /// that could be asked for a third.
    @Test func theVaultPrefersANeverUsedSessionOverAReturnedOne() {
        let vault = FTPSessionVault()
        let first = FakeResumableSession()
        let second = FakeResumableSession()
        let third = FakeResumableSession()
        let supply = [first, second, third]

        #expect(vault.checkOut(from: supply) === first)
        vault.checkIn(first)
        // The point of the whole case: `first` is free again and `second` has
        // never been offered, so `second` is the one to offer.
        #expect(vault.checkOut(from: supply) === second)
        vault.checkIn(second)
        #expect(vault.checkOut(from: supply) === third)
        vault.checkIn(third)

        // Supply exhausted: now a returned one comes round again, oldest
        // first, which is Ruling T5.2's deviation.
        #expect(vault.checkOut(from: supply) === first)
        #expect(vault.checkOut(from: supply) === second)
        #expect(vault.checkOut(from: supply) === third)
        // And nothing is handed out twice while held.
        #expect(vault.checkOut(from: supply) == nil)
    }

    /// A session the library does not mark single-use is never held, so it
    /// can be offered to two connections at once — which is exactly what
    /// `shouldBeSingleUse == false` means ("`session` cannot be used without
    /// leaking a correlator", so there is no per-use obligation to keep).
    @Test func aSessionThatIsNotSingleUseIsOfferedWithoutBeingHeld() {
        let vault = FTPSessionVault()
        let reusable = FakeResumableSession(singleUse: false)
        #expect(vault.checkOut(from: [reusable]) === reusable)
        #expect(vault.checkOut(from: [reusable]) === reusable)
        // A session that cannot be resumed at all is never offered.
        let spent = FakeResumableSession(resumable: false)
        #expect(vault.checkOut(from: [spent]) == nil)
    }

    /// The guard swift-nio-ssl cannot build: a session established by one
    /// control connection is offered only to THAT connection's data
    /// connections.
    ///
    /// The library compares the originating `NIOSSLContext` and the SNI
    /// server name, and for a peer named by address both names are `nil` —
    /// an IP literal cannot go in the SNI extension — so two connections to
    /// different addresses pass its check. macSCP is the layer that knows
    /// which control connection a data connection belongs to, which is why
    /// the scoping is here.
    @Test func aTLSSessionIsOfferedOnlyToItsOwnConnectionsDataConnections() async throws {
        let server = LoopbackFTPServer(
            security: .explicitTLS, advertisesMLSD: true, requiresTLSSessionReuse: true)
        let log = DeciderLog()
        let outcome = try await Self.running(server) { host, port in
            let mine = try await Self.connect(
                server, host: host, port: port, security: .explicitTLS,
                decider: Self.decider(log, answering: true))
            let other = try await Self.connect(
                server, host: host, port: port, security: .explicitTLS,
                decider: Self.decider(log, answering: true))
            let passive = try Self.passiveEndpoint(try await mine.send("PASV", argument: nil))
            let protection = try #require(await mine.dataProtection())

            // The negative: another control connection may not use it.
            var refusal: FTPConnectionFailure?
            do {
                let stolen = try await FTPControlConnection.openDataConnection(
                    host: passive.host, port: passive.port, protection: protection,
                    owner: other.identity, timeout: .seconds(30), idleTimeout: .seconds(30))
                await stolen.close()
            } catch let failure as FTPConnectionFailure {
                refusal = failure
            }

            // The positive beside it: the owner's own data connection gets
            // the same protection on the same listener and is served.
            let data = try await FTPControlConnection.openDataConnection(
                host: passive.host, port: passive.port, protection: protection,
                owner: mine.identity, timeout: .seconds(30), idleTimeout: .seconds(30))
            let transfer = try await mine.transferCommand("LIST") {
                _ = try await data.readToEnd()
            }
            await data.close()
            await mine.close()
            await other.close()
            return (refusal: refusal, reply: transfer.opening)
        }
        #expect(outcome.refusal == .sessionFromAnotherConnection)
        #expect(outcome.reply.code == 150)
    }

    /// Ruling T5.1's comparison: a data connection performing a FULL
    /// handshake must present its control connection's certificate material
    /// byte for byte, and a mismatch fails the transfer rather than asking
    /// anybody.
    ///
    /// The material is varied instead of the server, because one loopback
    /// server has one certificate: the protection handed to the data
    /// connection is rebuilt with other bytes in it, which is exactly the
    /// case the rule exists for — a `PASV` listener on another host that
    /// offers a different-but-valid certificate.
    @Test func aDataConnectionPresentingAnotherCertificateIsRefused() async throws {
        let server = LoopbackFTPServer(
            security: .explicitTLS, advertisesMLSD: true, requiresTLSSessionReuse: false)
        let log = DeciderLog()
        let outcome = try await Self.running(server) { host, port in
            let connection = try await Self.connect(
                server, host: host, port: port, security: .explicitTLS,
                decider: Self.decider(log, answering: true))
            let real = try #require(await connection.dataProtection())

            // A full handshake (no session offered) against material that is
            // not this server's.
            let first = try Self.passiveEndpoint(try await connection.send("PASV", argument: nil))
            var refusal: FTPConnectionFailure?
            do {
                let refused = try await FTPControlConnection.openDataConnection(
                    host: first.host, port: first.port,
                    protection: FTPControlConnection.DataProtection(
                        owner: connection.identity, context: real.context,
                        serverHostname: real.serverHostname,
                        controlCertificateDER: Array("not this server's certificate".utf8),
                        session: nil, vault: nil),
                    owner: connection.identity, timeout: .seconds(30), idleTimeout: .seconds(30))
                await refused.close()
            } catch let failure as FTPConnectionFailure {
                refusal = failure
            }

            // The positive beside it: the same full handshake, the control
            // connection's own bytes, served.
            let second = try Self.passiveEndpoint(try await connection.send("PASV", argument: nil))
            let data = try await FTPControlConnection.openDataConnection(
                host: second.host, port: second.port,
                protection: FTPControlConnection.DataProtection(
                    owner: connection.identity, context: real.context,
                    serverHostname: real.serverHostname,
                    controlCertificateDER: real.controlCertificateDER, session: nil, vault: nil),
                owner: connection.identity, timeout: .seconds(30), idleTimeout: .seconds(30))
            let transfer = try await connection.transferCommand("LIST") {
                _ = try await data.readToEnd()
            }
            await data.close()
            await connection.close()
            return (refusal: refusal, reply: transfer.opening)
        }
        #expect(outcome.refusal == .dataCertificateDiffers)
        #expect(outcome.reply.code == 150)
        // The control connection asked once; neither data connection asked at
        // all, including the one that was refused.
        #expect(log.askCount == 1)
    }

    /// A user name or password carrying CR or LF is refused AS A CREDENTIAL.
    ///
    /// Routing both through `FTPPath.validated` is right — either injects a
    /// command exactly as a file name would — but the refusal a user would
    /// have read said "Rename the file or folder and try again", and
    /// `FTPPathRefusal` left `connect` as a type nothing above maps.
    ///
    /// **Every expectation here binds its `Bool` first**, including the
    /// positive one: `#expect` prints what its subexpressions evaluated to,
    /// and the values this case is about are a user name and a password.
    @Test func aCredentialCarryingALineBreakIsRefusedAsACredential() async throws {
        let server = LoopbackFTPServer(
            security: .plain, advertisesMLSD: true, requiresTLSSessionReuse: false)
        let outcomes = try await Self.running(server) { host, port in
            let password = await Self.dial(
                server, host: host, port: port, security: .plain,
                password: "two\r\nlines")
            let user = await Self.dial(
                server, host: host, port: port, security: .plain,
                username: "two\nlines")
            // The positive beside them, same server, same dial.
            let clean = await Self.dial(server, host: host, port: port, security: .plain)
            return (password: password, user: user, clean: clean)
        }
        let passwordWasRefusedAsACredential = outcomes.password == .failed(.credentialNotSendable)
        #expect(passwordWasRefusedAsACredential)
        let userWasRefusedAsACredential = outcomes.user == .failed(.credentialNotSendable)
        #expect(userWasRefusedAsACredential)
        let aCleanLoginStillConnects = outcomes.clean == .connected
        #expect(aCleanLoginStillConnects)

        // What reached the wire: the refused password's dial got as far as
        // `USER` and no further, and the refused user name sent nothing at
        // all. The server stores no `PASS` argument, so these operands cannot
        // evaluate to a credential either.
        let verbs = await server.receivedCommands.map(\.verb)
        let noPasswordEverReachedTheWire = !verbs.contains("PASS") || verbs.filter { $0 == "PASS" }.count == 1
        #expect(noPasswordEverReachedTheWire)
        let theCleanDialLoggedIn = verbs.contains("PASS")
        #expect(theCleanDialLoggedIn)
    }

    // MARK: - The validated command path

    @Test func anArgumentCarryingCRLFNeverReachesTheServer() async throws {
        let server = LoopbackFTPServer(
            security: .plain, advertisesMLSD: true, requiresTLSSessionReuse: false)
        let refusal: FTPPathRefusal? = try await Self.running(server) { host, port in
            let connection = try await Self.connect(
                server, host: host, port: port, security: .plain)
            // The positive first, so the negative below is a refusal and not
            // a connection that had already stopped working.
            let ordinary = try await connection.send("SIZE", argument: "/absent.txt")
            #expect(ordinary.code == 550)
            var caught: FTPPathRefusal?
            do {
                _ = try await connection.send("SIZE", argument: "/a\r\nDELE /b")
            } catch let refusal as FTPPathRefusal {
                caught = refusal
            }
            await connection.close()
            return caught
        }
        #expect(refusal == .forbiddenCharacter(.carriageReturn))
        let verbs = await server.receivedCommands.map(\.verb)
        #expect(verbs.contains("SIZE"))
        #expect(!verbs.contains("DELE"))
        // The injected command never arrived, and neither did a second `SIZE`.
        #expect(verbs.filter { $0 == "SIZE" }.count == 1)
    }

    /// One function writes a command line, and it takes what it writes
    /// through `FTPPath.validated`.
    ///
    /// The anchor is a symbol name this scan cannot derive from Swift, so it
    /// is spelled — and `#require` on finding it is what keeps that from
    /// going stale in silence: a rename fails this check instead of leaving a
    /// negative scan matching nothing.
    @Test func exactlyOnePlaceWritesACommandLine() throws {
        let sources = try Self.ftpSources()
        #expect(sources.count >= 2, "the FTP source directory was not found")

        // The four source characters of a Swift `"\r\n"` literal.
        let terminator = #"\r\n"#
        let writers = sources.filter { Self.occurrences(of: terminator, in: $0.text) > 0 }
        #expect(writers.map(\.name) == ["FTPControlConnection.swift"])
        #expect(writers.first.map { Self.occurrences(of: terminator, in: $0.text) } == 1)

        // Positive controls for the counter, so neither figure above is a
        // pattern that can no longer match: one planted occurrence and none.
        #expect(Self.occurrences(of: terminator, in: #"ByteBuffer(string: line + "\r\n")"#) == 1)
        #expect(Self.occurrences(of: terminator, in: "ByteBuffer(string: line)") == 0)

        // And the one occurrence sits in the body of the one function that
        // builds a command line, beside the validation call.
        let url = Self.ftpSourceDirectory.appendingPathComponent("FTPControlConnection.swift")
        let code = try SourceCorpus.code(of: url)
        let withStrings = try SourceCorpus.commentFree(of: url)
        let body = try #require(
            Self.body(after: "func commandLine", inBlanked: code, slicing: withStrings),
            "no `func commandLine` in FTPControlConnection.swift")
        #expect(Self.occurrences(of: terminator, in: body) == 1)
        #expect(body.contains("FTPPath.validated("))
    }

    // MARK: - The connect timeout

    @Test func theConnectTimeoutIsHonouredRatherThanDropped() async throws {
        // A socket that listens and never answers: the kernel completes the
        // TCP handshake into its backlog, so the dial connects and then waits
        // for a greeting that cannot come.
        let socket = try #require(LoopbackSocket.listening())
        defer { socket.close() }
        let bound = Duration.milliseconds(400)

        let started = ContinuousClock.now
        var outcome = DialOutcome.connected
        do {
            let connection = try await FTPControlConnection.connect(
                FTPConnectionConfig(
                    host: "127.0.0.1", port: socket.port, username: "nobody",
                    security: .plain, password: ""),
                password: "", certificateDecider: .refusing, timeout: bound, trustStore: nil)
            await connection.close()
        } catch let failure as FTPConnectionFailure {
            outcome = .failed(failure)
        } catch {
            outcome = .otherError(String(describing: type(of: error)))
        }
        let elapsed = ContinuousClock.now - started

        // WHICH outcome, and that it arrived at all. The only bound asserted
        // is a floor: the dial did not give up before its own timeout. An
        // upper bound here would measure the runner (CLAUDE.md).
        #expect(outcome == .failed(.timedOut))
        #expect(elapsed >= bound)
    }

    // MARK: - Keepalive

    @Test func anIdleConnectionSendsNOOPToKeepTheSessionAlive() async throws {
        let server = LoopbackFTPServer(
            security: .plain, advertisesMLSD: true, requiresTLSSessionReuse: false)
        try await Self.running(server) { host, port in
            let connection = try await Self.connect(
                server, host: host, port: port, security: .plain,
                tuning: FTPControlConnection.Tuning(keepaliveInterval: .milliseconds(20)))
            // Waited on state, not on a clock: `pollUntil` has no deadline of
            // its own and this suite's `.timeLimit` is the only escape.
            try await pollUntil("the idle connection to send NOOP") {
                await server.receivedCommands.contains { $0.verb == "NOOP" }
            }
            await connection.close()
        }
        // Positive beside the wait: the NOOP carries no argument, so it is
        // the keepalive and not a command that happens to be named one.
        let noops = await server.receivedCommands.filter { $0.verb == "NOOP" }
        #expect(noops.allSatisfy { $0.argument.isEmpty })
        #expect(!noops.isEmpty)
    }

    // MARK: - Certificate trust

    /// A pinned certificate that changed is a hard stop, and the decider is
    /// never consulted — the contract `ServerCertificateValidation` states
    /// and `CLAUDE.md`'s architecture invariants require.
    @Test func aPinnedCertificateThatChangedIsAHardStopWithNoPrompt() async throws {
        let server = LoopbackFTPServer(
            security: .implicitTLS, advertisesMLSD: true, requiresTLSSessionReuse: false)
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-ftp-trust-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = TrustedCertificateStore(directory: directory)
        let log = DeciderLog()

        let outcome = try await Self.running(server) { host, port in
            // Pin something that is NOT what this server presents: its
            // certificate is minted per start.
            try store.upsert(
                TrustedCertificate(
                    host: host, port: port, derBase64: Data("not this server".utf8).base64EncodedString(),
                    subject: "pinned", issuer: "pinned", notAfter: nil))
            return await Self.dial(
                server, host: host, port: port, security: .implicitTLS,
                decider: Self.decider(log, answering: true), trustStore: store)
        }
        #expect(outcome == .failed(.certificateMismatch))
        // The negative that matters: a mismatch asks nobody. A decider that
        // answers yes could not have rescued it.
        #expect(log.askCount == 0)

        // The positive beside it: the same store, the same decider, a server
        // whose certificate is NOT pinned — the dial asks once, is told yes,
        // and remembers what the server actually presented.
        let unpinned = LoopbackFTPServer(
            security: .implicitTLS, advertisesMLSD: true, requiresTLSSessionReuse: false)
        let second = try await Self.running(unpinned) { host, port in
            let outcome = await Self.dial(
                unpinned, host: host, port: port, security: .implicitTLS,
                decider: Self.decider(log, answering: true), trustStore: store)
            return (outcome: outcome, host: host, port: port)
        }
        #expect(second.outcome == .connected)
        #expect(log.askCount == 1)
        // Pinned, and pinned to the right bytes — compared against the
        // server's own copy of its certificate rather than against a count
        // of rows, which the kernel handing out the same port twice would
        // make wrong.
        let presented = await unpinned.leafCertificateDER
        let pinned = try store.find(host: second.host, port: second.port)
        let pinnedTheRightCertificate = pinned?.derBase64 == presented?.base64EncodedString()
        #expect(pinnedTheRightCertificate)
        #expect(presented != nil)
    }

    /// A caller cancelled while it waits for the command turn is released,
    /// and the turn stays with whoever holds it.
    ///
    /// **Ruling T6.3, and it is not hygiene.** `acquire()` parked on a bare
    /// `withCheckedContinuation`, which ignores its task's cancellation, so a
    /// command issued while a transfer holds the turn could not be cancelled
    /// for as long as that transfer ran — and a transfer is as long as a file
    /// is. The same shape in `FTPConnectionPool.acquireTransfer` was measured
    /// outliving a 300-second time limit (fix round 1,
    /// `aWaiterForASlotAnswersCancellationRatherThanParkingForever`), which
    /// is what this one would do to a queue item too.
    ///
    /// It is also what makes `FTPTransferLease`'s concurrent-use path
    /// answerable: two `transferring` calls on one un-returned lease both
    /// pass the lease's guard, and they are correct — `transferCommand`'s
    /// turn serialises them — but the second one parks HERE, and before this
    /// it parked uncancellably.
    ///
    /// Three properties, because the first alone would hold for a connection
    /// that dropped the turn on the floor: the cancelled waiter ends in a
    /// cancellation; the turn is still held by the transfer that had it; and
    /// the connection is in step afterwards, which is the turn having been
    /// handed on exactly once. No clock — `turnWaiterCount` says when the
    /// waiter is really parked, and the drain parks on a latch this test
    /// raises itself.
    @Test func aWaiterForTheCommandTurnAnswersCancellation() async throws {
        let server = LoopbackFTPServer(
            security: .plain, advertisesMLSD: true, requiresTLSSessionReuse: false)
        let outcome = try await Self.running(server) { host, port in
            let connection = try await Self.connect(
                server, host: host, port: port, security: .plain)
            let passive = try Self.passiveEndpoint(try await connection.send("PASV", argument: nil))
            let data = try await connection.openDataConnection(
                host: passive.host, port: passive.port)
            let drained = AsyncSignal()
            let mayFinish = AsyncSignal()
            let transfer = Task {
                try await connection.transferCommand("LIST") {
                    _ = try await data.readToEnd()
                    drained.signal()
                    _ = await mayFinish.wait()
                }
            }
            _ = await drained.wait()

            // A second command on the same connection, which can only park:
            // the turn is held for the whole span of the transfer.
            let blocked = Task { try await connection.send("PWD", argument: nil) }
            try await pollUntil("the second command to park on the turn") {
                await connection.turnWaiterCount == 1
            }
            blocked.cancel()
            // **The bound, and it is this and not a `cancel()`** — the
            // cancel IS the property here, so it cannot also be the
            // backstop. `pollUntil` carries no deadline and ends only by
            // cancellation, so the suite's own time limit ends the case
            // LOUDLY if the waiter is never released, where
            // `await blocked.value` would have parked past it. Written this
            // way after the first draft used the value read and hung under
            // the plant — the fourth instance of that shape in this task,
            // inside the commit that removed the third.
            try await pollUntil("the cancelled turn waiter to be released") {
                await connection.turnWaiterCount == 0
            }
            // The turn did not move: the transfer still holds it.
            let heldByTheTransfer = await connection.turnIsHeld
            let waitersLeft = await connection.turnWaiterCount

            var waiterEnded = "no answer"
            do {
                waiterEnded = "answered(\(try await blocked.value.code))"
            } catch is CancellationError {
                waiterEnded = "cancelled"
            } catch let failure as FTPConnectionFailure {
                waiterEnded = "failed(\(failure))"
            } catch {
                waiterEnded = "otherError(\(String(describing: type(of: error))))"
            }

            mayFinish.signal()
            let completion = try await transfer.value.completion?.code
            // And the turn was handed on exactly once, which is what the
            // next command getting its OWN reply proves.
            let afterwards = try await connection.send("PWD", argument: nil).code
            await data.close()
            await connection.close()
            return (
                waiterEnded: waiterEnded, heldByTheTransfer: heldByTheTransfer,
                waitersLeft: waitersLeft, completion: completion, afterwards: afterwards
            )
        }
        #expect(outcome.waiterEnded == "cancelled")
        #expect(outcome.heldByTheTransfer)
        #expect(outcome.waitersLeft == 0)
        #expect(outcome.completion == 226)
        #expect(outcome.afterwards == 257)
    }

    /// The turn is handed to exactly one caller: a waiter that is resumed
    /// finds it HELD, not free.
    ///
    /// **Ruling T6.11, and the round that deferred this was wrong about
    /// why.** `release()` hands the turn on without clearing
    /// `commandInFlight`, because the resumed waiter owns it. Planting
    /// `commandInFlight = false` in front of the hand-off was GREEN across
    /// 62 tests, and fix round 2 recorded that as needing "a seam that can
    /// observe the turn is held by exactly one caller", called such a seam
    /// unavailable without a probabilistic three-way wire crossing, and
    /// deferred it to a backlog row. Withdrawn: the seam needs no third
    /// caller and no wire at all.
    ///
    /// What it needs is for the WAITER to be a transfer. A transfer's drain
    /// is the one suspension a test owns while the turn is held, so the flag
    /// can be read from inside the resumed waiter's own span — which is
    /// exactly the window the plant corrupts. Everything is ordered by a
    /// latch or by `turnWaiterCount`; there is no clock and no race.
    ///
    /// The reading pair, reproduced here rather than inherited (fixture
    /// depth 2 alone, then the same plus the plant):
    ///
    ///     heldInside=true  heldFromOutside=true  holder=226 waiter=226
    ///     heldInside=false heldFromOutside=false holder=226 waiter=226
    ///
    /// Both completions are `226` in both runs, which is the positive
    /// control "Guards that name what they watch" asks for: a `false`
    /// reading is a dropped turn and not a transfer that never ran.
    ///
    /// **The structural form is preferred and is owed.** Making the holder an
    /// identity — `private var turn: UUID?` with `commandInFlight` a computed
    /// `turn != nil` — stops `commandInFlight = false` being writable at all,
    /// and CLAUDE.md prefers a violation that will not compile to another
    /// anchor. It rewrites Task 5's turn representation across every caller,
    /// so it is not a fix-round edit; the closeout owns the row, and this
    /// case is what holds the property until then.
    @Test func theTurnIsHandedToExactlyOneWaiter() async throws {
        let server = LoopbackFTPServer(
            security: .plain, advertisesMLSD: true, requiresTLSSessionReuse: false,
            passiveDepth: 2)
        let outcome = try await Self.running(server) { host, port in
            let connection = try await Self.connect(
                server, host: host, port: port, security: .plain)
            // Both data connections are opened BEFORE either transfer takes
            // the turn: `PASV` and `openDataConnection` are themselves
            // commands, and one of them would otherwise park behind the
            // holder.
            let holderEndpoint = try Self.passiveEndpoint(
                try await connection.send("PASV", argument: nil))
            let holderData = try await connection.openDataConnection(
                host: holderEndpoint.host, port: holderEndpoint.port)
            let waiterEndpoint = try Self.passiveEndpoint(
                try await connection.send("PASV", argument: nil))
            let waiterData = try await connection.openDataConnection(
                host: waiterEndpoint.host, port: waiterEndpoint.port)

            let holderDrained = AsyncSignal()
            let holderMayFinish = AsyncSignal()
            let holder = Task {
                try await connection.transferCommand("LIST") {
                    _ = try await holderData.readToEnd()
                    holderDrained.signal()
                    _ = await holderMayFinish.wait()
                }
            }
            _ = await holderDrained.wait()

            // The waiter is a transfer too, so its drain runs inside the
            // span it was handed.
            let heldInside = FTPTurnReading()
            let waiterDrained = AsyncSignal()
            let waiterMayFinish = AsyncSignal()
            let waiter = Task {
                try await connection.transferCommand("LIST") {
                    heldInside.record(await connection.turnIsHeld)
                    _ = try await waiterData.readToEnd()
                    waiterDrained.signal()
                    _ = await waiterMayFinish.wait()
                }
            }
            try await pollUntil("the second transfer to park on the turn") {
                await connection.turnWaiterCount == 1
            }

            // Hand the turn over, then read the flag from inside the
            // waiter's own span and again from outside it.
            holderMayFinish.signal()
            let holderCompletion = try await holder.value.completion?.code
            _ = await waiterDrained.wait()
            let heldFromOutside = await connection.turnIsHeld
            waiterMayFinish.signal()
            let waiterCompletion = try await waiter.value.completion?.code

            await holderData.close()
            await waiterData.close()
            await connection.close()
            return (
                heldInside: heldInside.value, heldFromOutside: heldFromOutside,
                holder: holderCompletion, waiter: waiterCompletion
            )
        }
        print(
            "TURN heldInside=\(String(describing: outcome.heldInside))"
                + " heldFromOutside=\(outcome.heldFromOutside)"
                + " holder=\(String(describing: outcome.holder))"
                + " waiter=\(String(describing: outcome.waiter))")
        // The property.
        #expect(outcome.heldInside == true)
        #expect(outcome.heldFromOutside)
        // The positive control: both transfers really ran, so a `false`
        // above would be a dropped turn and not a transfer that never began.
        #expect(outcome.holder == 226)
        #expect(outcome.waiter == 226)
    }

    // MARK: - Failure text

    /// Every failure has a sentence of its own in all four catalogs, and the
    /// set under test is the compiler's rather than this file's.
    ///
    /// **The shape this replaces did not catch what it claimed.** It built a
    /// set by iterating a hand-written list of failures and compared its size
    /// to the literal `13`; a 14th case added to the enum, to its key mapping
    /// and to the test's own exhaustive `switch`, with a key no catalog
    /// declares, left it GREEN — the set was populated only from the list, so
    /// a case missing from the list was never counted. Now `Kind.allCases` is
    /// the compiler's list, `FTPConnectionFailure.kind` is exhaustive over
    /// the failure, and the set comparison below holds the two to each other
    /// in BOTH directions: a case missing from `all` makes the sets unequal,
    /// and so does a `Kind` no failure maps to.
    @Test func everyConnectionFailureHasItsOwnSentence() throws {
        let all: [FTPConnectionFailure] = [
            .greetingRefused(code: 421), .timedOut, .connectionClosed, .protocolViolation,
            .tlsUpgradeRefused(code: 502), .tlsHandshakeFailed, .loginRefused,
            .binaryModeRefused(code: 504),
            .credentialNotSendable, .certificateRejected, .certificateMismatch,
            .trustStoreUnreadable, .dataCertificateDiffers, .sessionFromAnotherConnection,
            .sessionRefusedByTLS,
            .passiveAddressRefused, .passiveModeRefused(code: 500),
            .transferRefused(code: 522), .restRefused(code: 501),
            .leaseAlreadyReturned,
        ]
        #expect(Set(all.map(\.kind)) == Set(FTPConnectionFailure.Kind.allCases))
        // Positive that the comparison is about something: an empty tag set
        // would satisfy an equality with an empty list of failures.
        #expect(!FTPConnectionFailure.Kind.allCases.isEmpty)

        for kind in FTPConnectionFailure.Kind.allCases {
            #expect(
                CoreL10n.string(kind.messageKey) != kind.messageKey,
                "no catalog text for \(kind.messageKey)")
        }
        // And the failures reach their own sentence, not just the tags.
        for failure in all {
            #expect(failure.message != failure.messageKey, "no catalog text for \(failure.messageKey)")
        }
        // Positive for the check itself: a key no catalog declares DOES come
        // back as its own text, so the comparisons above can fail.
        #expect(CoreL10n.string("core.connect.ftpNoSuchKey") == "core.connect.ftpNoSuchKey")
    }

    // MARK: - Source scanning

    private static var ftpSourceDirectory: URL {
        SourceCorpus.url(of: .sources)
            .appendingPathComponent("macSCPCore", isDirectory: true)
            .appendingPathComponent("FTP", isDirectory: true)
    }

    /// Every FTP source, comments blanked and string literals KEPT: the
    /// scans here look for literals, and a comment that quotes one is
    /// indistinguishable from it (CLAUDE.md, "Source-scanning guards read
    /// comments too").
    private static func ftpSources() throws -> [(name: String, text: String)] {
        let urls = try SourceCorpus.files(under: ftpSourceDirectory)
            .filter { $0.pathExtension == "swift" }
        let views = try SourceCorpus.commentFree(ofAll: urls)
        return urls.indices.map { (urls[$0].lastPathComponent, views[$0]) }
    }

    /// Non-overlapping occurrences of `token`. `grep -c` counts LINES, which
    /// is the wrong tool for "how many times does this appear" (CLAUDE.md);
    /// so is `contains`, which cannot tell one from two.
    private static func occurrences(of token: String, in text: String) -> Int {
        guard !token.isEmpty else { return 0 }
        var count = 0
        var searched = text.startIndex
        while let found = text.range(of: token, range: searched..<text.endIndex) {
            count += 1
            searched = found.upperBound
        }
        return count
    }

    /// The brace-balanced body after `anchor`, found in the fully blanked
    /// view and cut out of the one that kept its string literals.
    ///
    /// Two views, because neither does the job alone: braces inside a string
    /// literal would decide where a body ends in the second, and the literal
    /// this scan is looking for is gone from the first. `SourceCorpus`
    /// refuses a view that is not as long, in `Character`s, as the text it
    /// came from, which is what makes an offset found in one usable in the
    /// other.
    private static func body(
        after anchor: String, inBlanked blanked: String, slicing withStrings: String
    ) -> String? {
        guard let span = SourceSpan.bodySpan(after: anchor, in: blanked) else { return nil }
        let start = blanked.distance(from: blanked.startIndex, to: blanked.index(after: span.open))
        let end = blanked.distance(from: blanked.startIndex, to: span.close)
        guard withStrings.count >= end else { return nil }
        let from = withStrings.index(withStrings.startIndex, offsetBy: start)
        let to = withStrings.index(withStrings.startIndex, offsetBy: end)
        return String(withStrings[from..<to])
    }
}
