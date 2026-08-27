import Foundation

/// Which way a move entry moves the tab it hangs off.
///
/// A direction rather than an offset, and carried by the entry itself, so
/// no layer between this decision and `TabsViewModel.move(tabID:oneStep:)`
/// has to translate it. The step used to be worked out in the app layer's
/// handler, where nothing could call it with a value: swapping the two
/// numbers there left the whole suite green while "Move Right" on the first
/// tab became a silent no-op (final review, I1). What a value test can
/// reach now is the direction itself, on both sides of the one function
/// that turns it into a position.
public enum TabMoveStep: Equatable, Sendable {
    case left
    case right
}

/// Context-menu entries for a tab, in display order. The app layer maps
/// these to localized menu items; the decision lives here so it can be
/// tested without rendering anything — the same split
/// `BrowserContextMenu` uses.
public enum TabMenuEntry: Equatable, Sendable {
    case close
    case closeOthers
    /// Requires a neighbour on that side — a tab at either end is offered
    /// only the step that has somewhere to go.
    case move(TabMoveStep)
    /// Requires both a shell-capable backend and a live connection: see
    /// `ProtocolCapabilities.supportsShell` (`true` for SSH, `false` for S3
    /// and WebDAV) for the capability half, and a connected tab for the
    /// state half — there is no terminal to attach to otherwise.
    case openTerminal
    /// Requires both an ad-hoc-dialed tab and a live connection: persisting
    /// a connection that was dialed ad hoc, and only once it is actually
    /// connected. Absent for a tab that already belongs to a stored
    /// session, because there is nothing to save.
    case saveAsSession
}

public enum TabContextMenu {
    /// Which entries a tab offers.
    ///
    /// `index` and `count` decide the movement and the bulk close; the
    /// three flags decide the rest (see each `TabMenuEntry` case for its
    /// precondition). Nothing here reaches for a `ConnectionKind`: what an
    /// entry depends on is a capability or a state, never which protocol it
    /// happens to be.
    public static func entries(
        atIndex index: Int, ofTabCount count: Int,
        supportsShell: Bool, isAdHoc: Bool, isConnected: Bool
    ) -> [TabMenuEntry] {
        var entries: [TabMenuEntry] = [.close]
        if count > 1 { entries.append(.closeOthers) }
        if index > 0 { entries.append(.move(.left)) }
        if index < count - 1 { entries.append(.move(.right)) }
        if supportsShell && isConnected { entries.append(.openTerminal) }
        if isAdHoc && isConnected { entries.append(.saveAsSession) }
        return entries
    }
}
