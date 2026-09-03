import Foundation
import Observation

/// How a destination conflict (file already exists) is resolved.
/// Binding for the UI layer (M5b/T4).
public enum ConflictResolution: Sendable, Equatable { case overwrite, skip, rename }

/// Why `TransferQueueViewModel.cancelAll(reason:)` is being called
/// (connection-liveness plan, Task 8, fix round 1). Required, not a `Bool`
/// defaulting to `false`: a default meant a new call site could inherit
/// "not a drop" by writing nothing at all, and a reviewer flipping a single
/// literal at the one real call site was enough to silently revert the
/// whole feature with the full suite still green. Naming both cases makes
/// a wrong choice something that has to be TYPED, and — paired with a
/// behavioral test that drives the real give-up path — something that gets
/// caught when it is.
public enum CancelReason: Sendable, Equatable {
    /// A deliberate stop chosen by the person at the keyboard: the transfer
    /// bar's "Cancel all", or a teardown they asked for — disconnect, tab
    /// close, reconnect-in-place, cancelling a connection attempt. Swept
    /// items read `.cancelled`.
    case userRequested
    /// The connection was found gone (liveness give-up). The running item
    /// fails with a localized "connection lost" reason and every
    /// queued/resolving item is marked the same way and kept — see
    /// `cancelAll(reason:)`'s own doc comment for the full contract.
    case connectionLost
}

/// Describes a concrete destination conflict for the `ConflictDecider`.
public struct TransferConflict: Sendable, Equatable {
    public let fileName: String
    public let destinationDirectory: String
    public let direction: TransferDirection
    /// true when this conflict belongs to a recursive folder transfer —
    /// the sheet then labels Cancel as "Cancel folder transfer", because
    /// cancelling aborts the WHOLE group (M6a behavior, M6b labeling).
    public let isPartOfFolderTransfer: Bool

    public init(
        fileName: String, destinationDirectory: String,
        direction: TransferDirection, isPartOfFolderTransfer: Bool = false
    ) {
        self.fileName = fileName
        self.destinationDirectory = destinationDirectory
        self.direction = direction
        self.isPartOfFolderTransfer = isPartOfFolderTransfer
    }
}

/// UI decider. Returning nil == "Cancel" (item becomes `.cancelled`).
/// `applyToAll == true` sets the decision as a rule for the rest of the queue.
public typealias ConflictDecider =
    @Sendable (TransferConflict) async -> (resolution: ConflictResolution, applyToAll: Bool)?

/// A cross-backend transfer's destination label (M16): the target session's
/// display name and protocol kind. Set only for cross-session transfers so
/// the transfer row can show where a file is going and with which backend.
public struct CrossBackendTarget: Equatable, Sendable {
    public var name: String
    public var kind: ConnectionKind
    public init(name: String, kind: ConnectionKind) {
        self.name = name
        self.kind = kind
    }
}

/// UI state of a serial transfer queue (FIFO).
///
/// Replaces the single-transfer `TransferViewModel`: `enqueue` never discards
/// anything, it always enqueues and restarts a sleeping worker if needed.
///
/// Parallelism (M5c/T4): up to `maxConcurrent` transfers run at once. Slots are
/// filled in strict FIFO order from `order`; a slot that frees up is handed to
/// the next queued item (never a later one). The class is `@MainActor`; each
/// transfer's `copyFile` runs in its own task in `runningTransferTasks` (keyed
/// by item id, so `cancelAll` can cancel every in-flight transfer) and yields
/// the MainActor while transferring. Conflict prompts still serialize: at most
/// one decider prompt is open at a time, gated FIFO across slots.
@Observable
@MainActor
public final class TransferQueueViewModel {
    public struct Item: Identifiable, Equatable {
        public enum Status: Equatable {
            case queued
            case running(TransferProgress)
            case finished
            case failed(String)      // localized message
            case cancelled
            case skipped             // conflict resolved via `.skip` ("skipped")
            case interrupted         // connection lost mid-transfer; resumable (M5d/T3)

            /// true while this item is actively transferring — the UI needs this.
            public var isRunning: Bool {
                if case .running = self { return true }
                return false
            }

            /// true once this item has reached a terminal state. The group
            /// accounting (M5b/T3) decrements exactly at the transition to
            /// terminal — this predicate is the pivot for that.
            ///
            /// `.interrupted` is terminal (M5d/T3): the transfer is no longer
            /// running and the group accounting must count it exactly once,
            /// like any other terminal state. `retryInterrupted` re-enqueues a
            /// fresh `.queued` run rather than reviving the interrupted item's
            /// group membership.
            public var isTerminal: Bool {
                switch self {
                case .finished, .failed, .cancelled, .skipped, .interrupted: return true
                case .queued, .running: return false
                }
            }

            /// true exactly while the person at the keyboard can still stop
            /// this item: it has not started, or it is transferring right
            /// now. The transfer bar offers its per-row cancel for these two
            /// states and for no other, and `cancel(itemID:)` acts on these
            /// two and on no other — one predicate, so the button that is
            /// shown and the call that is answered can never disagree.
            ///
            /// Written as an exhaustive switch rather than as `!isTerminal`,
            /// even though the two coincide today: a later non-terminal
            /// state has to be listed here before this file compiles again,
            /// which is where the question "can a user cancel that one?"
            /// gets asked.
            public var isCancellable: Bool {
                switch self {
                case .queued, .running: return true
                case .finished, .failed, .cancelled, .skipped, .interrupted: return false
                }
            }
        }
        public let id: UUID
        public internal(set) var fileName: String   // `.rename` updates the displayed name
        public let direction: TransferDirection
        public internal(set) var status: Status
        /// The full path this item READS FROM — `Job.sourcePath`, carried
        /// onto the item so a row can answer "which file, and where is it
        /// going?" and not only "what is it called?". Never rewritten by a
        /// `.rename` resolution: renaming picks a free name at the
        /// DESTINATION, and the source is still the file it was.
        ///
        /// Which side of the transfer this path lives on is decided by
        /// `direction` together with `crossRemote` — see `TransferRowPaths`,
        /// the one place that mapping is written down.
        public let sourcePath: String
        /// Opaque reference to the tab this item writes INTO (M8b) — `nil` for
        /// same-session transfers. Used only by `hasActiveItems`, so a later
        /// task can warn before closing a tab that other tabs are still
        /// streaming to; never shown in this item's own display.
        public let destinationTabID: UUID?
        /// True only for editor write-backs enqueued via `enqueueEditUpload`
        /// (M9b) — the audit recorder maps a finished item with this flag to
        /// the `.editUpload` kind instead of the plain `.transferFinished`
        /// kind. `false` on every other path.
        public let isEditUpload: Bool
        /// The destination directory this item writes INTO (M9b/T4 review,
        /// finding 3) — the audit log spec requires "Richtung, Name, Ziel"
        /// (direction, name, destination); mirrors `Job.destinationDirectory`
        /// exactly, threaded through every construction site the same way
        /// `isEditUpload` is.
        public let destinationDirectory: String
        /// The full path this item WRITES — `destinationDirectory` joined
        /// with the name the transfer actually uses, by `RemotePath.join`,
        /// the engine's own join.
        ///
        /// Stored rather than derived from `destinationDirectory` +
        /// `fileName`, because `fileName` is a display LABEL and not always
        /// a name: `addTerminalItem` appends " →" to a skipped symlink and
        /// "/" to an expansion failure, so a rebuilt path would carry the
        /// decoration into the transfer row's hint and onto the pasteboard.
        ///
        /// A `.rename` resolution moves both this and `fileName`, together,
        /// at the single choke point `applyEffectiveName(_:to:in:)` — they
        /// are two spellings of one fact, and `renamedItemsDestinationPathFollowsTheEffectiveName`
        /// is what keeps the second one from going stale.
        public internal(set) var destinationPath: String
        /// Whether the destination backend supports append-based resume (M16).
        /// Read from `destination.supportsAppendResume` at enqueue; `false`
        /// for an S3 destination. Drives the passive resume warning in the
        /// transfer row. `true` for terminal skip/error items (no transfer).
        public let destinationSupportsResume: Bool
        /// True for a remote→remote transfer routed through this app (M8b) —
        /// mirrors `Job.crossRemote`. Such a transfer is enqueued with
        /// `direction == .upload` (the target-write side is what the tab
        /// indicator reflects), so direction alone would call its source a
        /// file on this machine. This flag is the only thing on the item
        /// that tells the two apart, which is why `TransferRowPaths` reads
        /// it and why removing it would silently mislabel one side of every
        /// cross-session transfer.
        public let crossRemote: Bool
        /// Cross-backend destination label (M16): the target session's name +
        /// kind, `nil` for same-session transfers. The queue holds only the
        /// opaque `destinationTabID`, so the App supplies this at enqueue.
        public let crossBackendTarget: CrossBackendTarget?
    }

    public private(set) var items: [Item] = []

    /// true while any item is queued/running (sidebar gate), and the gate
    /// the transfer bar's "Cancel all" reads.
    ///
    /// Written on `Status.isCancellable` rather than on a hand-listed pair
    /// of states, so this and the per-row cancel are ONE predicate. Two
    /// spellings that denote the same set today are two spellings that a
    /// later non-terminal status splits apart: `isCancellable`'s exhaustive
    /// switch refuses to compile until somebody decides, an inline
    /// `status == .queued || status.isRunning` compiles unchanged and
    /// silently answers "not active" — and the row would then offer a
    /// cancel on an item "Cancel all" says is not there.
    public var isActive: Bool {
        items.contains { $0.status.isCancellable }
    }

    /// Number of open (queued+running) items — for the "n pending" label.
    /// The same predicate as `isActive`, for the same reason: the header's
    /// count and the button beside it must not be able to disagree.
    public var pendingCount: Int {
        items.reduce(into: 0) { count, item in
            if item.status.isCancellable { count += 1 }
        }
    }

    /// true if any item is in the `.interrupted` state (M5d/T3) — drives the
    /// "Resume interrupted" banner (M5d/T4) and gates `retryInterrupted`.
    public var hasInterrupted: Bool {
        items.contains { $0.status == .interrupted }
    }

    /// True while any non-terminal item targets the given tab (M8b) — the
    /// app asks every OTHER tab's queue before closing a tab, so a close
    /// can warn when it would sever incoming cross-session streams.
    public func hasActiveItems(destinationTabID: UUID) -> Bool {
        items.contains { $0.destinationTabID == destinationTabID && !$0.status.isTerminal }
    }

    /// UI decider for destination conflicts. `nil` (default) ⇒ silent overwrite
    /// as in M5a. Awaited serially by the worker — exactly one open prompt.
    public var conflictDecider: ConflictDecider?

    /// Maximum number of transfers that may run at once (clamped to 1...8,
    /// default 3). ContentView sets this from the SettingsStore at session start
    /// and on change. A change affects FUTURE slot assignments only — transfers
    /// already running are never interrupted; raising the limit fills any freed
    /// slots immediately, lowering it lets the extra transfers finish naturally.
    public var maxConcurrent: Int = 3 {
        didSet {
            let clamped = min(8, max(1, maxConcurrent))
            if maxConcurrent != clamped {
                // Self-assignment does NOT re-enter didSet, so fall through to
                // the kick below instead of relying on a second pass.
                maxConcurrent = clamped
            }
            // A raised limit may open new slots for queued items; kicking is a
            // safe no-op when nothing is waiting or all slots are busy.
            kickWorker()
        }
    }

    /// App-global limiter injected by the app layer (M8a). nil = unthrottled
    /// (tests, CLI). All queues of a window share one instance, so limits
    /// apply in aggregate across tabs.
    public var limiter: BandwidthLimiter?

    /// Direction of the most recently STARTED job — drives the tab activity
    /// indicator's color (M8a; spec 2: on simultaneous both-direction
    /// activity the last started one wins).
    public private(set) var lastStartedDirection: TransferDirection?

    /// Direction to display in the tab activity indicator (M8a T5 review,
    /// finding 4). `lastStartedDirection` alone is nil on a fresh queue and
    /// STALE between a finished transfer and the next one starting — a
    /// freshly queued item would then briefly show the previous (or no)
    /// direction/color instead of its own. This falls back to the first
    /// still-queued item's direction whenever nothing is currently running;
    /// as soon as a transfer actually starts, `lastStartedDirection` (which
    /// spec 2 says should win on simultaneous both-direction activity) takes
    /// over again.
    public var displayDirection: TransferDirection? {
        if items.contains(where: { $0.status.isRunning }) {
            return lastStartedDirection
        }
        return items.first(where: { $0.status == .queued })?.direction
    }

    /// A compact roll-up of this queue's activity for the menu-bar panel
    /// (M11n). `nil` when the queue is idle. The fold lives in a pure static
    /// helper so it is unit-testable without driving the queue.
    public var activitySummary: TransferActivitySummary? {
        Self.activitySummary(for: items, direction: displayDirection)
    }

    /// Pure fold of a queue's items into a `TransferActivitySummary`. `nil`
    /// when nothing is queued or running. `fraction` is byte-weighted over
    /// running items with a known total; `bytesPerSecond` sums the running
    /// items that report a rate. Internal so tests (`@testable`) can call it
    /// with hand-built items.
    static func activitySummary(
        for items: [Item], direction: TransferDirection?
    ) -> TransferActivitySummary? {
        var runningCount = 0
        var pendingCount = 0
        var sumTransferred: UInt64 = 0
        var sumTotal: UInt64 = 0
        var anyKnownTotal = false
        var sumRate = 0.0
        var anyRate = false

        for item in items {
            switch item.status {
            case .queued:
                pendingCount += 1
            case let .running(progress):
                runningCount += 1
                if let total = progress.totalBytes, total > 0 {
                    sumTransferred += progress.bytesTransferred
                    sumTotal += total
                    anyKnownTotal = true
                }
                if let rate = progress.bytesPerSecond {
                    sumRate += rate
                    anyRate = true
                }
            case .finished, .failed, .cancelled, .skipped, .interrupted:
                continue
            }
        }

        guard runningCount > 0 || pendingCount > 0 else { return nil }

        let fraction = anyKnownTotal ? Double(sumTransferred) / Double(sumTotal) : nil
        let bytesPerSecond = anyRate ? sumRate : nil
        return TransferActivitySummary(
            runningCount: runningCount,
            pendingCount: pendingCount,
            fraction: fraction,
            bytesPerSecond: bytesPerSecond,
            direction: direction
        )
    }

    /// Monotonically increasing count of items that have transitioned into
    /// `.failed`, EVER — replaces the old item-based `failedCount` (M8a T5
    /// review, finding 2). `failedCount` could only ever compare against the
    /// CURRENT number of `.failed` items, which `clearCompleted()` removes:
    /// visit a tab (seen = failedCount), clean up completed items
    /// (failedCount drops back to 0), then a single new failure would still
    /// fail to exceed the stale watermark and the attention indicator would
    /// never re-light. This counter only ever grows, so the tab's
    /// `seenFailureCount` watermark (`SessionTab.seenFailureCount`) always
    /// detects a genuinely new failure. Incremented exactly once per
    /// non-terminal → `.failed` transition in `setStatus` — never on a
    /// repeated `setStatus` call for an already-terminal item.
    public private(set) var totalFailureCount = 0

    /// Optional audit-log sink (M9b/T2), default nil (no logging — matches
    /// ad-hoc/unstored sessions). Called EXACTLY once per item, at the same
    /// `wasTerminal` choke point in `setStatus` where `totalFailureCount`
    /// increments — never on a progress update (`.running` → `.running`)
    /// and never again once an item is already terminal. The App layer wires
    /// this to an `AuditRecorder.recordTransfer` closure for stored sessions.
    public var auditSink: ((Item) -> Void)?

    // MARK: - Private state

    private struct Job {
        let id: UUID
        let source: any RemoteFileSystem
        let sourcePath: String
        let destination: any RemoteFileSystem
        let destinationDirectory: String
        /// The destination name the transfer actually writes to. For a fresh
        /// enqueue this is the requested name; a retained interrupted job
        /// (M5d/T3) stores the POST-RENAME effective name here, so a resume
        /// continues the very file that was partially written.
        let fileName: String
        let direction: TransferDirection
        let onCompleted: (@MainActor () async -> Void)?
        /// Resume semantics for the engine (M5d/T3). `true` only for jobs
        /// re-enqueued by `retryInterrupted`: `TransferEngine.copyFile` then
        /// continues from the destination offset, and the queue's conflict
        /// check is bypassed (resuming IS the conflict decision).
        let resume: Bool
        /// Skips the destination conflict check by design (M5e/T3). `true` only
        /// for editor write-backs enqueued via `enqueueEditUpload`: writing the
        /// edited file back over the original IS the user's explicit intent, so
        /// no prompt is shown. Unlike `resume`, the engine still overwrites (no
        /// offset continuation). Default `false` on every other path.
        let bypassConflictCheck: Bool
        /// Opaque reference to the tab this job writes INTO (M8b) — carried
        /// through to the `Item` so `hasActiveItems` can find it; the job
        /// itself never dereferences it.
        let destinationTabID: UUID?
        /// True for a remote→remote transfer routed through this app (M8b): the
        /// stream is simultaneously a download from the source and an upload
        /// to the destination on this machine's link, so BOTH app-global
        /// buckets must pace it. Direction stays `.upload` regardless (the
        /// target-write side is what the tab indicator reflects).
        let crossRemote: Bool
        /// True only for editor write-back jobs (M9b) — carried through to
        /// the `Item` exactly like `destinationTabID`/`crossRemote` above, so
        /// every reconstruction site (retry, interrupt-retain) threads it
        /// instead of silently resetting to the default.
        let isEditUpload: Bool

        init(
            id: UUID, source: any RemoteFileSystem, sourcePath: String,
            destination: any RemoteFileSystem, destinationDirectory: String,
            fileName: String, direction: TransferDirection,
            onCompleted: (@MainActor () async -> Void)?, resume: Bool = false,
            bypassConflictCheck: Bool = false,
            destinationTabID: UUID? = nil, crossRemote: Bool = false,
            isEditUpload: Bool = false
        ) {
            self.id = id
            self.source = source
            self.sourcePath = sourcePath
            self.destination = destination
            self.destinationDirectory = destinationDirectory
            self.fileName = fileName
            self.direction = direction
            self.onCompleted = onCompleted
            self.resume = resume
            self.bypassConflictCheck = bypassConflictCheck
            self.destinationTabID = destinationTabID
            self.crossRemote = crossRemote
            self.isEditUpload = isEditUpload
        }
    }

    /// Error for when no free rename name could be found (Rule 5, limit reached).
    private struct NoFreeNameError: Error {}

    /// Result of the conflict check before the engine call.
    private enum Outcome {
        case proceed(fileName: String)      // (possibly renamed) destination name
        case skip                            // item → .skipped, no write
        case cancel                          // item → .cancelled
        case failed(message: String, error: Error)
    }

    private var jobs: [UUID: Job] = [:]
    private var order: [UUID] = []                                  // FIFO of queued ids
    private var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]
    /// Active `process` tasks, keyed by item id — one per occupied slot. Their
    /// count is the number of slots in use; `cancelAll` awaits them all.
    private var processTasks: [UUID: Task<Void, Never>] = [:]
    /// In-flight `copyFile` tasks, keyed by item id — one per transferring slot.
    /// `cancelAll` cancels every one (cooperative cancellation via T2).
    private var runningTransferTasks: [UUID: Task<Void, Error>] = [:]
    private var queueRule: ConflictResolution?                     // active "apply to all" rule; reset on drain
    /// Populated ONLY by `cancelAll(reason: .connectionLost)`, for the jobs that
    /// specific call is actively force-cancelling — `process`'s cancellation
    /// branch consumes (removes) an entry when it applies it, and
    /// `slotFinished` drops any leftover for a job that raced to `.finished`
    /// instead, so nothing here ever outlives the job it names.
    private var connectionLossReasons: [UUID: String] = [:]

    /// A minimal FIFO gate serializing conflict-decider prompts across slots:
    /// at most one prompt is open at a time, and waiters are woken in arrival
    /// order (no unfair wakeups). Only the `await decider(...)` call is gated —
    /// the rule/no-decider fast paths don't touch it.
    private let conflictGate = FIFOGate()

    /// Test hook (M6b): callers parked at the conflict-prompt gate.
    var conflictGateWaiterCount: Int { conflictGate.waiterCount }

    /// IDs of items CURRENTLY in `resolveConflictIfNeeded` (stat probe, decider
    /// prompt, rename probing) — dequeued but not yet registered in
    /// `runningTransferTasks`. Without tracking this window, `cancelAll` would
    /// miss these items (M5b/T2 review fix). An id is inserted right after
    /// dequeue and removed once its transfer is registered OR a terminal state
    /// is reached. A `Set` because multiple slots may resolve at once (M5c/T4).
    private var resolvingJobIDs: Set<UUID> = []

    // MARK: - Tree/group state (M5b/T3)

    /// Accounting for a recursive folder transfer. Reference type, so that
    /// scattered mutations (from `setStatus`, expansion, and `finishExpansion`)
    /// become visible without a re-assignment into `groups`.
    private final class TreeGroup {
        /// Not-yet-terminal items of this group.
        var remaining = 0
        /// Expansion has stopped running (regularly OR via cancel).
        var expansionDone = false
        /// Expansion walked the entire tree (was NOT cancelled).
        var expansionSucceeded = false
        /// At least one item has become `.finished`.
        var anyFinished = false
        /// onCompleted already fired — exactly-once latch.
        var fired = false
        let onCompleted: (@MainActor () async -> Void)?
        init(onCompleted: (@MainActor () async -> Void)?) { self.onCompleted = onCompleted }
    }

    private var groups: [UUID: TreeGroup] = [:]
    private var itemGroup: [UUID: UUID] = [:]                       // item id → group id
    private var expansionTasks: [UUID: Task<Void, Never>] = [:]     // group id → expansion task

    /// Clock hook for the rate window (M5c/T5), default the real
    /// `ContinuousClock`. Injectable so tests can drive a controlled tick
    /// source instead of depending on real wall-clock timing.
    private let now: @Sendable () -> ContinuousClock.Instant

    public init(now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now }) {
        self.now = now
    }

    // MARK: - Public API

    /// Enqueues and starts the worker if it's sleeping. ALWAYS enqueues —
    /// no more `isRunning`-based dropping.
    ///
    /// - Parameters:
    ///   - destinationTabID: Opaque reference to the tab this transfer writes
    ///     INTO (M8b) — `nil` (default) for a same-session transfer. Only
    ///     consumed by `hasActiveItems`.
    ///   - crossRemote: `true` for a remote→remote transfer routed through
    ///     this app (M8b) — the stream pays BOTH app-global bandwidth buckets
    ///     (real download from the source, real upload to the destination on
    ///     this machine's link). `false` (default) keeps the pre-M8b
    ///     single-bucket resolution.
    @discardableResult
    public func enqueue(
        fileName: String, direction: TransferDirection,
        source: any RemoteFileSystem, sourcePath: String,
        destination: any RemoteFileSystem, destinationDirectory: String,
        onCompleted: (@MainActor () async -> Void)?,
        destinationTabID: UUID? = nil, crossRemote: Bool = false,
        crossBackendTarget: CrossBackendTarget? = nil
    ) -> UUID {
        let id = UUID()
        jobs[id] = Job(
            id: id, source: source, sourcePath: sourcePath,
            destination: destination, destinationDirectory: destinationDirectory,
            fileName: fileName, direction: direction, onCompleted: onCompleted,
            destinationTabID: destinationTabID, crossRemote: crossRemote)
        order.append(id)
        items.append(Item(
            id: id, fileName: fileName, direction: direction, status: .queued,
            sourcePath: sourcePath,
            destinationTabID: destinationTabID, isEditUpload: false,
            destinationDirectory: destinationDirectory,
            destinationPath: RemotePath.join(destinationDirectory, fileName),
            destinationSupportsResume: destination.supportsAppendResume,
            crossRemote: crossRemote,
            crossBackendTarget: crossBackendTarget))
        kickWorker()
        return id
    }

    /// Enqueues an editor write-back: uploads `localURL` back to
    /// `remoteDirectory/fileName`, BYPASSING the conflict check by design
    /// (writing back is the user's explicit intent). Behaves like a normal
    /// item otherwise (bar, limits, slots, interrupted classification). The
    /// upload's source is the LOCAL file system (`source`) reading the temp
    /// file at `localURL`; `destination` is the remote file system (M5e/T3).
    @discardableResult
    public func enqueueEditUpload(
        fileName: String, localURL: URL,
        source: any RemoteFileSystem, destination: any RemoteFileSystem,
        remoteDirectory: String
    ) -> UUID {
        let id = UUID()
        jobs[id] = Job(
            id: id, source: source, sourcePath: localURL.path(percentEncoded: false),
            destination: destination, destinationDirectory: remoteDirectory,
            fileName: fileName, direction: .upload, onCompleted: nil,
            resume: false, bypassConflictCheck: true, isEditUpload: true)
        order.append(id)
        items.append(Item(
            id: id, fileName: fileName, direction: .upload, status: .queued,
            sourcePath: localURL.path(percentEncoded: false),
            destinationTabID: nil, isEditUpload: true,
            destinationDirectory: remoteDirectory,
            destinationPath: RemotePath.join(remoteDirectory, fileName),
            destinationSupportsResume: destination.supportsAppendResume,
            crossRemote: false,
            crossBackendTarget: nil))
        kickWorker()
        return id
    }

    /// Like `enqueueEditUpload`, but returns only once EXACTLY this write-back
    /// item is done (finished/failed/cancelled/interrupted). Throws on any
    /// non-success terminal state, mirroring `enqueueAndWait`. This is the
    /// serialization seam `EditSessionManager` uses to keep at most one
    /// write-back per edit in flight: it awaits completion here, then decides
    /// whether a coalesced save needs a fresh upload. Bypasses the conflict
    /// check exactly like `enqueueEditUpload` (same job construction).
    public func enqueueEditUploadAndWait(
        fileName: String, localURL: URL,
        source: any RemoteFileSystem, destination: any RemoteFileSystem,
        remoteDirectory: String
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            // Synchronous on the MainActor: enqueue first, then register the
            // waiter, before the worker can start — so no result misses it.
            let id = enqueueEditUpload(
                fileName: fileName, localURL: localURL,
                source: source, destination: destination,
                remoteDirectory: remoteDirectory)
            waiters[id] = continuation
        }
    }

    /// Like `enqueue`, but returns only once EXACTLY this item is done.
    /// Throws on failed/cancelled (Promise path: the Finder integration needs the file).
    public func enqueueAndWait(
        fileName: String, direction: TransferDirection,
        source: any RemoteFileSystem, sourcePath: String,
        destination: any RemoteFileSystem, destinationDirectory: String
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            // Synchronous on the MainActor: enqueue first, then register the
            // waiter, before the worker can even start running — so no result
            // can miss the waiter.
            let id = enqueue(
                fileName: fileName, direction: direction,
                source: source, sourcePath: sourcePath,
                destination: destination, destinationDirectory: destinationDirectory,
                onCompleted: nil)
            waiters[id] = continuation
        }
    }

    /// Enqueues an entire folder: creates destination directories (top-down)
    /// and enqueues every file as its own queue item. `onCompleted` fires exactly
    /// once when ALL items of the tree are terminal (finished/failed/skipped/
    /// cancelled) — even on partial failures. Symlinks are skipped (item with
    /// status `.skipped` and a " →" name suffix). Expansion errors (list/mkdir)
    /// appear as a `.failed` item under the folder name with a "/" suffix.
    ///
    /// The expansion runs as its own MainActor task BEFORE the transfers (BFS/DFS
    /// top-down): first `createDirectory(dest/dirName)`, then `list(source)` —
    /// files via `enqueue` (including T2 conflict logic), subdirectories recursively.
    ///
    /// onCompleted rule on cancellation: if the queue is COMPLETELY cancelled via
    /// `cancelAll` (no item reached `.finished` AND the expansion was cancelled
    /// rather than ending regularly), onCompleted does NOT fire — a refresh after
    /// a full cancellation would be pointless. But as soon as at least one item
    /// finished OR the expansion completed regularly, it fires.
    /// - Parameters:
    ///   - destinationTabID: Opaque reference to the tab this tree writes INTO
    ///     (M8b) — forwarded to EVERY expanded file item, so `hasActiveItems`
    ///     sees the whole tree, not just individual files.
    ///   - crossRemote: See `enqueue(...)` — forwarded to every expanded file
    ///     item so each pays both app-global buckets.
    public func enqueueTree(
        directoryName: String, direction: TransferDirection,
        source: any RemoteFileSystem, sourceDirectory: String,
        destination: any RemoteFileSystem, destinationDirectory: String,
        onCompleted: (@MainActor () async -> Void)?,
        destinationTabID: UUID? = nil, crossRemote: Bool = false,
        crossBackendTarget: CrossBackendTarget? = nil
    ) {
        let groupID = UUID()
        groups[groupID] = TreeGroup(onCompleted: onCompleted)
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.expandTree(
                    directoryName: directoryName, direction: direction,
                    source: source, sourceDirectory: sourceDirectory,
                    destination: destination, destinationDirectory: destinationDirectory,
                    group: groupID, destinationTabID: destinationTabID, crossRemote: crossRemote,
                    crossBackendTarget: crossBackendTarget)
                self.finishExpansion(groupID, succeeded: true)
            } catch {
                // Only cancellation propagates up to here — branch-local errors
                // are translated into `.failed` items in `expandTree`.
                self.finishExpansion(groupID, succeeded: false)
            }
        }
        expansionTasks[groupID] = task
    }

    /// Re-enqueues every `.interrupted` item against the NEW session's file
    /// systems, in their original (FIFO) order, with resume semantics (M5d/T3).
    ///
    /// The two parameters are the CURRENT session's local and remote file
    /// systems (`source` = local, `destination` = remote). Each item's
    /// `direction` decides which side is the transfer's source and which is
    /// its destination: an upload reads from `source` (local) and writes to
    /// `destination` (remote); a download swaps them. Only the file-system
    /// references change — the retained paths and the post-rename effective
    /// name stay, so the engine resumes the exact partial file.
    ///
    /// The re-enqueued jobs carry `resume: true` (engine continues from the
    /// destination offset) and BYPASS the queue's conflict check by design —
    /// resuming IS the conflict decision (documented). Items flip back to
    /// `.queued`; group membership is NOT revived (an interrupted tree item
    /// retries as an individual — the group already fired or died with the
    /// disconnect). Retry jobs have no waiter: the original `enqueueAndWait`
    /// continuation was already thrown at the interrupt (Promise contract), so
    /// a resumed transfer notifies nobody; a fresh Finder promise drop would
    /// create its own new item.
    public func retryInterrupted(source: any RemoteFileSystem, destination: any RemoteFileSystem) {
        // `items` preserves enqueue order, so filtering it yields the original
        // FIFO order of the interrupted items.
        let interruptedIDs = items.compactMap { $0.status == .interrupted ? $0.id : nil }
        for id in interruptedIDs {
            guard let retained = jobs[id] else { continue }
            // Direction picks which given FS is source vs. destination.
            let (transferSource, transferDestination): (any RemoteFileSystem, any RemoteFileSystem) =
                retained.direction == .upload ? (source, destination) : (destination, source)
            jobs[id] = Job(
                id: id, source: transferSource, sourcePath: retained.sourcePath,
                destination: transferDestination, destinationDirectory: retained.destinationDirectory,
                fileName: retained.fileName, direction: retained.direction,
                onCompleted: nil, resume: true,
                destinationTabID: retained.destinationTabID, crossRemote: retained.crossRemote,
                isEditUpload: retained.isEditUpload)
            order.append(id)
            setStatus(id, .queued)   // terminal → non-terminal: no group accounting
        }
        kickWorker()
    }

    /// Cancels everything: cancels the running transfer, queued → `.cancelled`,
    /// waiting continuations throw. Returns only after the worker has stopped.
    ///
    /// `reason` (connection-liveness plan, Task 8; required, not a `Bool`
    /// with a default — see `CancelReason`'s own doc comment for why) is
    /// the seam for a drop rather than a deliberate cancel: with
    /// `.connectionLost`, every item this call would otherwise mark
    /// `.cancelled` — the running transfer AND every queued/resolving item
    /// — becomes `.failed(reason)` instead, with the localized text
    /// resolved from `CoreL10n` here (never passed in from the App layer,
    /// which cannot see `CoreL10n` — it is internal to this module). A drop
    /// is not something the user chose, so it must not read the same as a
    /// deliberate cancel; and unlike `.interrupted`, no job is retained for
    /// either kind of item — a later retry re-enqueues fresh, through the
    /// ordinary conflict check, rather than resuming blind onto whatever
    /// the far side is now holding (no automatic resume, by design).
    ///
    /// A side effect worth naming rather than leaving incidental: marking a
    /// swept item `.failed` instead of `.cancelled` also runs it through
    /// `totalFailureCount`'s increment (`setStatus`'s own choke point,
    /// unchanged by this method), which feeds the tab's attention dot. That
    /// is correct here, not a leak — while `SessionTab.liveness == .lost`
    /// the maintainer's own ruling suppresses the attention dot in favor of
    /// the liveness dot, and once reconnected it returns pointing at
    /// exactly the transfers the drop killed.
    ///
    /// The running transfer is marked ONLY at the SAME choke point that
    /// already decides `.cancelled` vs `.finished` today — the
    /// `catch is CancellationError` branch in `process`, gated by
    /// `connectionLossReasons` (populated below) — never by writing `items`
    /// directly from here. A transfer whose `copyFile` had already
    /// returned successfully by the time `task.cancel()` runs below still
    /// takes the success branch there and finishes normally; only an
    /// ACTUAL cancellation can land on the reason this call supplies.
    ///
    /// `.interrupted` items are already terminal and are NOT swept here (M5d/T3):
    /// they are not in `order`, `resolvingJobIDs`, or `runningTransferTasks`, so
    /// they survive a teardown with their retained jobs intact — the queue
    /// outlives the session and a reconnect can still resume them.
    public func cancelAll(reason: CancelReason) async {
        let connectionLostReason: String? =
            reason == .connectionLost ? CoreL10n.string("core.transfer.connectionLost") : nil
        // 0. Stop and await any running tree expansion(s) BEFORE clearing queued
        //    items — so no new items can appear from here on (M5b/T3).
        //    `finishExpansion(succeeded: false)` marks the groups as cancelled;
        //    their onCompleted then only fires if an item had already become
        //    `.finished` (see `maybeFireGroup`).
        let expansions = expansionTasks
        expansionTasks.removeAll()
        for task in expansions.values { task.cancel() }
        for task in expansions.values { await task.value }
        // 1. Clear out every not-yet-started (queued) id.
        let queued = order
        order.removeAll()
        for id in queued {
            setStatus(id, connectionLostReason.map { .failed($0) } ?? .cancelled)
            jobs[id] = nil
            resumeWaiter(id, with: .failure(CancellationError()))
        }
        // 1b. Every slot CURRENTLY in `resolveConflictIfNeeded` (stat probe,
        //     decider prompt, rename probing): dequeued but not yet registered
        //     in `runningTransferTasks` — this window is covered here (M5b/T2
        //     review fix), now a set because several slots may resolve at once.
        //     Exactly-once: `process` sees the missing `jobs[id]` entry and does
        //     NOT touch status/waiter again.
        let resolving = resolvingJobIDs
        resolvingJobIDs.removeAll()
        for id in resolving {
            setStatus(id, connectionLostReason.map { .failed($0) } ?? .cancelled)
            jobs[id] = nil
            resumeWaiter(id, with: .failure(CancellationError()))
        }
        // 2. Cancel every active transfer — each copyFile ends with
        //    CancellationError (cooperative, T2); `process` marks its item
        //    `.cancelled`, or `.failed(connectionLostReason)` when this call
        //    was given one — `connectionLossReasons`, populated just below,
        //    is what tells `process` which of the two applies to a given id.
        if let connectionLostReason {
            for id in runningTransferTasks.keys {
                connectionLossReasons[id] = connectionLostReason
            }
        }
        for task in runningTransferTasks.values { task.cancel() }
        // 3. Await all slot tasks to unwind. `order` is now empty, so no slot
        //    re-fills; each `process` runs out and calls `slotFinished`. May
        //    block until an open decider prompt returns (documented/accepted) —
        //    but no slot transfers after cancel (see above). A snapshot of the
        //    task handles is stable even as `slotFinished` mutates the dict.
        let active = Array(processTasks.values)
        for task in active { await task.value }
    }

    /// Cancels EXACTLY ONE item, at the person's request — the transfer
    /// bar's per-row cancel. Returns `true` when the item was still open and
    /// this call took responsibility for it, `false` for an unknown id or an
    /// item that has already reached a terminal state (so a click on a stale
    /// row resurrects nothing).
    ///
    /// One item, and only that one. A file that belongs to a folder transfer
    /// is cancelled on its own here: the group's other items keep going, and
    /// the group's accounting simply counts this one as terminal like any
    /// other, so `onCompleted` still fires exactly once. That is the
    /// opposite of the conflict dialog's Cancel, which aborts the WHOLE
    /// folder via `cancelGroup` (M6a) — there the person is answering a
    /// question about the folder, here they are pointing at one row.
    ///
    /// The three states an open item can be in are handled where
    /// `cancelAll(reason: .userRequested)` handles them, for the same
    /// exactly-once reasons documented there:
    ///
    /// - **Queued**: dropped out of `order` and marked terminal right here,
    ///   synchronously, before any slot can pick it up. Its job is cleared
    ///   in the same statement run, so a later `process` cannot re-terminalize it.
    /// - **Resolving** (dequeued, inside `resolveConflictIfNeeded` — a stat
    ///   probe, an open decider prompt, rename probing — but not yet
    ///   registered as a running transfer): the same synchronous sweep.
    ///   `process` sees the missing `jobs[id]` entry when it wakes and
    ///   returns without touching status or waiter.
    /// - **Running**: cooperative cancellation ONLY. Nothing about the
    ///   item's state is written here; `process`'s `catch is
    ///   CancellationError` branch is the single choke point that marks it
    ///   `.cancelled`, resumes the waiter and frees the slot — which is also
    ///   what lets a transfer whose `copyFile` had already returned finish
    ///   normally instead of being retro-cancelled. `connectionLossReasons`
    ///   is deliberately not touched, so that branch lands on `.cancelled`
    ///   rather than on a "connection lost" failure: the person chose this.
    ///
    /// The freed slot is refilled by the ordinary `slotFinished` →
    /// `kickWorker` path, in FIFO order — cancelling the running item hands
    /// its slot to the next queued one rather than stalling the queue.
    @discardableResult
    public func cancel(itemID: UUID) -> Bool {
        if let position = order.firstIndex(of: itemID) {
            order.remove(at: position)
            setStatus(itemID, .cancelled)
            jobs[itemID] = nil
            resumeWaiter(itemID, with: .failure(CancellationError()))
            return true
        }
        if resolvingJobIDs.remove(itemID) != nil {
            setStatus(itemID, .cancelled)
            jobs[itemID] = nil
            resumeWaiter(itemID, with: .failure(CancellationError()))
            return true
        }
        if let transfer = runningTransferTasks[itemID] {
            transfer.cancel()
            return true
        }
        return false
    }

    /// Conflict-dialog "Cancel" on a tree item aborts the WHOLE folder
    /// transfer (M6a): sweeps this group's queued items, cancels its
    /// in-flight transfers cooperatively, and stops its expansion so no new
    /// items appear. Already-copied files stay in place (nothing is
    /// deleted). Built on the same exactly-once pattern as `cancelAll`:
    /// every swept id has its job cleared synchronously, so a later
    /// `process` guard (`jobs[id] != nil`) cannot double-terminalize it.
    /// Items of OTHER groups and ungrouped items are untouched.
    private func cancelGroup(_ groupID: UUID) {
        // Stop the expansion first — its task observes the cancellation at
        // its next checkpoint and runs `finishExpansion(succeeded: false)`.
        expansionTasks[groupID]?.cancel()
        // Sweep this group's queued (not yet started) items.
        let queuedGroupIDs = order.filter { itemGroup[$0] == groupID }
        order.removeAll { itemGroup[$0] == groupID }
        for id in queuedGroupIDs {
            setStatus(id, .cancelled)
            jobs[id] = nil
            resumeWaiter(id, with: .failure(CancellationError()))
        }
        // Sweep this group's items currently resolving a conflict in another
        // slot (their `process` bails on the missing job, exactly-once).
        let resolving = resolvingJobIDs.filter { itemGroup[$0] == groupID }
        resolvingJobIDs.subtract(resolving)
        for id in resolving {
            setStatus(id, .cancelled)
            jobs[id] = nil
            resumeWaiter(id, with: .failure(CancellationError()))
        }
        // Cancel this group's in-flight transfers cooperatively — each
        // `copyFile` throws `CancellationError` and its `process` marks the
        // item `.cancelled` (partial files stay, as in `cancelAll`).
        for (id, task) in runningTransferTasks where itemGroup[id] == groupID {
            task.cancel()
        }
    }

    /// Removes finished/failed/cancelled/skipped from the list. `.interrupted`
    /// items are KEPT (M5d/T3): they are resumable pending work — discarding
    /// them on "Clean up" would drop the retry metadata.
    public func clearCompleted() {
        items.removeAll { item in
            switch item.status {
            case .finished, .failed, .cancelled, .skipped: return true
            case .queued, .running, .interrupted: return false
            }
        }
    }

    // MARK: - Worker

    /// Fills free slots with queued items in strict FIFO order, up to
    /// `maxConcurrent`. Idempotent and safe to call repeatedly — from `enqueue`,
    /// when a slot frees (`slotFinished`), or when the limit is raised.
    ///
    /// The dequeued id is inserted into `resolvingJobIDs` SYNCHRONOUSLY here, at
    /// the moment the slot is committed. That closes the window between spawning
    /// a slot's task and its `process` body actually running: `cancelAll` can
    /// only interleave at an await, so from this synchronous commit onward the
    /// item is always covered by exactly one of the `cancelAll` sweeps
    /// (resolving → then running).
    private func kickWorker() {
        while processTasks.count < maxConcurrent, let jobID = nextQueuedID() {
            resolvingJobIDs.insert(jobID)
            let task = Task { @MainActor [weak self] in
                await self?.process(jobID)
                self?.slotFinished(jobID)
            }
            processTasks[jobID] = task
        }
    }

    /// A slot's `process` returned: free the slot and try to fill it with the
    /// next queued item (FIFO). Once nothing is left running or waiting, the
    /// batch-scoped "apply to all" rule expires (as in the old serial drain).
    private func slotFinished(_ jobID: UUID) {
        processTasks[jobID] = nil
        // Defensive: a job that raced to `.finished` between
        // `cancelAll(reason: .connectionLost)` marking it and its own task
        // actually returning never visits the cancellation branch that
        // would otherwise consume this entry — drop it here instead so it
        // cannot outlive the job it named.
        connectionLossReasons[jobID] = nil
        kickWorker()
        if processTasks.isEmpty && order.isEmpty {
            queueRule = nil
        }
    }

    private func nextQueuedID() -> UUID? {
        order.isEmpty ? nil : order.removeFirst()
    }

    private func process(_ jobID: UUID) async {
        // `resolvingJobIDs` already holds `jobID` (inserted in `kickWorker` when
        // the slot was committed). If `cancelAll` already cleared this job, bail
        // — status/waiter were handled there (exactly-once).
        guard let job = jobs[jobID] else { return }

        // Conflict check BEFORE the engine call; prompts serialize FIFO.
        // A resumed retry job (M5d/T3) bypasses it entirely: it already carries
        // its post-rename effective name and resuming IS the conflict decision.
        // An editor write-back (M5e/T3) bypasses it too — writing back over the
        // original is the user's explicit intent.
        let outcome: Outcome = (job.resume || job.bypassConflictCheck)
            ? .proceed(fileName: job.fileName)
            : await resolveConflictIfNeeded(job: job)

        // `cancelAll` may already have struck during the above await (stat
        // probe, decider, rename probing): status is then already `.cancelled`,
        // the waiter already thrown, `jobs[jobID]` already gone. Exactly-once:
        // do NOT resolve again here and do NOT transfer.
        guard jobs[jobID] != nil else { return }
        // The slot moves from "resolving" to "transferring" synchronously below
        // (no await in between) — `cancelAll`'s running-sweep covers it from here.
        resolvingJobIDs.remove(jobID)

        let effectiveFileName: String
        switch outcome {
        case .proceed(let name):
            effectiveFileName = name
            // On `.rename`, update the displayed name AND the path that name
            // spells out — see `applyEffectiveName`.
            if name != job.fileName {
                applyEffectiveName(name, to: jobID, in: job.destinationDirectory)
            }
        case .skip:
            setStatus(jobID, .skipped)
            jobs[jobID] = nil
            // onCompleted is NOT called; the waiter throws (the file never arrived).
            resumeWaiter(jobID, with: .failure(CancellationError()))
            return
        case .cancel:
            // Capture the group BEFORE setStatus — the terminal transition
            // removes the item's `itemGroup` entry.
            let groupID = itemGroup[jobID]
            setStatus(jobID, .cancelled)
            jobs[jobID] = nil
            resumeWaiter(jobID, with: .failure(CancellationError()))
            // Tree item: cancelling ONE conflict aborts the whole folder
            // transfer (M6a). Single-file items (no group) keep the old
            // behavior — only this item is cancelled.
            if let groupID { cancelGroup(groupID) }
            return
        case .failed(let message, let error):
            setStatus(jobID, .failed(message))
            jobs[jobID] = nil
            resumeWaiter(jobID, with: .failure(error))
            return
        }

        setStatus(jobID, .running(TransferProgress(bytesTransferred: 0, totalBytes: nil)))
        lastStartedDirection = job.direction

        // Ordered delivery: AsyncStream buffers in order, ONE consumer updates
        // the status — no task-per-chunk, no race with .finished.
        //
        // Rate/ETA (M5c/T5): computed HERE in the consumer, not in the engine —
        // a sliding ~3s window over (timestamp, bytes) pairs per transfer
        // (local in `rateWindow`, no cross-job state needed). ETA only when
        // both `totalBytes` and a rate are known.
        let (progressStream, progressContinuation) = AsyncStream<TransferProgress>.makeStream()
        let consumer = Task { @MainActor [weak self] in
            var rateWindow = RateWindow()
            for await progress in progressStream {
                guard let self else { return }
                let bytesPerSecond = rateWindow.record(bytes: progress.bytesTransferred, at: self.now())
                let etaSeconds: Double?
                if let total = progress.totalBytes, let rate = bytesPerSecond, rate > 0 {
                    let remaining = total > progress.bytesTransferred ? total - progress.bytesTransferred : 0
                    etaSeconds = Double(remaining) / rate
                } else {
                    etaSeconds = nil
                }
                let enriched = TransferProgress(
                    bytesTransferred: progress.bytesTransferred, totalBytes: progress.totalBytes,
                    bytesPerSecond: bytesPerSecond, etaSeconds: etaSeconds)
                self.setStatus(jobID, .running(enriched))
            }
        }

        // Only pull Sendable values into the transfer task (no Job/onCompleted).
        let source = job.source
        let sourcePath = job.sourcePath
        let destination = job.destination
        let destinationDirectory = job.destinationDirectory
        let fileName = effectiveFileName
        // Direction-dependent shared bucket (M6a): resolved HERE, at the
        // moment the transfer actually starts — a Settings change rebuilds
        // the bucket and therefore only applies to items starting next.
        let throttle: BandwidthBucket?
        let secondaryThrottle: BandwidthBucket?
        if job.crossRemote {
            // Cross-remote (M8b): the stream is upload to the target AND
            // download from the source — both app-global buckets pay.
            throttle = limiter?.uploadBucket
            secondaryThrottle = limiter?.downloadBucket
        } else {
            throttle = job.direction == .upload
                ? limiter?.uploadBucket : limiter?.downloadBucket
            secondaryThrottle = nil
        }
        // Resume flag (M5d/T3): only a retry job sets it — the engine then
        // continues from the destination offset instead of overwriting.
        let resume = job.resume
        let transfer = Task<Void, Error> {
            try await TransferEngine.copyFile(
                from: source, sourcePath: sourcePath,
                to: destination, destinationDirectory: destinationDirectory, fileName: fileName,
                resume: resume,
                throttle: throttle,
                secondaryThrottle: secondaryThrottle,
                onProgress: { progressContinuation.yield($0) }
            )
        }
        runningTransferTasks[jobID] = transfer

        do {
            try await transfer.value
            progressContinuation.finish()
            await consumer.value
            setStatus(jobID, .finished)
            jobs[jobID] = nil
            runningTransferTasks[jobID] = nil
            if let onCompleted = job.onCompleted { await onCompleted() }
            resumeWaiter(jobID, with: .success(()))
        } catch is CancellationError {
            progressContinuation.finish()
            await consumer.value
            // `connectionLossReasons` (connection-liveness plan, Task 8) is
            // populated ONLY by `cancelAll(reason: .connectionLost)`, for the
            // exact jobs THAT call force-cancelled — a plain user cancel
            // (`cancelAll(reason: .userRequested)`, or a tree `cancelGroup`)
            // never touches it, so those still land on `.cancelled` below.
            if let reason = connectionLossReasons.removeValue(forKey: jobID) {
                setStatus(jobID, .failed(reason))
            } else {
                setStatus(jobID, .cancelled)
            }
            jobs[jobID] = nil
            runningTransferTasks[jobID] = nil
            resumeWaiter(jobID, with: .failure(CancellationError()))
        } catch let error as RemoteFSError where error.isConnectionFailure {
            progressContinuation.finish()
            await consumer.value
            if job.bypassConflictCheck {
                // Editor write-back (M6a): NOT resumable — its temp source is
                // deleted by `stopAll` on disconnect, so a later resume would
                // visibly fail. Surface it as a plain failure instead; the
                // next editor save enqueues a fresh upload anyway.
                setStatus(jobID, .failed(CoreL10n.string("core.transfer.interrupted")))
                jobs[jobID] = nil
                runningTransferTasks[jobID] = nil
                resumeWaiter(jobID, with: .failure(error))
            } else if job.destinationTabID != nil {
                // Cross-session transfer (M8b review, finding 1): NOT
                // resumable. `retryInterrupted` always rebuilds an
                // `.interrupted` job against the CURRENT tab's own
                // source/destination file systems — for a job whose
                // destination is really ANOTHER tab's remote (frozen path,
                // possibly a now-gone session), that would silently retarget
                // the resumed stream at this tab's own remote, at the other
                // tab's path (and `resume: true` could even `.append` onto an
                // unrelated same-named file there). Surface it as a plain
                // failure instead, exactly like the edit-upload case above.
                setStatus(jobID, .failed(CoreL10n.string("core.transfer.interrupted")))
                jobs[jobID] = nil
                runningTransferTasks[jobID] = nil
                resumeWaiter(jobID, with: .failure(error))
            } else if !destination.supportsAppendResume {
                // Destination cannot append (e.g. S3, M13): a resume would
                // have to overwrite the whole object anyway, so a plain
                // retry from scratch is equivalent — classify as `.failed`
                // rather than offering a resume that can't actually resume.
                setStatus(jobID, .failed(CoreL10n.string("core.transfer.interrupted")))
                jobs[jobID] = nil
                runningTransferTasks[jobID] = nil
                resumeWaiter(jobID, with: .failure(error))
            } else {
                // Connection lost mid-transfer (M5d/T3): mark `.interrupted`
                // (NOT `.failed`) and RETAIN the job — under its EFFECTIVE
                // (post-rename) name — so a reconnect can resume the exact
                // partial file via `retryInterrupted`. The waiter still
                // throws (Promise contract), onCompleted does not fire. The
                // partial file stays at the destination as resume fodder.
                setStatus(jobID, .interrupted)
                jobs[jobID] = Job(
                    id: jobID, source: source, sourcePath: sourcePath,
                    destination: destination, destinationDirectory: destinationDirectory,
                    fileName: effectiveFileName, direction: job.direction,
                    onCompleted: nil, resume: false,
                    destinationTabID: job.destinationTabID, crossRemote: job.crossRemote,
                    // Defensive symmetry: edit uploads classify connection
                    // loss as .failed above (bypassConflictCheck), so a
                    // retained job can never carry isEditUpload == true
                    // today — forwarded anyway so a future reclassification
                    // cannot silently drop the flag (M9b/T2 review).
                    isEditUpload: job.isEditUpload)
                runningTransferTasks[jobID] = nil
                resumeWaiter(jobID, with: .failure(error))
            }
        } catch {
            progressContinuation.finish()
            await consumer.value
            setStatus(jobID, .failed(Self.message(for: error)))
            jobs[jobID] = nil
            runningTransferTasks[jobID] = nil
            resumeWaiter(jobID, with: .failure(error))
        }
    }

    // MARK: - Conflict logic

    /// Checks before the transfer whether the destination already exists, and
    /// resolves any conflict per the queue rule or `conflictDecider`.
    private func resolveConflictIfNeeded(job: Job) async -> Outcome {
        // Path join IDENTICAL to TransferEngine.copyFile (RemotePath.join).
        let destinationPath = RemotePath.join(job.destinationDirectory, job.fileName)
        do {
            _ = try await job.destination.stat(path: destinationPath)
        } catch RemoteFSError.notFound {
            return .proceed(fileName: job.fileName)   // no conflict
        } catch {
            return .failed(message: Self.message(for: error), error: error)
        }

        // Destination exists → conflict. Determine the resolution.
        let resolution: ConflictResolution
        if let rule = queueRule {
            resolution = rule                         // active rule: no prompt
        } else if let decider = conflictDecider {
            let conflict = TransferConflict(
                fileName: job.fileName,
                destinationDirectory: job.destinationDirectory,
                direction: job.direction,
                isPartOfFolderTransfer: itemGroup[job.id] != nil)
            // Serialize prompts across parallel slots: at most one decider is
            // open at a time, FIFO. Only the prompt itself is gated.
            await conflictGate.acquire()
            // Re-check: `cancelAll` may have fired while we waited for the gate.
            // Bail without prompting (and always release, so the gate never leaks).
            guard jobs[job.id] != nil else {
                conflictGate.release()
                return .cancel
            }
            // Re-check the rule too (M6a): an "apply to all" decision made
            // while this item waited at the gate answers its conflict as
            // well — prompting again would contradict the just-made rule.
            if let rule = queueRule {
                conflictGate.release()
                resolution = rule
            } else {
                let decision = await decider(conflict)
                // Set the rule BEFORE releasing the gate (M6a/T3 review
                // hardening): correctness must not depend on FIFOGate
                // resuming waiters via a scheduled (not inline) continuation.
                // A waiter woken synchronously by `release()` below would
                // otherwise race the (not-yet-set) rule.
                if let decision, decision.applyToAll { queueRule = decision.resolution }
                conflictGate.release()
                guard let decision else {
                    return .cancel                        // nil == cancel
                }
                resolution = decision.resolution
            }
        } else {
            resolution = .overwrite                   // default: silent overwrite (M5a)
        }

        switch resolution {
        case .overwrite:
            return .proceed(fileName: job.fileName)
        case .skip:
            return .skip
        case .rename:
            return await freeRenameOutcome(job: job)
        }
    }

    /// Finds a free name "name (2).ext", "name (3).ext", … via `stat` probing.
    private func freeRenameOutcome(job: Job) async -> Outcome {
        let (stem, ext) = Self.splitName(job.fileName)
        var counter = 2
        while counter <= 999 {
            let candidate = "\(stem) (\(counter))\(ext)"
            let candidatePath = RemotePath.join(job.destinationDirectory, candidate)
            do {
                _ = try await job.destination.stat(path: candidatePath)
                // exists → next candidate
            } catch RemoteFSError.notFound {
                return .proceed(fileName: candidate)  // free
            } catch {
                return .failed(message: Self.message(for: error), error: error)
            }
            counter += 1
        }
        return .failed(message: CoreL10n.string("core.transfer.noFreeName"), error: NoFreeNameError())
    }

    /// Splits a file name at the LAST dot into stem and extension (dot
    /// included). No dot (or a leading dot only) ⇒ empty extension.
    static func splitName(_ fileName: String) -> (stem: String, ext: String) {
        guard let dotIndex = fileName.lastIndex(of: "."), dotIndex != fileName.startIndex else {
            return (fileName, "")
        }
        return (String(fileName[..<dotIndex]), String(fileName[dotIndex...]))
    }

    // MARK: - Tree expansion (M5b/T3)

    /// Recursive top-down descent: first creates `dest/dirName`, then lists
    /// `sourceDirectory` and processes the entries (files → `enqueue`,
    /// subdirectories → recursive, symlinks → terminal `.skipped` item).
    /// Throws only `CancellationError`; branch-local list/mkdir errors are
    /// translated into `.failed` items and only end that branch.
    private func expandTree(
        directoryName: String, direction: TransferDirection,
        source: any RemoteFileSystem, sourceDirectory: String,
        destination: any RemoteFileSystem, destinationDirectory: String,
        group groupID: UUID, destinationTabID: UUID? = nil, crossRemote: Bool = false,
        crossBackendTarget: CrossBackendTarget? = nil
    ) async throws {
        try Task.checkCancellation()
        let destDir = RemotePath.join(destinationDirectory, directoryName)

        // Create the destination directory top-down.
        do {
            try await destination.createDirectory(at: destDir)
        } catch {
            try Task.checkCancellation()   // if it was cancellation, propagate it
            // The directory item itself lives IN the parent (`destinationDirectory`,
            // this call's own parameter) — `destDir` is the (failed-to-create)
            // directory, not its destination.
            addTerminalItem(
                group: groupID, name: directoryName + "/", sourcePath: sourceDirectory,
                direction: direction, status: .failed(Self.message(for: error)),
                destinationTabID: destinationTabID, destinationDirectory: destinationDirectory,
                destinationPath: destDir,
                crossRemote: crossRemote, crossBackendTarget: crossBackendTarget)
            return
        }

        // List the source directory.
        let entries: [RemoteFileItem]
        do {
            entries = try await source.list(path: sourceDirectory)
        } catch {
            try Task.checkCancellation()
            addTerminalItem(
                group: groupID, name: directoryName + "/", sourcePath: sourceDirectory,
                direction: direction, status: .failed(Self.message(for: error)),
                destinationTabID: destinationTabID, destinationDirectory: destinationDirectory,
                destinationPath: destDir,
                crossRemote: crossRemote, crossBackendTarget: crossBackendTarget)
            return
        }

        for entry in entries {
            try Task.checkCancellation()
            switch entry.kind {
            case .file:
                // File items go through the normal enqueue/conflict logic.
                let id = enqueue(
                    fileName: entry.name, direction: direction,
                    source: source, sourcePath: entry.path,
                    destination: destination, destinationDirectory: destDir,
                    onCompleted: nil, destinationTabID: destinationTabID, crossRemote: crossRemote,
                    crossBackendTarget: crossBackendTarget)
                registerGroupItem(id, group: groupID)
            case .directory:
                try await expandTree(
                    directoryName: entry.name, direction: direction,
                    source: source, sourceDirectory: entry.path,
                    destination: destination, destinationDirectory: destDir,
                    group: groupID, destinationTabID: destinationTabID, crossRemote: crossRemote,
                    crossBackendTarget: crossBackendTarget)
            case .symlink, .other:
                // Don't follow: terminal `.skipped` item with a " →" suffix.
                // Lives IN this level's directory, exactly like the file
                // items enqueued above.
                addTerminalItem(
                    group: groupID, name: entry.name + " →", sourcePath: entry.path,
                    direction: direction, status: .skipped, destinationTabID: destinationTabID,
                    destinationDirectory: destDir,
                    destinationPath: RemotePath.join(destDir, entry.name),
                    crossRemote: crossRemote, crossBackendTarget: crossBackendTarget)
            }
        }
    }

    // MARK: - Group accounting (M5b/T3)

    /// Assigns an already-enqueued item to a group and counts it as open. Must
    /// run synchronously right after `enqueue` (no await in between), otherwise
    /// the worker could terminalize the item before it's registered.
    private func registerGroupItem(_ id: UUID, group groupID: UUID) {
        guard let group = groups[groupID] else { return }
        group.remaining += 1
        itemGroup[id] = groupID
    }

    /// Appends an item that's IMMEDIATELY terminal (symlink skip or expansion
    /// error) and routes it through the same choke point as every other item.
    private func addTerminalItem(
        group groupID: UUID, name: String, sourcePath: String,
        direction: TransferDirection, status: Item.Status, destinationTabID: UUID? = nil,
        destinationDirectory: String, destinationPath: String, crossRemote: Bool = false,
        crossBackendTarget: CrossBackendTarget? = nil
    ) {
        let id = UUID()
        items.append(Item(
            id: id, fileName: name, direction: direction, status: .queued,
            sourcePath: sourcePath,
            destinationTabID: destinationTabID, isEditUpload: false,
            destinationDirectory: destinationDirectory,
            destinationPath: destinationPath,
            destinationSupportsResume: true,
            crossRemote: crossRemote,
            crossBackendTarget: crossBackendTarget))
        registerGroupItem(id, group: groupID)
        setStatus(id, status)   // triggers groupItemBecameTerminal
    }

    /// Called from the `setStatus` choke point as soon as a group item becomes
    /// terminal: decrements and checks for group completion.
    private func groupItemBecameTerminal(_ id: UUID, status: Item.Status) {
        guard let groupID = itemGroup.removeValue(forKey: id), let group = groups[groupID] else { return }
        group.remaining -= 1
        if case .finished = status { group.anyFinished = true }
        maybeFireGroup(groupID)
    }

    /// Marks a group's expansion as finished (regularly or cancelled) and
    /// checks for completion — items could already all be terminal beforehand.
    private func finishExpansion(_ groupID: UUID, succeeded: Bool) {
        expansionTasks[groupID] = nil
        guard let group = groups[groupID] else { return }
        group.expansionDone = true
        group.expansionSucceeded = succeeded
        maybeFireGroup(groupID)
    }

    /// Fires `onCompleted` exactly once, once ALL items are terminal AND the
    /// expansion is no longer running. On a full cancellation (nothing
    /// finished, expansion cancelled), only cleans up without firing.
    private func maybeFireGroup(_ groupID: UUID) {
        guard let group = groups[groupID], !group.fired else { return }
        guard group.expansionDone, group.remaining == 0 else { return }
        guard group.anyFinished || group.expansionSucceeded else {
            groups[groupID] = nil   // full cancellation: no refresh needed
            return
        }
        group.fired = true
        let onCompleted = group.onCompleted
        groups[groupID] = nil
        if let onCompleted {
            Task { @MainActor in await onCompleted() }
        }
    }

    // MARK: - Helpers

    /// Writes a `.rename` resolution's effective name onto the item — the
    /// displayed name and the destination path it spells out, in one
    /// statement, because they are two spellings of one fact and a caller
    /// that updated only the first would leave the row pointing its hint
    /// (and its "Copy paths") at a file that was never written.
    ///
    /// The join is `RemotePath.join`, the same one `resolveConflictIfNeeded`
    /// probes with and `TransferEngine.copyFile` writes with.
    private func applyEffectiveName(_ name: String, to id: UUID, in directory: String) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].fileName = name
        items[index].destinationPath = RemotePath.join(directory, name)
    }

    private func setStatus(_ id: UUID, _ status: Item.Status) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        let wasTerminal = items[index].status.isTerminal
        items[index].status = status
        // The only choke point of the group accounting: decrement exactly at
        // the non-terminal → terminal transition (M5b/T3). Scattered
        // decrements would miss cases.
        if status.isTerminal && !wasTerminal {
            // `totalFailureCount` (M8a T5 review, finding 2) increments here,
            // at the same non-terminal → terminal choke point, so a job that
            // is already terminal (`wasTerminal == true`) can never
            // double-count even if `setStatus` were ever called again with
            // the same `.failed` status.
            if case .failed = status { totalFailureCount += 1 }
            groupItemBecameTerminal(id, status: status)
            auditSink?(items[index])
        }
    }

    private func resumeWaiter(_ id: UUID, with result: Result<Void, Error>) {
        guard let continuation = waiters.removeValue(forKey: id) else { return }
        continuation.resume(with: result)
    }

    /// Public: the App layer reuses this mapping for editor-open failures (M6a).
    public static func message(for error: Error) -> String {
        switch error {
        case RemoteFSError.notFound(let path):
            return String(format: CoreL10n.string("core.transfer.notFound %@"), path)
        case RemoteFSError.permissionDenied(let path):
            return String(format: CoreL10n.string("core.error.permissionDenied %@"), path)
        case RemoteFSError.connectionFailed(let reason):
            return String(format: CoreL10n.string("core.error.connectionLost %@"), reason)
        case RemoteFSError.protocolError(let reason):
            return String(format: CoreL10n.string("core.transfer.failed %@"), reason)
        // The SECOND `message(for:)` this project has (Task 3 review, I-1).
        // A folder dropped onto an S3 bucket-list root makes
        // `TransferEngine` call `createDirectory("/name")`, which
        // `S3FileSystem` refuses — and this switch's `default:` below
        // renders `String(describing:)`, so without this arm the queue
        // showed the raw case. It reads exactly like the browser's arm in
        // `RemoteBrowserViewModel.message(for:path:)`, deliberately: a new
        // `RemoteFSError` case has two dumping `default:`s to close, not one.
        case RemoteFSError.bucketLevelRefused(let operation, _):
            return CoreL10n.string(operation.refusalMessageKey)
        // The second arm the same lesson asks for: a new `RemoteFSError`
        // case has TWO dumping `default:`s to close, in two view models
        // both called `message(for:)`.
        case RemoteFSError.crossBucketRenameRefused:
            return CoreL10n.string("core.connect.s3CrossBucketRename")
        default:
            return String(format: CoreL10n.string("core.transfer.failed %@"), String(describing: error))
        }
    }
}

/// Sliding ~3s window over (timestamp, bytesTransferred) samples, used to
/// derive a smoothed instantaneous transfer rate (M5c/T5). Scoped locally to
/// each transfer's progress-consumer task in `process` — no cross-job
/// storage needed, it's dropped along with the consumer once the transfer
/// ends.
struct RateWindow {
    private static let windowLength = Duration.seconds(3)

    private var samples: [(time: ContinuousClock.Instant, bytes: UInt64)] = []

    /// Records a new sample and returns the current rate in bytes/second —
    /// `nil` until at least two samples span a positive duration (i.e. never
    /// on the very first sample).
    mutating func record(bytes: UInt64, at time: ContinuousClock.Instant) -> Double? {
        samples.append((time, bytes))
        // Drop samples older than the window, but always keep at least one
        // as the baseline for the rate calculation below.
        while samples.count > 1, time - samples[0].time > Self.windowLength {
            samples.removeFirst()
        }
        guard let oldest = samples.first, oldest.time < time else { return nil }
        let elapsedSeconds = (time - oldest.time).secondsAsDouble
        guard elapsedSeconds > 0 else { return nil }
        let delta = bytes >= oldest.bytes ? bytes - oldest.bytes : 0
        return Double(delta) / elapsedSeconds
    }
}

/// Minimal FIFO async gate (binary semaphore). `acquire()` suspends callers in
/// arrival order when the gate is held; each `release()` wakes exactly the
/// longest-waiting caller — strictly fair, no unfair wakeups. Confined to the
/// `TransferQueueViewModel`'s MainActor, so its mutable state is race-free.
@MainActor
final class FIFOGate {
    private var available = true
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if available {
            available = false
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty {
            available = true
        } else {
            // Hand the gate directly to the next waiter (stays held, FIFO).
            waiters.removeFirst().resume()
        }
    }

    /// Number of callers currently suspended in `acquire()` — test hook
    /// (M6b) so gate-interleaving tests can wait deterministically for a
    /// sibling to be parked instead of yield-spinning.
    var waiterCount: Int { waiters.count }
}
