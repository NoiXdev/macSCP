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

    /// How many of `closing` hold a non-terminal item of their own.
    /// `@MainActor` for the same reason `hasIncomingTransfers` is:
    /// `SessionTab` is.
    @MainActor
    static func transferringCount(among closing: [SessionTab]) -> Int {
        closing.count { $0.transferQueue.isActive }
    }

    /// How many of `closing` are the destination of another tab's transfer.
    @MainActor
    static func incomingCount(among closing: [SessionTab], in tabs: [SessionTab]) -> Int {
        closing.count { hasIncomingTransfers(for: $0.id, in: tabs) }
    }

    /// The one question asked before closing several tabs at once. Empty
    /// when neither reason holds — the caller decides whether a dialog
    /// appears at all, exactly as with `message`.
    ///
    /// One question and one answer: declining cancels the whole operation
    /// rather than sparing the transferring tabs, because closing the quiet
    /// half would be a third behaviour nobody asked for.
    ///
    /// Both lines carry real plural forms via `Localizable.stringsdict`
    /// (the mechanism `snippets.export.confirm.message %lld` and
    /// `logins.export.summary %lld` already use — see `PluralCatalogTests`),
    /// not a hand-rolled one/other split: Polish needs a third `few`
    /// category these two counts don't get for free from plain `%d`. The
    /// `%lld` specifiers (rather than `%d`) match the `NSStringFormatValueTypeKey`
    /// the precedent's `.stringsdict` entries declare.
    static func bulkMessage(tabsClosing: Int, transferring: Int, incoming: Int) -> String {
        var lines: [String] = []
        if transferring > 0 {
            lines.append(String(
                format: L10n.string(
                    "tabs.closeOthers.activeTransfers %1$lld %2$lld",
                    "Closing %1$lld tabs cancels active transfers in %2$lld of them."),
                tabsClosing, transferring))
        }
        if incoming > 0 {
            lines.append(String(
                format: L10n.string(
                    "tabs.closeOthers.incomingTransfers %lld",
                    "%lld of them are receiving transfers from other tabs; closing cancels those."),
                incoming))
        }
        return lines.joined(separator: "\n")
    }
}
