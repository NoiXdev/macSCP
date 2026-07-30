import Foundation
import Observation

/// State of the remote browser: current path, sorted entries,
/// loading/error state. Works exclusively against the protocol.
@Observable
@MainActor
public final class RemoteBrowserViewModel {
    public enum State: Equatable {
        case loading
        case loaded
        case failed(message: String)
    }

    public private(set) var currentPath: String
    public private(set) var items: [RemoteFileItem] = []
    public private(set) var state: State = .loading

    /// Currently selected entries, in table order (M7a multi-select).
    /// The single source of truth for selection.
    public var selectedItems: [RemoteFileItem] = []

    /// Single-selection convenience: non-nil exactly when ONE row is
    /// selected. Double-click/editor paths keep using this.
    public var selectedItem: RemoteFileItem? {
        selectedItems.count == 1 ? selectedItems[0] : nil
    }

    /// Display filter for dotfiles (M7a). The caller re-`load()`s after
    /// changing it — the filter is presentation-only, never in the FS layer.
    public var showHiddenFiles = false

    private let fs: any RemoteFileSystem

    /// Optional audit-log sink (M9b/T2), default nil (no logging — matches
    /// ad-hoc/unstored sessions). Each of the four actions below fires it
    /// exactly once, AFTER the action completes: success and failure both
    /// report (failure with `isError: true` and the localized message the
    /// action already returns to its caller). The App layer wires this to an
    /// `AuditRecorder.recordAction` closure for stored sessions.
    public var auditSink: ((AuditEvent) -> Void)?

    public init(fs: any RemoteFileSystem, startPath: String = "/") {
        self.fs = fs
        self.currentPath = startPath
    }

    public var canGoUp: Bool { currentPath != "/" }

    public func load() async {
        state = .loading
        selectedItems = []
        do {
            let listed = try await fs.list(path: currentPath)
            items = displayItems(from: listed)
            state = .loaded
        } catch {
            items = []
            state = .failed(message: Self.message(for: error, path: currentPath))
        }
    }

    /// Shared display pipeline for `load()` and `refreshQuietly()` — the
    /// hidden-files filter and sort MUST stay identical between the two.
    private func displayItems(from listed: [RemoteFileItem]) -> [RemoteFileItem] {
        let visible = showHiddenFiles
            ? listed
            : listed.filter { !$0.name.hasPrefix(".") }
        return Self.sortedForDisplay(visible)
    }

    /// Silent background refresh (M9c): re-lists the current directory and
    /// swaps the rows WITHOUT touching `state` — no spinner, no hit-test
    /// block, selection preserved (pruned to paths still visible, which
    /// also closes the M7a backlog note about the hidden filter). Errors
    /// are swallowed silently: a dead server must not paint a failure
    /// screen every few seconds — any manual action still surfaces real
    /// problems. Both guards are needed: the state can change while the
    /// listing is in flight (e.g. a manual `load()` or `open()`), and the
    /// late writer must lose.
    public func refreshQuietly() async {
        guard state == .loaded else { return }
        let path = currentPath
        guard let listed = try? await fs.list(path: path) else { return }
        guard state == .loaded, currentPath == path else { return }
        // Rebuild the selection FROM the fresh items rather than filtering
        // the old structs (M9c final review): membership semantics are the
        // same, but the surviving entries carry current size/date/permission
        // values and stay in table order.
        let selectedPaths = Set(selectedItems.map(\.path))
        items = displayItems(from: listed)
        selectedItems = items.filter { selectedPaths.contains($0.path) }
    }

    public func open(_ item: RemoteFileItem) async {
        guard item.isDirectory else { return }
        currentPath = item.path
        await load()
    }

    public func goUp() async {
        guard canGoUp else { return }
        currentPath = RemotePath.parent(of: currentPath)
        await load()
    }

    public func refresh() async {
        await load()
    }

    public func disconnect() async {
        await fs.disconnect()
    }

    /// Directories first, then name case-insensitively —
    /// no backend sorts; this is the sole sorting authority.
    static func sortedForDisplay(_ items: [RemoteFileItem]) -> [RemoteFileItem] {
        items.sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    // MARK: - Browser actions (M7b)

    /// Entry-name validation for rename/new-folder sheets: non-empty, no
    /// path separator, not the two directory pseudo-entries.
    public static func isValidEntryName(_ name: String) -> Bool {
        !name.isEmpty && !name.contains("/") && name != "." && name != ".."
    }

    /// Renames `item` within the current directory. Returns nil on success
    /// (after refreshing; the selection follows the renamed entry), or a
    /// localized error message for inline display in the sheet.
    public func rename(_ item: RemoteFileItem, to newName: String) async -> String? {
        let destination = RemotePath.join(currentPath, newName)
        let detail = "rename \(item.path) → \(newName)"
        do {
            try await fs.rename(from: item.path, to: destination)
        } catch {
            let message = Self.message(for: error, path: item.path)
            auditSink?(AuditEvent(kind: .rename, detail: detail, isError: true, errorMessage: message))
            return message
        }
        await load()
        if let renamed = items.first(where: { $0.path == destination }) {
            selectedItems = [renamed]
        }
        auditSink?(AuditEvent(kind: .rename, detail: detail))
        return nil
    }

    /// Creates a folder in the current directory, refreshes, selects it.
    public func createFolder(named name: String) async -> String? {
        let path = RemotePath.join(currentPath, name)
        // `createDirectory` is idempotent by contract — an existing DIRECTORY
        // would be silently "created". A colliding name must surface in the
        // sheet instead, so probe first. Deviation from the task brief's
        // sketch (which probed the current `items` list): `items` is
        // display-filtered when `showHiddenFiles` is off, so a collision
        // with a HIDDEN dotfile directory would slip past an items-based
        // probe and `createDirectory` would silently "succeed" onto the
        // existing directory. Probing the filesystem directly via `stat`
        // sees the real entry regardless of the display filter.
        let detail = "mkdir \(path)"
        if (try? await fs.stat(path: path)) != nil {
            let message = Self.message(
                for: RemoteFSError.protocolError(reason: "destination already exists: \(path)"),
                path: path)
            auditSink?(AuditEvent(kind: .newFolder, detail: detail, isError: true, errorMessage: message))
            return message
        }
        do {
            try await fs.createDirectory(at: path)
        } catch {
            let message = Self.message(for: error, path: path)
            auditSink?(AuditEvent(kind: .newFolder, detail: detail, isError: true, errorMessage: message))
            return message
        }
        await load()
        if let created = items.first(where: { $0.path == path }) {
            selectedItems = [created]
        }
        auditSink?(AuditEvent(kind: .newFolder, detail: detail))
        return nil
    }

    /// Applies the low 12 permission bits to `item`, then refreshes.
    public func applyPermissions(_ permissions: UInt32, to item: RemoteFileItem) async -> String? {
        let detail = "chmod \(PosixPermissions(rawValue: permissions).octalString) \(item.path)"
        do {
            try await fs.setPermissions(path: item.path, permissions: permissions)
        } catch {
            let message = Self.message(for: error, path: item.path)
            auditSink?(AuditEvent(kind: .permissions, detail: detail, isError: true, errorMessage: message))
            return message
        }
        await load()
        auditSink?(AuditEvent(kind: .permissions, detail: detail))
        return nil
    }

    /// Applies permissions across `item`'s subtree (M11c/T2): a directory
    /// gets `directoryPermissions` and every file underneath gets
    /// `filePermissions` (a non-directory root gets `filePermissions` only,
    /// per `PermissionsTreeApplier`). Symlinks are never touched — see that
    /// walker's doc comments for the security rationale. `progress` is
    /// forwarded to the walk unchanged, for a live UI. The listing is
    /// reloaded exactly once after the walk finishes, regardless of outcome
    /// (success, partial failure, or cooperative cancellation) — unlike the
    /// single-item `applyPermissions` above, a failed reload is not skipped
    /// here because a recursive run can partially succeed even when it
    /// ultimately reports a failure, and the pane must reflect that. Exactly
    /// one audit event is written for the whole run: `isError` is set only
    /// when at least one entry failed, and `errorMessage` carries the
    /// walk's first failure message. The result is returned unchanged — the
    /// UI (T3) is responsible for phrasing it for display.
    public func applyPermissionsRecursively(
        filePermissions: UInt32,
        directoryPermissions: UInt32,
        to item: RemoteFileItem,
        progress: (@Sendable (PermissionsTreeResult) -> Void)? = nil
    ) async -> PermissionsTreeResult {
        let result = await PermissionsTreeApplier.apply(
            root: item.path, kind: item.kind, filePermissions: filePermissions,
            directoryPermissions: directoryPermissions, on: fs, progress: progress)

        await load()

        let fileOctal = PosixPermissions(rawValue: filePermissions).octalString
        let directoryOctal = PosixPermissions(rawValue: directoryPermissions).octalString
        var detail = "chmod -R \(fileOctal)/\(directoryOctal) \(item.path)"
            + " (changed \(result.changed), skipped \(result.skippedSymlinks), failed \(result.failed))"
        if result.cancelled {
            detail += " — cancelled"
        }

        if result.failed > 0 {
            auditSink?(AuditEvent(
                kind: .permissions, detail: detail, isError: true,
                errorMessage: result.firstErrorMessage))
        } else {
            auditSink?(AuditEvent(kind: .permissions, detail: detail))
        }
        return result
    }

    /// Deletes all `doomed` entries sequentially via `deleteTree` (a plain
    /// file behaves like `delete`; a symlink is removed as the link). Stops
    /// at the first failure and returns its localized message — already
    /// deleted entries stay deleted (documented in the spec). Refreshes in
    /// both outcomes so the pane reflects reality.
    ///
    /// The audit detail names only the paths ACTUALLY deleted (M9b/T4
    /// review, finding 6): the previous version listed every path in
    /// `doomed` even on a partial failure, falsely claiming paths past the
    /// break point were removed. On failure the detail is
    /// `delete <deleted paths> — failed at <path>` — the deleted-paths list
    /// is simply absent (just "delete ") when nothing was deleted before the
    /// first failure.
    public func deleteItems(_ doomed: [RemoteFileItem]) async -> String? {
        var deletedPaths: [String] = []
        var failure: String?
        var failedPath: String?
        for item in doomed {
            do {
                try await fs.deleteTree(at: item.path)
                deletedPaths.append(item.path)
            } catch {
                failure = Self.message(for: error, path: item.path)
                failedPath = item.path
                break
            }
        }
        await load()
        var detail = "delete " + deletedPaths.joined(separator: ", ")
        if let failedPath {
            detail += " — failed at \(failedPath)"
        }
        if let failure {
            auditSink?(AuditEvent(kind: .delete, detail: detail, isError: true, errorMessage: failure))
        } else {
            auditSink?(AuditEvent(kind: .delete, detail: detail))
        }
        return failure
    }

    // MARK: - navigate(to:) (M11g/T1)

    /// Navigates to a user-typed absolute path (editable path field): uses
    /// `RemotePath.normalizedAbsolute` to collapse repeated/trailing slashes
    /// — the one `RemotePath` function explicitly safe on hostile,
    /// hand-typed input (see that type's doc comment). Distinguishes three
    /// outcomes with three different messages: empty/whitespace-only input,
    /// a target that `stat`s successfully but is not a directory (its own
    /// message — distinct from "not found", since the FS DID find
    /// something), and any error the file system itself throws (passed
    /// through via the shared `message(for:path:)` mapper unchanged — this
    /// is how a permission-denied `stat` surfaces).
    ///
    /// Symlinks (correction 2026-07-30, T1 review): `LocalFileSystem.stat`
    /// deliberately reports `kind == .symlink` for a symlink even when it
    /// resolves to a directory, while Citadel's `stat` follows links and
    /// returns `.directory` directly — so a plain `isDirectory` check would
    /// reject `/tmp`, `/var`, and `/etc` in the LOCAL pane (all symlinks on
    /// every Mac) with the factually wrong "not a directory" message. When
    /// `stat` reports `.symlink`, a `list()` of the same path is attempted:
    /// if it succeeds, the target is walkable and navigation proceeds. This
    /// keeps Core symlink-agnostic (no `lstat`, no resolution logic here)
    /// and leaves the remote side untouched, since its `stat` already
    /// resolves links before this code ever sees the result.
    ///
    /// `currentPath` is left untouched on every failure path; on success it
    /// is set before `load()`, which also empties the selection.
    public func navigate(to path: String) async -> String? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return CoreL10n.string("core.browse.emptyPath")
        }
        let normalized = RemotePath.normalizedAbsolute(trimmed)
        let target: RemoteFileItem
        do {
            target = try await fs.stat(path: normalized)
        } catch {
            return Self.message(for: error, path: normalized)
        }
        if !target.isDirectory {
            var isWalkableSymlink = false
            if target.kind == .symlink {
                isWalkableSymlink = (try? await fs.list(path: normalized)) != nil
            }
            guard isWalkableSymlink else {
                return String(format: CoreL10n.string("core.browse.notADirectory %@"), normalized)
            }
        }
        currentPath = normalized
        await load()
        return nil
    }

    static func message(for error: Error, path: String) -> String {
        switch error {
        case RemoteFSError.notFound:
            return String(format: CoreL10n.string("core.browse.notFound %@"), path)
        case RemoteFSError.permissionDenied:
            return String(format: CoreL10n.string("core.error.permissionDenied %@"), path)
        case RemoteFSError.protocolError(let reason):
            return String(format: CoreL10n.string("core.browse.protocolError %@"), reason)
        case RemoteFSError.connectionFailed(let reason):
            return String(format: CoreL10n.string("core.error.connectionLost %@"), reason)
        default:
            return String(format: CoreL10n.string("core.error.unexpected %@"), String(describing: error))
        }
    }
}
