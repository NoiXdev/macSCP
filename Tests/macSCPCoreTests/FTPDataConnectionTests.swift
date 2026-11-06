import Foundation
import MacSCPTestSupport
import Testing

@testable import macSCPCore

/// The passive negotiation and one whole transfer: `EPSV` first and `PASV`
/// after it, the addresses this client will not dial, `REST` before `RETR`,
/// and what a cancelled transfer leaves behind.
///
/// **Nothing here puts a credential where a reader can reach it**, for the
/// reason `FTPControlConnectionTests` states: `#expect` prints the source text
/// of its expression AND what its subexpressions evaluated to. The dials go
/// through `Self.connect`, which takes the server's generated credentials and
/// returns a connection, and every comparison that would otherwise print an
/// address, a port or a file's contents is computed into a `Bool` first.
@Suite("FTP data connection", .timeLimit(.minutes(5)))
struct FTPDataConnectionTests {
    // MARK: - Helpers

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

    /// A logged-in control connection against the loopback server. The config
    /// it builds never holds the password — it travels as the `password:`
    /// argument, which no value type here stores.
    /// Says yes to whatever certificate it is shown. The TLS cases here are
    /// about session reuse, not about the trust decision, which
    /// `FTPControlConnectionTests` owns.
    private static let accepting = CertificateDecider.asking { _ in true }

    private static func connect(
        _ server: LoopbackFTPServer, host: String, port: Int,
        security: FTPSecurityMode = .plain,
        decider: CertificateDecider = .refusing
    ) async throws -> FTPControlConnection {
        let credentials = server.credentials
        return try await FTPControlConnection.connect(
            FTPConnectionConfig(
                host: host, port: port, username: credentials.username, security: security,
                password: ""),
            password: credentials.password,
            certificateDecider: decider,
            timeout: .seconds(30),
            trustStore: nil)
    }

    /// The scripted replies a dial reads before any of these tests gets a
    /// word in: `USER`, `PASS`, `FEAT`, `TYPE I`.
    private static let dialReplies: [[String]] = [
        ["331 Password required."],
        ["230 Login successful."],
        ["211-Features:", " UTF8", " SIZE", "211 End"],
        ["200 Type set."],
    ]

    private static func connectScript(
        host: String, port: Int
    ) async throws -> FTPControlConnection {
        try await FTPControlConnection.connect(
            FTPConnectionConfig(
                host: host, port: port, username: "scripted", security: .plain, password: ""),
            password: "unused-by-a-script",
            certificateDecider: .refusing,
            timeout: .seconds(30),
            trustStore: nil)
    }

    /// How a transfer ended, as a value that carries no server text: a
    /// failure's TYPE name when it is not an `FTPConnectionFailure`, so a
    /// wrong error type fails loudly instead of reading as "no failure".
    private enum TransferOutcome: Equatable, CustomStringConvertible {
        case completed
        case failed(FTPConnectionFailure)
        case cancelled
        case otherError(String)

        var description: String {
            switch self {
            case .completed: "completed"
            case .failed(let failure): "failed(\(failure))"
            case .cancelled: "cancelled"
            case .otherError(let type): "otherError(\(type))"
            }
        }
    }

    private static func outcome(of work: () async throws -> Void) async -> TransferOutcome {
        do {
            try await work()
            return .completed
        } catch is CancellationError {
            return .cancelled
        } catch let failure as FTPConnectionFailure {
            return .failed(failure)
        } catch {
            return .otherError(String(describing: type(of: error)))
        }
    }

    /// A `227` reply with the six numbers spelled out, for the parse table.
    private static func passiveReply(_ numbers: [Int]) -> FTPReply {
        FTPReply(
            code: 227,
            lines: [
                "Entering Passive Mode (\(numbers.map(String.init).joined(separator: ",")))."
            ])
    }

    private static let seededName = "/payload.bin"
    /// 4 KiB of a pattern that is not a constant byte, so a transfer that
    /// started at the wrong offset cannot match by accident.
    private static let seeded = Data((0..<4096).map { UInt8($0 % 251) })

    // MARK: - Passive negotiation

    /// `EPSV` is the command this client reaches for, and `PASV` is what it
    /// falls back to when the server does not know it.
    ///
    /// The preference is not a taste: `EPSV` carries no address at all
    /// (RFC 2428 section 3), so the question
    /// `aPASVReplyWithAnUnusableAddressIsRefusedRatherThanDialled` is about
    /// never arises on the preferred path.
    @Test func epsvIsPreferredAndPASVIsTheFallback() async throws {
        let modern = LoopbackFTPServer(
            security: .plain, advertisesMLSD: true, requiresTLSSessionReuse: false)
        await modern.seedFile(Self.seededName, contents: Self.seeded)
        let overEPSV = try await Self.running(modern) { host, port in
            let connection = try await Self.connect(modern, host: host, port: port)
            let sink = FTPByteSink()
            try await FTPDataConnection.transfer(
                "RETR", argument: Self.seededName, on: connection
            ) { channel in
                sink.append(try await channel.readToEnd())
            }
            await connection.close()
            return sink.matches(Self.seeded)
        }
        #expect(overEPSV)
        let modernVerbs = await modern.receivedCommands.map(\.verb)
        // The negative — no `PASV` — with its positive beside it: `EPSV` is
        // on the wire, so the absence of `PASV` is a preference and not a
        // transfer that never negotiated anything.
        #expect(modernVerbs.contains("EPSV"))
        #expect(!modernVerbs.contains("PASV"))

        // And the fallback, on a server that answers `EPSV` the way one
        // predating RFC 2428 does.
        let legacy = LoopbackFTPServer(
            security: .plain, advertisesMLSD: true, requiresTLSSessionReuse: false)
        await legacy.seedFile(Self.seededName, contents: Self.seeded)
        let overPASV = try await Self.running(legacy) { host, port in
            await legacy.refuseExtendedPassive()
            let connection = try await Self.connect(legacy, host: host, port: port)
            let sink = FTPByteSink()
            try await FTPDataConnection.transfer(
                "RETR", argument: Self.seededName, on: connection
            ) { channel in
                sink.append(try await channel.readToEnd())
            }
            await connection.close()
            return sink.matches(Self.seeded)
        }
        #expect(overPASV)
        let legacyVerbs = await legacy.receivedCommands.map(\.verb)
        // Both commands, in that order: the fallback is a fallback and not a
        // client that gave up on `EPSV` without ever trying it.
        let epsvIndex = legacyVerbs.firstIndex(of: "EPSV")
        let pasvIndex = legacyVerbs.firstIndex(of: "PASV")
        let triedInOrder = epsvIndex != nil && pasvIndex != nil && epsvIndex! < pasvIndex!
        #expect(triedInOrder)
        #expect(legacyVerbs.contains("RETR"))
    }

    /// A server that refused `EPSV` once is not asked again on the same
    /// connection.
    ///
    /// **The case `LoopbackFTPServer.refuseExtendedPassive` was deliberately
    /// built non-one-shot for, and which the first round did not write.** The
    /// memo is claimed by two comments to pay the extra round trip "once
    /// rather than once per transfer", and the review's probe
    /// (`prefersClassicPassive` → `false`) was GREEN across 56 tests: no case
    /// performed a second transfer on a legacy server, so nothing read the
    /// memo at all.
    ///
    /// Counted with `filter`, not `contains`: one `EPSV` and two `PASV`s is
    /// the property, and `contains` cannot tell one from two.
    @Test func theEPSVRefusalIsRememberedForTheRestOfTheConnection() async throws {
        let legacy = LoopbackFTPServer(
            security: .plain, advertisesMLSD: true, requiresTLSSessionReuse: false)
        await legacy.seedFile(Self.seededName, contents: Self.seeded)
        let both = try await Self.running(legacy) { host, port in
            await legacy.refuseExtendedPassive()
            let connection = try await Self.connect(legacy, host: host, port: port)
            let first = FTPByteSink()
            try await FTPDataConnection.transfer(
                "RETR", argument: Self.seededName, on: connection
            ) { channel in
                first.append(try await channel.readToEnd())
            }
            let second = FTPByteSink()
            try await FTPDataConnection.transfer(
                "RETR", argument: Self.seededName, on: connection
            ) { channel in
                second.append(try await channel.readToEnd())
            }
            await connection.close()
            return first.matches(Self.seeded) && second.matches(Self.seeded)
        }
        #expect(both)
        let verbs = await legacy.receivedCommands.map(\.verb)
        // One `EPSV` for two transfers: the refusal was remembered. The two
        // `PASV`s and the two `RETR`s beside it are the positive — both
        // transfers really happened, so the single `EPSV` is a memo and not a
        // second transfer that never ran.
        #expect(verbs.filter { $0 == "EPSV" }.count == 1)
        #expect(verbs.filter { $0 == "PASV" }.count == 2)
        #expect(verbs.filter { $0 == "RETR" }.count == 2)
    }

    /// A `227` this client cannot READ is refused where it is read, so
    /// nothing is dialled on the strength of it.
    ///
    /// **Five ways to be unusable**, counted against the table below: no
    /// parenthesised address at all, not six comma-separated fields, a field
    /// that is not a number, an octet past 255, and a port of zero. All five
    /// are the reply being unreadable; none of them is a judgement about
    /// WHERE the reply points, which is
    /// `aPassiveReplyNamingAnotherHostIsDialledAtTheControlPeer`.
    ///
    /// The comparisons are computed into `Bool`s before the expectations, so
    /// neither an address nor a port reaches a failure message.
    @Test func aPASVReplyWithAnUnusableAddressIsRefusedRatherThanDialled() async throws {
        let peer = "127.0.0.1"
        // The positive: an honest reply parses, and parses to the right
        // place. Without it the refusals below would also hold for a parser
        // that refuses everything.
        let honest = try FTPDataConnection.passiveEndpoint(
            Self.passiveReply([127, 0, 0, 1, 195, 80]), peerHost: peer)
        let honestIsTheRightEndpoint = honest == FTPDataEndpoint(host: peer, port: 195 * 256 + 80)
        #expect(honestIsTheRightEndpoint)

        let unusable: [(name: String, reply: FTPReply)] = [
            ("no address at all", FTPReply(code: 227, lines: ["Entering Passive Mode."])),
            ("five numbers", Self.passiveReply([127, 0, 0, 1, 195])),
            (
                "a field that is not a number",
                FTPReply(code: 227, lines: ["Entering Passive Mode (127,0,0,x,195,80)."])
            ),
            ("an octet past 255", Self.passiveReply([127, 0, 0, 999, 195, 80])),
            ("a port of zero", Self.passiveReply([127, 0, 0, 1, 0, 0])),
        ]
        #expect(unusable.count == 5)
        for candidate in unusable {
            var refusal: FTPConnectionFailure?
            do {
                _ = try FTPDataConnection.passiveEndpoint(candidate.reply, peerHost: peer)
            } catch let failure as FTPConnectionFailure {
                refusal = failure
            }
            #expect(refusal == .passiveAddressRefused, "\(candidate.name)")
        }

        // And on the wire: the refusal happens before the transfer command is
        // written, so the server never sees a `RETR` for a transfer that was
        // refused at the reply. The scripted server is what produces an
        // unreadable `227` — the loopback server's replies are always
        // well-formed, which is what a real server's are.
        let server = ScriptedFTPServer(
            greeting: [["220 Scripted server ready."]],
            replies: Self.dialReplies + [
                ["500 Unknown command."],
                ["227 Entering Passive Mode (127,0,0,1,0,0)."],
            ])
        let refused = try await Self.runningScript(server) { host, port in
            let connection = try await Self.connectScript(host: host, port: port)
            let outcome = await Self.outcome {
                try await FTPDataConnection.transfer(
                    "RETR", argument: Self.seededName, on: connection
                ) { channel in
                    _ = try await channel.readToEnd()
                }
            }
            await connection.close()
            return outcome
        }
        #expect(refused == .failed(.passiveAddressRefused))
        let verbs = await server.receivedCommands.map { String($0.split(separator: " ").first ?? "") }
        #expect(verbs.contains("PASV"))
        #expect(!verbs.contains("RETR"))
    }

    /// A passive reply naming a host that is not the peer is DIALLED AT THE
    /// PEER, not refused.
    ///
    /// **Ruling T6.2, and the hazard the review found under it.** The
    /// comparison this replaces — refuse unless the reply's address equals
    /// the control connection's host — could protect nothing, because both
    /// parsers already return `host: peerHost` whatever the reply named, so
    /// the named address was never dialled on either side of the decision.
    /// What it did do was refuse: `peerHost` is the host that was DIALLED, so
    /// for a server reached by name it is a hostname, while a `227` always
    /// carries dotted-quad octets — the comparison therefore refused the
    /// `PASV` fallback against every DNS-named server, honest or not, and the
    /// rig could not see it because its peer is `127.0.0.1` everywhere.
    ///
    /// **So the pure half uses a HOSTNAME peer**, which a merely-loosened
    /// comparison could not satisfy: a numeric-peer case would pass against
    /// one that still compared, and prove nothing. Both parsers are asked,
    /// because the review found the same comparison in the `EPSV` one.
    ///
    /// And the wire half tells substitution from trust: the server names
    /// `203.0.113.9` (RFC 5737 documentation space, unroutable from here), so
    /// the transfer can only complete if the control peer was dialled
    /// instead.
    @Test func aPassiveReplyNamingAnotherHostIsDialledAtTheControlPeer() async throws {
        let named = "ftp.example.com"
        let classic = try FTPDataConnection.passiveEndpoint(
            Self.passiveReply([203, 0, 113, 9, 195, 80]), peerHost: named)
        let classicGoesToThePeer = classic == FTPDataEndpoint(host: named, port: 195 * 256 + 80)
        #expect(classicGoesToThePeer)

        // RFC 2428 lets a server fill the net-addr field; most leave it
        // empty, which is why this path was quiet.
        let extended = try FTPDataConnection.extendedPassiveEndpoint(
            FTPReply(code: 229, lines: ["Entering Extended Passive Mode (|1|203.0.113.9|6446|)"]),
            peerHost: named)
        let extendedGoesToThePeer = extended == FTPDataEndpoint(host: named, port: 6446)
        #expect(extendedGoesToThePeer)

        // The positive beside them: the form every ordinary server sends
        // parses against the same hostname peer, so the two above are not a
        // parser that answers the peer for everything it is given.
        let ordinary = try FTPDataConnection.extendedPassiveEndpoint(
            FTPReply(code: 229, lines: ["Entering Extended Passive Mode (|||6446|)"]),
            peerHost: named)
        let ordinaryGoesToThePeer = ordinary == FTPDataEndpoint(host: named, port: 6446)
        #expect(ordinaryGoesToThePeer)

        // On the wire.
        let lying = LoopbackFTPServer(
            security: .plain, advertisesMLSD: true, requiresTLSSessionReuse: false)
        await lying.seedFile(Self.seededName, contents: Self.seeded)
        let served = try await Self.running(lying) { host, port in
            await lying.refuseExtendedPassive()
            await lying.answerPASVWith(host: "203.0.113.9")
            let connection = try await Self.connect(lying, host: host, port: port)
            let sink = FTPByteSink()
            let outcome = await Self.outcome {
                try await FTPDataConnection.transfer(
                    "RETR", argument: Self.seededName, on: connection
                ) { channel in
                    sink.append(try await channel.readToEnd())
                }
            }
            await connection.close()
            return (outcome: outcome, matched: sink.matches(Self.seeded))
        }
        #expect(served.outcome == .completed)
        #expect(served.matched)
        let lyingVerbs = await lying.receivedCommands.map(\.verb)
        #expect(lyingVerbs.contains("PASV"))
        #expect(lyingVerbs.contains("RETR"))
    }

    /// Both passive commands refused is reported as itself, not as a dial
    /// that failed.
    @Test func aServerThatRefusesBothPassiveCommandsIsReportedAsSuch() async throws {
        let server = ScriptedFTPServer(
            greeting: [["220 Scripted server ready."]],
            replies: Self.dialReplies + [
                ["500 Unknown command."],
                ["500 Unknown command."],
            ])
        let outcome = try await Self.runningScript(server) { host, port in
            let connection = try await Self.connectScript(host: host, port: port)
            let outcome = await Self.outcome {
                try await FTPDataConnection.transfer(
                    "RETR", argument: Self.seededName, on: connection
                ) { channel in
                    _ = try await channel.readToEnd()
                }
            }
            await connection.close()
            return outcome
        }
        #expect(outcome == .failed(.passiveModeRefused(code: 500)))
        // The positive beside it: both commands really were tried, and the
        // transfer command was not.
        let verbs = await server.receivedCommands.map { String($0.split(separator: " ").first ?? "") }
        #expect(verbs.contains("EPSV"))
        #expect(verbs.contains("PASV"))
        #expect(!verbs.contains("RETR"))
    }

    // MARK: - Resuming

    /// `REST <offset>` then `RETR` starts the download at the offset.
    @Test func restThenRETRResumesADownloadAtTheOffset() async throws {
        let offset = 1500
        let server = LoopbackFTPServer(
            security: .plain, advertisesMLSD: true, requiresTLSSessionReuse: false)
        await server.seedFile(Self.seededName, contents: Self.seeded)
        let outcome = try await Self.running(server) { host, port in
            let connection = try await Self.connect(server, host: host, port: port)
            let resumed = FTPByteSink()
            try await FTPDataConnection.transfer(
                "RETR", argument: Self.seededName, restartingAt: Int64(offset), on: connection
            ) { channel in
                resumed.append(try await channel.readToEnd())
            }
            // The positive beside it, on the same connection: no offset means
            // the whole file, so the resumed read above is a resumption and
            // not a server that always serves a tail.
            let whole = FTPByteSink()
            try await FTPDataConnection.transfer(
                "RETR", argument: Self.seededName, on: connection
            ) { channel in
                whole.append(try await channel.readToEnd())
            }
            await connection.close()
            return (
                resumed: resumed.matches(Data(Self.seeded.dropFirst(offset))),
                whole: whole.matches(Self.seeded)
            )
        }
        #expect(outcome.resumed)
        #expect(outcome.whole)

        // And the marker was sent exactly once, carrying the offset: a client
        // that sent two would have reset the second transfer's start too.
        let commands = await server.receivedCommands
        let markers = commands.filter { $0.verb == "REST" }
        #expect(markers.count == 1)
        #expect(markers.first?.argument == String(offset))
    }

    /// A refused `REST` stops the transfer instead of downloading from the
    /// start.
    ///
    /// The silent-corruption case: a client that carried on would receive the
    /// whole file and write it at the offset, so a resumed download would end
    /// with the file's head in the middle of it and no error anywhere. The
    /// scripted server is what produces the refusal — the loopback server
    /// accepts every marker, which is what a real one does.
    @Test func aRefusedRESTStopsTheTransferRatherThanDownloadingFromTheStart() async throws {
        let server = ScriptedFTPServer(
            greeting: [["220 Scripted server ready."]],
            replies: Self.dialReplies + [["501 Restart not supported."]])
        let outcome = try await Self.runningScript(server) { host, port in
            let connection = try await Self.connectScript(host: host, port: port)
            let outcome = await Self.outcome {
                try await FTPDataConnection.transfer(
                    "RETR", argument: Self.seededName, restartingAt: 1500, on: connection
                ) { channel in
                    _ = try await channel.readToEnd()
                }
            }
            await connection.close()
            return outcome
        }
        #expect(outcome == .failed(.restRefused(code: 501)))
        // The negative with its positive: `REST` was written and nothing
        // after it was.
        let verbs = await server.receivedCommands.map { String($0.split(separator: " ").first ?? "") }
        #expect(verbs.contains("REST"))
        #expect(!verbs.contains("RETR"))
        #expect(!verbs.contains("EPSV"))
    }

    // MARK: - Cancellation

    /// A cancelled transfer leaves its control connection usable.
    ///
    /// **The half of the cancellation invariant that is not the pool's.** The
    /// pool's own case
    /// (`FTPConnectionPoolTests.aCancelledTransfersConnectionIsDiscardedAndNotReused`)
    /// says the slot comes back and the connection is not handed out again;
    /// this one says the connection was still fit to hand out, which is the
    /// property the discard must not be allowed to stand in for. One control
    /// connection per tab means a cancel that closed it would disconnect the
    /// tab.
    ///
    /// Measured on the Task 5 tree, before the shield in `transferCommand`:
    /// the `PWD` below came back `failed(connectionClosed)`. The owed
    /// completion reply is read in the drain's own task, and an `AsyncStream`
    /// iteration in a CANCELLED task ends at once with no element — so the
    /// read could not succeed, and the branch that closes the connection when
    /// it fails ran every time.
    ///
    /// No clock anywhere: the drain reads the payload to its end, raises
    /// `reached`, and then parks on a latch nothing ever raises, so the
    /// cancellation is the only thing that can end it.
    @Test func aCancelledTransferLeavesItsControlConnectionUsable() async throws {
        let server = LoopbackFTPServer(
            security: .plain, advertisesMLSD: true, requiresTLSSessionReuse: false)
        await server.seedFile(Self.seededName, contents: Self.seeded)
        let outcome = try await Self.running(server) { host, port in
            let connection = try await Self.connect(server, host: host, port: port)
            let reached = AsyncSignal()
            let parked = AsyncSignal()
            let transfer = Task {
                await Self.outcome {
                    try await FTPDataConnection.transfer(
                        "RETR", argument: Self.seededName, on: connection
                    ) { channel in
                        _ = try await channel.readToEnd()
                        reached.signal()
                        if await parked.wait() == .cancelled { throw CancellationError() }
                    }
                }
            }
            _ = await reached.wait()
            transfer.cancel()
            let ended = await transfer.value

            // What the connection does next IS whether it survived: a closed
            // one cannot write and its line stream has ended, so both ways
            // that can end are `connectionClosed`.
            var afterwards = "no answer"
            do {
                afterwards = "answered(\(try await connection.send("PWD", argument: nil).code))"
            } catch let failure as FTPConnectionFailure {
                afterwards = "failed(\(failure))"
            } catch {
                afterwards = "otherError(\(String(describing: type(of: error))))"
            }
            await connection.close()
            return (ended: ended, afterwards: afterwards)
        }
        #expect(outcome.ended == .cancelled)
        #expect(outcome.afterwards == "answered(257)")
    }

    /// A cancelled read throws rather than reporting a short file as
    /// complete.
    ///
    /// **The silent-truncation case, and the reason `read(into:)` ends with a
    /// cancellation check.** An `AsyncStream` iteration in a cancelled task
    /// ends with no element, exactly as a peer that closed does, so a read
    /// that trusted the ended stream returned the bytes it happened to have
    /// as a COMPLETE transfer — a file short by however much was left, with
    /// no error anywhere, which §6 names as the one anti-goal.
    ///
    /// The data connection here is opened and then left alone: no transfer
    /// command is issued on the control connection, so nothing is ever going
    /// to arrive on it and the read can only end by being cancelled. The
    /// cancel is deterministic either way — a `next()` in a task that is
    /// already cancelled ends the same way one cancelled mid-wait does — so
    /// there is no clock and no race.
    ///
    /// The positive that a read of this channel CAN return bytes is the pair
    /// above: `epsvIsPreferredAndPASVIsTheFallback` and
    /// `restThenRETRResumesADownloadAtTheOffset` both read a seeded file to
    /// its end through this very method.
    @Test func aCancelledReadThrowsRatherThanReportingAShortFileAsComplete() async throws {
        let server = LoopbackFTPServer(
            security: .plain, advertisesMLSD: true, requiresTLSSessionReuse: false)
        await server.seedFile(Self.seededName, contents: Self.seeded)
        let outcome = try await Self.running(server) { host, port in
            let connection = try await Self.connect(server, host: host, port: port)
            let channel = try await FTPDataConnection.openPassive(on: connection)
            let sink = FTPByteSink()
            let reading = Task {
                await Self.outcome { sink.append(try await channel.readToEnd()) }
            }
            reading.cancel()
            let ended = await reading.value
            await channel.close()
            await connection.close()
            return (ended: ended, bytes: sink.count)
        }
        // Nothing arrived, which is exactly the state in which returning
        // `Data()` as a finished download would be wrong.
        #expect(outcome.bytes == 0)
        #expect(outcome.ended == .cancelled)
    }

    // MARK: - A refused session resumption

    /// A `522` is retried once rather than handed to the caller.
    ///
    /// A server with `require_ssl_reuse` refuses a data connection whose
    /// handshake was a full one. That is a condition the client can sometimes
    /// heal by opening another data connection, and a `522` reaching the user
    /// is a diagnosis nobody can act on — so the transfer tries a second time
    /// and only then reports the refusal.
    ///
    /// Both halves are here, because neither implies the other: a refusal
    /// that heals is retried and succeeds, and one that does not heal stops
    /// after exactly two attempts instead of looping.
    @Test func aRefusedSessionResumptionIsRetriedOnceRatherThanSurfaced() async throws {
        let healing = LoopbackFTPServer(
            security: .explicitTLS, advertisesMLSD: true, requiresTLSSessionReuse: true)
        await healing.seedFile(Self.seededName, contents: Self.seeded)
        let retried = try await Self.running(healing) { host, port in
            let connection = try await Self.connect(
                healing, host: host, port: port, security: .explicitTLS, decider: Self.accepting)
            await healing.refuseNextTransferWith522()
            let sink = FTPByteSink()
            let outcome = await Self.outcome {
                try await FTPDataConnection.transfer(
                    "RETR", argument: Self.seededName, on: connection
                ) { channel in
                    sink.append(try await channel.readToEnd())
                }
            }
            await connection.close()
            return (outcome: outcome, matched: sink.matches(Self.seeded))
        }
        #expect(retried.outcome == .completed)
        #expect(retried.matched)
        // The positive that the seam fired at all: two transfer commands
        // reached the server, so the success above is a retry and not a
        // refusal that never happened.
        let healingRETRs = await healing.receivedCommands.filter { $0.verb == "RETR" }.count
        #expect(healingRETRs == 2)

        // The other half: a refusal that does not heal stops after two.
        let refusing = LoopbackFTPServer(
            security: .explicitTLS, advertisesMLSD: true, requiresTLSSessionReuse: true)
        await refusing.seedFile(Self.seededName, contents: Self.seeded)
        let gaveUp = try await Self.running(refusing) { host, port in
            let connection = try await Self.connect(
                refusing, host: host, port: port, security: .explicitTLS, decider: Self.accepting)
            // The peer issues two sessions and both are taken here, so every
            // data connection from now on performs a FULL handshake and the
            // server refuses it. No seam: this is the server's own policy.
            let first = await connection.dataProtection()
            let second = await connection.dataProtection()
            let held = first?.session != nil && second?.session != nil
            let outcome = await Self.outcome {
                try await FTPDataConnection.transfer(
                    "RETR", argument: Self.seededName, on: connection
                ) { channel in
                    _ = try await channel.readToEnd()
                }
            }
            await connection.close()
            return (outcome: outcome, held: held)
        }
        #expect(gaveUp.held)
        #expect(gaveUp.outcome == .failed(.transferRefused(code: 522)))
        #expect(await refusing.refusedDataConnectionCount == 2)
    }
}
