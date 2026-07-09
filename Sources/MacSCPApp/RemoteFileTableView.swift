import AppKit
import SwiftUI
import macSCPCore

/// AppKit-NSTableView als SwiftUI-View. Spec-Vorgabe: reine SwiftUI-Listen
/// brechen bei Verzeichnissen mit tausenden Einträgen ein.
struct RemoteFileTableView: NSViewRepresentable {
    let items: [RemoteFileItem]
    let selectedPath: String?
    let onOpen: (RemoteFileItem) -> Void
    let onSelect: (RemoteFileItem?) -> Void
    var pasteboardWriter: ((RemoteFileItem) -> NSPasteboardWriting?)? = nil

    func makeCoordinator() -> Coordinator {
        let coordinator = Coordinator(onOpen: onOpen, onSelect: onSelect)
        coordinator.pasteboardWriter = pasteboardWriter
        return coordinator
    }

    func makeNSView(context: Context) -> NSScrollView {
        let table = NSTableView()
        table.style = .inset
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = false

        for (identifier, title, width) in [
            ("name", "Name", 260.0),
            ("size", "Größe", 90.0),
            ("modified", "Geändert", 160.0),
        ] {
            let column = NSTableColumn(identifier: .init(identifier))
            column.title = title
            column.width = width
            table.addTableColumn(column)
        }

        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        table.target = context.coordinator
        table.doubleAction = #selector(Coordinator.doubleClicked(_:))
        // Drag nach außerhalb der App erlauben (z.B. Finder als Ziel).
        table.setDraggingSourceOperationMask(.copy, forLocal: false)

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        context.coordinator.table = table
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.items = items
        context.coordinator.onOpen = onOpen
        context.coordinator.onSelect = onSelect
        context.coordinator.pasteboardWriter = pasteboardWriter
        guard let table = nsView.documentView as? NSTableView else { return }
        // reloadData() löscht die Auswahl ohne Delegate-Aufruf —
        // deshalb programmatisch wiederherstellen, Callback dabei unterdrücken.
        context.coordinator.suppressSelectionCallback = true
        table.reloadData()
        if let selectedPath,
           let row = items.firstIndex(where: { $0.path == selectedPath }) {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        context.coordinator.suppressSelectionCallback = false
    }

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var items: [RemoteFileItem] = []
        var onOpen: (RemoteFileItem) -> Void
        var onSelect: (RemoteFileItem?) -> Void
        var pasteboardWriter: ((RemoteFileItem) -> NSPasteboardWriting?)?
        weak var table: NSTableView?
        var suppressSelectionCallback = false

        init(onOpen: @escaping (RemoteFileItem) -> Void, onSelect: @escaping (RemoteFileItem?) -> Void) {
            self.onOpen = onOpen
            self.onSelect = onSelect
        }

        func numberOfRows(in tableView: NSTableView) -> Int {
            items.count
        }

        /// Liefert den Drag-Pasteboard-Writer für eine Zeile (z.B. Datei-URL) —
        /// nil macht die Zeile nicht ziehbar (z.B. Verzeichnisse).
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
                    field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                    field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
                    field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                ])
            }
            cell.textField?.stringValue = text
            return cell
        }

        @objc func doubleClicked(_ sender: Any?) {
            guard let row = table?.clickedRow, row >= 0, row < items.count else { return }
            let item = items[row]
            if item.isDirectory {
                onOpen(item)
            }
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !suppressSelectionCallback else { return }
            guard let table else { return }
            let row = table.selectedRow
            onSelect(row >= 0 && row < items.count ? items[row] : nil)
        }
    }
}
