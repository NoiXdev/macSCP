import Foundation
import Testing

@testable import macSCPCore

/// The mechanism `CitadelFileSystem.disconnect()` leans on, exercised
/// without Docker. `LivenessProbeRaceTests` makes the same two claims about
/// the App-layer twin `BoundedClose` is modelled on, and it exists for the
/// same reason: the case that matters is an operation that never returns at
/// all, which nothing built out of `Task.sleep` can stand in for. The
/// gated `LivenessProbeDropIntegrationTests
/// .teardownAgainstAStillFrozenPeerTerminates` is what shows the fake was
/// modelling something — a real Citadel `sftp.close()` against a frozen
/// container — and it needs a Docker rig, so these two run everywhere and
/// that one runs on request.
@Suite("BoundedClose")
struct BoundedCloseTests {
    /// Suspends forever, exactly as `LivenessProbeRaceTests
    /// .NeverRespondingFileSystem.stat` does and for the same reason. The
    /// runtime's "leaked its continuation" note on stdout is the expected
    /// consequence of the race abandoning it, not a failure; that suite has
    /// printed the same line for as long as it has existed.
    private func neverReturns() async {
        await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in
            // Deliberately never resumed.
        }
    }

    /// The claim the fix rests on: an operation with no end of its own does
    /// not become the caller's problem.
    ///
    /// The upper bound is the harness's `.timeLimit`, not a wall-clock
    /// `#expect`, for the reason `LivenessProbeRaceTests` writes out at
    /// length: elapsed time under a parallel suite measures scheduler
    /// contention as much as it measures this race, and a number large
    /// enough to be safe is too large to mean anything. "This must not
    /// hang" is the actual claim.
    @Test(.timeLimit(.minutes(1)))
    func anOperationThatNeverReturnsIsAbandonedAtTheBound() async {
        let startedAt = ContinuousClock.now
        let finished = await BoundedClose.run(boundSeconds: 1) { await self.neverReturns() }
        let elapsed = startedAt.duration(to: .now)
        #expect(finished == false)
        // Lower bound: an implementation that answered `false` on the spot,
        // without ever waiting out `boundSeconds`, would satisfy the line
        // above just as well. Contention cannot make this fire falsely — it
        // only ever pushes elapsed time up. The small margin under a full
        // second tolerates the sleep landing a hair early.
        #expect(elapsed >= .milliseconds(900))
    }

    /// The other half, and the one that keeps the normal teardown path
    /// honest: an operation that finishes returns at ITS OWN speed. Without
    /// this, a `run` that simply always waited out `boundSeconds` would pass
    /// the test above — and would add five seconds to every ordinary
    /// disconnect.
    @Test func anOperationThatFinishesInsideTheBoundIsNotAbandoned() async {
        let startedAt = ContinuousClock.now
        let finished = await BoundedClose.run(boundSeconds: 30) {}
        let elapsed = startedAt.duration(to: .now)
        #expect(finished == true)
        // Far below the 30-second bound and far above anything contention
        // plausibly adds to an operation that does nothing: this
        // distinguishes "returned when the operation did" from "returned
        // when the bound elapsed", which is the whole distinction, without
        // pinning a scheduler.
        #expect(elapsed < .seconds(15))
    }
}
