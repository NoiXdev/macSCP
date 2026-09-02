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

/// Thrown when a child outlives the bound it was run with.
///
/// Carries the stderr collected up to that point: when a CLI stalls, the
/// half-written diagnostic is usually the only thing that says why. It also
/// carries what the escalation actually did, because a stalled child on a
/// loaded CI runner is the one case nobody can attach a debugger to — the
/// error is the entire report, and an error that says only "empty" cannot
/// distinguish a child that wrote nothing from a reader that never got
/// there. CI run 33693297919 was exactly that ambiguity.
struct SubprocessTimeout: Error, CustomStringConvertible {
    /// What the escalation did, and how long each phase really took.
    struct ReapReport: Sendable {
        /// Wall-clock spent on the bounded wait. On a saturated runner this
        /// overruns `timeout` — a deadline is when a sleeping task becomes
        /// RUNNABLE, not when it runs — and saying so by how much is the
        /// difference between "the bound is wrong" and "the machine is busy".
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

    let executable: String

    /// The argument list, for a test or a debugger that needs it — never for
    /// a message. `description` names only how MANY there were.
    ///
    /// Since the short waits were converted, `ConnectFailureSecrecyTests` and
    /// `Support/InstalledKey.swift` run `ssh-keygen -N <passphrase>` through
    /// this runner, so an argument value is a secret's value and a rendered
    /// argument list is that secret in a CI log. Nothing here renders one, and
    /// `aTimeoutNamesNoArgumentValue` holds this type to it.
    let arguments: [String]

    let timeout: Duration
    let stderrSoFar: Data
    let reap: ReapReport

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
            \(arguments.count) arguments (values withheld: an argument can be \
            a passphrase)
            \(phases)
            stdout reader: \(reap.stdoutDrained ? "drained" : "still open"); \
            stderr reader: \(reap.stderrDrained ? "drained" : "still open")
            stderr so far: \(text.isEmpty ? "(empty)" : text)
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
/// So every wait here is a suspension. The pipes are read on
/// `DispatchQueue.global()`, which grows a thread rather than starving;
/// termination arrives through `Process.terminationHandler`; and the caller
/// waits on `AsyncSignal`s, which are `AsyncStream`s, not semaphores.
enum SubprocessRunner {
    /// Runs `executable` with `arguments`, drains both pipes, and awaits
    /// termination without parking a cooperative-pool thread.
    ///
    /// Both pipes are drained CONCURRENTLY, on their own queues. Reading
    /// stdout to EOF before touching stderr deadlocks as soon as the child
    /// fills the stderr pipe's kernel buffer while this side is still
    /// waiting on stdout — the same hazard `PasswordCommandSecretSource`
    /// guards against (`Sources/macSCPCore/Sessions/CLISecretSources.swift`).
    ///
    /// Bounded, because an unbounded wait turns "the command stalled" into
    /// "the suite hangs with no clue which call did it". On expiry the child
    /// is asked to terminate, then killed, so the pipes reach EOF and the
    /// readers finish; `SubprocessTimeout` carries what stderr held by then.
    ///
    /// A cancelled task gets the same ending and a `CancellationError`: the
    /// caller who stopped waiting — a `.timeLimit` trait, an enclosing task
    /// group — has no way to reach the child, so this leaves none behind.
    ///
    /// - Parameter stdin: written to the child and the write end closed, so
    ///   the child sees EOF. `nil` gives the child the null device, which is
    ///   what a test wants for a command that must not read a terminal.
    @discardableResult
    static func run(
        _ executable: URL,
        arguments: [String],
        environment: [String: String]? = nil,
        currentDirectory: URL? = nil,
        stdin: Data? = nil,
        timeout: Duration = .seconds(60)
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

        // Incrementally, not `readDataToEndOfFile()`. That call returns only
        // at EOF, so a box filled by it holds everything or nothing — and
        // nothing is what it holds exactly when the child is stuck, which is
        // the only time the timeout path reads it. `availableData` blocks
        // until there are bytes and answers an empty `Data` at EOF, so the
        // box tracks what the child has written all along and the latch still
        // means EOF.
        DispatchQueue.global().async {
            let handle = stdoutPipe.fileHandleForReading
            while case let chunk = handle.availableData, !chunk.isEmpty {
                stdoutBox.append(chunk)
            }
            stdoutDrained.signal()
        }
        DispatchQueue.global().async {
            let handle = stderrPipe.fileHandleForReading
            while case let chunk = handle.availableData, !chunk.isEmpty {
                stderrBox.append(chunk)
            }
            stderrDrained.signal()
        }
        if let stdin, let stdinPipe {
            DispatchQueue.global().async {
                let handle = stdinPipe.fileHandleForWriting
                try? handle.write(contentsOf: stdin)
                try? handle.close()
            }
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
                arguments: arguments,
                timeout: timeout,
                stderrSoFar: stderrBox.read(),
                reap: SubprocessTimeout.ReapReport(
                    bound: bound,
                    sigtermGrace: grace.sigterm,
                    sigkillGrace: grace.sigkill,
                    stdoutDrained: stdoutDrained.isRaised,
                    stderrDrained: stderrDrained.isRaised))
        case .cancelled:
            _ = await reap()
            throw CancellationError()
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
