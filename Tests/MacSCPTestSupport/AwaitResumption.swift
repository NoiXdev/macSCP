import NIOConcurrencyHelpers

/// The three states `awaitResumption`/`awaitResumptionThrowing` move
/// through, mirroring `CancellableWaitState` in `AwaitCancellably.swift`:
/// a value can arrive from the body's continuation, cancellation can arrive
/// from `withTaskCancellationHandler`, and only the first of the two may
/// resume the outer wait.
private enum ResumptionWaitState<Value: Sendable>: Sendable {
    /// The payload is the outer continuation, EMPTY until the outer body
    /// stores it — `onCancel` can run before that happens.
    case waiting(CheckedContinuation<Value, any Error>?)
    /// `onCancel` got there first.
    case cancelled
    /// The wrapped body's continuation resumed first.
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
public func awaitResumption<Value: Sendable>(
    _ body: @escaping @Sendable (CheckedContinuation<Value, Never>) -> Void
) async throws -> Value {
    let state = NIOLockedValueBox(ResumptionWaitState<Value>.waiting(nil))

    // Unstructured: this task is the only thing that ever calls `body`,
    // and it is deliberately left running (never cancelled, never awaited
    // to completion by anything but the closure below) when `body` never
    // resumes — the same abandonment `AwaitCancellably.swift` documents
    // for the NIO future it never cancels either.
    let bodyTask = Task<Value, Never> {
        await withCheckedContinuation(body)
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
