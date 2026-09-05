import Foundation
import MacSCPTestSupport

/// Process-wide serialization for tests that mutate the `SSH_AUTH_SOCK`
/// environment variable (M11e/T2).
///
/// `@Suite(.serialized)` only serializes tests WITHIN one suite —
/// `AgentAuthTests` and `ConnectFailureSecrecyTests` (which take this lock
/// directly), and the gated agent tests in
/// `CitadelFileSystemIntegrationTests` and `GoServerRSAIntegrationTests`
/// (which reach it through `withAgentEnv`) are four DIFFERENT suites
/// (counted 2026-09-02, after a review found the first count one short),
/// and Swift Testing is free to run different suites
/// concurrently. All of them
/// temporarily overwrite the same process-global `SSH_AUTH_SOCK` variable
/// (set it to a test-owned socket, run a connect, restore the original), so
/// without a lock that spans suites, one suite's mutation could interleave
/// with the other's and leave a test authenticating against the wrong agent.
///
/// This is that cross-suite lock. Every env-mutation site wraps its
/// set/restore critical section in `AgentEnvLock.shared.run { ... }`.
///
/// `@unchecked Sendable` behind an `NSLock` rather than an `actor`: `acquire()`
/// routes through `awaitResumption`
/// (`Tests/MacSCPTestSupport/AwaitResumption.swift`), whose body closure
/// must be `@Sendable` to run on the unstructured task that watches for
/// cancellation — an actor's isolated state cannot be touched from a
/// `@Sendable` closure that way, so the lock takes over the isolation an
/// actor used to provide. Every critical section this lock guards is a
/// short synchronous mutation (append/remove-first on `waiters`), so an
/// `NSLock` is exactly as safe here as the actor was — the actor was chosen
/// for idiom, not because a plain lock could not do this job.
///
/// UNLIKE the broadcast latches elsewhere in this plan (`PlainSignal`,
/// `TestSignal`, `Gate`) — where an orphaned, never-removed waiter is
/// harmless because it is simply resumed later, a no-op nobody is
/// listening to — this is an EXCLUSIVE hand-off primitive: `release()`
/// pops exactly one waiter and hands it the lock. A cancelled `acquire()`
/// that left its entry in `waiters` would have `release()` pop that stale
/// entry, resume nobody real, and never reach the `waiters.isEmpty` branch
/// that clears `isLocked` — the lock leaks forever, in a process-wide
/// `static let shared`, and every later `AgentEnvLock.shared.run` queues
/// indefinitely.
///
/// Two rounds of the same lesson, both on 2026-09-05: round 1 gave each
/// QUEUED waiter a token (`id`) and an `awaitResumption` `onCancel:`
/// closure that removes it under the same lock before the
/// `CancellationError` reaches the caller — but `acquire()`'s FAST,
/// uncontested path (the lock is free, so this call takes it immediately)
/// used to run as an ordinary `body`, which committed `isLocked = true`
/// asynchronously with respect to `awaitResumption`'s own cancellation
/// bookkeeping — a cancellation landing in that gap left `isLocked` stuck
/// at `true` forever, held by nobody, because a token-removal `cleanup`
/// cannot undo an already-taken lock the way it undoes an entry sitting
/// in `waiters`. Round 3 moved that fast path into `tryImmediate` (see
/// `acquire()` below and `AwaitResumption.swift`'s own doc comment, "round
/// 3"): a synchronous, atomic "take it now or don't" callback that
/// commits inside the SAME critical section `awaitResumption` uses to
/// decide whether a cancellation still has anything to cancel — so a
/// cancellation arriving after `tryImmediate` commits finds nothing left
/// to undo, and one arriving before it never lets `tryImmediate` run at
/// all. `AgentEnvLockTests` pins the scenarios both rounds fixed.
final class AgentEnvLock: @unchecked Sendable {
    static let shared = AgentEnvLock()

    private let lock = NSLock()
    private var isLocked = false
    private var waiters: [(id: UUID, continuation: CheckedContinuation<Void, Never>)] = []

    /// Internal, not private: `AgentEnvLockTests` constructs its own
    /// instance rather than mutating `.shared`, so a test that deliberately
    /// cancels a queued waiter cannot interfere with — or be interfered
    /// with by — some other suite's concurrent, ordinary use of the
    /// process-wide lock.
    init() {}

    /// How many callers are currently queued behind the lock — read by
    /// `AgentEnvLockTests` to poll for "B has genuinely parked" before
    /// cancelling it, rather than guessing with a sleep.
    var queuedCount: Int { lock.withLock { waiters.count } }

    /// Whether the lock is currently held by anyone — read by
    /// `AgentEnvLockTests` to confirm a cancelled waiter's stale entry did
    /// not leave this stuck at `true` forever.
    var isCurrentlyLocked: Bool { lock.withLock { isLocked } }

    /// Internal, not private (same reason as `init()` above):
    /// `AgentEnvLockTests` calls `acquire()`/`release()` directly to
    /// model "this task now holds the lock, and I release it myself"
    /// versus "cancellation won and nothing was ever acquired" —
    /// `run(_:)`'s own acquire-body-release bundling can't express that
    /// distinction from outside.
    func acquire() async throws {
        let id = UUID()
        try await awaitResumption(
            // Queuing only — the uncontested fast path is `tryImmediate`
            // below, not here, per fix round 3: this closure runs on
            // `awaitResumption`'s own `bodyTask`, asynchronously with
            // respect to its `state`'s cancellation transition, so
            // anything it commits here is only ever a REVOCABLE queue
            // entry (`cleanup` below can always remove it). An
            // IRREVOCABLE commitment — actually taking the lock — must
            // happen inside `tryImmediate`'s own atomic step instead; see
            // `AwaitResumption.swift`'s doc comment, "round 3".
            { (continuation: CheckedContinuation<Void, Never>) in
                self.lock.withLock {
                    self.waiters.append((id, continuation))
                }
            },
            onCancel: {
                self.lock.withLock {
                    if let index = self.waiters.firstIndex(where: { $0.id == id }) {
                        self.waiters.remove(at: index)
                    }
                }
            },
            tryImmediate: {
                self.lock.withLock { () -> Void? in
                    guard !self.isLocked else { return nil }
                    self.isLocked = true
                    return ()
                }
            }
        )
    }

    func release() {
        let pending: CheckedContinuation<Void, Never>? = lock.withLock {
            if waiters.isEmpty {
                isLocked = false
                return nil
            } else {
                return waiters.removeFirst().continuation
            }
        }
        pending?.resume()
    }

    /// Runs `body` with exclusive ownership of the lock, for the whole
    /// duration `SSH_AUTH_SOCK` is set to a test-owned value.
    ///
    /// `throws` rather than `rethrows`: `acquire()` can itself throw
    /// `CancellationError` (if the calling task is cancelled while
    /// waiting), independently of whether `body` ever throws, which
    /// `rethrows` cannot express. The release is spelled out on both paths
    /// rather than left to `defer`, because it now has to run after an
    /// `await` — the ordering is unchanged: the lock is still given up
    /// before `run` returns or rethrows, and never given up if `acquire()`
    /// itself never completed.
    func run<T>(_ body: () async throws -> T) async throws -> T {
        try await acquire()
        do {
            let result = try await body()
            release()
            return result
        } catch {
            release()
            throw error
        }
    }
}
