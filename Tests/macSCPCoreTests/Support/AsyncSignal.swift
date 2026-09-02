import Foundation
import Synchronization

/// A one-shot latch that any thread can raise and `async` code can await —
/// the `await` replacement for a `DispatchSemaphore` a test would otherwise
/// `wait()` on from a cooperative-pool thread (see CLAUDE.md, "Tests never
/// block the cooperative pool").
///
/// Three properties the semaphore it replaces also had, and which the call
/// sites depend on:
///
/// - **Latching, not edge-triggered.** A `signal()` that lands before anyone
///   waits still satisfies every later `wait()`. `LoopbackTLSStub`'s listener
///   can become ready before the initializer reaches its wait.
/// - **Several waits per signal.** `EmbeddedKeyPorterTests` waits twice on
///   one signal: once for the bounded expectation, and again after unblocking
///   a FIFO it had to open to release the stuck reader.
/// - **Cancellation is its own answer.** A `DispatchSemaphore` cannot be
///   cancelled, so its caller never had to distinguish the case. An
///   `AsyncStream` finishes when its awaiting task is cancelled exactly as it
///   does when someone finishes it, so a wait built on one and reporting a
///   plain `Bool` reports "raised" for a cancellation — see `WaitOutcome`.
///
/// Each waiter gets its own `AsyncStream`, so a waiter whose task is
/// cancelled unwinds through the stream's own cancellation handling rather
/// than through a continuation this type would have to track — there is no
/// continuation here that a cancellation could strand.
final class AsyncSignal: Sendable {
    /// How a wait ended. Three cases, because two cannot express the
    /// difference between "the thing I waited for happened" and "nobody is
    /// waiting for it any more" — and a caller that conflates them acts on a
    /// child process that is still running.
    enum WaitOutcome: Sendable, Equatable {
        case signalled
        case timedOut
        case cancelled
    }

    private struct State {
        var isRaised = false
        var waiters: [UUID: AsyncStream<Void>.Continuation] = [:]
    }

    /// `Mutex`, not `NSLock`: `NSLock.lock()` is unavailable from an
    /// asynchronous context, and `wait()` is one.
    private let state = Mutex(State())

    /// Whether the latch has been raised, without waiting for it. Lets a
    /// caller skip work that only makes sense while the thing is pending —
    /// `SubprocessRunner` uses it to avoid signalling a pid that has already
    /// been reaped.
    var isRaised: Bool { state.withLock { $0.isRaised } }

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
        // Yield BEFORE finishing: receiving an element is the only thing that
        // tells a waiter it was released rather than cancelled, since a
        // cancelled `AsyncStream` iteration ends the same way a finished one
        // does — with no element.
        for continuation in released {
            continuation.yield(())
            continuation.finish()
        }
    }

    /// Suspends until the latch is raised or this task is cancelled. Nothing
    /// is parked: the suspension is an `AsyncStream` the signal finishes.
    ///
    /// Never returns `.timedOut` — it has no bound.
    func wait() async -> WaitOutcome {
        guard !Task.isCancelled else { return .cancelled }
        let identifier = UUID()
        let stream: AsyncStream<Void>? = state.withLock { state in
            guard !state.isRaised else { return nil }
            let made = AsyncStream<Void>.makeStream(of: Void.self)
            state.waiters[identifier] = made.continuation
            return made.stream
        }
        guard let stream else { return .signalled }

        var released = false
        for await _ in stream {
            released = true
            break
        }

        _ = state.withLock { $0.waiters.removeValue(forKey: identifier) }
        return released ? .signalled : .cancelled
    }

    /// Suspends until the latch is raised, `timeout` elapses, or this task is
    /// cancelled, and answers which of the three happened.
    func wait(timeout: Duration) async -> WaitOutcome {
        await Self.race(timeout: timeout) { await self.wait() }
    }

    /// Runs `work` against a deadline, and reports which of the three ended
    /// the wait.
    ///
    /// The bound is a `Task.sleep` racing `work` inside a task group, so the
    /// deadline costs a suspension rather than a thread. The loser is
    /// cancelled once the winner is known, and reports `.cancelled` — which
    /// is discarded, because the group's first result has already been taken.
    ///
    /// The case that makes the third outcome necessary is the race that
    /// starts, or becomes, cancelled from OUTSIDE: then both children are
    /// cancelled, `Task.sleep` throws instead of returning `.timedOut`, and
    /// whichever answers first says `.cancelled`. Without that case the
    /// caller would read an outside cancellation as a bound it never set.
    static func race(
        timeout: Duration, _ work: @escaping @Sendable () async -> WaitOutcome
    ) async -> WaitOutcome {
        await withTaskGroup(of: WaitOutcome.self, returning: WaitOutcome.self) { group in
            group.addTask { await work() }
            group.addTask {
                do {
                    try await Task.sleep(for: timeout)
                    return .timedOut
                } catch {
                    // `Task.sleep` throws only on cancellation.
                    return .cancelled
                }
            }
            let first = await group.next() ?? .cancelled
            group.cancelAll()
            return first
        }
    }
}
