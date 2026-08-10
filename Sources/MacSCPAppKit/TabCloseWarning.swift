import Foundation
import macSCPCore

/// The two reasons closing a tab is worth warning about, and the text that
/// names them. Lifted out of `ContentView` so the wording and the
/// both-reasons-at-once case are held by tests rather than by reading.
enum TabCloseWarning {
    /// True while any OTHER tab's queue holds a non-terminal item that
    /// targets this tab — closing it would sever those incoming
    /// cross-session streams. `@MainActor`-isolated because `SessionTab` is;
    /// `message(activeTransfers:incomingTransfers:)` below needs no such
    /// isolation, so it stays free of it.
    @MainActor
    static func hasIncomingTransfers(for tabID: UUID, in tabs: [SessionTab]) -> Bool {
        tabs.contains { $0.id != tabID && $0.transferQueue.hasActiveItems(destinationTabID: tabID) }
    }

    /// One line per reason that holds, in a fixed order. Empty when neither
    /// holds — the caller decides whether a dialog appears at all.
    static func message(activeTransfers: Bool, incomingTransfers: Bool) -> String {
        var lines: [String] = []
        if activeTransfers {
            lines.append(L10n.string(
                "tabs.close.activeTransfers", "Active transfers in this tab will be canceled."))
        }
        if incomingTransfers {
            lines.append(L10n.string(
                "tabs.close.incomingTransfers",
                "Other tabs are streaming to this session; closing cancels those transfers."))
        }
        return lines.joined(separator: "\n")
    }
}
