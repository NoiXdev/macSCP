import Foundation

/// Runs `operation` against a wall-clock bound and answers whether it
/// finished inside it. `false` means the bound elapsed first: the operation
/// is cancelled best-effort and then ABANDONED — this function does not wait
/// for it, which is the entire point.
///
/// This is `LivenessProbeRace`'s shape
/// (`Sources/MacSCPAppKit/ContentView+Detail.swift`), for
/// `LivenessProbeRace`'s reason, off the main actor because Core has none to
/// lean on and `CitadelFileSystem.disconnect()` is not isolated to one.
///
/// Being off the main actor is what lets the second caller work too:
/// `TeardownStage.runBounded` (App layer) bounds two main-actor-isolated
/// stages of `ContentView.teardown(_:reason:)` with this. Their bodies hop
/// back onto the main actor from inside `operation`, and the bound task
/// sleeps somewhere else entirely — so a stage that suspends can be
/// abandoned while the caller is still awaiting on the main actor. What no
/// bound here can do is interrupt an operation that BLOCKS the main actor
/// without suspending; nothing this type does can help there.
///
/// The other thing to know before wrapping a call in this: `operation` runs
/// in a task of its own, so the caller SUSPENDS before it starts, where a
/// direct call would have run the operation's own synchronous head first.
/// That is not free everywhere — `ContentView.teardown(_:reason:)` calls
/// `transferQueue.cancelAll(reason:)` directly for exactly this reason, and
/// its doc comment records what the extra main-actor turn changed.
///
/// Why not `withTaskGroup`: it implicitly awaits every remaining child
/// before its own scope returns, even one abandoned via `cancelAll()` — a
/// structured-concurrency guarantee, not a bug, but it defeats a bound
/// whenever the abandoned child cannot finish early. Citadel's path into NIO
/// ends in a bare `EventLoopFuture.get()` with no cancellation handler, so a
/// cancelled call waiting on a peer that never answers does not finish
/// early, and the "timeout" waits forever. Two unstructured tasks resolving
/// one continuation is the only shape here that can outlive its own
/// operation.
///
/// Exactly-once resumption (this project's standing continuation invariant;
/// see `ConflictPromptBridge`'s doc comment for the fuller treatment),
/// argued without the main actor `LivenessProbeRace` uses for the same
/// purpose. "At most once": `Box.resume(with:)` is the only place the
/// continuation is taken, it is taken and cleared inside one `lock`
/// critical section, so of the two racing calls exactly one finds it
/// non-`nil`. "At least once": the bound task alone guarantees it —
/// `Task.sleep` completes on its own schedule regardless of what
/// `operation` does, which is precisely the case this type exists for,
/// where `await operation()` never returns to reach its own call. The
/// continuation is resumed OUTSIDE the critical section, so resuming can
/// never re-enter the lock.
///
/// `adopt(operation:bound:)` closes the one gap the main-actor version does
/// not have. There, the synchronous `withCheckedContinuation` closure runs
/// on the main actor without yielding, so both tasks are stored before
/// either body can start. Here the bodies can run first, and a race that
/// settles before the tasks are stored would leave the bound task sleeping
/// out its full term with nothing left to resume. Handing both tasks over
/// under the same lock makes that impossible: either the box stores them
/// (and `resume(with:)` cancels them), or the box is already settled (and
/// `adopt` cancels them itself).
public enum BoundedClose {
    public static func run(
        boundSeconds: Int, operation: @escaping @Sendable () async -> Void
    ) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let box = Box(continuation: continuation)
            let operationTask = Task {
                await operation()
                box.resume(with: true)
            }
            let boundTask = Task {
                try? await Task.sleep(for: .seconds(boundSeconds))
                box.resume(with: false)
            }
            box.adopt(operation: operationTask, bound: boundTask)
        }
    }

    /// `@unchecked Sendable` because `lock` is what serializes access to the
    /// three stored properties once the box is shared: `init` runs inside
    /// the `withCheckedContinuation` closure, before either racing task
    /// exists to see it, and every access after that sits inside a
    /// `lock.withLock` block below.
    private final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Bool, Never>?
        private var operationTask: Task<Void, Never>?
        private var boundTask: Task<Void, Never>?

        init(continuation: CheckedContinuation<Bool, Never>) {
            self.continuation = continuation
        }

        func adopt(operation: Task<Void, Never>, bound: Task<Void, Never>) {
            let alreadySettled: Bool = lock.withLock {
                guard continuation != nil else { return true }
                operationTask = operation
                boundTask = bound
                return false
            }
            if alreadySettled {
                operation.cancel()
                bound.cancel()
            }
        }

        /// The only place `continuation` is taken and resumed — see this
        /// type's own doc comment for the exactly-once argument.
        func resume(with value: Bool) {
            let taken:
                (CheckedContinuation<Bool, Never>, Task<Void, Never>?, Task<Void, Never>?)? =
                    lock.withLock {
                        guard let continuation else { return nil }
                        self.continuation = nil
                        let tasks = (continuation, operationTask, boundTask)
                        operationTask = nil
                        boundTask = nil
                        return tasks
                    }
            guard let (continuation, operationTask, boundTask) = taken else { return }
            operationTask?.cancel()
            boundTask?.cancel()
            continuation.resume(returning: value)
        }
    }
}
