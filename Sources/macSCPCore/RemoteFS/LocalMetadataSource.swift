import Foundation

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

extension LocalFileSystem: LocalMetadataSource {
    /// Runs `metadataProbe` for every item in `items`, each on its OWN
    /// unstructured child `Task` (plain `Task {}`, not `Task.detached`: this
    /// method already runs on an ordinary task, not an actor, so there is no
    /// actor isolation for `Task.detached` to strip, and a plain `Task`
    /// still gets its own top-level task — inheriting THIS task's priority
    /// is a better default than always running at the base priority
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
    /// rest of the listing renders normally.
    ///
    /// The stream finishes two ways:
    /// - every child has yielded (the tally's count reaches `items.count`),
    ///   or
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
    /// writes the `browser.local entry slow` `.debug` line — the line used
    /// to wrap `list`'s own per-entry loop (Task 1 removed that loop; this
    /// is where the same line lives now).
    public func metadata(for items: [RemoteFileItem]) -> AsyncStream<RemoteFileItem> {
        let probe = metadataProbe
        let clock = ContinuousClock()
        return AsyncStream { continuation in
            guard !items.isEmpty else {
                continuation.finish()
                return
            }
            let tally = MetadataTally(total: items.count)
            continuation.onTermination = { _ in
                Task { await tally.consumerWentAway(continuation) }
            }
            for item in items {
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
                    await tally.childFinished(yielding: filled ?? item, into: continuation)
                }
            }
        }
    }
}

/// Counts finished children for one `metadata(for:)` call and decides, the
/// one time it matters, when the stream finishes. An `actor` rather than a
/// `Mutex<Int>`: finishing also has to CALL `continuation.finish()`/`.yield`
/// exactly once at the transition, and doing that under a `Mutex`'s
/// synchronous closure would mean holding the lock across those calls —
/// unnecessary here since every caller is already in an async context (a
/// child `Task`, or the `onTermination` callback's own `Task`), so actor
/// isolation costs nothing extra and reads better than a hand-rolled
/// check-then-act under a raw lock.
private actor MetadataTally {
    private var remaining: Int
    private var finished = false

    init(total: Int) {
        remaining = total
    }

    /// A child finished normally. Yields `item` and, if every item has now
    /// been accounted for, finishes the stream. A no-op if the stream
    /// already finished (the consumer went away while this child was still
    /// running) — that child's result is simply dropped.
    func childFinished(
        yielding item: RemoteFileItem, into continuation: AsyncStream<RemoteFileItem>.Continuation
    ) {
        guard !finished else { return }
        continuation.yield(item)
        remaining -= 1
        if remaining == 0 {
            finished = true
            continuation.finish()
        }
    }

    /// The consumer stopped iterating (`onTermination`). Whatever children
    /// are still running are abandoned as of this call — `childFinished`
    /// above will no-op for every one of them from here on.
    func consumerWentAway(_ continuation: AsyncStream<RemoteFileItem>.Continuation) {
        guard !finished else { return }
        finished = true
        continuation.finish()
    }
}
