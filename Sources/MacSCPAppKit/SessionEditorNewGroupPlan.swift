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
@MainActor
enum SessionEditorNewGroupPlan {
    /// Where the new group lands: the picker's current group, or the top
    /// level (`nil`) when that is "No group" — or when it names a group that
    /// is no longer there, which the picker cannot show either and which
    /// `SessionListViewModel.createGroup(named:inGroup:)` would refuse.
    static func parentID(forSelection selectedGroupID: UUID?, groups: [StoredGroup]) -> UUID? {
        guard let selectedGroupID, groups.contains(where: { $0.id == selectedGroupID }) else {
            return nil
        }
        return selectedGroupID
    }

    /// The name prompt's title — the sidebar's own ("New group in “Work”"),
    /// asked about the same parent this plan creates in.
    static func title(forSelection selectedGroupID: UUID?, groups: [StoredGroup]) -> String {
        SidebarNewGroupAlertPlan.title(
            parentID: parentID(forSelection: selectedGroupID, groups: groups), groups: groups)
    }

    /// Creates the group through `sessionList` and makes the form's picker
    /// show it. Answers the created group, or `nil` when nothing was created
    /// — an empty name, or a store refusal `sessionList.errorMessage` already
    /// reports — in which case the picker keeps what it showed.
    @discardableResult
    static func commit(
        name: String, form: ConnectionViewModel, sessionList: SessionListViewModel
    ) -> StoredGroup? {
        let parentID = parentID(forSelection: form.selectedGroupID, groups: sessionList.groups)
        guard let group = sessionList.createGroup(named: name, inGroup: parentID) else { return nil }
        form.selectedGroupID = group.id
        return group
    }
}
