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
    /// Cross-session transfer targets (M8b/T4) — evaluated fresh on EVERY
    /// `menuNeedsUpdate` call, not cached here, so a menu opened later in the
    /// session always shows the current set of other tabs and their current
    /// remote directories (menu build freezes the path into `CrossSessionTarget`
    /// at that moment — Spec §5.3). `nil` (the local pane's default before
    /// `ContentView` wires it) yields the pre-M8b flat "Transfer" entry.
    var crossSessionTargets: (() -> [CrossSessionTarget])? = nil

    func makeCoordinator() -> Coordinator {
        let coordinator = Coordinator(onOpen: onOpen, onSelect: onSelect, side: side)
        coordinator.onOpenFile = onOpenFile
        coordinator.onOpenSymlink = onOpenSymlink
        coordinator.pasteboardWriter = pasteboardWriter
        coordinator.onMenuAction = onMenuAction
        coordinator.onGoUp = onGoUp
        coordinator.crossSessionTargets = crossSessionTargets
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

        for (identifier, title, width) in [
            ("name", L10n.string("filetable.column.name", "Name"), 260.0),
            ("size", L10n.string("filetable.column.size", "Size"), 90.0),
            ("modified", L10n.string("filetable.column.modified", "Modified"), 160.0),
        ] {
            let column = NSTableColumn(identifier: .init(identifier))
            let header = PolishedHeaderCell(textCell: title)
            column.headerCell = header
            column.width = width
            table.addTableColumn(column)
        }

        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        table.target = context.coordinator
        table.doubleAction = #selector(Coordinator.doubleClicked(_:))
        // Allow dragging out of the app (e.g. the Finder as a target).
        table.setDraggingSourceOperationMask(.copy, forLocal: false)
        // Context menu (M7b): built lazily per click in menuNeedsUpdate.
        table.menu = NSMenu()
        table.menu?.delegate = context.coordinator

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        context.coordinator.table = table
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
        context.coordinator.crossSessionTargets = crossSessionTargets
        guard let table = nsView.documentView as? NSTableView else { return }
        if itemsChanged {
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
            }
            context.coordinator.suppressSelectionCallback = false
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
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard modifiers.contains(.command),
                !modifiers.contains(.shift),
                !modifiers.contains(.option),
                !modifiers.contains(.control),
                let coordinator = commandCoordinator
            else {
                return super.performKeyEquivalent(with: event)
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
            guard modifiers.isDisjoint(with: [.command, .option, .control]),
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

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
        var items: [RemoteFileItem] = []
        var onOpen: (RemoteFileItem) -> Void
        var onSelect: ([RemoteFileItem]) -> Void
        var onOpenFile: ((RemoteFileItem) -> Void)?
        var onOpenSymlink: ((RemoteFileItem) -> Void)?
        var pasteboardWriter: ((RemoteFileItem) -> NSPasteboardWriting?)?
        var onMenuAction: ((BrowserMenuEntry, [RemoteFileItem]) -> Void)?
        var onGoUp: (() -> Void)?
        var crossSessionTargets: (() -> [CrossSessionTarget])?
        let side: BrowserPaneSide
        weak var table: NSTableView?
        var suppressSelectionCallback = false

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
            guard row < items.count, let columnID = tableColumn?.identifier.rawValue else {
                return nil
            }
            let item = items[row]
            let text: String
            switch columnID {
            case "name": text = FileListFormatter.displayName(for: item)
            case "size": text = FileListFormatter.sizeString(for: item)
            case "modified": text = FileListFormatter.dateString(for: item)
            default: return nil
            }

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
                // Symlink marker (M11h/T1): only the "name" column ever needs
                // it, built once per fresh cell and toggled with `isHidden`
                // on every reuse below — never re-added, never repositioned.
                // It lives IN the existing 12pt left inset rather than
                // pushing `field` further right, so the resting layout (row
                // height, text baseline, 12pt text indent) is byte-for-byte
                // what M5g froze: `field`'s own leading constraint above is
                // untouched.
                if columnID == "name" {
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
            cell.textField?.stringValue = text
            switch columnID {
            case "name":
                cell.textField?.font = .systemFont(ofSize: 12.5)
                cell.textField?.textColor = DesignTokens.inkNS
                cell.textField?.alignment = .natural
                // Recycling hygiene (M11h/T1, critical): both `isHidden` and
                // `toolTip` are set UNCONDITIONALLY on every reuse, the same
                // way `stringValue`/font/color above already are — a row
                // that scrolls from a symlink to a plain file must not keep
                // showing either, since `makeView(withIdentifier:)` hands
                // back the exact same `NSTableCellView` instance.
                let isSymlink = item.kind == .symlink
                cell.imageView?.isHidden = !isSymlink
                if isSymlink {
                    let description = L10n.string("filetable.symlinkTooltip", "Symbolic link")
                    cell.imageView?.image = NSImage(
                        systemSymbolName: "arrow.up.forward",
                        accessibilityDescription: description)
                    cell.toolTip = description
                } else {
                    cell.toolTip = nil
                }
            case "size":
                cell.textField?.font = .monospacedDigitSystemFont(ofSize: 12.5, weight: .regular)
                cell.textField?.textColor = DesignTokens.inkSecondaryNS
                cell.textField?.alignment = .right
            default: // "modified"
                cell.textField?.font = .monospacedDigitSystemFont(ofSize: 12.5, weight: .regular)
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
            guard let action = BrowserKeyCommand.resolve(key: key, selection: selection, side: side)
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
                table?.deselectAll(nil)
                onSelect([])
            }
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !suppressSelectionCallback else { return }
            guard let table else { return }
            let rows = table.selectedRowIndexes
            onSelect(rows.compactMap { $0 < items.count ? items[$0] : nil })
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
                for: selection, side: side, crossSessionTargets: crossSessionTargets?() ?? [])
            // `.transferToOtherPane` is immediately followed (per the Core
            // model, `BrowserContextMenu.entries`) by zero or more
            // `.transferToSession` entries — those join the SAME "Transfer"
            // submenu rather than becoming a second parent item (M8b/T4
            // requirement 2). Consumed together here; without any cross-
            // session targets this produces the exact same single-item
            // submenu as before M8b (byte-identical flat structure).
            var index = 0
            while index < entries.count {
                let entry = entries[index]
                if entry == .transferToOtherPane {
                    var targets: [CrossSessionTarget] = []
                    index += 1
                    while index < entries.count, case .transferToSession(let target) = entries[index] {
                        targets.append(target)
                        index += 1
                    }
                    menu.addItem(makeTransferItem(selection: selection, targets: targets))
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
        /// via `menu.transfer.toSession` with the target's remote path as
        /// the item's subtitle (M8b/T4 requirement 2).
        private func makeTransferItem(
            selection: [RemoteFileItem], targets: [CrossSessionTarget]
        ) -> NSMenuItem {
            let parent = NSMenuItem(
                title: L10n.string("menu.transfer", "Transfer"), action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            submenu.addItem(actionItem(
                title: L10n.string("menu.transfer.otherPane", "To the other pane"),
                entry: .transferToOtherPane, selection: selection))
            if !targets.isEmpty {
                submenu.addItem(.separator())
                for target in targets {
                    let item = actionItem(
                        title: String(
                            format: L10n.string("menu.transfer.toSession", "To “%@”"), target.title),
                        entry: .transferToSession(target), selection: selection)
                    item.subtitle = target.remotePath
                    submenu.addItem(item)
                }
            }
            parent.submenu = submenu
            return parent
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
                return actionItem(title: L10n.string("menu.info", "Info & Permissions…"), entry: entry, selection: selection)
            case .newFolder:
                return actionItem(title: L10n.string("menu.newFolder", "New Folder…"), entry: entry, selection: selection)
            case .copyPath:
                return actionItem(title: L10n.string("menu.copyPath", "Copy Path"), entry: entry, selection: selection)
            case .delete:
                let item = actionItem(title: L10n.string("menu.delete", "Delete…"), entry: entry, selection: selection)
                return item
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

        DesignTokens.hairlineNS.setFill()
        NSRect(x: cellFrame.minX, y: cellFrame.maxY - 1,
               width: cellFrame.width, height: 1).fill()
    }

    override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
        // Everything happens in draw(withFrame:in:) — keep AppKit from
        // painting the default title on top.
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
