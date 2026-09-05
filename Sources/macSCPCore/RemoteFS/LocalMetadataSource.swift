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

    /// Un-marks `path` (round 2, self-healing): a probe that eventually DOES
    /// return, even after its own listing's supervisor already marked it,
    /// removes its own path here — that visit's row still fills in (the
    /// child was never cancelled, only ignored), and a LATER listing of the
    /// same directory probes the path again rather than skipping it
    /// forever. Idempotent — clearing a path that was never marked, or was
    /// already cleared, changes nothing.
    public func clear(_ path: String) {
        paths.withLock { _ = $0.remove(path) }
    }
}

/// The two deadlines `LocalFileSystem.metadata(for:)`'s supervisor drives
/// (round 2 of the final fix round, from the review): a SHORT one that only
/// ever writes a log line, and a LONGER one that is the sole trigger for
/// blacklisting a path in `StuckPaths`. Splitting them is the fix for the
/// exact regression the review named — the original supervisor logged AND
/// marked at the same 500 ms deadline, so a cloud file that simply took a
/// second or two to answer was blacklisted for the rest of the session
/// after its very first slow listing.
///
/// `slowEntryThreshold` (default 500 ms) is unchanged from before round 2:
/// far above any local syscall's normal cost (the M11g review measured
/// 12-14 µs/entry for the plain `resourceValues` lookup), so crossing it
/// means something is actually slow, not that the disk is merely busy —
/// but "slow" alone is not "stuck," which is why it only ever writes the
/// `(still pending)` log line, never a mark.
///
/// `stuckEntryDeadline` (default 5 s) is what actually blacklists a path.
/// Five seconds, not five hundred milliseconds: a cloud placeholder or a
/// momentarily busy network mount answering within a second or two is
/// ordinary slowness, not stuck, and must not cost every later listing of
/// the same directory a skipped probe for the rest of the session; a
/// genuinely dead mount does not answer in five seconds either, so the
/// deadline still catches the case `StuckPaths` exists for.
///
/// Both are `init` parameters (with an `initializer` on `LocalFileSystem`
/// defaulting to `.default` below) rather than fixed constants, so a test
/// can drive the whole two-deadline sequence — the log-only line, then the
/// mark — in milliseconds instead of the production five seconds, without
/// ever asserting on elapsed time itself (CLAUDE.md: a wall-clock ceiling
/// measures the runner; these tests wait on the OUTCOME — the log's
/// contents, `StuckPaths`' membership — never on a duration).
public struct MetadataDeadlines: Sendable {
    public let slowEntryThreshold: Duration
    public let stuckEntryDeadline: Duration

    public init(
        slowEntryThreshold: Duration = .milliseconds(500),
        stuckEntryDeadline: Duration = .seconds(5)
    ) {
        self.slowEntryThreshold = slowEntryThreshold
        self.stuckEntryDeadline = stuckEntryDeadline
    }

    public static let `default` = MetadataDeadlines()
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
    /// supervisor sleeps to `MetadataDeadlines.slowEntryThreshold` once,
    /// then asks the tally which items it has not yet accounted for and,
    /// for each, writes `browser.local entry slow name=… ms=… (still
    /// pending)` — the trailing `(still pending)` keeping this text
    /// distinct from the per-child line above, so a log reader can tell
    /// "this one came back late" from "this one had not come back at THIS
    /// instant." That first deadline is a LOG LINE ONLY (round 2, from the
    /// review): it does NOT mark anything in `stuckPaths` — a cloud file
    /// that merely takes a second or two to answer must not be blacklisted
    /// off one slow listing.
    ///
    /// The supervisor then sleeps the REMAINDER to
    /// `MetadataDeadlines.stuckEntryDeadline` and, only THEN, asks the
    /// tally to mark whatever is still pending — `tally.markStillPending`
    /// reads the pending set and inserts each path into `stuckPaths` in
    /// ONE actor turn (round 2, Important: the previous shape snapshotted
    /// the pending set and marked it in two separate steps with an actor
    /// hop in between, so a child that finished in that gap was still
    /// blacklisted forever). Because `MetadataTally` is an actor and
    /// `markStillPending`'s own body has no `await` in it, it runs to
    /// completion without yielding to any concurrently-arriving
    /// `childFinished` call — the read and the mark are atomic with
    /// respect to the tally's own state. Each newly-marked path gets its
    /// own `browser.local entry stuck name=…` line at `.debug` — the mark
    /// is the event a tester actually wants to see in a report, distinct
    /// from the two "still running" lines above it.
    ///
    /// The supervisor fires its two sleeps at most once each per call (no
    /// repeating timer) and is cancelled the moment the tally finishes —
    /// every child done, or the consumer gone — so a listing that
    /// completes well inside either deadline never has a live supervisor
    /// Task to clean up later.
    ///
    /// Self-healing (round 2, ruled in alongside the above): a child that
    /// eventually DOES return — even one already marked stuck by the
    /// SECOND deadline, a cloud file that finally answers at 6 s — clears
    /// its own path from `stuckPaths` right here, unconditionally (a path
    /// never marked is a harmless no-op to clear). That visit's row still
    /// fills in normally (the child was never cancelled, only ignored by
    /// the tally once past the threshold), and a LATER listing of the same
    /// directory probes the path again instead of skipping it forever.
    public func metadata(for items: [RemoteFileItem]) -> AsyncStream<RemoteFileItem> {
        let probe = metadataProbe
        let clock = ContinuousClock()
        let stuckPaths = self.stuckPaths
        let deadlines = self.metadataDeadlines
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
                try? await Task.sleep(for: deadlines.slowEntryThreshold)
                guard !Task.isCancelled else { return }
                let pending = await tally.itemsStillPending(among: toProbe)
                if !pending.isEmpty {
                    let thresholdMs = Int(deadlines.slowEntryThreshold.milliseconds.rounded())
                    for item in pending {
                        DiagnosticLog.shared.log(
                            .debug, "browser.local",
                            "entry slow name=\(item.name) ms=\(thresholdMs) (still pending)")
                    }
                }
                let remainder = max(.zero, deadlines.stuckEntryDeadline - deadlines.slowEntryThreshold)
                try? await Task.sleep(for: remainder)
                guard !Task.isCancelled else { return }
                let marked = await tally.markStillPending(among: toProbe, into: stuckPaths)
                for item in marked {
                    DiagnosticLog.shared.log(.debug, "browser.local", "entry stuck name=\(item.name)")
                }
            }
            Task { await tally.supervisorStarted(supervisor) }
            for item in toProbe {
                let url = URL(fileURLWithPath: item.path)
                Task {
                    let entryStart = clock.now
                    let filled = await probe(url)
                    let elapsed = entryStart.duration(to: clock.now)
                    if elapsed >= deadlines.slowEntryThreshold {
                        DiagnosticLog.shared.log(
                            .debug, "browser.local",
                            "entry slow name=\(item.name) ms=\(Int(elapsed.milliseconds.rounded()))")
                    }
                    // Self-healing (round 2): unconditional, a harmless no-op
                    // if this path was never marked. The order matters: the
                    // tally learns the child finished FIRST, so a supervisor
                    // mark that lands in between cannot see this item as
                    // pending any more; the clear is the last write, and a
                    // mark can never undo it (round 3, reviewer-caught).
                    await tally.childFinished(item: item, yielding: filled ?? item, into: continuation)
                    stuckPaths?.clear(item.path)
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

    /// Round 2: the supervisor's SECOND-deadline query, which both reads
    /// AND marks in one actor turn — the fix for the exact regression the
    /// review named. The previous shape called `itemsStillPending` to get
    /// a snapshot, then marked each path in `stuckPaths` from OUTSIDE the
    /// actor; a child whose `childFinished` ran on this actor in the gap
    /// between those two steps had already left `accountedPaths`, but the
    /// snapshot taken before it was stale, and marked it anyway. This
    /// method's own body has no `await` in it, so once the actor dispatches
    /// it, it runs to completion without yielding the actor to any
    /// concurrently-arriving `childFinished`/`consumerWentAway` call — the
    /// read of `accountedPaths` and the calls to `stuckPaths.markStuck`
    /// happen as one indivisible step relative to this tally's own state.
    /// Returns exactly the items actually marked (empty once the stream
    /// has already finished, same as `itemsStillPending`, and empty when
    /// `stuckPaths` is `nil` — nothing to mark, so nothing is reported
    /// marked either).
    func markStillPending(
        among candidates: [RemoteFileItem], into stuckPaths: StuckPaths?
    ) -> [RemoteFileItem] {
        guard !finished, let stuckPaths else { return [] }
        let pending = candidates.filter { !accountedPaths.contains($0.path) }
        for item in pending {
            stuckPaths.markStuck(item.path)
        }
        return pending
    }
}
