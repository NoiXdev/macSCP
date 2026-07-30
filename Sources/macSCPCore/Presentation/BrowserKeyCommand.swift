import Foundation

/// Keyboard events the browser pane cares about (M11j). AppKit-free by
/// design: the App layer maps an `NSEvent` down to one of these cases so
/// this resolver never has to import AppKit.
public enum BrowserKey: Sendable {
    case returnKey
    case commandDown
    case commandO
    case commandUp
    case commandDelete
    case commandI
    case space
    case escape
}

/// The effect a key press should have on a browser pane, carrying whatever
/// data the caller needs to perform it.
public enum BrowserKeyAction: Equatable, Sendable {
    case open(RemoteFileItem)
    case goUp
    case rename(RemoteFileItem)
    case info(RemoteFileItem)
    case delete([RemoteFileItem])
    case transfer([RemoteFileItem])
    case clearSelection
}

/// Maps a key press + current selection + pane side to a `BrowserKeyAction`.
///
/// Finder-style keyboard shortcuts (Return to rename, Cmd-Delete, Cmd-I, ...)
/// must never be more or less permissive than the right-click context menu
/// (`BrowserContextMenu.entries(for:side:)`) — a selection that can't be
/// renamed from the menu must not be renamable from the keyboard either, and
/// vice versa. Rather than duplicating each entry's eligibility rule here
/// (single selection only, never a symlink, at least one non-symlink, ...),
/// this resolver asks `BrowserContextMenu.entries` for the current selection
/// and only emits an action when the corresponding `BrowserMenuEntry` is
/// present. That keeps the two call sites backed by one source of truth, so
/// menu and keyboard can never drift apart as the eligibility rules evolve.
public enum BrowserKeyCommand {
    public static func resolve(
        key: BrowserKey, selection: [RemoteFileItem], side: BrowserPaneSide
    ) -> BrowserKeyAction? {
        switch key {
        case .commandUp:
            return .goUp
        case .escape:
            return .clearSelection
        case .returnKey:
            guard let only = selection.first, selection.count == 1 else { return nil }
            let entries = BrowserContextMenu.entries(for: selection, side: side)
            guard entries.contains(.rename) else { return nil }
            return .rename(only)
        case .commandDown, .commandO:
            guard let only = selection.first, selection.count == 1 else { return nil }
            return .open(only)
        case .commandDelete:
            guard !selection.isEmpty else { return nil }
            let entries = BrowserContextMenu.entries(for: selection, side: side)
            guard entries.contains(.delete) else { return nil }
            return .delete(selection)
        case .commandI:
            guard let only = selection.first, selection.count == 1 else { return nil }
            let entries = BrowserContextMenu.entries(for: selection, side: side)
            guard entries.contains(.infoAndPermissions) else { return nil }
            return .info(only)
        case .space:
            guard !selection.isEmpty else { return nil }
            let entries = BrowserContextMenu.entries(for: selection, side: side)
            guard entries.contains(.transferToOtherPane) else { return nil }
            return .transfer(selection)
        }
    }
}
