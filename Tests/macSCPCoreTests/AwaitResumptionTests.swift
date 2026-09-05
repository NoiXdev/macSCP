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
}
