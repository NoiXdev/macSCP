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
/// half-written diagnostic is usually the only thing that says why.
struct SubprocessTimeout: Error, CustomStringConvertible {
    let executable: String
    let arguments: [String]
    let timeout: Duration
    let stderrSoFar: Data

    var description: String {
        let text = String(decoding: stderrSoFar, as: UTF8.self)
        return """
            \(executable) did not exit within \(timeout): \
            \(arguments.joined(separator: " "))
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

        DispatchQueue.global().async {
            stdoutBox.store(stdoutPipe.fileHandleForReading.readDataToEndOfFile())
            stdoutDrained.signal()
        }
        DispatchQueue.global().async {
            stderrBox.store(stderrPipe.fileHandleForReading.readDataToEndOfFile())
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
        let settled: @Sendable (Duration) async -> Bool = { bound in
            await AsyncSignal.race(timeout: bound) {
                await stdoutDrained.wait()
                await stderrDrained.wait()
                await exited.wait()
            }
        }

        if await settled(timeout) == false {
            process.terminate()
            if await settled(.seconds(2)) == false {
                kill(process.processIdentifier, SIGKILL)
                _ = await settled(.seconds(5))
            }
            throw SubprocessTimeout(
                executable: executable.lastPathComponent,
                arguments: arguments,
                timeout: timeout,
                stderrSoFar: stderrBox.read())
        }

        return SubprocessResult(
            status: process.terminationStatus,
            stdout: stdoutBox.read(),
            stderr: stderrBox.read())
    }

    /// Where a background pipe read puts what it collected.
    ///
    /// Locked rather than a bare `var` behind `@unchecked Sendable`: on the
    /// timeout path the collected stderr is read while the reader may still
    /// be running, so there is no happens-before edge to lean on.
    private final class OutputBox: Sendable {
        private let storage = Mutex(Data())

        func store(_ value: Data) { storage.withLock { $0 = value } }
        func read() -> Data { storage.withLock { $0 } }
    }
}
