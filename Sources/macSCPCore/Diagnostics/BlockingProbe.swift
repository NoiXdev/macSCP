import Foundation
import Synchronization

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
///
/// **It keeps that plain `nil` where `DetachedProbe` no longer does**, and
/// the measurement behind the split is in `ProbeStart`'s doc comment: this
/// type's private queue is overcommit, so its body starts in single-digit
/// milliseconds on a machine where a detached body waits nine seconds for a
/// cooperative-pool thread. A deadline here bounds the WORK; there it also
/// bounded the queueing.
enum BlockingProbe {
    /// Returns `body`'s result, or `nil` when the deadline expired or the
    /// calling task was cancelled first. The two are not distinguished here:
    /// the caller knows which it is by asking `Task.isCancelled`.
    static func run<T: Sendable>(
        label: String, timeout: Duration, _ body: @escaping @Sendable () -> T
    ) async -> T? {
        let once = OneShot<T?>()
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
///
/// **Three outcomes, not two** (maintainer's decision, 2026-09-25). The
/// deadline is armed when the probe is CREATED, so on a loaded machine it
/// can expire before the body has begun. `ProbeAnswer` says which happened;
/// `ProbeStart`'s doc comment carries the measurement and why
/// `BlockingProbe` needs none of it. **The limit itself did not move**: the
/// deadline is armed at the same point and fires at the same moment, and a
/// probe the pool never starts still ends by it. What changed is only what
/// the row SAYS.
enum DetachedProbe {
    /// How the probe's body is put on a thread of its own — `Task.detached`
    /// in production, and `detach` below is that default.
    ///
    /// A parameter rather than a hardcoded call, because the one thing this
    /// type reports that nothing else can observe — a body the pool never
    /// started — is otherwise measurable only by STARVING the cooperative
    /// pool, which ends every test sharing the process: the 2026-09-25
    /// investigation had to run 200 CPU-bound tasks beside the case it was
    /// reproducing, and deleted the harness afterwards. A launcher that
    /// HOLDS the body states the same fact with no load at all.
    typealias Launch = @Sendable (@escaping @Sendable () async -> Void) -> Task<Void, Never>

    /// The production launcher. Detached, not a child: a child inherits the
    /// caller's isolation, so the probe would run ON the diagnostics actor
    /// and serialize with the very deadline that is supposed to bound it.
    static let detach: Launch = { body in Task.detached(operation: body) }

    /// Returns `body`'s result, or — when the deadline expired or the
    /// calling task was cancelled first — which side of its own start the
    /// probe was on (`ProbeStart`). The caller tells a deadline from a
    /// cancellation the way `BlockingProbe.run`'s does, by asking
    /// `Task.isCancelled`.
    static func run<T: Sendable>(
        timeout: Duration, launch: Launch = DetachedProbe.detach,
        _ body: @escaping @Sendable () async -> T
    ) async -> ProbeAnswer<T> {
        let once = OneShot<ProbeAnswer<T>>()
        // Raised as the body's FIRST statement, and READ at the moment the
        // deadline fires rather than afterwards. "Had the body begun when
        // the deadline expired?" is a question about one instant; a body
        // that begins a microsecond later must not turn a row that has
        // already been settled into a claim about the server.
        let begun = Mutex(false)
        let start: @Sendable () -> ProbeStart = {
            begun.withLock { $0 } ? .began : .neverBegan
        }
        let work = launch {
            begun.withLock { $0 = true }
            once.deliver(.answered(await body()))
        }
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
        let expiry = DeadlineTimer.shared.schedule(after: timeout) {
            once.deliver(.unanswered(start()))
        }
        defer {
            work.cancel()
            DeadlineTimer.shared.cancel(expiry)
        }
        return await withTaskCancellationHandler {
            await withCheckedContinuation {
                (continuation: CheckedContinuation<ProbeAnswer<T>, Never>) in
                once.arm(continuation)
            }
        } onCancel: {
            once.deliver(.unanswered(start()))
        }
    }
}

/// Whether a probe's body had BEGUN when its deadline (or a cancellation)
/// settled the call.
///
/// The distinction is not a nicety. `DetachedProbe` arms its deadline when
/// the probe is CREATED, and a `Task.detached` body reaches its first
/// statement only once the cooperative pool — which is FIFO, non-preemptive
/// and exactly as wide as the machine has cores — has a thread for it.
/// Measured 2026-09-27 on the ten-core development machine, in a standalone
/// binary, with 200 CPU-bound cooperative tasks filling the pool (they
/// drained in 10.006-10.041 s): a detached body reached its first statement
/// **9.483 / 9.490 / 9.494 s** after its creation, 3 of 3 runs. So a deadline
/// can expire over work that never began, and a row reporting that as a
/// timeout is an accusation against a server this Mac never contacted.
///
/// **`BlockingProbe` does not share it**, and that was measured in the same
/// binary and the same three runs rather than assumed: its body goes onto a
/// PRIVATE `DispatchQueue`, which is overcommit and so draws a thread from
/// the kernel whether or not the cores are busy. Under the identical load
/// its first block ran **0.000116 / 0.002357 / 0.006739 s** after
/// submission — four orders of magnitude, and the same answer the
/// 2026-09-24/25 measurement gave against a parked global queue (0.3-1.3 ms,
/// 4 of 4). It is not unbounded — `kern.wq_max_threads`, 512 here, bounds
/// overcommit threads too — but reaching that needs hundreds of
/// simultaneously blocked queues, and a diagnosis runs a handful. So
/// `BlockingProbe.run` keeps its `T?`.
enum ProbeStart: Sendable, Equatable {
    /// The body had begun. Something was measured, and it overran.
    case began
    /// The body had NOT begun: nothing was measured, and nothing was sent.
    case neverBegan
}

/// What a bounded probe answered: the body's result, or — when the deadline
/// or a cancellation settled the call first — which side of its own start
/// the body was on.
enum ProbeAnswer<Value: Sendable>: Sendable {
    case answered(Value)
    case unanswered(ProbeStart)

    /// The result, or `nil` when there was none — the `T?` this type
    /// replaced. For the callers whose reader never learns which of the two
    /// unanswered cases it was: `HostAddressLookup`, whose one reader is a
    /// form's address menu, and `AddressNames`, whose is a `no answer` cell
    /// beside an address that WAS resolved. Neither is a step outcome, and
    /// neither says anything about a server.
    var value: Value? {
        guard case .answered(let value) = self else { return nil }
        return value
    }
}

extension ProbeAnswer: Equatable where Value: Equatable {}

/// Resumes a continuation exactly once, whichever of the three racers gets
/// there first — the work, the deadline, or a cancellation.
///
/// The cancellation handler can fire BEFORE the continuation exists (a task
/// cancelled between entering `withTaskCancellationHandler` and the
/// `withCheckedContinuation` closure running), so an answer that arrives
/// early is held rather than dropped. Without that, the continuation would
/// never be resumed and the caller would hang on a cancelled task.
private final class OneShot<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Never>?
    private var isSettled = false
    private var early: Early?

    /// The early answer, boxed, so ONE field carries both facts: whether an
    /// answer arrived before the continuation existed, and what it was.
    ///
    /// A bare `Value?` cannot, because `Value` is itself an Optional for
    /// `BlockingProbe` (`OneShot<T?>`) — `nil` would be both "nothing
    /// arrived" and "the deadline delivered nil". That used to be a `Bool`
    /// beside a `Value?`, which is two fields holding one invariant; the
    /// failure it allowed is the worst kind this type has — the pair read
    /// apart, the continuation stored and never resumed, a HANG rather than
    /// a red. One field cannot come apart.
    private struct Early {
        let value: Value
    }

    func arm(_ continuation: CheckedContinuation<Value, Never>) {
        lock.lock()
        if let early {
            self.early = nil
            lock.unlock()
            continuation.resume(returning: early.value)
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    func deliver(_ value: Value) {
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
            early = Early(value: value)
            lock.unlock()
        }
    }
}
