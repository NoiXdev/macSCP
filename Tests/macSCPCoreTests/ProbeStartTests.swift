import Foundation
import Testing

@testable import macSCPCore

/// The third thing a bounded probe can report: that its body never began.
///
/// `DetachedProbe` arms its deadline when the probe is CREATED, so on a
/// loaded machine the deadline can expire over work the cooperative pool
/// never started — measured 2026-09-27 at 9.483 / 9.490 / 9.494 s, 3 of 3
/// (`ProbeStart`'s own doc comment carries the harness and the control).
/// Until that day such a row read `timedOut`, which is a sentence about the
/// far end, for a server this Mac had not contacted.
///
/// **No wall-clock ceiling anywhere below, and no starved pool either.** The
/// 2026-09-25 investigation reproduced the problem by running 200 CPU-bound
/// tasks beside the case under test, which ends every other test sharing the
/// process — `ProbeDeadlineSaturationTests` is gated for exactly that reason,
/// and that hog suite was deleted. `DetachedProbe.Launch` states the same
/// fact with no load at all: a launcher that HOLDS the body is a body that
/// has not begun, whatever the machine is doing. What the cases assert is an
/// outcome and an ordering; the one duration any of them reads is a FLOOR,
/// which a slow machine cannot defeat.
@Suite("A probe that never began", .timeLimit(.minutes(1)))
struct ProbeStartTests {
    /// Short, because nothing here waits for it on a clock: each case waits
    /// for the probe to return, however late that is.
    private static let deadline = Duration.milliseconds(200)

    /// The whole point: a body the pool never started reads `neverBegan`,
    /// where until 2026-09-27 it was indistinguishable from a body that ran
    /// and overran.
    ///
    /// That the deadline still ENDS the call is what returning at all
    /// proves. The hold is never opened before the answer is read, so
    /// nothing but the deadline could have settled it.
    @Test func aBodyTheLauncherNeverStartedReadsNeverBegan() async throws {
        let hold = HeldLaunch()
        defer { hold.open() }
        let bodyBegan = AsyncSignal()

        let start = ContinuousClock.now
        let answer = await DetachedProbe.run(timeout: Self.deadline, launch: hold.launch) {
            bodyBegan.signal()
            return "the body's own answer"
        }
        // Both read BEFORE the hold is opened (CLAUDE.md, "Tests that watch
        // a defect heal"): opening it runs the body, which raises the signal
        // and would satisfy the second check by healing what it measures.
        let hadBegun = bodyBegan.isRaised
        let elapsed = start.duration(to: ContinuousClock.now)

        #expect(
            answer == .unanswered(.neverBegan),
            "a body that never began answered \(answer) — `began` here is the row that accuses a server")
        #expect(hadBegun == false, "the hold let the body run, so this case measured nothing")
        // A FLOOR. A slow machine can only make the deadline later.
        #expect(
            elapsed >= Self.deadline,
            "the call came back after \(elapsed), before its own \(Self.deadline) deadline")

        // The positive beside the two negatives (CLAUDE.md, "Guards that
        // name what they watch"): the hold really does hold a body that
        // would otherwise run, rather than a launcher that launched nothing.
        hold.open()
        #expect(await bodyBegan.wait() == .signalled, "the held body never ran, even once released")
    }

    /// A body that HAD begun reads `began`, so the row one layer up stays
    /// `timedOut` — the outcome this change must not take away from the
    /// steps that earned it.
    ///
    /// Settled by a CANCELLATION rather than by the deadline, and
    /// deliberately: both read the same flag at the same moment, and the
    /// cancellation is the half a test can order. Making the DEADLINE win
    /// over a body that has provably begun would mean betting that the pool
    /// starts the body inside the bound — the bet the 2026-09-25 CI reds
    /// lost. The deadline half is held by
    /// `ProbeDeadlineSaturationTests.aDetachedProbeDeadlineLandsWhileTheGlobalQueueHasNoThreadToGive`,
    /// whose body reaches `suspendUntilCancelled` before the deadline
    /// because the pool it parks is the Dispatch one, not the cooperative
    /// one.
    @Test func aBodyThatHadBegunReadsBegan() async throws {
        let began = AsyncSignal()
        let probe = Task {
            // Long enough that the deadline plays no part: the cancellation
            // below is what settles this call, and the suite's own time
            // limit is what ends the case if nothing does.
            await DetachedProbe.run(timeout: .seconds(600)) { () -> String in
                began.signal()
                await Self.suspendUntilCancelled()
                return "the body's own answer"
            }
        }

        #expect(await began.wait() == .signalled)
        probe.cancel()
        let answer = await probe.value
        #expect(
            answer == .unanswered(.began),
            "a body that had begun answered \(answer)")
    }

    /// The ordinary answer, and the positive anchor the two cases above
    /// need: a probe that finishes inside its deadline is `answered`, so
    /// neither unanswered case can be satisfied by a type that never
    /// answers at all.
    @Test func aBodyThatFinishesInsideItsDeadlineIsAnswered() async throws {
        let answer = await DetachedProbe.run(timeout: .seconds(600)) { "the body's own answer" }
        #expect(answer == .answered("the body's own answer"))
    }

    /// Which outcome each side of the start becomes — the one mapping the
    /// three racing call sites read — asserted as the pure function it is:
    /// no clock, no pool, no walk.
    ///
    /// The catalogue key beside it, because a reason with no key renders as
    /// the English Core measured in all four languages with nothing red
    /// (`DiagnosticReason`'s own doc comment).
    @Test func eachSideOfTheStartNamesTheOutcomeItReports() {
        #expect(ConnectionDiagnostics.outcome(forUnanswered: .began) == .timedOut)
        #expect(
            ConnectionDiagnostics.outcome(forUnanswered: .neverBegan)
                == .notStarted(DiagnosticReason.probeNotStarted))
        #expect(DiagnosticReason.key(for: DiagnosticReason.probeNotStarted) != nil)
    }

    /// Parks until the calling task is cancelled, and never on its own — the
    /// helper `ConnectionDiagnosticsTests`, `HostAddressLookupTests` and
    /// `ProbeDeadlineTests` each keep, for the reason CLAUDE.md records: a
    /// fake that finishes by itself can outrun the deadline it is supposed
    /// to be raced against.
    private static func suspendUntilCancelled() async {
        let (never, producer) = AsyncStream<Never>.makeStream()
        for await _ in never {}
        producer.finish()
    }
}

/// A `DetachedProbe.Launch` that KEEPS the probe's body instead of starting
/// it, until `open()` says so.
///
/// Not private: `ConnectionDiagnosticsJumpTests` holds a target-half step's
/// probe with the same launcher, where the fakes a step's context needs
/// live.
///
/// **It holds the body by not launching it at all**, rather than by parking
/// a launched one. Two reasons, and the second is the one that matters.
/// A parked launch would have to be parked on something a CANCELLATION does
/// not release — `DetachedProbe` cancels the launch it abandons, in the same
/// `defer` that calls the deadline off — and the only such thing is a bare
/// continuation, which this tree forbids for its own good reasons
/// (`PollingGuardTests.noBareContinuationEscapesAwaitResumption`). And a
/// launch released by that cancellation would run the body the instant the
/// call returned, racing the snapshot the case above takes. Nothing is
/// launched here, so the cancellation reaches nothing, and the body is where
/// a body the cooperative pool never started is: waiting to be given a
/// thread.
final class HeldLaunch: @unchecked Sendable {
    private let lock = NSLock()
    private var held: (@Sendable () async -> Void)?
    private var isOpen = false

    var launch: DetachedProbe.Launch {
        { [self] body in
            keep(body)
            // A handle over nothing. `DetachedProbe` cancels what it
            // abandoned; there is deliberately nothing here for that
            // cancellation to reach.
            return Task.detached {}
        }
    }

    private func keep(_ body: @escaping @Sendable () async -> Void) {
        lock.lock()
        guard !isOpen else {
            lock.unlock()
            Task.detached { await body() }
            return
        }
        held = body
        lock.unlock()
    }

    /// Starts the body that was held, if one was. Idempotent, so a case can
    /// open it for its positive anchor and still carry a `defer` for the
    /// paths that never reach one.
    func open() {
        lock.lock()
        let body = held
        held = nil
        isOpen = true
        lock.unlock()
        if let body { Task.detached { await body() } }
    }
}

extension DiagnosticOutcome {
    /// Whether this is an outcome a step's own DEADLINE produced — either of
    /// the two, and asking for either is the point.
    ///
    /// `timedOut` when the probe ran and overran, `notStarted` when this Mac
    /// never gave it a thread. A fixture that drives a whole walk against a
    /// deliberately short budget cannot say which it will get: the second is
    /// a fact about the runner, and the three-core CI machine produces it
    /// (`ProbeStart`). So a case whose property is "the deadline settled
    /// this row, and the probe's own answer was not taken" asks for this,
    /// and the cases that CAN say which ask for one by name — the suite
    /// above, and `ConnectionDiagnostics.outcome(forUnanswered:)` under it.
    ///
    /// Exhaustive rather than two comparisons, so a seventh outcome has to
    /// be classified here instead of quietly falling out of the set.
    var settledByItsDeadline: Bool {
        switch self {
        case .timedOut, .notStarted: return true
        case .ok, .failed, .unavailable, .skipped: return false
        }
    }
}
