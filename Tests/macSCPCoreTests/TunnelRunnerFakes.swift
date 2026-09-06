import Foundation
import MacSCPTestSupport
import NIOCore
import Testing

@testable import macSCPCore

// The doubles `TunnelRunnerTests` drives the runner with, and the collector
// both that suite and `DiagnosticLogSharedSinkTests`' tunnel-line test read
// its state stream through.
//
// A file of their own rather than `private` types inside the suite, because
// the log-line test cannot live in the same file: `TunnelRunner` logs
// through `DiagnosticLog.shared` (the house pattern, and what keeps
// `DiagnosticLogSecrecyGuardTests`' scan able to see its call site), and
// `DiagnosticLogSharedSinkIsolationGuardTests` allows exactly one test file
// to mention that singleton.

/// Collects everything the runner publishes, so a test can await one state
/// AND read the whole sequence afterwards.
///
/// The buffering matters: `AsyncStream.makeStream()` buffers without bound,
/// so a collector built right after `init` — before `start(decider:)` is ever
/// called — misses nothing, and `waitFor` is satisfied by a state that has
/// ALREADY been published.
///
/// `pollUntil` rather than a continuation the recorder resumes, deliberately:
/// a bare continuation that is never resumed outlives its suite's
/// `.timeLimit` (`docs/BACKLOG.md`, "A test parked on a bare continuation
/// outlives its time limit"), which is exactly what happened while this file
/// was being written — the whole bundle sat at 0 % CPU past the limit instead
/// of reporting a red. `pollUntil` carries no deadline of its own and answers
/// cancellation, so the trait is what ends a wait that cannot be satisfied.
final class TunnelStateCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [TunnelState] = []
    /// How far `waitFor` has already consumed.
    ///
    /// Without it, every wait is answered by HISTORY: a second
    /// `waitFor(.active(connections: 0))` after a reconnect would be
    /// satisfied by the FIRST `active` the runner ever published, and the
    /// test would race ahead of the retry it meant to wait for. Both defects
    /// were observed while writing this file — one as a wrong count, one as
    /// a wait for a state that could no longer come, because the test had
    /// already dropped a connection whose disconnect handler the runner had
    /// not yet registered.
    private var cursor = 0

    init(_ states: AsyncStream<TunnelState>) {
        Task { [self] in
            for await state in states { append(state) }
        }
    }

    var recorded: [TunnelState] {
        lock.lock()
        defer { lock.unlock() }
        return seen
    }

    private func append(_ state: TunnelState) {
        lock.lock()
        seen.append(state)
        lock.unlock()
    }

    /// Waits for the NEXT `wanted` — one not already consumed by an earlier
    /// wait — and consumes it.
    func waitFor(_ wanted: TunnelState) async throws {
        try await pollUntil("the runner to publish \(wanted)") {
            self.consume { $0 == wanted }
        }
    }

    /// Any `.failed`, whatever its reason — the reason is a mapped sentence
    /// this suite deliberately does not spell out, so a change to
    /// `DialSupport.reason(for:)` does not rewrite these tests.
    func waitForFailure() async throws {
        try await pollUntil("the runner to publish a failure") {
            self.consume {
                if case .failed = $0 { return true }
                return false
            }
        }
    }

    private func consume(_ match: (TunnelState) -> Bool) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let index = seen[cursor...].firstIndex(where: match) else { return false }
        cursor = index + 1
        return true
    }
}

/// Hands out a fresh `TunnelFakeConnection` per dial, and can be told which
/// attempt numbers throw instead.
final class TunnelFakeConnections: @unchecked Sendable {
    private let lock = NSLock()
    private var connections: [TunnelFakeConnection] = []
    private var attempts = 0
    private var failures: [Int: any Error] = [:]

    var made: [TunnelFakeConnection] {
        lock.lock()
        defer { lock.unlock() }
        return connections
    }

    func failAttempts(_ numbers: [Int], with error: any Error) {
        lock.lock()
        for number in numbers { failures[number] = error }
        lock.unlock()
    }

    var connect: TunnelRunner.Connect {
        { [self] _ in
            let planned: (any Error)? = lock.withLock {
                attempts += 1
                return failures[attempts]
            }
            if let planned { throw planned }
            let connection = TunnelFakeConnection()
            lock.withLock { connections.append(connection) }
            return connection
        }
    }
}

/// An SSH connection that never dials anything: it remembers the runner's
/// disconnect handler so a test can drop the connection by hand, and counts
/// its own `disconnect()`.
final class TunnelFakeConnection: TunnelSSHConnection, @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable () -> Void)?
    private var disconnects = 0

    var disconnectCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return disconnects
    }

    func onDisconnect(_ handler: @escaping @Sendable () -> Void) {
        lock.withLock { self.handler = handler }
    }

    /// The transport drop a real connection reports through Citadel's own
    /// close future.
    func drop() {
        let handler = lock.withLock { self.handler }
        handler?()
    }

    func openDirectTCPIP(host: String, port: Int) async throws -> Channel {
        throw TunnelFailure.channelOpenFailed(reason: "the fake connection opens no channels")
    }

    func withRemotePortForward(
        bind: String, port: Int, onOpen: @escaping @Sendable (Int) -> Void,
        handleChannel: @escaping @Sendable (Channel) async throws -> Void
    ) async throws {
        throw TunnelFailure.bindFailed(reason: "the fake connection forwards nothing")
    }

    func disconnect() async {
        lock.withLock { disconnects += 1 }
    }
}

/// Builds a `TunnelFakeRuntime` per start, remembering the kind it was asked for
/// and the seams it was handed.
final class TunnelFakeRuntimes: TunnelRuntimeFactory, @unchecked Sendable {
    private let lock = NSLock()
    private let port: Int
    private let firstStopGate: TunnelLatch?
    private var runtimes: [TunnelFakeRuntime] = []
    private var kinds: [TunnelProfile.Kind] = []

    /// - Parameter firstStopGate: when given, the FIRST runtime's `stop()`
    ///   parks on it. That is what holds `TunnelRunner.stop()` suspended at
    ///   `await running?.value` for as long as a test needs, which is the
    ///   only way to drive the start-during-stop window deliberately rather
    ///   than by racing the scheduler.
    init(boundPort: Int, firstStopGate: TunnelLatch? = nil) {
        port = boundPort
        self.firstStopGate = firstStopGate
    }

    var made: [TunnelFakeRuntime] {
        lock.lock()
        defer { lock.unlock() }
        return runtimes
    }

    var startedKinds: [TunnelProfile.Kind] {
        lock.lock()
        defer { lock.unlock() }
        return kinds
    }

    func start(
        _ kind: TunnelProfile.Kind, over connection: any TunnelSSHConnection,
        observer: @escaping TunnelConnectionObserver, onEnded: @escaping @Sendable () -> Void
    ) async throws -> any TunnelRuntime {
        let gate = lock.withLock { runtimes.isEmpty ? firstStopGate : nil }
        let runtime = TunnelFakeRuntime(
            port: port, observer: observer, onEnded: onEnded, stopGate: gate)
        lock.withLock {
            runtimes.append(runtime)
            kinds.append(kind)
        }
        return runtime
    }
}

final class TunnelFakeRuntime: TunnelRuntime, @unchecked Sendable {
    private let lock = NSLock()
    private let port: Int
    private var stops = 0
    private var stopsEntered = 0
    private let stopGate: TunnelLatch?
    /// The runner's own connection observer, so a test can report an
    /// accepted connection without a socket.
    let observer: TunnelConnectionObserver?
    private let onEnded: @Sendable () -> Void

    init(
        port: Int, observer: @escaping TunnelConnectionObserver,
        onEnded: @escaping @Sendable () -> Void, stopGate: TunnelLatch? = nil
    ) {
        self.port = port
        self.observer = observer
        self.onEnded = onEnded
        self.stopGate = stopGate
    }

    var boundPort: Int? { port }

    /// How many `stop()` calls have COMPLETED.
    var stopCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return stops
    }

    /// How many `stop()` calls have been ENTERED — which for a gated
    /// runtime is the only observable that says the teardown is parked
    /// rather than finished.
    var stopEntered: Int {
        lock.lock()
        defer { lock.unlock() }
        return stopsEntered
    }

    /// The forward ending by itself, with the SSH connection still up.
    func endOnItsOwn() { onEnded() }

    func stop() async {
        lock.withLock { stopsEntered += 1 }
        await stopGate?.wait()
        lock.withLock { stops += 1 }
    }
}

/// Records what the runner asked to sleep for and returns at once — the
/// backoff is measured by the ASK, never by the clock.
final class TunnelRecordedSleeper: @unchecked Sendable {
    private let lock = NSLock()
    private var durations: [Duration] = []

    var slept: [Duration] {
        lock.lock()
        defer { lock.unlock() }
        return durations
    }

    var sleep: TunnelRunner.Sleeper {
        { [self] duration in
            lock.withLock { durations.append(duration) }
        }
    }
}

/// Parks until the calling task is cancelled, and counts both. What
/// `stopDuringBackoffEndsTheRun` needs: a backoff that is genuinely in
/// flight, and a record that `stop()` is what ended it.
final class TunnelParkingSleeper: @unchecked Sendable {
    private let lock = NSLock()
    private var enteredCount = 0
    private var cancelledCount = 0

    var entered: Int {
        lock.lock()
        defer { lock.unlock() }
        return enteredCount
    }

    var cancelled: Int {
        lock.lock()
        defer { lock.unlock() }
        return cancelledCount
    }

    var sleep: TunnelRunner.Sleeper {
        { [self] _ in
            lock.withLock { enteredCount += 1 }
            do {
                // A long park, ended by cancellation rather than by
                // elapsing: no ceiling is asserted on it, and the test that
                // uses it cancels within microseconds.
                try await Task.sleep(for: .seconds(3600))
            } catch {
                lock.withLock { cancelledCount += 1 }
                throw error
            }
        }
    }
}

/// A latch a test opens by hand, awaited without throwing.
///
/// `try?` around the sleep on purpose: what waits on this is a teardown
/// running inside an ALREADY-CANCELLED task (`TunnelRunner.stop()` cancels
/// the run task before its `releaseCurrent()` runs), so a wait that
/// propagated cancellation would return immediately and the window this
/// exists to hold open would never open. No deadline of its own — the
/// suite's `.timeLimit` ends a latch nobody releases.
final class TunnelLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var opened = false

    var isOpen: Bool {
        lock.lock()
        defer { lock.unlock() }
        return opened
    }

    func release() {
        lock.withLock { opened = true }
    }

    func wait() async {
        while !isOpen {
            try? await Task.sleep(for: .milliseconds(1))
        }
    }
}

/// A counter a test double bumps and a test polls on — the smallest thing
/// that turns "has the dial been entered yet" into an `await`.
final class TunnelCallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }

    func record() {
        lock.withLock { calls += 1 }
    }
}
