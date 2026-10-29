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
/// **Fetching content, and what the session being gone means.** The content
/// diff and "compare anyway" need the bytes of both files, and get them one
/// way only: `TransferQueueViewModel.enqueueAndWait`, as the edit session
/// does, into this comparison's own temporary directory, so every byte a
/// comparison moves is visible in the transfer bar. The queue is the tab's;
/// like the two file systems it is held in a property that
/// `releaseFileSystems()` clears, and every entry point that fetches reads
/// both through one `guard` and ends in `ComparisonFetchError.sessionClosed`
/// when either is gone. A closed session is an explicit answer, never a
/// crash and never an empty result.
///
/// **Two shapes of comparison, and they do not share a path.** A `.folders`
/// comparison walks two roots and classifies pairs; its content diff and its
/// byte settling are per ROW (`diff(forRowAt:)`, `settleUndetermined(rowAt:)`).
/// A `.filePair` comparison is two files the user picked, has no walk and no
/// rows, and is diffed straight away by `diffFilePair()`: size and checksum
/// exist to avoid a fetch, not to stand in front of one somebody asked for.
/// **A folder row is fetched from the two paths IT carries**
/// (`ComparisonRow.leftPath`, `.rightPath`), never from its `relativePath`
/// joined to the two roots: a pair the second pairing pass made is spelled
/// differently on each side, and that join named a path the right side does
/// not have. A file pair's two sides are the two roots, which are themselves
/// each side's own path.
/// Neither diff entry point ever asks a file system for a checksum — a folder
/// row's classification already did, once, during the walk.
///
/// No `deinit` cleanup, as everywhere in this tree: the owner ends it.
@MainActor
@Observable
final class Comparison: Identifiable {
    /// What the comparison is of.
    enum Kind {
        /// Two folders, walked and classified.
        case folders
        /// Two files the user chose. No walk, no rows.
        case filePair
    }

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
    /// The tab's transfer queue, through which every fetch goes. A SIBLING of
    /// `fileSystems`, not a member: `ComparisonOwnershipTests` counts exactly
    /// two file systems in this object's graph and exactly one queue. Cleared
    /// by `releaseFileSystems()` together with them, so a comparison that
    /// outlives its tab does not keep the tab's queue (and whatever interrupted
    /// jobs it retains, each of which holds file systems) alive.
    private(set) var transferQueue: TransferQueueViewModel?
    let kind: Kind
    let leftRoot: String
    let rightRoot: String
    let algorithm: ChecksumAlgorithm

    /// Where this comparison's fetched files live: `nil` until the first
    /// fetch creates it, and `nil` again once `releaseFileSystems()` has
    /// removed it. `cancel()` leaves it alone.
    @ObservationIgnored private(set) var temporaryDirectory: URL?
    @ObservationIgnored private let temporaryRoot: URL

    private(set) var rows: [ComparisonRow] = []
    private(set) var progress = ComparisonProgress(directoriesVisited: 0, rowsProduced: 0)
    private(set) var state: State = .idle

    /// The walk. Kept so `cancel()` can reach it and `waitForWalk()` can
    /// wait for it; never read to decide what the state is.
    private var walk: Task<Void, Never>?

    /// Everything this comparison has running that is NOT the walk, so
    /// `cancel()` can reach it. Keyed so a task removes its own entry as it
    /// ends and a long session does not accumulate finished tasks.
    ///
    /// **Why this exists.** The content diff is started by the view's
    /// `.task(id: target)`, which cancels its own load when the selection
    /// moves, so nothing has to be held for it. The byte settling ("compare
    /// contents anyway") has no such owner: it is started by a button, it
    /// opts in to `cancelsWithTask` on both of its downloads, and before
    /// 2026-10-15 nothing anywhere held the task that would deliver that
    /// cancel. Over WebDAV, on an equal-size pair of 2 GB, closing the window
    /// moved 4 GB afterwards into a directory the close had just deleted:
    /// self-healing, and not what the user asked to stop paying for. Tab
    /// teardown was covered — the queue's `cancelAll` reaches every
    /// transfer — and closing a window with the tab still open was the gap.
    @ObservationIgnored private var trackedWork: [UUID: Task<Void, Never>] = [:]

    /// `temporaryRoot` is where the per-comparison directory is created; the
    /// default is the process's temporary directory, and a test passes its own
    /// so it can see what is left behind.
    init(
        left: any RemoteFileSystem, leftRoot: String,
        right: any RemoteFileSystem, rightRoot: String,
        algorithm: ChecksumAlgorithm,
        transferQueue: TransferQueueViewModel,
        kind: Kind = .folders,
        temporaryRoot: URL = FileManager.default.temporaryDirectory
            .appendingPathComponent("macscp-compare", isDirectory: true)
    ) {
        self.fileSystems = FileSystems(left: left, right: right)
        self.transferQueue = transferQueue
        self.kind = kind
        self.leftRoot = leftRoot
        self.rightRoot = rightRoot
        self.algorithm = algorithm
        self.temporaryRoot = temporaryRoot
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
        // A file pair has nothing to walk: it is over before it began, and
        // `.completed` says only that no pair is waiting to be classified.
        if kind == .filePair {
            state = .finished(.completed)
            return
        }
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

    /// Starts `operation` in a task this comparison OWNS, so `cancel()`
    /// reaches it, and hands the task back for a caller that wants to await
    /// it. The task removes its own entry when it ends.
    ///
    /// **Not gated on the state.** A comparison that was cancelled or that
    /// completed still holds its rows and, until the release, its two file
    /// systems, so settling a row of it is a thing a user may legitimately
    /// ask for; what this guarantees is that the next `cancel()` reaches
    /// whatever is in flight at that moment.
    @discardableResult
    func startTrackedWork(_ operation: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        let key = UUID()
        let task = Task { [weak self] in
            await operation()
            self?.trackedWork[key] = nil
        }
        trackedWork[key] = task
        return task
    }

    /// Suspends until every tracked task has unwound. For a caller that
    /// needs that; `cancel()` does not, for the same reason it does not wait
    /// on the walk.
    func waitForTrackedWork() async {
        for task in trackedWork.values { await task.value }
    }

    /// Ends the comparison now. Idempotent, and also valid before `start()`:
    /// a comparison that never ran is then finished and cannot be started.
    ///
    /// The state changes first and the tasks are cancelled second; see the
    /// type's doc comment for why neither waits on the walk.
    ///
    /// **It cancels the walk AND everything else this comparison started**
    /// (`startTrackedWork`, today the byte settling of a row). The window's
    /// close and the tab's teardown both reach it through here, in that one
    /// call: `ComparisonWindowModel.windowClosed()` and
    /// `SessionTab.endComparisons()` each call this before the release.
    ///
    /// **It does not touch the fetched files.** `cancel()` stops the WALK; a
    /// diff the user opened for a row that had already arrived is a different
    /// operation, may be fetching or being read at this very moment, and
    /// deleting its files under it would answer a question nobody asked. The
    /// directory is removed by `releaseFileSystems()`, which teardown always
    /// calls after this; the cost is that a cancelled comparison keeps its
    /// fetched files until the tab closes. An earlier version also removed
    /// them here (the plan's brief asked for it), and a Cancel pressed during
    /// a diff then killed that diff with a raw file error and still left an
    /// empty directory behind.
    func cancel() {
        finish(.cancelled)
        walk?.cancel()
        // Taken out of the dictionary first: each task clears its own entry
        // as it unwinds, and mutating a collection being iterated is not a
        // thing to leave to luck.
        let tracked = trackedWork
        trackedWork.removeAll()
        for task in tracked.values { task.cancel() }
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
        transferQueue = nil
        removeTemporaryDirectory()
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

// MARK: - Fetching content

/// Why a fetch, a content diff or a byte settling could not be attempted.
/// Distinct from `DiffRefusal`, which is a REASON a pair cannot be shown as a
/// diff and travels in the `Result`; these are the cases where there was no
/// attempt to describe. They carry no display text: the window maps them to
/// localized messages.
enum ComparisonFetchError: Error, Equatable {
    /// The comparison no longer holds the two file systems and the queue:
    /// the tab that owned the connection has been torn down. What was
    /// measured is still readable; nothing that needs the connection is.
    case sessionClosed
    /// The entry point belongs to the other `Comparison.Kind`.
    case wrongKind
    case rowOutOfRange(Int)
    /// The row is not a pair of files whose content could be compared
    /// (one side missing, a directory, a type mismatch, a link, or a path
    /// that could not be read in the first place).
    case noContentToCompare(ComparisonState)
}

extension UndeterminedReason {
    /// Whether fetching both files and comparing their bytes can settle a row
    /// carrying this reason.
    ///
    /// The checksum reasons say "the connection could not give a usable
    /// checksum" about two ordinary files; bytes answer that. So does
    /// `.kindNotReported`, which says a listing did not report what kind of
    /// entry this is: for an ordinary file a fetch is what answers it. This
    /// read "a fetch is the one thing that can answer it", which over-reaches
    /// for a FIFO or a device, where a fetch was read and not measured and may
    /// not end. `.linkOnASide`
    /// is refused because a link's content is its target path, so bytes would
    /// answer a different question from the one the row asks, and
    /// `.unreadable` because it may be a DIRECTORY the walk could not list as
    /// well as a file it could not classify.
    ///
    /// This comment used to say "`.unsupportedKind` is a link or a special
    /// entry, for which no content comparison is meaningful". That is true of
    /// a link and false of an unreported type, and is replaced by the reason
    /// each case decides. Exhaustive on purpose: a new reason has to be
    /// decided here. What the decision DOES is pinned by what a settle does,
    /// in `ComparisonFetchTests`, and not by a list written against this.
    nonisolated var canBeSettledByBytes: Bool {
        switch self {
        case .checksumUnavailable, .algorithmUnavailable, .algorithmsDiffer, .etagIsNotAFileHash,
            .kindNotReported:
            true
        case .linkOnASide, .unreadable:
            false
        }
    }
}

extension Comparison {
    /// Lines of context around a change in the diff `diff(forRowAt:)` and
    /// `diffFilePair()` produce.
    nonisolated static let diffContextLines = 3

    /// Both sides of `row`, downloaded into this comparison's temporary
    /// directory through the transfer queue. The files stay there until
    /// `releaseFileSystems()` removes the directory.
    ///
    /// - Throws: `ComparisonFetchError.sessionClosed` when the session is
    ///   gone, `.wrongKind` on a file-pair comparison, `.noContentToCompare`
    ///   for a row that is not a pair of files; and whatever the queue throws
    ///   for a failed transfer, which fails this pair and not the comparison.
    func fetchPair(_ row: ComparisonRow) async throws -> (left: URL, right: URL) {
        guard kind == .folders else { throw ComparisonFetchError.wrongKind }
        guard Self.hasFilesOnBothSides(row.state) else {
            throw ComparisonFetchError.noContentToCompare(row.state)
        }
        let fetched = try await fetch(leftPath: row.leftPath, rightPath: row.rightPath)
        return (fetched.left, fetched.right)
    }

    /// The line diff of the row at `index`, or the reason there is none.
    ///
    /// **No checksum is asked for, here or on the way.** The row's state came
    /// from the walk, which asked once; this fetches and diffs.
    func diff(forRowAt index: Int) async throws -> Result<[DiffHunk], DiffRefusal> {
        guard kind == .folders else { throw ComparisonFetchError.wrongKind }
        guard rows.indices.contains(index) else { throw ComparisonFetchError.rowOutOfRange(index) }
        let row = rows[index]
        guard Self.hasFilesOnBothSides(row.state) else {
            throw ComparisonFetchError.noContentToCompare(row.state)
        }
        return try await diff(leftPath: row.leftPath, rightPath: row.rightPath)
    }

    /// The line diff of the two files a `.filePair` comparison was made for.
    /// **Skips the classification entirely**: no size comparison to settle
    /// the pair, no checksum. The user asked to see the content.
    func diffFilePair() async throws -> Result<[DiffHunk], DiffRefusal> {
        guard kind == .filePair else { throw ComparisonFetchError.wrongKind }
        return try await diff(leftPath: leftRoot, rightPath: rightRoot)
    }

    /// "Compare anyway": fetches both sides of the undetermined row at
    /// `index`, compares their bytes, and replaces THAT row's state with
    /// `.same` or `.differs`. No other row is touched, and no checksum is
    /// asked for — the connection already said it cannot give one.
    ///
    /// The comparison is on bytes and is not bounded by the diff's size
    /// ceiling: a ceiling exists to keep a line diff affordable, and a byte
    /// comparison streams. Returns the new state.
    @discardableResult
    func settleUndetermined(rowAt index: Int) async throws -> ComparisonState {
        guard kind == .folders else { throw ComparisonFetchError.wrongKind }
        guard rows.indices.contains(index) else { throw ComparisonFetchError.rowOutOfRange(index) }
        let row = rows[index]
        guard case .undetermined(let reason) = row.state, reason.canBeSettledByBytes else {
            throw ComparisonFetchError.noContentToCompare(row.state)
        }
        let fetched = try await fetch(leftPath: row.leftPath, rightPath: row.rightPath)
        defer { try? FileManager.default.removeItem(at: fetched.directory) }

        let equal = try await mappingReleaseToSessionClosed {
            try await Self.contentsAreEqual(fetched.left, fetched.right)
        }
        let settled: ComparisonState = equal ? .same : .differs
        // The same row, still: rows are only ever appended to while a walk
        // runs, so the index holds; the path is checked because writing the
        // answer onto another file's row would be the one wrong thing this
        // method could do.
        guard rows.indices.contains(index),
            rows[index].hasRelativePath(row.relativePath)
        else {
            throw ComparisonFetchError.rowOutOfRange(index)
        }
        rows[index] = ComparisonRow(
            relativePath: row.relativePath, leftPath: row.leftPath, rightPath: row.rightPath,
            state: settled)
        return settled
    }

    // MARK: Shared steps

    /// The diff of two paths on the two sides. The size ceiling is checked
    /// from `stat` BEFORE any byte is fetched; the byte checks run on what
    /// arrived, because a size a server reports can be absent or stale.
    private func diff(
        leftPath: String, rightPath: String
    ) async throws -> Result<[DiffHunk], DiffRefusal> {
        try await mappingReleaseToSessionClosed {
            try await diffUnmapped(leftPath: leftPath, rightPath: rightPath)
        }
    }

    /// Runs `body`, and when it throws after the session was let go says so.
    /// A connection closed under a `stat`, or a fetch directory swept under a
    /// read, throws whatever the backend or the file system throws, and
    /// "the session is closed" is the true account of every one of them.
    /// `fetch` does the same for its own window.
    ///
    /// `body` is `@MainActor` because this type is, and that annotation is
    /// what keeps the call on the actor instead of hopping off it. Without
    /// it the closure type is nonisolated, so `body()` suspends off the main
    /// actor and a non-`Sendable` `T` has to be sent back across that
    /// boundary -- which the runner's toolchain rejects and the newer local
    /// one accepts. CI run 40913494898 (2026-10-29) failed the build with
    /// exactly one distinct error, printed as:
    ///
    ///     Sources/MacSCPAppKit/Comparison.swift:494:30: error: non-sendable
    ///     result type 'T' cannot be sent from nonisolated context in call
    ///     to parameter 'body'
    ///
    /// while `swift build` on the same commit was green here from a clean
    /// scratch path, so no incremental cache was hiding it. That run's own
    /// first step printed `Xcode 16.4` and `Build version 16F6` for the
    /// runner; this machine's `swift --version` printed `Apple Swift version
    /// 6.4 (swiftlang-6.4.0.34.1)`. It is the same split the warning budget
    /// in `.github/workflows/ci.yml` already records for
    /// `asyncParseAsRoot()`, in the same words -- a diagnostic the runner
    /// prints and the newer local toolchain does not.
    private func mappingReleaseToSessionClosed<T>(
        _ body: @MainActor () async throws -> T
    ) async throws -> T {
        do {
            return try await body()
        } catch {
            if fileSystems == nil { throw ComparisonFetchError.sessionClosed }
            throw error
        }
    }

    private func diffUnmapped(
        leftPath: String, rightPath: String
    ) async throws -> Result<[DiffHunk], DiffRefusal> {
        guard let sides = fileSystems, transferQueue != nil else {
            throw ComparisonFetchError.sessionClosed
        }
        for (side, system, path) in [
            (DiffRefusal.Side.left, sides.left, leftPath),
            (DiffRefusal.Side.right, sides.right, rightPath),
        ] {
            let item = try await system.stat(path: path)
            // The KIND before the size (fix round 1, F1). A `.filePair`
            // comparison skips the classification by design — the user asked
            // for the content — so this is the only place either side's kind
            // AS `stat` REPORTS IT is looked at. The qualifier is fix round
            // 3's: this comment read "the only place either side's kind is
            // looked at", which stopped being true in round 2, when the menu
            // model began reading the FAR side's kind from the other pane's
            // listing (`BrowserContextMenu.entries(… destinationRows:)`) —
            // better information, since a listing sees a link where `stat`
            // follows it. What this check is still alone in seeing is a far
            // side the menu model had no row for. Without it, a directory
            // there was handed to the transfer queue as a download and the
            // user got a raw transfer failure.
            //
            // Before the size, not after: both orders answer truthfully, and
            // only this one answers with the fact the user can act on. See
            // `DiffRefusal.notAnOrdinaryFile` for the one shape this cannot
            // see — a remote symlink to a regular file, because SFTP's `stat`
            // follows links.
            //
            // **What is refused is what is KNOWN to be unsuitable, and
            // nothing else.** This guard read `item.kind == .file`, which
            // treated `.other` as unsuitable. `.other` is also what `stat`
            // answers when the type was not reported (no permission bits
            // arrived), so on the very server that gives a row the reason
            // `.kindNotReported` — settled by bytes, because for an ordinary
            // file a fetch is what answers it; this clause read "because a
            // fetch is the one thing that can answer it", which over-reaches
            // for a FIFO or a device — the diff of the settled row was
            // refused as "not an ordinary file": the overview and the diff
            // telling the user two things about the same two files. An
            // unreported type goes on to the fetch.
            //
            // This sentence ended "which fails by name if it is a device node
            // and reads the bytes if it is not." That was written from
            // intent, not from a measurement, and is withdrawn. What was READ
            // (not run): `TransferEngine.copyFile` makes one `stat` for a
            // progress total and then opens the stream, with no kind check
            // and no size ceiling (the size is only the progress total), and
            // `settleUndetermined` adds neither. Nothing in that reading
            // says a device node or a FIFO fails by name; what it leaves
            // open is a download that does not end, visible in the transfer
            // bar and cancellable. Not run against a device. The ordinary
            // single-item download takes the same path (see
            // `ContentView.transferSelection`).
            // `UndeterminedReason.canBeSettledByBytes` decides the same
            // question for the settle, and
            // `aRowBytesCanSettleIsNotThenRefusedByTheDiffAndAnUnsettleableOneIsBoth`
            // holds the two to each other.
            switch item.kind {
            case .directory, .symlink:
                return .failure(.notAnOrdinaryFile(side: side, path: path))
            case .file, .other:
                break
            }
            if let size = item.size,
                let refusal = DiffEligibility.refusal(forByteCount: Int(clamping: size))
            {
                return .failure(refusal)
            }
        }

        let fetched = try await fetch(leftPath: leftPath, rightPath: rightPath)
        defer { try? FileManager.default.removeItem(at: fetched.directory) }

        var contents: [[UInt8]] = []
        for url in [fetched.left, fetched.right] {
            // The length on disk first: a side whose `stat` carried no size
            // has already been moved, but is not also loaded into memory.
            if let length = try FileManager.default.attributesOfItem(
                atPath: url.path(percentEncoded: false))[.size] as? NSNumber,
                let refusal = DiffEligibility.refusal(forByteCount: length.intValue)
            {
                return .failure(refusal)
            }
            let bytes = [UInt8](try Data(contentsOf: url))
            if let refusal = DiffEligibility.refusal(forBytes: bytes) { return .failure(refusal) }
            contents.append(bytes)
        }

        let left = Self.lines(of: contents[0])
        let right = Self.lines(of: contents[1])
        if let refusal = DiffEligibility.refusal(leftLines: left.count, rightLines: right.count) {
            return .failure(refusal)
        }
        let hunks = try await Self.computeHunks(left: left, right: right)
        return .success(hunks)
    }

    private struct Fetched {
        /// The per-fetch directory holding `left/` and `right/`.
        let directory: URL
        let left: URL
        let right: URL
    }

    /// Downloads the two paths through the queue into a directory of their
    /// own. A fresh directory per fetch, because the queue asks its conflict
    /// decider when a destination exists, and a second fetch of the same row
    /// must not put a dialog in front of the user.
    private func fetch(leftPath: String, rightPath: String) async throws -> Fetched {
        guard let sides = fileSystems, let queue = transferQueue else {
            throw ComparisonFetchError.sessionClosed
        }
        let directory = try makeFetchDirectory()
        let leftDirectory = directory.appendingPathComponent("left", isDirectory: true)
        let rightDirectory = directory.appendingPathComponent("right", isDirectory: true)
        let leftName = Self.fileName(of: leftPath)
        let rightName = Self.fileName(of: rightPath)
        do {
            try FileManager.default.createDirectory(
                at: leftDirectory, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(
                at: rightDirectory, withIntermediateDirectories: true)
            // The destination is a fresh `LocalFileSystem()`, a stateless
            // value, rather than a stored one: a third file system in this
            // object's graph is exactly what the ownership guard forbids.
            //
            // `cancelsWithTask`: selecting a row starts its diff, and moving
            // the selection cancels the awaiting task; without this the
            // download carried on behind a view that had gone elsewhere.
            // Opt-in on the queue, so the other callers of
            // `enqueueAndWait` are unchanged.
            try await queue.enqueueAndWait(
                fileName: leftName, direction: .download,
                source: sides.left, sourcePath: leftPath,
                destination: LocalFileSystem(),
                destinationDirectory: leftDirectory.path(percentEncoded: false),
                cancelsWithTask: true)
            // Between the two transfers too: a release during the first must
            // not be followed by a second download over the released system.
            guard fileSystems != nil else { throw ComparisonFetchError.sessionClosed }
            try await queue.enqueueAndWait(
                fileName: rightName, direction: .download,
                source: sides.right, sourcePath: rightPath,
                destination: LocalFileSystem(),
                destinationDirectory: rightDirectory.path(percentEncoded: false),
                cancelsWithTask: true)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            // A transfer cancelled because the tab was torn down is not a
            // failed pair; the session being gone is the true answer.
            if fileSystems == nil {
                removeTemporaryDirectory()
                throw ComparisonFetchError.sessionClosed
            }
            throw error
        }
        // The teardown may have run while the transfers were in flight. What
        // arrived is then of a session nobody can use any more.
        guard fileSystems != nil else {
            try? FileManager.default.removeItem(at: directory)
            removeTemporaryDirectory()
            throw ComparisonFetchError.sessionClosed
        }
        return Fetched(
            directory: directory,
            left: leftDirectory.appendingPathComponent(leftName, isDirectory: false),
            right: rightDirectory.appendingPathComponent(rightName, isDirectory: false))
    }

    /// This comparison's own directory under `temporaryRoot`, whether or not
    /// it exists.
    private var comparisonDirectory: URL {
        temporaryRoot.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    private func makeFetchDirectory() throws -> URL {
        let root = comparisonDirectory
        let directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectory = root
        return directory
    }

    /// Removes the comparison's directory whether or not `temporaryDirectory`
    /// says it exists. A removal that lands while a transfer is still writing
    /// into the tree can fail on the file the writer is creating at that
    /// moment and leave the directory behind, with `temporaryDirectory`
    /// already `nil`; found by `ComparisonFetchTests` as an empty directory
    /// left under the temporary root, in about half the runs of the two
    /// release-during-transfer cases. The fetch that notices the session is
    /// gone calls this again once its own transfer has ended.
    func removeTemporaryDirectory() {
        temporaryDirectory = nil
        try? FileManager.default.removeItem(at: comparisonDirectory)
    }

    private static func hasFilesOnBothSides(_ state: ComparisonState) -> Bool {
        switch state {
        case .same, .differs: true
        case .undetermined(let reason): reason.canBeSettledByBytes
        case .onlyLeft, .onlyRight, .bothDirectories, .typeMismatch: false
        }
    }

    private static func fileName(of path: String) -> String {
        path.split(separator: "/", omittingEmptySubsequences: true).last.map(String.init) ?? "file"
    }

    // MARK: Pure steps

    /// Cuts bytes into lines on LF, and **losslessly**: joining the result
    /// with "\n" gives the text back. Three consequences, each deliberate and
    /// each pinned by `ComparisonFetchTests`:
    ///
    /// - **CRLF is split.** The cut is on the byte 0x0A, not on a Swift
    ///   `Character`: `split(separator: "\n")` on a `String` never sees a LF
    ///   inside a CRLF, because the pair is ONE `Character`, and would hand
    ///   back a Windows file as a single line. Each line keeps its trailing
    ///   CR, so a CRLF file has as many lines as its LF twin and differs from
    ///   it on every one of them, which is true: the bytes differ.
    /// - **A final newline ends in an empty last line.** "a\nb\n" is
    ///   ["a", "b", ""] and "a\nb" is ["a", "b"], so a file and its twin
    ///   without the final newline show that difference, as `FileDiff`
    ///   already pins for the shapes it is given. The other choice would show
    ///   an empty diff for two files the folder view just called different.
    /// - **A UTF-8 byte order mark stays, as U+FEFF at the start of line 1.**
    ///   Same reason: stripping it would make a pair that differs by exactly
    ///   those three bytes show no difference, and a BOM in front of a `#!`
    ///   line is a difference somebody comparing two copies of a script wants
    ///   to see. The cost is a changed first line whose two sides LOOK
    ///   identical; making U+FEFF visible is for the view.
    ///
    /// The bytes must be valid UTF-8, which `DiffEligibility` has already
    /// established on the way here.
    nonisolated static func lines(of bytes: [UInt8]) -> [String] {
        bytes.split(separator: 0x0A, omittingEmptySubsequences: false).map {
            String(decoding: $0, as: UTF8.self)
        }
    }

    /// Runs the diff off the main actor: bounded by `DiffEligibility`, but a
    /// bounded diff is still hundreds of milliseconds at the top of the range.
    private nonisolated static func computeHunks(
        left: [String], right: [String]
    ) async throws -> [DiffHunk] {
        let task = Task.detached(priority: .userInitiated) {
            FileDiff.hunks(left: left, right: right, context: Self.diffContextLines)
        }
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    /// Whether two files hold the same bytes: sizes first, then a chunked
    /// read that stops at the first difference. Off the main actor.
    private nonisolated static func contentsAreEqual(_ a: URL, _ b: URL) async throws -> Bool {
        let task = Task.detached(priority: .userInitiated) { () throws -> Bool in
            let sizeA = try FileManager.default.attributesOfItem(
                atPath: a.path(percentEncoded: false))[.size] as? NSNumber
            let sizeB = try FileManager.default.attributesOfItem(
                atPath: b.path(percentEncoded: false))[.size] as? NSNumber
            guard sizeA == sizeB else { return false }
            let handleA = try FileHandle(forReadingFrom: a)
            let handleB = try FileHandle(forReadingFrom: b)
            defer {
                try? handleA.close()
                try? handleB.close()
            }
            let chunk = 1 << 20
            while true {
                try Task.checkCancellation()
                let blockA = try handleA.read(upToCount: chunk) ?? Data()
                let blockB = try handleB.read(upToCount: chunk) ?? Data()
                if blockA != blockB { return false }
                if blockA.isEmpty { return true }
            }
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }
}
