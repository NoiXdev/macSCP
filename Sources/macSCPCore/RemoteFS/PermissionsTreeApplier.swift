import Foundation

/// Outcome of applying permissions across a directory subtree (M11c/T1):
/// how many entries were changed, how many symlinks were skipped (never
/// touched), how many operations failed, and — for UI display and audit —
/// the first failure's message plus whether cancellation cut the walk
/// short. `Equatable`/`Sendable` so a `progress` callback can hand out a
/// mid-walk snapshot and a test can compare it directly against the final
/// result.
public struct PermissionsTreeResult: Equatable, Sendable {
    public var changed: Int
    public var skippedSymlinks: Int
    public var failed: Int
    public var firstErrorMessage: String?
    public var cancelled: Bool

    public init(
        changed: Int = 0, skippedSymlinks: Int = 0, failed: Int = 0,
        firstErrorMessage: String? = nil, cancelled: Bool = false
    ) {
        self.changed = changed
        self.skippedSymlinks = skippedSymlinks
        self.failed = failed
        self.firstErrorMessage = firstErrorMessage
        self.cancelled = cancelled
    }
}

/// Applies POSIX permissions across a directory subtree (M11c spec §1/§2):
/// one value for everything, or a separate value for files vs. directories.
/// Pure over `any RemoteFileSystem` — no protocol extension needed, so it
/// works unmodified against both backends (Local/Citadel).
///
/// SYMLINK SAFETY (security-critical, established in M7a): `setPermissions`
/// FOLLOWS symlinks on both backends — there is no lchmod equivalent — so
/// calling it on a symlink would silently change permissions on a target
/// OUTSIDE the tree. This walk therefore determines every entry's kind
/// EXCLUSIVELY from `list()` (SSH_FXP_READDIR / directory enumeration —
/// both report a symlink AS a symlink, never resolved), the exact guarantee
/// `CitadelFileSystem.deleteTree` already rests its own symlink safety on
/// (see its doc comments). A `.symlink` entry is counted in
/// `skippedSymlinks` and is NEVER passed to `setPermissions` and NEVER
/// listed/descended into — regardless of what it points to.
///
/// The root's kind is supplied by the CALLER (the browser already has it
/// from its own listing) rather than re-derived here via a stat probe.
/// Unlike `deleteTree`, which has no caller-supplied kind for its own top
/// level and so falls back to a careful stat-based `topLevelKind` guard,
/// this walker has no such fallback and does not need one: the caller is
/// the UI's existing listing, which — like every deeper entry in this walk
/// — already went through `list()`, so the same unresolved-kind guarantee
/// covers it too. A caller that fabricates a `.directory` kind for a path
/// it never actually listed would defeat that guarantee, exactly as passing
/// a wrong kind to `deleteTree`'s internal recursive step would; that risk
/// is inherent to any kind-from-caller design and is why `RemoteFileSystem`
/// itself gains no new protocol surface here (Global Constraints).
public enum PermissionsTreeApplier {
    /// Applies `directoryPermissions` to directories and `filePermissions`
    /// to everything else across the subtree rooted at `root` (`kind` is
    /// the root's own kind, as already known by the caller). Errors are
    /// counted, never thrown (mirrors `applyImport`'s pattern) — the walk
    /// always runs to completion or stops at a cooperative cancellation
    /// point and returns the partial counts either way; already-applied
    /// permissions are never rolled back. `progress`, when given, fires
    /// after every entry that changes the tally (changed, skipped, or
    /// failed) with the current running total, for a live UI.
    public static func apply(
        root: String,
        kind: RemoteFileKind,
        filePermissions: UInt32,
        directoryPermissions: UInt32,
        on fs: any RemoteFileSystem,
        progress: (@Sendable (PermissionsTreeResult) -> Void)? = nil
    ) async -> PermissionsTreeResult {
        var result = PermissionsTreeResult()

        // Root .symlink: do nothing at all beyond counting it — never
        // touched, never listed (spec §2).
        guard kind != .symlink else {
            result.skippedSymlinks += 1
            progress?(result)
            return result
        }

        if kind == .directory {
            await applyOne(path: root, permissions: directoryPermissions, on: fs, result: &result, progress: progress)
            guard !result.cancelled else { return result }
            await walk(
                root, filePermissions: filePermissions, directoryPermissions: directoryPermissions,
                on: fs, result: &result, progress: progress)
        } else {
            // Root .file (or .other): only the root itself is touched.
            await applyOne(path: root, permissions: filePermissions, on: fs, result: &result, progress: progress)
        }
        return result
    }

    /// Lists `directory` and processes each child: `.symlink` is counted
    /// and skipped (never touched, never descended into); `.directory` gets
    /// `directoryPermissions` and is then walked further; everything else
    /// gets `filePermissions`. A `list` failure counts as one failure and
    /// simply stops descending into THIS directory — the rest of the
    /// already-discovered tree keeps going (mirrors `applyImport`'s
    /// error-counting pattern; matches `deleteTree`'s "not entered" wording
    /// for a listing that fails).
    private static func walk(
        _ directory: String,
        filePermissions: UInt32,
        directoryPermissions: UInt32,
        on fs: any RemoteFileSystem,
        result: inout PermissionsTreeResult,
        progress: (@Sendable (PermissionsTreeResult) -> Void)?
    ) async {
        guard !Task.isCancelled else {
            result.cancelled = true
            return
        }

        let children: [RemoteFileItem]
        do {
            children = try await fs.list(path: directory)
        } catch is CancellationError {
            result.cancelled = true
            return
        } catch {
            result.failed += 1
            if result.firstErrorMessage == nil {
                result.firstErrorMessage = String(describing: error)
            }
            progress?(result)
            return
        }

        for child in children {
            guard !Task.isCancelled else {
                result.cancelled = true
                return
            }
            switch child.kind {
            case .symlink:
                result.skippedSymlinks += 1
                progress?(result)
            case .directory:
                await applyOne(
                    path: child.path, permissions: directoryPermissions, on: fs, result: &result,
                    progress: progress)
                guard !result.cancelled else { return }
                await walk(
                    child.path, filePermissions: filePermissions, directoryPermissions: directoryPermissions,
                    on: fs, result: &result, progress: progress)
                guard !result.cancelled else { return }
            case .file, .other:
                await applyOne(
                    path: child.path, permissions: filePermissions, on: fs, result: &result, progress: progress)
                guard !result.cancelled else { return }
            }
        }
    }

    /// Calls `setPermissions` for one entry, updates `changed`/`failed`
    /// accordingly, and fires `progress` — but only when the call actually
    /// ran (a pre-empted call due to cancellation reports no tally change
    /// and no progress, keeping the progress-call count equal to the
    /// number of entries actually processed, per spec §7). Checks
    /// cancellation BEFORE the call (spec §6: before every entry) and also
    /// treats a `CancellationError` thrown mid-call as cancellation rather
    /// than a counted failure — real backends can surface cancellation as
    /// a thrown error from a long-running network call, not only as a
    /// pre-check.
    private static func applyOne(
        path: String, permissions: UInt32, on fs: any RemoteFileSystem,
        result: inout PermissionsTreeResult,
        progress: (@Sendable (PermissionsTreeResult) -> Void)?
    ) async {
        guard !Task.isCancelled else {
            result.cancelled = true
            return
        }
        do {
            try await fs.setPermissions(path: path, permissions: permissions)
            result.changed += 1
        } catch is CancellationError {
            result.cancelled = true
            return
        } catch {
            result.failed += 1
            if result.firstErrorMessage == nil {
                result.firstErrorMessage = String(describing: error)
            }
        }
        progress?(result)
    }
}
