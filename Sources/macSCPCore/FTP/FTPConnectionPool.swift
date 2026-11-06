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
    private var waiting: [UUID: CheckedContinuation<Void, Never>] = [:]

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
            let identifier = UUID()
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                waiting[identifier] = continuation
                waitingOrder.append(identifier)
            }
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
        waiting.removeValue(forKey: next)?.resume()
    }

    // MARK: - Lifecycle

    /// Closes the command connection and every idle transfer connection, and
    /// releases every waiter.
    ///
    /// Explicit, like every other lifecycle here: no `deinit` cleanup. A
    /// lease still out when this runs closes its own connection when it is
    /// released, because `isShutDown` stops it being pooled again.
    func shutdown() async {
        isShutDown = true
        let open = idle + [commandConnection].compactMap { $0 }
        idle = []
        commandConnection = nil
        for connection in open { await connection.close() }
        let stranded = waitingOrder
        waitingOrder = []
        for identifier in stranded { waiting.removeValue(forKey: identifier)?.resume() }
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
    /// drops the stream never returns to any code of its own. What covers it
    /// is the continuation's termination handler, which the runtime runs when
    /// the stream and its iterator are both released; it cancels the task
    /// doing the work, and that task's one exit path releases the lease.
    ///
    /// Cancelling after a normal finish is harmless — the task is already
    /// past its last suspension — so there is one handler and not two paths.
    func readStream(
        _ path: String, startingAt offset: Int64 = 0
    ) -> AsyncThrowingStream<Data, any Error> {
        let (stream, continuation) = AsyncThrowingStream.makeStream(
            of: Data.self, throwing: (any Error).self)
        let work = Task { [self] in
            do {
                try await FTPDataConnection.transfer(
                    "RETR", argument: path, restartingAt: offset > 0 ? offset : nil,
                    on: connection
                ) { channel in
                    try await channel.read { chunk in
                        // A consumer that has already gone is a read with
                        // nowhere to put its bytes: stop here rather than
                        // draining the rest of the file into a finished
                        // stream. The termination handler below has usually
                        // cancelled this task already; this is the same
                        // ending read off the yield instead.
                        if case .terminated = continuation.yield(chunk) {
                            throw CancellationError()
                        }
                    }
                }
                continuation.finish()
                await release(reusable: true)
            } catch {
                continuation.finish(throwing: error)
                await release(reusable: Self.reusable(after: error))
            }
        }
        continuation.onTermination = { _ in work.cancel() }
        return stream
    }

    /// Whether the connection a transfer failed on may be handed out again.
    private static func reusable(after error: any Error) -> Bool {
        if error is CancellationError { return false }
        guard let failure = error as? FTPConnectionFailure else { return false }
        return failure.leavesConnectionInStep
    }
}
