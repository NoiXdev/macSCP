import Foundation

/// Context-menu entries for a tab, in display order. The app layer maps
/// these to localized menu items; the decision lives here so it can be
/// tested without rendering anything — the same split
/// `BrowserContextMenu` uses.
public enum TabMenuEntry: Equatable, Sendable {
    case close
    case closeOthers
    case moveLeft
    case moveRight
    /// Only where the backend has a shell at all — see
    /// `ProtocolCapabilities.supportsShell`, which is `true` for SSH and
    /// `false` for S3 and WebDAV.
    case openTerminal
    /// Persisting a connection that was dialed ad hoc. Absent for a tab
    /// that already belongs to a stored session, because there is nothing
    /// to save.
    case saveAsSession
}

public enum TabContextMenu {
    /// Which entries a tab offers.
    ///
    /// `index` and `count` decide the movement and the bulk close; the
    /// three flags decide the rest. Nothing here reaches for a
    /// `ConnectionKind`: what an entry depends on is a capability or a
    /// state, never which protocol it happens to be.
    public static func entries(
        atIndex index: Int, ofTabCount count: Int,
        supportsShell: Bool, isAdHoc: Bool, isConnected: Bool
    ) -> [TabMenuEntry] {
        var entries: [TabMenuEntry] = [.close]
        if count > 1 { entries.append(.closeOthers) }
        if index > 0 { entries.append(.moveLeft) }
        if index < count - 1 { entries.append(.moveRight) }
        // A terminal needs a shell AND a live connection: the capability
        // says the backend could have one, the state says there is
        // something to attach it to.
        if supportsShell && isConnected { entries.append(.openTerminal) }
        if isAdHoc && isConnected { entries.append(.saveAsSession) }
        return entries
    }
}
