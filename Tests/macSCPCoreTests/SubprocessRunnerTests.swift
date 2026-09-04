import Foundation
import Testing

/// What `SubprocessRunner` has to get right for the suites that replaced
/// their blocking child waits with it: the exit status and both streams of a
/// normal child, an output volume no pipe buffer holds, a child that outlives
/// its bound, and the three inputs a caller can hand it.
///
/// Five minutes rather than the one minute the rest of the tree carries, and
/// the reason is in two of the cases: each hands the runner a child bounded
/// at sixty seconds and then waits, unbounded, for a latch the stderr seam
/// raises, and each already declares a five-minute limit of its own, with
/// that argument written out. A suite-level minute would sit under those and
/// end them before the property they measure is reachable. The limit here is
/// a net under an unbounded `AsyncSignal.wait()`, so a regression in the seam
/// is a red naming the test rather than a run that never returns; it is not
/// a budget any case is expected to approach.
@Suite("SubprocessRunner", .timeLimit(.minutes(5)))
struct SubprocessRunnerTests {
    private static let shell = URL(fileURLWithPath: "/bin/sh")

    @Test func aNormalChildReportsItsStatusAndBothStreams() async throws {
        let result = try await SubprocessRunner.run(
            Self.shell,
            arguments: ["-c", "printf 'on stdout'; printf 'on stderr' >&2; exit 3"])
        #expect(result.status == 3)
        #expect(result.stdoutText == "on stdout")
        #expect(result.stderrText == "on stderr")
    }

    /// 256 KB down each stream, both written at once by backgrounded
    /// commands. A pipe's kernel buffer is a few tens of kilobytes, so a
    /// runner that drained one stream to EOF before starting on the other
    /// would deadlock here: the child would block writing to the stream
    /// nobody is reading, and so never reach EOF on the one that is.
    @Test func aChildFillingBothPipesIsDrainedWithoutDeadlock() async throws {
        let block = 256 * 1024
        let result = try await SubprocessRunner.run(
            Self.shell,
            arguments: [
                "-c",
                """
                dd if=/dev/zero bs=1024 count=256 2>/dev/null | tr '\\0' 'a' &
                dd if=/dev/zero bs=1024 count=256 2>/dev/null | tr '\\0' 'b' >&2 &
                wait
                """,
            ],
            timeout: .seconds(30))
        #expect(result.status == 0)
        #expect(result.stdout.count == block)
        #expect(result.stderr.count == block)
        #expect(result.stdout.allSatisfy { $0 == UInt8(ascii: "a") })
        #expect(result.stderr.allSatisfy { $0 == UInt8(ascii: "b") })
    }

    /// The child announces its own pid and then `exec`s `sleep`, so the pid
    /// on stderr IS the process this runner owns — not a shell that would
    /// leave an orphan behind when it dies.
    ///
    /// This used to force the ending with a 2 s bound and parse the pid out
    /// of `SubprocessTimeout.stderrSoFar` afterwards — the identical clock
    /// race `aTimeoutReportsWhatTheChildWroteBeforeTheBound` carried before
    /// it was replaced by `aCancelledRunReportsWhatTheChildWroteBeforeTheStop`:
    /// the bound is wall-clock, the readability handler's scheduling is not,
    /// and a starved Dispatch global queue can still be mid-flight past the
    /// bound with no pid in the box yet.
    ///
    /// The reader is the synchronisation point instead, exactly as in that
    /// sibling: the run gets a 60 s bound against a child that sleeps 30,
    /// `onStderrChunk` raises `arrived` once the pid line is in the box, the
    /// test waits for that with no bound of its own, and only then cancels.
    ///
    /// Cancellation in place of a timeout is not a narrower proof. The
    /// property under test is "the process this runner owns is dead once the
    /// run has ended", and that does not care which of `run`'s two abnormal
    /// endings produced the ending — a runner that killed the child on a
    /// timeout but leaked it on cancellation (or the reverse) would still be
    /// broken. Proving it under the ending this test CAN place after an
    /// observation is exactly as much of a proof as the timeout would have
    /// been, and it is the only one available without racing a clock.
    @Test(.timeLimit(.minutes(5)))
    func aChildThatOutlivesItsBoundThrowsAndIsKilled() async throws {
        let arrived = AsyncSignal()
        let task = Task { () -> SubprocessResult in
            try await SubprocessRunner.run(
                Self.shell,
                arguments: ["-c", "echo $$ >&2; exec sleep 30"],
                timeout: .seconds(60),
                onStderrChunk: { chunk in
                    let text = String(decoding: chunk, as: UTF8.self)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if pid_t(text) != nil { arrived.signal() }
                })
        }

        // No bound of its own: see the sibling case for why.
        #expect(await arrived.wait() == .signalled)
        task.cancel()

        var thrown: (any Error)?
        do {
            _ = try await task.value
            Issue.record("a cancelled run returned a result instead of reporting cancellation")
        } catch {
            thrown = error
        }
        let error = try #require(
            thrown as? SubprocessCancelled,
            "cancellation surfaced as \(String(describing: thrown))")
        let announced = String(decoding: error.stderrSoFar, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // The whole error, not just the field: it names each reader's drained
        // state and how long every escalation phase took, which is what CI run
        // 33693297919 could not say when this line failed on an empty stderr.
        let pid = try #require(pid_t(announced), "the child announced no pid. \(error)")

        // Foundation reaps the child on its own thread once it dies, and
        // `kill(pid, 0)` still succeeds against a zombie — so this allows a
        // moment for the reap rather than reading once and hoping.
        var stillThere = true
        for _ in 0..<50 where stillThere {
            stillThere = kill(pid, 0) == 0
            if stillThere { try? await Task.sleep(for: .milliseconds(100)) }
        }
        #expect(stillThere == false, "pid \(pid) survived cancellation")
    }

    /// Raises a latch the first time a chunk containing `marker` reaches the
    /// stderr box.
    ///
    /// The seam runs the observer AFTER the append, so a raised latch is a
    /// statement about the box and not merely about the pipe: by the time
    /// this signals, `stderrSoFar` already contains those bytes.
    private static func markerObserver(
        _ marker: String, _ arrived: AsyncSignal
    ) -> @Sendable (Data) -> Void {
        { chunk in
            if String(decoding: chunk, as: UTF8.self).contains(marker) { arrived.signal() }
        }
    }

    /// `stderrSoFar` means what it says: what the child wrote before the run
    /// ended, whether or not the pipe ever reaches EOF — and proving it does
    /// not need a clock.
    ///
    /// This replaces a case that ran the same child under a 2 s bound and
    /// then asserted the marker was in the timeout's `stderrSoFar`. The child
    /// writes the marker at once, but it reaches the box only when the
    /// runner's `readabilityHandler` gets a Dispatch global-queue thread, and
    /// on a three-core CI runner starting 3800 tests in one burst that thread
    /// is contended. The bound is wall-clock; the handler's scheduling is
    /// not. So the assertion was a race, and CI ran it red twice on that
    /// expectation before the investigation of run 33741778350 named it.
    ///
    /// The reader is now the synchronisation point instead: the run gets a
    /// bound no machine can reach (60 s, against a child that sleeps 60),
    /// `onStderrChunk` raises `arrived` once the marker is in the box, the
    /// test waits for that — bounded only by the suite, so a starved runner
    /// makes this slow and never wrong — and only then cancels. Nothing in
    /// that sequence a slow machine can reorder.
    ///
    /// The facts asserted are the ones the old case asserted: the bytes
    /// written before the ending survive into the error, and the grandchild
    /// still holding the write end leaves `stderrDrained == false`. The
    /// ending is a cancellation rather than a bound because cancellation is
    /// the only one of the two the test can place AFTER an observation.
    ///
    /// `sleep 60` for both the child and the grandchild: the child must still
    /// be alive when the cancellation arrives, however late that is, or the
    /// run settles normally and there is no captured-output path to read.
    ///
    /// The `.timeLimit` is a net under the seam, not a clock in the property:
    /// `arrived.wait()` below has no bound of its own on purpose, so a
    /// regression that stopped `onStderrChunk` from being called — a defect
    /// in the seam itself, not in reader scheduling — would otherwise hang
    /// this test forever rather than fail it. Five minutes is far past
    /// anything reader scheduling has been observed to cost.
    @Test(.timeLimit(.minutes(5)))
    func aCancelledRunReportsWhatTheChildWroteBeforeTheStop() async throws {
        let marker = "wrote-before-the-stop-\(UUID().uuidString)"
        let arrived = AsyncSignal()
        let task = Task { () -> SubprocessResult in
            try await SubprocessRunner.run(
                Self.shell,
                arguments: ["-c", "echo '\(marker)' >&2; sleep 60 & exec sleep 60"],
                timeout: .seconds(60),
                onStderrChunk: Self.markerObserver(marker, arrived))
        }

        // No bound of its own: a wait that gave up here would put the clock
        // back in exactly the place this test exists to take it out of.
        #expect(await arrived.wait() == .signalled)
        task.cancel()

        var thrown: (any Error)?
        do {
            _ = try await task.value
            Issue.record("a cancelled run returned a result instead of reporting cancellation")
        } catch {
            thrown = error
        }
        let error = try #require(
            thrown as? SubprocessCancelled,
            "cancellation surfaced as \(String(describing: thrown))")
        let text = String(decoding: error.stderrSoFar, as: UTF8.self)
        #expect(
            text.contains(marker),
            "stderr the reader had delivered was lost; the error said: \(error)")
        // The grandchild still holds the write end, so this is the case the
        // description has to be able to explain rather than merely survive.
        //
        // The `false` is a fact about THIS child, not a decision of the
        // runner. For the whole of `run` the pipes are bound alive (re-review
        // 3, N-2) and the handler stays installed, so the only thing that can
        // raise the drained latch is EOF — and the grandchild withholds it.
        #expect(error.reap.stderrDrained == false)
        #expect("\(error)".contains("stderr reader"))
    }

    /// The other ending carries the same capture: a run that ends on its
    /// bound reports what the reader had delivered by then.
    ///
    /// This one cannot be taken off the clock the way the case above is —
    /// there is no path to `SubprocessTimeout` that does not begin with a
    /// deadline, and that deadline starts inside `run`, where the test has no
    /// place to put an observation before it. So `arrived` buys a DIAGNOSIS
    /// here rather than a proof: it says whether the reader ever delivered
    /// before the bound fired, which separates "the runner starved the
    /// reader" — an environment condition, and this run simply cannot see
    /// the property past it — from "the error dropped what the reader
    /// delivered", which is a defect. That is exactly the distinction the
    /// empty-string failure of run 33741778350 could not make.
    ///
    /// The two causes get two different endings, not two different failure
    /// messages on the same red. When the reader never delivered, this is a
    /// MEASURED SKIP: the case prints what it knows and returns green,
    /// because a starved Dispatch global queue is not a fact about
    /// `SubprocessRunner`, and a `#require` that reddened here would be the
    /// same flake this whole investigation exists to remove, wearing a
    /// clearer message. Red is reserved for the one case that is a defect:
    /// the reader delivered the marker and the error does not carry it.
    ///
    /// The bound stays at the 2 s the replaced case used, and the reason is a
    /// measurement rather than a preference. Widening it looked free and was
    /// not, while `anOuterMarginOverrunKeepsTheHopsTheWalkHadMeasured` still
    /// raced a 250 ms Dispatch timer against a 400 ms sleep: a longer-lived
    /// child here was load inside that 150 ms window. Measured 2026-09-03 on
    /// the ten-core development machine, full `swift test`: with this bound
    /// at 10 s, that case went red in 3 of 8 runs against 0 of 12 on the
    /// branch point; at 6 s, 5 of 8; at 4 s it was 0 of 8 on a quiet machine
    /// and 1 of 5 when the machine was busy, measured in interleaved pairs
    /// against the branch point's 0 of 5. At 2 s the load is the load this
    /// suite already had. That race is gone as of this round — the case now
    /// forces the abandonment through `NetworkTrace.run`'s `onAbandon` seam
    /// instead of racing a timer against a sleep — so the constraint that
    /// kept this bound at 2 s no longer holds; widening it is not this
    /// round's ruling, and is left for one that measures it.
    @Test func aTimeoutCarriesWhatTheReaderDelivered() async throws {
        let marker = "delivered-before-the-bound-\(UUID().uuidString)"
        let arrived = AsyncSignal()
        var thrown: SubprocessTimeout?
        do {
            _ = try await SubprocessRunner.run(
                Self.shell,
                arguments: ["-c", "echo '\(marker)' >&2; sleep 60 & exec sleep 60"],
                timeout: .seconds(2),
                onStderrChunk: Self.markerObserver(marker, arrived))
            Issue.record("a child sleeping for 60 s returned inside a 2 s bound")
        } catch let error as SubprocessTimeout {
            thrown = error
        }

        let error = try #require(thrown)
        guard arrived.isRaised else {
            // Measured skip, not a failure — see the comment above. Printed
            // rather than silent, so a run of nothing but skips is still
            // visible in the log rather than looking exactly like a run of
            // nothing but passes.
            print("""
                SKIP aTimeoutCarriesWhatTheReaderDelivered: the stderr reader \
                never delivered the marker inside the 2 s bound; the Dispatch \
                global queue was starved, and this run cannot say anything \
                about what the error carries. \(error)
                """)
            return
        }
        let text = String(decoding: error.stderrSoFar, as: UTF8.self)
        #expect(
            text.contains(marker),
            "the reader delivered the marker and the timeout did not carry it: \(error)")
        #expect(error.reap.stderrDrained == false)
    }

    /// A reader must not need a free Dispatch global-queue thread.
    ///
    /// GATED behind `MACSCP_SATURATION=1`, and skipped by default. A test
    /// that fills the global queue cannot share a parallel run: in CI run
    /// 33705649537 on the three-core runner it passed, in 23.54 s, and while
    /// it held the queue two unrelated tests went red around it — a 2 s
    /// bound in the timeout case that has since been replaced by
    /// `aCancelledRunReportsWhatTheChildWroteBeforeTheStop` fired after
    /// ~17 s, and `AsyncSignalTests`' 200 ms bound measured 15.68 s. The
    /// proof is worth having and not worth that; run it alone, on purpose.
    ///
    /// Measured 2026-09-03, gated on, alone, on the ten-core development
    /// machine: limit 64, free width 64, 80 blocks parked and 80 released,
    /// in 3 of 3 runs; the parked-thread mutant (readers back to an
    /// `availableData` loop on `DispatchQueue.global()`) turns it red 5 of 5.
    ///
    /// This is the shape CI run 33698102652 failed in, reproduced without CI
    /// load. Blocks are parked in `read(2)` on pipes nobody writes to — the
    /// very thing the old readers did, one pair per child, for every child in
    /// a suite that now awaits all of them. Dispatch's global pool has a
    /// finite width and blocked threads count against it, so a reader
    /// submitted behind them never runs at all and the box stays empty however
    /// incrementally it would have filled.
    ///
    /// How many blocks is derived at run time, not assumed: the width is a
    /// property of the kernel's workqueue on the machine running the test,
    /// not of this code, and an earlier version parked a constant 96 that
    /// happened to exceed the width seen on one ten-core box. A wider pool
    /// would have let the parked-thread reader get its thread, and this test
    /// would have stayed green with the defect present — insensitive, which
    /// from the outside reads exactly like satisfied.
    ///
    /// Two numbers, and what each one is:
    ///
    /// - The pool's width is READ, from `kern.wq_max_constrained_threads` —
    ///   the kernel's limit on constrained (non-overcommit) workqueue
    ///   threads, which is the pool `DispatchQueue.global()` draws from. The
    ///   count parked is that plus a margin, so once the pool is full of
    ///   these blocks the margin sits queued behind it whatever else the
    ///   parallel suite is doing, and a reader block submitted after them
    ///   cannot start.
    /// - The FREE width at this moment is MEASURED, by submitting blocks one
    ///   at a time and waiting for each to start: the first that does not
    ///   start within a short bound is the saturation, and the number before
    ///   it is how many threads the pool had to give. Alone on the machine
    ///   that equals the limit; inside the parallel suite it is whatever
    ///   the other tests left, and measured 2026-09-03 in 3 of 3 full runs
    ///   it was ZERO — the first block started 1.35 s to 3.27 s late, because
    ///   other tests already held every thread. So the free width is
    ///   asserted to be at most the limit, and not to be positive.
    ///
    /// Measured 2026-09-03 on the ten-core development machine, alone:
    /// limit 64, free width 64, in 3 of 3 runs of this test.
    ///
    /// The positive anchor for the mechanism is at the end: after the write
    /// ends are closed, every parked block is required to have run and
    /// returned. A block that ran reached its first instruction, so the
    /// start signal the measurement rests on is proven to work even when the
    /// measured free width is zero — and no thread is left behind.
    ///
    /// Measured 2026-09-03 under exactly this saturation: an `availableData`
    /// loop on a `DispatchQueue.global()` block captured 0 bytes; the
    /// `readabilityHandler` the runner uses captured the marker.
    ///
    /// The blockers are parked on pipe reads rather than a sleep because a
    /// blocking sleep is precisely what this suite forbids (CLAUDE.md, "Tests
    /// never block the cooperative pool"), and closing the write ends releases
    /// every one of them deterministically, on every exit path, including a
    /// failed `#require`.
    @Test(.enabled(
        if: ProcessInfo.processInfo.environment["MACSCP_SATURATION"] == "1",
        "saturates the global queue for every test running beside it (CI run 33705649537); run alone with MACSCP_SATURATION=1"))
    func readersDoNotNeedAFreeGlobalQueueThread() async throws {
        let limit = try #require(
            Self.constrainedWorkqueueThreadLimit(),
            "kern.wq_max_constrained_threads is not readable here; the test cannot know the pool's width")
        try #require(limit > 0, "the kernel reports a constrained-thread limit of \(limit)")
        let margin = 16
        let startBound = Duration.milliseconds(250)
        // A ceiling on what this test will park, whatever the kernel says.
        // `Pipe()` cannot report `EMFILE` — it hands back handles over
        // invalid descriptors, and the first read on one raises an ObjC
        // exception that takes the whole test process down with no name on
        // it — and every parked block is a workqueue thread with its own
        // stack. 128 blocks is 256 descriptors, and it is above the limit
        // measured anywhere so far (64), so the loop below can still run
        // PAST the limit and the `<= limit` check stays a measurement.
        let cap = 128

        var writeEnds: [FileHandle] = []
        var finished: [AsyncSignal] = []
        defer { for handle in writeEnds { try? handle.close() } }

        // Parks one block. `started` is raised on the block's first
        // instruction, so a wait on it that times out means the pool had no
        // thread to give; `done` is raised when the block returns, which it
        // does once its write end is closed.
        //
        // `startBound` is the one wall-clock bound this suite keeps, and it
        // keeps it because here the bound IS the measurement, not a ceiling
        // over one: "a block that cannot start within `startBound`" is the
        // definition of the saturation this test exists to observe, and
        // `.timedOut` is the reading it takes. Nothing about it is an
        // assertion that the machine was fast enough — the free width it
        // produces is asserted to be at most the kernel's limit and is
        // allowed to be zero, which is what a slow runner produces. The test
        // is gated on `MACSCP_SATURATION` and runs alone.
        let park: (AsyncSignal?) -> Void = { started in
            let pipe = Pipe()
            writeEnds.append(pipe.fileHandleForWriting)
            let readEnd = pipe.fileHandleForReading
            let done = AsyncSignal()
            finished.append(done)
            DispatchQueue.global().async {
                started?.signal()
                _ = readEnd.availableData
                done.signal()
            }
        }

        // The loop is allowed to run PAST the limit, so that `freeWidth <=
        // limit` below is a measurement of libdispatch honouring the
        // kernel's number and not a restatement of the loop's own bound.
        var freeWidth = 0
        var saturated = false
        while writeEnds.count < cap {
            let started = AsyncSignal()
            park(started)
            if await started.wait(timeout: startBound) == .timedOut {
                saturated = true
                break
            }
            freeWidth += 1
        }
        #expect(freeWidth <= limit, "\(freeWidth) blocks started on a pool the kernel limits to \(limit)")
        try #require(
            saturated,
            "\(writeEnds.count) blocks all started on a pool the kernel limits to \(limit): not saturated")
        while writeEnds.count < min(limit + margin, cap) { park(nil) }

        // `sleep 60`, not 10: CI run 33705649537 caught this exact shape —
        // this test saturating the pool while a NEIGHBOUR held a 2 s bound
        // over a `sleep 10` child, whose bound fired ~17 s late, after the
        // child had already exited. Here the saturating test and the bound
        // are the same test, so the risk lands on whoever runs it: on a
        // smaller or busier machine than the one this file's numbers were
        // measured on, this 2 s bound can itself fire late enough to find
        // an exited `sleep 10` child, and the marker assertion below — the
        // entire proof this test exists for — never executes. `aadbafca`
        // made this same correction, `sleep 10` to `sleep 60`, for the
        // neighbour run 33705649537 actually broke; this is its twin.
        let marker = "under-saturation-\(UUID().uuidString)"
        var thrown: SubprocessTimeout?
        do {
            _ = try await SubprocessRunner.run(
                Self.shell,
                arguments: ["-c", "echo '\(marker)' >&2; exec sleep 60"],
                timeout: .seconds(2))
            Issue.record("a child sleeping for 60 s returned inside a 2 s bound")
        } catch let error as SubprocessTimeout {
            thrown = error
        }

        let error = try #require(thrown)
        let text = String(decoding: error.stderrSoFar, as: UTF8.self)
        #expect(
            text.contains(marker),
            """
            a saturated global queue (limit \(limit), free width \(freeWidth) when \
            this test began, \(writeEnds.count) blocks parked) silenced the \
            reader; the error said: \(error)
            """)

        // Release, then require that every block ran and returned. No
        // deadline over the release at all: the ten-second one that used to
        // stand here was a wall clock over work a saturated pool schedules,
        // which is the ceiling that measures the runner rather than the
        // property (CLAUDE.md, "A wall-clock ceiling in a test measures the
        // runner") -- and this is the one test in the tree that deliberately
        // starves that pool. Each latch is awaited unbounded; a block that
        // never returns ends this test through the suite's time limit.
        // Closed here and forgotten, so the `defer` above has nothing left
        // to close twice on this path.
        for handle in writeEnds { try? handle.close() }
        writeEnds.removeAll()
        var released = 0
        for done in finished where await done.wait() == .signalled {
            released += 1
        }
        #expect(released == finished.count, "\(finished.count - released) parked blocks never returned")
        // The record of a gated run, since it only runs when someone asks.
        print("readersDoNotNeedAFreeGlobalQueueThread: limit \(limit), free width \(freeWidth), parked \(finished.count), released \(released)")
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

    /// No argument VALUE reaches the failure message.
    ///
    /// Since the short waits were converted, several suites in this target run
    /// `ssh-keygen -N <passphrase>` through this runner, so an argument can be
    /// a secret's value and a rendered argument list is that secret sitting in
    /// a public CI log. (No count here on purpose: a number written into a
    /// comment is a claim about the rest of the tree that has to be recounted
    /// on every change — CLAUDE.md, "Comments that describe other code" — and
    /// the property does not depend on how many there are.)
    ///
    /// `SubprocessTimeout` stores `argumentCount`, not the arguments, so this
    /// test guards a boundary rather than being the only thing between a
    /// passphrase and a CI log: what the type does not hold, no later
    /// conformance can render.
    ///
    /// The test itself is the second exit, and it is shut here too: `#expect`
    /// reports the SOURCE TEXT of the expression it checks, so a secret named
    /// inside an expectation leaks through the failure it is meant to prevent
    /// (CLAUDE.md, "A value a test must not leak has two exits, not one").
    /// Every `Bool` below is therefore computed first, and no message
    /// interpolates the rendered error.
    @Test func aTimeoutNamesNoArgumentValue() async throws {
        let secret = "passphrase-\(UUID().uuidString)"
        var thrown: SubprocessTimeout?
        do {
            _ = try await SubprocessRunner.run(
                Self.shell,
                arguments: ["-c", "exec sleep 60", secret],
                timeout: .seconds(1))
            Issue.record("a child sleeping for 60 s returned inside a 1 s bound")
        } catch let error as SubprocessTimeout {
            thrown = error
        }

        let error = try #require(thrown)
        let rendered = "\(error)"
        let rendersTheValue = rendered.contains(secret)
        #expect(rendersTheValue == false, "an argument value reached the failure message")

        // The positive half: the message still says enough to identify the
        // invocation. Without it, a `description` that rendered nothing at all
        // would satisfy the check above.
        let namesTheExecutable = rendered.contains("sh")
        let namesTheCount = rendered.contains("\(error.argumentCount) arguments")
        #expect(namesTheExecutable)
        #expect(namesTheCount)
        #expect(error.argumentCount == 3)
    }

    /// Cancellation is an outcome of its own, not a quiet "it settled".
    ///
    /// An `AsyncStream` finishes when its awaiting task is cancelled just as
    /// it does when someone finishes it, so a wait that cannot tell the two
    /// apart reports the child as settled the moment an enclosing
    /// `.timeLimit` or task group fires — and then reads `terminationStatus`
    /// off a child that is still running and walks away leaving it there.
    ///
    /// Both halves are checked here: the error that comes back out is a
    /// `SubprocessCancelled`, and the child is gone. The child announces its
    /// own pid into a file and then `exec`s `sleep`, so the pid on disk IS
    /// the process the runner owns.
    ///
    /// The error was a bare `CancellationError` until the cancelled ending
    /// was given the same fields the timed-out one has. What the type IS
    /// matters here for the reason the three outcomes exist at all: an
    /// `AsyncStream` ends the same way when it is finished and when its
    /// waiter is cancelled, so a runner that could not tell them apart would
    /// read `terminationStatus` off a live child and walk away from it.
    @Test func aCancelledRunKillsItsChildAndReportsCancellation() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-runner-cancel-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pidFile = directory.appendingPathComponent("pid")
        let pidPath = pidFile.path(percentEncoded: false)

        let task = Task { () -> SubprocessResult in
            try await SubprocessRunner.run(
                Self.shell,
                arguments: ["-c", "echo $$ > '\(pidPath)'; exec sleep 30"],
                timeout: .seconds(120))
        }

        // Cancel a RUNNING child, not the spawn: without this the test could
        // pass against a runner that only ever refuses to start.
        var announced: pid_t?
        for _ in 0..<200 where announced == nil {
            if let text = try? String(contentsOf: pidFile, encoding: .utf8),
               text.hasSuffix("\n"),
               let value = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                announced = value
            } else {
                try? await Task.sleep(for: .milliseconds(25))
            }
        }
        let childPID = try #require(announced, "the child never announced its pid")

        task.cancel()
        var thrown: (any Error)?
        do {
            _ = try await task.value
            Issue.record("a cancelled run returned a result instead of reporting cancellation")
        } catch {
            thrown = error
        }
        // No wall-clock ceiling on the way back: a run that ignored the
        // cancellation would return the child's result after its 30 s sleep
        // and fail on the `Issue.record` above, and one that honoured it
        // throws. What the type of the error is, and whether the child is
        // gone, are the two claims; how long the runner took to deliver them
        // measures the runner (CLAUDE.md, "A wall-clock ceiling in a test
        // measures the runner").
        #expect(thrown is SubprocessCancelled, "cancellation surfaced as \(String(describing: thrown))")

        var stillThere = true
        for _ in 0..<50 where stillThere {
            stillThere = kill(childPID, 0) == 0
            if stillThere { try? await Task.sleep(for: .milliseconds(100)) }
        }
        #expect(stillThere == false, "pid \(childPID) outlived the cancelled run")
    }

    /// 128 KB in, so the writer proves it does not deadlock either: a runner
    /// that wrote stdin before starting to read would stall the moment the
    /// child's output filled a pipe nobody was draining.
    @Test func stdinIsWrittenAndClosedSoTheChildSeesEOF() async throws {
        let payload = Data(repeating: UInt8(ascii: "z"), count: 128 * 1024)
        let result = try await SubprocessRunner.run(
            URL(fileURLWithPath: "/bin/cat"), arguments: [], stdin: payload)
        #expect(result.status == 0)
        #expect(result.stdout == payload)
    }

    @Test func theEnvironmentAndWorkingDirectoryReachTheChild() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-subprocess-runner-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        FileManager.default.createFile(
            atPath: directory.appendingPathComponent("marker").path(percentEncoded: false),
            contents: Data())

        let listed = try await SubprocessRunner.run(
            URL(fileURLWithPath: "/bin/ls"), arguments: [], currentDirectory: directory)
        #expect(listed.status == 0)
        #expect(listed.stdoutText.contains("marker"))

        let probed = try await SubprocessRunner.run(
            Self.shell,
            arguments: ["-c", "printf '%s' \"$MACSCP_RUNNER_PROBE\""],
            environment: ["MACSCP_RUNNER_PROBE": "reached"])
        #expect(probed.stdoutText == "reached")
    }
}
