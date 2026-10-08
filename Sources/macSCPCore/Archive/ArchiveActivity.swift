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
        /// The plan could not be made: the name, the format or the folder
        /// did not allow it, and nothing ran. Every case of
        /// `ArchiveRefusal` is a sentence for the user, which is why this is
        /// kept whole where `.couldNotRun` is not.
        case refused(ArchiveRefusal)
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
    private var previewTask: Task<Void, Never>?
    private var previewGeneration = 0
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []

    public init() {}

    public var isRunning: Bool { state != .idle }

    /// Whether a preview (`preview(_:completion:)`) is still being made.
    public var isPreviewing: Bool { previewTask != nil }

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
        start(
            operation: plan.operation, title: plan.title, runner: runner,
            makePlan: { plan }, prepare: prepare)
    }

    /// Starts an operation whose plan is made INSIDE it.
    ///
    /// **Why the plan is made here.** Naming a compression reads the folder,
    /// and that read takes as long as the far side takes. Done in a task of
    /// the caller's, nothing owned it: a tab closed in that window found no
    /// running operation to cancel, and the run started afterwards on a pane
    /// that no longer existed, with an hour's budget and no Cancel to press.
    /// Made here, the read is under the same task as the run, so the one
    /// `cancel()` the teardown already calls reaches it, and a plan that
    /// arrives after the cancel is never run: `Task.checkCancellation()`
    /// stands between the two.
    ///
    /// `title` is what the row says until the plan exists; it becomes the
    /// plan's own title the moment it does. A refusal thrown by `makePlan`
    /// ends the operation as `.refused`, anything else as `.couldNotRun`.
    @discardableResult
    public func start(
        operation: ArchiveOperation, title: String, runner: any ArchiveRunner,
        makePlan: @escaping @Sendable () async throws -> ArchivePlan,
        prepare: (@Sendable () async throws -> Void)? = nil
    ) -> Bool {
        guard state == .idle else { return false }
        state = .running(title: title)
        self.operation = operation
        lastOutcome = nil
        task = Task { [self] in
            let ending: Ending
            do {
                let plan = try await makePlan()
                try Task.checkCancellation()
                state = .running(title: plan.title)
                try await prepare?()
                ending = try await runner.run(plan) == .finished ? .finished : .cancelled
            } catch let failure as ArchiveFailure {
                ending = .failed(failure)
            } catch let refusal as ArchiveRefusal {
                ending = .refused(refusal)
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

    /// Runs `work` as a preview the pane is waiting on (the extract dialog's
    /// listing) and hands its result to `completion` on the main actor,
    /// unless it was cancelled meanwhile.
    ///
    /// Owned here for the reason `start(operation:...)` makes its plan here:
    /// a listing can run as long as the archive is large, and a tab closed
    /// during it must not leave a child process reading on. `cancel()`
    /// reaches it, and a cancelled preview delivers nothing. A new preview
    /// supersedes one still running.
    public func preview<Value: Sendable>(
        _ work: @escaping @Sendable () async throws -> Value,
        completion: @escaping @MainActor (Result<Value, any Error>) -> Void
    ) {
        previewTask?.cancel()
        previewGeneration += 1
        let generation = previewGeneration
        previewTask = Task { [self] in
            let result: Result<Value, any Error>
            do { result = .success(try await work()) } catch { result = .failure(error) }
            // Cancelled, or superseded while it ran: nobody is waiting for it.
            if !Task.isCancelled, generation == previewGeneration { completion(result) }
            if generation == previewGeneration {
                previewTask = nil
                resumeWaitersIfSettled()
            }
        }
    }

    /// Cancels the running operation and the preview, if any. The ending of
    /// an operation arrives through its task, as `.cancelled`.
    public func cancel() {
        task?.cancel()
        previewTask?.cancel()
    }

    /// Forgets the last ending, so the pane stops showing it.
    public func dismissOutcome() { lastOutcome = nil }

    /// Returns once no operation is running and no preview is being made. An
    /// `await` over a continuation the finishing task raises: no polling and
    /// no sleeping, which would be a wall-clock wait in a suite that is not
    /// allowed one.
    public func waitUntilIdle() async {
        guard state != .idle || previewTask != nil else { return }
        await withCheckedContinuation { idleWaiters.append($0) }
    }

    private func finish(with ending: Ending) {
        task = nil
        operation = nil
        lastOutcome = ending
        state = .idle
        resumeWaitersIfSettled()
    }

    private func resumeWaitersIfSettled() {
        guard state == .idle, previewTask == nil else { return }
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
