import Foundation
import Testing

/// What `SubprocessRunner` has to get right for the suites that replaced
/// their blocking child waits with it: the exit status and both streams of a
/// normal child, an output volume no pipe buffer holds, a child that outlives
/// its bound, and the three inputs a caller can hand it.
@Suite("SubprocessRunner")
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
    /// Two things are checked, and the second is the one that matters: the
    /// throw arrives near the bound rather than at the child's own 30 s, and
    /// the pid is gone afterwards. A runner that gave up without killing
    /// would satisfy the first and fail the second.
    @Test func aChildThatOutlivesItsBoundThrowsAndIsKilled() async throws {
        let started = ContinuousClock.now
        var timeout: SubprocessTimeout?
        do {
            _ = try await SubprocessRunner.run(
                Self.shell,
                arguments: ["-c", "echo $$ >&2; exec sleep 30"],
                timeout: .seconds(2))
            Issue.record("a child that sleeps for 30 s returned inside a 2 s bound")
        } catch let error as SubprocessTimeout {
            timeout = error
        }
        let elapsed = ContinuousClock.now - started
        #expect(elapsed < .seconds(20), "the bound did not end the wait: \(elapsed)")

        let error = try #require(timeout)
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
        #expect(stillThere == false, "pid \(pid) survived the timeout")
    }

    /// `stderrSoFar` means what it says: what the child wrote before the
    /// bound, whether or not the pipe ever reaches EOF.
    ///
    /// `readDataToEndOfFile()` returns ONLY at EOF, so a box filled that way
    /// holds everything or nothing — and "nothing" is what a caller gets
    /// exactly when the child is stuck, which is the only time this field is
    /// read. The child here backgrounds a second `sleep` that inherits the
    /// stderr write end, so killing the direct child does not close the pipe
    /// and EOF never arrives inside the escalation at all.
    ///
    /// CI run 33693297919 failed on the empty half of this: a timeout whose
    /// `stderrSoFar` was `""` could not say whether the child had written
    /// nothing or the reader had not got there, which is also why the error
    /// now reports each reader's drained state.
    ///
    /// `sleep 10`, not 60: the grandchild outlives this test either way (it is
    /// reparented to `launchd`), so the number is purely how long a leftover
    /// process sits on the CI runner per parallel copy of the suite.
    @Test func aTimeoutReportsWhatTheChildWroteBeforeTheBound() async throws {
        let marker = "wrote-before-the-bound-\(UUID().uuidString)"
        var thrown: SubprocessTimeout?
        do {
            _ = try await SubprocessRunner.run(
                Self.shell,
                arguments: ["-c", "echo '\(marker)' >&2; sleep 10 & exec sleep 10"],
                timeout: .seconds(2))
            Issue.record("a child sleeping for 10 s returned inside a 2 s bound")
        } catch let error as SubprocessTimeout {
            thrown = error
        }

        let error = try #require(thrown)
        let text = String(decoding: error.stderrSoFar, as: UTF8.self)
        #expect(
            text.contains(marker),
            "stderr written before the bound was lost; the error said: \(error)")
        // The grandchild still holds the write end, so this is the case the
        // description has to be able to explain rather than merely survive.
        //
        // The `false` is a fact about THIS child, not a decision of the
        // runner. For the whole of `run` the pipes are bound alive (re-review
        // 3, N-2) and the handler stays installed, so the only thing that can
        // raise the drained latch is EOF — and the grandchild withholds it.
        // What happens AFTER the throw is a separate question: the frame
        // releases its pipes, and — measured 2026-09-03 on a bare `Pipe` —
        // Foundation's readability source does not retain the handle, so a
        // released handle closes its fd and cancels its source at once. The
        // runner's pipes are also held by its `Process`, whose release after
        // the throw is not measured here; round 1's M-4 is at most that. If
        // the runner ever closed its read ends itself, both latches would
        // raise inside the escalation and this line would need revisiting on
        // a runner that got strictly better.
        #expect(error.reap.stderrDrained == false)
        #expect("\(error)".contains("stderr reader"))
    }

    /// A reader must not need a free Dispatch global-queue thread.
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
    @Test func readersDoNotNeedAFreeGlobalQueueThread() async throws {
        let limit = try #require(
            Self.constrainedWorkqueueThreadLimit(),
            "kern.wq_max_constrained_threads is not readable here; the test cannot know the pool's width")
        try #require(limit > 0, "the kernel reports a constrained-thread limit of \(limit)")
        let margin = 16
        let startBound = Duration.milliseconds(250)

        var writeEnds: [FileHandle] = []
        var finished: [AsyncSignal] = []
        defer { for handle in writeEnds { try? handle.close() } }

        // Parks one block. `started` is raised on the block's first
        // instruction, so a wait on it that times out means the pool had no
        // thread to give; `done` is raised when the block returns, which it
        // does once its write end is closed.
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
        while freeWidth < 2 * limit {
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
        while writeEnds.count < limit + margin { park(nil) }

        let marker = "under-saturation-\(UUID().uuidString)"
        var thrown: SubprocessTimeout?
        do {
            _ = try await SubprocessRunner.run(
                Self.shell,
                arguments: ["-c", "echo '\(marker)' >&2; exec sleep 10"],
                timeout: .seconds(2))
            Issue.record("a child sleeping for 10 s returned inside a 2 s bound")
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

        // Release, then require that every block ran and returned. The bound
        // is generous because a block that has not started yet gets its
        // thread only when the parallel suite's other blockers let go.
        for handle in writeEnds { try? handle.close() }
        var released = 0
        for done in finished {
            if await done.wait(timeout: .seconds(10)) == .signalled { released += 1 }
        }
        #expect(released == finished.count, "\(finished.count - released) parked blocks never returned")
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
    /// `CancellationError`, and the child is gone. The child announces its
    /// own pid into a file and then `exec`s `sleep`, so the pid on disk IS
    /// the process the runner owns.
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

        let started = ContinuousClock.now
        task.cancel()
        var thrown: (any Error)?
        do {
            _ = try await task.value
            Issue.record("a cancelled run returned a result instead of reporting cancellation")
        } catch {
            thrown = error
        }
        let elapsed = ContinuousClock.now - started
        #expect(thrown is CancellationError, "cancellation surfaced as \(String(describing: thrown))")
        #expect(elapsed < .seconds(20), "the cancelled run took \(elapsed) to come back")

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
