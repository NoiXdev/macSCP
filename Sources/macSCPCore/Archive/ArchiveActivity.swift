import Foundation
import Observation

/// The one archive operation a pane may have running, and how the last one
/// ended.
///
/// **Why a model of its own.** The transfer queue counts bytes, and the
/// maintainer ruled that `TransferQueueViewModel.Item.Status` stays
/// byte-shaped: an archive has no byte count to report, only "running" and an
/// ending. This model exists instead of widening that type. It lives on a
/// pane's view model, so it belongs to a session and not to a view, and a
/// pane that is remounted does not lose track of a run that is still going.
///
/// **At most one per pane** (maintainer decision 3): `start` answers `false`
/// while one runs. Nothing queues.
///
/// **Cancelling** cancels the task, and the task is what closes the exec
/// channel (remote) or terminates the child (local). A cancel is an ENDING of
/// its own, `.cancelled`, never a failure: the user did nothing wrong.
@Observable
@MainActor
public final class ArchiveActivity {
    public enum State: Equatable, Sendable {
        case idle
        /// `title` is the name the operation is about: the archive being
        /// made, or the archive being unpacked.
        case running(title: String)
    }

    /// How the last operation ended. Carries no text of any tool: a far
    /// side's words are not ours to pass on, so each case is a sentence the
    /// App layer owns.
    public enum Ending: Equatable, Sendable {
        case finished
        case cancelled
        case failed(ArchiveFailure)
        /// The run did not reach a verdict from the tool: the preparation
        /// before it failed (the subfolder could not be created), or the
        /// channel failed with something that is not an `ArchiveFailure` (a
        /// dropped connection). Deliberately one case: the user's next step
        /// is the same, and the underlying error's description is a far
        /// side's text.
        case couldNotRun
    }

    public private(set) var state: State = .idle
    /// What the running operation is, for the sentence that describes it
    /// ("Compressing", "Extracting"). `nil` exactly when idle.
    public private(set) var operation: ArchiveOperation?
    /// The last ending, kept until the next `start` or `dismissOutcome()` so
    /// the pane can show one sentence about a failure.
    public private(set) var lastOutcome: Ending?

    private var task: Task<Void, Never>?
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []

    public init() {}

    public var isRunning: Bool { state != .idle }

    /// Starts `plan` on `runner`. Returns `false`, and starts nothing, while
    /// an operation is already running.
    ///
    /// `prepare` runs INSIDE the operation, before the runner: the extract
    /// dialog's new subfolder has to exist before `tar -C` is pointed at it,
    /// and creating it here keeps the creation under the same cancel and the
    /// same "one at a time" as the run it belongs to. A throw from it ends
    /// the operation as `.couldNotRun` without the runner being asked.
    @discardableResult
    public func start(
        _ plan: ArchivePlan, runner: any ArchiveRunner,
        prepare: (@Sendable () async throws -> Void)? = nil
    ) -> Bool {
        guard state == .idle else { return false }
        state = .running(title: plan.title)
        operation = plan.operation
        lastOutcome = nil
        task = Task { [self] in
            let ending: Ending
            do {
                try await prepare?()
                ending = try await runner.run(plan) == .finished ? .finished : .cancelled
            } catch let failure as ArchiveFailure {
                ending = .failed(failure)
            } catch {
                // A cancelled channel may surface as any error at all; the
                // task's own flag is the reliable witness.
                ending = error is CancellationError || Task.isCancelled
                    ? .cancelled : .couldNotRun
            }
            finish(with: ending)
        }
        return true
    }

    /// Cancels the running operation, if any. The ending arrives through
    /// the task, as `.cancelled`.
    public func cancel() { task?.cancel() }

    /// Forgets the last ending, so the pane stops showing it.
    public func dismissOutcome() { lastOutcome = nil }

    /// Returns once no operation is running. An `await` over a continuation
    /// the finishing task raises: no polling and no sleeping, which would be
    /// a wall-clock wait in a suite that is not allowed one.
    public func waitUntilIdle() async {
        guard state != .idle else { return }
        await withCheckedContinuation { idleWaiters.append($0) }
    }

    private func finish(with ending: Ending) {
        task = nil
        operation = nil
        lastOutcome = ending
        state = .idle
        let waiters = idleWaiters
        idleWaiters = []
        for waiter in waiters { waiter.resume() }
    }
}

extension ArchivePlan {
    /// The name this plan is about, for a row that says what is running.
    ///
    /// Read off the plan rather than passed beside it, so the title and the
    /// command cannot disagree. A compressed file is created as
    /// `<source>.gz` although its only operand is the source; every other
    /// plan's first operand is the archive (made, or unpacked) behind its
    /// `./` prefix.
    public var title: String {
        let first = words.lazy.compactMap { word -> String? in
            if case .operand(let value) = word { value } else { nil }
        }.first ?? ""
        let name = first.hasPrefix("./") ? String(first.dropFirst(2)) : first
        if case .compress(.gz) = operation { return name + ".gz" }
        return name
    }
}
