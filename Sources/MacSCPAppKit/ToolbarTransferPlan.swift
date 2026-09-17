import Foundation
import macSCPCore

/// Whether the toolbar's Upload or Download button asks before it transfers
/// the selection (maintainer decision of 2026-09-16): it asks only when the
/// selection holds more than one item or a folder; a single file transfers
/// without a question.
///
/// **Scope: the two toolbar buttons only** (`uploadButton`/`downloadButton`
/// in `ContentView+Transfers.swift`). The decision named those two buttons,
/// so every other route to a transfer stays as it was and does not ask: the
/// pane context menu's transfer to the other pane, its transfer to another
/// tab's session (`transferToSession`), and drag and drop — within a pane
/// pair, between tabs, or from Finder.
enum ToolbarTransferPlan: Equatable {
    /// Transfer at once, as the buttons did before the question existed.
    case transferNow
    /// Ask first, naming how many items would be transferred and whether a
    /// folder — a whole tree — is among them.
    case ask(itemCount: Int, includesFolders: Bool)

    /// Symlinks do not count: `transferSelection` skips them, so a symlink
    /// is not an item that would be transferred, and a file beside a symlink
    /// is still a single file. A selection with nothing transferable in it
    /// asks nothing — there is nothing to confirm.
    static func plan(for selection: [RemoteFileItem]) -> ToolbarTransferPlan {
        let transferable = selection.filter { $0.kind != .symlink }
        let includesFolders = transferable.contains { $0.kind == .directory }
        guard transferable.count > 1 || includesFolders else { return .transferNow }
        return .ask(itemCount: transferable.count, includesFolders: includesFolders)
    }

    // MARK: - The question's text

    static func titleKey(side: BrowserPaneSide) -> (key: String, defaultValue: String) {
        switch side {
        case .local: ("browser.transferConfirm.upload.title", "Upload the selection?")
        case .remote: ("browser.transferConfirm.download.title", "Download the selection?")
        }
    }

    /// Plural keys (`Localizable.stringsdict`): argument 1 is the item
    /// count, argument 2 the destination directory the pane showed when the
    /// button was pressed.
    static func messageKey(
        side: BrowserPaneSide, includesFolders: Bool
    ) -> (key: String, defaultValue: String) {
        switch (side, includesFolders) {
        case (.local, false):
            ("browser.transferConfirm.upload.message %lld %@",
             "%1$lld items will be uploaded to “%2$@”.")
        case (.local, true):
            ("browser.transferConfirm.upload.messageWithFolders %lld %@",
             "%1$lld items, including folders with everything in them, will be uploaded to “%2$@”.")
        case (.remote, false):
            ("browser.transferConfirm.download.message %lld %@",
             "%1$lld items will be downloaded to “%2$@”.")
        case (.remote, true):
            ("browser.transferConfirm.download.messageWithFolders %lld %@",
             "%1$lld items, including folders with everything in them, will be downloaded to “%2$@”.")
        }
    }

    static func title(side: BrowserPaneSide) -> String {
        let entry = titleKey(side: side)
        return L10n.string(entry.key, entry.defaultValue)
    }

    /// The confirm button reads exactly like the toolbar button that asked.
    static func confirmLabel(side: BrowserPaneSide) -> String {
        switch side {
        case .local: L10n.string("browser.upload", "Upload")
        case .remote: L10n.string("browser.download", "Download")
        }
    }

    static func message(
        side: BrowserPaneSide, itemCount: Int, includesFolders: Bool, destinationPath: String
    ) -> String {
        let entry = messageKey(side: side, includesFolders: includesFolders)
        return String(format: L10n.string(entry.key, entry.defaultValue), itemCount, destinationPath)
    }
}

/// A pending toolbar transfer question. Everything the transfer needs is
/// captured when the button is pressed — the tab, its session, the side, the
/// selection — and the confirm action transfers exactly that, never the
/// selection or the tab as they stand when the question is answered (the
/// "capture now, not later" discipline `ImportKeyTarget` follows).
struct ToolbarTransferRequest: Identifiable, Equatable {
    let id = UUID()
    let tab: SessionTab
    let session: BrowserSession
    let side: BrowserPaneSide
    let selection: [RemoteFileItem]
    let itemCount: Int
    let includesFolders: Bool
    /// The directory the OTHER pane showed at press, for the message.
    let destinationPath: String

    /// Identity, not value: `SessionTab` is a reference type with no
    /// equality of its own, and two presses are two questions.
    static func == (lhs: ToolbarTransferRequest, rhs: ToolbarTransferRequest) -> Bool {
        lhs.id == rhs.id
    }
}
