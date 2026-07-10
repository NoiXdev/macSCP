import Foundation
import Observation

/// How a destination conflict (file already exists) is resolved.
/// Binding for the UI layer (M5b/T4).
public enum ConflictResolution: Sendable, Equatable { case overwrite, skip, rename }

/// Describes a concrete destination conflict for the `ConflictDecider`.
public struct TransferConflict: Sendable, Equatable {
    public let fileName: String
    public let destinationDirectory: String
    public let direction: TransferDirection

    public init(fileName: String, destinationDirectory: String, direction: TransferDirection) {
        self.fileName = fileName
        self.destinationDirectory = destinationDirectory
        self.direction = direction
    }
}

/// UI decider. Returning nil == "Cancel" (item becomes `.cancelled`).
/// `applyToAll == true` sets the decision as a rule for the rest of the queue.
public typealias ConflictDecider =
    @Sendable (TransferConflict) async -> (resolution: ConflictResolution, applyToAll: Bool)?

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
        }
        public let id: UUID
        public internal(set) var fileName: String   // `.rename` updates the displayed name
        public let direction: TransferDirection
        public internal(set) var status: Status
    }

    public private(set) var items: [Item] = []

    /// true while any item is queued/running (sidebar gate).
    public var isActive: Bool {
        items.contains { $0.status == .queued || $0.status.isRunning }
    }

    /// Number of open (queued+running) items — for the "n pending" label.
    public var pendingCount: Int {
        items.reduce(into: 0) { count, item in
            if item.status == .queued || item.status.isRunning { count += 1 }
        }
    }

    /// true if any item is in the `.interrupted` state (M5d/T3) — drives the
    /// "Resume interrupted" banner (M5d/T4) and gates `retryInterrupted`.
    public var hasInterrupted: Bool {
        items.contains { $0.status == .interrupted }
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

    /// Bandwidth ceilings in bytes/second, direction-dependent (M5c/T5); `0`
    /// (default) = unlimited, matching `TransferEngine.copyFile`'s
    /// `bytesPerSecondLimit` semantics. `ContentView` sets these from
    /// `SettingsStore` at session start and via `.onChange`. Read in
    /// `process` at the moment a slot actually starts transferring, so a
    /// change applies to items STARTING after it — already-running transfers
    /// keep whatever limit they started with.
    public var uploadLimitBytesPerSec: Int = 0
    public var downloadLimitBytesPerSec: Int = 0

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

        init(
            id: UUID, source: any RemoteFileSystem, sourcePath: String,
            destination: any RemoteFileSystem, destinationDirectory: String,
            fileName: String, direction: TransferDirection,
            onCompleted: (@MainActor () async -> Void)?, resume: Bool = false,
            bypassConflictCheck: Bool = false
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

    /// A minimal FIFO gate serializing conflict-decider prompts across slots:
    /// at most one prompt is open at a time, and waiters are woken in arrival
    /// order (no unfair wakeups). Only the `await decider(...)` call is gated —
    /// the rule/no-decider fast paths don't touch it.
    private let conflictGate = FIFOGate()

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
    @discardableResult
    public func enqueue(
        fileName: String, direction: TransferDirection,
        source: any RemoteFileSystem, sourcePath: String,
        destination: any RemoteFileSystem, destinationDirectory: String,
        onCompleted: (@MainActor () async -> Void)?
    ) -> UUID {
        let id = UUID()
        jobs[id] = Job(
            id: id, source: source, sourcePath: sourcePath,
            destination: destination, destinationDirectory: destinationDirectory,
            fileName: fileName, direction: direction, onCompleted: onCompleted)
        order.append(id)
        items.append(Item(id: id, fileName: fileName, direction: direction, status: .queued))
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
            resume: false, bypassConflictCheck: true)
        order.append(id)
        items.append(Item(id: id, fileName: fileName, direction: .upload, status: .queued))
        kickWorker()
        return id
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
    public func enqueueTree(
        directoryName: String, direction: TransferDirection,
        source: any RemoteFileSystem, sourceDirectory: String,
        destination: any RemoteFileSystem, destinationDirectory: String,
        onCompleted: (@MainActor () async -> Void)?
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
                    group: groupID)
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
                onCompleted: nil, resume: true)
            order.append(id)
            setStatus(id, .queued)   // terminal → non-terminal: no group accounting
        }
        kickWorker()
    }

    /// Cancels everything: cancels the running transfer, queued → `.cancelled`,
    /// waiting continuations throw. Returns only after the worker has stopped.
    ///
    /// `.interrupted` items are already terminal and are NOT swept here (M5d/T3):
    /// they are not in `order`, `resolvingJobIDs`, or `runningTransferTasks`, so
    /// they survive a teardown with their retained jobs intact — the queue
    /// outlives the session and a reconnect can still resume them.
    public func cancelAll() async {
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
            setStatus(id, .cancelled)
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
            setStatus(id, .cancelled)
            jobs[id] = nil
            resumeWaiter(id, with: .failure(CancellationError()))
        }
        // 2. Cancel every active transfer — each copyFile ends with
        //    CancellationError (cooperative, T2) and `process` marks its item
        //    `.cancelled`.
        for task in runningTransferTasks.values { task.cancel() }
        // 3. Await all slot tasks to unwind. `order` is now empty, so no slot
        //    re-fills; each `process` runs out and calls `slotFinished`. May
        //    block until an open decider prompt returns (documented/accepted) —
        //    but no slot transfers after cancel (see above). A snapshot of the
        //    task handles is stable even as `slotFinished` mutates the dict.
        let active = Array(processTasks.values)
        for task in active { await task.value }
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
            // On `.rename`, update the displayed name.
            if name != job.fileName, let index = items.firstIndex(where: { $0.id == jobID }) {
                items[index].fileName = name
            }
        case .skip:
            setStatus(jobID, .skipped)
            jobs[jobID] = nil
            // onCompleted is NOT called; the waiter throws (the file never arrived).
            resumeWaiter(jobID, with: .failure(CancellationError()))
            return
        case .cancel:
            setStatus(jobID, .cancelled)
            jobs[jobID] = nil
            resumeWaiter(jobID, with: .failure(CancellationError()))
            return
        case .failed(let message, let error):
            setStatus(jobID, .failed(message))
            jobs[jobID] = nil
            resumeWaiter(jobID, with: .failure(error))
            return
        }

        setStatus(jobID, .running(TransferProgress(bytesTransferred: 0, totalBytes: nil)))

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
        // Direction-dependent limit (M5c/T5): only read HERE, at the moment the
        // transfer actually starts — a change to `uploadLimitBytesPerSec`/
        // `downloadLimitBytesPerSec` therefore only applies to items starting
        // next; already-running transfers keep the limit they started with.
        let bytesPerSecondLimit = job.direction == .upload
            ? uploadLimitBytesPerSec : downloadLimitBytesPerSec
        // Resume flag (M5d/T3): only a retry job sets it — the engine then
        // continues from the destination offset instead of overwriting.
        let resume = job.resume
        let transfer = Task<Void, Error> {
            try await TransferEngine.copyFile(
                from: source, sourcePath: sourcePath,
                to: destination, destinationDirectory: destinationDirectory, fileName: fileName,
                resume: resume,
                bytesPerSecondLimit: bytesPerSecondLimit,
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
            setStatus(jobID, .cancelled)
            jobs[jobID] = nil
            runningTransferTasks[jobID] = nil
            resumeWaiter(jobID, with: .failure(CancellationError()))
        } catch let error as RemoteFSError where error.isConnectionFailure {
            // Connection lost mid-transfer (M5d/T3): mark `.interrupted` (NOT
            // `.failed`) and RETAIN the job — under its EFFECTIVE (post-rename)
            // name — so a reconnect can resume the exact partial file via
            // `retryInterrupted`. The waiter still throws (Promise contract),
            // onCompleted does not fire. The partial file stays at the
            // destination as resume fodder.
            progressContinuation.finish()
            await consumer.value
            setStatus(jobID, .interrupted)
            jobs[jobID] = Job(
                id: jobID, source: source, sourcePath: sourcePath,
                destination: destination, destinationDirectory: destinationDirectory,
                fileName: effectiveFileName, direction: job.direction,
                onCompleted: nil, resume: false)
            runningTransferTasks[jobID] = nil
            resumeWaiter(jobID, with: .failure(error))
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
                direction: job.direction)
            // Serialize prompts across parallel slots: at most one decider is
            // open at a time, FIFO. Only the prompt itself is gated.
            await conflictGate.acquire()
            // Re-check: `cancelAll` may have fired while we waited for the gate.
            // Bail without prompting (and always release, so the gate never leaks).
            guard jobs[job.id] != nil else {
                conflictGate.release()
                return .cancel
            }
            let decision = await decider(conflict)
            conflictGate.release()
            guard let decision else {
                return .cancel                        // nil == cancel
            }
            resolution = decision.resolution
            if decision.applyToAll { queueRule = decision.resolution }
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
        group groupID: UUID
    ) async throws {
        try Task.checkCancellation()
        let destDir = RemotePath.join(destinationDirectory, directoryName)

        // Create the destination directory top-down.
        do {
            try await destination.createDirectory(at: destDir)
        } catch {
            try Task.checkCancellation()   // if it was cancellation, propagate it
            addTerminalItem(
                group: groupID, name: directoryName + "/",
                direction: direction, status: .failed(Self.message(for: error)))
            return
        }

        // List the source directory.
        let entries: [RemoteFileItem]
        do {
            entries = try await source.list(path: sourceDirectory)
        } catch {
            try Task.checkCancellation()
            addTerminalItem(
                group: groupID, name: directoryName + "/",
                direction: direction, status: .failed(Self.message(for: error)))
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
                    onCompleted: nil)
                registerGroupItem(id, group: groupID)
            case .directory:
                try await expandTree(
                    directoryName: entry.name, direction: direction,
                    source: source, sourceDirectory: entry.path,
                    destination: destination, destinationDirectory: destDir,
                    group: groupID)
            case .symlink, .other:
                // Don't follow: terminal `.skipped` item with a " →" suffix.
                addTerminalItem(
                    group: groupID, name: entry.name + " →",
                    direction: direction, status: .skipped)
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
        group groupID: UUID, name: String,
        direction: TransferDirection, status: Item.Status
    ) {
        let id = UUID()
        items.append(Item(id: id, fileName: name, direction: direction, status: .queued))
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

    private func setStatus(_ id: UUID, _ status: Item.Status) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        let wasTerminal = items[index].status.isTerminal
        items[index].status = status
        // The only choke point of the group accounting: decrement exactly at
        // the non-terminal → terminal transition (M5b/T3). Scattered
        // decrements would miss cases.
        if status.isTerminal && !wasTerminal {
            groupItemBecameTerminal(id, status: status)
        }
    }

    private func resumeWaiter(_ id: UUID, with result: Result<Void, Error>) {
        guard let continuation = waiters.removeValue(forKey: id) else { return }
        continuation.resume(with: result)
    }

    static func message(for error: Error) -> String {
        switch error {
        case RemoteFSError.notFound(let path):
            return String(format: CoreL10n.string("core.transfer.notFound %@"), path)
        case RemoteFSError.permissionDenied(let path):
            return String(format: CoreL10n.string("core.error.permissionDenied %@"), path)
        case RemoteFSError.connectionFailed(let reason):
            return String(format: CoreL10n.string("core.error.connectionLost %@"), reason)
        case RemoteFSError.protocolError(let reason):
            return String(format: CoreL10n.string("core.transfer.failed %@"), reason)
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
}
