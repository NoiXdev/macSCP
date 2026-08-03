import Foundation

/// Errors from validating a transfer's SOURCE before planning — distinct from
/// `TransferPlanError`, which is about the DESTINATION's conflict rule.
public enum TransferSourceError: Error, Equatable, Sendable {
    /// `TransferPlan.jobs` plans exactly one file job from a source path — it
    /// does NOT expand a directory into a recursive tree of jobs (M20 Task 9
    /// review). Letting a directory source through would silently plan a
    /// single, wrong job against it (a "file" job whose "source" is actually
    /// a directory) instead of failing clearly. The CLI's `get`/`put` are
    /// single-file transfers only; recursive directory transfers are the
    /// GUI queue's job (`TransferQueueViewModel`), not this planner's.
    case isDirectory(path: String)
}

/// Errors from validating an `rm` target before deleting it — distinct from
/// `TransferSourceError`, which guards a transfer's source argument, and from
/// the raw `RemoteFSError.protocolError` the backend would otherwise throw
/// for a directory target (M20 Task 11).
public enum DeleteSourceError: Error, Equatable, Sendable {
    /// `rm` without `--recursive` deletes a plain file only. `deleteTree`
    /// walks a whole subtree — a typo must not be able to trigger that — so
    /// a directory target without the flag is refused here with a clear
    /// message rather than surfacing whatever raw error `delete(path:)`
    /// would throw for it.
    case isDirectory(path: String)
}

/// Rejects a directory source for a single-file transfer. Pure and I/O-free
/// — the caller does the `stat` and hands in the already-fetched item — so
/// this is fully unit-testable without a network or a filesystem, unlike the
/// `stat` call itself.
public enum TransferSourceGuard {
    public static func checkNotDirectory(_ item: RemoteFileItem) throws {
        if item.isDirectory {
            throw TransferSourceError.isDirectory(path: item.path)
        }
    }

    /// Rejects a directory target for `rm` unless `recursive` is set. Same
    /// shape as `checkNotDirectory` — caller does the `stat`, this only
    /// decides — kept as a sibling here rather than a new type/file since
    /// the check is identical, only the error (and its message) differs.
    public static func checkDeletable(_ item: RemoteFileItem, recursive: Bool) throws {
        if item.isDirectory && !recursive {
            throw DeleteSourceError.isDirectory(path: item.path)
        }
    }
}
