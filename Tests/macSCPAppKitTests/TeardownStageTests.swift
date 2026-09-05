import Foundation
import Testing

@testable import MacSCPAppKit

/// What `ContentView.teardown(_:reason:)` leans on, exercised without
/// Docker. `BoundedCloseTests` already pins the race itself; these are the
/// claims that belong to the App-layer wrapper around it — that a stage
/// which does not come back is abandoned, that abandoning one stage does
/// not cost the next one its turn, and that every stage carries a bound and
/// a name.
///
/// Only the two stages this type still covers appear below. Teardown's
/// first stage, `transferQueue.cancelAll(reason:)`, is not one of them any
/// more — it is called directly and unbounded, for the reason
/// `ContentView.teardown(_:reason:)` records; what pins THAT is
/// `LivenessGiveUpOrderingTests`, behaviorally, not this file.
///
/// What these cannot show, and what only the gated
/// `LivenessProbeDropIntegrationTests
/// .teardownWithAnOpenShellAgainstAStillFrozenPeerTerminates` shows, is that
/// `teardown` actually routes its stages through this type against a real
/// frozen peer. A revert to bare `await session.terminal.shutdown()` would
/// leave everything below green.
@Suite("Teardown stage bounds")
struct TeardownStageTests {
    /// Suspends forever — `BoundedCloseTests.neverReturns`' shape, for its
    /// reason: an operation with no end of its own is the only thing a
    /// bound is for, and nothing built out of `Task.sleep` stands in for it.
    /// The runtime's "leaked its continuation" note on stdout is the
    /// expected consequence of the abandonment, not a failure.
    ///
    /// For the same reason as `BoundedCloseTests.neverReturns`, the continuation IS the API under test here.
    /// A teardown stage must finish inside its bound by RACING this call,
    /// not by cancelling it, so this stays a genuinely bare, never-resumed
    /// `withCheckedContinuation`.
    private func neverReturns() async {
        await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in
            // Deliberately never resumed.
        }
    }

    /// Somewhere for an abandoned stage's successor to say it ran.
    /// `@unchecked Sendable` because `lock` is what serializes the single
    /// write and the single read.
    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var raised = false
        var isRaised: Bool { lock.withLock { raised } }
        func raise() { lock.withLock { raised = true } }
    }

    @Test(.timeLimit(.minutes(1)))
    func aStageThatNeverReturnsIsAbandoned() async {
        // `boundSeconds: 0` rather than the stage's own five: this asserts
        // the abandonment BRANCH, and spending the real bound to reach it
        // would put five seconds into the ungated suite for nothing. The
        // production value is asserted separately, below.
        let finished = await TeardownStage.shutDownTerminal
            .runBounded(boundSeconds: 0) { await self.neverReturns() }
        #expect(finished == false)
    }

    /// The other half: a stage that returns is not abandoned, and does not
    /// wait out its bound to say so. Without this, a `runBounded` that
    /// always slept through `boundSeconds` would satisfy the test above and
    /// would add five seconds to every ordinary disconnect.
    ///
    /// The bound is an hour and the limit a minute, and the gap between them
    /// IS the assertion. This used to compare elapsed wall-clock time
    /// against four seconds, which cannot tell "slept through the bound"
    /// from "the machine was busy": on a loaded CI runner an empty operation
    /// measured 6.58 s and 7.56 s and turned the suite red twice — while
    /// `finished` was `true` both times, so the bound had demonstrably not
    /// fired and the test failed anyway. An implementation that waits out
    /// its bound now needs an hour and cannot reach the limit; one that
    /// returns with its operation finishes at once. No contention closes a
    /// gap that wide.
    ///
    /// A bound forwarded as zero is caught by `finished` itself rather than
    /// by a clock: the bound would win the race and this would be `false`.
    @Test(.timeLimit(.minutes(1)))
    func aStageThatReturnsIsNotAbandonedAndDoesNotWaitOutItsBound() async {
        let finished = await TeardownStage.stopEditWatchers
            .runBounded(boundSeconds: 3600) {}
        #expect(finished == true)
    }

    /// The property the whole per-stage design exists for, and the one a
    /// single bound around all of `teardown` would not have: giving up on
    /// one stage costs that stage only. Teardown runs to its end.
    @Test(.timeLimit(.minutes(1)))
    func abandoningOneStageStillLetsTheNextOneRun() async {
        let ran = Flag()
        let abandoned = await TeardownStage.stopEditWatchers
            .runBounded(boundSeconds: 0) { await self.neverReturns() }
        let followed = await TeardownStage.shutDownTerminal.runBounded { ran.raise() }
        #expect(abandoned == false)
        #expect(followed == true)
        #expect(ran.isRaised)
    }

    /// Every stage bounds itself with a real number of seconds and names a
    /// distinct call. The names are what the abandonment log line carries —
    /// two stages sharing one would make the line unable to say which one
    /// gave up, which is the entire reason the log line exists.
    @Test func everyStageHasAPositiveBoundAndItsOwnName() {
        for stage in TeardownStage.allCases {
            #expect(stage.boundSeconds > 0)
            #expect(!stage.callSite.isEmpty)
        }
        let names = Set(TeardownStage.allCases.map(\.callSite))
        #expect(names.count == TeardownStage.allCases.count)
    }
}
