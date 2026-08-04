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

    /// `rm --recursive` alone must not be enough to wipe a whole session.
    /// `SessionReference.parse` maps an empty path to `/`, so a truncated or
    /// unquoted argument (`rm -r prod:` instead of `rm -r prod:/tmp/old`)
    /// reaches `deleteTree(at: "/")` with nothing else in the way — for an
    /// S3 session, "/" is the bucket root, i.e. every object in it. This is
    /// refused unless the caller also passes the explicit `allowRoot` escape
    /// hatch (M20 final-review Finding A).
    case isSessionRoot(path: String)
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

    /// Rejects a directory target for `rm` unless `recursive` is set, and —
    /// when `recursive` IS set — separately rejects the session root unless
    /// `allowRoot` is also set. Same shape as `checkNotDirectory` — caller
    /// does the `stat`, this only decides — kept as a sibling here rather
    /// than a new type/file since the check is identical, only the error
    /// (and its message) differs.
    ///
    /// The two checks are deliberately NOT merged: a non-recursive delete of
    /// the root is already refused as a plain directory before `allowRoot`
    /// is ever consulted, so `.isSessionRoot` only fires on the one path
    /// that is actually destructive — `deleteTree`.
    ///
    /// `allowRoot` defaults to `false` (opt-in, not opt-out) so every
    /// existing call site that doesn't know about the escape hatch keeps the
    /// safe behavior. Root is checked via `RemotePath.normalizedAbsolute`
    /// rather than a raw `== "/"` comparison so the guard isn't defeated by
    /// an unnormalized form of the same path (e.g. a trailing slash).
    ///
    /// Deliberately narrow: this catches the EXACT session root only, not
    /// "near-root" paths one level down. A path like `/var` or an S3
    /// top-level prefix is a deliberately typed, named target — not the
    /// "an empty argument silently became the root" trap this guard exists
    /// to close — so broadening it there would refuse legitimate,
    /// intentional deletes for no safety gain.
    public static func checkDeletable(
        _ item: RemoteFileItem, recursive: Bool, allowRoot: Bool = false
    ) throws {
        if item.isDirectory && !recursive {
            throw DeleteSourceError.isDirectory(path: item.path)
        }
        if recursive && !allowRoot && RemotePath.normalizedAbsolute(item.path) == "/" {
            throw DeleteSourceError.isSessionRoot(path: item.path)
        }
    }
}
