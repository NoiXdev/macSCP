import Foundation
import MacSCPTestSupport
import NIOCore
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
        trustStore: TrustedCertificateStore? = nil, password: String? = nil
    ) async -> DialOutcome {
        let credentials = server.credentials
        do {
            let connection = try await FTPControlConnection.connect(
                Self.config(host: host, port: port, security: security, username: credentials.username),
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
            let reply = try await connection.send("LIST", argument: nil)
            if reply.code == 150 {
                _ = try await data.readToEnd()
                _ = try await connection.readFurtherReply()
            }
            await data.close()
            let resumed = data.didResumeTLSSession
            await connection.close()
            return (reply: reply, resumed: resumed)
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
                    owner: other.identity, timeout: .seconds(30))
                await stolen.close()
            } catch let failure as FTPConnectionFailure {
                refusal = failure
            }

            // The positive beside it: the owner's own data connection gets
            // the same protection on the same listener and is served.
            let data = try await FTPControlConnection.openDataConnection(
                host: passive.host, port: passive.port, protection: protection,
                owner: mine.identity, timeout: .seconds(30))
            let reply = try await mine.send("LIST", argument: nil)
            if reply.code == 150 {
                _ = try await data.readToEnd()
                _ = try await mine.readFurtherReply()
            }
            await data.close()
            await mine.close()
            await other.close()
            return (refusal: refusal, reply: reply)
        }
        #expect(outcome.refusal == .sessionFromAnotherConnection)
        #expect(outcome.reply.code == 150)
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
                password: "", certificateDecider: .refusing, timeout: bound)
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

    // MARK: - Failure text

    /// Every failure has a sentence of its own in all four catalogs.
    ///
    /// The `switch` is exhaustive over the enum, so a case added to it does
    /// not compile until it is named here; the count then holds `all` to the
    /// same set, so a case named in the `switch` but missing from `all` fails
    /// too. The lookup itself cannot fail loudly — `CoreL10n.string` falls
    /// back to the key text — so the check is that a key does NOT come back
    /// as itself.
    @Test func everyConnectionFailureHasItsOwnSentence() throws {
        let all: [FTPConnectionFailure] = [
            .greetingRefused(code: 421), .timedOut, .connectionClosed, .protocolViolation,
            .tlsUpgradeRefused(code: 502), .tlsHandshakeFailed, .loginRefused,
            .certificateRejected, .certificateMismatch, .trustStoreUnreadable,
            .dataCertificateDiffers, .sessionFromAnotherConnection, .sessionRefusedByTLS,
        ]
        var named: Set<String> = []
        for failure in all {
            switch failure {
            case .greetingRefused: named.insert("greetingRefused")
            case .timedOut: named.insert("timedOut")
            case .connectionClosed: named.insert("connectionClosed")
            case .protocolViolation: named.insert("protocolViolation")
            case .tlsUpgradeRefused: named.insert("tlsUpgradeRefused")
            case .tlsHandshakeFailed: named.insert("tlsHandshakeFailed")
            case .loginRefused: named.insert("loginRefused")
            case .certificateRejected: named.insert("certificateRejected")
            case .certificateMismatch: named.insert("certificateMismatch")
            case .trustStoreUnreadable: named.insert("trustStoreUnreadable")
            case .dataCertificateDiffers: named.insert("dataCertificateDiffers")
            case .sessionFromAnotherConnection: named.insert("sessionFromAnotherConnection")
            case .sessionRefusedByTLS: named.insert("sessionRefusedByTLS")
            }
        }
        #expect(named.count == 13)
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
