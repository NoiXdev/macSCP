import Foundation
import Observation

/// Column a directory listing can be sorted by (M11l). Directories always
/// group first regardless of the chosen key — see
/// `RemoteBrowserViewModel.sortedForDisplay`'s doc comment.
public enum FileSortKey: Sendable, Equatable {
    case name
    case size
    case modified
    /// M11m: numeric ordering of the raw permission bits.
    case permissions
    /// M11m: `localizedCaseInsensitiveCompare` on the owner string; a
    /// missing owner sorts as the "greatest" possible value (opposite
    /// identity from `.size`/`.modified`'s "missing == smallest") — see
    /// `sortedForDisplay`'s doc comment for the full rule.
    case owner
    /// M11m: same rule as `.owner`, for the group string.
    case group
    /// M11m: stable kind order (directory, file, symlink, other) — though
    /// directories are already separated into their own group by the
    /// directories-first rule below, so in practice this only orders
    /// file/symlink/other against each other.
    case type
}

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

    // MARK: - Search (M11k/T1)

    /// The full displayed listing BEFORE search is applied: hidden-files
    /// filter + sort (`displayItems(from:)`), exactly what `items` used to
    /// be before search existed. `load()`/`refreshQuietly()` are the normal
    /// writers (`navigate(to:)` additionally restores a saved snapshot of
    /// this on a rolled-back failed navigation — see that method); the
    /// search derivation reads from this, never from a raw FS listing, so
    /// it stays bounded to what's already on screen (no recursion, no extra
    /// server round-trips — see the M11k design doc).
    private var displayedAll: [RemoteFileItem] = []

    /// Match paths from the last successful derivation, in listing order.
    /// Used by `focusNextMatch()`/`focusPreviousMatch()` to find the
    /// selection's position among matches; not exposed publicly since T2
    /// only needs the counts and the jump navigation, not the raw list.
    private var searchMatchPaths: [String] = []

    /// Search query for the current directory listing (name-only, bounded
    /// to `displayedAll` — see the M11k design doc's "Grenze" section).
    /// Any change re-derives `items` immediately.
    public var searchQuery: String = "" {
        didSet { applySearch() }
    }

    /// Interprets `searchQuery` as a regular expression instead of a plain
    /// substring when `true`.
    public var searchIsRegex: Bool = false {
        didSet { applySearch() }
    }

    /// `.filter` shows only matches; `.jump` keeps the full listing and
    /// moves the selection between matches instead.
    public var searchMode: FileSearchMode = .filter {
        didSet { applySearch() }
    }

    // MARK: - Sort (M11l/T1)

    /// Sort key for the current listing (per-pane display preference).
    /// Setting this re-sorts `displayedAll` in place — no server round-trip
    /// — and re-derives `items` through the same `applySearch()` pipeline
    /// the search state uses, so sort and an active filter compose
    /// consistently. Unlike `searchQuery`, this is NEVER reset by
    /// `load()`/`open`/`goUp`/`navigate(to:)`: it is a display preference of
    /// the pane, not an attribute of the directory (M11l design).
    public var sortKey: FileSortKey = .name {
        didSet { resortDisplayedAll() }
    }

    /// Sort direction for `sortKey`. See `sortKey`'s doc comment for the
    /// same survives-navigation rule.
    public var sortAscending: Bool = true {
        didSet { resortDisplayedAll() }
    }

    /// Re-sorts the already hidden-filtered `displayedAll` with the current
    /// `sortKey`/`sortAscending` and re-derives `items` via `applySearch()`.
    /// Re-sorting the already-sorted list (rather than re-listing from the
    /// server) is safe because `sortedForDisplay` is a full, deterministic
    /// re-order driven entirely by its comparator — the PREVIOUS order of
    /// its input never affects the result.
    private func resortDisplayedAll() {
        displayedAll = Self.sortedForDisplay(displayedAll, key: sortKey, ascending: sortAscending)
        applySearch()
    }

    /// Set when `searchQuery`/`searchIsRegex` describe an invalid regular
    /// expression. Deliberately does NOT clear `items` when set — the
    /// maintainer rejected a faked "0 matches" for this case (M11k design);
    /// the last valid listing stays on screen while the UI shows the error.
    public private(set) var searchError: FileSearchError?

    /// "N of M" readout for the search field (T2). Both reflect the last
    /// SUCCESSFUL derivation — they hold their previous values across an
    /// invalid-regex edit, consistent with `items` staying put too.
    public private(set) var searchMatchCount = 0
    public private(set) var searchTotalCount = 0

    /// Re-derives `items` (and the search-facing state) from `displayedAll`
    /// via the pure `FileSearch.derive`. On success, `items`/counts/error
    /// are all updated together. On an invalid regex, ONLY `searchError` is
    /// set — `items`, the counts, and `searchMatchPaths` are left exactly
    /// as they were, per the "invalid regex is never a faked zero-match
    /// result" rule.
    private func applySearch() {
        switch FileSearch.derive(
            all: displayedAll, query: searchQuery, isRegex: searchIsRegex, mode: searchMode
        ) {
        case .success(let derivation):
            searchError = nil
            items = derivation.visible
            searchMatchPaths = derivation.matchPaths
            searchMatchCount = derivation.matchCount
            searchTotalCount = derivation.totalCount
        case .failure(let error):
            searchError = error
        }
    }

    /// Resets the search to "no filter" (empty query). Called by the
    /// navigation entry points (`open`/`goUp`/`navigate`-on-success) so a
    /// filter left over from a previous directory never silently hides the
    /// new one — NOT by `load()`, which keeps the active search so a
    /// same-directory refresh (rename/delete/chmod) re-applies it. Also the
    /// operation the App layer's Esc handling (T2) uses to close the field.
    public func clearSearch() {
        searchQuery = ""
    }

    /// Moves `selectedItems` to the next search match, in listing order,
    /// wrapping past the last match back to the first. No-op if there are
    /// no matches. If the current selection isn't itself a match (or
    /// nothing is selected), lands on the first match.
    public func focusNextMatch() {
        guard !searchMatchPaths.isEmpty else { return }
        let currentIndex = selectedItems.first.flatMap { searchMatchPaths.firstIndex(of: $0.path) }
        let nextIndex = currentIndex.map { ($0 + 1) % searchMatchPaths.count } ?? 0
        focusMatch(at: nextIndex)
    }

    /// Moves `selectedItems` to the previous search match, wrapping past
    /// the first match back to the last. Mirrors `focusNextMatch()`.
    public func focusPreviousMatch() {
        guard !searchMatchPaths.isEmpty else { return }
        let currentIndex = selectedItems.first.flatMap { searchMatchPaths.firstIndex(of: $0.path) }
        let previousIndex = currentIndex.map { ($0 - 1 + searchMatchPaths.count) % searchMatchPaths.count }
            ?? searchMatchPaths.count - 1
        focusMatch(at: previousIndex)
    }

    private func focusMatch(at index: Int) {
        let path = searchMatchPaths[index]
        // In `.jump` mode `items` is the full listing, so the match is
        // always present; in `.filter` mode it's present too (matches are
        // exactly what's visible). Either way, look it up in `items` rather
        // than `displayedAll` so the selection is built from the same rows
        // the table is showing.
        guard let match = items.first(where: { $0.path == path }) else { return }
        selectedItems = [match]
    }

    /// Re-lists `currentPath` and re-derives `items` (M11k: WITH the
    /// currently active search, unchanged). `load()` is also the
    /// same-directory refresh path used after `rename`/`createFolder`/
    /// `applyPermissions`/`applyPermissionsRecursively`/`deleteItems` — none
    /// of those change `currentPath`, so a filter active while renaming or
    /// deleting an entry must survive the refresh and keep applying to the
    /// fresh listing (M11k design/T1 fix). Resetting search on an actual
    /// directory CHANGE is the job of the three navigation entry points
    /// (`open(_:)`, `goUp()`, `navigate(to:)`), each of which calls
    /// `clearSearch()` itself before/around calling into this method.
    ///
    /// Staleness guard (M18a review, Important): the App fires
    /// `refreshAndSelect(path:)` — which calls this method — in a DETACHED
    /// `Task` after `createFolder`/`rename`/`createFile`, so the sheet can
    /// dismiss immediately instead of waiting on a listing that may block on
    /// a slow server or a macOS permission prompt. That means this method's
    /// `await` can still be in flight when the user navigates elsewhere, so
    /// the directory being listed is captured up front and the result — in
    /// BOTH the success and the failure branch — is only applied if
    /// `currentPath` is still that same directory afterwards: the late
    /// writer must lose, exactly like `refreshQuietly()` below already
    /// guards against the same race for its own (silent, timer-driven)
    /// refresh.
    public func load() async {
        state = .loading
        selectedItems = []
        let path = currentPath
        do {
            let listed = try await fs.list(path: path)
            guard currentPath == path else { return }
            displayedAll = displayItems(from: listed)
            applySearch()
            state = .loaded
        } catch {
            guard currentPath == path else { return }
            displayedAll = []
            applySearch()
            state = .failed(message: Self.message(for: error, path: path))
        }
    }

    /// Shared display pipeline for `load()` and `refreshQuietly()` — the
    /// hidden-files filter and sort MUST stay identical between the two.
    private func displayItems(from listed: [RemoteFileItem]) -> [RemoteFileItem] {
        let visible = showHiddenFiles
            ? listed
            : listed.filter { !$0.name.hasPrefix(".") }
        return Self.sortedForDisplay(visible, key: sortKey, ascending: sortAscending)
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
        displayedAll = displayItems(from: listed)
        // Unlike `load()`, the directory is the SAME one — an active
        // search stays active and is re-applied to the fresh listing
        // (M11k design).
        applySearch()
        selectedItems = items.filter { selectedPaths.contains($0.path) }
    }

    public func open(_ item: RemoteFileItem) async {
        guard item.isDirectory else { return }
        currentPath = item.path
        // A directory change: a filter from the OLD directory must not
        // silently hide the new one (M11k design). Unlike `navigate(to:)`,
        // `open`/`goUp` have no rollback-on-failure path, so there is no
        // "stranded search" risk here to guard against.
        clearSearch()
        await load()
    }

    public func goUp() async {
        guard canGoUp else { return }
        currentPath = RemotePath.parent(of: currentPath)
        // See the comment in `open(_:)` — same rationale.
        clearSearch()
        await load()
    }

    public func refresh() async {
        await load()
    }

    /// Refreshes the listing and selects `path` when present. Called after a
    /// successful create/rename so the sheet can dismiss immediately (M18a).
    public func refreshAndSelect(path: String) async {
        await load()
        if let entry = items.first(where: { $0.path == path }) {
            selectedItems = [entry]
        }
    }

    public func disconnect() async {
        await fs.disconnect()
    }

    /// Directories always group first, no matter which `key`/`ascending` is
    /// requested (M11l/T1): this is a DELIBERATE grouping, not a bug — a
    /// directory carries no comparable size, and mixing it into a size/date
    /// ordering with files would be both meaningless and a silent behavior
    /// change from the folders-first browsing this app has always had.
    /// Within each group (directories, then non-directories), entries are
    /// ordered by `key`:
    /// - `.name`: `localizedCaseInsensitiveCompare` (today's only key,
    ///   unchanged).
    /// - `.size`: NUMERIC comparison of the `UInt64` byte count — never
    ///   lexicographic (9 < 10 < 100, not "10" < "100" < "9"). An item with
    ///   no `size` (e.g. a directory compared within its own group, or an FS
    ///   that never reports one) sorts as if it had the SMALLEST possible
    ///   size, i.e. first among ascending results.
    /// - `.modified`: `Date` comparison. An item with no `modifiedAt` sorts
    ///   as if it were the OLDEST possible date, i.e. first among ascending
    ///   results.
    /// Every comparison ends with a `name.localizedCaseInsensitiveCompare`
    /// tiebreaker, so two entries with equal size/date always land in the
    /// same deterministic order (stable, regardless of input order).
    /// `ascending == false` reverses the ordering WITHIN each group only —
    /// it does not touch the "smallest"/"oldest" identity of a missing
    /// value, so a missing size/date still sorts to the same end of its
    /// group's own ordering (last, once descending flips "smallest first"
    /// into "smallest last") — and it never touches the directories-first
    /// grouping itself (folders stay on top even sorting "descending").
    /// The pre-M11l call site (`sortedForDisplay(_:)`, no `key`/`ascending`)
    /// keeps working unchanged via the defaults below.
    static func sortedForDisplay(
        _ items: [RemoteFileItem], key: FileSortKey = .name, ascending: Bool = true
    ) -> [RemoteFileItem] {
        items.sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            // The PRIMARY key follows `ascending`; the name tiebreaker does
            // NOT (M11l/T1 review): equal-size or equal-date rows always read
            // A→Z, even in a descending sort, matching the Finder. Applying
            // the direction flip to the whole comparison (tiebreaker included)
            // would sort those Z→A, which reads as inconsistent.
            let primary = primaryOrder(a, b, key: key)
            if primary != .orderedSame {
                return ascending ? primary == .orderedAscending : primary == .orderedDescending
            }
            return nameOrder(a, b) == .orderedAscending
        }
    }

    /// `ComparisonResult` for `a` vs. `b` under `key`, WITHOUT the name
    /// tiebreaker (which `sortedForDisplay` applies separately, always
    /// ascending). For `.name` the key IS the name, so there is nothing left
    /// to break ties with. See `sortedForDisplay`'s doc comment for the
    /// missing-value rule.
    private static func primaryOrder(_ a: RemoteFileItem, _ b: RemoteFileItem, key: FileSortKey) -> ComparisonResult {
        switch key {
        case .name:
            return nameOrder(a, b)
        case .size:
            return compareOptional(a.size, b.size)
        case .modified:
            return compareOptional(a.modifiedAt, b.modifiedAt)
        case .permissions:
            return compareOptional(a.permissions, b.permissions)
        case .owner:
            return compareOptionalLocalizedString(a.owner, b.owner)
        case .group:
            return compareOptionalLocalizedString(a.group, b.group)
        case .type:
            return compareTypeRank(a.kind, b.kind)
        }
    }

    private static func nameOrder(_ a: RemoteFileItem, _ b: RemoteFileItem) -> ComparisonResult {
        a.name.localizedCaseInsensitiveCompare(b.name)
    }

    /// A missing value (`nil`) is ordered as the SMALLEST/OLDEST possible
    /// value — first among ascending results. Both call sites above
    /// (`.size`, `.modified`) rely on this exact rule.
    private static func compareOptional<T: Comparable>(_ a: T?, _ b: T?) -> ComparisonResult {
        switch (a, b) {
        case (nil, nil): return .orderedSame
        case (nil, _): return .orderedAscending
        case (_, nil): return .orderedDescending
        case (let x?, let y?):
            if x < y { return .orderedAscending }
            if x > y { return .orderedDescending }
            return .orderedSame
        }
    }

    /// Same idea as `compareOptional`, but for the M11m `.owner`/`.group`
    /// keys: present values compare with `localizedCaseInsensitiveCompare`,
    /// and a missing value (`nil`) is ordered as the GREATEST possible
    /// value — the OPPOSITE identity from `compareOptional`'s "missing ==
    /// smallest" rule for `.size`/`.modified`. That identity is what makes
    /// `nil` sort LAST in the common ascending case; `sortedForDisplay`'s
    /// direction flip then moves it to FIRST under a descending sort,
    /// exactly the same mechanical reversal `.size`/`.modified` already get
    /// (see that method's doc comment) — the identity itself never changes,
    /// only which end of the ordering it lands on.
    private static func compareOptionalLocalizedString(_ a: String?, _ b: String?) -> ComparisonResult {
        switch (a, b) {
        case (nil, nil): return .orderedSame
        case (nil, _): return .orderedDescending
        case (_, nil): return .orderedAscending
        case (let x?, let y?):
            return x.localizedCaseInsensitiveCompare(y)
        }
    }

    /// Stable rank for `.type` sorting: directory, file, symlink, other, in
    /// that order. Directories are already split into their own group by
    /// `sortedForDisplay`'s directories-first rule, so this rank only ever
    /// discriminates between non-directory kinds in practice — it's kept
    /// complete (covering `.directory` too) so the function stands on its
    /// own as a total, documented ordering.
    private static func typeRank(_ kind: RemoteFileKind) -> Int {
        switch kind {
        case .directory: return 0
        case .file: return 1
        case .symlink: return 2
        case .other: return 3
        }
    }

    private static func compareTypeRank(_ a: RemoteFileKind, _ b: RemoteFileKind) -> ComparisonResult {
        let (rankA, rankB) = (typeRank(a), typeRank(b))
        if rankA < rankB { return .orderedAscending }
        if rankA > rankB { return .orderedDescending }
        return .orderedSame
    }

    // MARK: - Browser actions (M7b)

    /// Entry-name validation for rename/new-folder sheets: non-empty, no
    /// path separator, not the two directory pseudo-entries.
    public static func isValidEntryName(_ name: String) -> Bool {
        !name.isEmpty && !name.contains("/") && name != "." && name != ".."
    }

    /// Renames `item` within the current directory. Returns nil on success,
    /// or a localized error message for inline display in the sheet.
    /// Deliberately does NOT refresh the listing itself — refreshing is
    /// presentation only, and keeping it out of this method means dismissing
    /// the sheet never waits on a listing, which can block on a slow server,
    /// a huge directory, or a macOS permission prompt (M18a). Callers refresh
    /// via `refreshAndSelect(path:)` afterwards, passing the destination path
    /// so the renamed entry ends up selected.
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
        auditSink?(AuditEvent(kind: .rename, detail: detail))
        return nil
    }

    /// Creates a folder in the current directory. Returns nil on success, or
    /// a localized error message for inline display in the sheet. Deliberately
    /// does NOT refresh the listing itself — see `rename(_:to:)`'s doc
    /// comment for the rationale (M18a). Callers refresh via
    /// `refreshAndSelect(path:)` afterwards.
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
        // The directory exists once `createDirectory` returns; refreshing the
        // listing is presentation only. Keeping it out of this method means
        // dismissing the sheet never waits on a listing — which can block on
        // a slow server, a huge directory, or a macOS permission prompt
        // (M18a). Callers refresh via `refreshAndSelect(path:)` afterwards.
        auditSink?(AuditEvent(kind: .newFolder, detail: detail))
        return nil
    }

    /// Creates an empty file in the current directory. Same collision probe
    /// and error contract as `createFolder(named:)` — see its doc comment
    /// for the rationale of probing via `stat` instead of the display-
    /// filtered `items` list. Like it, this does NOT refresh the listing;
    /// callers use `refreshAndSelect(path:)` afterwards (M18a).
    public func createFile(named name: String) async -> String? {
        let path = RemotePath.join(currentPath, name)
        let detail = "create \(path)"
        if (try? await fs.stat(path: path)) != nil {
            let message = Self.message(
                for: RemoteFSError.protocolError(reason: "destination already exists: \(path)"),
                path: path)
            auditSink?(AuditEvent(kind: .newFile, detail: detail, isError: true, errorMessage: message))
            return message
        }
        do {
            let empty = AsyncThrowingStream<Data, Error> { $0.finish() }
            try await fs.write(path: path, mode: .overwrite, contents: empty)
        } catch {
            let message = Self.message(for: error, path: path)
            auditSink?(AuditEvent(kind: .newFile, detail: detail, isError: true, errorMessage: message))
            return message
        }
        auditSink?(AuditEvent(kind: .newFile, detail: detail))
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
    ///
    /// A `stat` success is not the same thing as a navigable directory
    /// (M11g final review, Important): a directory with no read permission
    /// `stat`s fine (its metadata is visible) but fails `load()`'s own
    /// `list` — the common case of a non-root SFTP user typing `/root`.
    /// `load()` cannot fail loudly by design (it's also the silent
    /// auto-refresh path), so its failure is read back from `state`
    /// afterwards instead: if `load()` left the view model in `.failed`,
    /// that's not a successful navigation, and everything — `currentPath`,
    /// `items`, `selectedItems` — is rolled back to its pre-navigate
    /// snapshot, exactly as every OTHER failure path here already leaves it,
    /// so the field can stay open with the message instead of the pane
    /// falling back to its red failure screen for a directory whose old
    /// listing was fine all along.
    ///
    /// Search (M11k/T1 fix): the active search is cleared ONLY after
    /// `load()` has actually succeeded AND the target directory differs
    /// from `currentPath` — navigating to the SAME directory (e.g.
    /// re-submitting the path bar unchanged) keeps the filter, exactly like
    /// a same-directory `load()` triggered by `rename`/`deleteItems`/etc.
    /// `searchQuery`/`searchIsRegex`/`searchMode` are never touched before
    /// that point, so a FAILED navigation can't strand the user with a
    /// cleared search on top of the failure message: the search-derived
    /// state that `load()` mutates while probing the new (bad) path —
    /// `displayedAll`, `items`, `searchError`, `searchMatchCount`,
    /// `searchTotalCount` — is captured up front alongside the existing
    /// snapshot and restored byte-for-byte on rollback, same as `state`/
    /// `selectedItems` already were.
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
        let previousPath = currentPath
        let previousDisplayedAll = displayedAll
        let previousState = state
        let previousSelection = selectedItems
        let directoryChanging = normalized != currentPath
        currentPath = normalized
        await load()
        if case .failed(let message) = state {
            // Roll back the base and re-derive ALL search-facing state from
            // it in one place (M11k/T1 review): the failed `load()` above ran
            // `applySearch()` against an empty `displayedAll`, which zeroed
            // `searchMatchPaths`/counts/`items`. Restoring only some of those
            // fields by hand left `searchMatchPaths` stale (empty) while the
            // query and counts still claimed matches — jump navigation would
            // then find nothing. Restoring the base and calling `applySearch`
            // reproduces the exact pre-navigate derived state (same inputs)
            // and can't drift as fields are added.
            currentPath = previousPath
            displayedAll = previousDisplayedAll
            state = previousState
            selectedItems = previousSelection
            applySearch()
            return message
        }
        if directoryChanging {
            clearSearch()
        }
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
