import Foundation
import Synchronization
import Testing

@testable import macSCPCore

/// The deadline `BlockingProbe` and `DetachedProbe` put over one diagnostic
/// step, and the one property the maintainer asked of it on 2026-09-24: a
/// hard limit, independent of load.
///
/// Until this file's commit the deadline was
/// `DispatchQueue.global().asyncAfter`, and that queue draws from the
/// kernel's CONSTRAINED workqueue pool — `kern.wq_max_constrained_threads`,
/// 64 on the development machine — whose threads a blocked caller keeps. A
/// deadline that needs a thread from a pool the process has already filled
/// is not a deadline; it is a request. Measured 2026-09-25 on the ten-core
/// development machine, in a standalone binary rather than in this suite: a
/// 0.3 s `asyncAfter` on the global queue, armed after 80 blocks had been
/// parked in `read(2)` on that pool, had not fired 5 s later in 4 of 4 runs
/// — it fired at 5.001–5.011 s, when the parked blocks were released. The
/// same 0.3 s deadline on a thread of the process's own fired at
/// 0.300–0.307 s in those same 4 runs. `docs/BACKLOG.md`'s row "CI
/// starvation: the deadline, bcrypt and audit-append costs left open"
/// records the other half of the same weakness from the cooperative side:
/// ten CPU-bound tasks delayed a 0.3 s global timer to 5.0 s.
///
/// The two suites below are the two halves of the proof. This one holds the
/// timer to its contract on an idle machine — it fires, it can be called
/// off, it does not fire early, and several of them fire in deadline order.
/// `ProbeDeadlineSaturationTests` holds it to the same contract with the
/// pool full, and is gated, because a test that fills the pool ends every
/// other test sharing the process.
@Suite("Probe deadlines", .timeLimit(.minutes(1)))
struct ProbeDeadlineTests {
    /// A scheduled deadline fires; a cancelled one does not.
    ///
    /// The second half is an ORDERING, not a wall-clock ceiling: the
    /// cancelled deadline is due 190 ms BEFORE the one that is awaited, so
    /// by the time the awaited one has fired, a cancel that did nothing
    /// would already have shown. A slow machine delays both and cannot
    /// reorder them.
    @Test func aScheduledDeadlineFiresAndACancelledOneDoesNot() async throws {
        let fired = AsyncSignal()
        let cancelledFired = AsyncSignal()

        let cancelled = DeadlineTimer.shared.schedule(after: .milliseconds(10)) {
            cancelledFired.signal()
        }
        DeadlineTimer.shared.cancel(cancelled)
        let ticket = DeadlineTimer.shared.schedule(after: .milliseconds(200)) { fired.signal() }
        defer { DeadlineTimer.shared.cancel(ticket) }

        #expect(await fired.wait() == .signalled)
        // Read AFTER the later deadline has fired, so this is not a race
        // with a cancel that has not landed yet — it is a statement about a
        // deadline whose own moment is long past.
        #expect(cancelledFired.isRaised == false, "a cancelled deadline fired anyway")
    }

    /// A deadline does not fire EARLY. A floor, which a slow machine cannot
    /// defeat — CLAUDE.md, "A wall-clock ceiling in a test measures the
    /// runner": no ceiling stands beside it.
    @Test func aDeadlineDoesNotFireBeforeItsDuration() async throws {
        let fired = AsyncSignal()
        let start = ContinuousClock.now
        let ticket = DeadlineTimer.shared.schedule(after: .milliseconds(200)) { fired.signal() }
        defer { DeadlineTimer.shared.cancel(ticket) }

        #expect(await fired.wait() == .signalled)
        let elapsed = start.duration(to: ContinuousClock.now)
        #expect(elapsed >= .milliseconds(200), "a 200 ms deadline fired after \(elapsed)")
    }

    /// Several deadlines at once fire in deadline order, not in the order
    /// they were scheduled — the timer holds a set, not a single entry, and
    /// the later-scheduled earlier deadline must not wait behind the one
    /// already pending.
    ///
    /// The order is recorded BY THE BODIES, on the timing thread, and read
    /// only once both have run. A first version read `late.isRaised` in the
    /// test's own task right after awaiting `early`, and that is not the
    /// ordering it claimed to be: it is the ordering plus however long the
    /// cooperative pool took to resume this test. It went red in the full
    /// suite on 2026-09-25 — `lateHadFired == false` failed after 9.612 s,
    /// with both deadlines long past and nothing wrong with the timer. Which
    /// is the shape CLAUDE.md's "A wall-clock ceiling in a test measures the
    /// runner" names, worn as an ordering: a comparison whose second half is
    /// read at a moment the runner chooses.
    @Test func severalDeadlinesFireInDeadlineOrder() async throws {
        let fired = Mutex<[String]>([])
        let early = AsyncSignal()
        let late = AsyncSignal()

        let lateTicket = DeadlineTimer.shared.schedule(after: .milliseconds(300)) {
            fired.withLock { $0.append("late") }
            late.signal()
        }
        let earlyTicket = DeadlineTimer.shared.schedule(after: .milliseconds(20)) {
            fired.withLock { $0.append("early") }
            early.signal()
        }
        defer {
            DeadlineTimer.shared.cancel(lateTicket)
            DeadlineTimer.shared.cancel(earlyTicket)
        }

        #expect(await early.wait() == .signalled)
        #expect(await late.wait() == .signalled)
        #expect(fired.withLock { $0 } == ["early", "late"])
    }
}

/// The same deadline, with the Dispatch global queue's pool full.
///
/// GATED behind `MACSCP_SATURATION=1` and skipped by default, following
/// `SubprocessRunnerTests.readersDoNotNeedAFreeGlobalQueueThread` — the one
/// test in this tree that already fills that pool, whose own doc records why
/// such a test cannot share a run (CI run 33705649537: while it held the
/// queue, two unrelated tests went red around it). The suite is
/// `.serialized` so its two cases cannot fill the pool against each other;
/// run the gate one case at a time, with `--filter`.
///
/// **The harness is not shared with that test, and the reason is that this
/// one needs less.** There, the FREE width of the pool is the measurement,
/// so it parks one block at a time and reads a bound to find the first that
/// cannot start. Here nothing is timed: the blocks are parked, the canary is
/// submitted BEHIND them, and the global queue serves in FIFO order within a
/// QoS band — so a canary submitted after more blocks than the pool's width,
/// every one of which parks for ever, cannot have started. The count comes
/// from the same sysctl for the same reason (the width is the kernel's
/// property, not this code's), and the pipes-and-`read(2)` shape is the same
/// because closing a write end releases a parked block deterministically, on
/// every exit path, including a failed `#expect`.
///
/// **What each case proves, and how it avoids a clock.** The probe's
/// deadline must be observed while the global queue still cannot run
/// anything — that is an ordering between two events, not a duration:
///
/// 1. the probe returns `nil`, which only its deadline can produce here,
///    because the work parks until this test releases it; and
/// 2. at that moment the canary submitted to `DispatchQueue.global()` has
///    NOT started.
///
/// Both are read before anything is released (CLAUDE.md, "Tests that watch a
/// defect heal"), and the positive anchor comes after: once released, the
/// canary is required to start and the work to finish, so a canary that
/// simply never worked cannot masquerade as saturation.
///
/// With the deadline on `DispatchQueue.global()`, case 1 cannot be reached
/// at all — the probe never returns while the pool is parked, and the suite's
/// time limit is what ends the test. Measured 2026-09-25, both cases red
/// that way before the timer was written.
@Suite("Probe deadlines under a saturated Dispatch pool", .serialized, .timeLimit(.minutes(1)))
struct ProbeDeadlineSaturationTests {
    private static let gate = ProcessInfo.processInfo.environment["MACSCP_SATURATION"] == "1"
    private static let gateReason: Comment =
        "fills the Dispatch global queue for every test running beside it; run alone with MACSCP_SATURATION=1"

    /// The step deadline these cases give the probes. Short, because nothing
    /// here waits for it to pass on a clock — the test waits for the probe
    /// to return, however late that is.
    private static let stepTimeout = Duration.milliseconds(200)

    @Test(.enabled(if: gate, gateReason))
    func aBlockingProbeDeadlineLandsWhileTheGlobalQueueHasNoThreadToGive() async throws {
        let parked = try ParkedGlobalQueue.park()
        defer { parked.release() }

        let canaryStarted = AsyncSignal()
        DispatchQueue.global().async { canaryStarted.signal() }

        // The work parks until this test releases it and can therefore never
        // finish on its own while the deadline races it — the defect
        // `938609d8` fixed in `ConnectionDiagnosticsTests`, where a fake that
        // slept and then succeeded outran the very deadline under test.
        let work = Pipe()
        let workEnded = AsyncSignal()
        defer { try? work.fileHandleForWriting.close() }
        let workInput = work.fileHandleForReading

        let outcome = await BlockingProbe.run(
            label: "macSCP.tests.probe-deadline-saturation", timeout: Self.stepTimeout
        ) { () -> String in
            _ = workInput.availableData
            workEnded.signal()
            return "the work's own answer"
        }

        let canaryHadStarted = canaryStarted.isRaised
        let workHadEnded = workEnded.isRaised
        #expect(outcome == nil, "the probe returned the work's answer, so the deadline did not settle it")
        #expect(
            canaryHadStarted == false,
            "the global queue had a thread to give, so this run did not measure a saturated pool")
        #expect(workHadEnded == false, "the work finished on its own, so nothing here raced the deadline")

        try? work.fileHandleForWriting.close()
        parked.release()
        #expect(await workEnded.wait() == .signalled)
        #expect(await canaryStarted.wait() == .signalled, "the canary never started even once released")
        let returned = await parked.returned()
        #expect(returned == parked.count, "\(parked.count - returned) parked blocks never returned")
    }

    @Test(.enabled(if: gate, gateReason))
    func aDetachedProbeDeadlineLandsWhileTheGlobalQueueHasNoThreadToGive() async throws {
        let parked = try ParkedGlobalQueue.park()
        defer { parked.release() }

        let canaryStarted = AsyncSignal()
        DispatchQueue.global().async { canaryStarted.signal() }

        // Parks until cancelled, and `DetachedProbe` cancels an abandoned
        // probe only AFTER it has stopped waiting for it — so this body
        // cannot return before the deadline has settled the call.
        let workEnded = AsyncSignal()
        let outcome = await DetachedProbe.run(timeout: Self.stepTimeout) { () -> String in
            await suspendUntilCancelled()
            workEnded.signal()
            return "the work's own answer"
        }

        let canaryHadStarted = canaryStarted.isRaised
        let workHadEnded = workEnded.isRaised
        #expect(outcome == nil, "the probe returned the work's answer, so the deadline did not settle it")
        #expect(
            canaryHadStarted == false,
            "the global queue had a thread to give, so this run did not measure a saturated pool")
        #expect(workHadEnded == false, "the work finished on its own, so nothing here raced the deadline")

        parked.release()
        #expect(await canaryStarted.wait() == .signalled, "the canary never started even once released")
        let returned = await parked.returned()
        #expect(returned == parked.count, "\(parked.count - returned) parked blocks never returned")
    }
}

/// Blocks parked in `read(2)` on the Dispatch global queue, enough of them
/// that the queue has no thread left for anything submitted behind them.
///
/// The count is READ from the kernel — `kern.wq_max_constrained_threads` is
/// the limit on the constrained workqueue threads the global queues draw
/// from, and it is a property of the machine, not of this code — plus a
/// margin that sits queued behind the full pool. The cap is the one
/// `SubprocessRunnerTests` measured its own parking against: a `Pipe()` past
/// the descriptor limit hands back handles over invalid descriptors, and the
/// first read on one raises an ObjC exception that takes the test process
/// down with no name on it.
private struct ParkedGlobalQueue {
    private let writeEnds: [FileHandle]
    private let finished: [AsyncSignal]

    var count: Int { finished.count }

    static func park() throws -> ParkedGlobalQueue {
        let limit = try #require(
            constrainedWorkqueueThreadLimit(),
            "kern.wq_max_constrained_threads is not readable here; this test cannot know the pool's width")
        try #require(limit > 0, "the kernel reports a constrained-thread limit of \(limit)")
        let margin = 16
        let cap = 128

        var writeEnds: [FileHandle] = []
        var finished: [AsyncSignal] = []
        for _ in 0..<min(limit + margin, cap) {
            let pipe = Pipe()
            writeEnds.append(pipe.fileHandleForWriting)
            let readEnd = pipe.fileHandleForReading
            let done = AsyncSignal()
            finished.append(done)
            DispatchQueue.global().async {
                _ = readEnd.availableData
                done.signal()
            }
        }
        return ParkedGlobalQueue(writeEnds: writeEnds, finished: finished)
    }

    /// Releases every parked block. Idempotent: a second close throws and is
    /// swallowed, so a case can release before its positive anchors and
    /// still carry a `defer` for the paths that never reach them.
    func release() {
        for handle in writeEnds { try? handle.close() }
    }

    /// How many parked blocks returned. Unbounded — a block that never
    /// returns ends the test through the suite's own time limit, never
    /// through a clock read here.
    func returned() async -> Int {
        var returned = 0
        for done in finished where await done.wait() == .signalled { returned += 1 }
        return returned
    }

    /// `kern.wq_max_constrained_threads`: the kernel's per-process limit on
    /// constrained workqueue threads, which is the width of the pool behind
    /// the non-overcommit global queues. `nil` if the sysctl is not there.
    private static func constrainedWorkqueueThreadLimit() -> Int? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.wq_max_constrained_threads", &value, &size, nil, 0) == 0,
            size == MemoryLayout<Int32>.size
        else { return nil }
        return Int(value)
    }
}

/// Parks until the calling task is cancelled, and never on its own — the
/// same helper `ConnectionDiagnosticsTests` and `HostAddressLookupTests`
/// each keep privately, for the same reason: a fake that finishes by itself
/// can outrun the deadline it is supposed to be raced against.
private func suspendUntilCancelled() async {
    let (never, producer) = AsyncStream<Never>.makeStream()
    for await _ in never {}
    producer.finish()
}
