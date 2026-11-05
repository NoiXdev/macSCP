import Foundation
import MacSCPTestSupport
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import Testing

@testable import macSCPCore

/// The in-process FTP/FTPS server and the seams the later FTP tasks lean on.
///
/// Every test here drives the server with `LoopbackFTPClient`, which is a test
/// aid and not the production client. The server's credentials are generated
/// per instance (`LoopbackFTPCredentials`); no expectation below names them,
/// and the ones that ask whether a credential leaked compute a `Bool` first,
/// because `#expect` prints the source text of what it checks.
@Suite("Loopback FTP server", .timeLimit(.minutes(5)))
struct LoopbackFTPServerTests {
    // MARK: Helpers

    /// Starts `server`, runs `body` against it and always stops it.
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

    /// The feature names of a `FEAT` reply, with the leading space stripped.
    private static func features(_ reply: FTPReply) -> Set<String> {
        Set(reply.lines.map { $0.trimmingCharacters(in: .whitespaces) })
    }

    /// `(a,b,c,d,p1,p2)` out of a `227` reply.
    private static func passiveEndpoint(_ reply: FTPReply) throws -> (host: String, port: Int) {
        let text = reply.lines.joined(separator: " ")
        let open = try #require(text.firstIndex(of: "("))
        let close = try #require(text.firstIndex(of: ")"))
        let numbers = text[text.index(after: open)..<close].split(separator: ",").compactMap { Int($0) }
        try #require(numbers.count == 6)
        return (numbers[0..<4].map(String.init).joined(separator: "."), numbers[4] * 256 + numbers[5])
    }

    /// The port out of a `229` reply, `(|||port|)`.
    private static func extendedPort(_ reply: FTPReply) throws -> Int {
        let text = reply.lines.joined(separator: " ")
        let open = try #require(text.range(of: "(|||"))
        let close = try #require(text.range(of: "|)"))
        return try #require(Int(text[open.upperBound..<close.lowerBound]))
    }

    /// Connects over a control connection that is already logged in over TLS
    /// (explicit mode, `PROT P` set) and returns it with the greeting read.
    private static func protectedLogin(
        host: String, port: Int, credentials: LoopbackFTPCredentials
    ) async throws -> LoopbackFTPClient {
        let client = try await LoopbackFTPClient.connect(host: host, port: port)
        _ = try await client.readReply()
        _ = try await client.command("AUTH TLS")
        try await client.startTLS()
        _ = try await client.command("PBSZ 0")
        _ = try await client.command("PROT P")
        _ = try await client.login(credentials)
        return client
    }

    // MARK: The three security modes

    @Test func theLoopbackServerCompletesAPlainLoginAndReportsFEAT() async throws {
        let server = LoopbackFTPServer(
            security: .plain, advertisesMLSD: true, requiresTLSSessionReuse: false)
        let credentials = server.credentials
        try await Self.running(server) { host, port in
            let client = try await LoopbackFTPClient.connect(host: host, port: port)
            let greeting = try await client.readReply()
            #expect(greeting.code == 220)

            let login = try await client.login(credentials)
            #expect(login.code == 230)

            let features = Self.features(try await client.command("FEAT"))
            // Positive beside the negative: the list is the server's real one,
            // so an absent AUTH means something.
            #expect(features.contains("UTF8"))
            #expect(features.contains("MLSD"))
            #expect(!features.contains("AUTH TLS"))
            await client.close()
        }

        let commands = await server.receivedCommands
        #expect(commands.contains { $0.verb == "PASS" })
        #expect(commands.allSatisfy { !$0.overTLS })
        // The password is never written to the log; computed first so a
        // failure cannot print it.
        let passwordLogged = commands.contains { $0.argument == credentials.password }
        #expect(passwordLogged == false)
    }

    @Test func aWrongPasswordIsRefusedWith530() async throws {
        let server = LoopbackFTPServer(
            security: .plain, advertisesMLSD: true, requiresTLSSessionReuse: false)
        try await Self.running(server) { host, port in
            let client = try await LoopbackFTPClient.connect(host: host, port: port)
            _ = try await client.readReply()
            _ = try await client.command("USER someone")
            let reply = try await client.command("PASS not-the-password")
            #expect(reply.code == 530)
            // Not logged in, so a listing is refused for that reason.
            let refused = try await client.command("PWD")
            #expect(refused.code == 530)
            await client.close()
        }
    }

    @Test func theLoopbackServerUpgradesOnAUTHTLSWhenConfiguredExplicit() async throws {
        let server = LoopbackFTPServer(
            security: .explicitTLS, advertisesMLSD: true, requiresTLSSessionReuse: false)
        let credentials = server.credentials
        try await Self.running(server) { host, port in
            let client = try await LoopbackFTPClient.connect(host: host, port: port)
            #expect(try await client.readReply().code == 220)
            let features = Self.features(try await client.command("FEAT"))
            #expect(features.contains("AUTH TLS"))

            // Credentials are refused in the clear.
            #expect(try await client.command("USER anyone").code == 530)

            #expect(try await client.command("AUTH TLS").code == 234)
            try await client.startTLS()
            #expect(try await client.command("PBSZ 0").code == 200)
            #expect(try await client.command("PROT P").code == 200)
            #expect(try await client.login(credentials).code == 230)
            await client.close()
        }

        let commands = await server.receivedCommands
        // A Bool, computed first: a failed `#expect` on a record would print the
        // record, and the record is what the redaction exists to keep clean.
        let passwordsOverTLS = commands.filter { $0.verb == "PASS" }.allSatisfy(\.overTLS)
        let passwordSeen = commands.contains { $0.verb == "PASS" }
        #expect(passwordSeen)
        #expect(passwordsOverTLS)
        // The upgrade happened exactly once, on the control connection, and
        // it was a full handshake (nothing to resume yet).
        #expect(await server.handshakes == [.init(connection: .control, resumed: false)])
    }

    @Test func theLoopbackServerSpeaksTLSFromTheFirstByteWhenConfiguredImplicit() async throws {
        let server = LoopbackFTPServer(
            security: .implicitTLS, advertisesMLSD: true, requiresTLSSessionReuse: false)
        let credentials = server.credentials
        try await Self.running(server) { host, port in
            let client = try await LoopbackFTPClient.connect(
                host: host, port: port, implicitTLS: true)
            #expect(try await client.readReply().code == 220)
            #expect(try await client.login(credentials).code == 230)
            await client.close()

            // The negative: a client that does not speak TLS first never gets
            // a greeting. The positive is the lines above.
            let plain = try await LoopbackFTPClient.connect(host: host, port: port)
            try await plain.send("NOOP")
            let greeting = try? await plain.readReply()
            #expect(greeting?.code != 220)
            await plain.close()
        }

        let commands = await server.receivedCommands
        let passwordsOverTLS = commands.filter { $0.verb == "PASS" }.allSatisfy(\.overTLS)
        let passwordSeen = commands.contains { $0.verb == "PASS" }
        #expect(passwordSeen)
        #expect(passwordsOverTLS)
        #expect(await server.handshakes.first == .init(connection: .control, resumed: false))
    }

    @Test func theCertificateIsMintedAtRunTimeAndOnlyForTheModesThatNeedOne() async throws {
        let plain = LoopbackFTPServer(
            security: .plain, advertisesMLSD: true, requiresTLSSessionReuse: false)
        let explicit = LoopbackFTPServer(
            security: .explicitTLS, advertisesMLSD: true, requiresTLSSessionReuse: false)
        let other = LoopbackFTPServer(
            security: .explicitTLS, advertisesMLSD: true, requiresTLSSessionReuse: false)
        _ = try await plain.start()
        _ = try await explicit.start()
        _ = try await other.start()
        let plainCertificate = await plain.leafCertificateDER
        let explicitCertificate = await explicit.leafCertificateDER
        let otherCertificate = await other.leafCertificateDER
        await plain.stop()
        await explicit.stop()
        await other.stop()

        #expect(plainCertificate == nil)
        #expect(!(explicitCertificate ?? Data()).isEmpty)
        // Two servers never share a certificate: nothing is a fixture.
        #expect(explicitCertificate != otherCertificate)
    }

    // MARK: The hostile seams

    @Test func theLoopbackServerCanBeToldToRefuseWith421() async throws {
        let server = LoopbackFTPServer(
            security: .plain, advertisesMLSD: true, requiresTLSSessionReuse: false)
        try await Self.running(server) { host, port in
            await server.refuseNextAcquireWith421()

            let refused = try await LoopbackFTPClient.connect(host: host, port: port)
            let reply = try await refused.readReply()
            #expect(reply.code == 421)
            #expect(reply.isTransient)
            // ... and the server hung up.
            await #expect(throws: LoopbackFTPClientError.connectionClosed) {
                _ = try await refused.readReply()
            }
            await refused.close()

            // One shot: the next connection is served.
            let served = try await LoopbackFTPClient.connect(host: host, port: port)
            #expect(try await served.readReply().code == 220)
            await served.close()
        }
        #expect(await server.controlConnectionCount == 2)
    }

    @Test func aDesynchronisedReplyLeavesTheStreamOneReplyAhead() async throws {
        let server = LoopbackFTPServer(
            security: .plain, advertisesMLSD: true, requiresTLSSessionReuse: false)
        let credentials = server.credentials
        try await Self.running(server) { host, port in
            let client = try await LoopbackFTPClient.connect(host: host, port: port)
            _ = try await client.readReply()
            _ = try await client.login(credentials)

            // Without the seam the stream is in step.
            #expect(try await client.command("PWD").code == 257)

            await server.desynchroniseNextReply()
            #expect(try await client.command("NOOP").code == 200)
            // The next command's reply is the stale one, and its own comes
            // after it.
            let stale = try await client.command("PWD")
            #expect(stale.code == 200)
            #expect(try await client.readReply().code == 257)
            await client.close()
        }
    }

    @Test func aPASVReplyCanNameAnotherHostAndEPSVIsUnaffected() async throws {
        let server = LoopbackFTPServer(
            security: .plain, advertisesMLSD: true, requiresTLSSessionReuse: false)
        let credentials = server.credentials
        try await Self.running(server) { host, port in
            let client = try await LoopbackFTPClient.connect(host: host, port: port)
            _ = try await client.readReply()
            _ = try await client.login(credentials)

            let honest = try Self.passiveEndpoint(try await client.command("PASV"))
            #expect(honest.host == "127.0.0.1")

            await server.answerPASVWith(host: "203.0.113.9")
            let lying = try Self.passiveEndpoint(try await client.command("PASV"))
            #expect(lying.host == "203.0.113.9")
            #expect(lying.port > 0)

            let extended = try await client.command("EPSV")
            #expect(extended.code == 229)
            #expect(try Self.extendedPort(extended) > 0)
            await client.close()
        }
    }

    @Test func theControlConnectionCanBeDroppedMidTransfer() async throws {
        let server = LoopbackFTPServer(
            security: .plain, advertisesMLSD: true, requiresTLSSessionReuse: false)
        let credentials = server.credentials
        let content = Data(repeating: 0x41, count: 64 * 1024)
        await server.seedFile("/big.bin", contents: content)
        try await Self.running(server) { host, port in
            let client = try await LoopbackFTPClient.connect(host: host, port: port)
            _ = try await client.readReply()
            _ = try await client.login(credentials)

            let endpoint = try Self.passiveEndpoint(try await client.command("PASV"))
            await server.dropControlConnectionMidTransfer()
            let data = try await client.openData(host: host, port: endpoint.port, protected: false)
            try await client.send("RETR big.bin")
            #expect(try await client.readReply().code == 150)

            let received = try await data.readToEnd()
            #expect(received.count == content.count / 2)
            await #expect(throws: LoopbackFTPClientError.connectionClosed) {
                _ = try await client.readReply()
            }
            await client.close()
        }
    }

    // MARK: Protocol behaviour the later tasks rely on

    @Test func listingsAndTransfersWorkOverPassiveMode() async throws {
        let server = LoopbackFTPServer(
            security: .plain, advertisesMLSD: true, requiresTLSSessionReuse: false)
        let credentials = server.credentials
        await server.seedFile("/docs/readme.txt", contents: Data("hello".utf8))
        try await Self.running(server) { host, port in
            let client = try await LoopbackFTPClient.connect(host: host, port: port)
            _ = try await client.readReply()
            _ = try await client.login(credentials)

            func passive() async throws -> LoopbackFTPClientData {
                let endpoint = try Self.passiveEndpoint(try await client.command("PASV"))
                return try await client.openData(host: host, port: endpoint.port, protected: false)
            }

            // LIST (unix format) and MLSD (facts) both carry the entry.
            let list = try await passive()
            try await client.send("LIST /docs")
            #expect(try await client.readReply().code == 150)
            let listing = String(decoding: try await list.readToEnd(), as: UTF8.self)
            #expect(try await client.readReply().code == 226)
            #expect(listing.contains("readme.txt"))
            #expect(listing.contains("5 Jan"))

            let facts = try await passive()
            try await client.send("MLSD /docs")
            #expect(try await client.readReply().code == 150)
            let mlsd = String(decoding: try await facts.readToEnd(), as: UTF8.self)
            #expect(try await client.readReply().code == 226)
            #expect(mlsd.contains("type=file;size=5;"))

            // Upload, then fetch it back.
            let upload = try await passive()
            try await client.send("STOR /docs/new.bin")
            #expect(try await client.readReply().code == 150)
            try await upload.write(Data([1, 2, 3, 4]))
            await upload.close()
            #expect(try await client.readReply().code == 226)
            #expect(try await client.command("SIZE /docs/new.bin").lines == ["4"])

            let download = try await passive()
            try await client.send("RETR /docs/new.bin")
            #expect(try await client.readReply().code == 150)
            #expect(try await download.readToEnd() == Data([1, 2, 3, 4]))
            #expect(try await client.readReply().code == 226)

            #expect(try await client.command("DELE /docs/new.bin").code == 250)
            #expect(try await client.command("SIZE /docs/new.bin").code == 550)
            await client.close()
        }
        // The uploaded file was visible to the server as bytes, then removed.
        #expect(await server.contents(of: "/docs/new.bin") == nil)
        #expect(await server.contents(of: "/docs/readme.txt") == Data("hello".utf8))
    }

    @Test func aServerThatDoesNotAdvertiseMLSDRefusesIt() async throws {
        let server = LoopbackFTPServer(
            security: .plain, advertisesMLSD: false, requiresTLSSessionReuse: false)
        let credentials = server.credentials
        try await Self.running(server) { host, port in
            let client = try await LoopbackFTPClient.connect(host: host, port: port)
            _ = try await client.readReply()
            _ = try await client.login(credentials)
            let features = Self.features(try await client.command("FEAT"))
            #expect(features.contains("UTF8"))
            #expect(!features.contains("MLSD"))
            #expect(!features.contains { $0.hasPrefix("MLST") })
            #expect(try await client.command("MLSD").code == 500)
            // LIST is what is left.
            #expect(try await client.command("PASV").code == 227)
            await client.close()
        }
    }

    @Test func stopClosesTheListenerAndCanBeCalledTwice() async throws {
        let server = LoopbackFTPServer(
            security: .plain, advertisesMLSD: true, requiresTLSSessionReuse: false)
        let endpoint = try await server.start()
        let before = try await LoopbackFTPClient.connect(host: endpoint.host, port: endpoint.port)
        #expect(try await before.readReply().code == 220)
        await server.stop()
        await server.stop()
        // The open connection was ended by the stop ...
        await #expect(throws: LoopbackFTPClientError.connectionClosed) {
            _ = try await before.readReply()
        }
        // ... and nothing listens any more.
        await #expect(throws: (any Error).self) {
            _ = try await LoopbackFTPClient.connect(host: endpoint.host, port: endpoint.port)
        }
    }

    // MARK: require_ssl_reuse

    /// Drives one `LIST` over a protected data connection that starts a fresh
    /// handshake (the only kind swift-nio-ssl's client can start) and returns
    /// the reply to it.
    private static func protectedList(
        host: String, port: Int, credentials: LoopbackFTPCredentials
    ) async throws -> FTPReply {
        let client = try await protectedLogin(host: host, port: port, credentials: credentials)
        let endpoint = try passiveEndpoint(try await client.command("PASV"))
        let data = try await client.openData(host: host, port: endpoint.port, protected: true)
        try await client.send("LIST")
        let outcome = try await client.readReply()
        if outcome.code == 150 {
            _ = try await data.readToEnd()
            _ = try await client.readReply()
        }
        await data.close()
        await client.close()
        return outcome
    }

    /// The positive control for the whole seam: a client that DOES resume, and
    /// the server telling the two kinds of handshake apart. `openssl s_client
    /// -reconnect` makes one full handshake and several that offer the first
    /// session again; its own report ("New" once, "Reused" for each of the
    /// others) is the oracle, independent of the inspector under test. Pinned to TLS 1.2,
    /// where LibreSSL's `-reconnect` completes (a TLS 1.3 run of the same
    /// command against a Network.framework listener was killed after 90 s
    /// without finishing and is not measured).
    @Test func theServerReadsAResumedHandshakeOffTheWire() async throws {
        let server = LoopbackFTPServer(
            security: .implicitTLS, advertisesMLSD: true, requiresTLSSessionReuse: false,
            maximumTLSVersion: .tlsv12)
        let endpoint = try await server.start()
        let result: SubprocessResult
        do {
            result = try await SubprocessRunner.run(
                URL(fileURLWithPath: "/usr/bin/openssl"),
                arguments: [
                    "s_client", "-connect", "\(endpoint.host):\(endpoint.port)",
                    "-reconnect", "-tls1_2",
                ])
        } catch {
            await server.stop()
            throw error
        }
        await server.stop()

        let report = result.stdoutText.split(separator: "\n")
        let clientNew = report.filter { $0.hasPrefix("New,") }.count
        let clientReused = report.filter { $0.hasPrefix("Reused,") }.count
        // The property, not the count `-reconnect` happens to use: the client
        // made one full handshake and at least one resumption, and the server
        // saw exactly the same split, in the same order.
        #expect(clientNew == 1)
        #expect(clientReused >= 1)

        let handshakes = await server.handshakes
        let expected =
            [LoopbackFTPHandshake(connection: .control, resumed: false)]
            + Array(repeating: LoopbackFTPHandshake(connection: .control, resumed: true), count: clientReused)
        #expect(handshakes == expected)
    }

    /// The acceptance half of the `require_ssl_reuse` seam, which needs a client
    /// that can resume across two connections to two different ports. The two
    /// stacks a Swift client could use cannot (see the dependency record), so
    /// this one borrows `openssl s_client`: it saves a session to a file on a
    /// first connection and offers it on a second, to the data port.
    ///
    /// What the server enforces is "this data handshake resumed SOME session
    /// this server issued", which is what the inspector can see on the wire --
    /// not "the control connection's own session". Here the saved session comes
    /// from an earlier control connection, not from the one issuing `LIST`, and
    /// the server accepts it. The stricter reading -- the data session must be
    /// the control connection's own -- is not enforced and not tested.
    @Test func aServerThatRequiresSessionReuseAcceptsAResumedDataHandshake() async throws {
        let server = LoopbackFTPServer(
            security: .implicitTLS, advertisesMLSD: true, requiresTLSSessionReuse: true,
            maximumTLSVersion: .tlsv12)
        let credentials = server.credentials
        await server.seedFile("/inbox/report.txt", contents: Data("x".utf8))
        let openssl = URL(fileURLWithPath: "/usr/bin/openssl")
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-ftp-session-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sessionFile = directory.appendingPathComponent("session.pem").path(percentEncoded: false)

        let endpoint = try await server.start()
        let outcome: (reply: FTPReply, listing: String, closing: FTPReply)
        do {
            // A first connection whose only job is to leave a session behind.
            let seed = try await SubprocessRunner.run(
                openssl,
                arguments: [
                    "s_client", "-connect", "\(endpoint.host):\(endpoint.port)",
                    "-tls1_2", "-quiet", "-sess_out", sessionFile,
                ], stdin: Data("QUIT\r\n".utf8))
            #expect(seed.status == 0)
            #expect(FileManager.default.fileExists(atPath: sessionFile))

            let client = try await LoopbackFTPClient.connect(
                host: endpoint.host, port: endpoint.port, implicitTLS: true)
            _ = try await client.readReply()
            _ = try await client.login(credentials)
            _ = try await client.command("PBSZ 0")
            _ = try await client.command("PROT P")
            let passive = try Self.passiveEndpoint(try await client.command("PASV"))
            try await client.send("LIST /inbox")

            // `stdin: Data()` is an empty pipe, not the null device: s_client
            // polls its standard input, macOS cannot poll /dev/null, and
            // without a pollable stdin it printed "poll error" and exited
            // before reading the listing (measured while writing this test).
            let data = try await SubprocessRunner.run(
                openssl,
                arguments: [
                    "s_client", "-connect", "\(endpoint.host):\(passive.port)",
                    "-tls1_2", "-quiet", "-ign_eof", "-sess_in", sessionFile,
                ], stdin: Data())
            let first = try await client.readReply()
            // A refusal ends the exchange at its one reply (`522`); reading a
            // second reply then would wait for a `226` that never comes and
            // turn an assertion failure into a hang.
            let last = first.code == 150 ? try await client.readReply() : first
            await client.close()
            outcome = (first, data.stdoutText, last)
        } catch {
            await server.stop()
            throw error
        }
        await server.stop()

        #expect(outcome.reply.code == 150)
        #expect(outcome.closing.code == 226)
        #expect(outcome.listing.contains("report.txt"))
        #expect(await server.refusedDataConnectionCount == 0)
        // The last handshake is the data connection's, and it resumed.
        #expect(await server.handshakes.last == .init(connection: .data, resumed: true))
    }

    @Test func aServerThatRequiresSessionReuseRefusesAFreshDataHandshake() async throws {
        let server = LoopbackFTPServer(
            security: .explicitTLS, advertisesMLSD: true, requiresTLSSessionReuse: true)
        let credentials = server.credentials
        let reply = try await Self.running(server) { host, port in
            try await Self.protectedList(host: host, port: port, credentials: credentials)
        }
        #expect(reply.code == 522)
        #expect(await server.refusedDataConnectionCount == 1)
        // What the refusal rested on: the control handshake and the data
        // handshake were both full ones.
        #expect(
            await server.handshakes == [
                .init(connection: .control, resumed: false),
                .init(connection: .data, resumed: false),
            ])
    }

    @Test func aServerThatDoesNotRequireSessionReuseServesTheSameFreshHandshake() async throws {
        let server = LoopbackFTPServer(
            security: .explicitTLS, advertisesMLSD: true, requiresTLSSessionReuse: false)
        let credentials = server.credentials
        let reply = try await Self.running(server) { host, port in
            try await Self.protectedList(host: host, port: port, credentials: credentials)
        }
        // Same client, same handshake, no refusal: the flag was the only
        // difference between this test and the one above.
        #expect(reply.code == 150)
        #expect(await server.refusedDataConnectionCount == 0)
        #expect(await server.handshakes.last == .init(connection: .data, resumed: false))
    }

    // MARK: Fix round 1

    /// F11. `PASS`'s argument is what keeps a credential out of every record this
    /// server hands back, and so out of any failure report that prints one.
    @Test func thePASSArgumentIsRedactedInEveryRecordAndOnlyThatOne() async throws {
        let server = LoopbackFTPServer(
            security: .plain, advertisesMLSD: true, requiresTLSSessionReuse: false)
        let credentials = server.credentials
        try await Self.running(server) { host, port in
            let client = try await LoopbackFTPClient.connect(host: host, port: port)
            _ = try await client.readReply()
            _ = try await client.login(credentials)
            // A second attempt with a different secret: redaction must not
            // depend on the attempt having succeeded.
            _ = try await client.command("PASS another-attempt-value")
            await client.close()
        }
        let commands = await server.receivedCommands

        let passRecords = commands.filter { $0.verb == "PASS" }
        // Computed first; a failed `#expect` on a record would print it.
        //
        // The marker is spelled as a LITERAL on purpose, and must stay one.
        // Reading `LoopbackFTPReceivedCommand.redactedArgument` here would look
        // tidier (a second copy of a name is a rename waiting to happen) and
        // would make this pin satisfied by whatever value the symbol holds: a
        // plant that changes the marker would then pass. The literal is what
        // makes the pin bite -- measured in fix round 1, where the plant
        // `redactedArgument = ""` was caught by this test and by nothing else.
        let allRedacted = passRecords.allSatisfy { $0.argument == "<redacted>" }
        let anyFieldCarriesIt = commands.contains {
            $0.argument.contains(credentials.password) || $0.verb.contains(credentials.password)
        }
        let anyFieldCarriesTheOtherAttempt = commands.contains {
            $0.argument.contains("another-attempt-value")
        }
        let usernameKept = commands.contains {
            $0.verb == "USER" && $0.argument == credentials.username
        }
        #expect(passRecords.count == 2)
        #expect(allRedacted)
        #expect(anyFieldCarriesIt == false)
        #expect(anyFieldCarriesTheOtherAttempt == false)
        // The positive beside the negatives: the log does record arguments, so
        // "no record carries the password" is a statement about redaction and
        // not about an empty log.
        #expect(usernameKept)
    }

    /// G5. A stopped server can be started again, and the second run serves.
    /// `stopping` is irreversible in the state, so without `start()` clearing it
    /// the second run would close every connection on arrival and the client
    /// would see a bare close instead of a greeting.
    @Test func aStoppedServerCanBeStartedAgainAndServesTheSecondRun() async throws {
        let server = LoopbackFTPServer(
            security: .plain, advertisesMLSD: true, requiresTLSSessionReuse: false)
        _ = try await server.start()
        await server.stop()
        let second = try await server.start()
        let client = try await LoopbackFTPClient.connect(host: second.host, port: second.port)
        let greeting = try await client.readReply()
        await client.close()
        await server.stop()
        #expect(greeting.code == 220)
        // The second run's connection is the only one it counted.
        #expect(await server.controlConnectionCount == 1)
    }

    /// G6. A TLS handshake that fails with a transport error says so, as the
    /// other two waits do. A plain server answers a TLS ClientHello with a
    /// plaintext greeting, which the client's TLS layer cannot parse.
    @Test func aFailedHandshakeSurfacesTheTransportsError() async throws {
        let server = LoopbackFTPServer(
            security: .plain, advertisesMLSD: true, requiresTLSSessionReuse: false)
        let endpoint = try await server.start()
        var surfaced = false
        do {
            _ = try await LoopbackFTPClient.connect(
                host: endpoint.host, port: endpoint.port, implicitTLS: true, replyBound: .seconds(30))
        } catch LoopbackFTPClientError.connectionFailed(let description) {
            surfaced = !description.isEmpty
        } catch {
            surfaced = false
        }
        await server.stop()
        #expect(surfaced)
    }

    /// G4. A channel nobody can be handed (the accept loop's stream has ended) is
    /// closed by a closer that `stop()` can await, not by a detached task that
    /// holds the channel, its descriptor and a loop reference for as long as it
    /// lives. Real channels on a real loopback connection: a server whose
    /// children are wrapped and announced exactly as `LoopbackFTPServer` does it,
    /// against a stream that is already finished.
    @Test func anUndeliverableChannelIsClosedByARegisteredCloser() async throws {
        let state = LoopbackFTPState()
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let (_, continuation) = AsyncStream.makeStream(
            of: NIOAsyncChannel<ByteBuffer, ByteBuffer>.self)
        continuation.finish()
        let listener = try await awaitCancellably(
            ServerBootstrap(group: group)
                .childChannelInitializer { channel in
                    channel.eventLoop.makeCompletedFuture {
                        let wrapped = try NIOAsyncChannel<ByteBuffer, ByteBuffer>(
                            wrappingChannelSynchronously: channel)
                        try channel.pipeline.syncOperations.addHandler(
                            LoopbackActivationAnnouncer {
                                LoopbackFTPServer.hand(wrapped, to: continuation, state: state)
                            })
                    }
                }
                .bind(host: "127.0.0.1", port: 0))
        let port = try #require(listener.localAddress?.port)
        let client = try await LoopbackFTPClient.connect(
            host: "127.0.0.1", port: port, replyBound: .seconds(30))

        // The announcer fires on the server's loop, after the client's connect
        // returned; wait for the registration, not for a time.
        try await pollUntil("the closer is registered") {
            state.box.withLockedValue { !$0.reapers.isEmpty }
        }
        let closers = state.takeReapers()
        #expect(closers.count == 1)
        for closer in closers { await closer.value }
        // Awaiting the closer is what closed the channel: the client sees it.
        await #expect(throws: LoopbackFTPClientError.connectionClosed) {
            _ = try await client.readReply()
        }

        await client.close()
        _ = try await awaitCancellably(listener.close())
        try await group.shutdownGracefully()
    }

#if compiler(>=6.2)
    // MARK: Exit tests
    //
    // `#expect(processExitsWith:)` needs the Swift 6.2-era Testing library, and
    // the gate runs on `macos-latest`. `.github/workflows/ci.yml` records, in its
    // own comment, that in run 40913494898 (2026-10-29) that label resolved to a
    // runner with Xcode 16.4 / Swift 6.1.2 selected, and that the run went red
    // because code a newer toolchain accepts can still fail the build there. An
    // unwrapped exit test would not fail one test on such a runner; the whole
    // Core test target would not compile, and all of its tests would be lost.
    // The wrapper keeps the target building; on a toolchain that has the feature
    // each of these is a real pin, and the guards they test stand regardless.
    //
    // `.signal(SIGTRAP)`, not `.failure`: the re-review of fix round 2 planted a
    // disabled guard with the body `exit(3)` and `.failure` stayed green, because
    // it pins only "the child exited non-zero"; it also measured a failed
    // `precondition` as SIGTRAP in `-Onone` and `-O` alike. The message is
    // checked in debug builds only (release strips it), and it is what tells the
    // guard's trap from `AsyncStream`'s own. The waits for "a read is in flight"
    // spin a bounded number of times (a count, not a clock): without the guard
    // the first read never says it is in flight, and an unbounded wait would
    // hang the child instead of failing the test.

    /// What an exit test observes of the child, and whether it trapped in the
    /// guard (the message names the cause) rather than anywhere else.
    private static func trappedWith(_ message: String, _ result: ExitTest.Result?) -> Bool {
        guard let result else { return false }
        #if DEBUG
        return String(decoding: result.standardErrorContent, as: UTF8.self).contains(message)
        #else
        return true
        #endif
    }

    /// G3 and G9, the class. The guard behind each `@unchecked Sendable` reader
    /// traps, with a message that names the cause, when two reads overlap.
    @Test func overlappingReadsOnASingleConsumerStreamTrap() async throws {
        let result = await #expect(
            processExitsWith: .signal(SIGTRAP), observing: [\.standardErrorContent]
        ) {
            let guardUnderTest = LoopbackSingleReaderGuard()
            guardUnderTest.enter("test")
            guardUnderTest.enter("test")
        }
        let trappedInTheGuard = Self.trappedWith("two reads overlapped", result)
        #expect(trappedInTheGuard)
        // The positive beside it: sequential use does not trap.
        let sequential = LoopbackSingleReaderGuard()
        sequential.enter("test")
        sequential.leave()
        sequential.enter("test")
        sequential.leave()
    }

    /// H2. Each reader goes THROUGH the guard: the overlap, not the sequence. A
    /// second read begun while a first is in flight traps with the guard's
    /// message. Without `reader.enter` in the reader, a sequential test cannot
    /// tell (a second iteration over a finished stream returns empty), and the
    /// overlapping case ends in `AsyncStream`'s own trap or in nothing -- neither
    /// of which carries this message. A task finishes the stream after half a
    /// second so a reader without the guard ends the child instead of hanging it.
    @Test func theDataChunkSourceTrapsOnOverlappingDrains() async throws {
        let result = await #expect(
            processExitsWith: .signal(SIGTRAP), observing: [\.standardErrorContent]
        ) {
            let (stream, continuation) = AsyncStream.makeStream(of: ByteBuffer.self)
            let source = LoopbackChunkSource(stream)
            Task { _ = await source.drain() }
            var spins = 0
            while !source.isReading, spins < 200_000 { spins += 1; await Task.yield() }
            Task {
                try? await Task.sleep(for: .milliseconds(500))
                continuation.finish()
            }
            _ = await source.drain()
        }
        let trappedInTheGuard = Self.trappedWith("two reads overlapped", result)
        #expect(trappedInTheGuard)
    }

    @Test func theControlLineSourceTrapsOnOverlappingReads() async throws {
        let result = await #expect(
            processExitsWith: .signal(SIGTRAP), observing: [\.standardErrorContent]
        ) {
            let (stream, continuation) = AsyncStream.makeStream(of: ByteBuffer.self)
            let source = LoopbackLineSource(stream)
            Task { _ = await source.next() }
            var spins = 0
            while !source.isReading, spins < 200_000 { spins += 1; await Task.yield() }
            Task {
                try? await Task.sleep(for: .milliseconds(500))
                continuation.finish()
            }
            _ = await source.next()
        }
        let trappedInTheGuard = Self.trappedWith("two reads overlapped", result)
        #expect(trappedInTheGuard)
    }

    @Test func thePassiveListenerTrapsOnOverlappingReads() async throws {
        let result = await #expect(
            processExitsWith: .signal(SIGTRAP), observing: [\.standardErrorContent]
        ) {
            let channel = try await awaitCancellably(
                ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
                    .bind(host: "127.0.0.1", port: 0))
            let (stream, continuation) = AsyncStream.makeStream(of: LoopbackFTPDataConnection.self)
            let listener = LoopbackFTPPassiveListener(channel: channel, connections: stream, port: 0)
            Task { _ = await listener.next() }
            var spins = 0
            while !listener.isReading, spins < 200_000 { spins += 1; await Task.yield() }
            Task {
                try? await Task.sleep(for: .milliseconds(500))
                continuation.finish()
            }
            await listener.discard()
        }
        let trappedInTheGuard = Self.trappedWith("two reads overlapped", result)
        #expect(trappedInTheGuard)
    }

    /// H6. Two overlapping `start()` calls: the second traps, loudly, instead of
    /// both passing a check that only the first `await` had updated. An
    /// explicit-TLS server, because minting its certificate (an `openssl` child
    /// process) is the wide window during which `start()` is in flight.
    @Test func aSecondStartWhileOneIsInFlightTraps() async throws {
        let result = await #expect(
            processExitsWith: .signal(SIGTRAP), observing: [\.standardErrorContent]
        ) {
            let server = LoopbackFTPServer(
                security: .explicitTLS, advertisesMLSD: true, requiresTLSSessionReuse: false)
            Task { _ = try? await server.start() }
            var spins = 0
            while !(await server.isStarting), spins < 200_000 { spins += 1; await Task.yield() }
            _ = try? await server.start()
        }
        let trappedInTheServer = Self.trappedWith("not idle", result)
        #expect(trappedInTheServer)
    }

    /// H6. A `stop()` that arrives while `start()` is in flight traps, loudly.
    /// It used to return without a word and leave the server running.
    @Test func aStopWhileAStartIsInFlightTraps() async throws {
        let result = await #expect(
            processExitsWith: .signal(SIGTRAP), observing: [\.standardErrorContent]
        ) {
            let server = LoopbackFTPServer(
                security: .explicitTLS, advertisesMLSD: true, requiresTLSSessionReuse: false)
            Task { _ = try? await server.start() }
            var spins = 0
            while !(await server.isStarting), spins < 200_000 { spins += 1; await Task.yield() }
            await server.stop()
        }
        let trappedInTheServer = Self.trappedWith("in flight", result)
        #expect(trappedInTheServer)
    }
#endif

    /// H1. The three ways a wait ends without a reply stay three. Peer closed:
    /// `theLoopbackServerCanBeToldToRefuseWith421` and
    /// `stopClosesTheListenerAndCanBeCalledTwice` assert `.connectionClosed`. Bound
    /// fired: `aSilentPeerEndsTheClientsWaitWithANamedError` asserts
    /// `.noReplyWithin`. Cancelled, here: with the peer still connected, a read
    /// whose task is cancelled throws `CancellationError`, not a close.
    @Test func aCancelledReadIsNotReportedAsAClosedConnection() async throws {
        let silent = try await SilentServer.start()
        let client = try await LoopbackFTPClient.connect(
            host: "127.0.0.1", port: silent.port, replyBound: .seconds(30))
        let clientPort = try #require(client.localPort)
        try await silent.waitUntilSettled(clientPort: clientPort)
        let reading = Task { try await client.readReply() }
        reading.cancel()
        let outcome = await reading.result

        var cancelled = false
        var describedAsAClose = false
        switch outcome {
        case .failure(let error):
            cancelled = error is CancellationError
            describedAsAClose = (error as? LoopbackFTPClientError) == .connectionClosed
        case .success:
            break
        }
        let stillHeld = silent.isHolding(clientPort: clientPort)
        await client.close()
        await silent.stop()

        #expect(cancelled)
        #expect(describedAsAClose == false)
        // The peer never closed anything: the cancellation was the whole story.
        #expect(stillHeld)
    }

    /// H1. The fixture answers for ITS connection, not for everything that
    /// reached the port. A second client connects to the same server and goes
    /// away; the first connection is still reported held.
    @Test func aForeignConnectionToTheSilentServerDoesNotSpeakForOurs() async throws {
        let silent = try await SilentServer.start()
        let ours = try await LoopbackFTPClient.connect(
            host: "127.0.0.1", port: silent.port, replyBound: .seconds(30))
        let foreign = try await LoopbackFTPClient.connect(
            host: "127.0.0.1", port: silent.port, replyBound: .seconds(30))
        let ourPort = try #require(ours.localPort)
        let foreignPort = try #require(foreign.localPort)
        try await silent.waitUntilSettled(clientPort: ourPort)
        try await silent.waitUntilSettled(clientPort: foreignPort)
        await foreign.close()
        // The server sees the foreign connection close: wait for that, so the
        // assertion below is about a server that HAS a closed connection in hand.
        try await pollUntil("the foreign connection is closed on the server") {
            !silent.isHolding(clientPort: foreignPort)
        }
        let oursStillHeld = silent.isHolding(clientPort: ourPort)
        await ours.close()
        await silent.stop()

        #expect(oursStillHeld)
    }

    /// H1, the data reader: a cancelled `readToEnd()` must not hand back a prefix
    /// of the payload as though it were all of it.
    @Test func aCancelledDataReadThrowsInsteadOfReturningAPrefix() async throws {
        let silent = try await SilentServer.start(sending: Data("0123456789".utf8))
        let client = try await LoopbackFTPClient.connect(
            host: "127.0.0.1", port: silent.port, replyBound: .seconds(30))
        let data = try await client.openData(host: "127.0.0.1", port: silent.port, protected: false)
        try await silent.waitUntilSettled(clientPort: try #require(data.localPort))
        try await pollUntil("the payload has arrived") { data.bytesReceived >= 10 }
        let reading = Task { try await data.readToEnd() }
        reading.cancel()
        let outcome = await reading.result

        var cancelled = false
        switch outcome {
        case .failure(let error): cancelled = error is CancellationError
        case .success: break
        }
        await client.close()
        await silent.stop()
        #expect(cancelled)
    }

    /// H3. `stop()` waits for the closers registered with it before it takes the
    /// event loops down. The wait is observed with a FLOOR: `stop()` is started,
    /// the test lets the scheduler run for a while, and `stop()` must still be
    /// waiting -- a slow machine cannot make a blocked `stop()` finish early,
    /// only a `stop()` that does not wait can. Then the closer is released and
    /// `stop()` must finish having seen it complete.
    @Test func stopWaitsForARegisteredCloserBeforeItReturns() async throws {
        let server = LoopbackFTPServer(
            security: .plain, advertisesMLSD: true, requiresTLSSessionReuse: false)
        _ = try await server.start()
        let release = AsyncSignal()
        let closerDone = AsyncSignal()
        await server.adoptCloser(
            Task {
                _ = await release.wait()
                closerDone.signal()
            })

        let stopped = AsyncSignal()
        let closerHadFinished = NIOLockedValueBox(false)
        let stopping = Task {
            await server.stop()
            closerHadFinished.withLockedValue { $0 = closerDone.isRaised }
            stopped.signal()
        }
        try await Task.sleep(for: .milliseconds(300))
        let stillWaiting = !stopped.isRaised
        release.signal()
        await stopping.value

        #expect(stillWaiting)
        #expect(closerHadFinished.withLockedValue { $0 })
    }

    /// H4. `readToEnd()` returns the bytes that arrived and records a transport
    /// error that follows them; it does not throw the payload away.
    @Test func readToEndReturnsTheBytesAndRecordsALaterTransportError() async throws {
        let payload = Data("0123456789".utf8)
        let silent = try await SilentServer.start(sending: payload)
        let client = try await LoopbackFTPClient.connect(
            host: "127.0.0.1", port: silent.port, replyBound: .seconds(30))
        let data = try await client.openData(host: "127.0.0.1", port: silent.port, protected: false)
        try await silent.waitUntilSettled(clientPort: try #require(data.localPort))
        // Wait for delivery, not for time: the error must follow the bytes.
        try await pollUntil("the payload has arrived") { data.bytesReceived >= payload.count }
        data.injectTransportError()
        let received = try await data.readToEnd()
        let failure = data.transportFailure
        await client.close()
        await silent.stop()

        #expect(received == payload)
        #expect(failure != nil)
    }

    /// H4, the other half: the data reader's hang bound. Nothing arrives and the
    /// connection stays up, so the bound is the only way the read can end.
    @Test func aSilentDataConnectionEndsReadToEndWithTheNamedError() async throws {
        let silent = try await SilentServer.start()
        let client = try await LoopbackFTPClient.connect(
            host: "127.0.0.1", port: silent.port, replyBound: .milliseconds(200))
        let data = try await client.openData(host: "127.0.0.1", port: silent.port, protected: false)
        let dataPort = try #require(data.localPort)
        try await silent.waitUntilSettled(clientPort: dataPort)
        var thrown: LoopbackFTPClientError?
        do {
            _ = try await data.readToEnd()
        } catch {
            thrown = error as? LoopbackFTPClientError
        }
        let stillHeld = silent.isHolding(clientPort: dataPort)
        await client.close()
        await silent.stop()

        #expect(stillHeld)
        #expect(thrown == .noReplyWithin(milliseconds: 200))
    }

    /// G3. A second `readToEnd()` on the same data connection reads the one
    /// iterator the connection owns, finds the stream ended, and returns
    /// nothing; it does not start a second iteration over a unicast stream.
    @Test func aDataConnectionCanBeReadToEndTwice() async throws {
        let server = LoopbackFTPServer(
            security: .plain, advertisesMLSD: true, requiresTLSSessionReuse: false)
        let credentials = server.credentials
        await server.seedFile("/f", contents: Data("abc".utf8))
        try await Self.running(server) { host, port in
            let client = try await LoopbackFTPClient.connect(host: host, port: port)
            _ = try await client.readReply()
            _ = try await client.login(credentials)
            let endpoint = try Self.passiveEndpoint(try await client.command("PASV"))
            let data = try await client.openData(host: host, port: endpoint.port, protected: false)
            try await client.send("RETR /f")
            #expect(try await client.readReply().code == 150)
            let first = try await data.readToEnd()
            let second = try await data.readToEnd()
            #expect(first == Data("abc".utf8))
            #expect(second.isEmpty)
            #expect(data.transportFailure == nil)
            await client.close()
        }
    }

    /// F2, the deterministic half: the invariant lives in the state that owns
    /// the set. A channel is either in the snapshot `beginStopping()` returns or
    /// is closed by the call that registers it; the window `stop()` used to
    /// leave open between snapshot and shutdown does not exist.
    @Test func aChannelTrackedAfterStoppingBeginsIsClosedByTheCall() async throws {
        let state = LoopbackFTPState()
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let before = try await awaitCancellably(
            ServerBootstrap(group: group).bind(host: "127.0.0.1", port: 0))
        state.track(before)
        let snapshot = state.beginStopping()
        let after = try await awaitCancellably(
            ServerBootstrap(group: group).bind(host: "127.0.0.1", port: 0))
        state.track(after)

        // `track` closes from outside the loop by scheduling onto it, so a
        // task submitted to the same loop afterwards runs after that close.
        let afterIsActive = try await awaitCancellably(after.eventLoop.submit { after.isActive })
        let beforeIsActive = try await awaitCancellably(before.eventLoop.submit { before.isActive })

        // The positive beside the negative: a channel tracked before the flag
        // is in the snapshot and untouched -- closing it is `stop()`'s job.
        #expect(snapshot.count == 1)
        #expect(beforeIsActive)
        #expect(afterIsActive == false)

        _ = try await awaitCancellably(before.close())
        try await group.shutdownGracefully()
    }

    /// F3, with the fixture of fix round 2 (G1). The client's hang bound turns a
    /// silent peer into a named error.
    ///
    /// **The peer is a server that ACCEPTS the connection, holds it open and
    /// never writes** (`SilentServer`), and the test asserts that it was still
    /// holding it when the wait ended. Before this round the peer was a
    /// `LoopbackSocket.listening()` socket nobody accepts from, which completes
    /// the TCP handshake in the kernel's backlog and leaves the connection's
    /// life to the kernel and to the descriptor's owner.
    ///
    /// Withdrawn wording, verbatim: "what is asserted is the error, which
    /// lateness cannot change." It was false. In the re-review of Task 4's fix
    /// round 1 this test failed in 2 of 20 whole-suite runs, with
    /// `.connectionClosed` where `.noReplyWithin` was expected, and the durations
    /// did not separate the red runs from the green. `.connectionClosed` means the
    /// stream ended with no cause recorded, i.e. the connection went inactive
    /// before the 200 ms timer fired. An assertion on an error that only one side
    /// of a timing race can produce is a ceiling in disguise: the test's outcome
    /// depended on a 200 ms timer beating the transport.
    ///
    /// **The cause was not determined.** Measured in fix round 2, with the two
    /// paths logged (client active / inactive / error, and the listening
    /// descriptor's state on a failure): 0 reproductions in 38 whole-suite runs of
    /// the Core suite (12 on an idle machine, 12 with two suite loops side by side,
    /// 14 with 16 busy loops added) and in 400 isolated iterations of exactly this
    /// scenario under 14 busy loops. What the fixture changes is therefore
    /// removed hypotheses, not a located cause: nothing that depends on the
    /// kernel's accept queue or on the listening descriptor's lifetime is left in
    /// the path, and if the connection does go away, `stillHeld` says so and the
    /// failure reads "the peer's connection was gone", not "the wrong error".
    @Test func aSilentPeerEndsTheClientsWaitWithANamedError() async throws {
        let silent = try await SilentServer.start()
        let client: LoopbackFTPClient
        do {
            client = try await LoopbackFTPClient.connect(
                host: "127.0.0.1", port: silent.port, replyBound: .milliseconds(200))
        } catch {
            await silent.stop()
            throw error
        }
        // Unconditional, not hoped for (fix round 3, H1): `connect` returning does
        // not mean the server has accepted -- a plant that delayed the accept's
        // bookkeeping by 400 ms made `stillHeld` itself lose the race to the
        // 200 ms timer. Wait for the accept, then start the wait that is measured.
        let clientPort = try #require(client.localPort)
        do {
            try await silent.waitUntilSettled(clientPort: clientPort)
        } catch {
            await client.close()
            await silent.stop()
            throw error
        }
        var thrown: LoopbackFTPClientError?
        do {
            _ = try await client.readReply()
        } catch {
            thrown = error as? LoopbackFTPClientError
        }
        // Read before anything is closed: the guarantee the outcome rests on.
        let stillHeld = silent.isHolding(clientPort: clientPort)
        await client.close()
        await silent.stop()

        #expect(stillHeld)
        #expect(thrown == .noReplyWithin(milliseconds: 200))
    }

    /// F13. A transport error reaches the awaiting side as an error that says
    /// so, not as a quiet end of stream. Closing a listening socket resets the
    /// connection nobody accepted from it; on macOS that surfaces to the client
    /// as ECONNRESET (every one of the 6 probe runs that logged an outcome), which
    /// is the platform dependence of this test.
    @Test func aTransportErrorEndsTheClientsWaitAsAFailureNotAsAClose() async throws {
        let silent = try #require(LoopbackSocket.listening())
        let client = try await LoopbackFTPClient.connect(
            host: "127.0.0.1", port: silent.port, replyBound: .seconds(30))
        silent.close()
        var failed = false
        do {
            _ = try await client.readReply()
        } catch let LoopbackFTPClientError.connectionFailed(description) {
            failed = !description.isEmpty
        } catch {
            failed = false
        }
        #expect(failed)
        await client.close()
    }

    /// F4. `requiresTLSSessionReuse` is paired with protected data: a session
    /// that never issues `PROT P` is refused, not waved through.
    @Test func aServerThatRequiresSessionReuseRefusesClearData() async throws {
        let server = LoopbackFTPServer(
            security: .explicitTLS, advertisesMLSD: true, requiresTLSSessionReuse: true)
        let credentials = server.credentials
        let reply = try await Self.running(server) { host, port in
            let client = try await LoopbackFTPClient.connect(host: host, port: port)
            _ = try await client.readReply()
            _ = try await client.command("AUTH TLS")
            try await client.startTLS()
            _ = try await client.command("PBSZ 0")
            #expect(try await client.command("PROT C").code == 200)
            _ = try await client.login(credentials)
            let endpoint = try Self.passiveEndpoint(try await client.command("PASV"))
            let data = try await client.openData(host: host, port: endpoint.port, protected: false)
            let reply = try await client.command("LIST")
            await data.close()
            await client.close()
            return reply
        }
        #expect(reply.code == 522)
        // Refused before any data connection was used: no data handshake, and
        // the full-handshake refusal counter did not move.
        #expect(await server.handshakes == [.init(connection: .control, resumed: false)])
        #expect(await server.refusedDataConnectionCount == 0)
    }
}

/// A server that accepts every connection, holds it open and never writes.
/// Not `LoopbackSocket.listening()`: that leaves the connection in the kernel's
/// accept queue, unaccepted, and its life is the kernel's and the descriptor
/// owner's. Here the connection is established and owned by this object, so
/// nothing but `stop()` can close it.
final class SilentServer: Sendable {
    let port: Int
    private let listener: Channel
    /// Every accepted connection, for `stop()` to close, whether or not it has
    /// settled.
    private let all: NIOLockedValueBox<[Channel]>
    /// Settled connections by the client's port: the single source of truth for
    /// "the server holds this connection". An entry appears when the connection
    /// has become active (or been closed before it could), and not before.
    private let entries: NIOLockedValueBox<[Int: Channel]>

    private init(
        port: Int, listener: Channel, all: NIOLockedValueBox<[Channel]>,
        entries: NIOLockedValueBox<[Int: Channel]>
    ) {
        self.port = port
        self.listener = listener
        self.all = all
        self.entries = entries
    }

    /// `sending` is written to every accepted connection as soon as it is
    /// active, and the connection is held open after it.
    static func start(sending: Data = Data()) async throws -> SilentServer {
        let all = NIOLockedValueBox<[Channel]>([])
        let entries = NIOLockedValueBox<[Int: Channel]>([:])
        let listener = try await awaitCancellably(
            ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
                .childChannelInitializer { channel in
                    all.withLockedValue { $0.append(channel) }
                    // Read now: a channel closed before it settles may no longer
                    // know its peer.
                    let peerPort = channel.remoteAddress?.port ?? -1
                    // A child's initializer runs BEFORE the channel is registered
                    // and active, so "it was accepted" is not "it is open": a
                    // check made in between sees an inactive channel. The
                    // announcer fires when the channel becomes active (or, if it
                    // is closed first, when its handlers are removed), which is
                    // the moment the connection's state is settled either way,
                    // and the moment it gets an entry.
                    return channel.eventLoop.makeCompletedFuture {
                        try channel.pipeline.syncOperations.addHandler(
                            LoopbackActivationAnnouncer {
                                if !sending.isEmpty {
                                    channel.writeAndFlush(ByteBuffer(bytes: sending), promise: nil)
                                }
                                entries.withLockedValue { $0[peerPort] = channel }
                            })
                    }
                }
                .bind(host: "127.0.0.1", port: 0))
        guard let port = listener.localAddress?.port else {
            _ = try? await awaitCancellably(listener.close())
            throw LoopbackFTPServerError.noLocalPort
        }
        return SilentServer(port: port, listener: listener, all: all, entries: entries)
    }

    /// Waits until the connection whose CLIENT port is `clientPort` has settled:
    /// become active, or been closed before it could. A client's `connect`
    /// returning means the TCP handshake finished in the kernel, not that this
    /// process has accepted anything, and a connection in `held` may not be
    /// registered yet. So the guarantee a test rests on -- the server holds ITS
    /// connection -- is established before the wait it measures begins, by
    /// waiting on state, never on time. A connection closed on arrival still
    /// settles, so a server that misbehaves that way fails the test's assertion
    /// instead of hanging it.
    ///
    /// By port, not by count: anything else that dials this port (the kernel
    /// hands out ports other tests have just freed) makes a count, or "every
    /// held connection is open", say something about a connection the test does
    /// not own.
    func waitUntilSettled(clientPort: Int) async throws {
        try await pollUntil("the silent server has settled the connection from port \(clientPort)") {
            self.entries.withLockedValue { $0[clientPort] != nil }
        }
    }

    /// The connection from `clientPort` is held and still open.
    func isHolding(clientPort: Int) -> Bool {
        entries.withLockedValue { $0[clientPort]?.isActive ?? false }
    }

    func stop() async {
        _ = try? await awaitCancellably(listener.close())
        for channel in all.withLockedValue({ $0 }) { _ = try? await awaitCancellably(channel.close()) }
    }
}
