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
            let visible = showHiddenFiles
                ? listed
                : listed.filter { !$0.name.hasPrefix(".") }
            items = Self.sortedForDisplay(visible)
            state = .loaded
        } catch {
            items = []
            state = .failed(message: Self.message(for: error, path: currentPath))
        }
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
        do {
            try await fs.rename(from: item.path, to: destination)
        } catch {
            return Self.message(for: error, path: item.path)
        }
        await load()
        if let renamed = items.first(where: { $0.path == destination }) {
            selectedItems = [renamed]
        }
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
        if (try? await fs.stat(path: path)) != nil {
            return Self.message(
                for: RemoteFSError.protocolError(reason: "destination already exists: \(path)"),
                path: path)
        }
        do {
            try await fs.createDirectory(at: path)
        } catch {
            return Self.message(for: error, path: path)
        }
        await load()
        if let created = items.first(where: { $0.path == path }) {
            selectedItems = [created]
        }
        return nil
    }

    /// Applies the low 12 permission bits to `item`, then refreshes.
    public func applyPermissions(_ permissions: UInt32, to item: RemoteFileItem) async -> String? {
        do {
            try await fs.setPermissions(path: item.path, permissions: permissions)
        } catch {
            return Self.message(for: error, path: item.path)
        }
        await load()
        return nil
    }

    /// Deletes all `doomed` entries sequentially via `deleteTree` (a plain
    /// file behaves like `delete`; a symlink is removed as the link). Stops
    /// at the first failure and returns its localized message — already
    /// deleted entries stay deleted (documented in the spec). Refreshes in
    /// both outcomes so the pane reflects reality.
    public func deleteItems(_ doomed: [RemoteFileItem]) async -> String? {
        var failure: String?
        for item in doomed {
            do {
                try await fs.deleteTree(at: item.path)
            } catch {
                failure = Self.message(for: error, path: item.path)
                break
            }
        }
        await load()
        return failure
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
