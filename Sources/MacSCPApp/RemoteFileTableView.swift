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

    func makeCoordinator() -> Coordinator {
        let coordinator = Coordinator(onOpen: onOpen, onSelect: onSelect)
        coordinator.onOpenFile = onOpenFile
        coordinator.pasteboardWriter = pasteboardWriter
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

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var items: [RemoteFileItem] = []
        var onOpen: (RemoteFileItem) -> Void
        var onSelect: ([RemoteFileItem]) -> Void
        var onOpenFile: ((RemoteFileItem) -> Void)?
        var pasteboardWriter: ((RemoteFileItem) -> NSPasteboardWriting?)?
        weak var table: NSTableView?
        var suppressSelectionCallback = false

        init(onOpen: @escaping (RemoteFileItem) -> Void, onSelect: @escaping ([RemoteFileItem]) -> Void) {
            self.onOpen = onOpen
            self.onSelect = onSelect
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
