import Foundation
import Synchronization
#if canImport(Darwin)
import Darwin
#endif

/// Runs a child process attached to a real pseudo-terminal, so the child's
/// `isatty(stdin)` is true — the one condition
/// `Tests/macSCPCoreTests/Support/SubprocessRunner.swift` can never produce,
/// since it always hands the child the null device for stdin. This is what
/// closes the backlog row "`--non-interactive` cannot be told apart from its
/// own absence in this harness": every existing CLI integration test runs
/// under a false `hasTTY`, where `HostKeyPolicy.decision(for: .ask,
/// hasTTY: false)` already resolves to `.reject` before the flag is ever
/// read, so the two cases the row asks for need a real terminal to tell the
/// flag's own contribution apart from the policy's.
///
/// ## How the controlling terminal is acquired
///
/// `posix_openpt`/`grantpt`/`unlockpt`/`ptsname_r` open the master side and
/// name the slave device. The slave itself is opened **inside the child**,
/// through `posix_spawn_file_actions_addopen` for fd 0 — not opened here and
/// `adddup2`'d in, which is what an earlier version of this file did and
/// which measurably does NOT acquire a controlling terminal. On Darwin the
/// kernel's tty driver assigns the controlling terminal from its `open(2)`
/// entry point: a process that is a session leader with no controlling
/// terminal (`POSIX_SPAWN_SETSID` below makes it one) acquires the tty it
/// opens as that terminal. `adddup2` shares an existing open file
/// description without ever calling that entry point, so it cannot trigger
/// the assignment — measured by running `/usr/bin/tty` under each shape: the
/// `addopen` shape below prints the real `/dev/ttysNNN` path, and the
/// `adddup2`-of-a-parent-opened-slave shape prints nothing at all (`tty`
/// exits 0 with empty stdout, mirrored in
/// `Tests/macSCPCoreTests/PTYSubprocessTests.swift`'s positive case). Fds 1
/// and 2 are then `adddup2`'d from fd 0, so all three share the one real
/// open.
///
/// ## How the child's exit is observed
///
/// Not `DispatchSource.makeProcessSource(identifier:eventMask:.exit)`, the
/// shape this file started with: on this toolchain, resuming that source
/// crashes the whole process with `SIGTRAP` the instant its event fires —
/// reproduced eight times while building this file, including with a
/// deliberately empty event handler (so the fault is the source itself, not
/// anything this code does with it), across both a `posix_spawn`ed pty child
/// and a plain `Foundation.Process`. Instead, a dedicated `Thread` blocks in
/// `waitpid(2)` — the same call the process source would have made
/// internally — and resumes a `SingleShot` continuation from it. That thread
/// is not one of Swift's cooperative-pool threads, so this still holds
/// CLAUDE.md's "Tests never block the cooperative pool": nothing `await`ed
/// here ever blocks, only a plain OS thread created for exactly this wait
/// does, and it does nothing else.
///
/// ## Reading the master, and the second slave reference
///
/// A dedicated `Thread` blocks in a plain `read(2)` loop on the master
/// descriptor — not `DispatchIO`, which was this file's first shape and
/// which lost every byte of a fast child's output the instant real
/// concurrency entered the picture (below). Each chunk it reads feeds both
/// an internal buffer (for `Result.output`) and `Handle.output`, an
/// `AsyncStream<String>` a caller's `interact` closure can watch for prompt
/// text as it arrives. Like the exit-reaping thread above, this is a plain
/// OS thread, not one of Swift's cooperative-pool threads.
///
/// `openMaster()` also opens a SECOND reference to the slave
/// (`extraSlaveFD`), held by this side alone and closed only once the child
/// has exited. Without it: `/usr/bin/tty` — a child that writes one line and
/// exits in microseconds — read back as EMPTY, `n=0`, in every one of 40
/// concurrent runs, and in 5 of 5 sequential runs with no concurrency at
/// all. The moment the child's own three fds (0/1/2, all one open file
/// description) all close, Darwin's tty driver tears the line down and
/// whatever was still sitting unread in the master's queue goes with it —
/// this is the driver's teardown rule, not a scheduling race this file's
/// own code could win by reading sooner; a read already in flight when the
/// child exits can still lose. Holding a second, independent reference to
/// the slave open changes which side of that rule a run is on: the line is
/// not torn down while ANY reference survives, so the output is still there
/// once this side gets around to reading it, however late. The extra
/// reference is closed right after the exit-reaping thread's `waitpid`
/// returns (releasing the last reference, so the read loop's next `read(2)`
/// finally sees the real EOF and ends) — never any earlier, and measured:
/// closing it immediately after `waitpid` but BEFORE that run's read
/// reproduced the same `n=0` loss, because the read had not yet reached the
/// kernel by the time the last reference vanished. A PTY master reports
/// "the slave side is gone" as a plain zero-length read once every
/// reference (the child's own, and this side's extra one) has closed, or as
/// `EIO` if the hang-up is more abrupt — this file treats both the same
/// way, as the read simply being done, never as a thrown error.
public struct PTYSubprocess: Sendable {
    /// What a finished (or forcibly ended) child left behind.
    public struct Result: Sendable {
        /// Everything read from the master, in arrival order, decoded from
        /// UTF-8 leniently (invalid sequences become the replacement
        /// character rather than failing the whole read).
        public let output: String
        /// The exit code from a normal exit, meaningless when `signal` is
        /// set.
        public let status: Int32
        /// The signal that ended the child, `nil` for a normal exit.
        public let signal: Int32?
    }

    /// Thrown when one of the PTY or `posix_spawn` setup calls fails, before
    /// there is a child to report a `Result` for.
    public struct SpawnError: Error, CustomStringConvertible, Sendable {
        public let step: String
        public let errnoValue: Int32
        public var description: String {
            "\(step) failed (errno \(errnoValue)): \(String(cString: strerror(errnoValue)))"
        }
    }

    /// The live child an `interact` closure is handed: a place to watch
    /// output arrive and to answer it.
    public final class Handle: Sendable {
        private let masterFD: Int32
        private let pid: pid_t

        /// Chunks read from the master as they arrive, decoded from UTF-8
        /// leniently. `run(_:...)` is ALSO reading the same underlying
        /// bytes into `Result.output` independently of whatever this stream
        /// yields, so consuming it here (or not) never affects what the
        /// finished `Result` carries.
        public let output: AsyncStream<String>

        init(masterFD: Int32, pid: pid_t, output: AsyncStream<String>) {
            self.masterFD = masterFD
            self.pid = pid
            self.output = output
        }

        /// Writes `text` to the child's terminal — an answer to a prompt,
        /// most likely. Blocks only as long as the kernel's tty input
        /// buffer takes to accept a few bytes, which is not a wait this
        /// file needs to route through `async`.
        public func write(_ text: String) {
            let bytes = Array(text.utf8)
            guard !bytes.isEmpty else { return }
            bytes.withUnsafeBufferPointer { buffer in
                guard let base = buffer.baseAddress else { return }
                var offset = 0
                while offset < buffer.count {
                    let written = Darwin.write(masterFD, base + offset, buffer.count - offset)
                    guard written > 0 else { break }
                    offset += written
                }
            }
        }

        /// Ends the child immediately. Idempotent by way of `kill(2)` on an
        /// already-dead pid being a harmless no-op (a zombie the reaping
        /// thread has not yet collected still safely wears this pid — see
        /// the safety net in `run(_:...)` for why that is what makes this
        /// safe to call unconditionally).
        public func terminate() {
            guard pid > 0 else { return }
            kill(pid, SIGKILL)
        }
    }

    /// A resolve-once value continuation any thread can settle and `async`
    /// code can await — the bridge from the blocking `waitpid` thread and
    /// the blocking master-read thread (both plain, non-cooperative-pool
    /// execution contexts) into this function's `async` body. Reimplemented
    /// here rather than reusing `Tests/macSCPCoreTests/Support/AsyncSignal.swift`,
    /// which this target cannot see (SwiftPM compiles each test target from
    /// its own directory; `MacSCPTestSupport` is the one place shared by
    /// both).
    private final class SingleShot<Value: Sendable>: Sendable {
        private let state = Mutex<(value: Value?, continuation: CheckedContinuation<Value, Never>?)>((nil, nil))

        /// Whether this has already settled, without waiting for it —
        /// `run(_:...)`'s safety net reads this so it never sends a signal
        /// to a pid number the kernel could since have reused (see the
        /// comment at that call site for why a zombie makes this race-free).
        var isResolved: Bool { state.withLock { $0.value != nil } }

        /// Settles this exactly once; every call after the first is
        /// ignored. Safe from any thread.
        func resume(_ newValue: Value) {
            let continuation: CheckedContinuation<Value, Never>? = state.withLock { state in
                guard state.value == nil else { return nil }
                state.value = newValue
                let pending = state.continuation
                state.continuation = nil
                return pending
            }
            continuation?.resume(returning: newValue)
        }

        /// Suspends until this settles. Nothing is parked: the suspension
        /// is a `CheckedContinuation`, resumed from whichever thread calls
        /// `resume(_:)`.
        func value() async -> Value {
            if let existing = state.withLock({ $0.value }) { return existing }
            return await withCheckedContinuation { continuation in
                let alreadySettled: Value? = state.withLock { state in
                    if let value = state.value { return value }
                    state.continuation = continuation
                    return nil
                }
                if let alreadySettled {
                    continuation.resume(returning: alreadySettled)
                }
            }
        }
    }

    private init() {}

    /// Opens the master/slave pair, names the slave, and — the part that is
    /// NOT optional — opens a SECOND reference to the slave that this side
    /// keeps for itself, `O_NOCTTY` so it never becomes this process's own
    /// controlling terminal.
    ///
    /// Without it: measured by spawning `/usr/bin/tty` (a child that writes
    /// one line and exits in microseconds) and reading the master only
    /// after `waitpid` confirms the child is gone. Every one of 40
    /// concurrent runs still came back with ZERO bytes read
    /// (`n=0`), and so did 5 of 5 sequential, single-threaded runs with no
    /// concurrency at all: once the child's own three fds (0/1/2, all the
    /// same open file description) all close, Darwin's tty driver tears the
    /// line down and the master's read buffer goes with it, whether or not
    /// this side had already issued its read. Repeating the exact same
    /// sequence with this second slave reference held open until this
    /// side's own read is done went 5 of 5 (and separately, the concurrent
    /// run's own `spawn` failures also disappeared): the tty is not
    /// considered fully closed — so the driver keeps the queue — as long as
    /// ANY reference to the slave is still open, whether or not it is the
    /// child's own. This is not a timing race this file's own scheduling
    /// could lose or win faster; it is the driver's teardown rule, and only
    /// holding a second reference open changes which side of that rule a
    /// run is on.
    ///
    /// Both descriptors are closed on every failure path below their own
    /// open, since there is no child yet to inherit either.
    private static func openMaster() throws -> (masterFD: Int32, extraSlaveFD: Int32, slavePath: String) {
        let masterFD = posix_openpt(O_RDWR | O_NOCTTY)
        guard masterFD >= 0 else { throw SpawnError(step: "posix_openpt", errnoValue: errno) }
        guard grantpt(masterFD) == 0 else {
            let failure = errno
            close(masterFD)
            throw SpawnError(step: "grantpt", errnoValue: failure)
        }
        guard unlockpt(masterFD) == 0 else {
            let failure = errno
            close(masterFD)
            throw SpawnError(step: "unlockpt", errnoValue: failure)
        }
        var nameBuffer = [Int8](repeating: 0, count: Int(PATH_MAX))
        guard ptsname_r(masterFD, &nameBuffer, nameBuffer.count) == 0 else {
            let failure = errno
            close(masterFD)
            throw SpawnError(step: "ptsname_r", errnoValue: failure)
        }
        let slavePath = nameBuffer.withUnsafeBufferPointer { buffer -> String in
            guard let base = buffer.baseAddress else { return "" }
            return String(cString: base)
        }
        let extraSlaveFD = open(slavePath, O_RDWR | O_NOCTTY)
        guard extraSlaveFD >= 0 else {
            let failure = errno
            close(masterFD)
            throw SpawnError(step: "open(slavePath)", errnoValue: failure)
        }
        return (masterFD, extraSlaveFD, slavePath)
    }

    /// `posix_spawn`s `executable` with the slave as fds 0/1/2, as a new
    /// session leader (`POSIX_SPAWN_SETSID`) so opening the slave acquires
    /// it as the controlling terminal — see this file's doc comment for the
    /// measurement behind that shape.
    private static func spawn(
        executable: URL, arguments: [String], environment: [String: String],
        slavePath: String, masterFD: Int32, extraSlaveFD: Int32
    ) throws -> pid_t {
        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)
        defer { posix_spawn_file_actions_destroy(&fileActions) }

        let openStatus = slavePath.withCString { slaveCPath in
            posix_spawn_file_actions_addopen(&fileActions, 0, slaveCPath, O_RDWR, 0)
        }
        guard openStatus == 0 else {
            throw SpawnError(step: "posix_spawn_file_actions_addopen", errnoValue: openStatus)
        }
        posix_spawn_file_actions_adddup2(&fileActions, 0, 1)
        posix_spawn_file_actions_adddup2(&fileActions, 0, 2)
        // Neither of this side's own two slave-adjacent descriptors is the
        // child's to hold: the master, closed so the child cannot keep this
        // side's own reads open past its lifetime, and the extra slave
        // reference (`openMaster()`'s own doc comment), which exists so
        // THIS side controls when the tty line is allowed to tear down —
        // the child inheriting a fourth reference to it would only leave
        // one more descriptor for `Handle.terminate()`'s `SIGKILL` to not
        // clean up on its own.
        posix_spawn_file_actions_addclose(&fileActions, masterFD)
        posix_spawn_file_actions_addclose(&fileActions, extraSlaveFD)

        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID))

        let path = executable.path(percentEncoded: false)
        var argvPointers = ([path] + arguments).map { strdup($0) }
        argvPointers.append(nil)
        defer { for pointer in argvPointers where pointer != nil { free(pointer) } }

        var envPointers = environment.map { strdup("\($0.key)=\($0.value)") }
        envPointers.append(nil)
        defer { for pointer in envPointers where pointer != nil { free(pointer) } }

        var pid: pid_t = 0
        let spawnStatus = path.withCString { execCPath in
            posix_spawn(&pid, execCPath, &fileActions, &attr, &argvPointers, &envPointers)
        }
        guard spawnStatus == 0 else {
            throw SpawnError(step: "posix_spawn", errnoValue: spawnStatus)
        }
        return pid
    }

    /// Runs `executable` under a real pseudo-terminal, hands `interact` a
    /// `Handle` to watch and answer it with, and returns once the child has
    /// exited and its master has been fully drained.
    ///
    /// - Parameter interact: run while the child is alive, concurrently with
    ///   the master being read (the read thread below runs independently of
    ///   whatever this closure is doing) — the shape a caller waiting for a
    ///   prompt and then answering it needs. The default does nothing, for
    ///   a child that needs no answers at all.
    /// - Returns: everything the child wrote, and how it ended.
    public static func run(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        interact: @Sendable (Handle) async throws -> Void = { _ in }
    ) async throws -> Result {
        let (masterFD, extraSlaveFD, slavePath) = try openMaster()
        let pid: pid_t
        do {
            pid = try spawn(
                executable: executable, arguments: arguments, environment: environment,
                slavePath: slavePath, masterFD: masterFD, extraSlaveFD: extraSlaveFD)
        } catch {
            close(extraSlaveFD)
            close(masterFD)
            throw error
        }

        let collected = Mutex(Data())
        let (outputStream, outputContinuation) = AsyncStream<String>.makeStream(of: String.self)

        // See this file's doc comment ("Reading the master, and the second
        // slave reference"): a plain blocking `read(2)` loop on a dedicated
        // OS thread, not `DispatchIO` — which lost every byte of a fast
        // child's output the moment real concurrency entered the picture,
        // regardless of how early its read was registered. Every chunk
        // read feeds both the accumulator behind `Result.output` and
        // `Handle.output`'s stream, in the order it arrived.
        let readDone = SingleShot<Void>()
        Thread.detachNewThread {
            var buffer = [UInt8](repeating: 0, count: 4096)
            readLoop: while true {
                let bytesRead = buffer.withUnsafeMutableBytes { rawBuffer -> Int in
                    guard let base = rawBuffer.baseAddress else { return -1 }
                    return read(masterFD, base, rawBuffer.count)
                }
                switch bytesRead {
                case ..<0, 0:
                    // A negative return (`EIO`, most often — the abrupt
                    // hang-up a PTY reports once every slave reference is
                    // gone) or a plain zero-length read (the orderly EOF
                    // the same event can also produce): both mean the
                    // master has nothing further to give, ever.
                    break readLoop
                default:
                    let chunk = Array(buffer[0..<bytesRead])
                    collected.withLock { $0.append(contentsOf: chunk) }
                    outputContinuation.yield(String(decoding: chunk, as: UTF8.self))
                }
            }
            outputContinuation.finish()
            readDone.resume(())
        }

        let exitDone = SingleShot<(status: Int32, signal: Int32?)>()
        // See this file's doc comment: `DispatchSource.makeProcessSource`
        // crashes on this toolchain the instant it fires, so the child's
        // exit is reaped on a dedicated thread instead — an OS thread, not
        // one of Swift's cooperative-pool threads, so nothing here parks a
        // thread the test runner needed.
        Thread.detachNewThread {
            var status: Int32 = 0
            waitpid(pid, &status, 0)
            // Releasing the last slave reference is what lets the read
            // loop above's next `read(2)` see the real EOF and finish —
            // done here, the moment the child is confirmed gone, and never
            // any earlier (this file's doc comment measured why).
            close(extraSlaveFD)
            let signalled = (status & 0x7f) != 0
            if signalled {
                exitDone.resume((status: -1, signal: status & 0x7f))
            } else {
                exitDone.resume((status: (status >> 8) & 0xff, signal: nil))
            }
        }

        let handle = Handle(masterFD: masterFD, pid: pid, output: outputStream)

        var interactError: Error?
        do {
            try await interact(handle)
        } catch {
            interactError = error
        }

        // The safety net: only reached when `interact` threw, or when the
        // enclosing task was cancelled out from under it (a suite's own
        // `.timeLimit`, most likely) — the two cases where this function is
        // about to leave without ever having waited for the child to exit
        // on its own, and where nothing else here has asked it to stop. On
        // the plain success path this does NOT fire: a child asked no
        // question at all (the default `interact`, or one that answered
        // and simply returned) is meant to keep running until it exits by
        // itself, and killing it the moment `interact` returns would end
        // it before it had done its work — measured the hard way, as every
        // case in this file but `terminateEndsAChildWithASignal()` first
        // came back `signal == SIGKILL` before this guard was narrowed to
        // the two failure paths.
        //
        // `isResolved` false here means the pid is either still running or
        // a not-yet-reaped zombie — either way still safely addressed by
        // this pid number, since the kernel cannot reuse a pid before it is
        // reaped, and reaping is exactly what flips `isResolved` to true.
        // So this can never target a pid the kernel has since handed to an
        // unrelated process.
        if (interactError != nil || Task.isCancelled), !exitDone.isResolved {
            kill(pid, SIGKILL)
        }

        // Awaited unconditionally, whether `interact` threw or returned
        // normally: the child's exit is always reaped and its master
        // reader always drained before this function returns on any path —
        // no child outlives this call.
        let exitResult = await exitDone.value()
        await readDone.value()
        close(masterFD)

        if let interactError { throw interactError }

        let outputText = collected.withLock { String(decoding: $0, as: UTF8.self) }
        return Result(output: outputText, status: exitResult.status, signal: exitResult.signal)
    }
}
