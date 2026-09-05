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

/// Which way a pane entry points: the action the user can take right now.
/// One entry per pane with a changing label, never two entries of which one
/// is dead — this menu omits what does not apply instead of greying it.
public enum PaneAction: Equatable, Sendable {
    case show
    case hide
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
    /// Take this tab out of the window it is in and give it one of its own.
    /// Requires a neighbour — not on either side, just anywhere: moving the
    /// only tab of a window into a new window would close one window and
    /// open another holding the same thing, which is a no-op with a
    /// flicker. That is the whole precondition, and it is a count, which is
    /// why it can be decided here: what the app layer does with the answer
    /// (open a window, park the tab, close the emptied one) is the app
    /// layer's business, and nothing about a window is known here.
    case moveToNewWindow
    /// Show or hide one of the window's two halves. Requires both a live
    /// connection and the pane's own `PaneToggleState` reporting
    /// `isEnabled`: there are no halves to switch on a tab still showing a
    /// connection form, and `isEnabled` is false for the last visible half,
    /// so no entry here can empty the window.
    /// Always the built-in terminal; `SettingsStore.terminalTarget` has no
    /// say, for the same reason the Terminal menu's entries ignore it.
    case pane(PaneToggle, PaneAction)
    /// Open this session's shell in an external terminal. Always external,
    /// never the built-in pane. Needs a shell and a live connection.
    ///
    /// The capability half is `ProtocolCapabilities.supportsShell` (`true`
    /// for SSH, `false` for S3 and WebDAV); the state half is a connected
    /// tab — there is no shell to attach to otherwise.
    case openExternalTerminal
    /// Requires both an ad-hoc-dialed tab and a live connection: persisting
    /// a connection that was dialed ad hoc, and only once it is actually
    /// connected. Absent for a tab that already belongs to a stored
    /// session, because there is nothing to save.
    case saveAsSession
}

public enum TabContextMenu {
    /// Which entries a tab offers.
    ///
    /// `index` and `count` decide the movement, the bulk close and the move
    /// into a new window; the five remaining facts decide the rest (see each
    /// `TabMenuEntry` case for its precondition). Nothing here reaches for a
    /// `ConnectionKind`: what an entry depends on is a capability or a
    /// state, never which protocol it happens to be.
    ///
    /// The two toggle states are read, not recomputed: `PaneVisibility.
    /// toggleState(for:hasShell:)` has already folded in both the shell's
    /// absence and the lock on the last visible half, so `isEnabled` is the
    /// whole question of whether a pane entry can be offered at all.
    public static func entries(
        atIndex index: Int, ofTabCount count: Int,
        supportsShell: Bool, isAdHoc: Bool, isConnected: Bool,
        filesToggle: PaneToggleState, terminalToggle: PaneToggleState
    ) -> [TabMenuEntry] {
        var entries: [TabMenuEntry] = [.close]
        if count > 1 { entries.append(.closeOthers) }
        if index > 0 { entries.append(.move(.left)) }
        if index < count - 1 { entries.append(.move(.right)) }
        if count > 1 { entries.append(.moveToNewWindow) }
        if isConnected && filesToggle.isEnabled {
            entries.append(.pane(.files, filesToggle.isOn ? .hide : .show))
        }
        if isConnected && terminalToggle.isEnabled {
            entries.append(.pane(.terminal, terminalToggle.isOn ? .hide : .show))
        }
        if supportsShell && isConnected { entries.append(.openExternalTerminal) }
        if isAdHoc && isConnected { entries.append(.saveAsSession) }
        return entries
    }
}
