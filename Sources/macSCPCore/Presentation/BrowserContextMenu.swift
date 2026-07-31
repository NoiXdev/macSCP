import Foundation

/// Which pane a context menu belongs to (M7b) — the editor entry exists
/// only on the remote side.
public enum BrowserPaneSide: Sendable { case local, remote }

/// Cross-session transfer target (M8b). Identifies a remote pane in another
/// tab as a destination for "Transfer" menu actions.
public struct CrossSessionTarget: Equatable, Sendable, Identifiable {
    public let id: UUID
    public let title: String
    public let remotePath: String

    public init(id: UUID, title: String, remotePath: String) {
        self.id = id
        self.title = title
        self.remotePath = remotePath
    }
}

/// Context-menu entries in display order. The AppKit layer maps these to
/// localized NSMenuItems; keeping the decision logic here makes it unit-
/// testable (the test target only links macSCPCore — M7a lesson).
public enum BrowserMenuEntry: Equatable, Sendable {
    case transferToOtherPane   // submenu "Transfer" — see transferToSession for the M8b per-session targets
    case transferToSession(CrossSessionTarget)  // M8b: transfer to another tab's remote
    case openInEditor          // remote FILES only (M5e path)
    case rename                // single selection only
    case infoAndPermissions    // single, NEVER for symlinks (chmod follows links)
    case newFolder             // always (also on background click)
    case copyPath              // any non-empty selection
    case delete                // any non-empty selection
}

public enum BrowserContextMenu {
    /// Menu model for a selection. Empty selection = background click.
    /// The `crossSessionTargets` parameter lists remote panes from other tabs
    /// that can receive transfers — these appear in the submenu right after
    /// the "to other pane" item when `transferToOtherPane` is present.
    public static func entries(
        for selection: [RemoteFileItem], side: BrowserPaneSide,
        crossSessionTargets: [CrossSessionTarget] = []
    ) -> [BrowserMenuEntry] {
        guard !selection.isEmpty else { return [.newFolder] }
        var entries: [BrowserMenuEntry] = []
        if selection.contains(where: { $0.kind != .symlink }) {
            entries.append(.transferToOtherPane)
            // M8b: append per-session targets (same transferability gate)
            entries.append(contentsOf: crossSessionTargets.map { .transferToSession($0) })
        }
        if selection.count == 1, let only = selection.first {
            if side == .remote && only.kind == .file {
                entries.append(.openInEditor)
            }
            entries.append(.rename)
            if only.kind != .symlink {
                entries.append(.infoAndPermissions)
            }
        }
        entries.append(.newFolder)
        entries.append(.copyPath)
        entries.append(.delete)
        return entries
    }
}
