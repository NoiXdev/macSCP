import Foundation
import Synchronization

/// A one-shot latch that any thread can raise and `async` code can await —
/// the `await` replacement for a `DispatchSemaphore` a test would otherwise
/// `wait()` on from a cooperative-pool thread (see CLAUDE.md, "Tests never
/// block the cooperative pool").
///
/// Two properties the semaphore it replaces also had, and which the call
/// sites depend on:
///
/// - **Latching, not edge-triggered.** A `signal()` that lands before anyone
///   waits still satisfies every later `wait()`. `LoopbackTLSStub`'s listener
///   can become ready before the initializer reaches its wait.
/// - **Several waits per signal.** `EmbeddedKeyPorterTests` waits twice on
///   one signal: once for the bounded expectation, and again after unblocking
///   a FIFO it had to open to release the stuck reader.
///
/// Each waiter gets its own `AsyncStream`, so a waiter whose task is
/// cancelled unwinds through the stream's own cancellation handling rather
/// than through a continuation this type would have to track — there is no
/// continuation here that a cancellation could strand.
final class AsyncSignal: Sendable {
    private struct State {
        var isRaised = false
        var waiters: [UUID: AsyncStream<Void>.Continuation] = [:]
    }

    /// `Mutex`, not `NSLock`: `NSLock.lock()` is unavailable from an
    /// asynchronous context, and `wait()` is one.
    private let state = Mutex(State())

    /// Raises the latch and releases every waiter. Idempotent, and safe from
    /// any thread — a dispatch queue, a `Process.terminationHandler`, an
    /// `NWListener` state handler.
    func signal() {
        let released = state.withLock { state -> [AsyncStream<Void>.Continuation] in
            guard !state.isRaised else { return [] }
            state.isRaised = true
            let waiters = Array(state.waiters.values)
            state.waiters.removeAll()
            return waiters
        }
        for continuation in released { continuation.finish() }
    }

    /// Suspends until the latch is raised. Nothing is parked: the suspension
    /// is an `AsyncStream` the signal finishes.
    func wait() async {
        let identifier = UUID()
        let stream: AsyncStream<Void>? = state.withLock { state in
            guard !state.isRaised else { return nil }
            let made = AsyncStream<Void>.makeStream(of: Void.self)
            state.waiters[identifier] = made.continuation
            return made.stream
        }
        guard let stream else { return }

        for await _ in stream { break }

        _ = state.withLock { $0.waiters.removeValue(forKey: identifier) }
    }

    /// Suspends until the latch is raised or `timeout` elapses, and answers
    /// which of the two happened — `true` for the signal.
    func wait(timeout: Duration) async -> Bool {
        await Self.race(timeout: timeout) { await self.wait() }
    }

    /// Runs `work` against a deadline. `true` if `work` finished first.
    ///
    /// The bound is a `Task.sleep` racing `work` inside a task group, so the
    /// deadline costs a suspension rather than a thread. The loser is
    /// cancelled once the winner is known; a cancelled `wait()` returns
    /// early, and the `true` it then reports is discarded because the group's
    /// first result has already been taken.
    ///
    /// Shared with `SubprocessRunner`, which races the same way against a
    /// combined "both pipes drained and the child has exited" wait.
    static func race(timeout: Duration, _ work: @escaping @Sendable () async -> Void) async -> Bool {
        await withTaskGroup(of: Bool.self, returning: Bool.self) { group in
            group.addTask {
                await work()
                return true
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
    }
}
