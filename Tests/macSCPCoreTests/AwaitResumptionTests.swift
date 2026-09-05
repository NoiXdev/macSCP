import Foundation
import Testing

import MacSCPTestSupport

/// `awaitResumption`/`awaitResumptionThrowing` (`Tests/MacSCPTestSupport/AwaitResumption.swift`)
/// are the fix for `docs/BACKLOG.md`, "A test parked on a bare continuation
/// outlives its time limit": a bare `withCheckedContinuation` ignores `Task`
/// cancellation, so Swift Testing's `.timeLimit` never actually unparks a
/// test stuck on one. These tests pin the three properties that make the
/// replacement safe to use everywhere a bare continuation used to sit —
/// no clock of any kind, per CLAUDE.md "A wall-clock ceiling in a test
/// measures the runner": the only thing that ends a wait here is either the
/// body resuming, or `.timeLimit` cancelling the suite.
@Suite("awaitResumption", .timeLimit(.minutes(1)))
struct AwaitResumptionTests {
    private enum ProbeError: Error, Equatable { case thrown }

    /// A body that never calls its continuation is exactly the shape the
    /// backlog finding measured — `DiagnosticLog.flush()`'s bare
    /// continuation, reverted to reproduce the bug. Cancelling the task
    /// awaiting `awaitResumption` must unpark it with `CancellationError`,
    /// not hang; `started` proves the body actually ran (and so really is
    /// parked, not merely not-yet-scheduled) before the cancel is issued —
    /// without it this test could pass for the wrong reason, cancelling a
    /// task before its body ever got a chance to park.
    @Test func aBodyThatNeverResumesThrowsCancellationErrorWhenTheAwaitingTaskIsCancelled() async throws {
        let started = AsyncSignal()
        let task = Task<Void, any Error> {
            _ = try await awaitResumption { (_: CheckedContinuation<Void, Never>) in
                started.signal()
                // Deliberately never resumes `_`.
            }
        }

        let outcome = await started.wait()
        #expect(outcome == .signalled)

        task.cancel()
        await #expect(throws: CancellationError.self) {
            try await task.value
        }
    }

    /// Positive: a body that does resume delivers its value, the ordinary
    /// path every converted bare-continuation call site exercises.
    @Test func aBodyThatResumesReturnsTheValue() async throws {
        let value = try await awaitResumption { (continuation: CheckedContinuation<Int, Never>) in
            continuation.resume(returning: 42)
        }
        #expect(value == 42)
    }

    /// A continuation resumed once already reached `.done` before any
    /// cancellation is attempted — `awaitResumption`'s internal state
    /// machine (`ResumptionWaitState`) guards exactly this case: a
    /// cancellation arriving after the value is already delivered must find
    /// `.done` and no-op, never call `resume` a second time on the same
    /// continuation. Swift traps the process on a genuine double resume
    /// ("SWIFT TASK CONTINUATION MISUSE"), so reaching the assertions below
    /// at all is itself part of what this test checks.
    @Test func cancellingAfterTheValueAlreadyArrivedIsANoOpNotATrap() async throws {
        let task = Task<Int, any Error> {
            try await awaitResumption { (continuation: CheckedContinuation<Int, Never>) in
                continuation.resume(returning: 7)
            }
        }

        let value = try await task.value
        #expect(value == 7)

        task.cancel()
        #expect(task.isCancelled)
    }

    /// The throwing sibling's ordinary path: a body that resumes with a
    /// value.
    @Test func theThrowingVariantReturnsTheValueOnSuccess() async throws {
        let value = try await awaitResumptionThrowing { (continuation: CheckedContinuation<Int, any Error>) in
            continuation.resume(returning: 9)
        }
        #expect(value == 9)
    }

    /// The throwing sibling's error path: a body that resumes with an error
    /// propagates it to the caller, distinct from `CancellationError`.
    @Test func theThrowingVariantPropagatesAThrownError() async throws {
        await #expect(throws: ProbeError.thrown) {
            try await awaitResumptionThrowing { (continuation: CheckedContinuation<Int, any Error>) in
                continuation.resume(throwing: ProbeError.thrown)
            }
        }
    }

    /// The throwing sibling's cancellation path, mirroring
    /// `aBodyThatNeverResumesThrowsCancellationErrorWhenTheAwaitingTaskIsCancelled`
    /// above.
    @Test func theThrowingVariantThrowsCancellationErrorWhenTheAwaitingTaskIsCancelled() async throws {
        let started = AsyncSignal()
        let task = Task<Void, any Error> {
            _ = try await awaitResumptionThrowing { (_: CheckedContinuation<Void, any Error>) in
                started.signal()
                // Deliberately never resumes `_`.
            }
        }

        let outcome = await started.wait()
        #expect(outcome == .signalled)

        task.cancel()
        await #expect(throws: CancellationError.self) {
            try await task.value
        }
    }

    // MARK: - `onCancel` (fix round 1, docs/BACKLOG.md's own entry)

    /// A `@unchecked Sendable` box for a plain `Int` count, guarded by a
    /// lock — `onCancel` and the test body both touch it from different
    /// tasks.
    private final class LockedCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func increment() { lock.withLock { count += 1 } }
        var value: Int { lock.withLock { count } }
    }

    /// `AgentEnvLock.acquire()` appended its continuation to a `waiters`
    /// list and never removed it on cancellation (docs/BACKLOG.md's fix
    /// round 1): a cancelled waiter's entry stayed behind, and the next
    /// `release()` popped that stale entry and handed the lock to a task
    /// that no longer existed — a permanent leak in a process-wide lock.
    /// `onCancel` exists so a caller with its own bookkeeping can clean it
    /// up exactly when THIS function's cancellation path wins the race.
    /// `started` proves the body actually ran (and so really is parked,
    /// not merely not-yet-scheduled) before the cancel is issued.
    @Test func onCancelRunsWhenCancellationWinsTheRace() async throws {
        let started = AsyncSignal()
        let cleanupCalls = LockedCounter()
        let task = Task<Void, any Error> {
            _ = try await awaitResumption(
                { (_: CheckedContinuation<Void, Never>) in
                    started.signal()
                    // Deliberately never resumes.
                },
                onCancel: { cleanupCalls.increment() }
            )
        }

        let outcome = await started.wait()
        #expect(outcome == .signalled)

        task.cancel()
        await #expect(throws: CancellationError.self) {
            try await task.value
        }
        #expect(cleanupCalls.value == 1)
    }

    /// The positive companion: a body that already resumed must not ALSO
    /// run `onCancel` if the (now-finished) task is cancelled afterward —
    /// `onCancel` runs only on a WINNING cancellation, per its own doc
    /// comment's once-latch. Without this, `onCancelRunsWhenCancellationWinsTheRace`
    /// could pass merely because `onCancel` always runs, cancellation or
    /// not.
    @Test func onCancelDoesNotRunAfterABodyHasAlreadyResumed() async throws {
        let cleanupCalls = LockedCounter()
        let task = Task<Int, any Error> {
            try await awaitResumption(
                { (continuation: CheckedContinuation<Int, Never>) in
                    continuation.resume(returning: 3)
                },
                onCancel: { cleanupCalls.increment() }
            )
        }

        let value = try await task.value
        #expect(value == 3)

        task.cancel()
        #expect(cleanupCalls.value == 0)
    }

    /// Fix round 2 (docs/BACKLOG.md's own entry): round 1's `onCancel` only
    /// fired `cleanup` when a continuation had ALREADY been stored in
    /// `state` — cancel-BEFORE-the-body-registers slipped through it. A
    /// task cancelled before it is even scheduled reaches
    /// `withTaskCancellationHandler` already cancelled, so `onCancel` fires
    /// before the operation closure has stored anything, and `state` was
    /// still `.waiting(nil)` — round 1 read that as "nothing to clean up"
    /// and skipped `cleanup`, while `body` (on its own, uncancelled
    /// `bodyTask`) went on to register later, orphaned.
    ///
    /// `task.cancel()` runs in the SAME synchronous step as the `Task {}`
    /// that creates it — no `AsyncSignal`, no `pollUntil` — so the task
    /// never gets a chance to run before it is marked cancelled, pinning
    /// exactly the scenario the finding named rather than a cancellation
    /// that merely happens to land early.
    @Test func aTaskCancelledBeforeItIsScheduledStillThrowsCancellationError() async throws {
        let cleanupCalls = LockedCounter()
        let task = Task<Void, any Error> {
            _ = try await awaitResumption(
                { (_: CheckedContinuation<Void, Never>) in
                    // Deliberately never resumes. Whether this ever runs
                    // at all depends on which of `body`'s own gate and the
                    // cancellation wins the race inside `awaitResumption`
                    // — both outcomes are correct, and neither changes
                    // `cleanupCalls` below.
                },
                onCancel: { cleanupCalls.increment() }
            )
        }
        task.cancel()

        await #expect(throws: CancellationError.self) {
            try await task.value
        }
        #expect(cleanupCalls.value == 1, """
            onCancel must fire even when cancellation wins before the body             has registered anything — round 1 only fired it when a             continuation had already been stored in `state`.
            """)
    }

    // MARK: - `tryImmediate` (fix round 3)

    /// `AgentEnvLock.acquire()`'s FAST, uncontested path used to commit
    /// `isLocked = true` and resume its OWN continuation as an ordinary
    /// `body`, leaving `state` at `.waiting` until a SEPARATE monitor task
    /// later transitioned it to `.done` — a cancellation landing in that
    /// gap threw `CancellationError` at a caller that had, in fact,
    /// already been handed an irrevocable commitment (docs/BACKLOG.md's
    /// fix round 3). `tryImmediate` closes that gap by committing to
    /// `.done`, and resuming the outer continuation, in the SAME
    /// `state.withLockedValue` step that decides whether the commitment
    /// happens at all — so a cancellation racing against that ONE
    /// synchronous step cannot land inside it, only before or after.
    ///
    /// `body` here would prove the bug if it ever ran: `tryImmediate`
    /// commits on every call in this test, so `body` (the queuing path)
    /// must never be invoked at all.
    @Test func tryImmediateCommitsAtomicallyWithStateSoALateCancelIsIgnored() async throws {
        let started = AsyncSignal()
        let task = Task<Int, any Error> {
            try await awaitResumption(
                { (_: CheckedContinuation<Int, Never>) in
                    Issue.record("body must not run when tryImmediate already committed")
                },
                tryImmediate: {
                    started.signal()
                    return 42
                }
            )
        }

        let outcome = await started.wait()
        #expect(outcome == .signalled)

        // By the time `started` is observed signalled, `tryImmediate` has
        // already returned and `state` has already moved to `.done` and
        // resumed the outer continuation — all inside the same locked
        // step `started.signal()` ran in. This cancel is therefore always
        // racing AFTER that commitment, never during it (there is no
        // "during" to race against from outside this function), so it
        // must be a no-op.
        task.cancel()

        let value = try await task.value
        #expect(value == 42)
    }

    /// The positive companion: `tryImmediate` returning `nil` (no
    /// capacity) falls through to the ordinary queued path, and `body` —
    /// unlike the test above — DOES run. Without this, the negative
    /// above (`body` must not run) could pass merely because `body` is
    /// never called at all, `tryImmediate` present or not.
    @Test func tryImmediateReturningNilFallsThroughToBody() async throws {
        let value = try await awaitResumption(
            { (continuation: CheckedContinuation<Int, Never>) in
                continuation.resume(returning: 7)
            },
            tryImmediate: { nil }
        )
        #expect(value == 7)
    }
}
