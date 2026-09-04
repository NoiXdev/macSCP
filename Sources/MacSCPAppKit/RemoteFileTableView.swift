import AppKit
import SwiftUI
import macSCPCore

/// AppKit `NSTableView` wrapped as a SwiftUI view. Spec requirement: plain
/// SwiftUI lists collapse in performance for directories with thousands of
/// entries.
struct RemoteFileTableView: NSViewRepresentable {
    let items: [RemoteFileItem]
    let selectedPaths: Set<String>
    let onOpen: (RemoteFileItem) -> Void
    let onSelect: ([RemoteFileItem]) -> Void
    /// Double-click on a plain FILE row (kind == .file). Directories keep
    /// going through `onOpen` (cd); symlinks/other are unchanged (no-op).
    /// Optional because the local pane doesn't wire it (M5e/T4).
    var onOpenFile: ((RemoteFileItem) -> Void)? = nil
    /// Double-click on a SYMLINK row (kind == .symlink; M11h/T1) — the item's
    /// own path (not a resolved target Core never computes) is handed back
    /// so the caller can attempt `navigate(to:)`, the same route the path
    /// field's Enter key already uses. `.other` stays a no-op; unlike
    /// `onOpenFile` this is wired for BOTH panes, since `navigate(to:)` is a
    /// plain `RemoteBrowserViewModel` operation with no local/remote split.
    var onOpenSymlink: ((RemoteFileItem) -> Void)? = nil
    var pasteboardWriter: ((RemoteFileItem) -> NSPasteboardWriting?)? = nil
    /// Which pane this table belongs to (M7b) — drives the context menu's
    /// entries (the editor entry is remote-only). Explicit rather than
    /// inferred from `onOpenFile != nil`, so the side is self-documenting
    /// at every call site instead of an implicit side effect of the wiring.
    let side: BrowserPaneSide
    var onMenuAction: ((BrowserMenuEntry, [RemoteFileItem]) -> Void)? = nil
    /// "Go up one directory" (M11j/T2) — driven by the ⌘↑ keyboard shortcut,
    /// wired to the SAME `viewModel.goUp()` call the toolbar's up-arrow
    /// button already makes (`BrowserPane`). `nil` by default like the other
    /// optional closures above, though every call site wires it.
    var onGoUp: (() -> Void)? = nil
    /// ⌘F (M11k/T2) — opens THIS pane's own search bar and moves focus into
    /// its field. A pure UI signal with no dependency on the current
    /// selection (unlike every other keyboard command below), so it is
    /// threaded exactly like `onGoUp`/`onOpenSymlink` rather than going
    /// through `BrowserKeyCommand.resolve`/`dispatch(key:selection:)` — see
    /// `KeyboardDrivenTableView.performKeyEquivalent`'s dedicated branch.
    var onOpenSearch: (() -> Void)? = nil
    /// Bumped by `BrowserPane` whenever the table should reclaim first
    /// responder (M11k/T2) — e.g. right after Esc closes the search bar and
    /// focus must return to the file list. A plain counter rather than a
    /// `Binding<Bool>`: `updateNSView` diffs it against the coordinator's
    /// last-seen value (see `Coordinator.lastFocusRequestToken`), the same
    /// discipline `needsReload` already uses for `items`, so an unrelated
    /// SwiftUI re-render never steals focus away from an open search field.
    var focusRequestToken: Int = 0
    /// Cross-session transfer targets (M8b/T4) — evaluated fresh on EVERY
    /// `menuNeedsUpdate` call, not cached here, so a menu opened later in the
    /// session always shows the current set of other tabs and their current
    /// remote directories (menu build freezes the path into `CrossSessionTarget`
    /// at that moment — Spec §5.3). `nil` (the local pane's default before
    /// `ContentView` wires it) yields the pre-M8b flat "Transfer" entry.
    var crossSessionTargets: (() -> [CrossSessionTarget])? = nil
    /// Protocol-contributed file actions for the SELECTED item's backend
    /// (M14/T5) — e.g. S3's "Share Link…". Evaluated fresh on every
    /// `menuNeedsUpdate` call, the same discipline as `crossSessionTargets`
    /// above, so a later backend/settings change is always reflected in the
    /// next menu the user opens. `nil` (the default, and what the LOCAL pane
    /// always passes) yields the pre-M14 entry list — a local file never
    /// shows a backend action, since the local file system never contributes
    /// any.
    var fileActions: (() -> [FileActionContribution])? = nil
    /// Whether this pane's backend can answer the checksum question — read
    /// from the capability on the remote side and from the local file
    /// system's own conformance on the local one (see
    /// `ChecksumAvailability`). Forwarded verbatim to the menu model, which
    /// leaves the entry OUT where this is `false` rather than adding a
    /// disabled one.
    var supportsChecksum: Bool = false
    /// Whether this pane's backend has a permission model the info sheet's
    /// editor speaks (see `PermissionsAvailability`). Read here for one
    /// thing only: the TITLE of the entry that opens that sheet — "Info &
    /// Permissions" where there is an editor, "Info" where the sheet will
    /// say there is none (`PermissionsPresentation.infoMenuTitle`). The
    /// entry itself is offered either way.
    var supportsPermissions: Bool = false
    /// Which columns to build, in `FileColumn.allCases` order (M11m/T2) —
    /// mirrors `SettingsStore.visibleColumns`. Defaults to the pre-M11m
    /// fixed three (`name`/`size`/`modified`) so any call site that doesn't
    /// thread the setting through yet keeps today's exact layout.
    var visibleColumns: Set<FileColumn> = Set(FileColumn.allCases.filter(\.defaultVisible))
    /// What this pane has already been asked to compute (2026-09-02) — the
    /// only source the `checksum` column reads, and a plain value, so the
    /// table can neither start a request nor learn of one it was not told
    /// about. Threaded in exactly like `visibleColumns` above: the pane owns
    /// it, this view renders it. The empty default is the correct one for
    /// every call site: a table nobody has asked anything of shows an empty
    /// column.
    var checksumLedger: ChecksumLedger = ChecksumLedger()
    /// Which digest the `checksum` column shows, and names in its header —
    /// mirrors `SettingsStore.checksumAlgorithm`. A value recorded under
    /// another algorithm is not shown under this one (the ledger keys on it),
    /// so switching the setting empties the column until the user asks again.
    var checksumAlgorithm: ChecksumAlgorithm = .preferred
    /// This pane's current sort column/direction (M11l/T2) — mirrors
    /// `RemoteBrowserViewModel.sortKey`/`sortAscending`. Threaded in from the
    /// VM rather than read off `NSTableView.sortDescriptors` because Core
    /// (`sortedForDisplay`) is the sole sort authority; the table's own
    /// `sortDescriptors` exist only to detect header clicks and drive the
    /// header indicator, never to reorder rows (see `onSortChange` below).
    /// Defaults match the VM's own defaults (`.name` ascending).
    var sortKey: FileSortKey = .name
    var sortAscending: Bool = true
    /// Fired when a header click changes the active column or flips its
    /// direction (M11l/T2). The caller is expected to set
    /// `viewModel.sortKey`/`sortAscending` here, exactly like `onSelect`
    /// sets `viewModel.selectedItems` — the reordered `items` then comes
    /// back through the existing reload/reconcile path in `updateNSView`,
    /// never sorted by AppKit itself.
    var onSortChange: ((FileSortKey, Bool) -> Void)? = nil
    /// What this pane is looking at, for the bucket-list action gate
    /// (2026-09-02) — forwarded verbatim to `BrowserContextMenu.entries`
    /// and `BrowserKeyCommand.resolve`, which are the one predicate the menu
    /// and the keyboard already shared. `.ordinary` (the default, and what
    /// every pane but an S3 bucket-list one is) yields exactly the menu and
    /// the key handling this view had before.
    var scope: BrowserScope = .ordinary
    /// The OTHER pane of this window — where "Transfer ▸ To the other pane"
    /// and the Space key would send (review C-1). A CLOSURE, not a value, so
    /// it is read fresh at each `menuNeedsUpdate`/key press, the same
    /// discipline `crossSessionTargets` and `fileActions` above already use:
    /// the other pane's current directory changes without this view being
    /// re-created. `nil` yields `.ordinary`, which is what every pane whose
    /// counterpart is a local pane or a non-bucket-list remote one is.
    var destinationScope: (() -> BrowserScope)? = nil

    func makeCoordinator() -> Coordinator {
        let coordinator = Coordinator(onOpen: onOpen, onSelect: onSelect, side: side)
        coordinator.onOpenFile = onOpenFile
        coordinator.onOpenSymlink = onOpenSymlink
        coordinator.pasteboardWriter = pasteboardWriter
        coordinator.onMenuAction = onMenuAction
        coordinator.onGoUp = onGoUp
        coordinator.onOpenSearch = onOpenSearch
        coordinator.crossSessionTargets = crossSessionTargets
        coordinator.fileActions = fileActions
        coordinator.supportsChecksum = supportsChecksum
        coordinator.supportsPermissions = supportsPermissions
        coordinator.checksumLedger = checksumLedger
        coordinator.checksumAlgorithm = checksumAlgorithm
        coordinator.onSortChange = onSortChange
        coordinator.scope = scope
        coordinator.destinationScope = destinationScope
        return coordinator
    }

    func makeNSView(context: Context) -> NSScrollView {
        let table = KeyboardDrivenTableView()
        table.commandCoordinator = context.coordinator
        table.style = .plain
        table.usesAlternatingRowBackgroundColors = false
        table.allowsMultipleSelection = true
        table.rowHeight = 24
        table.intercellSpacing = NSSize(width: 0, height: 0)
        // Mockup row separators: hairline at 45% between rows.
        table.gridStyleMask = .solidHorizontalGridLineMask
        table.gridColor = DesignTokens.hairlineFaintNS
        table.headerView = NSTableHeaderView(
            frame: NSRect(x: 0, y: 0, width: 0, height: 22))

        Self.buildColumns(
            visible: visibleColumns, checksumAlgorithm: checksumAlgorithm, in: table)
        context.coordinator.lastVisibleColumns = visibleColumns
        context.coordinator.lastChecksumAlgorithm = checksumAlgorithm

        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        table.target = context.coordinator
        table.doubleAction = #selector(Coordinator.doubleClicked(_:))
        // Allow dragging out of the app (e.g. the Finder as a target).
        table.setDraggingSourceOperationMask(.copy, forLocal: false)
        // Context menu (M7b): built lazily per click in menuNeedsUpdate.
        table.menu = NSMenu()
        table.menu?.delegate = context.coordinator
        context.coordinator.table = table

        // Initial sort state (M11l/T2): mirrors the VM default (`.name`
        // ascending) so the header indicator starts on the Name column,
        // truthfully reflecting the order `items` is already in. This ALSO
        // seeds `lastSyncedSort*` so the very first `updateNSView` call
        // (which SwiftUI always makes right after `makeNSView`, with the
        // same `sortKey`/`sortAscending`) is a no-op rather than redundantly
        // re-touching `table.sortDescriptors`.
        table.sortDescriptors = [NSSortDescriptor(key: sortKey.columnIdentifier, ascending: sortAscending)]
        context.coordinator.updateSortIndicators(activeKey: sortKey, ascending: sortAscending)
        context.coordinator.lastSyncedSortKey = sortKey
        context.coordinator.lastSyncedSortAscending = sortAscending

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        return scroll
    }

    /// Whether the table's backing data actually changed and therefore needs
    /// a `reloadData()` — plain SwiftUI re-renders (e.g. an unrelated
    /// `@Observable` write triggering `updateNSView`) must NOT reload the
    /// table, since `reloadData()` unconditionally clears the AppKit
    /// selection. Pulled out as a static helper so it's unit-testable
    /// without an `NSTableView`.
    static func needsReload(old: [RemoteFileItem], new: [RemoteFileItem]) -> Bool {
        old != new
    }

    /// What one cell of `column` says about `item`.
    ///
    /// A `switch` over `FileColumn` and not over the identifier STRING
    /// (2026-09-02): the string switch this replaces needed a `default`, so
    /// a new column could be added to the enum, built into the table, given
    /// a header — and render blank forever, with nothing red. The
    /// exhaustiveness check now refuses to compile that, which is the
    /// boundary a source-scanning guard was standing in for. (It was
    /// standing badly: a scan of this file for the column's identifier was
    /// satisfied by the STYLING switch below, whose `default` swallows most
    /// columns, so the case it was watching could be deleted from here and
    /// the scan stayed green. Measured while writing this.)
    ///
    /// Pure and static so the whole mapping is decidable in a test without
    /// an `NSTableView`, the same reason `needsReload` is.
    static func cellText(
        for column: FileColumn, item: RemoteFileItem, ledger: ChecksumLedger,
        algorithm: ChecksumAlgorithm
    ) -> String {
        switch column {
        case .name: return FileListFormatter.displayName(for: item)
        case .size: return FileListFormatter.sizeString(for: item)
        case .modified: return FileListFormatter.dateString(for: item)
        // M11m/T2: `permissions`/`owner`/`group` reuse the Core formatters
        // (T1) and substitute the localized "—" placeholder for `nil`.
        // `type` ALSO reuses a Core formatter now (Browser Type Column,
        // 2026-09-04): `FileTypeLabel.label(for:)` already returns
        // localized, catalogue-keyed text (an `isBucket`/kind word or the
        // name's extension, through `CoreL10n`) — unlike the other Core
        // formatters here, which return raw values the App localizes
        // itself. An App-layer `typeText(for:)` used to translate
        // `item.kind` alone into this cell's text; it is deleted with this
        // change, since it could not see `isBucket` and rendered coarser
        // text than the column now sorts by (Task 1's finding).
        case .permissions:
            return FileColumnFormatter.permissionsText(for: item) ?? emptyCellPlaceholder
        case .owner:
            return FileColumnFormatter.ownerText(for: item) ?? emptyCellPlaceholder
        case .group:
            return FileColumnFormatter.groupText(for: item) ?? emptyCellPlaceholder
        case .type: return FileTypeLabel.label(for: item)
        // The one column that shows nothing rather than a placeholder when
        // it has nothing (2026-09-02): "—" would say the listing did not
        // carry the value, and there is no listing that carries this one.
        // An empty cell says what is true — nobody has asked about this
        // file.
        case .checksum:
            return checksumCellText(for: item, in: ledger, algorithm: algorithm)
        }
    }

    /// What one cell of `column` says when the pointer rests on it, or
    /// `nil` for no tooltip at all.
    ///
    /// Exhaustive over `FileColumn` for the same reason `cellText` is, and
    /// pulled out of the styling switch so the recycling rule — a reused
    /// cell must be told its tooltip on EVERY pass, `nil` included — is
    /// stated once instead of once per branch. Two columns have one: the
    /// name cell says when a row is a symlink or a bucket (Browser Type
    /// Column, 2026-09-04 — `isBucket` checked first, same precedence
    /// `FileTypeLabel` uses), and a digest carries its whole value because
    /// the column truncates it in the middle.
    static func cellToolTip(for column: FileColumn, item: RemoteFileItem, text: String)
        -> String? {
        switch column {
        case .name:
            if item.isBucket { return bucketDescription }
            return item.kind == .symlink ? symlinkDescription : nil
        case .checksum: return text.isEmpty ? nil : text
        case .size, .modified, .permissions, .owner, .group, .type: return nil
        }
    }

    /// The word for a symlink, shown both as the marker's accessibility
    /// description and as the name cell's tooltip — one lookup, so the two
    /// cannot come apart.
    static var symlinkDescription: String {
        L10n.string("filetable.symlinkTooltip", "Symbolic link")
    }

    /// The word for an S3 bucket row (Browser Type Column, 2026-09-04),
    /// shown both as the marker's accessibility description and as the
    /// name cell's tooltip — same pairing as `symlinkDescription`, one
    /// lookup so the two cannot come apart.
    static var bucketDescription: String {
        L10n.string("filetable.bucketTooltip", "Bucket")
    }

    /// Backing storage for the two kind-marker glyphs `Coordinator
    /// .tableView(_:viewFor:row:)` fills in and reads (Task 2 review, minor
    /// 7): that method used to call `NSImage(systemSymbolName
    /// :accessibilityDescription:)` itself on every cell it handed back, so
    /// scrolling past the same rows repeatedly kept allocating equivalent
    /// images nobody needed a fresh copy of. Filled once, on the first row
    /// that needs each one, and reused after — a plain cache rather than a
    /// `static let`, because the `NSImage(systemSymbolName:` calls that fill
    /// it have to stay textually where they always were, right beside
    /// `cell.toolTip = …`: `IconTooltipLintTests`' proximity-window scan
    /// only credits an icon with a hover hint within `hintWindow` (12) lines
    /// of where the icon ITSELF is constructed in the source, and moving the
    /// construction call up here — over 500 lines from that `toolTip =`
    /// line — would strand `archivebox`/`arrow.up.forward` outside every
    /// hint the table has (measured by running that suite against this
    /// exact change: 2 issues, "has no hover hint", before this cache
    /// design replaced it). `@MainActor` because AppKit's table-view
    /// delegate/data-source callbacks that fill and read it always run on
    /// the main actor. Sharing one `NSImage` instance across every row that
    /// shows it is safe regardless of where it is built: `NSImageView.image`
    /// is a reference the view only DISPLAYS, and nothing in this file (or
    /// anywhere else that reads an `NSImageView`) ever mutates the `NSImage`
    /// behind it — each row just re-points `imageView.image` at the same
    /// instance.
    @MainActor private static var cachedBucketMarkerImage: NSImage?
    @MainActor private static var cachedSymlinkMarkerImage: NSImage?

    /// Whether a change in the inputs `buildColumns` reads means the table's
    /// columns have to be torn down and built again.
    ///
    /// A rebuild is not free: it discards every width the user dragged. A
    /// changed column SET is worth that (the user just changed the columns).
    /// A changed algorithm is worth it only while the checksum column is
    /// actually shown — it is the one column whose header names the
    /// algorithm, and with it hidden a rebuild resets everyone's widths for
    /// a header nobody can see (review I3).
    static func columnsNeedRebuild(
        lastVisible: Set<FileColumn>?, visible: Set<FileColumn>,
        lastAlgorithm: ChecksumAlgorithm?, algorithm: ChecksumAlgorithm
    ) -> Bool {
        if lastVisible != visible { return true }
        return visible.contains(.checksum) && lastAlgorithm != algorithm
    }

    /// Localized placeholder for a `nil` permissions/owner/group value
    /// (M11m/T2) — `RemoteFileItem.owner`/`.group` are legitimately `nil`
    /// (per the M11m data-source rules: no `longname`, no numeric fallback
    /// either), and a single-`stat` lookup never carries `owner`/`group` at
    /// all (only a directory listing does).
    static var emptyCellPlaceholder: String {
        L10n.string("filetable.cell.placeholder", "—")
    }

    /// The `checksum` column's cell text (2026-09-02): the hex the user
    /// already asked for, or the empty string.
    ///
    /// A lookup and nothing else — the Core formatter it defers to takes the
    /// ledger by value and has no way to request anything, so drawing,
    /// scrolling or switching on this column cannot cause work on the far
    /// side. Pulled out as a static helper for the same reason `needsReload`
    /// is: it is the whole behaviour of the column, and a test can read it
    /// without an `NSTableView`.
    static func checksumCellText(
        for item: RemoteFileItem, in ledger: ChecksumLedger, algorithm: ChecksumAlgorithm
    ) -> String {
        FileColumnFormatter.checksumText(for: item, in: ledger, algorithm: algorithm) ?? ""
    }

    /// Per-column width and default click-to-sort direction (M11m/T2),
    /// keyed by `FileColumn` — display order itself always comes from
    /// `FileColumn.allCases`, never from this dictionary's own iteration
    /// order. `size` keeps its pre-M11m default (largest-first, i.e.
    /// descending) from M11l. `permissions` is given the SAME
    /// descending default rather than the ascending one `owner`/`group`/
    /// `type`/`modified` use — the design doc left this one unspecified
    /// ("a sensible default — pick and note it"): descending puts the
    /// most-permissive files first, mirroring "biggest first" for size, a
    /// more useful first click than "least permissive first" would be.
    ///
    /// `defaultAscending` is OPTIONAL, and `nil` means the column carries no
    /// sort-descriptor prototype at all — an unclickable header, which is
    /// what `checksum` needs (2026-09-02). Sorting by a column that is empty
    /// for every row nobody asked about would order the listing by what the
    /// user happened to ask for, and `FileSortKey` has no case for it either
    /// (Core is the only sort authority; a header click it cannot express is
    /// a header click that must not be offered).
    static let columnSpecs: [FileColumn: (width: CGFloat, defaultAscending: Bool?)] = [
        .name: (260, true),
        .size: (90, false),
        .modified: (160, true),
        // 105, not 90 (M11m/T2 review): a full "rwxrwxrwx" at 12.5pt
        // monospaced plus the 2x12pt cell insets needs ~91pt, so 90 would
        // middle-truncate the last bit. Column stays user-resizable.
        .permissions: (105, false),
        .owner: (110, true),
        .group: (110, true),
        .type: (90, true),
        // 300: a full SHA-256 is 64 monospaced digits (~480pt at 12.5pt plus
        // the 2x12pt insets), which would be a wider default column than the
        // file names beside it. So the resting width shows a prefix, the
        // column stays user-resizable like every other, and the cell carries
        // the whole value as its tooltip.
        .checksum: (300, nil),
    ]

    /// Builds `table`'s columns from scratch, in `FileColumn.allCases` order
    /// filtered to `visible` (M11m/T2) — `name` always included regardless
    /// of `visible`, matching `SettingsStore.visibleColumns`'s own
    /// always-includes-`name` guarantee, so this stays correct even if a
    /// caller somehow passes a set missing it. Each column gets its
    /// `PolishedHeaderCell` (localized title) and `sortDescriptorPrototype`
    /// keyed by `FileColumn.rawValue` — the same raw string
    /// `FileSortKey.columnIdentifier` below already produces, so
    /// `sortDescriptorsDidChange` keeps working unmodified for every column,
    /// old or new. Callers are responsible for anything ELSE a rebuild
    /// implies (restoring the sort indicator, reloading data) — this
    /// function only ever adds columns, it never touches selection, sort
    /// state, or existing columns (callers must remove those first).
    private static func buildColumns(
        visible: Set<FileColumn>, checksumAlgorithm: ChecksumAlgorithm, in table: NSTableView
    ) {
        for column in FileColumn.allCases where column == .name || visible.contains(column) {
            guard let spec = columnSpecs[column] else { continue }
            let tableColumn = NSTableColumn(identifier: .init(column.rawValue))
            let header = PolishedHeaderCell(
                textCell: column.localizedHeaderTitle(checksumAlgorithm: checksumAlgorithm))
            tableColumn.headerCell = header
            tableColumn.width = spec.width
            if let ascending = spec.defaultAscending {
                tableColumn.sortDescriptorPrototype = NSSortDescriptor(
                    key: column.rawValue, ascending: ascending)
            }
            table.addTableColumn(tableColumn)
        }
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        let oldItems = context.coordinator.items
        let itemsChanged = Self.needsReload(old: oldItems, new: items)
        context.coordinator.items = items
        context.coordinator.onOpen = onOpen
        context.coordinator.onSelect = onSelect
        context.coordinator.onOpenFile = onOpenFile
        context.coordinator.onOpenSymlink = onOpenSymlink
        context.coordinator.pasteboardWriter = pasteboardWriter
        context.coordinator.onMenuAction = onMenuAction
        context.coordinator.onGoUp = onGoUp
        context.coordinator.onOpenSearch = onOpenSearch
        context.coordinator.crossSessionTargets = crossSessionTargets
        context.coordinator.fileActions = fileActions
        context.coordinator.supportsChecksum = supportsChecksum
        context.coordinator.supportsPermissions = supportsPermissions
        // A newly recorded checksum (or a different algorithm setting)
        // changes the TEXT of rows that are otherwise byte-for-byte the
        // same items, so `needsReload` above cannot see it — diffed here
        // against what the coordinator itself last held, the same
        // discipline every other diff in this function uses.
        //
        // Cost, measured by reading rather than by profiling (review M4): a
        // run over N files reloads the whole listing N times, once per value
        // that lands, plus the selection reconciliation below. It is a full
        // reload because a value can change any visible row's text and the
        // ledger does not say which. Acceptable as it stands — the run's
        // sheet is modal over the table while it happens — and the place to
        // narrow it, if a large batch over a huge directory ever feels slow,
        // is a per-row reload keyed on the item that changed.
        let checksumTextChanged =
            context.coordinator.checksumLedger != checksumLedger
            || context.coordinator.checksumAlgorithm != checksumAlgorithm
        context.coordinator.checksumLedger = checksumLedger
        context.coordinator.checksumAlgorithm = checksumAlgorithm
        context.coordinator.onSortChange = onSortChange
        context.coordinator.scope = scope
        context.coordinator.destinationScope = destinationScope
        guard let table = nsView.documentView as? NSTableView else { return }
        // Column rebuild (M11m/T2): diffed against the last SET the
        // COORDINATOR itself recorded (`lastVisibleColumns`) — the same
        // discipline the sort-state/items/focus-token diffs below already
        // use — so a plain SwiftUI re-render with an unchanged setting never
        // tears down and rebuilds the columns (that would flash the header
        // and briefly show empty cells for no reason). A real change (the
        // user (un)checking a box in Settings) removes every existing
        // column and calls the SAME `buildColumns` helper `makeNSView` uses,
        // then restores the sort indicator (the fresh header cells start
        // with none) and reloads the row data so the newly added/removed
        // columns' cells populate immediately rather than waiting for the
        // next scroll. `reloadData()` clears the AppKit selection like the
        // `itemsChanged` branch below already accounts for — the same
        // selection-reconciliation block further down restores it
        // unconditionally, so no separate restore is needed here.
        //
        // The algorithm setting is part of this diff and not only of the
        // cell text: it is in the checksum column's HEADER, and a header is
        // built here and nowhere else — but only while that column is
        // shown, see `columnsNeedRebuild`.
        let columnsChanged = Self.columnsNeedRebuild(
            lastVisible: context.coordinator.lastVisibleColumns, visible: visibleColumns,
            lastAlgorithm: context.coordinator.lastChecksumAlgorithm,
            algorithm: checksumAlgorithm)
        if columnsChanged {
            context.coordinator.lastVisibleColumns = visibleColumns
            context.coordinator.lastChecksumAlgorithm = checksumAlgorithm
            context.coordinator.suppressSelectionCallback = true
            for column in table.tableColumns {
                table.removeTableColumn(column)
            }
            Self.buildColumns(
                visible: visibleColumns, checksumAlgorithm: checksumAlgorithm, in: table)
            context.coordinator.updateSortIndicators(activeKey: sortKey, ascending: sortAscending)
            table.reloadData()
            context.coordinator.suppressSelectionCallback = false
        }
        // Sort state reconciliation (M11l/T2): diffed against the last value
        // the COORDINATOR itself pushed (not against a locally-cached SwiftUI
        // value), the same discipline `itemsChanged`/`focusRequestToken`
        // already use — a plain re-render with an unchanged sort state must
        // never re-touch `table.sortDescriptors` (that would needlessly
        // re-fire `sortDescriptorsDidChange`). A change here can only come
        // from an EXTERNAL source (not a header click, since a header click
        // already updates `lastSyncedSort*` itself in the delegate method
        // before this ever runs) — e.g. a future reset-to-default action.
        if context.coordinator.lastSyncedSortKey != sortKey
            || context.coordinator.lastSyncedSortAscending != sortAscending {
            context.coordinator.lastSyncedSortKey = sortKey
            context.coordinator.lastSyncedSortAscending = sortAscending
            table.sortDescriptors = [
                NSSortDescriptor(key: sortKey.columnIdentifier, ascending: sortAscending)
            ]
            context.coordinator.updateSortIndicators(activeKey: sortKey, ascending: sortAscending)
        }
        // `!columnsChanged` because that branch has already reloaded — the
        // rows would otherwise be reloaded twice in the one update where a
        // toggle and a fresh checksum arrive together.
        if !columnsChanged && (itemsChanged || checksumTextChanged) {
            // reloadData() clears the selection without a delegate call —
            // the reconciliation below restores it right after.
            context.coordinator.suppressSelectionCallback = true
            table.reloadData()
            context.coordinator.suppressSelectionCallback = false
        }
        // Selection reconciliation runs INDEPENDENTLY of the reload guard
        // (task-3 re-review): a content-identical refresh still clears
        // `selectedItems` in the view model, and without this step the
        // table would keep showing the stale highlight while the toolbar
        // buttons (bound to the model) already disabled themselves. A no-op
        // when desired == actual, so the live cmd-click path is untouched.
        let desired = IndexSet(items.indices.filter { selectedPaths.contains(items[$0].path) })
        if table.selectedRowIndexes != desired {
            context.coordinator.suppressSelectionCallback = true
            if desired.isEmpty {
                table.deselectAll(nil)
            } else {
                table.selectRowIndexes(desired, byExtendingSelection: false)
                // Scrolls the new selection into view (M11k/T2): plain
                // `selectRowIndexes` does not auto-scroll, so a jump-mode
                // match outside the currently visible rows would otherwise
                // become selected without the user ever seeing it move.
                if let firstDesired = desired.first {
                    table.scrollRowToVisible(firstDesired)
                }
            }
            context.coordinator.suppressSelectionCallback = false
        }
        // Reclaims first responder for the table (M11k/T2) — see
        // `focusRequestToken`'s doc comment for why this is diffed rather
        // than acted on unconditionally.
        if context.coordinator.lastFocusRequestToken != focusRequestToken {
            context.coordinator.lastFocusRequestToken = focusRequestToken
            table.window?.makeFirstResponder(table)
        }
    }

    /// `NSTableView` subclass driving Finder-style keyboard shortcuts
    /// (M11j/T2) — see `docs/superpowers/specs/2026-07-30-m11j-browser-keyboard-design.md`.
    /// Split across two overrides because AppKit routes Command-modified key
    /// presses through `performKeyEquivalent(with:)`, NOT `keyDown(with:)` —
    /// the classic trap this design works around.
    private final class KeyboardDrivenTableView: NSTableView {
        weak var commandCoordinator: Coordinator?

        /// The ⌘-combined keys: ⌘↓/⌘O (open), ⌘↑ (go up), ⌘⌫ (delete), ⌘I
        /// (info). Requires Command and NO Shift/Option/Control, so ⌘⇧…
        /// combos (app-menu shortcuts) are never swallowed here. Returns
        /// `true` only when an action was actually produced and dispatched;
        /// otherwise falls through to `super` so menu shortcuts and default
        /// focus handling keep working.
        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            // `performKeyEquivalent(with:)` is broadcast by NSWindow
            // depth-first through the ENTIRE content-view tree, not routed
            // to the first responder like `keyDown` is. With two panes open
            // in one window, both tables would otherwise see the same
            // event; whichever sits first in subview order would act on ITS
            // OWN selection regardless of which pane the user is actually
            // in. Deferring to `super` here when this table isn't first
            // responder lets the event continue down the tree to the table
            // that IS focused. `keyDown` below needs no such guard because
            // it already only ever fires on the first responder.
            guard window?.firstResponder === self else {
                return super.performKeyEquivalent(with: event)
            }
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard modifiers.contains(.command),
                !modifiers.contains(.shift),
                !modifiers.contains(.option),
                !modifiers.contains(.control),
                let coordinator = commandCoordinator
            else {
                return super.performKeyEquivalent(with: event)
            }

            // ⌘F opens THIS pane's own search bar (M11k/T2) — a pure UI
            // action with no dependency on the current selection, unlike
            // every key below, so it bypasses `BrowserKeyCommand.resolve`/
            // `dispatch(key:selection:)` entirely and calls straight into
            // the coordinator's `onOpenSearch` closure, mirroring how
            // `onGoUp`/`onOpenSymlink` are wired elsewhere in this type.
            // Collision check (M11k/T2): ⌘F has no `keyboardShortcut`
            // anywhere else in the app (confirmed via a full-source search)
            // and SwiftUI adds no default "Find" menu item, so it was fully
            // unbound before this.
            if event.charactersIgnoringModifiers?.lowercased() == "f" {
                guard let onOpenSearch = coordinator.onOpenSearch else {
                    return super.performKeyEquivalent(with: event)
                }
                onOpenSearch()
                return true
            }

            let key: BrowserKey?
            switch event.keyCode {
            case 125: key = .commandDown
            case 126: key = .commandUp
            case 51: key = .commandDelete
            default:
                switch event.charactersIgnoringModifiers?.lowercased() {
                case "o": key = .commandO
                case "i": key = .commandI
                default: key = nil
                }
            }

            guard let key, let selection = coordinator.currentSelection(),
                coordinator.dispatch(key: key, selection: selection)
            else {
                return super.performKeyEquivalent(with: event)
            }
            return true
        }

        /// The modifier-less keys: Return (rename), Space (transfer), Esc
        /// (clear selection). Plain Delete/Backspace is intentionally NOT
        /// handled here — only ⌘⌫ deletes, so an unmodified delete key falls
        /// straight through to `super` and does nothing, matching Finder.
        /// Any other unhandled key also falls through so native arrow-key
        /// selection and type-select keep working.
        override func keyDown(with event: NSEvent) {
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard modifiers.isDisjoint(with: [.command, .option, .control, .shift]),
                let coordinator = commandCoordinator
            else {
                super.keyDown(with: event)
                return
            }

            let key: BrowserKey?
            switch event.keyCode {
            case 36, 76: key = .returnKey // Return, numpad Enter
            case 49: key = .space
            case 53: key = .escape
            default: key = nil
            }

            guard let key, let selection = coordinator.currentSelection(),
                coordinator.dispatch(key: key, selection: selection)
            else {
                super.keyDown(with: event)
                return
            }
        }
    }

    /// Main-actor isolated because every way into this object already runs
    /// there: SwiftUI builds it from `makeCoordinator()`, and AppKit invokes
    /// data-source, delegate and menu callbacks on the main thread. Without
    /// it, the helper methods that are not protocol witnesses — `open` and
    /// `updateSortIndicators` among them — stay nonisolated and cannot touch
    /// the `NSTableView` they exist to drive.
    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
        var items: [RemoteFileItem] = []
        var onOpen: (RemoteFileItem) -> Void
        var onSelect: ([RemoteFileItem]) -> Void
        var onOpenFile: ((RemoteFileItem) -> Void)?
        var onOpenSymlink: ((RemoteFileItem) -> Void)?
        var pasteboardWriter: ((RemoteFileItem) -> NSPasteboardWriting?)?
        var onMenuAction: ((BrowserMenuEntry, [RemoteFileItem]) -> Void)?
        var onGoUp: (() -> Void)?
        var onOpenSearch: (() -> Void)?
        var crossSessionTargets: (() -> [CrossSessionTarget])?
        var fileActions: (() -> [FileActionContribution])?
        var supportsChecksum = false
        var supportsPermissions = false
        var onSortChange: ((FileSortKey, Bool) -> Void)?
        /// Refreshed on every `updateNSView`, like `supportsChecksum` and
        /// `crossSessionTargets` above, so a navigation into (or out of) the
        /// bucket list is reflected in the next menu the user opens and in
        /// the next key they press.
        var scope: BrowserScope = .ordinary
        var destinationScope: (() -> BrowserScope)?
        /// The other pane's scope right now — `.ordinary` when no closure was
        /// supplied, which is the answer for every pane whose counterpart
        /// cannot be a bucket list.
        var currentDestinationScope: BrowserScope { destinationScope?() ?? .ordinary }
        let side: BrowserPaneSide
        weak var table: NSTableView?
        var suppressSelectionCallback = false
        /// Last `focusRequestToken` value `updateNSView` acted on (M11k/T2)
        /// — see that property's doc comment on `RemoteFileTableView`.
        var lastFocusRequestToken = 0
        /// Last sort key/direction THIS coordinator itself pushed into
        /// `table.sortDescriptors` and the header indicators (M11l/T2) — see
        /// the diffing comment at its `updateNSView` call site. `nil` only
        /// before `makeNSView` runs its initial sync.
        var lastSyncedSortKey: FileSortKey?
        var lastSyncedSortAscending: Bool?
        /// Last `visibleColumns` set THIS coordinator itself built the
        /// table's columns from (M11m/T2) — see the column-rebuild diffing
        /// comment at its `updateNSView` call site. `nil` only before
        /// `makeNSView` runs its initial build.
        var lastVisibleColumns: Set<FileColumn>?
        /// The algorithm the CURRENT headers were built with (2026-09-02) —
        /// the checksum column's header names it, so a changed setting has
        /// to rebuild the columns and not merely the cells. `nil` only
        /// before `makeNSView` runs its initial build.
        var lastChecksumAlgorithm: ChecksumAlgorithm?
        /// What this pane has already been asked to compute, and under which
        /// algorithm to read it — the `checksum` column's only source. Pushed
        /// in from the view on every update; see those properties there.
        var checksumLedger = ChecksumLedger()
        var checksumAlgorithm: ChecksumAlgorithm = .preferred

        init(
            onOpen: @escaping (RemoteFileItem) -> Void, onSelect: @escaping ([RemoteFileItem]) -> Void,
            side: BrowserPaneSide
        ) {
            self.onOpen = onOpen
            self.onSelect = onSelect
            self.side = side
        }

        func numberOfRows(in tableView: NSTableView) -> Int {
            items.count
        }

        /// Returns the drag pasteboard writer for a row (e.g. a file URL) —
        /// `nil` makes the row non-draggable (e.g. directories).
        func tableView(
            _ tableView: NSTableView,
            pasteboardWriterForRow row: Int
        ) -> NSPasteboardWriting? {
            guard row >= 0, row < items.count else { return nil }
            return pasteboardWriter?(items[row])
        }

        func tableView(
            _ tableView: NSTableView,
            viewFor tableColumn: NSTableColumn?,
            row: Int
        ) -> NSView? {
            guard row < items.count, let columnID = tableColumn?.identifier.rawValue,
                let column = FileColumn(rawValue: columnID)
            else {
                return nil
            }
            let item = items[row]
            let text = RemoteFileTableView.cellText(
                for: column, item: item, ledger: checksumLedger, algorithm: checksumAlgorithm)

            let reuseID = NSUserInterfaceItemIdentifier("cell-\(columnID)")
            let cell: NSTableCellView
            if let reused = tableView.makeView(withIdentifier: reuseID, owner: nil)
                as? NSTableCellView {
                cell = reused
            } else {
                cell = NSTableCellView()
                cell.identifier = reuseID
                let field = NSTextField(labelWithString: "")
                field.lineBreakMode = .byTruncatingMiddle
                field.translatesAutoresizingMaskIntoConstraints = false
                cell.addSubview(field)
                cell.textField = field
                NSLayoutConstraint.activate([
                    field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 12),
                    field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -12),
                    field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                ])
                // Kind marker (M11h/T1; extended for buckets, Browser Type
                // Column 2026-09-04): only the "name" column ever needs it,
                // built once per fresh cell — the `NSImageView` itself,
                // never re-added, never repositioned. It lives IN the
                // existing 12pt left inset rather than pushing `field`
                // further right, so the resting layout (row height, text
                // baseline, 12pt text indent) is byte-for-byte what M5g
                // froze: `field`'s own leading constraint above is
                // untouched. Its IMAGE is no longer fixed at build time —
                // see the block right after this `if`/`else`, which sets it
                // (and the marker's visibility) on every reuse, because
                // which glyph a row gets now varies row to row.
                if column == .name {
                    let marker = NSImageView()
                    marker.translatesAutoresizingMaskIntoConstraints = false
                    marker.contentTintColor = DesignTokens.inkTertiaryNS
                    marker.symbolConfiguration = NSImage.SymbolConfiguration(
                        pointSize: 11, weight: .regular)
                    marker.isHidden = true
                    cell.addSubview(marker)
                    cell.imageView = marker
                    NSLayoutConstraint.activate([
                        marker.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 1),
                        marker.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                    ])
                }
            }
            // Recycling hygiene (M11h/T1, critical; extended for buckets,
            // Browser Type Column 2026-09-04): both the marker's IMAGE and
            // its visibility are set UNCONDITIONALLY on every reuse — a row
            // that scrolls from a bucket to a symlink to a plain file must
            // not keep showing the wrong glyph (or any glyph at all), since
            // `makeView(withIdentifier:)` hands back the exact same
            // `NSTableCellView` instance. `isBucket` is checked first,
            // matching `FileTypeLabel`'s own precedence — a bucket's `kind`
            // is `.directory`, never `.symlink`, so the two branches cannot
            // collide in practice, but the order still documents which one
            // would win. Kept right beside `cell.toolTip` below (rather than
            // in the styling switch further down) so the icon assignment
            // and the hover hint that explains it stay close in the source.
            if column == .name {
                if item.isBucket {
                    RemoteFileTableView.cachedBucketMarkerImage = RemoteFileTableView.cachedBucketMarkerImage
                        ?? NSImage(systemSymbolName: "archivebox", accessibilityDescription: RemoteFileTableView.bucketDescription)
                    cell.imageView?.image = RemoteFileTableView.cachedBucketMarkerImage
                    cell.imageView?.isHidden = false
                } else if item.kind == .symlink {
                    RemoteFileTableView.cachedSymlinkMarkerImage = RemoteFileTableView.cachedSymlinkMarkerImage
                        ?? NSImage(systemSymbolName: "arrow.up.forward", accessibilityDescription: RemoteFileTableView.symlinkDescription)
                    cell.imageView?.image = RemoteFileTableView.cachedSymlinkMarkerImage
                    cell.imageView?.isHidden = false
                } else {
                    cell.imageView?.isHidden = true
                }
            }
            cell.toolTip = RemoteFileTableView.cellToolTip(
                for: column, item: item, text: text)
            cell.textField?.stringValue = text
            // Typed and exhaustive, like `cellText(for:)` above (review I1):
            // this used to switch on the identifier STRING and end in a
            // `default`, so renaming the enum's raw value would have been a
            // compile error in the text mapping and a silent fall-through
            // here — the digest losing its monospacing and, worse, the
            // tooltip that is the only way to read a middle-truncated
            // 64-digit value.
            switch column {
            case .name:
                cell.textField?.font = .systemFont(ofSize: 12.5)
                cell.textField?.textColor = DesignTokens.inkNS
                cell.textField?.alignment = .natural
                // The marker's image and visibility are set above, beside
                // `cell.toolTip` — not here, since they now vary with
                // `isBucket` too and not with the column's TEXT styling.
            case .size:
                cell.textField?.font = .monospacedDigitSystemFont(ofSize: 12.5, weight: .regular)
                cell.textField?.textColor = DesignTokens.inkSecondaryNS
                cell.textField?.alignment = .right
            case .modified:
                cell.textField?.font = .monospacedDigitSystemFont(ofSize: 12.5, weight: .regular)
                cell.textField?.textColor = DesignTokens.inkSecondaryNS
                cell.textField?.alignment = .natural
            // Monospaced like "size" (M11m/T2 brief) so the fixed-width rwx
            // string's columns of letters/dashes stay vertically aligned
            // between rows, even though it is not digits; the digest is
            // monospaced for the same reason and because two hex values are
            // compared by eye, digit under digit.
            case .permissions, .checksum:
                cell.textField?.font = .monospacedDigitSystemFont(ofSize: 12.5, weight: .regular)
                cell.textField?.textColor = DesignTokens.inkSecondaryNS
                cell.textField?.alignment = .natural
            case .owner, .group, .type:
                cell.textField?.font = .systemFont(ofSize: 12.5)
                cell.textField?.textColor = DesignTokens.inkSecondaryNS
                cell.textField?.alignment = .natural
            }
            return cell
        }

        @objc func doubleClicked(_ sender: Any?) {
            guard let row = table?.clickedRow, row >= 0, row < items.count else { return }
            open(items[row])
        }

        /// Kind-based routing for "open" — shared by the double-click handler
        /// above and the ⌘↓/⌘O keyboard action below (M11j/T2) so the
        /// directory/file/symlink branch exists in exactly one place.
        func open(_ item: RemoteFileItem) {
            if item.isDirectory {
                onOpen(item)
            } else if item.kind == .file {
                onOpenFile?(item)
            } else if item.kind == .symlink {
                onOpenSymlink?(item)
            }
            // `.other`: unchanged (no-op).
        }

        // MARK: - Keyboard commands (M11j/T2)

        /// The current selection, read BY VALUE at the moment of the call
        /// (never captured earlier) — the same anti-staleness discipline
        /// `menuNeedsUpdate`/`MenuActionBox` already use for the context
        /// menu. `nil` only when the table itself is gone.
        func currentSelection() -> [RemoteFileItem]? {
            guard let table else { return nil }
            return table.selectedRowIndexes.compactMap { $0 < items.count ? items[$0] : nil }
        }

        /// Resolves `key` against the CURRENT selection (read fresh by the
        /// caller, by value — same discipline as `MenuActionBox` at menu-build
        /// time, against a stale index) and dispatches the resulting action.
        /// Returns whether an action was produced and performed, so the
        /// `NSTableView` subclass knows whether to swallow the event or fall
        /// through to `super` (native type-select / focus handling).
        func dispatch(key: BrowserKey, selection: [RemoteFileItem]) -> Bool {
            guard let action = BrowserKeyCommand.resolve(
                key: key, selection: selection, side: side, scope: scope,
                destination: currentDestinationScope)
            else {
                return false
            }
            perform(action)
            return true
        }

        /// Routes a resolved `BrowserKeyAction` to exactly the same closures
        /// the double-click handler and context menu already use — the
        /// keyboard is a third caller of the same one model, never a second
        /// implementation of any action.
        func perform(_ action: BrowserKeyAction) {
            switch action {
            case .open(let item):
                open(item)
            case .goUp:
                onGoUp?()
            case .rename(let item):
                onMenuAction?(.rename, [item])
            case .info(let item):
                onMenuAction?(.infoAndPermissions, [item])
            case .delete(let selection):
                onMenuAction?(.delete, selection)
            case .transfer(let selection):
                onMenuAction?(.transferToOtherPane, selection)
            case .clearSelection:
                // `deselectAll(nil)` already fires
                // `tableViewSelectionDidChange` -> `onSelect([])` when the
                // selection was non-empty, so no explicit call is needed
                // here.
                table?.deselectAll(nil)
            }
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !suppressSelectionCallback else { return }
            guard let table else { return }
            let rows = table.selectedRowIndexes
            onSelect(rows.compactMap { $0 < items.count ? items[$0] : nil })
        }

        // MARK: - Sort (M11l/T2)

        /// AppKit's native click-to-sort machinery (driven by each column's
        /// `sortDescriptorPrototype`, set in `makeNSView`) still works even
        /// though `PolishedHeaderCell` fully suppresses default header
        /// painting: header-click hit-testing and `sortDescriptors` toggling
        /// happen in `NSTableHeaderView` itself, entirely independent of the
        /// header cell's `draw(withFrame:in:)` override. So this delegate
        /// method fires exactly like it would with a stock header cell — the
        /// custom cell only affects what gets PAINTED (title + our own
        /// indicator triangle, added below), never what gets CLICKED.
        ///
        /// Only `tableView.sortDescriptors.first` is consulted: AppKit always
        /// makes the just-toggled column's descriptor the first element
        /// (prepending it), so the primary key/direction is always there
        /// regardless of how many older descriptors trail behind it — this
        /// view model only ever tracks a single sort key, so anything past
        /// `.first` is irrelevant here.
        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            guard let descriptor = tableView.sortDescriptors.first,
                let key = FileSortKey(columnIdentifier: descriptor.key ?? "")
            else { return }
            lastSyncedSortKey = key
            lastSyncedSortAscending = descriptor.ascending
            updateSortIndicators(activeKey: key, ascending: descriptor.ascending)
            onSortChange?(key, descriptor.ascending)
        }

        /// Updates every column's header cell to show (or hide) the ▲/▼
        /// indicator (M11l/T2) — `PolishedHeaderCell` draws it itself (see
        /// that type's doc comment) since it suppresses AppKit's own
        /// `indicatorImage` painting along with everything else AppKit would
        /// normally paint by default.
        func updateSortIndicators(activeKey: FileSortKey, ascending: Bool) {
            guard let table else { return }
            for column in table.tableColumns {
                guard let cell = column.headerCell as? PolishedHeaderCell else { continue }
                let isActive = FileSortKey(columnIdentifier: column.identifier.rawValue) == activeKey
                cell.sortIndicatorAscending = isActive ? ascending : nil
            }
            table.headerView?.needsDisplay = true
        }

        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            let reuseID = NSUserInterfaceItemIdentifier("polished-row")
            if let reused = tableView.makeView(withIdentifier: reuseID, owner: nil)
                as? PolishedRowView {
                return reused
            }
            let rowView = PolishedRowView()
            rowView.identifier = reuseID
            return rowView
        }

        // MARK: - Context menu (M7b)

        /// Finder behavior: right-click on an unselected row selects it
        /// first (and reports the change); right-click inside the current
        /// selection keeps it; a click below the rows targets the pane
        /// background (empty selection → "New Folder" only).
        func menuNeedsUpdate(_ menu: NSMenu) {
            guard let table else { return }
            let clicked = table.clickedRow
            var selection: [RemoteFileItem] = []
            if clicked >= 0, clicked < items.count {
                if !table.selectedRowIndexes.contains(clicked) {
                    table.selectRowIndexes(IndexSet(integer: clicked), byExtendingSelection: false)
                    onSelect([items[clicked]])
                }
                selection = table.selectedRowIndexes.compactMap {
                    $0 < items.count ? items[$0] : nil
                }
            }
            menu.removeAllItems()
            let entries = BrowserContextMenu.entries(
                for: selection, side: side, crossSessionTargets: crossSessionTargets?() ?? [],
                fileActions: fileActions?() ?? [],
                supportsChecksum: supportsChecksum, scope: scope,
                destination: currentDestinationScope)
            // `.transferToOtherPane` is immediately followed (per the Core
            // model, `BrowserContextMenu.entries`) by zero or more
            // `.transferToSession` entries — those join the SAME "Transfer"
            // submenu rather than becoming a second parent item (M8b/T4
            // requirement 2). Consumed together here; without any cross-
            // session targets this produces the exact same single-item
            // submenu as before M8b (byte-identical flat structure).
            //
            // Since fix round 1 of the bucket-list task the run can also
            // START with a `.transferToSession`: the other pane of THIS
            // window may be unable to receive (a bucket list) while another
            // TAB's remote pane can, so `entries` drops `.transferToOtherPane`
            // and keeps the targets. The submenu is then built without its
            // first item. The order is the Core model's contract, pinned by
            // `crossSessionTargetsSurviveARefusingOtherPaneAndKeepTheirOrder`.
            var index = 0
            while index < entries.count {
                let entry = entries[index]
                let startsATransferRun: Bool
                if case .transferToSession = entry { startsATransferRun = true }
                else { startsATransferRun = entry == .transferToOtherPane }
                if startsATransferRun {
                    let includesOtherPane = entry == .transferToOtherPane
                    var targets: [CrossSessionTarget] = []
                    if includesOtherPane { index += 1 }
                    while index < entries.count, case .transferToSession(let target) = entries[index] {
                        targets.append(target)
                        index += 1
                    }
                    menu.addItem(makeTransferItem(
                        selection: selection, targets: targets,
                        includesOtherPane: includesOtherPane))
                    continue
                }
                if entry == .delete, menu.items.isEmpty == false {
                    menu.addItem(.separator())
                }
                menu.addItem(makeItem(entry, selection: selection))
                index += 1
            }
        }

        /// Builds the single "Transfer" submenu: the existing "to the other
        /// pane" item first, then — only when `targets` is non-empty — a
        /// separator followed by one item per cross-session target, titled
        /// via `menu.transfer.toSession.kind` (target title + backend badge)
        /// with the target's remote path as the item's subtitle (M8b/T4
        /// requirement 2; backend badge added in M16 T4).
        ///
        /// `includesOtherPane` is `false` when the Core model withheld
        /// `.transferToOtherPane` because this window's other pane cannot
        /// receive (fix round 1). The separator goes with it: it exists to
        /// divide that first item from the targets, and with nothing above
        /// it would open the submenu with a rule.
        private func makeTransferItem(
            selection: [RemoteFileItem], targets: [CrossSessionTarget],
            includesOtherPane: Bool = true
        ) -> NSMenuItem {
            let parent = NSMenuItem(
                title: L10n.string("menu.transfer", "Transfer"), action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            if includesOtherPane {
                submenu.addItem(actionItem(
                    title: L10n.string("menu.transfer.otherPane", "To the other pane"),
                    entry: .transferToOtherPane, selection: selection))
            }
            if !targets.isEmpty {
                if includesOtherPane { submenu.addItem(.separator()) }
                for target in targets {
                    let item = actionItem(
                        title: String(
                            format: L10n.string("menu.transfer.toSession.kind", "To “%@” · %@"),
                            target.title, backendBadgeLabel(target.kind)),
                        entry: .transferToSession(target), selection: selection)
                    item.subtitle = target.remotePath
                    submenu.addItem(item)
                }
            }
            parent.submenu = submenu
            return parent
        }

        /// Backend badge label for a cross-session target (M16 T4) — reads
        /// the canonical M12 `BackendDescriptor` source, same as
        /// `SessionSidebar.swift`/`TabStripView.swift`/`TransferQueueBar.swift`,
        /// so the label always tracks the shared badge L10n keys instead of
        /// hardcoding a switch.
        private func backendBadgeLabel(_ kind: ConnectionKind) -> String {
            let descriptor = BackendDescriptor.descriptor(for: kind)
            return L10n.string(descriptor.badgeLabelKey, descriptor.badgeLabelDefault)
        }

        private func makeItem(_ entry: BrowserMenuEntry, selection: [RemoteFileItem]) -> NSMenuItem {
            switch entry {
            case .transferToOtherPane, .transferToSession:
                // Both consumed inline by `menuNeedsUpdate` (folded into one
                // "Transfer" submenu via `makeTransferItem`) — never reaches
                // here. Degrade gracefully rather than crash if that
                // invariant is ever broken: debug builds assert, release
                // builds render a disabled placeholder.
                assertionFailure("transferToOtherPane/transferToSession are handled in menuNeedsUpdate")
                let placeholder = NSMenuItem(
                    title: L10n.string("menu.transfer", "Transfer"),
                    action: nil, keyEquivalent: "")
                placeholder.isEnabled = false
                return placeholder
            case .openInEditor:
                return actionItem(title: L10n.string("menu.openEditor", "Open"), entry: entry, selection: selection)
            case .rename:
                return actionItem(title: L10n.string("menu.rename", "Rename…"), entry: entry, selection: selection)
            case .infoAndPermissions:
                return actionItem(
                    title: PermissionsPresentation.infoMenuTitle(supportsPermissions: supportsPermissions),
                    entry: entry, selection: selection)
            case .newFolder:
                return actionItem(title: L10n.string("menu.newFolder", "New Folder…"), entry: entry, selection: selection)
            case .newFile:
                return actionItem(title: L10n.string("menu.newFile", "New File…"), entry: entry, selection: selection)
            case .copyPath:
                return actionItem(title: L10n.string("menu.copyPath", "Copy Path"), entry: entry, selection: selection)
            case .computeChecksum:
                return actionItem(
                    title: L10n.string("menu.checksum", "Compute Checksum…"),
                    entry: entry, selection: selection)
            case .delete:
                let item = actionItem(title: L10n.string("menu.delete", "Delete…"), entry: entry, selection: selection)
                return item
            case .backendFileAction(let action):
                // Generic render of a protocol-contributed action (M14): the
                // table view never inspects the backend, just the title.
                // Handler wiring (e.g. the S3 presigned-URL sheet) happens at
                // the `onMenuAction` call site in `ContentView`, keyed off
                // `action.id` — this file never inspects it either.
                return actionItem(
                    title: L10n.string(action.titleKey, action.titleDefault), entry: entry, selection: selection)
            }
        }

        private func actionItem(
            title: String, entry: BrowserMenuEntry, selection: [RemoteFileItem]
        ) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: #selector(menuItemFired(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = MenuActionBox(entry: entry, selection: selection)
            return item
        }

        @objc private func menuItemFired(_ sender: NSMenuItem) {
            guard let box = sender.representedObject as? MenuActionBox else { return }
            onMenuAction?(box.entry, box.selection)
        }
    }
}

/// NSMenuItem.representedObject needs a class — boxes the menu action.
private final class MenuActionBox {
    let entry: BrowserMenuEntry
    let selection: [RemoteFileItem]
    init(entry: BrowserMenuEntry, selection: [RemoteFileItem]) {
        self.entry = entry
        self.selection = selection
    }
}

/// Mockup-style column header: versal 10.5pt semibold with tracking in
/// inkTertiary, 12pt leading inset, hairline bottom border (spec M5g).
private final class PolishedHeaderCell: NSTableHeaderCell {
    /// Sort indicator state for THIS column's header (M11l/T2): `nil` when
    /// this column is not the active sort column (no triangle drawn);
    /// otherwise the direction (`true` = ascending ▲, `false` = descending
    /// ▼). Written by `Coordinator.updateSortIndicators` whenever the sort
    /// state changes. Because `draw(withFrame:in:)` below never calls
    /// `super` (the whole point of this subclass — see its header-body
    /// comment), AppKit's own `indicatorImage`/`setIndicatorImage(_:in:)`
    /// machinery never paints anything either; this property and the
    /// drawing it drives are a full replacement for it, not a supplement.
    var sortIndicatorAscending: Bool?

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {
        // Flat background matching the table body, so header and content
        // read as one surface (mockup: seamless card).
        NSColor.controlBackgroundColor.setFill()
        cellFrame.fill()

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10.5, weight: .semibold),
            .foregroundColor: DesignTokens.inkTertiaryNS,
            .kern: 0.8,
        ]
        let text = NSAttributedString(
            string: stringValue.uppercased(with: .current), attributes: attributes)
        let size = text.size()
        let textRect = NSRect(
            x: cellFrame.minX + 12,
            y: cellFrame.midY - size.height / 2,
            width: cellFrame.width - 16,
            height: size.height)
        text.draw(in: textRect)

        // Sort indicator (M11l/T2): drawn AFTER the title so it never
        // affects the title's own metrics above (font/kern/inset all
        // untouched) — it lives entirely in the free space between the
        // (short, uppercased) title and the header's trailing edge, mirrored
        // off the same 12pt inset the title's leading edge uses.
        if let ascending = sortIndicatorAscending {
            drawSortIndicator(ascending: ascending, in: cellFrame)
        }

        DesignTokens.hairlineNS.setFill()
        NSRect(x: cellFrame.minX, y: cellFrame.maxY - 1,
               width: cellFrame.width, height: 1).fill()
    }

    /// Small filled triangle at the trailing edge: ▲ for ascending, ▼ for
    /// descending, in `inkTertiary` (M11l/T2). `NSTableHeaderView` is
    /// flipped (y grows downward) — the same assumption the hairline above
    /// already makes by drawing its "bottom" border at `cellFrame.maxY`.
    private func drawSortIndicator(ascending: Bool, in cellFrame: NSRect) {
        let width: CGFloat = 7
        let height: CGFloat = 5
        let x = cellFrame.maxX - 12 - width
        let topY = cellFrame.midY - height / 2
        let bottomY = cellFrame.midY + height / 2

        let path = NSBezierPath()
        if ascending {
            // ▲: point at the top (visually up, i.e. the smaller y in this
            // flipped view).
            path.move(to: NSPoint(x: x, y: bottomY))
            path.line(to: NSPoint(x: x + width, y: bottomY))
            path.line(to: NSPoint(x: x + width / 2, y: topY))
        } else {
            // ▼: point at the bottom.
            path.move(to: NSPoint(x: x, y: topY))
            path.line(to: NSPoint(x: x + width, y: topY))
            path.line(to: NSPoint(x: x + width / 2, y: bottomY))
        }
        path.close()
        DesignTokens.inkTertiaryNS.setFill()
        path.fill()
    }

    override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
        // Everything happens in draw(withFrame:in:) — keep AppKit from
        // painting the default title on top.
    }
}

/// Maps `FileSortKey` to/from the column identifiers used both as
/// `NSUserInterfaceItemIdentifier.rawValue` (see `RemoteFileTableView
/// .buildColumns`) and `NSSortDescriptor.key` — kept in one place so the
/// name/size/modified/permissions/owner/group/type switch exists exactly
/// once in this file. The raw strings deliberately match `FileColumn
/// .rawValue` (M11m/T2), so a column identifier round-trips through either
/// type with the same string.
extension FileSortKey {
    fileprivate var columnIdentifier: String {
        switch self {
        case .name: return "name"
        case .size: return "size"
        case .modified: return "modified"
        case .permissions: return "permissions"
        case .owner: return "owner"
        case .group: return "group"
        case .type: return "type"
        }
    }

    fileprivate init?(columnIdentifier: String) {
        switch columnIdentifier {
        case "name": self = .name
        case "size": self = .size
        case "modified": self = .modified
        case "permissions": self = .permissions
        case "owner": self = .owner
        case "group": self = .group
        case "type": self = .type
        default: return nil
        }
    }
}

/// Localized column header title (M11m/T2) — shared by `PolishedHeaderCell`
/// (via `buildColumns`) and the Settings column-visibility checkboxes
/// (`SettingsView.swift`), so the title/fallback pair for a given column
/// lives in exactly one place. `Core` itself never carries this text (the
/// project's language policy keeps user-facing strings out of Core).
extension FileColumn {
    var localizedTitle: String {
        let fallback: String
        switch self {
        case .name: fallback = "Name"
        case .size: fallback = "Size"
        case .modified: fallback = "Modified"
        case .permissions: fallback = "Permissions"
        case .owner: fallback = "Owner"
        case .group: fallback = "Group"
        case .type: fallback = "Type"
        case .checksum: fallback = "Checksum"
        }
        return L10n.string("filetable.column.\(rawValue)", fallback)
    }

    /// The title the table's HEADER carries, which for the checksum column
    /// is not the same string as the one the Settings checkbox carries
    /// (2026-09-02).
    ///
    /// A column of hex over a bare "Checksum" would leave out the one thing
    /// somebody comparing against a published figure has to know: which
    /// digest these are. The setting names the column; the header names
    /// what is in it. `ChecksumAlgorithm.displayName` is deliberately not
    /// localized (see its own doc comment) — it is a standard's spelling,
    /// and translating it would make the comparison harder.
    func localizedHeaderTitle(checksumAlgorithm: ChecksumAlgorithm) -> String {
        guard self == .checksum else { return localizedTitle }
        return String(
            format: L10n.string("filetable.column.checksum.withAlgorithm %@", "Checksum (%@)"),
            checksumAlgorithm.displayName)
    }
}

/// Mockup-style row: rectangular remoteSoft selection in BOTH panes (blue is
/// the selection color per CI), identical with and without key focus.
private final class PolishedRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }
        DesignTokens.remoteSoftNS.setFill()
        bounds.fill()
    }

    override var isEmphasized: Bool {
        get { false } // never fall back to the vibrant system blue
        set {}
    }
}
