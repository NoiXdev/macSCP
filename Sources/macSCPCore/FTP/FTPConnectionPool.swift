import Foundation
import Synchronization

/// The process-wide `421` budget, keyed on host plus account (spec §5a).
///
/// **Why it is process-wide, against the architecture invariant that
/// connection state belongs to the window scope.** The shared thing here is
/// not a connection: it is a REFUSAL COUNT. A shared host counts connections
/// per account and answers `421 Too many connections`, so a shrink kept per
/// tab means two tabs on one host each shrink to one and still hold two
/// sockets each, and a third tab opens at the default and re-trips the
/// lockout the other two just escaped. The shape is `TabRegistry`'s —
/// bookkeeping, never state, and it holds no connection and nothing that
/// could close one.
///
/// It carries no credential: the account is a user name, which is also what
/// `StoredFTPConfig` persists in the clear.
enum FTPPoolBudget {
    /// One key's refusals. An actor rather than a `Mutex`, because the
    /// interface the plan asked for is `async` on both calls and an actor is
    /// what makes that honest rather than decorative.
    private actor Store {
        static let shared = Store()

        private var refusals: [Key: Int] = [:]

        func record(_ key: Key) {
            refusals[key, default: 0] += 1
        }

        func refusals(for key: Key) -> Int {
            refusals[key] ?? 0
        }
    }

    /// Host and account together. A struct rather than an interpolated
    /// string, so a host containing the separator cannot be confused with an
    /// account.
    private struct Key: Hashable, Sendable {
        let host: String
        let account: String
    }

    /// Records that this host and account answered a dial with `421`.
    static func refusalRecorded(host: String, account: String) async {
        await Store.shared.record(Key(host: host, account: account))
    }

    /// How many transfer connections this host and account may hold, given
    /// what the user configured.
    ///
    /// One fewer per refusal recorded, and never fewer than one: a budget of
    /// zero is a queue that can never start an item, which is a hang and not
    /// a degradation. §5's rule is that the pool degrades gracefully rather
    /// than failing the queue.
    static func slots(host: String, account: String, configured: Int) async -> Int {
        let refusals = await Store.shared.refusals(for: Key(host: host, account: account))
        return max(1, configured - refusals)
    }
}

/// One tab's FTP connections: the reserved command connection, and a pool of
/// transfer connections sized by `SettingsStore.maxConcurrentTransfers`
/// (spec §5, §5b).
///
/// FTP has no multiplexing — a control connection carries one data transfer
/// at a time — so "one connection per tab" cannot hold here. What holds
/// instead: listing, navigation, rename and delete run on a connection
/// nothing else may take, so a running upload never blocks the browser, and
/// each queue item takes a connection of its own from the pool. A tab holds
/// `maxConcurrentTransfers + 1` sockets, four at the shipped default.
///
/// **The release invariant is the pool's real failure mode, and it is why
/// `FTPTransferLease` exists** (spec §5a). A pooled connection is held by a
/// STREAM, not by a call, and a consumer that abandons the stream must still
/// give the connection back. One leak per abandoned download ends in a
/// permanently starved pool, which a user sees as a queue that hangs for no
/// reason. So every way of using a lease here — `transferring`, `readStream`
/// — releases it on every exit, including a thrown error and a cancellation,
/// and the explicit `release(reusable:)` is there for a lease that is never
/// used at all.
///
/// Nothing here blocks a thread: acquiring a slot is an `await` on a
/// continuation, never a semaphore (CLAUDE.md, "Tests never block the
/// cooperative pool" — and the rule binds the code the tests drive).
actor FTPConnectionPool {
    /// The floor and the ceiling a slot count is held to, the same 1...8 that
    /// `SettingsStore.maxConcurrentTransfers` clamps to (spec §5b: one
    /// number, the existing one). Clamped here too because a caller that
    /// computes its own number must not be able to ask for none.
    private static let slotRange = 1...8

    private let config: FTPConnectionConfig
    private let password: String
    private let certificateDecider: CertificateDecider
    private let timeout: Duration
    private let trustStore: TrustedCertificateStore?
    private let tuning: FTPControlConnection.Tuning

    /// How many transfer connections this pool was built for, clamped.
    /// `nonisolated` because it never changes and a caller reading the number
    /// should not have to hop.
    nonisolated let configuredSlots: Int

    /// Connections that are idle and fit to hand out again.
    private var idle: [FTPControlConnection] = []
    /// Leases that have been handed out and not returned.
    private var outstanding = 0
    /// Waiters for a slot, in arrival order, each resumed exactly once.
    private var waitingOrder: [UUID] = []
    private var waiting: [UUID: CheckedContinuation<Void, any Error>] = [:]

    private var commandConnection: FTPControlConnection?
    private var isShutDown = false

    init(
        config: FTPConnectionConfig,
        password: String,
        transferSlots: Int,
        certificateDecider: CertificateDecider,
        timeout: Duration,
        trustStore: TrustedCertificateStore?,
        tuning: FTPControlConnection.Tuning = .default
    ) {
        self.config = config
        self.password = password
        self.certificateDecider = certificateDecider
        self.timeout = timeout
        self.trustStore = trustStore
        self.tuning = tuning
        self.configuredSlots = min(
            Self.slotRange.upperBound, max(Self.slotRange.lowerBound, transferSlots))
    }

    // MARK: - The budget

    /// How many transfer connections this pool may hold right now: what it
    /// was configured for, less what this host and account have been refused.
    func effectiveSlots() async -> Int {
        await FTPPoolBudget.slots(
            host: config.host, account: config.username, configured: configuredSlots)
    }

    /// How many callers are parked waiting for a slot.
    ///
    /// **A seam, and it earns its keep rather than being convenience.** ONE
    /// case reads it, `shutdownReleasesAWaiterRatherThanLeavingItParked`,
    /// which has to know a waiter is really parked before it shuts the pool
    /// down: a waiter that has not parked yet takes the `guard !isShutDown`
    /// arm on its first look and never reaches the release the case exists
    /// to measure, so the case would pass against a pool that strands every
    /// waiter it has.
    ///
    /// Withdrawn wording, verbatim: "The two cases about a wait ENDING — by
    /// cancellation and by `shutdown()` — have to know a waiter is really
    /// parked before they end it". It was false of the cancellation case,
    /// which cancels at once and never reads this — and does not need to,
    /// because `waitForASlot` checks `Task.isCancelled` before it parks, so
    /// that case is deterministic either way. An enumeration in a comment is
    /// a claim about the rest of the project, and this one was written in the
    /// round whose R6 was three such claims; it is corrected here by running
    /// the command rather than by rereading the sentence:
    ///
    ///     /usr/bin/grep -rno 'pool\.waiterCount' Tests
    ///
    /// prints **1** line, the one call site. It is spelled with the receiver
    /// on purpose: a bare `waiterCount` over `Sources Tests` also matches
    /// `TransferQueueViewModel`'s unrelated property of the same name, the
    /// `conflictGateWaiterCount` that reads it, and — the reason the figure
    /// has to be a call-site count rather than a tree-wide one — every
    /// sentence here that names it, which moved the answer twice while this
    /// paragraph was being written.
    var waiterCount: Int { waitingOrder.count }

    /// Slots nothing is holding. Never negative: a budget that shrinks below
    /// what is already out means no new lease until one comes back, not a
    /// count that reads as a debt.
    var freeTransferSlots: Int {
        get async {
            max(0, await effectiveSlots() - outstanding)
        }
    }

    // MARK: - The reserved connection

    /// The command connection, dialled on first use and kept.
    ///
    /// Reserved: it is not one of the transfer slots, and nothing takes it
    /// away. Listing, navigation, `SIZE`, rename, delete and `MKD` run here.
    func command() async throws -> FTPControlConnection {
        // The same first statement `acquireTransfer()` below has, and for the
        // same reason: after `shutdown()` this pool dials nothing. Without
        // it, `commandConnection` is nil — `shutdown()` nils it — so a
        // command arriving after a disconnect opened a FRESH connection,
        // greeting, TLS where the mode has it, and a login with the password
        // this pool still holds, which nothing then closed. It was reachable
        // by any post-disconnect `list`/`stat`, and the case that measured it
        // is an App one: `SessionTab`'s permission probe is started by the
        // install and not awaited, so a teardown can race it into here
        // (Ruling T8.9 of the FTP plan, fix round 2;
        // `FTPFileSystemTests.aProbeAfterTheConnectionWasShutDownOpensNoSecondConnection`).
        guard !isShutDown else { throw FTPConnectionFailure.connectionClosed }
        if let commandConnection { return commandConnection }
        let connection = try await dial()
        commandConnection = connection
        return connection
    }

    // MARK: - Transfer slots

    /// A lease on one transfer connection, waiting for a slot if every one is
    /// out.
    ///
    /// The wait is an `await` on a continuation: waiters are released in
    /// arrival order, each exactly once, which is the shape
    /// `FTPControlConnection`'s command turn already uses.
    func acquireTransfer() async throws -> FTPTransferLease {
        while true {
            guard !isShutDown else { throw FTPConnectionFailure.connectionClosed }
            // The budget is read FIRST, and the test-and-take below it runs
            // with no suspension in between: an actor is re-entrant at every
            // `await`, so reading the limit and taking the slot in one
            // expression would let two acquires both see the last slot free
            // and both take it.
            let limit = await effectiveSlots()
            if outstanding < limit {
                outstanding += 1
                break
            }
            try await waitForASlot()
        }
        do {
            let connection = try await reuseOrDial()
            return FTPTransferLease(pool: self, connection: connection)
        } catch {
            // The slot is given back before the error leaves: a dial that
            // failed is not a connection anybody is holding.
            outstanding -= 1
            wakeOneWaiter()
            throw error
        }
    }

    /// Parks until a slot frees, and ANSWERS CANCELLATION.
    ///
    /// **A bare continuation does not.** `withCheckedContinuation` ignores
    /// its task's cancellation, so a queue item cancelled while it waited
    /// for a slot would wait forever — and, measured on 2026-11-06, so does
    /// a TEST: a mutation probe that planted away `transferring`'s release
    /// left four pool cases parked here, and the planted run did not stop at
    /// its 300-second time limit but ran past twelve minutes until it was
    /// killed. That is `docs/BACKLOG.md`'s row "A test parked on a bare
    /// continuation outlives its time limit", reached through this wait.
    ///
    /// Two races, both closed on the actor rather than with a second lock.
    /// `onCancel` cannot touch actor state, so it hops; if that hop lands
    /// FIRST, `cancelWaiter` finds nothing to cancel — and the body below
    /// then sees `Task.isCancelled`, because the flag is set before
    /// `onCancel` runs, so it refuses to park at all. If the body lands
    /// first, the hop finds the waiter and resumes it. Either way the
    /// continuation is resumed exactly once, because removing the entry and
    /// resuming it happen together in one actor step, here and in
    /// `wakeOneWaiter`.
    private func waitForASlot() async throws {
        let identifier = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, any Error>) in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                waiting[identifier] = continuation
                waitingOrder.append(identifier)
            }
        } onCancel: {
            Task { await self.cancelWaiter(identifier) }
        }
    }

    /// Releases one waiter with a `CancellationError`, if it is still
    /// waiting.
    private func cancelWaiter(_ identifier: UUID) {
        guard let continuation = waiting.removeValue(forKey: identifier) else { return }
        waitingOrder.removeAll { $0 == identifier }
        continuation.resume(throwing: CancellationError())
    }

    /// Takes an idle connection, or dials a new one.
    private func reuseOrDial() async throws -> FTPControlConnection {
        if let reused = idle.popLast() { return reused }
        return try await dial()
    }

    /// One dial, with the `421` rule of §5 on it.
    ///
    /// A `421` is the server saying "not this many", so it shrinks the budget
    /// for this host and account and the dial is tried once more. It does not
    /// fail the item: the queue degrades to fewer sockets rather than to a
    /// failed download. A second `421` is reported, because a client that
    /// kept retrying a server that keeps refusing is a client in a loop.
    ///
    /// **It sees a `421` GREETING only, which is the narrower of the two
    /// readings §5 admits.** A shared host that accepts the connection and
    /// then answers `421` to `USER` or `PASS` does not shrink the budget
    /// here: that refusal arrives as `loginRefused`, which is also what a
    /// wrong password is, and telling the two apart means carrying the reply
    /// code out of the login. §5 does not say when the `421` arrives, so
    /// this is not a violation — but it is a choice, and the wider reading
    /// belongs with whoever maps reply codes for the UI.
    private func dial() async throws -> FTPControlConnection {
        do {
            return try await connect()
        } catch FTPConnectionFailure.greetingRefused(let code) where code == Self.tooManyConnections {
            await FTPPoolBudget.refusalRecorded(host: config.host, account: config.username)
            return try await connect()
        }
    }

    /// `421 Service not available`, which a shared host answers when an
    /// account already holds as many connections as it may.
    private static let tooManyConnections = 421

    private func connect() async throws -> FTPControlConnection {
        try await FTPControlConnection.connect(
            config,
            password: password,
            certificateDecider: certificateDecider,
            timeout: timeout,
            trustStore: trustStore,
            tuning: tuning)
    }

    /// Takes a lease back. Called by `FTPTransferLease` and by nothing else.
    ///
    /// `reusable: false` DISCARDS the connection (spec §5a): a cancelled or
    /// desynchronised control connection is dropped rather than returned,
    /// because the next command's reply would otherwise be read as the
    /// previous command's and the backend would answer confidently and
    /// wrongly. The slot comes back either way — that is the half a starved
    /// pool is made of.
    fileprivate func give(back connection: FTPControlConnection, reusable: Bool) async {
        outstanding = max(0, outstanding - 1)
        if reusable, !isShutDown {
            idle.append(connection)
        } else {
            await connection.close()
        }
        wakeOneWaiter()
    }

    private func wakeOneWaiter() {
        guard let next = waitingOrder.first else { return }
        waitingOrder.removeFirst()
        waiting.removeValue(forKey: next)?.resume(returning: ())
    }

    // MARK: - Lifecycle

    /// Closes the command connection and every idle transfer connection, and
    /// releases every waiter.
    ///
    /// Explicit, like every other lifecycle here: no `deinit` cleanup. A
    /// lease still out when this runs closes its own connection when it is
    /// released, because `isShutDown` stops it being pooled again.
    ///
    /// **What bounds this stage, and where that bound comes from.** It is the
    /// fourth and last stage of `TabTeardown.run`, which calls
    /// `remote.disconnect()` unbounded — deliberately, because the SSH
    /// backend carries a bound of this project's own inside
    /// `CitadelFileSystem.disconnect()`. FTP carries none: this function ends
    /// in `FTPControlConnection.close()`, whose last statement is
    /// `channel.close().get()`, the cancellation-blind shape `BoundedClose`'s
    /// own doc comment describes. What bounds it is the TLS library's
    /// default, which is somebody else's number rather than this project's:
    /// `clientContext()` builds from `TLSConfiguration.makeClientConfiguration()`,
    /// whose `shutdownTimeout` is `.seconds(5)`
    /// (`.build/checkouts/swift-nio-ssl/Sources/NIOSSL/TLSConfiguration.swift`,
    /// the `makeClientConfiguration` literal), and `NIOSSLHandler
    /// .scheduleTimedOutShutdown` is what schedules the unclean shutdown on
    /// it. Plain FTP's close is a local TCP close and returns at once; an
    /// FTPS close against a peer that stops answering `close_notify` is
    /// capped near five seconds.
    ///
    /// **So the closes run CONCURRENTLY, and that is the whole reason for the
    /// task group.** A pool holds up to `maxConcurrentTransfers + 1`
    /// connections and nothing evicts an idle one beforehand — there is no
    /// reaper, and `idle` is touched in four places: its declaration,
    /// `reuseOrDial`, `give(back:reusable:)` and here, which this command
    /// prints as five lines (the two statements of this function being one
    /// place):
    ///
    ///     /usr/bin/grep -n -e '^    private var idle' -e '^        if let reused = idle\.popLast' -e '^            idle\.append' -e '^        let open = idle' -e '^        idle = \[\]' Sources/macSCPCore/FTP/FTPConnectionPool.swift
    ///
    /// **Every pattern is anchored at the line start, with the code's own
    /// indentation, and that is not tidying.** Corrected 2026-11-08, Ruling
    /// N2: the committed form carried the patterns unanchored and claimed five
    /// lines, and it printed **six** — the sixth being the command line in
    /// this very comment, which spells what it searches for. (Withdrawn
    /// wording, verbatim: the same command line without the five `^` and
    /// without the indentation in each pattern. It is not reproduced here in
    /// full, because a verbatim copy would re-create the defect it is being
    /// withdrawn for and move the figure again — Ruling T5b.6; what changed is
    /// the anchoring and nothing else.) A doc comment that quotes the code it
    /// describes is indistinguishable from that code to a scanner, which is
    /// CLAUDE.md's "Source-scanning guards read comments too", and an anchored
    /// pattern is the cheapest thing that tells them apart: a `///` line
    /// cannot begin with four spaces and then `private var idle`.
    ///
    /// So one FTPS tab at the maximum setting
    /// holds nine. Serially that stage was up to nine five-second bounds —
    /// about 45 s — against a `QuitWatchdog.bound` of 15 s whose own
    /// derivation computes "one tab's worth" from three bounds with the third
    /// measured at ~5 s. Independent sockets have no reason to close in
    /// series, so the group makes the stage ONE such bound again and the
    /// quit's arithmetic true again. Nothing here blocks a thread and nothing
    /// waits on a clock: each child task awaits one actor's `close()`, and
    /// this actor's state is emptied BEFORE the group runs, so the
    /// re-entrancy the group's suspension allows finds nothing left to close
    /// — a second `shutdown()` finds an empty `open`, `command()` and
    /// `acquireTransfer()` refuse on `isShutDown`, and a lease released
    /// meanwhile closes its own connection.
    ///
    /// **The five seconds in THIS comment is read from the library's source,
    /// cited above, and not measured in production** — the label matters
    /// because SSH's figure in the same argument
    /// (`TeardownStage`, `5.002063 s / 5.304208 s / 5.333977 s`) was measured
    /// against a frozen peer and this one was not.
    ///
    /// It HAS since been observed against the fixture, which is a different
    /// claim and is why the label above still stands. (Withdrawn wording,
    /// verbatim: "reproducing it needs a peer that accepts the connection and
    /// then stops answering `close_notify`, which the loopback fixture cannot
    /// be made to do (its own NIOSSL handler answers on its own event loop)".
    /// The obstacle was named correctly and the conclusion was wrong: a
    /// handler at the HEAD of the server's pipeline, before the TLS handlers,
    /// drops the raw ciphertext a `close_notify` arrives as, so the server's
    /// own handler never sees it — `LoopbackFTPServer.goDeaf()`.) With that,
    /// `shutdownClosesTheConnectionsAtOnceRatherThanOneAfterAnother` spent
    /// 5.070 s and 5.223 s on two runs closing three connections
    /// concurrently, and it asserts neither figure: it asserts that all three
    /// closes were in flight while none had finished, which is the property
    /// this task group exists for and the one a serial loop cannot produce.
    /// `shutdownClosesEveryConnectionThePoolHeldAtOnce` is the other half,
    /// that every connection is closed at all.
    func shutdown() async {
        isShutDown = true
        let open = idle + [commandConnection].compactMap { $0 }
        idle = []
        commandConnection = nil
        await withTaskGroup(of: Void.self) { group in
            for connection in open {
                group.addTask { await connection.close() }
            }
        }
        let stranded = waitingOrder
        waitingOrder = []
        for identifier in stranded { waiting.removeValue(forKey: identifier)?.resume(returning: ()) }
    }
}

/// One transfer connection, reserved.
///
/// **A lease can only be used with the connection it came from**, because the
/// connection never leaves it: there is no `lease.connection` to pair with
/// another lease's slot, and `transferring` and `readStream` are the only
/// ways in. That is the scoping guard as a type rather than as a check
/// (CLAUDE.md, "Guards that name what they watch": prefer a violation that
/// will not compile).
///
/// **`deinit` is NOT the release path.** Release is explicit and total: every
/// method here that uses the connection releases the lease on every exit —
/// normal completion, a thrown error, or cancellation — and
/// `release(reusable:)` is there for a lease that is acquired and then not
/// used. A `deinit` release would be a release at a time nobody chose, on a
/// thread nobody chose, with no way to say whether the connection is still
/// fit to reuse.
final class FTPTransferLease: Sendable {
    private let pool: FTPConnectionPool
    private let connection: FTPControlConnection
    /// Whether the lease has already gone back. The first release decides,
    /// and later ones do nothing: a second release that incremented the free
    /// count would hand one slot to two items, which is worse than the leak
    /// it would be covering for.
    private let returned = Mutex(false)

    fileprivate init(pool: FTPConnectionPool, connection: FTPControlConnection) {
        self.pool = pool
        self.connection = connection
    }

    /// Gives the connection back. Idempotent; the first call decides.
    ///
    /// `reusable: false` discards the connection — see
    /// `FTPConnectionPool.give(back:reusable:)`.
    func release(reusable: Bool) async {
        let first = returned.withLock { done -> Bool in
            let was = done
            done = true
            return !was
        }
        guard first else { return }
        await pool.give(back: connection, reusable: reusable)
    }

    /// Whether this lease has gone back, read the same way `release` reads
    /// it.
    ///
    /// **What it closes, and what it does not.** A lease whose connection the
    /// pool has already handed to somebody else must not run a transfer on
    /// it: the review measured exactly that — one socket, two owners, a
    /// complete `RETR` on a connection a second lease held. Both entry points
    /// ask this before they touch the connection, so use-AFTER-return cannot
    /// happen. What this cannot see is a `release` racing a transfer that is
    /// ALREADY running, because the check is a read and not a reservation;
    /// that is a caller releasing a lease it is using, which is a misuse the
    /// type has no way to express a refusal of — `transferring` and
    /// `readStream` release the lease themselves, so a correct caller never
    /// calls `release` for a transfer in flight.
    private var hasGoneBack: Bool { returned.withLock { $0 } }

    /// Runs one transfer on this lease's connection and releases the lease.
    ///
    /// Total: the release happens on every exit. Whether the connection is
    /// reusable afterwards is read off the failure — a server that REFUSED a
    /// command answered it, and the reply stream is where it was, while a
    /// connection that closed, timed out or sent something unreadable is one
    /// nothing has established the state of
    /// (`FTPConnectionFailure.leavesConnectionInStep`). A cancellation is
    /// never reusable (§5a).
    func transferring(
        _ command: String, argument: String? = nil,
        restartingAt offset: Int64? = nil,
        draining body: @Sendable (FTPDataChannel) async throws -> Void
    ) async throws {
        guard !hasGoneBack else { throw FTPConnectionFailure.leaseAlreadyReturned }
        do {
            try await FTPDataConnection.transfer(
                command, argument: argument, restartingAt: offset, on: connection,
                draining: body)
        } catch {
            await release(reusable: Self.reusable(after: error))
            throw error
        }
        await release(reusable: true)
    }

    /// A download as a stream of chunks, with the lease released on every way
    /// the stream can end — read to its end, thrown, or ABANDONED.
    ///
    /// The abandoned case is the one spec §5a is about, and it is the one a
    /// call-site `defer` cannot cover: a consumer that stops iterating and
    /// drops the stream never returns to any code of its own.
    ///
    /// **It is PULL-based, which is what makes the abandonment visible.**
    /// `AsyncStream`'s `yield` never suspends, so a pushing drain runs to the
    /// end of the file whatever the consumer does — and a drain that runs to
    /// the end releases the lease by FINISHING, so a case that abandoned a
    /// stream would be measuring a transfer that completed anyway. The
    /// consumer therefore asks for each chunk through `demands`, and the
    /// drain takes one of those tokens before it reads on. At most two
    /// CONSUMER-VISIBLE chunks are in flight: one in `supply`, one in the
    /// consumer's hand.
    ///
    /// **It does NOT bound the memory this transfer costs, and the earlier
    /// version of this comment said it did.** Withdrawn wording, verbatim:
    /// "It is PULL-based, which is what makes the abandonment visible AND
    /// bounds the memory", "a 4 GB download would sit in the buffer", and "At
    /// most two chunks are ever in flight, which is the same 'never more than
    /// one chunk is buffered' `LocalFileSystem.readStream` states, within one
    /// chunk of read-ahead". The two-chunk count is right for the chunks the
    /// consumer sees and says nothing about the layer under it: the data
    /// channel's inbound stream is built with no buffering policy, whose
    /// default is unbounded, `FTPChannelSink.channelRead` yields into it
    /// unconditionally, and nothing under `Sources/macSCPCore/FTP/` turns
    /// NIO's automatic reading off. So the socket is drained as fast as the
    /// network delivers, however little the consumer asks for.
    ///
    /// Measured 2026-11-06 — a 67,108,864-byte file, one 2,048-byte chunk
    /// pulled and held, resident size sampled until it stopped moving:
    /// growth **134,987,776 bytes, 2.01x the payload** (two copies, both ends
    /// being in one process for the loopback rig). The control at an eighth
    /// of the payload, 8,388,608 bytes, grew 17,186,816 — **2.05x** — so the
    /// figure tracks the file and is not a fixed overhead, which is what
    /// "unbounded" means here. The measurement was an untracked test case,
    /// removed with `rm`; it asserts no figure, because a resident-size
    /// figure asserted on one machine is a test that fails on another.
    ///
    /// **The commands that establish all of it live in the `docs/BACKLOG.md`
    /// row "An FTP download's inbound buffer is unbounded", and they live
    /// there rather than here for a reason worth knowing**: the negative one
    /// searches these sources for the name of the option nobody sets, so a
    /// comment that quoted it would be the only match and would report
    /// itself — the self-falsifying sentence CLAUDE.md records, caught here
    /// by re-running the command after writing the sentence. The real bound
    /// is in that row too: a buffering policy, automatic reading off, and an
    /// explicit read per chunk, which is the shape
    /// `Sources/macSCPCore/Tunnels/BytePump.swift` already uses. It is a
    /// design, not an edit.
    ///
    /// What ends the drain when the consumer walks away: dropping the stream
    /// releases the closure below, which holds the only reference to the
    /// demand continuation, so the demand stream finishes and the drain's
    /// next token does not arrive. It throws, and its one exit path releases
    /// the lease.
    func readStream(
        _ path: String, startingAt offset: Int64 = 0
    ) -> AsyncThrowingStream<Data, any Error> {
        // A returned lease refuses here too, and it has to refuse through the
        // stream: this method cannot throw, and handing back a working
        // stream on a connection somebody else holds is the very thing
        // `hasGoneBack` exists to stop.
        guard !hasGoneBack else {
            return AsyncThrowingStream { throw FTPConnectionFailure.leaseAlreadyReturned }
        }
        // Consumer to drain: one token per chunk wanted.
        let (demands, continuation) = AsyncStream.makeStream(of: Void.self)
        let demand = FTPDemandSource(continuation)
        // Drain to consumer.
        let (supply, chunks) = AsyncThrowingStream.makeStream(
            of: Data.self, throwing: (any Error).self)
        let waiting = FTPSingleReader(demands)
        let arriving = FTPSingleThrowingReader(supply)
        Task { [self] in
            do {
                try await FTPDataConnection.transfer(
                    "RETR", argument: path, restartingAt: offset > 0 ? offset : nil,
                    on: connection
                ) { channel in
                    try await channel.read { chunk in
                        chunks.yield(chunk)
                        // Asked for AFTER the chunk is handed over, so the
                        // first one needs no token and the drain is parked
                        // here — not on the network — whenever the consumer
                        // is idle. A consumer that has gone finishes this
                        // stream, and that is the ending.
                        guard await waiting.next() else { throw CancellationError() }
                    }
                }
                chunks.finish()
                await release(reusable: true)
            } catch {
                chunks.finish(throwing: error)
                await release(reusable: Self.reusable(after: error))
            }
        }
        return AsyncThrowingStream {
            demand.request()
            return try await arriving.next()
        }
    }

    /// Whether the connection a transfer failed on may be handed out again.
    ///
    /// An error this layer does not recognise is NOT reusable, and a
    /// cancellation is one of those: §5a's rule is that a cancelled or
    /// desynchronised connection is dropped, and "I do not know what this
    /// error means" is not a state in which to hand a connection to the next
    /// item. A mutation probe on 2026-11-06 is why this says so rather than
    /// testing for `CancellationError` by name: an `if error is
    /// CancellationError { return false }` stood here, and planting it away
    /// was GREEN across 8 tests, because the `guard` below already answers
    /// `false` for it. A line both of whose arms agree is not a guard.
    private static func reusable(after error: any Error) -> Bool {
        guard let failure = error as? FTPConnectionFailure else { return false }
        return failure.leavesConnectionInStep
    }
}

/// The consumer's end of a `readStream`'s demand channel.
///
/// **Its `deinit` is how a dropped stream is noticed, and it is spelled by
/// hand because `AsyncThrowingStream(unfolding:)` has no `onTermination`.**
/// It is the same mechanism — the stream's storage going away — reached
/// through the only hook an unfolding stream offers: the closure it holds,
/// which holds this. Measured 2026-11-06: releasing the `AsyncStream.Continuation`
/// alone did NOT finish the stream, so the drain stayed parked on a token
/// that could not arrive and `anAbandonedReadStreamReturnsItsLeaseToThePool`
/// ran into its 300-second hang bound. With the explicit `finish()` here it
/// passes.
///
/// **Why this is not the `deinit` cleanup CLAUDE.md rules out, argued
/// properly.** The first version of this paragraph said "nothing is torn down
/// here. One stream is finished", and the review was right that this is too
/// quick: the chain this `deinit` starts ends in `connection.close()`, so
/// something certainly is torn down. The invariant is about teardown that is
/// ORDERED AND OWNED — the UI runs `cancelAll` → `shutdown` → `disconnect`
/// in one place, and nothing may reach around that order through an object
/// graph nobody sequenced. This does not: the owner here is the CONSUMER of
/// the stream, releasing it IS its explicit act, and the order that follows
/// is the one `readStream` spells — finish the demand, let the drain throw,
/// release the lease, and let the pool decide whether the connection is
/// pooled or closed. What makes a hook necessary at all is spec §5a, which
/// requires abandonment to return the lease, and an unfolding stream offers
/// no other; what makes it safe is that the hook starts a sequence rather
/// than performing a teardown.
final class FTPDemandSource: Sendable {
    private let continuation: AsyncStream<Void>.Continuation

    init(_ continuation: AsyncStream<Void>.Continuation) {
        self.continuation = continuation
    }

    /// Asks for one more chunk.
    func request() {
        continuation.yield(())
    }

    deinit {
        continuation.finish()
    }
}

/// One `AsyncStream`'s iterator, in a reference a closure can hold.
///
/// `FTPLineSource`'s shape and for its reason: an actor cannot call a
/// mutating `async` method on a stored property, a closure cannot capture a
/// mutable local and still be `@Sendable`, and an `AsyncStream` has a single
/// consumer — two overlapping `next()` calls on one iterator are undefined
/// behaviour that stays silent, so `reader` turns a violation into a named
/// trap. Here the single consumer is the drain of one `readStream`.
final class FTPSingleReader: @unchecked Sendable {
    private var iterator: AsyncStream<Void>.Iterator
    private let reader = Mutex(false)

    init(_ stream: AsyncStream<Void>) {
        iterator = stream.makeAsyncIterator()
    }

    /// Whether a token arrived. `false` means the other end has gone.
    func next() async -> Bool {
        let overlapped = reader.withLock { busy -> Bool in
            let was = busy
            busy = true
            return was
        }
        precondition(!overlapped, "two reads overlapped on one FTP demand stream")
        defer { reader.withLock { $0 = false } }
        return await iterator.next() != nil
    }
}

/// The same, for the chunks a `readStream`'s consumer pulls. Its single
/// consumer is the unfolding closure the stream hands out, which the runtime
/// never calls twice at once.
final class FTPSingleThrowingReader: @unchecked Sendable {
    private var iterator: AsyncThrowingStream<Data, any Error>.Iterator
    private let reader = Mutex(false)

    init(_ stream: AsyncThrowingStream<Data, any Error>) {
        iterator = stream.makeAsyncIterator()
    }

    func next() async throws -> Data? {
        let overlapped = reader.withLock { busy -> Bool in
            let was = busy
            busy = true
            return was
        }
        precondition(!overlapped, "two reads overlapped on one FTP chunk stream")
        defer { reader.withLock { $0 = false } }
        return try await iterator.next()
    }
}
