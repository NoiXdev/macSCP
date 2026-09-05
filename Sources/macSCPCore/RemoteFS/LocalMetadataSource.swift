import Foundation
import Synchronization

/// Phase two of the local-listing-never-blocks design
/// (`docs/superpowers/specs/2026-09-04-local-listing-never-blocks-design.md`,
/// point 2): fills in the `size`/`modifiedAt`/`owner`/`group` that
/// `LocalFileSystem.list` (phase one) leaves nil, one entry at a time, as
/// each entry's own metadata call returns — never waiting for the slowest
/// one to unblock the rest.
///
/// A local-only capability, not a `RemoteFileSystem` requirement: SFTP's
/// `readdir` already returns attributes with the names, so a remote backend
/// has no second phase to run.
public protocol LocalMetadataSource: Sendable {
    /// Yields each of `items`, filled in, as its own metadata call finishes.
    /// Order is NOT guaranteed to match `items`' order — a slow entry lets
    /// faster ones arrive first, which is the entire point.
    ///
    /// The stream finishes when every entry has been accounted for, OR when
    /// the consumer stops iterating (cancellation, `break`, a scope exit) —
    /// whichever comes first. An entry whose metadata call never returns is
    /// ABANDONED, not awaited: see the conforming type's `metadata(for:)`
    /// doc comment for the full argument and its accepted cost.
    func metadata(for items: [RemoteFileItem]) -> AsyncStream<RemoteFileItem>
}

/// A session-scoped memory of paths whose `metadata(for:)` probe was still
/// running when `LocalFileSystem.slowEntryThreshold` elapsed (final fix
/// round, ruled IN by the whole-plan review): without it, a stuck child
/// costs one fresh thread on EVERY visit to the same directory, and the
/// tester's own home folder — the folder behind the report this design
/// exists for — is exactly the folder one keeps returning to. Once a path
/// is marked, later `metadata(for:)` calls skip probing it entirely (see
/// that method's doc comment); its row simply stays `-`.
///
/// One instance is shared by every `LocalFileSystem` backing the same
/// browser session (`ContentView.swift` builds one and hands it to both the
/// `localFS` used for transfers and the `RemoteBrowserViewModel`'s own
/// instance), so a path proven stuck through one is remembered by the
/// other too. Scoped to the session, not the process: a fresh session gets
/// a fresh, empty memory, so a path that was merely slow once (a cold
/// cache, a momentary network hiccup) is not condemned forever.
///
/// A plain `Mutex<Set<String>>` wrapper, not an actor: every access is a
/// synchronous membership test or insert, and `Mutex<Value>` is
/// unconditionally `Sendable` regardless of `Value`'s own sendability — the
/// same reasoning `DiagnosticLog`'s own state lock and `FileListFormatter`'s
/// cached formatters already document for themselves in this module.
public final class StuckPaths: Sendable {
    private let paths = Mutex<Set<String>>([])

    public init() {}

    /// Whether `path` was marked stuck by a previous listing's supervisor.
    public func contains(_ path: String) -> Bool {
        paths.withLock { $0.contains(path) }
    }

    /// Marks `path` stuck. Idempotent — inserting the same path twice (two
    /// listings whose supervisors both fire before either finishes) changes
    /// nothing further.
    public func markStuck(_ path: String) {
        paths.withLock { _ = $0.insert(path) }
    }
}

extension LocalFileSystem: LocalMetadataSource {
    /// Runs `metadataProbe` for every item in `items` that is not already
    /// known-stuck (see `StuckPaths` above), each on its OWN unstructured
    /// child `Task` (plain `Task {}`, not `Task.detached`: this method
    /// already runs on an ordinary task, not an actor, so there is no actor
    /// isolation for `Task.detached` to strip, and a plain `Task` still
    /// gets its own top-level task — inheriting THIS task's priority is a
    /// better default than always running at the base priority
    /// `Task.detached` would use). Every child yields its filled item into
    /// the stream and is otherwise ignored by this method: no `await`, no
    /// task group, no handle kept for cancellation.
    ///
    /// That "otherwise ignored" is deliberate, not an oversight — it is the
    /// whole point of phase two. A child that calls into a stuck syscall
    /// (a dead network mount, a cloud placeholder answering after a network
    /// timeout, a TCC prompt nobody answers) does not read cancellation
    /// while parked there; AWAITING it, even under `withTaskCancellationHandler`,
    /// would mean this method's own return — and therefore the stream
    /// finishing — waits for that syscall too, which is exactly the hang
    /// phase two exists to remove. So this method never joins a child: it
    /// only ever finds out a child is DONE, through `MetadataTally` below,
    /// never that a child is merely cancelled. A stuck entry costs one
    /// thread parked in the syscall for as long as the process runs (or
    /// until the syscall itself eventually returns/errors) — accepted,
    /// deliberately, in exchange for every other entry, and the pane itself,
    /// never waiting on it. The one place that cost is visible from outside
    /// this method: the pane shows `-` for that one row, forever, while the
    /// rest of the listing renders normally. When `stuckPaths` is set, that
    /// cost is paid at most once per session per path — see the paragraph
    /// on the supervisor below.
    ///
    /// Items already in `stuckPaths` (if this instance carries one) never
    /// get a child at all: this method logs `browser.local entry skipped
    /// name=…` once for each and moves on, so a directory containing a path
    /// proven stuck by a PREVIOUS listing does not spend a new thread
    /// re-discovering that fact. Its row is left exactly as phase one built
    /// it (every metadata field nil), same as a row whose child is still
    /// running when the stream finishes.
    ///
    /// The stream finishes two ways:
    /// - every non-skipped item has yielded (the tally's count reaches the
    ///   count of items actually probed), or
    /// - the consumer stops iterating — `onTermination` fires (cancellation,
    ///   `break`, the consuming scope going away) and tells the tally to
    ///   finish the stream right there. Children still in flight are NOT
    ///   cancelled by this — there is nothing that could observe a
    ///   cancellation in a plain `URL.resourceValues` call anyway — they are
    ///   simply no longer listened to: `MetadataTally` drops any later
    ///   `yield` once it has finished the stream, so a late child cannot
    ///   reopen it or emit into a continuation nobody reads any more.
    ///
    /// Each child is timed with a `ContinuousClock` reading taken
    /// immediately around its own `metadataProbe` call — never derived from
    /// a running total, so one slow entry cannot be hidden by several fast
    /// ones averaging it out. `>= LocalFileSystem.slowEntryThreshold` (500 ms)
    /// writes the `browser.local entry slow` `.debug` line ON RETURN — the
    /// line used to wrap `list`'s own per-entry loop (Task 1 removed that
    /// loop; this is where the same line lives now) — for an entry that was
    /// slow but DID eventually come back.
    ///
    /// A SEPARATE supervisor `Task`, one per `metadata(for:)` call, covers
    /// the entry the per-child line above cannot: one that never comes back
    /// at all. The per-child line only runs after `probe` RETURNS, so a
    /// permanently stuck entry — the exact case this design exists to name
    /// — never reached it (final whole-plan review, Important). The
    /// supervisor sleeps `Self.slowEntryThreshold` once, then asks the tally
    /// which items it has not yet accounted for and, for each, writes
    /// `browser.local entry slow name=… ms=… (still pending)` — the
    /// trailing `(still pending)` keeping this text distinct from the
    /// per-child line above, so a log reader can tell "this one came back
    /// late" from "this one had not come back at THIS instant" — and marks
    /// the path stuck in `stuckPaths`, if this instance carries one. The
    /// supervisor fires at most once per call (a single sleep, not a
    /// repeating timer) and is cancelled the moment the tally finishes —
    /// every child done, or the consumer gone — so a listing that completes
    /// well inside the threshold never has a live supervisor Task to clean
    /// up later.
    public func metadata(for items: [RemoteFileItem]) -> AsyncStream<RemoteFileItem> {
        let probe = metadataProbe
        let clock = ContinuousClock()
        let stuckPaths = self.stuckPaths
        return AsyncStream { continuation in
            guard !items.isEmpty else {
                continuation.finish()
                return
            }
            var toProbe: [RemoteFileItem] = []
            toProbe.reserveCapacity(items.count)
            for item in items {
                if let stuckPaths, stuckPaths.contains(item.path) {
                    DiagnosticLog.shared.log(
                        .debug, "browser.local", "entry skipped name=\(item.name)")
                } else {
                    toProbe.append(item)
                }
            }
            guard !toProbe.isEmpty else {
                continuation.finish()
                return
            }
            let tally = MetadataTally(total: toProbe.count)
            continuation.onTermination = { _ in
                Task { await tally.consumerWentAway(continuation) }
            }
            let supervisor = Task {
                try? await Task.sleep(for: Self.slowEntryThreshold)
                guard !Task.isCancelled else { return }
                let pending = await tally.itemsStillPending(among: toProbe)
                guard !pending.isEmpty else { return }
                let thresholdMs = Int(Self.slowEntryThreshold.milliseconds.rounded())
                for item in pending {
                    stuckPaths?.markStuck(item.path)
                    DiagnosticLog.shared.log(
                        .debug, "browser.local",
                        "entry slow name=\(item.name) ms=\(thresholdMs) (still pending)")
                }
            }
            Task { await tally.supervisorStarted(supervisor) }
            for item in toProbe {
                let url = URL(fileURLWithPath: item.path)
                Task {
                    let entryStart = clock.now
                    let filled = await probe(url)
                    let elapsed = entryStart.duration(to: clock.now)
                    if elapsed >= Self.slowEntryThreshold {
                        DiagnosticLog.shared.log(
                            .debug, "browser.local",
                            "entry slow name=\(item.name) ms=\(Int(elapsed.milliseconds.rounded()))")
                    }
                    await tally.childFinished(item: item, yielding: filled ?? item, into: continuation)
                }
            }
        }
    }
}

/// Counts finished children for one `metadata(for:)` call, tracks which
/// items have been accounted for (for the supervisor's "still pending"
/// query), and decides, the one time it matters, when the stream finishes.
/// An `actor` rather than a `Mutex<Int>`: finishing also has to CALL
/// `continuation.finish()`/`.yield` exactly once at the transition, and
/// doing that under a `Mutex`'s synchronous closure would mean holding the
/// lock across those calls — unnecessary here since every caller is
/// already in an async context (a child `Task`, the supervisor `Task`, or
/// the `onTermination` callback's own `Task`), so actor isolation costs
/// nothing extra and reads better than a hand-rolled check-then-act under a
/// raw lock.
private actor MetadataTally {
    private var remaining: Int
    private var finished = false
    private var accountedPaths: Set<String> = []
    private var supervisor: Task<Void, Never>?

    init(total: Int) {
        remaining = total
    }

    /// Records the supervisor Task so the two finishing paths below can
    /// cancel it. Called from a separate unstructured `Task` (the same
    /// pattern `childFinished`'s and `consumerWentAway`'s own callers use)
    /// rather than synchronously, so there is no guarantee it runs BEFORE
    /// every child does — if every child has already finished by the time
    /// this runs, the stream is already `finished`, and the task handed in
    /// is cancelled immediately instead of being stored, so a supervisor
    /// that would otherwise sleep past a listing that finished in a few
    /// milliseconds never gets the chance to.
    func supervisorStarted(_ task: Task<Void, Never>) {
        guard !finished else {
            task.cancel()
            return
        }
        supervisor = task
    }

    /// A child finished normally. Yields `item` and, if every item has now
    /// been accounted for, finishes the stream and cancels the supervisor
    /// (its "still pending" query would find nothing left to report). A
    /// no-op if the stream already finished (the consumer went away while
    /// this child was still running) — that child's result is simply
    /// dropped, and its path is NOT recorded as accounted (nothing reads
    /// `accountedPaths` after `finished` is set, so this is inert either
    /// way).
    func childFinished(
        item: RemoteFileItem, yielding filled: RemoteFileItem,
        into continuation: AsyncStream<RemoteFileItem>.Continuation
    ) {
        guard !finished else { return }
        accountedPaths.insert(item.path)
        continuation.yield(filled)
        remaining -= 1
        if remaining == 0 {
            finished = true
            continuation.finish()
            supervisor?.cancel()
        }
    }

    /// The consumer stopped iterating (`onTermination`). Whatever children
    /// are still running are abandoned as of this call — `childFinished`
    /// above will no-op for every one of them from here on — and the
    /// supervisor is cancelled: a consumer that is gone will never read a
    /// "still pending" line about a stream it stopped listening to.
    func consumerWentAway(_ continuation: AsyncStream<RemoteFileItem>.Continuation) {
        guard !finished else { return }
        finished = true
        continuation.finish()
        supervisor?.cancel()
    }

    /// The subset of `candidates` whose `childFinished` has not yet run, as
    /// of right now — the supervisor's own query, taken once at the
    /// threshold rather than polled. Empty once the stream has already
    /// finished (nothing is "pending" against a call that is over).
    func itemsStillPending(among candidates: [RemoteFileItem]) -> [RemoteFileItem] {
        guard !finished else { return [] }
        return candidates.filter { !accountedPaths.contains($0.path) }
    }
}
