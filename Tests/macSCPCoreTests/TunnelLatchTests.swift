import Foundation
import MacSCPTestSupport
import Testing

@testable import macSCPCore

/// The gate `TunnelRunnerTests` and `CLITunnelForegroundRunTests` hold a
/// teardown open with, measured on its own.
///
/// Both properties are the same one seen from two sides, and both matter
/// because the ONLY path this latch is ever waited on from is a cancelled
/// one (`TunnelRunner.performStop` cancels the run task, and the fake
/// runtime's `stop()` runs inside it): the wait must not end when the task
/// is cancelled, and it must end when — and only when — someone releases
/// it. The suite that used to prove this by accident is still there; this
/// is the direct measurement, so a future change to `TunnelLatch` is red
/// here rather than red as a puzzling ordering failure two files away.
///
/// `.timeLimit(.minutes(1))` per `PollingGuardTests
/// .everyCallerOfPollUntilDeclaresATimeLimit` — and, honestly, it would
/// not save this suite if the latch regressed: a wait that ignores
/// cancellation ignores the time limit's cancellation too. Every case
/// releases its latch on the way out.
@Suite("Tunnel latch", .timeLimit(.minutes(1)))
struct TunnelLatchTests {
    /// A wait entered from an ALREADY-CANCELLED task stays parked, and the
    /// release is what ends it — not the cancellation.
    ///
    /// The cancellation is not raced. The task first parks on an
    /// `AsyncSignal` nobody signals, which DOES answer cancellation, and
    /// records that it came back `.cancelled`; only then does it enter
    /// `latch.wait()`. So by the time `cancelObserved` is 1 the
    /// cancellation is delivered and processed, and a `wait()` that
    /// answered it would already have returned — `AsyncSignal.wait()`
    /// answers an already-cancelled task synchronously, before any
    /// suspension. Measured against exactly that mutation (the detached
    /// task removed, so the wait answers cancellation): red in 10 of 10
    /// runs, where an earlier version of this case that polled only on
    /// "the wait was entered" was red in 3 of 5 (CLAUDE.md, "A guard's
    /// sensitivity is a number").
    ///
    /// The postcondition is read BEFORE the release (CLAUDE.md, "Tests
    /// that watch a defect heal"): once the latch is open, a wait that
    /// returned for the wrong reason and one that returned for the right
    /// reason look the same.
    @Test func aWaitInsideACancelledTaskEndsOnTheReleaseAndNotOnTheCancellation() async throws {
        let latch = TunnelLatch()
        defer { latch.release() }
        let cancelObserved = TunnelCallCounter()
        let returned = TunnelCallCounter()
        let entered = TunnelCallCounter()

        let waiting = Task {
            let park = AsyncSignal()
            entered.record()
            let outcome = await park.wait()
            #expect(outcome == .cancelled)
            cancelObserved.record()
            await latch.wait()
            returned.record()
        }
        try await pollUntil("the task to park") { entered.count == 1 }
        waiting.cancel()
        try await pollUntil("the task to observe its cancellation") { cancelObserved.count == 1 }

        #expect(waiting.isCancelled)
        #expect(returned.count == 0, "the wait returned on cancellation")

        latch.release()
        await waiting.value
        #expect(returned.count == 1)
    }

    /// A release that lands BEFORE anyone waits still satisfies the wait:
    /// the latch is a level, not an edge. `TunnelFakeRuntimes` gives the
    /// same latch to a runtime whose `stop()` may be entered at any point
    /// after the test opened it.
    @Test func aReleaseBeforeTheWaitIsAlreadyOpen() async {
        let latch = TunnelLatch()
        #expect(latch.isOpen == false)
        latch.release()
        #expect(latch.isOpen)
        await latch.wait()
    }
}
