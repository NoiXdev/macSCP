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
}
