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
    var pasteboardWriter: ((RemoteFileItem) -> NSPasteboardWriting?)? = nil
    /// Which pane this table belongs to (M7b) — drives the context menu's
    /// entries (the editor entry is remote-only). Explicit rather than
    /// inferred from `onOpenFile != nil`, so the side is self-documenting
    /// at every call site instead of an implicit side effect of the wiring.
    let side: BrowserPaneSide
    var onMenuAction: ((BrowserMenuEntry, [RemoteFileItem]) -> Void)? = nil

    func makeCoordinator() -> Coordinator {
        let coordinator = Coordinator(onOpen: onOpen, onSelect: onSelect, side: side)
        coordinator.onOpenFile = onOpenFile
        coordinator.pasteboardWriter = pasteboardWriter
        coordinator.onMenuAction = onMenuAction
        return coordinator
    }

    func makeNSView(context: Context) -> NSScrollView {
        let table = NSTableView()
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
        context.coordinator.pasteboardWriter = pasteboardWriter
        context.coordinator.onMenuAction = onMenuAction
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

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
        var items: [RemoteFileItem] = []
        var onOpen: (RemoteFileItem) -> Void
        var onSelect: ([RemoteFileItem]) -> Void
        var onOpenFile: ((RemoteFileItem) -> Void)?
        var pasteboardWriter: ((RemoteFileItem) -> NSPasteboardWriting?)?
        var onMenuAction: ((BrowserMenuEntry, [RemoteFileItem]) -> Void)?
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
            }
            cell.textField?.stringValue = text
            switch columnID {
            case "name":
                cell.textField?.font = .systemFont(ofSize: 12.5)
                cell.textField?.textColor = DesignTokens.inkNS
                cell.textField?.alignment = .natural
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
            let item = items[row]
            if item.isDirectory {
                onOpen(item)
            } else if item.kind == .file {
                onOpenFile?(item)
            }
            // Symlinks/other: unchanged (no-op).
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
            for entry in BrowserContextMenu.entries(for: selection, side: side) {
                if entry == .delete, menu.items.isEmpty == false {
                    menu.addItem(.separator())
                }
                menu.addItem(makeItem(entry, selection: selection))
            }
        }

        private func makeItem(_ entry: BrowserMenuEntry, selection: [RemoteFileItem]) -> NSMenuItem {
            switch entry {
            case .transferToOtherPane:
                // Submenu now with a single target — M8 hooks per-session
                // targets into the same submenu.
                let parent = NSMenuItem(
                    title: L10n.string("menu.transfer", "Transfer"), action: nil, keyEquivalent: "")
                let submenu = NSMenu()
                submenu.addItem(actionItem(
                    title: L10n.string("menu.transfer.otherPane", "To the other pane"),
                    entry: entry, selection: selection))
                parent.submenu = submenu
                return parent
            case .transferToSession:
                // Wired in M8b/T4.
                fatalError("transferToSession cases should be hooked into the Transfer submenu, not created standalone")
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
