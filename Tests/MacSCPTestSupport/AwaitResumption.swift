import NIOConcurrencyHelpers

/// The three states `awaitResumption`/`awaitResumptionThrowing` move
/// through, mirroring `CancellableWaitState` in `AwaitCancellably.swift`:
/// a value can arrive from the body's continuation, cancellation can arrive
/// from `withTaskCancellationHandler`, and only the first of the two may
/// resume the outer wait. `awaitResumption` (not `awaitResumptionThrowing`,
/// which has no `onCancel` yet) also uses this SAME lock to gate whether
/// `body` is invoked at all, AND — fix round 3, see `awaitResumption`'s own
/// doc comment — to let an optional `tryImmediate` commit straight to
/// `.done` without ever creating `body`'s `bodyTask` at all. One lock,
/// three decisions, not three locks.
/// What the operation closure decided, still holding `state`'s lock at
/// the moment it decided — file-scope rather than nested inside
/// `awaitResumption` because Swift does not allow a type, generic or not,
/// to nest inside a generic function. `Value` (not `Void`) because
/// `.committed` carries `tryImmediate`'s result straight through to the
/// resume call, with no intermediate storage.
private enum AwaitResumptionDecision<Value> {
    case committed(Value)
    case queued
    case alreadyOver
}

private enum ResumptionWaitState<Value: Sendable>: Sendable {
    /// The payload is the outer continuation, EMPTY until the outer body
    /// stores it — `onCancel` can run before that happens.
    case waiting(CheckedContinuation<Value, any Error>?)
    /// `onCancel` got there first.
    case cancelled
    /// A value arrived first — either `body`'s continuation resumed (the
    /// queued path), or `tryImmediate` committed synchronously (the fast
    /// path, fix round 3). Both reach this SAME case, because from
    /// `onCancel`'s side they must be indistinguishable: either way, the
    /// wait is over and there is nothing left to cancel.
    case done
}

/// Runs `body` with a bare `CheckedContinuation`, the way a hand-rolled test
/// double resumes a waiter, but answers `Task` cancellation instead of
/// parking forever when `body` never calls its continuation.
///
/// `docs/BACKLOG.md`, "A test parked on a bare continuation outlives its
/// time limit": a bare `withCheckedContinuation`/`withCheckedThrowingContinuation`
/// in a test ignores `Task` cancellation, so Swift Testing's `.timeLimit`
/// cancels the test's task but never unparks the continuation underneath
/// it — the "exceeded" report is not the process actually stopping. This
/// function is the cancellation-aware replacement: every bare continuation
/// wait in `Tests/` (outside this file and outside a file whose enclosing
/// comment carries the sentence "the continuation IS the API under test
/// here") goes through it instead.
///
/// `body`'s own continuation cannot itself observe cancellation — it is a
/// `CheckedContinuation<Value, Never>`, exactly the bare shape being
/// replaced. So `body` is not run against the continuation this function
/// itself awaits; it is run against a **second**, independent continuation
/// on an unstructured child `Task`, and this function awaits a **third**
/// continuation that either that child or `onCancel` resumes — whichever
/// gets there first, guarded by `state` the same way `awaitCancellably`
/// guards its race between a future completing and a cancellation. If
/// `body` never resumes, the child `Task` and its continuation are simply
/// abandoned: still suspended, not blocking any thread, so the cooperative
/// pool stays free (CLAUDE.md, "Tests never block the cooperative pool").
///
/// A body that genuinely never resumes makes the Swift runtime print
/// "SWIFT TASK CONTINUATION MISUSE: ... leaked its continuation without
/// resuming it" once the process tears down the still-suspended child task
/// — observed from `AwaitResumptionTests`' own cancellation cases. That
/// print is expected here, not a bug: it is the runtime's own diagnostic
/// for exactly the shape this function accepts (an abandoned, never-resumed
/// continuation) rather than evidence of a crash or a hang, and the CI
/// warning gate does not see it — it scans compiler `file:line:col:
/// warning:` lines, not a runtime print with neither.
///
/// `onCancel`, when given, runs synchronously as part of a WINNING
/// cancellation — the once-latch below decides who gets to run it, so it
/// never runs after `body` (or `tryImmediate`) has already committed a
/// value, and never runs twice. It exists for a caller that stores a
/// token derived from `body`'s continuation somewhere OUTSIDE this
/// function's own state — `AgentEnvLock.acquire()` appends its
/// continuation to a FIFO `waiters` list, and a cancelled wait must remove
/// that entry before this function's own `CancellationError` reaches the
/// caller, or a later, unrelated `release()` pops the stale entry, "hands
/// off" the lock to a task that no longer exists, and never clears
/// `isLocked` — a permanent leak in a process-wide `static let shared`
/// lock.
///
/// `tryImmediate`, when given, is an atomic "check and maybe commit right
/// now" callback — `AgentEnvLock.acquire()`'s own fast (uncontested) path:
/// take the lock and return a value if it was free, or return `nil` if it
/// was not. It runs SYNCHRONOUSLY, under the SAME `state.withLockedValue`
/// this function uses for every other decision, and a value it returns
/// transitions `state` straight to `.done` in that one critical section —
/// `body` is never even created for this call, and `onCancel`, if a
/// cancellation lands a moment later, finds `.done` and does nothing.
///
/// Fix history, all on 2026-09-05 (docs/BACKLOG.md's own entry), each
/// found in code review of the one before:
///
/// - **Round 1** added `onCancel` but tied it to whether a continuation
///   had ALREADY been stored in `state` — `waiter != nil` was the
///   once-latch. A cancellation winning before the operation closure had
///   stored anything read as "nothing to clean up" and skipped `cleanup`
///   while `body` (on `bodyTask`, unstructured, inheriting no
///   cancellation) registered later anyway: orphaned.
/// - **Round 2** made the once-latch "did THIS call win the transition to
///   `.cancelled`" instead, and moved `body`'s own invocation inside the
///   same locked section, gated on `state` still being `.waiting` — so
///   `body` and the cancellation transition could no longer interleave.
///   This closed the gap for callers where every commitment is REVOCABLE
///   (a queued token `cleanup` can always remove).
/// - **Round 3** (this one) is for a caller whose FAST path commits
///   something IRREVOCABLE — `AgentEnvLock`'s uncontested `acquire()` sets
///   `isLocked = true` and hands the lock over immediately, and no
///   `cleanup` closure can undo "the lock is already held" the way it
///   undoes "remove me from the queue". Before this round, that fast path
///   ran as an ordinary `body`: it flipped `isLocked` and resumed its OWN
///   `bodyTask` continuation, but `state` itself stayed `.waiting` until a
///   SEPARATE monitor `Task` later awaited `bodyTask.value` and only THEN
///   transitioned to `.done`. A cancellation landing in that window found
///   `state` still `.waiting`, transitioned it to `.cancelled`, and threw
///   `CancellationError` at the caller — who now believes it never
///   acquired the lock, while `isLocked` is stuck at `true` forever, held
///   by nobody. `tryImmediate` closes this by making the commitment and
///   the `state` transition the SAME atomic step, so there is no window
///   between them for a cancellation to land in.
///
/// The four orders `state` can see a value and a cancellation arrive in,
/// traced in prose (`AwaitResumptionTests`, `AgentEnvLockTests` pin all
/// four):
///
/// 1. **Cancel before register.** The task is already cancelled when
///    `withTaskCancellationHandler` is entered, so `onCancel` fires before
///    the operation closure has run at all. `state` is still
///    `.waiting(nil)`; the transition to `.cancelled` succeeds, `cleanup`
///    runs (there is nothing for it to find yet — a harmless no-op), and
///    there is no continuation to resume. The operation closure runs
///    afterward, finds `state` already `.cancelled`, and throws
///    immediately. Neither `tryImmediate` nor `body` is ever called — no
///    side effect ever happens, so there is nothing to undo.
/// 2. **Cancel while queued.** The operation closure runs first;
///    `tryImmediate` is absent or returns `nil` (no capacity), so `state`
///    becomes `.waiting(theOuterContinuation)` and `body` is invoked
///    (queuing logic only, for `AgentEnvLock`) to register a REVOCABLE
///    token. A cancellation arriving afterward transitions `state` to
///    `.cancelled`, and `cleanup` removes that token before the caller
///    ever sees the thrown `CancellationError` — round 2's fix, unchanged.
/// 3. **Cancel after the fast path commits.** The operation closure runs
///    first; `tryImmediate` succeeds (the resource was free), so `state`
///    goes straight from `.waiting(nil)` to `.done` in that SAME locked
///    step, and the outer continuation resumes with the value immediately
///    — the caller already holds what it asked for. A cancellation
///    arriving afterward finds `state` at `.done`, changes nothing, and
///    calls neither `cleanup` nor a resume — the value was already
///    delivered before the cancellation was even processed, so there is
///    nothing left to cancel. This is round 3's fix: before it, this
///    order shared `state`'s fate with order 2 even though the
///    commitment itself was irrevocable.
/// 4. **Resume then cancel (queued path).** `body`'s queued continuation
///    is resumed later (by whatever external event `cleanup` would have
///    pre-empted — `AgentEnvLock.release()`, for instance); the monitor
///    `Task` picks up the value and transitions `state` from
///    `.waiting(outer)` to `.done`, resuming the outer continuation. A
///    cancellation arriving afterward finds `.done`, same as order 3's
///    tail — proven already by `cancellingAfterTheValueAlreadyArrivedIsANoOpNotATrap`.
public func awaitResumption<Value: Sendable>(
    _ body: @escaping @Sendable (CheckedContinuation<Value, Never>) -> Void,
    onCancel cleanup: (@Sendable () -> Void)? = nil,
    tryImmediate: (@Sendable () -> Value?)? = nil
) async throws -> Value {
    let state = NIOLockedValueBox(ResumptionWaitState<Value>.waiting(nil))

    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Value, any Error>) in
            let decision = state.withLockedValue { current -> AwaitResumptionDecision<Value> in
                switch current {
                case .waiting:
                    if let tryImmediate, let value = tryImmediate() {
                        current = .done
                        return .committed(value)
                    }
                    current = .waiting(continuation)
                    return .queued
                case .cancelled, .done:
                    return .alreadyOver
                }
            }
            switch decision {
            case .committed(let value):
                continuation.resume(returning: value)
            case .alreadyOver:
                continuation.resume(throwing: CancellationError())
            case .queued:
                // Unstructured: this task is the only thing that ever calls
                // `body`, and it is deliberately left running — never
                // cancelled, never awaited to completion by anything but
                // the monitor task below — in TWO cases: `body` never
                // resumes (the same abandonment `AwaitCancellably.swift`
                // documents for the NIO future it never cancels either),
                // or `state` is already `.cancelled` by the time this runs
                // and `body` is skipped entirely (round 2).
                let bodyTask = Task<Value, Never> {
                    await withCheckedContinuation { (bodyContinuation: CheckedContinuation<Value, Never>) in
                        state.withLockedValue { current in
                            // Only calls `body` while `current` is still
                            // `.waiting` — `.cancelled` means the transition
                            // in `onCancel` already won the race, and
                            // `body`'s own registration must not happen
                            // after that. `.done` cannot appear here: it
                            // requires a value to have already arrived,
                            // which — on the `.queued` path — requires
                            // `body` to have already been called once.
                            guard case .waiting = current else { return }
                            body(bodyContinuation)
                        }
                    }
                }
                Task {
                    let value = await bodyTask.value
                    let waiter = state.withLockedValue {
                        (current) -> CheckedContinuation<Value, any Error>? in
                        guard case .waiting(let stored) = current else { return nil }
                        current = .done
                        return stored
                    }
                    waiter?.resume(returning: value)
                }
            }
        }
    } onCancel: {
        let (transitioned, waiter) = state.withLockedValue {
            (current) -> (Bool, CheckedContinuation<Value, any Error>?) in
            switch current {
            case .waiting(let stored):
                current = .cancelled
                return (true, stored)
            case .cancelled, .done:
                return (false, nil)
            }
        }
        // `transitioned` IS the once-latch: only the caller that actually
        // moved `.waiting` to `.cancelled` reaches here, so `cleanup` runs
        // at most once, and never after a value has already committed —
        // whether via `body`'s resume (`.done`, order 4) or via
        // `tryImmediate` (`.done`, order 3) — both leave `transitioned`
        // false. This does NOT require a continuation to have been stored
        // yet either (order 1): a cancellation that wins before the
        // operation closure has even run must still fire `cleanup`,
        // because `bodyTask`'s own gate reads this SAME `.cancelled` value
        // to decide whether to call `body` at all.
        if transitioned {
            cleanup?()
        }
        waiter?.resume(throwing: CancellationError())
    }
}

/// The throwing-body sibling of `awaitResumption`: `body` gets a
/// `CheckedContinuation<Value, any Error>` — the bare shape used by tests
/// that resume with a thrown error rather than only a value — with the
/// same cancellation guarantee. `bodyTask` carries a `Result` rather than
/// throwing itself, because `Task<Value, Never>`'s cancellation-free
/// abandonment (the same property `awaitResumption` relies on above) needs
/// a `Never`-failure task; the error `body` threw is recovered from the
/// `Result` once `bodyTask` completes, not lost.
public func awaitResumptionThrowing<Value: Sendable>(
    _ body: @escaping @Sendable (CheckedContinuation<Value, any Error>) -> Void
) async throws -> Value {
    let state = NIOLockedValueBox(ResumptionWaitState<Value>.waiting(nil))

    let bodyTask = Task<Result<Value, any Error>, Never> {
        do {
            return .success(try await withCheckedThrowingContinuation(body))
        } catch {
            return .failure(error)
        }
    }

    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Value, any Error>) in
            let alreadyOver = state.withLockedValue { current -> Bool in
                switch current {
                case .waiting:
                    current = .waiting(continuation)
                    return false
                case .cancelled, .done:
                    return true
                }
            }
            guard !alreadyOver else {
                continuation.resume(throwing: CancellationError())
                return
            }
            Task {
                let result = await bodyTask.value
                let waiter = state.withLockedValue {
                    (current) -> CheckedContinuation<Value, any Error>? in
                    guard case .waiting(let stored) = current else { return nil }
                    current = .done
                    return stored
                }
                waiter?.resume(with: result)
            }
        }
    } onCancel: {
        let waiter = state.withLockedValue { (current) -> CheckedContinuation<Value, any Error>? in
            switch current {
            case .waiting(let stored):
                current = .cancelled
                return stored
            case .cancelled, .done:
                return nil
            }
        }
        waiter?.resume(throwing: CancellationError())
    }
}
