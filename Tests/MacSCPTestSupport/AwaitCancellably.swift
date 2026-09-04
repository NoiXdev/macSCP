import NIOConcurrencyHelpers
import NIOCore

/// The three states `awaitCancellably` moves through. At file scope because
/// a generic function cannot nest a type; it belongs to that function alone.
private enum CancellableWaitState<Value: Sendable>: Sendable {
    /// Before the race is decided. The payload is the parked continuation,
    /// and it is EMPTY until the body stores it — `onCancel` can run first.
    case waiting(CheckedContinuation<Value, any Error>?)
    /// `onCancel` got there first.
    case cancelled
    /// `whenComplete` got there first.
    case done
}

/// Awaits `future` in a way that answers task cancellation, so a future that
/// never completes ends this test instead of parking the run.
///
/// `EventLoopFuture.get()` cannot do that, and says so: NIO documents it as
/// violating "Structured Concurrency because cancellation isn't respected"
/// (`swift-nio`, `Sources/NIOCore/AsyncAwaitSupport.swift`). Both sides of
/// that were measured here on 2026-09-04, by planting a `connectTimeout`
/// past the harness limit and timing the run:
///
/// - Through `get()`, limit one minute, deadline planted at 90 s: the red
///   was recorded at 60 s and the process stayed alive until 90.005 s — it
///   ended when the FUTURE ended, not when the harness said so.
/// - Through this function, limit three minutes, deadline planted at 600 s:
///   red at 180 s, run over at 192.003 s. It ended when the harness said so,
///   with the future still outstanding.
///
/// The 12 s between the limit and the end is the `loops.shutdownGracefully()`
/// that follows in the test, which is not cancellation-aware either; it is
/// bounded because a forced group shutdown completes, where the connect does
/// not. On the regression this test actually exists for — a deadline that
/// does not cover the resolving state — nothing fires at all, so through
/// `get()` the red is written and the run then sits at 0 % CPU until the CI
/// job timeout: the shape of
/// `docs/superpowers/specs/2026-08-08-testsuite-hang-investigation.md`,
/// arrived at from the other side.
///
/// No clock of its own. The wait ends when the future completes or when the
/// task is cancelled, and nothing here measures how long either took.
///
/// The future is not cancelled on the way out — a NIO future has no such
/// operation — it is left to complete into a callback that resumes nobody.
/// The three states are what make that safe, and each exists for a race that
/// happens:
///
/// - `.waiting` carries the continuation once it is stored. It starts EMPTY,
///   because `onCancel` can run before the body has stored anything: a task
///   cancelled before this call runs the handler immediately.
/// - `.cancelled` is written by `onCancel`. A body that finds it resumes with
///   `CancellationError` at once and never registers `whenComplete`.
/// - `.done` is written by `whenComplete`. Both it and `onCancel` take the
///   lock, take the continuation out, and leave a state the other cannot
///   resume from — so the waiter is resumed exactly once, whichever wins.
///
/// Moved here from `ConnectMainActorLivenessTests.swift`, its original and
/// only caller, so `AgentAuthTests.nextOffer` and
/// `SSHPrivateKeyLoaderTests.collectOfferedKeys` — the two other
/// `EventLoopFuture.get()` sites named in `docs/BACKLOG.md` ("Wall-clock
/// ceilings still in the tree") — can call it too, instead of each growing
/// its own copy of this state machine.
public func awaitCancellably<Value: Sendable>(
    _ future: EventLoopFuture<Value>
) async throws -> Value {
    let state = NIOLockedValueBox(CancellableWaitState<Value>.waiting(nil))

    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Value, any Error>) in
            let alreadyOver = state.withLockedValue { current -> Bool in
                switch current {
                case .waiting:
                    current = .waiting(continuation)
                    return false
                case .cancelled:
                    return true
                case .done:
                    // Unreachable: nothing can complete this box before
                    // `whenComplete` is registered at the foot of this same
                    // closure, and no other code registers it. The arm
                    // resumes anyway rather than falling through to that
                    // registration, because a state machine whose
                    // unreachable arm parks forever is one edit away from a
                    // hang.
                    return true
                }
            }
            guard !alreadyOver else {
                continuation.resume(throwing: CancellationError())
                return
            }
            future.whenComplete { result in
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
