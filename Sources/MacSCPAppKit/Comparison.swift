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
/// **The result outlives the connection; the connection does not outlive the
/// tab's teardown.** The rows, the progress and the outcome are local data and
/// stay readable for as long as anything holds this object — a window that
/// has resolved it keeps showing what was measured after its session closed.
/// The two file systems are held in `fileSystems`, which is `nil` once
/// `releaseFileSystems()` has run (`SessionTab.endComparisons()` calls it,
/// after the cancel). Anything that needs a connection reads `fileSystems`
/// and has nothing to read afterwards: using a closed session is not
/// forbidden by a convention, it cannot be written. The roots and the
/// algorithm are plain data and stay, because a window that says WHAT was
/// compared needs them.
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
        /// Someone called `cancel()`; nothing else produces this.
        case cancelled
        /// The walk threw and nobody had cancelled: in practice the root of
        /// either side could not be listed (a stray `CancellationError` from
        /// a backend lands here too). Rows below the root that
        /// could not be read are `.undetermined(.unreadable)` rows, not this.
        case failed(any Error)
    }

    enum State {
        case idle
        case running
        case finished(Outcome)
    }

    let id = UUID()

    /// The two sides' file systems as one value, so they are released
    /// together or not at all: two separate optionals could be left
    /// half-released, and no caller can use half a comparison.
    struct FileSystems {
        let left: any RemoteFileSystem
        let right: any RemoteFileSystem
    }

    /// Borrowed from the owning tab's session; see the type's doc comment.
    /// `nil` after `releaseFileSystems()`, and then for good.
    private(set) var fileSystems: FileSystems?
    let leftRoot: String
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
        self.fileSystems = FileSystems(left: left, right: right)
        self.leftRoot = leftRoot
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
        guard case .idle = state, let sides = fileSystems else { return }
        state = .running
        // Read here, not inside the task: the task's first turn may come after
        // a release, and a walk that was already started owns the references
        // it was started with until it unwinds.
        walk = Task { [self] in
            do {
                try await FolderComparison.walk(
                    left: sides.left, leftRoot: leftRoot,
                    right: sides.right, rightRoot: rightRoot,
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
                // `.failed` whatever was thrown, a `CancellationError`
                // included. `.cancelled` is written by `cancel()` alone, which
                // settles the state BEFORE it cancels the task, and `finish`
                // is a no-op from then on — so by the time a cancel can reach
                // this catch the state is already `.cancelled`. A
                // `CancellationError` arriving while the state is still
                // `.running` is one nobody asked for (a backend throws it
                // too, and Core rethrows it), and telling the user they
                // stopped something they did not stop would be a false
                // statement about what happened.
                finish(.failed(error))
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

    /// Lets go of the two file systems. The rows, the progress and the
    /// outcome are untouched. Irreversible and idempotent.
    ///
    /// It does NOT stop a walk: `cancel()` does that, and `SessionTab.
    /// endComparisons()` calls the two in that order. A walk that is still
    /// unwinding keeps the references it was started with until it does, so
    /// this is "this object no longer offers a connection", not "no reference
    /// to one exists anywhere".
    func releaseFileSystems() {
        fileSystems = nil
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
