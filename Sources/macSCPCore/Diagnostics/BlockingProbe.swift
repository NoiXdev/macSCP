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
        // Armed BEFORE the work starts, and called off when the work wins:
        // an uncalled-off deadline holds the `OneShot` it captured until it
        // passes, and there is no reason to leave a set of them behind when
        // cancelling is one line. Arming it first only makes the limit
        // stricter — it counts from before the work is submitted, never from
        // after — and an answer that arrives before the continuation exists
        // is held by the `OneShot` rather than dropped.
        //
        // `DeadlineTimer`, NOT `DispatchQueue.global().asyncAfter`: the
        // global queue draws from the kernel's constrained workqueue pool,
        // and a deadline that needs a thread from a pool this process has
        // already filled does not fire. The measurement, the alternatives
        // weighed against it and what the thread costs are all in
        // `DeadlineTimer`'s own doc comment.
        let expiry = DeadlineTimer.shared.schedule(after: timeout) { once.deliver(nil) }
        defer { DeadlineTimer.shared.cancel(expiry) }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
                once.arm(continuation)
                // The work's own queue is private and therefore OVERCOMMIT,
                // which is why it starts where the global queue's timer did
                // not: measured 2026-09-25 with 80 blocks parked on the
                // global queue, a fresh queue's first block ran in
                // 0.3–1.3 ms, in 4 of 4 runs. It is not unbounded —
                // `kern.wq_max_threads` (512 here) bounds overcommit threads
                // too — but reaching that takes hundreds of simultaneously
                // blocked queues, and a diagnosis runs a handful.
                DispatchQueue(label: label).async { once.deliver(body()) }
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
        // A timer off the cooperative pool, NOT a `Task.sleep` on another
        // task. A deadline that waits for a cooperative-pool thread before it
        // can start counting is not a deadline: measured under the full suite
        // (a saturated pool), a `Task.detached` sleep of 1 s let a 3 s probe
        // run to completion, because the task carrying the sleep did not
        // start until the pool had room.
        //
        // It was `DispatchQueue.global().asyncAfter` until 2026-09-25, with a
        // comment claiming that pool "overcommits past the core count" and so
        // fires on time at this scale. It does not overcommit: the global
        // queues draw from the kernel's CONSTRAINED pool
        // (`kern.wq_max_constrained_threads`, 64 on the development machine),
        // and blocked callers hold those threads. Measured that day: with 80
        // blocks parked on that pool a 0.3 s `asyncAfter` had not fired 5 s
        // later, in 4 of 4 runs. `DeadlineTimer` fires on a thread of the
        // process's own, which no pool can refuse it — the full measurement,
        // the alternatives weighed against it and the cost are in its doc
        // comment.
        let expiry = DeadlineTimer.shared.schedule(after: timeout) { once.deliver(nil) }
        defer {
            work.cancel()
            DeadlineTimer.shared.cancel(expiry)
        }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
                once.arm(continuation)
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
