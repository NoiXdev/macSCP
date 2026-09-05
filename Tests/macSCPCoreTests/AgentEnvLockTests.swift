import Foundation
import MacSCPTestSupport
import Testing

/// Pins the fix for `docs/BACKLOG.md`'s "A test parked on a bare
/// continuation outlives its time limit", fix round 1: `AgentEnvLock`
/// (`Tests/macSCPCoreTests/AgentEnvLock.swift`) is an EXCLUSIVE hand-off
/// primitive, unlike the broadcast latches (`PlainSignal`, `TestSignal`,
/// `Gate`) also converted to `awaitResumption` in this plan. A cancelled
/// waiter that left its entry behind made `release()` pop that stale
/// entry, hand the lock to a task that no longer existed, and never clear
/// `isLocked` — a permanent leak in a process-wide lock.
///
/// A fresh `AgentEnvLock()` instance, never `.shared`: this test cancels a
/// queued waiter on purpose, and `.shared` is a process-wide lock other
/// suites use concurrently for their own, unrelated `SSH_AUTH_SOCK`
/// critical sections — sharing it here would risk this test interfering
/// with (or being interfered with by) them.
@Suite("AgentEnvLock", .timeLimit(.minutes(1)))
struct AgentEnvLockTests {
    /// The scenario the bug produced: A holds the lock, B queues behind
    /// it, B is cancelled while still queued, A releases — and a fresh C
    /// must still be able to acquire without waiting, with `isLocked` false
    /// again once C releases. Under the bug this test's own `.timeLimit`
    /// is what turns C's hang into a red rather than an actual deadlock —
    /// C's `run` would queue forever behind a lock nothing will ever
    /// release again.
    @Test func aCancelledWaiterDoesNotLeakTheLockForever() async throws {
        let lock = AgentEnvLock()
        let aHolds = AsyncSignal()
        let releaseA = AsyncSignal()

        let taskA = Task<Void, any Error> {
            try await lock.run {
                aHolds.signal()
                _ = await releaseA.wait()
            }
        }
        let aOutcome = await aHolds.wait()
        #expect(aOutcome == .signalled)

        let taskB = Task<Void, any Error> {
            try await lock.run {}
        }
        // B must be genuinely parked in `acquire()` — appended to
        // `waiters`, not merely scheduled — before it is cancelled; a
        // `pollUntil` on the lock's own queued count, no clock, is the
        // deterministic way to know that without a sleep.
        try await pollUntil("B queues behind A") { lock.queuedCount == 1 }

        taskB.cancel()
        await #expect(throws: CancellationError.self) {
            try await taskB.value
        }

        // Positive, read BEFORE A releases: the cancelled waiter's entry
        // is already gone, not merely "will be skipped later" — without
        // this, the fix could be proven only by C eventually succeeding,
        // which the bug would also eventually do if some UNRELATED task
        // happened to call release() again.
        #expect(lock.queuedCount == 0, "B's cancelled entry should have been removed from the queue")

        releaseA.signal()
        try await taskA.value

        // A fresh task acquires without waiting — under the bug this hangs
        // until the suite's own `.timeLimit`, because `isLocked` never
        // cleared and nothing will ever call `release()` again to serve it.
        let taskC = Task<Void, any Error> {
            try await lock.run {}
        }
        try await taskC.value

        #expect(lock.isCurrentlyLocked == false)
    }

    /// Fix round 2: the SAME scenario as `aCancelledWaiterDoesNotLeakTheLockForever`,
    /// but B is created and cancelled in the SAME synchronous step — no
    /// `pollUntil` gives B's own task a chance to run and append itself to
    /// `waiters` before the cancel lands. This is the exact shape the
    /// round-2 finding named: cancellation arriving before the body has
    /// registered anything. Under round 1's fix, `onCancel` fired
    /// `cleanup` only when a continuation had already been stored in
    /// `awaitResumption`'s own `state` — which nothing here guarantees —
    /// so B's body could still register its token AFTER `cleanup` had
    /// already run (or without `cleanup` ever running at all), leaving it
    /// orphaned exactly as before.
    @Test func aWaiterCancelledBeforeItRegistersDoesNotLeakTheLockForever() async throws {
        let lock = AgentEnvLock()
        let aHolds = AsyncSignal()
        let releaseA = AsyncSignal()

        let taskA = Task<Void, any Error> {
            try await lock.run {
                aHolds.signal()
                _ = await releaseA.wait()
            }
        }
        let aOutcome = await aHolds.wait()
        #expect(aOutcome == .signalled)

        // Created and cancelled in the same synchronous step: B's own task
        // never gets a chance to run before `.cancel()` marks it, so any
        // registration `acquire()` performs happens strictly AFTER the
        // cancellation already won — the ordering round 1 did not cover.
        let taskB = Task<Void, any Error> {
            try await lock.run {}
        }
        taskB.cancel()

        await #expect(throws: CancellationError.self) {
            try await taskB.value
        }

        releaseA.signal()
        try await taskA.value

        // A fresh task acquires without waiting — under the bug this hangs
        // until the suite's own `.timeLimit`, because a stale entry from
        // B (registered after its own cancellation) leaves `isLocked`
        // stuck at `true` forever.
        let taskC = Task<Void, any Error> {
            try await lock.run {}
        }
        try await taskC.value

        #expect(lock.isCurrentlyLocked == false)
        #expect(lock.queuedCount == 0)
    }
}
