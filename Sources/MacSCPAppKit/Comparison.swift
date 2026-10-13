import Foundation
import Observation
import macSCPCore

/// One folder comparison: the rows `FolderComparison.walk` has produced so
/// far, the latest progress, and the task running the walk.
///
/// **Owned by the tab, never by a window.** A comparison runs over the
/// connection of the `SessionTab` that created it (`SessionTab.
/// startComparison(...)`, the only constructor call in the App target), is
/// held in that tab's `comparisons`, and is ended by `TabTeardown.run(_:
/// reason:)` together with the tab's other work. The window that shows it
/// (a later task) is a view onto this object and holds no connection of its
/// own. The reason is this project's standing invariant: connection and
/// session state belongs to the window scope, `TabRegistry` holds ownership
/// and never state, and nothing app-wide may keep a connection alive.
///
/// **What it stores, and what it does not.** The two file systems it was
/// handed are BORROWED from the tab's session: this type never opens,
/// reconnects or closes one, and holds no connector, no configuration and no
/// credentials. `ComparisonOwnershipTests` reads the stored properties to say
/// so, rather than trusting this paragraph.
///
/// **Teardown is synchronous and never waits.** `cancel()` flips the state to
/// `.finished(.cancelled)` BEFORE it returns and only then asks the task to
/// stop. `TabTeardown` calls it from a function that is deliberately not
/// bounded around this call, and the walk may be parked in a network call to
/// a peer that stopped answering; a teardown that waited for it to unwind
/// would inherit that hang. The state therefore does not depend on how
/// quickly the walk notices: once `cancel()` has returned, no later row or
/// progress report reaches this object, and a walk that was past its last
/// cancellation check and returns normally cannot turn the state into
/// `.completed`.
///
/// No `deinit` cleanup, as everywhere in this tree: the owner ends it.
@MainActor
@Observable
final class Comparison: Identifiable {
    /// How a comparison ended. `.cancelled` and `.failed` leave `rows`
    /// incomplete; only `.completed` means every pair was classified.
    enum Outcome {
        case completed
        case cancelled
        /// The walk threw something that was not a cancel: in practice the
        /// root of either side could not be listed. Rows below the root that
        /// could not be read are `.undetermined(.unreadable)` rows, not this.
        case failed(any Error)
    }

    enum State {
        case idle
        case running
        case finished(Outcome)
    }

    let id = UUID()

    /// Borrowed from the owning tab's session; see the type's doc comment.
    let left: any RemoteFileSystem
    let leftRoot: String
    let right: any RemoteFileSystem
    let rightRoot: String
    let algorithm: ChecksumAlgorithm

    private(set) var rows: [ComparisonRow] = []
    private(set) var progress = ComparisonProgress(directoriesVisited: 0, rowsProduced: 0)
    private(set) var state: State = .idle

    /// The walk. Kept so `cancel()` can reach it and `waitForWalk()` can
    /// wait for it; never read to decide what the state is.
    private var walk: Task<Void, Never>?

    init(
        left: any RemoteFileSystem, leftRoot: String,
        right: any RemoteFileSystem, rightRoot: String,
        algorithm: ChecksumAlgorithm
    ) {
        self.left = left
        self.leftRoot = leftRoot
        self.right = right
        self.rightRoot = rightRoot
        self.algorithm = algorithm
    }

    /// Whether the walk is over, however it ended. Not "everything was
    /// compared": see `outcome`.
    var isFinished: Bool {
        if case .finished = state { return true }
        return false
    }

    var isRunning: Bool {
        if case .running = state { return true }
        return false
    }

    var outcome: Outcome? {
        if case .finished(let outcome) = state { return outcome }
        return nil
    }

    /// Starts the walk. Does nothing unless the comparison is idle: a
    /// comparison runs once, and a cancelled one stays cancelled.
    func start() {
        guard case .idle = state else { return }
        state = .running
        walk = Task { [self] in
            do {
                try await FolderComparison.walk(
                    left: left, leftRoot: leftRoot,
                    right: right, rightRoot: rightRoot,
                    algorithm: algorithm,
                    onRow: { row in
                        // Dropped once finished: a cancel that lands while the
                        // walk is between two checks must not add a row after
                        // `cancel()` has returned.
                        guard self.isRunning else { return }
                        self.rows.append(row)
                    },
                    onProgress: { progress in
                        guard self.isRunning else { return }
                        self.progress = progress
                    })
                finish(.completed)
            } catch {
                finish(error is CancellationError ? .cancelled : .failed(error))
            }
        }
    }

    /// Ends the comparison now. Idempotent, and also valid before `start()`:
    /// a comparison that never ran is then finished and cannot be started.
    ///
    /// The state changes first and the task is cancelled second; see the
    /// type's doc comment for why neither waits on the walk.
    func cancel() {
        finish(.cancelled)
        walk?.cancel()
    }

    /// Suspends until the walk's task has unwound, which after `cancel()` is
    /// the moment it has stopped talking to the connection. For callers that
    /// need that — `TabTeardown` is not one of them, for the reason above.
    func waitForWalk() async {
        await walk?.value
    }

    /// The only writer of `.finished`, and a no-op once the state is
    /// finished: whichever of `cancel()` and the walk's own ending comes
    /// first decides the outcome, and the other cannot overwrite it.
    private func finish(_ outcome: Outcome) {
        if case .finished = state { return }
        state = .finished(outcome)
    }
}
