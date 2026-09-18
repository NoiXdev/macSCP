import Foundation
import macSCPCore

/// The "New group…" alert's title (Task 4, fix round 1). Before this fix
/// every route into the alert — the background menu, a session's "Move
/// to…" submenu, and the folder-row menu this task added — shared one
/// plain title, so a group created inside a folder gave no indication of
/// which folder it was landing in until after it was named.
///
/// A plain function over plain values, the same reason `TabTitlePlan`
/// exists as a free-standing type: nothing in this project can render a
/// view in a test, so this decision has to live somewhere a test can reach
/// it directly. `SessionSidebar`'s `.alert(...)` is the one caller.
enum SidebarNewGroupAlertPlan {
    /// `parentID` is `SessionSidebar`'s `pendingNewGroupParentID`; `groups`
    /// is `viewModel.groups`.
    ///
    /// `nil`, or a `parentID` naming no group in `groups` — a stale id from
    /// a folder that vanished between the menu click and the alert
    /// rendering — both fall back to the plain title rather than showing a
    /// placeholder or a blank name. The background menu and a session's
    /// "Move to…" submenu always pass `nil`, so their alert is unchanged
    /// from before this fix.
    static func title(parentID: UUID?, groups: [StoredGroup]) -> String {
        guard let parentID, let parent = groups.first(where: { $0.id == parentID }) else {
            return L10n.string("sidebar.newGroup.title", "New group")
        }
        return String(
            format: L10n.string("sidebar.newGroup.title.inFolder %@", "New group in “%@”"),
            parent.name)
    }
}
