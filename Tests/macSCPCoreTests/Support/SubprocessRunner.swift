import Foundation
import Synchronization

/// What a finished child process left behind.
struct SubprocessResult: Sendable {
    let status: Int32
    let stdout: Data
    let stderr: Data

    /// The two streams as text, for the many call sites that assert on
    /// output. Lossy decoding, deliberately: a test that fails because a
    /// byte was not UTF-8 should say what the command printed, not vanish
    /// into a nil.
    var stdoutText: String { String(decoding: stdout, as: UTF8.self) }
    var stderrText: String { String(decoding: stderr, as: UTF8.self) }
}

/// What the escalation did to end a run, and how long each phase really took.
///
/// Shared by both of the runner's failure endings — the bound expiring and
/// the caller's task being cancelled — because the escalation itself is the
/// same on both paths, and so is the question a reader of either error asks:
/// did the child write nothing, or did the reader never get there?
struct SubprocessReapReport: Sendable {
    /// Wall-clock spent on the wait that ended. On a saturated runner this
    /// overruns the bound — a deadline is when a sleeping task becomes
    /// RUNNABLE, not when it runs — and saying so by how much is the
    /// difference between "the bound is wrong" and "the machine is busy".
    /// On the cancellation path it is how long the wait had run when the
    /// cancellation reached it, which no bound predicts.
    let bound: Duration
    /// `nil` when the phase was not reached (the child had already been
    /// reaped, so nothing was signalled).
    let sigtermGrace: Duration?
    let sigkillGrace: Duration?
    /// Whether each reader had seen EOF by the time the error was built.
    /// A reader still open after `SIGKILL` means something OTHER than the
    /// child holds the write end — a grandchild that inherited it, most
    /// likely — and that is a fact about the child, not about the runner.
    let stdoutDrained: Bool
    let stderrDrained: Bool
}

/// Thrown when a child outlives the bound it was run with.
///
/// Carries the stderr collected up to that point: when a CLI stalls, the
/// half-written diagnostic is usually the only thing that says why. It also
/// carries what the escalation actually did, because a stalled child on a
/// loaded CI runner is the one case nobody can attach a debugger to — the
/// error is the entire report, and an error that says only "empty" cannot
/// distinguish a child that wrote nothing from a reader that never got
/// there. CI run 33693297919 was exactly that ambiguity.
struct SubprocessTimeout: Error, CustomStringConvertible, Sendable {
    let executable: String

    /// How many arguments there were. NOT the arguments.
    ///
    /// Several suites in this target run `ssh-keygen -N <passphrase>` through
    /// this runner, so an argument value can be a secret's value and a
    /// rendered argument list is that secret sitting in a public CI log.
    /// Storing the count rather than the list is what makes the leak
    /// unwritable: no later `CustomDebugStringConvertible`, `LocalizedError`
    /// or `dump()` can print what this type does not hold. A comment plus one
    /// textual expectation over `description` could only forbid it (CLAUDE.md,
    /// "Guards that name what they watch", rule 3 — a property that keeps
    /// buying one spelling wants a structural boundary).
    let argumentCount: Int

    let timeout: Duration
    let stderrSoFar: Data
    let reap: SubprocessReapReport

    var description: String {
        let text = String(decoding: stderrSoFar, as: UTF8.self)
        let phases = [
            "waited \(reap.bound) for the \(timeout) bound",
            reap.sigtermGrace.map { "\($0) after SIGTERM" },
            reap.sigkillGrace.map { "\($0) after SIGKILL" },
        ]
        .compactMap { $0 }
        .joined(separator: ", ")
        return """
            \(executable) did not exit within \(timeout), given \
            \(argumentCount) arguments (values withheld: an argument can be \
            a passphrase)
            \(phases)
            stdout reader: \(reap.stdoutDrained ? "drained" : "still open"); \
            stderr reader: \(reap.stderrDrained ? "drained" : "still open")
            stderr so far: \(text.isEmpty ? "(empty)" : text)
            """
    }
}

/// Thrown when the caller's task is cancelled while a child is still running.
///
/// A bare `CancellationError` before, and that threw away everything the run
/// had collected. The evidence problem is the SAME one `SubprocessTimeout`
/// was given its fields for: the child is ended by the same escalation, and
/// what it had written by then is the only account of what it was doing.
///
/// It is also what lets a test stop depending on a clock. A bound is when a
/// sleeping task becomes RUNNABLE, not when it runs, so "the child wrote this
/// before the bound" read off a timed-out run is a race between the deadline
/// and the reader getting a Dispatch thread — the race CI run 33741778350 was
/// investigated for. Cancellation has no deadline in it: a test can wait for
/// the reader to deliver, cancel, and read what was captured, with nothing in
/// the sequence that a slow machine can reorder.
///
/// `argumentCount`, not the arguments, for the reason `SubprocessTimeout`
/// gives at its own field: an argument value can be a passphrase, and what
/// this type does not hold, no later conformance can render.
struct SubprocessCancelled: Error, CustomStringConvertible, Sendable {
    let executable: String

    /// How many arguments there were. NOT the arguments.
    let argumentCount: Int

    let stdoutSoFar: Data
    let stderrSoFar: Data
    let reap: SubprocessReapReport

    var stdoutText: String { String(decoding: stdoutSoFar, as: UTF8.self) }
    var stderrText: String { String(decoding: stderrSoFar, as: UTF8.self) }

    var description: String {
        let phases = [
            "waited \(reap.bound) before the cancellation",
            reap.sigtermGrace.map { "\($0) after SIGTERM" },
            reap.sigkillGrace.map { "\($0) after SIGKILL" },
        ]
        .compactMap { $0 }
        .joined(separator: ", ")
        return """
            \(executable) was cancelled while running, given \(argumentCount) \
            arguments (values withheld: an argument can be a passphrase)
            \(phases)
            stdout reader: \(reap.stdoutDrained ? "drained" : "still open"); \
            stderr reader: \(reap.stderrDrained ? "drained" : "still open")
            stderr so far: \(stderrText.isEmpty ? "(empty)" : stderrText)
            """
    }
}

/// Runs child processes for the test suites without parking a thread of the
/// Swift concurrency cooperative pool.
///
/// The pool is exactly as wide as the machine has cores, and Swift Testing
/// runs every test on it. A test that blocks — `Process.waitUntilExit()`, a
/// `DispatchGroup.wait()`, a semaphore — holds one of those few threads for
/// as long as the child runs, and on a three-core CI runner three such tests
/// are enough to starve the other three thousand (CLAUDE.md, "Tests never
/// block the cooperative pool"; the measurement is in
/// `docs/superpowers/specs/2026-08-08-testsuite-hang-investigation.md`).
///
/// So every wait here is a suspension, and no thread is parked on the
/// child's behalf either: the pipes are read by `FileHandle.readabilityHandler`
/// — a Dispatch source that runs a short block per readable event — rather
/// than by a block that sits in `read(2)` for the child's whole life;
/// termination arrives through `Process.terminationHandler`; and the caller
/// waits on `AsyncSignal`s, which are `AsyncStream`s, not semaphores. The
/// stdin writer is a `writeabilityHandler` on a non-blocking descriptor, for
/// the same reason: a block on the global queue does not merely park while
/// the child accepts its input — under a full constrained pool it never
/// starts, and a child reading to EOF then waits for input that is never
/// written (re-review 4, N-10).
///
/// An earlier version of this comment said the pipes were read on
/// `DispatchQueue.global()`, "which grows a thread rather than starving".
/// CI run 33698102652 refuted both halves: Dispatch's global pool has a
/// finite width that blocked threads count against, and once the parallel
/// suite had parked enough readers, a newly submitted one never got a
/// thread at all — the child exited, and its output was never read. The
/// comment at the readers below carries the log line.
enum SubprocessRunner {
    /// Runs `executable` with `arguments`, drains both pipes, and awaits
    /// termination without parking a cooperative-pool thread.
    ///
    /// Both pipes are drained CONCURRENTLY, each by its own
    /// `readabilityHandler` source rather than a blocking read to EOF.
    /// Draining stdout to EOF before touching stderr deadlocks as soon as
    /// the child fills the stderr pipe's kernel buffer while this side is
    /// still waiting on stdout — the same hazard `PasswordCommandSecretSource`
    /// guards against (`Sources/macSCPCore/Sessions/CLISecretSources.swift`).
    ///
    /// Bounded, because an unbounded wait turns "the command stalled" into
    /// "the suite hangs with no clue which call did it". On expiry the child
    /// is asked to terminate, then killed. A child that held its write ends
    /// alone then closes them, so the pipes reach EOF and the readers finish;
    /// one whose grandchild inherited them does not, and the readers stay
    /// open past the throw. `SubprocessTimeout` carries what stderr held by
    /// then, and its `SubprocessReapReport` says which of the two it was.
    ///
    /// A cancelled task gets the same ending and a `SubprocessCancelled`: the
    /// caller who stopped waiting — a `.timeLimit` trait, an enclosing task
    /// group — has no way to reach the child, so this leaves none behind, and
    /// the error carries what the run had collected rather than discarding it.
    ///
    /// - Parameter stdin: written to the child and the write end closed, so
    ///   the child sees EOF. `nil` gives the child the null device, which is
    ///   what a test wants for a command that must not read a terminal.
    /// - Parameter onStderrChunk: an observation seam, `nil` at every call
    ///   site that is not about the reader itself. It is invoked from the
    ///   stderr readability handler AFTER the chunk has been appended, so a
    ///   caller that raises a latch from it knows the box already holds those
    ///   bytes — which is what turns "wait for the reader" into a
    ///   synchronisation point rather than a sleep. Same shape and same
    ///   purpose as `ICMPEcho.TransmitObserver`: a property that no
    ///   assertion on the OUTCOME can reach, observed where it happens.
    /// - Parameter onStdoutChunk: the same seam as `onStderrChunk`, on the
    ///   other stream — added for the `diagnose` line-buffering measurement
    ///   (`CLIMatrixDiagnoseITests.rowsArriveInMoreThanOneChunk`), which has
    ///   to count stdout reads as they land rather than only see the
    ///   settled `SubprocessResult`.
    @discardableResult
    static func run(
        _ executable: URL,
        arguments: [String],
        environment: [String: String]? = nil,
        currentDirectory: URL? = nil,
        stdin: Data? = nil,
        timeout: Duration = .seconds(60),
        onStderrChunk: (@Sendable (Data) -> Void)? = nil,
        onStdoutChunk: (@Sendable (Data) -> Void)? = nil
    ) async throws -> SubprocessResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let environment { process.environment = environment }
        if let currentDirectory { process.currentDirectoryURL = currentDirectory }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        let stdinPipe: Pipe?
        if stdin != nil {
            let pipe = Pipe()
            stdinPipe = pipe
            process.standardInput = pipe
        } else {
            stdinPipe = nil
            process.standardInput = FileHandle.nullDevice
        }

        let stdoutBox = OutputBox()
        let stderrBox = OutputBox()
        let stdoutDrained = AsyncSignal()
        let stderrDrained = AsyncSignal()
        let exited = AsyncSignal()

        // Installed before `run()`: a child that exits between the launch and
        // the assignment would otherwise never raise the latch.
        process.terminationHandler = { _ in exited.signal() }
        try process.run()

        // Event-driven, and this is the third shape these readers have had.
        //
        // `readDataToEndOfFile()` returned only at EOF, so the box held
        // everything or nothing — and nothing is what it held exactly when
        // the child was stuck, which is the only time the timeout path reads
        // it. An `availableData` loop fixed that but kept the real problem:
        // it PARKS a thread in `read(2)` for the child's whole life. Since
        // every child in this suite is awaited, every child parks two, and
        // Dispatch's global pool has a finite width that blocked threads
        // count against — so a reader block that cannot get a thread never
        // reads, and the box stays empty however incrementally it would have
        // filled. CI run 33698102652 is that, in the runner's own words:
        // "waited 9.951088917 seconds for the 2.0 seconds bound … stdout
        // reader: still open; stderr reader: still open … stderr so far:
        // (empty)".
        //
        // `readabilityHandler` installs a Dispatch source instead: a short
        // block runs per readable event and returns the thread. An empty
        // chunk is EOF, which clears the handler and raises the latch —
        // `AsyncSignal.signal()` is idempotent, so exactly-once holds even if
        // the source were to fire again.
        //
        // Measured 2026-09-03, both shapes against a child that writes a
        // marker and sleeps, with the global queue saturated by blocking
        // blocks in `read(2)` — as many as the kernel's constrained-thread
        // limit plus a margin, the limit read at run time rather than
        // written here, and the pool's free width measured alongside by
        // submitting until a block no longer starts
        // (`readersDoNotNeedAFreeGlobalQueueThread`): the loop captured 0
        // bytes, this captures the marker.
        let drain: @Sendable (FileHandle, OutputBox, AsyncSignal, (@Sendable (Data) -> Void)?) -> Void = {
            handle, box, latch, observer in
            handle.readabilityHandler = { handle in
                let chunk = handle.availableData
                guard !chunk.isEmpty else {
                    handle.readabilityHandler = nil
                    latch.signal()
                    return
                }
                // The observer runs AFTER the append, never before: its whole
                // purpose is to let a caller conclude that the box already
                // holds these bytes.
                box.append(chunk)
                observer?(chunk)
            }
        }
        drain(stdoutPipe.fileHandleForReading, stdoutBox, stdoutDrained, onStdoutChunk)
        drain(stderrPipe.fileHandleForReading, stderrBox, stderrDrained, onStderrChunk)

        // The pipes must outlive the wait, and nothing above guarantees that
        // (re-review 3, N-2). The handler captures only the box and the
        // latch — its `handle` parameter shadows the outer one, which is
        // what keeps it free of a cycle — so the `Pipe`s are held by these
        // locals and by `process`, and Swift promises neither past its last
        // use. Measured 2026-09-03 on a bare `Pipe` with a handler installed:
        // the readability source does NOT retain the handle, so releasing the
        // pipe deallocates it, closes the fd and cancels the source at once.
        // Were that to happen here with bytes still buffered, EOF would never
        // be delivered, the drained latch never raised, and a child that ran
        // for milliseconds would come back as a full-length timeout with an
        // empty box. This `defer` is a use at scope exit, so the tuple lives
        // through the wait, the reap and the return on every path; it is
        // deliberately not the handler capturing its own handle, which would
        // be a cycle broken only by the `= nil` at EOF — never on the
        // grandchild path. (`withExtendedLifetime` has no `async` overload,
        // hence the `defer` rather than a wrapping call.)
        defer { withExtendedLifetime((stdoutPipe, stderrPipe, stdinPipe)) {} }
        if let stdin, let stdinPipe {
            Self.write(stdin, to: stdinPipe.fileHandleForWriting)
        }

        // "Settled" means all three: a child can exit while a reader still
        // has buffered bytes to collect, and reading `terminationStatus`
        // before the handler has fired is reading a status that does not
        // exist yet.
        //
        // A wait that is cut short says `.cancelled` rather than joining
        // `.signalled`, and the difference is load-bearing: on `.cancelled`
        // the child is still running, so `terminationStatus` must not be read
        // (Foundation raises on a live child) and the child must not be left
        // behind.
        let settled: @Sendable (Duration) async -> AsyncSignal.WaitOutcome = { bound in
            await AsyncSignal.race(timeout: bound) {
                if await stdoutDrained.wait() == .cancelled { return .cancelled }
                if await stderrDrained.wait() == .cancelled { return .cancelled }
                return await exited.wait()
            }
        }

        // Ends the child and joins its readers. Runs DETACHED, because one of
        // the two callers below is the cancellation path: a task group child
        // that inherited that cancellation would find every `Task.sleep`
        // throwing at once, and the two-second grace before `SIGKILL` would
        // be no grace at all. A detached task inherits no cancellation, so
        // the escalation is the same on both paths.
        //
        // It reports how long each phase really took, because those are the
        // numbers that separate "the escalation is broken" from "the runner
        // is time-slicing a three-core box across three thousand tests".
        let pid = process.processIdentifier
        let reap: @Sendable () async -> (sigterm: Duration?, sigkill: Duration?) = {
            await Task.detached { () -> (sigterm: Duration?, sigkill: Duration?) in
                guard !exited.isRaised else { return (nil, nil) }
                kill(pid, SIGTERM)
                let afterTerminate = ContinuousClock.now
                let settledAfterTerminate = await settled(.seconds(2))
                let sigtermGrace = ContinuousClock.now - afterTerminate
                guard settledAfterTerminate != .signalled, !exited.isRaised else {
                    return (sigtermGrace, nil)
                }
                kill(pid, SIGKILL)
                let afterKill = ContinuousClock.now
                _ = await settled(.seconds(5))
                return (sigtermGrace, ContinuousClock.now - afterKill)
            }.value
        }

        let boundStarted = ContinuousClock.now
        let outcome = await settled(timeout)
        let bound = ContinuousClock.now - boundStarted

        switch outcome {
        case .signalled:
            return SubprocessResult(
                status: process.terminationStatus,
                stdout: stdoutBox.read(),
                stderr: stderrBox.read())
        case .timedOut:
            let grace = await reap()
            throw SubprocessTimeout(
                executable: executable.lastPathComponent,
                argumentCount: arguments.count,
                timeout: timeout,
                stderrSoFar: stderrBox.read(),
                reap: SubprocessReapReport(
                    bound: bound,
                    sigtermGrace: grace.sigterm,
                    sigkillGrace: grace.sigkill,
                    stdoutDrained: stdoutDrained.isRaised,
                    stderrDrained: stderrDrained.isRaised))
        case .cancelled:
            let grace = await reap()
            throw SubprocessCancelled(
                executable: executable.lastPathComponent,
                argumentCount: arguments.count,
                stdoutSoFar: stdoutBox.read(),
                stderrSoFar: stderrBox.read(),
                reap: SubprocessReapReport(
                    bound: bound,
                    sigtermGrace: grace.sigterm,
                    sigkillGrace: grace.sigkill,
                    stdoutDrained: stdoutDrained.isRaised,
                    stderrDrained: stderrDrained.isRaised))
        }
    }

    /// Writes `input` to the child and closes the write end, without a
    /// thread parked on the pipe.
    ///
    /// The same shape as the readers, mirrored: the descriptor is put into
    /// non-blocking mode and a `writeabilityHandler` writes as much as the
    /// pipe takes per writable event, stopping at `EAGAIN` until the child
    /// has drained some and the source fires again. Written in full — or
    /// refused, because the child closed its end (`EPIPE`) — the handler is
    /// cleared and the write end closed, so the child sees EOF. A
    /// `DispatchQueue.global()` block did this before, and a block on that
    /// queue is exactly what a full constrained pool never starts.
    ///
    /// `F_SETNOSIGPIPE`, because a raw `write(2)` to a pipe whose reader has
    /// gone would otherwise deliver `SIGPIPE` to the whole test process.
    /// The child cannot see either flag: both are on this side's open file
    /// description, which the child does not inherit.
    ///
    /// The handle's lifetime is the caller's `withExtendedLifetime` above;
    /// a child that exits without reading everything leaves the source to be
    /// cancelled with the pipe when `run` returns, and nothing parked.
    private static func write(_ input: Data, to handle: FileHandle) {
        let fd = handle.fileDescriptor
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        _ = fcntl(fd, F_SETNOSIGPIPE, 1)
        guard !input.isEmpty else {
            try? handle.close()
            return
        }
        let cursor = Mutex(0)
        handle.writeabilityHandler = { handle in
            let finished: Bool = cursor.withLock { offset in
                while offset < input.count {
                    let written = input.withUnsafeBytes { bytes -> Int in
                        guard let base = bytes.baseAddress else { return 0 }
                        return Darwin.write(handle.fileDescriptor, base + offset, input.count - offset)
                    }
                    if written > 0 {
                        offset += written
                    } else if written < 0, errno == EAGAIN {
                        return false
                    } else {
                        // EPIPE, or a descriptor already gone: the child
                        // stopped reading, and there is nobody to write for.
                        return true
                    }
                }
                return true
            }
            if finished {
                handle.writeabilityHandler = nil
                try? handle.close()
            }
        }
    }

    /// Where a background pipe read accumulates what it has collected.
    ///
    /// Locked rather than a bare `var` behind `@unchecked Sendable`, and the
    /// lock is doing real work here: on the timeout path the collected stderr
    /// is read WHILE the reader is still appending to it, so there is no
    /// happens-before edge to lean on and no quiet moment to read in.
    private final class OutputBox: Sendable {
        private let storage = Mutex(Data())

        func append(_ chunk: Data) { storage.withLock { $0.append(chunk) } }
        func read() -> Data { storage.withLock { $0 } }
    }
}
