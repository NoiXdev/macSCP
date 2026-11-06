import Foundation
import MacSCPTestSupport
import Testing

@testable import macSCPCore

/// The transfer pool: the reserved command connection beside it, the release
/// invariant that is the pool's real failure mode (spec §5a), and the `421`
/// budget that is keyed on host plus account.
///
/// **Nothing here puts a credential where a reader can reach it**, for the
/// reason `FTPControlConnectionTests` states: `#expect` prints the source text
/// of its expression AND what its subexpressions evaluated to. The pool is
/// built by `Self.pool`, which takes the server's generated credentials and
/// returns the pool; no expectation below takes a config, a password or an
/// address as an operand.
///
/// `.timeLimit(.minutes(5))` because the cases here call `pollUntil`, which
/// carries no deadline of its own (`PollingGuardTests`).
@Suite("FTP connection pool", .timeLimit(.minutes(5)))
struct FTPConnectionPoolTests {
    // MARK: - Helpers

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

    /// A pool against the loopback server.
    ///
    /// `account` is the budget's key beside the host, and it defaults to a
    /// fresh one per call: `FTPPoolBudget` is process-wide by design (spec
    /// §5a), so two tests sharing an account would share a refusal count and
    /// the second would read the first's shrink.
    private static func pool(
        _ server: LoopbackFTPServer, host: String, port: Int, slots: Int,
        account: String? = nil
    ) -> FTPConnectionPool {
        let credentials = server.credentials
        return FTPConnectionPool(
            config: FTPConnectionConfig(
                host: host, port: port, username: account ?? credentials.username,
                security: .plain, password: ""),
            password: credentials.password,
            transferSlots: slots,
            certificateDecider: .refusing,
            timeout: .seconds(30),
            trustStore: nil)
    }

    private static let seededName = "/payload.bin"
    /// 512 KiB, so a read arrives in several chunks and a stream can be
    /// abandoned between two of them.
    private static let seeded = Data((0..<(512 * 1024)).map { UInt8($0 % 251) })

    /// Takes one chunk off a lease's read stream and then DROPS the stream,
    /// by letting both it and its iterator go out of scope.
    ///
    /// A function rather than a `do { }` block in the caller, because the
    /// stream has to be released too: a block leaves it alive in the
    /// enclosing scope, and the termination handler that returns the lease
    /// runs when the last reference goes.
    private static func firstChunkThenDrop(
        _ lease: FTPTransferLease, path: String
    ) async throws -> Int {
        let stream = lease.readStream(path)
        var iterator = stream.makeAsyncIterator()
        return try await iterator.next()?.count ?? 0
    }

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

    // MARK: - The reserved connection

    /// The command connection is reserved: it is not one of the transfer
    /// slots, and it keeps answering while every slot is out.
    ///
    /// That is the whole of §5's connection model in one case — "four sockets
    /// per tab at the default" is three transfer slots plus this one — and
    /// the property a browser that stays usable during an upload rests on.
    @Test func theCommandConnectionIsNotOneOfTheTransferSlots() async throws {
        let server = LoopbackFTPServer(
            security: .plain, advertisesMLSD: true, requiresTLSSessionReuse: false)
        let outcome = try await Self.running(server) { host, port in
            let pool = Self.pool(server, host: host, port: port, slots: 2)
            let command = try await pool.command()
            // Reserved means the SAME connection comes back, not a second
            // dial that happens to behave alike.
            let again = try await pool.command()
            let reserved = command === again

            let first = try await pool.acquireTransfer()
            let second = try await pool.acquireTransfer()
            let freeWhileBothOut = await pool.freeTransferSlots
            // The command connection answers with both slots out: it is not
            // one of them, and nothing is queued behind them.
            let answered = try await command.send("PWD", argument: nil).code

            await first.release(reusable: true)
            await second.release(reusable: true)
            let freeAfterwards = await pool.freeTransferSlots
            await pool.shutdown()
            return (
                reserved: reserved, freeWhileBothOut: freeWhileBothOut, answered: answered,
                freeAfterwards: freeAfterwards
            )
        }
        #expect(outcome.reserved)
        #expect(outcome.freeWhileBothOut == 0)
        #expect(outcome.answered == 257)
        #expect(outcome.freeAfterwards == 2)
        // Three sockets for two slots: the reserved one is the third.
        #expect(await server.controlConnectionCount == 3)
    }

    // MARK: - The release invariant (spec §5a)

    /// A read stream that is abandoned mid-download gives its lease back.
    ///
    /// Written as a measurement rather than as an assertion of intent, which
    /// is what the brief asks for: the free count is AWAITED through
    /// `pollUntil`, never slept for. The abandonment is real — the stream and
    /// its iterator both go out of scope inside `firstChunkThenDrop` — and
    /// nothing in the test calls `release`.
    ///
    /// One leak per abandoned download ends in a permanently starved pool,
    /// which a user sees as a queue that hangs for no reason.
    @Test func anAbandonedReadStreamReturnsItsLeaseToThePool() async throws {
        let server = LoopbackFTPServer(
            security: .plain, advertisesMLSD: true, requiresTLSSessionReuse: false)
        await server.seedFile(Self.seededName, contents: Self.seeded)
        try await Self.running(server) { host, port in
            let pool = Self.pool(server, host: host, port: port, slots: 1)
            let lease = try await pool.acquireTransfer()
            // The positive beside the negative: the slot really is taken
            // while the stream is alive, so the recovery below is a release
            // and not a count that was never decremented.
            let freeWhileHeld = await pool.freeTransferSlots
            #expect(freeWhileHeld == 0)

            let firstChunk = try await Self.firstChunkThenDrop(lease, path: Self.seededName)
            // Something really was read before the drop, so the abandonment
            // happened mid-download rather than before it started.
            #expect(firstChunk > 0)

            try await pollUntil("the abandoned stream's lease to come back") {
                await pool.freeTransferSlots == 1
            }
            await pool.shutdown()
        }
    }

    /// A cancelled transfer's connection is discarded, and the slot it held
    /// comes back.
    ///
    /// Both halves, because neither implies the other: a pool that kept the
    /// connection would hand a possibly desynchronised one to the next item,
    /// and a pool that discarded it without returning the slot would starve.
    /// The third half — that the discarded connection was still FIT to be
    /// handed out, so the discard is a choice and not a connection the cancel
    /// destroyed — is
    /// `FTPDataConnectionTests.aCancelledTransferLeavesItsControlConnectionUsable`.
    ///
    /// What counts the discard is the server's own tally of control
    /// connections: a reused connection adds none, a discarded one costs a
    /// dial.
    @Test func aCancelledTransfersConnectionIsDiscardedAndNotReused() async throws {
        let server = LoopbackFTPServer(
            security: .plain, advertisesMLSD: true, requiresTLSSessionReuse: false)
        await server.seedFile(Self.seededName, contents: Self.seeded)
        let counts = try await Self.running(server) { host, port in
            let pool = Self.pool(server, host: host, port: port, slots: 1)

            // The positive first: an ordinary transfer's connection IS reused,
            // so the extra dial below belongs to the cancel and not to the
            // pool dialling every time.
            let first = try await pool.acquireTransfer()
            _ = await Self.outcome {
                try await first.transferring("RETR", argument: Self.seededName) { channel in
                    _ = try await channel.readToEnd()
                }
            }
            let afterOneTransfer = await server.controlConnectionCount
            let second = try await pool.acquireTransfer()
            await second.release(reusable: true)
            let afterReuse = await server.controlConnectionCount

            // And now the cancel.
            let reached = AsyncSignal()
            let parked = AsyncSignal()
            let third = try await pool.acquireTransfer()
            let work = Task {
                await Self.outcome {
                    try await third.transferring("RETR", argument: Self.seededName) { channel in
                        _ = try await channel.readToEnd()
                        reached.signal()
                        if await parked.wait() == .cancelled { throw CancellationError() }
                    }
                }
            }
            _ = await reached.wait()
            work.cancel()
            let ended = await work.value
            try await pollUntil("the cancelled transfer's slot to come back") {
                await pool.freeTransferSlots == 1
            }

            let fourth = try await pool.acquireTransfer()
            let afterCancel = await server.controlConnectionCount
            await fourth.release(reusable: true)
            await pool.shutdown()
            return (
                afterOneTransfer: afterOneTransfer, afterReuse: afterReuse,
                afterCancel: afterCancel, ended: ended
            )
        }
        #expect(counts.ended == .cancelled)
        // Reuse costs no dial.
        #expect(counts.afterReuse == counts.afterOneTransfer)
        // The cancel does: the connection it ran on was not handed out again.
        #expect(counts.afterCancel == counts.afterOneTransfer + 1)
    }

    /// A control connection that dies mid-transfer fails the item and frees
    /// the slot.
    ///
    /// The item fails — the caller is told, rather than being handed a
    /// truncated file — and the slot comes back without the test releasing
    /// anything, because `transferring` releases on every exit.
    @Test func aControlConnectionDroppedMidTransferFailsTheItemAndFreesTheSlot() async throws {
        let server = LoopbackFTPServer(
            security: .plain, advertisesMLSD: true, requiresTLSSessionReuse: false)
        await server.seedFile(Self.seededName, contents: Self.seeded)
        let outcome = try await Self.running(server) { host, port in
            let pool = Self.pool(server, host: host, port: port, slots: 1)
            let lease = try await pool.acquireTransfer()
            await server.dropControlConnectionMidTransfer()
            let received = FTPByteSink()
            let ended = await Self.outcome {
                try await lease.transferring("RETR", argument: Self.seededName) { channel in
                    received.append(try await channel.readToEnd())
                }
            }
            try await pollUntil("the dropped connection's slot to come back") {
                await pool.freeTransferSlots == 1
            }
            // And the next item is served: the pool is not poisoned by the
            // connection it discarded.
            let next = try await pool.acquireTransfer()
            let again = FTPByteSink()
            let secondEnded = await Self.outcome {
                try await next.transferring("RETR", argument: Self.seededName) { channel in
                    again.append(try await channel.readToEnd())
                }
            }
            await pool.shutdown()
            return (
                ended: ended, truncated: received.count < Self.seeded.count,
                secondEnded: secondEnded, secondMatched: again.matches(Self.seeded)
            )
        }
        // The item failed rather than reporting a short file as complete.
        #expect(outcome.ended == .failed(.connectionClosed))
        #expect(outcome.truncated)
        #expect(outcome.secondEnded == .completed)
        #expect(outcome.secondMatched)
    }

    /// A REFUSED transfer's connection is reused, because the server
    /// answered the command.
    ///
    /// The other arm of `FTPConnectionFailure.leavesConnectionInStep`, and it
    /// needs its own case: the dropped-connection case above pins the arm
    /// that discards, and a pool that discarded on every failure would pass
    /// that one while costing a dial per missing file. A `550` leaves the
    /// reply stream exactly where it was — the refusal is the whole answer
    /// and nothing further is owed
    /// (`FTPControlConnectionTests.aRefusedTransferCarriesNoCompletionReply`).
    @Test func aRefusedTransfersConnectionIsReusedBecauseTheServerAnsweredIt() async throws {
        let server = LoopbackFTPServer(
            security: .plain, advertisesMLSD: true, requiresTLSSessionReuse: false)
        await server.seedFile(Self.seededName, contents: Self.seeded)
        let outcome = try await Self.running(server) { host, port in
            let pool = Self.pool(server, host: host, port: port, slots: 1)
            let first = try await pool.acquireTransfer()
            let refused = await Self.outcome {
                try await first.transferring("RETR", argument: "/absent.bin") { channel in
                    _ = try await channel.readToEnd()
                }
            }
            let afterRefusal = await server.controlConnectionCount
            // The next item takes a connection: if the refused one had been
            // discarded, this would cost a dial.
            let second = try await pool.acquireTransfer()
            let sink = FTPByteSink()
            let served = await Self.outcome {
                try await second.transferring("RETR", argument: Self.seededName) { channel in
                    sink.append(try await channel.readToEnd())
                }
            }
            let afterReuse = await server.controlConnectionCount
            await pool.shutdown()
            return (
                refused: refused, served: served, matched: sink.matches(Self.seeded),
                afterRefusal: afterRefusal, afterReuse: afterReuse
            )
        }
        #expect(outcome.refused == .failed(.transferRefused(code: 550)))
        // The positive beside it: the connection that was kept really was
        // usable, and it served the next item.
        #expect(outcome.served == .completed)
        #expect(outcome.matched)
        #expect(outcome.afterReuse == outcome.afterRefusal)
    }

    // MARK: - The 421 budget

    /// A `421` on acquiring a transfer connection shrinks the budget for that
    /// host and account, and the item is served anyway.
    ///
    /// §5: the pool degrades gracefully rather than failing the queue. A
    /// `421` is the server saying "not this many", so the answer is fewer
    /// sockets, not a failed download.
    @Test func a421OnAcquireShrinksTheBudgetForThatHostAndAccount() async throws {
        let server = LoopbackFTPServer(
            security: .plain, advertisesMLSD: true, requiresTLSSessionReuse: false)
        // The ACCOUNT is the server's own generated user name, and that is
        // what isolates this case: `FTPPoolBudget` is process-wide by design,
        // so a hand-written account shared with another test would share its
        // refusal count. A server's credentials are generated per instance,
        // so the key here cannot collide -- and the account has to be one the
        // server will log in, which a made-up one is not.
        let outcome = try await Self.running(server) { host, port in
            let pool = Self.pool(server, host: host, port: port, slots: 3)
            // The budget is whole before anything is refused: the positive
            // beside the shrink below.
            let before = await pool.effectiveSlots()
            // The command connection is dialled first, so the armed refusal
            // lands on the transfer dial and not on it.
            _ = try await pool.command()
            await server.refuseNextAcquireWith421()
            let lease = try await pool.acquireTransfer()
            let after = await pool.effectiveSlots()
            await lease.release(reusable: true)
            await pool.shutdown()
            // Read straight off the budget as well, so the shrink is the
            // shared record's and not a number the pool kept to itself.
            // Computed into an `Int` first: an expectation naming the account
            // would print it.
            let recorded = await FTPPoolBudget.slots(
                host: host, account: server.credentials.username, configured: 3)
            return (before: before, after: after, recorded: recorded)
        }
        // The item was served — `acquireTransfer` returned rather than
        // throwing — and the budget is one smaller.
        #expect(outcome.before == 3)
        #expect(outcome.after == 2)
        #expect(outcome.recorded == 2)
    }

    /// A second pool on the same host and account starts from the shrunk
    /// budget.
    ///
    /// §5a: the server's limit is per account, so a per-tab shrink would let
    /// a third tab open at the default and re-trip the lockout the other two
    /// just escaped. The shared thing is a refusal count, never a connection.
    @Test func aSecondPoolOnTheSameHostAndAccountInheritsTheShrunkBudget() async throws {
        // Another account on the same host. It never dials — only
        // `effectiveSlots()` is asked of it — so it does not have to be one
        // the server would log in, and the account that DOES dial is the
        // server's own, for the isolation reason the case above states.
        let other = "unrelated-\(UUID().uuidString)"
        let server = LoopbackFTPServer(
            security: .plain, advertisesMLSD: true, requiresTLSSessionReuse: false)
        let outcome = try await Self.running(server) { host, port in
            let first = Self.pool(server, host: host, port: port, slots: 3)
            _ = try await first.command()
            await server.refuseNextAcquireWith421()
            let lease = try await first.acquireTransfer()
            await lease.release(reusable: true)
            await first.shutdown()

            // A pool that has refused nothing itself, on the same host and
            // account.
            let second = Self.pool(server, host: host, port: port, slots: 3)
            let inherited = await second.effectiveSlots()
            await second.shutdown()

            // The positive beside it: the budget is keyed, not global. A pool
            // on another account on the same host is untouched.
            let unrelated = Self.pool(server, host: host, port: port, slots: 3, account: other)
            let untouched = await unrelated.effectiveSlots()
            await unrelated.shutdown()
            return (inherited: inherited, untouched: untouched)
        }
        #expect(outcome.inherited == 2)
        #expect(outcome.untouched == 3)
    }

    // MARK: - The number (spec §5b)

    /// The slot count is `SettingsStore.maxConcurrentTransfers`, and it
    /// carries that setting's clamp.
    ///
    /// §5b: one number, the existing one. The clamp is the store's (1...8),
    /// and the pool clamps its own argument too — a pool built with zero
    /// slots would be a queue that can never start an item, which is a hang
    /// rather than a configuration.
    @Test @MainActor func theSlotCountFollowsMaxConcurrentTransfersAndItsClamp() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-ftp-pool-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SettingsStore(directory: directory)

        // The shipped default, which is where "four sockets per tab" comes
        // from: three slots plus the reserved command connection.
        #expect(store.maxConcurrentTransfers == 3)
        store.maxConcurrentTransfers = 99
        let clampedHigh = store.maxConcurrentTransfers
        store.maxConcurrentTransfers = 0
        let clampedLow = store.maxConcurrentTransfers
        #expect(clampedHigh == 8)
        #expect(clampedLow == 1)

        // And the pool follows it, including past the ends: a caller that
        // computes a slot count of its own cannot ask for none.
        let fromSetting = Self.slots(configured: clampedHigh)
        let fromFloor = Self.slots(configured: clampedLow)
        let belowTheFloor = Self.slots(configured: 0)
        let aboveTheCeiling = Self.slots(configured: 99)
        #expect(fromSetting == 8)
        #expect(fromFloor == 1)
        #expect(belowTheFloor == 1)
        #expect(aboveTheCeiling == 8)
    }

    /// A pool's configured slot count, built against nothing: the number is
    /// decided at construction and needs no server to read.
    private static func slots(configured: Int) -> Int {
        FTPConnectionPool(
            config: FTPConnectionConfig(
                host: "127.0.0.1", port: 21, username: "nobody", security: .plain, password: ""),
            password: "",
            transferSlots: configured,
            certificateDecider: .refusing,
            timeout: .seconds(30),
            trustStore: nil
        ).configuredSlots
    }
}
