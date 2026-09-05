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
    /// The row's `FileTypeLabel` (Browser Type Column, 2026-09-04):
    /// `localizedCaseInsensitiveCompare`d, same rule as `.owner`/`.group`.
    /// Directories are already separated into their own group by the
    /// directories-first rule below (a bucket row's `kind` is `.directory`
    /// too, so buckets sort inside that group, ordered by their own
    /// "Bucket" label against "Folder") — so in practice this discriminates
    /// within the directory group and within the non-directory group
    /// separately.
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

    /// The error `load()` most recently caught, set in the same breath as
    /// `state = .failed(message:)` and `nil` again from the top of every
    /// `load()` call (fix round 1, Structural). `State` stays `Equatable`
    /// and carries only the display text; this is the seam the App layer
    /// reads to log `error` `\(logCategory) reason=…` through
    /// `DiagnosticLog.log(_:_:_:reason:)` — which needs the ORIGINAL error,
    /// not the already-rendered `message`, so it can compute
    /// `DialSupport.reason(for:)` itself rather than have a caller
    /// hand-format `reason=\(message)` (the shape the secrecy guard now
    /// refuses).
    public private(set) var lastLoadError: (any Error)?

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

    /// Diagnostic-log category this pane's `load()` events are filed under.
    /// Set once at construction by the App, which is the only layer that
    /// knows which pane this is — the view model itself only ever sees `fs`
    /// as `any RemoteFileSystem` and cannot tell `LocalFileSystem` from a
    /// remote backend by inspecting it. `ContentView.swift` passes
    /// `"browser.local"` for the pane it builds on `LocalFileSystem` and
    /// `"browser.remote"` for the other; the default here covers every other
    /// construction site (tests, previews) with the remote spelling, since a
    /// remote backend is what every non-App caller of this initializer
    /// actually passes.
    public let logCategory: String

    /// Optional audit-log sink (M9b/T2), default nil (no logging — matches
    /// ad-hoc/unstored sessions). Each of the four actions below fires it
    /// exactly once, AFTER the action completes: success and failure both
    /// report (failure with `isError: true` and the localized message the
    /// action already returns to its caller). The App layer wires this to an
    /// `AuditRecorder.recordAction` closure for stored sessions.
    public var auditSink: ((AuditEvent) -> Void)?

    public init(
        fs: any RemoteFileSystem, startPath: String = "/", logCategory: String = "browser.remote"
    ) {
        self.fs = fs
        self.currentPath = startPath
        self.logCategory = logCategory
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

    /// The Task Task 3's phase-two metadata merge runs as (local-listing-
    /// never-blocks design, point 3), stored so a NEW `load()` call — or
    /// simply calling `load()` again for the SAME directory, e.g. a
    /// `rename`/`delete` refresh — cancels whatever merge is still running
    /// for a PREVIOUS listing. Nothing else does: `LocalMetadataSource
    /// .metadata(for:)`'s stream can sit open indefinitely behind one stuck
    /// entry (Task 2's accepted cost — a child that never returns leaves
    /// `MetadataTally`'s count short forever, so the stream never calls
    /// `finish()` on its own), and this Task is not the one SwiftUI's
    /// `.task { await viewModel.load() }` (`BrowserPane.swift`) owns — that
    /// Task is cancelled only when the PANE goes away, while
    /// `open(_:)`/`goUp()`/`navigate(to:)` each call `load()` again from
    /// whatever Task the button/double-click handler created, a Task
    /// entirely unrelated to the one still consuming the OLD directory's
    /// stream. The staleness guard inside the loop below still stops a late
    /// arrival from repainting the wrong directory even if this
    /// cancellation somehow lost a race, but by itself that guard would
    /// leave the old consumption loop parked forever, doing nothing useful
    /// — cancelling it here is what actually lets it go: a cancelled `for
    /// await` over an `AsyncStream` observes the cancellation at its next
    /// suspension point, ends the loop, and fires the stream's
    /// `onTermination` (`consumerWentAway`, `LocalMetadataSource.swift`),
    /// exactly as if this loop had `break`-ed out on its own.
    private var mergeTask: Task<Void, Never>?

    /// `true` between a merge arrival that changed `displayedAll` and the
    /// `publishMergedMetadata` call that reflects it — the coalescing flag
    /// `load()`'s merge loop and its own scheduled flush (see
    /// `mergeFlushScheduled`) share. Backing STORAGE for that sharing is
    /// ordinary `@MainActor`-isolated instance state, deliberately not a
    /// local `var` captured by two separate `Task { }` closures: two
    /// escaping closures over the same mutable local works out in practice
    /// (Swift boxes a captured `var` shared by every closure that closes
    /// over it), but going through `self` avoids the question entirely and
    /// reads the same as `mergeTask` itself.
    private var mergeDirty = false

    /// `true` while a flush `Task` is already scheduled to run
    /// `publishMergedMetadata` — sibling to `mergeDirty`. This is what
    /// keeps a burst of arrivals from scheduling one flush Task per item:
    /// only the FIRST arrival since the last flush schedules one; every
    /// arrival after it just updates `mergeDirty` and relies on the
    /// already-scheduled flush to pick it up.
    private var mergeFlushScheduled = false

    /// `true` between a merge arrival whose `kind` changed in a way that
    /// flips `isDirectory` (`.other` resolving to `.directory` once
    /// metadata arrives is the case this exists for — `listByReaddir`
    /// returns `.other` for a `DT_UNKNOWN` child, and phase two's `item(for:)`
    /// never returns `.other`, so such a row can only ever move INTO one of
    /// `.file`/`.directory`/`.symlink`) and the next `publishMergedMetadata`
    /// call that reflects it (final fix round, Minor). `sortedForDisplay`
    /// groups directories first regardless of `sortKey`, so a kind change
    /// that flips `isDirectory` reorders the listing under EVERY sort key,
    /// not only the ones in `metadataOrderedSortKeys` below — `publish
    /// MergedMetadata` resorts when either this or the sort-key-based
    /// `needsResort` is set, and clears this flag right after.
    private var mergeGroupingChanged = false

    /// `load()`'s own path→index map into `displayedAll`, built once when
    /// the merge starts and rebuilt inside `publishMergedMetadata` whenever
    /// a resort actually reordered `displayedAll` (final fix round,
    /// Important — replaces a `firstIndex(where:)` scan per arrival, which
    /// is O(n) per arrival and therefore O(n²) over a full listing; 5000
    /// entries meant roughly 12.5 million compares on the main actor for a
    /// single merge). Looking an arrival up here instead is O(1). Kept
    /// current the same way the old per-arrival scan stayed correct across
    /// an in-flight resort: `sortedForDisplay` is the only thing that moves
    /// an entry to a DIFFERENT index without changing its `path` (a plain
    /// metadata fill-in overwrites the element in place, so the index
    /// itself never changes for that), and every call that runs it
    /// (`publishMergedMetadata`'s own resort) rebuilds this map in the same
    /// breath — see that method's doc comment.
    private var mergePathIndex: [String: Int] = [:]

    /// Sort keys phase two's arriving `size`/`modifiedAt`/`owner`/`group`
    /// can change the order of — `.name` and `.type` are already correct
    /// from phase one's own `kind`/name, so re-sorting for either of those
    /// on every arrival would just repeat phase one's own sort for no
    /// visible change (Task 3 coordinator resolution). `.permissions` is
    /// deliberately NOT in this set (final fix round, Minor): phase two's
    /// `item(for:)` never fills `permissions` (the local pane's own
    /// `permissionModel` doc comment states this — the field stays nil
    /// straight through phase two), so re-sorting for it on every arrival
    /// would, like `.name`/`.type`, produce no visible change — the
    /// difference is `.permissions` looks like a phase-two field, not a
    /// phase-one one, which is exactly why it needs saying rather than
    /// simply being absent from the list.
    private static let metadataOrderedSortKeys: Set<FileSortKey> = [
        .size, .modified, .owner, .group,
    ]

    /// The path→index map for `mergePathIndex`, freshly built from
    /// `items`' current order — `path` (`RemoteFileItem.id`) is unique
    /// within one directory listing, so `uniqueKeysWithValues` never traps.
    private static func pathIndex(for items: [RemoteFileItem]) -> [String: Int] {
        Dictionary(uniqueKeysWithValues: items.enumerated().map { ($1.path, $0) })
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
        mergeTask?.cancel()
        // A merge session abandoned mid-flight (by the cancel above) may
        // leave these set — reset unconditionally so a stale
        // `mergeFlushScheduled == true` from a cancelled session can never
        // make THIS session's loop believe a flush is already pending when
        // none will ever run (see both properties' doc comments).
        mergeDirty = false
        mergeFlushScheduled = false
        mergeGroupingChanged = false
        mergePathIndex = [:]
        state = .loading
        lastLoadError = nil
        selectedItems = []
        let path = currentPath
        let clock = ContinuousClock()
        let start = clock.now
        do {
            let listed = try await fs.list(path: path)
            guard currentPath == path else { return }
            displayedAll = displayItems(from: listed)
            applySearch()
            state = .loaded
            // Its own line, one layer above `LocalFileSystem.list`'s own
            // `browser.local list done` (which the local pane ALSO writes,
            // at the FS level): that line carries the raw read and the
            // per-entry timing, this one the hidden-file filter and sort
            // that turn a raw listing into what the pane actually shows —
            // `displayedAll.count`, not `listed.count`.
            let ms = Int(start.duration(to: clock.now).milliseconds.rounded())
            // `displayedAll.count` captured into a local first: the message
            // argument is `@Sendable @autoclosure`, and `displayedAll` is
            // `@MainActor`-isolated.
            let count = displayedAll.count
            DiagnosticLog.shared.log(
                .info, logCategory, "load done path=\(path) count=\(count) ms=\(ms)")

            // Phase two (Task 3, local-listing-never-blocks design, point
            // 3): a local backend's size/modified/owner/group arrive after
            // the fact, one entry at a time — `LocalMetadataSource
            // .metadata(for:)` yields each of `listed`, filled in, in
            // ARRIVAL order (not `listed`'s own order — see that
            // protocol's doc comment). A remote backend never satisfies
            // `as?` here: SFTP's `readdir` already returns attributes with
            // the names, so it has no second phase to run.
            //
            // Spawned as its own Task rather than awaited inline: every
            // existing caller of `load()` (`open`, `goUp`,
            // `refreshAndSelect`, `navigate(to:)`) already awaits it
            // expecting it to return once phase one is on screen, and a
            // directory with one permanently stuck entry must not turn
            // every one of them into a hang — Task 2's accepted cost is
            // one stuck THREAD, never a stuck caller. A plain `Task`, not
            // `.detached`: `load()` is already `@MainActor`-isolated, so
            // the merge inherits that isolation for free, the same
            // reasoning `LocalMetadataSource.metadata(for:)`'s own
            // children give for themselves. Stored in `mergeTask` so the
            // NEXT `load()` call can cancel it — see that property's doc
            // comment.
            //
            // `metadataSource.metadata(for: listed)` is called HERE,
            // synchronously, before the Task below is even created —
            // deliberately not inside the Task's own closure. `Task { }`
            // only ENQUEUES its closure; it does not start running it
            // before `load()` itself returns (there is no further `await`
            // below this point). A test — or a caller — that inspects the
            // file system's own bookkeeping right after `await load()`
            // returns (e.g. "was `metadata(for:)` called with phase one's
            // listing yet?") must see it already true, not racing whether
            // the spawned Task has had a turn on the executor yet. Calling
            // it here, before spawning, makes that true by construction:
            // only the (potentially long-running, potentially never-
            // ending) CONSUMPTION of the stream happens inside the Task.
            if let metadataSource = fs as? any LocalMetadataSource, !listed.isEmpty {
                let needsResort = Self.metadataOrderedSortKeys.contains(sortKey)
                let stream = metadataSource.metadata(for: listed)
                // Built once, here, from phase one's just-sorted
                // `displayedAll` — before the merge loop below ever reads
                // it (final fix round, Important, replacing a per-arrival
                // `firstIndex(where:)` scan: 5000 entries meant roughly
                // 12.5 million compares on the main actor for one merge).
                // `publishMergedMetadata` rebuilds this whenever ITS OWN
                // resort actually reorders `displayedAll` — the only thing
                // that moves an entry to a different index without
                // changing its `path` — so the loop below can trust a
                // single dictionary lookup instead of re-scanning.
                mergePathIndex = Self.pathIndex(for: displayedAll)
                mergeTask = Task { @MainActor [weak self] in
                    guard let self else { return }
                    // Batches UI updates rather than publishing once per
                    // arrival (measured 2026-09-05: a naive one-publish-
                    // per-item republish would fire once per file in a
                    // 5000-entry directory), WITHOUT reaching for a
                    // wall-clock duration: only the FIRST arrival since the
                    // last flush schedules a plain `Task` (inheriting this
                    // one's `@MainActor` isolation) to run
                    // `publishMergedMetadata` — every arrival after it,
                    // while that flush is still pending, just updates
                    // `mergeDirty` and relies on the already-scheduled
                    // flush to pick it up (`mergeFlushScheduled` is the
                    // guard against scheduling a second one). This is
                    // deliberately NOT "wait N ms since the last publish
                    // and check again on the next arrival" (an earlier
                    // version of this loop measured 2026-09-05): with a
                    // stuck entry in the SAME directory as fast ones, that
                    // shape can leave a fast entry's own update sitting in
                    // `mergeDirty` forever, since nothing but ANOTHER
                    // arrival or the stream's own `finish()` ever
                    // re-checked the elapsed time — and a directory with a
                    // stuck entry is precisely the case where neither may
                    // ever happen again. Scheduling the flush as its own
                    // Task instead means it runs on the next turn this
                    // Task's priority gets from the executor regardless of
                    // whether the stream ever yields again.
                    for await filled in stream {
                        guard self.currentPath == path else { return }
                        guard let index = self.mergePathIndex[filled.path] else { continue }
                        // A `.other` row resolving to `.directory` (or, in
                        // principle, the reverse) moves between the
                        // directories-first and non-directory groups no
                        // matter which `sortKey` is active — see
                        // `mergeGroupingChanged`'s own doc comment.
                        let previousKind = self.displayedAll[index].kind
                        self.displayedAll[index] = filled
                        if (previousKind == .directory) != (filled.kind == .directory) {
                            self.mergeGroupingChanged = true
                        }
                        self.mergeDirty = true
                        guard !self.mergeFlushScheduled else { continue }
                        self.mergeFlushScheduled = true
                        Task { @MainActor [weak self] in
                            guard let self, self.currentPath == path else { return }
                            if self.mergeDirty {
                                self.publishMergedMetadata(
                                    needsResort: needsResort || self.mergeGroupingChanged)
                                self.mergeDirty = false
                                self.mergeGroupingChanged = false
                            }
                            self.mergeFlushScheduled = false
                        }
                    }
                    guard self.currentPath == path, self.mergeDirty else { return }
                    self.publishMergedMetadata(needsResort: needsResort || self.mergeGroupingChanged)
                    self.mergeDirty = false
                    self.mergeGroupingChanged = false
                }
            }
        } catch {
            guard currentPath == path else { return }
            displayedAll = []
            applySearch()
            let message = Self.message(for: error, path: path)
            state = .failed(message: message)
            lastLoadError = error
            // The ORIGINAL `error`, not `message` (fix round 1, Structural):
            // `message` is already the user-facing, localized banner text —
            // interpolating it a second time here is exactly the
            // hand-written `reason=` shape the new `log(_:_:_:reason:)`
            // overload replaces. Passing `error` lets that overload compute
            // `DialSupport.reason(for:)` itself, the one place that mapping
            // happens.
            DiagnosticLog.shared.log(.info, logCategory, "load failed path=\(path)", reason: error)
        }
    }

    /// The one publish point `load()`'s phase-two merge loop uses, for both
    /// its per-arrival batch and its final catch-up after the stream ends
    /// — so the two can never drift into applying the sort/search pipeline
    /// differently. Re-sorts `displayedAll` only when `needsResort` is set
    /// (`sortKey` is one of `metadataOrderedSortKeys`, OR a kind change
    /// flipped the directories-first grouping — see `mergeGroupingChanged`),
    /// rebuilding `mergePathIndex` in the same breath so the merge loop's
    /// next lookup sees the entries at their NEW indices, then re-derives
    /// `items` via `applySearch()` exactly like every other mutation of
    /// `displayedAll` in this type.
    ///
    /// `selectedItems` is re-derived from the fresh `items` afterwards
    /// (final fix round, Minor) — the same rebuild-by-path
    /// `refreshQuietly()` already does for its own refresh, applied here so
    /// a row selected before its metadata arrived (Get Info opened on a
    /// still-loading entry) reads the FILLED struct once the merge catches
    /// up, not the nil-metadata one `load()`'s phase-one publish handed to
    /// `selectedItems` originally.
    private func publishMergedMetadata(needsResort: Bool) {
        if needsResort {
            displayedAll = Self.sortedForDisplay(displayedAll, key: sortKey, ascending: sortAscending)
            mergePathIndex = Self.pathIndex(for: displayedAll)
        }
        let selectedPaths = Set(selectedItems.map(\.path))
        applySearch()
        selectedItems = items.filter { selectedPaths.contains($0.path) }
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
    ///
    /// Wired only to the remote pane today (`ContentView+Detail.swift`'s
    /// auto-refresh timer) — never to the local one, which is what lets
    /// this method call `fs.list(path:)` directly rather than through
    /// `load()`'s own phase-two merge. If it were ever wired to the local
    /// pane, this WOULD be a regression: `fs.list` alone only ever returns
    /// phase one (every metadata field nil), so `displayItems(from:)` below
    /// would silently overwrite whatever `size`/`modifiedAt`/`owner`/`group`
    /// a previous merge had already filled in, with no second phase of its
    /// own to fill them back in afterwards.
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
        // `.type`'s label goes through `CoreL10n` (`FileTypeLabel.sortKey`),
        // and `sorted(by:)` calls its comparator O(n log n) times, each
        // touching two items — computing the label INSIDE the comparator
        // (as before) re-derives the same item's label on every comparison
        // it takes part in. Computed once per item here instead, keyed by
        // `path` (== `RemoteFileItem.id`, unique within one directory
        // listing), and looked up rather than re-resolved below. Empty, at
        // no cost, for every other key. The order this produces is
        // unchanged: label, then the same name tiebreak.
        let typeLabels: [String: String] =
            key == .type
            ? Dictionary(
                uniqueKeysWithValues: items.map { ($0.path, FileTypeLabel.sortKey(for: $0)) })
            : [:]
        return items.sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            // The PRIMARY key follows `ascending`; the name tiebreaker does
            // NOT (M11l/T1 review): equal-size or equal-date rows always read
            // A→Z, even in a descending sort, matching the Finder. Applying
            // the direction flip to the whole comparison (tiebreaker included)
            // would sort those Z→A, which reads as inconsistent.
            let primary = primaryOrder(a, b, key: key, typeLabels: typeLabels)
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
    /// missing-value rule. `typeLabels` is `sortedForDisplay`'s once-per-item
    /// cache for `.type`; every other key ignores it.
    private static func primaryOrder(
        _ a: RemoteFileItem, _ b: RemoteFileItem, key: FileSortKey,
        typeLabels: [String: String] = [:]
    ) -> ComparisonResult {
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
            return compareTypeLabel(a, b, labels: typeLabels)
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

    /// `.type`'s ordering: `FileTypeLabel.sortKey`, `localizedCaseInsensitiveCompare`d
    /// — every row has a label (there's no "missing" case the way
    /// size/date/owner have), so there's no nil-identity rule to state here.
    /// `labels` is `sortedForDisplay`'s once-per-item cache, keyed by
    /// `path`; a miss (should not happen — every item sorted was in the
    /// array the cache was built from) falls back to resolving it here
    /// rather than crashing.
    private static func compareTypeLabel(
        _ a: RemoteFileItem, _ b: RemoteFileItem, labels: [String: String]
    ) -> ComparisonResult {
        let labelA = labels[a.path] ?? FileTypeLabel.sortKey(for: a)
        let labelB = labels[b.path] ?? FileTypeLabel.sortKey(for: b)
        return labelA.localizedCaseInsensitiveCompare(labelB)
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
        switch await probeExistence(at: path) {
        case .exists:
            let message = Self.message(
                for: RemoteFSError.protocolError(reason: "destination already exists: \(path)"),
                path: path)
            auditSink?(AuditEvent(kind: .newFolder, detail: detail, isError: true, errorMessage: message))
            return message
        case .absent, .unverifiable:
            // Unlike `createFile` below, an UNVERIFIABLE probe still proceeds
            // here (M18a final review, Important-1): `createDirectory` is
            // idempotent by contract and writes at most a zero-byte marker.
            // On `LocalFileSystem`/`CitadelFileSystem` that marker IS the
            // directory itself, so there is nothing to destroy. On S3
            // (`S3FileSystem.createDirectory`) the "marker" is an
            // unconditional `PUT <key>/` with an empty body — harmless
            // against another directory marker, but it silently replaces any
            // object that already happens to live under that exact
            // trailing-slash key. Proceeding anyway keeps this path's
            // user-visible messages exactly as they were (a permission
            // problem surfaces as `createDirectory`'s own error below).
            break
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

    /// Outcome of the pre-create existence probe shared by `createFolder`
    /// and `createFile` (M18a final review, Important-1). The three cases
    /// exist because "`stat` threw" is NOT one verdict: only
    /// `RemoteFSError.notFound` means "there is definitely nothing here",
    /// and only that verdict may let a create proceed blindly.
    private enum ExistenceProbe {
        /// `stat` returned an entry — something already occupies the path.
        case exists
        /// `stat` reported a definite "does not exist".
        case absent
        /// `stat` failed for any other reason (permission denied, a protocol
        /// error, a dropped connection). Existence is UNKNOWN — the path may
        /// well hold a file full of data.
        case unverifiable(Error)
    }

    /// `stat`s `path` and classifies the outcome. All three backends report a
    /// missing path as `RemoteFSError.notFound`: `LocalFileSystem.stat`
    /// throws it directly, `CitadelFileSystem.stat` maps SFTP's
    /// `SSH_FX_NO_SUCH_FILE` to it via `mapSFTPError`, and
    /// `S3FileSystem.stat` throws it when its `ListObjectsV2` pages contain
    /// no matching key. Everything else — SFTP's `SSH_FX_PERMISSION_DENIED`,
    /// an S3 `ListObjectsV2` 403 from a bucket that grants `s3:PutObject`
    /// but not `s3:ListBucket` (which maps to `.authenticationFailed`, not
    /// `.notFound`), a torn connection — is `.unverifiable`.
    private func probeExistence(at path: String) async -> ExistenceProbe {
        do {
            _ = try await fs.stat(path: path)
            return .exists
        } catch RemoteFSError.notFound {
            return .absent
        } catch {
            return .unverifiable(error)
        }
    }

    /// Creates an empty file in the current directory. Same collision probe
    /// and error contract as `createFolder(named:)` — see its doc comment
    /// for the rationale of probing via `stat` instead of the display-
    /// filtered `items` list. Like it, this does NOT refresh the listing;
    /// callers use `refreshAndSelect(path:)` afterwards (M18a).
    ///
    /// Unlike `createFolder`, an `.unverifiable` probe is a HARD STOP here
    /// (M18a final review, Important-1): the create below is a
    /// `.overwrite` write, i.e. a truncation, so treating "I could not tell"
    /// as "nothing is there" would silently blank an existing file whenever
    /// `stat` fails for a reason other than "not found". The failure is
    /// surfaced as an error message — the sheet stays open — and nothing is
    /// written.
    public func createFile(named name: String) async -> String? {
        let path = RemotePath.join(currentPath, name)
        let detail = "create \(path)"
        switch await probeExistence(at: path) {
        case .exists:
            let message = Self.message(
                for: RemoteFSError.protocolError(reason: "destination already exists: \(path)"),
                path: path)
            auditSink?(AuditEvent(kind: .newFile, detail: detail, isError: true, errorMessage: message))
            return message
        case .unverifiable(let error):
            let message = Self.message(for: error, path: path)
            auditSink?(AuditEvent(kind: .newFile, detail: detail, isError: true, errorMessage: message))
            return message
        case .absent:
            break
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
        // Superseded (M18a final review, Important-2): with `load()`'s
        // late-writer guard in place, a navigation whose `load()` lost the
        // race no longer owns `state` — reading it below would describe
        // SOMEONE ELSE's navigation. Acting on that verdict would roll
        // `currentPath`/`displayedAll` back to this navigation's snapshot,
        // silently undoing the winner, and hand its failure message back to
        // this caller as if it were this navigation's own. A superseded
        // navigation claims no verdict and touches nothing.
        guard currentPath == normalized else { return nil }
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
            // A captured `.loading` must NEVER be restored (M18a final
            // review, Important-2): `previousState` is sampled after the
            // `stat` above, by which time a detached refresh (the `Task` the
            // App fires after create/rename) may already have set
            // `.loading`. That refresh is gone by the time we get here — it
            // either finished or lost `load()`'s late-writer guard — so
            // restoring `.loading` would strand the pane with a spinner over
            // a correct listing and nothing in flight to clear it, with the
            // table's `.allowsHitTesting(state == .loaded)` and the disabled
            // Refresh/Go-Up buttons leaving no way out. The rollback below
            // re-derives the full listing from `previousDisplayedAll`, so
            // `.loaded` is the truthful state; a captured `.failed` still
            // restores as-is (the pane WAS showing a failure before).
            state = previousState == .loading ? .loaded : previousState
            selectedItems = previousSelection
            applySearch()
            return message
        }
        if directoryChanging {
            clearSearch()
        }
        return nil
    }

    // MARK: - Checksums (file checksums, Task 4)

    /// The digest of one file, on request — never as a side effect of a
    /// transfer, and never by downloading anything (the maintainer ruled
    /// that out on 2026-08-27, fallbacks included).
    ///
    /// The capability is reached the way every optional backend capability
    /// in this project is reached: an `as?` on the file system. A backend
    /// that does not conform, and a backend that conforms and answers that
    /// it has nothing, come out of here as the SAME statement — because
    /// they are the same fact for the person looking at the screen, and
    /// neither is an error.
    ///
    /// `algorithm` is passed on untouched. S3 answers a SHA-256 request
    /// with the ETag's MD5, and that substitution belongs to S3, which
    /// labels it: the returned `FileChecksum` names its own algorithm and
    /// its own origin, so nothing here has to second-guess the request.
    ///
    /// Not audited, unlike `rename`/`createFolder`/`createFile`/`delete`
    /// above: those four change the far side, and the audit log is a record
    /// of changes. Asking for a digest changes nothing.
    public func checksum(
        of item: RemoteFileItem, algorithm: ChecksumAlgorithm
    ) async -> ChecksumRequestResult {
        guard let provider = fs as? any RemoteChecksumProvider else {
            return .unavailableOnThisConnection
        }
        do {
            switch try await provider.remoteChecksum(forFileAt: item.path, algorithm: algorithm) {
            case .checksum(let value):
                return .checksum(value)
            case .unavailableOnThisConnection:
                return .unavailableOnThisConnection
            }
        } catch {
            return .failed(Self.message(for: error, path: item.path))
        }
    }

    static func message(for error: Error, path: String) -> String {
        switch error {
        case RemoteFSError.notFound:
            return String(format: CoreL10n.string("core.browse.notFound %@"), path)
        case RemoteFSError.permissionDenied:
            return String(format: CoreL10n.string("core.error.permissionDenied %@"), path)
        // `.authenticationFailed` mid-browse-session (M18a final review,
        // Minor B) is precisely the S3-403 case documented on
        // `S3FileSystem.mapErrorStatus`: S3 collapses "bad credentials" and
        // "credentials valid but the policy forbids this" into the same
        // HTTP status, so from a browse action's point of view it reads
        // exactly like `.permissionDenied` -- reusing that message avoids
        // both a raw `default` dump AND a new catalog key. Distinct from
        // `.jumpAuthenticationFailed`, which stays in `default` here: it is
        // a connect-time-only case (`ConnectionViewModel` maps it to a
        // dedicated, form-highlighting message) that a browse action never
        // throws.
        case RemoteFSError.authenticationFailed:
            return String(format: CoreL10n.string("core.error.permissionDenied %@"), path)
        // A bucket is not a folder (2026-09-02): the one action the design
        // offers on a bucket row is OPEN, and `S3FileSystem` refuses the
        // rest itself. Its own case, so this is a written sentence rather
        // than the `default:` dump of an operation name and a path.
        case RemoteFSError.bucketLevelRefused(let operation, _):
            return CoreL10n.string(operation.refusalMessageKey)
        // The second arm the same lesson asks for: a new `RemoteFSError`
        // case has TWO dumping `default:`s to close, in two view models
        // both called `message(for:)`.
        case RemoteFSError.crossBucketRenameRefused:
            return CoreL10n.string("core.connect.s3CrossBucketRename")
        // `.bucketListForbidden` is NOT connect-time only (Task 3 review,
        // M-3): `listBuckets` runs again on every listing of `/` and on a
        // `stat` of a bucket, so a policy revoked mid-session lands here.
        // Without this arm it printed `core.error.unexpected
        // bucketListForbidden`. `.bucketListEmpty` needs no arm — `connect`
        // is its only thrower, and a later empty account is an empty
        // browser, not an error.
        case RemoteFSError.bucketListForbidden:
            return CoreL10n.string("core.connect.s3BucketListForbidden")
        // `.protocolError`/`.connectionFailed` (fix round 1, Critical): the
        // associated `reason` is dropped, unread, on purpose — it is where
        // `S3FileSystem`/`WebDAVFileSystem` embed the endpoint the user
        // typed, a field that takes `scheme://KEY:SECRET@host` as ordinary
        // input, and this method's return value is written both to the
        // on-screen banner and (`RemoteBrowserViewModel.load()`'s catch)
        // to the diagnostic log. `DialSupport.reason(for: error)` maps the
        // SAME two cases to a fixed, credential-free English sentence — the
        // same mapper the connect path and the diagnostics report already
        // trust with exactly this error, so the browse banner does not get
        // a second, less-audited path to the same information.
        case RemoteFSError.protocolError:
            return String(
                format: CoreL10n.string("core.browse.protocolError %@"), DialSupport.reason(for: error))
        case RemoteFSError.connectionFailed:
            return String(
                format: CoreL10n.string("core.error.connectionLost %@"), DialSupport.reason(for: error))
        default:
            return String(format: CoreL10n.string("core.error.unexpected %@"), String(describing: error))
        }
    }
}
