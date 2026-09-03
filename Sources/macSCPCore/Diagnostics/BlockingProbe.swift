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
        // A work item rather than a bare closure so the timer can be called
        // off when the work wins: an uncancelled `asyncAfter` block survives
        // until its deadline, holding the `OneShot` it captured. Harmless at
        // one timer per step, and there is no reason to leave a queue of them
        // behind when cancelling is one line.
        let expiry = DispatchWorkItem { once.deliver(nil) }
        defer { expiry.cancel() }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
                once.arm(continuation)
                DispatchQueue(label: label).async { once.deliver(body()) }
                DispatchQueue.global().asyncAfter(
                    deadline: .now() + timeout.seconds, execute: expiry)
            }
        } onCancel: {
            once.deliver(nil)
        }
    }
}

/// Runs an ASYNC probe under a deadline, and does not wait for it when the
/// deadline wins.
///
/// The shape `withTaskGroup` cannot give: a task group awaits every child
/// before its body's value is returned, so `cancelAll()` bounds the call only
/// for a probe that HONOURS cancellation. Several here do not — Citadel arms
/// an uncancellable 15 s timer the moment `openSFTP` is called
/// (`CitadelFileSystem.disconnect`'s citation), and a `recv` loop on a raw
/// socket honours nothing at all — so a task group would have bounded the
/// reported row while the user watched a spinner for as long as the probe
/// felt like taking.
///
/// **What happens to the abandoned probe.** It is `cancel()`ed — an ASK,
/// which a probe that ignores cancellation ignores — and then left to finish
/// on its own. Its result is delivered into a `OneShot` that has already been
/// settled, so it is dropped; nothing here waits for it, and no continuation
/// is resumed twice. It holds whatever it holds (a socket, a connect
/// attempt) until its own transport gives up.
enum DetachedProbe {
    /// Returns `body`'s result, or `nil` when the deadline expired or the
    /// calling task was cancelled first — the same contract as
    /// `BlockingProbe.run`, and the caller tells the two apart the same way,
    /// by asking `Task.isCancelled`.
    static func run<T: Sendable>(
        timeout: Duration, _ body: @escaping @Sendable () async -> T
    ) async -> T? {
        let once = OneShot<T>()
        // Detached, not a child: a child inherits this actor's isolation, so
        // the probe would run ON the diagnostics actor and serialize with the
        // very deadline that is supposed to bound it.
        let work = Task.detached { once.deliver(await body()) }
        let expiry = DispatchWorkItem { once.deliver(nil) }
        defer {
            work.cancel()
            expiry.cancel()
        }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
                once.arm(continuation)
                // A Dispatch timer, NOT a `Task.sleep` on another task. A
                // deadline that waits for a cooperative-pool thread before it
                // can start counting is not a deadline: measured under the
                // full suite (a saturated pool), a `Task.detached` sleep of
                // 1 s let a 3 s probe run to completion, because the task
                // carrying the sleep did not start until the pool had room.
                //
                // Dispatch's global pool is separate from the cooperative one
                // and overcommits past the core count, which is why it fires
                // on time HERE — at three steps and a handful of addresses.
                // That is a statement about this scale, not a property of
                // Dispatch: the blocking probes in this same file occupy that
                // pool through their own serial queues, and enough
                // simultaneously blocked ones would delay this block too.
                DispatchQueue.global().asyncAfter(
                    deadline: .now() + timeout.seconds, execute: expiry)
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
