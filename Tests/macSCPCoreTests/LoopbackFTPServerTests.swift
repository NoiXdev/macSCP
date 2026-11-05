import Foundation
import MacSCPTestSupport
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

    /// F2, the integration half. No deadline on `stop()`: if the race returns,
    /// this hangs until the suite's limit and fails there, by name. It is not
    /// reproduced to fail on the old code -- see the state test above for the
    /// pin; this exercises the shape the review reasoned about.
    @Test func stoppingWhileAPassiveTransferIsPipelinedReturns() async throws {
        var stopped = 0
        for _ in 0..<20 {
            let server = LoopbackFTPServer(
                security: .plain, advertisesMLSD: true, requiresTLSSessionReuse: false)
            let credentials = server.credentials
            await server.seedFile("/f", contents: Data("x".utf8))
            let endpoint = try await server.start()
            let client = try await LoopbackFTPClient.connect(host: endpoint.host, port: endpoint.port)
            _ = try await client.readReply()
            _ = try await client.login(credentials)
            // Two commands in one write, so the session binds a listener and
            // goes straight to waiting for a connection that will not come.
            try await client.send("PASV\r\nRETR /f")
            await server.stop()
            await client.close()
            stopped += 1
        }
        #expect(stopped == 20)
    }

    /// F3. The client's hang bound turns a silent peer into a named error.
    /// A listening socket nobody accepts from completes the TCP handshake and
    /// never speaks. The bound is short here because it is the thing tested;
    /// what is asserted is the error, which lateness cannot change.
    @Test func aSilentPeerEndsTheClientsWaitWithANamedError() async throws {
        let silent = try #require(LoopbackSocket.listening())
        defer { silent.close() }
        let client = try await LoopbackFTPClient.connect(
            host: "127.0.0.1", port: silent.port, replyBound: .milliseconds(200))
        await #expect(throws: LoopbackFTPClientError.noReplyWithin(milliseconds: 200)) {
            _ = try await client.readReply()
        }
        await client.close()
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
