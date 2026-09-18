import Foundation
import macSCPCore

/// The session editor's "New group…" button beside its group picker
/// (jump-and-groups plan, Task 5): where the new group lands, what the name
/// prompt is titled, and what the picker shows afterwards.
///
/// A plain type over the two view models rather than code inside
/// `SessionEditorGroupPicker`, for the reason `SidebarNewGroupAlertPlan` states:
/// nothing in this project can render a view in a test, so the decision has
/// to live somewhere a test can reach it directly.
///
/// Decided for the maintainer (Task 5's brief): the group is created INSIDE
/// the group the picker currently shows, at the top level when it shows "No
/// group"; and it stays created if the editor is then cancelled, because a
/// group is created immediately everywhere else too.
///
/// A chosen group that is no longer there — deleted from the sidebar while
/// the editor was open — is handed to the store as it stands, and the store
/// refuses it with the typed error the sidebar's own "New group…" gets for a
/// stale parent (`CreateGroupParentMissing`, through
/// `SessionListViewModel.errorMessage`). Until the final review of this plan
/// (M11) the editor lifted such a selection to the top level instead: the
/// silent lift Task 4's rule forbids in Core, done one layer up.
@MainActor
enum SessionEditorNewGroupPlan {
    /// The name prompt's title — the sidebar's own ("New group in “Work”"),
    /// asked about the same parent this plan creates in. A selection naming
    /// no group gets the sidebar's plain title, as a stale
    /// `pendingNewGroupParentID` does there.
    static func title(forSelection selectedGroupID: UUID?, groups: [StoredGroup]) -> String {
        SidebarNewGroupAlertPlan.title(parentID: selectedGroupID, groups: groups)
    }

    /// Creates the group through `sessionList`, inside the picker's current
    /// group, and makes the form's picker show it. Answers the created group,
    /// or `nil` when nothing was created — an empty name, or a store refusal
    /// (a vanished parent among them) `sessionList.errorMessage` already
    /// reports — in which case the picker keeps what it showed.
    @discardableResult
    static func commit(
        name: String, form: ConnectionViewModel, sessionList: SessionListViewModel
    ) -> StoredGroup? {
        guard let group = sessionList.createGroup(named: name, inGroup: form.selectedGroupID) else {
            return nil
        }
        form.selectedGroupID = group.id
        return group
    }
}
