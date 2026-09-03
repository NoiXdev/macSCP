import Foundation

/// Runs one blocking socket sequence off the cooperative pool and awaits it
/// with a deadline.
///
/// `getaddrinfo`, `connect` and `poll` block the thread they run on, and
/// Swift's cooperative pool is exactly as wide as the machine has cores — a
/// blocking call on it parks a thread that every other task then cannot have
/// (CLAUDE.md, "Tests never block the cooperative pool"; the rule holds in
/// Sources for the same reason it holds in Tests). So each probe gets a
/// `DispatchQueue` of its own and reaches the caller through a continuation.
///
/// The deadline is a SECOND resumption of the same continuation, not a
/// cancellation of the queue: none of those three calls can be interrupted
/// once entered. `getaddrinfo` in particular runs to its own completion —
/// the queue thread it holds is released whenever the resolver is done with
/// it, and its late answer is dropped. That is the trade this type makes,
/// and it is why the caller gets `nil` rather than a partial result.
enum BlockingProbe {
    /// Returns `body`'s result, or `nil` when the deadline expired or the
    /// calling task was cancelled first. The two are not distinguished here:
    /// the caller knows which it is by asking `Task.isCancelled`.
    static func run<T: Sendable>(
        label: String, timeout: Duration, _ body: @escaping @Sendable () -> T
    ) async -> T? {
        let once = OneShot<T>()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
                once.arm(continuation)
                DispatchQueue(label: label).async { once.deliver(body()) }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout.seconds) {
                    once.deliver(nil)
                }
            }
        } onCancel: {
            once.deliver(nil)
        }
    }
}

/// Resumes a continuation exactly once, whichever of the three racers gets
/// there first — the work, the deadline, or a cancellation.
///
/// The cancellation handler can fire BEFORE the continuation exists (a task
/// cancelled between entering `withTaskCancellationHandler` and the
/// `withCheckedContinuation` closure running), so an answer that arrives
/// early is held rather than dropped. Without that, the continuation would
/// never be resumed and the caller would hang on a cancelled task.
private final class OneShot<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T?, Never>?
    private var isSettled = false
    private var hasEarlyAnswer = false
    private var earlyAnswer: T?

    func arm(_ continuation: CheckedContinuation<T?, Never>) {
        lock.lock()
        if hasEarlyAnswer {
            let answer = earlyAnswer
            hasEarlyAnswer = false
            earlyAnswer = nil
            lock.unlock()
            continuation.resume(returning: answer)
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    func deliver(_ value: T?) {
        lock.lock()
        guard !isSettled else {
            lock.unlock()
            return
        }
        isSettled = true
        if let continuation {
            self.continuation = nil
            lock.unlock()
            continuation.resume(returning: value)
        } else {
            hasEarlyAnswer = true
            earlyAnswer = value
            lock.unlock()
        }
    }
}
