import SwiftUI
import macSCPCore

/// The session editor's group choice (jump-and-groups plan, Task 5): the
/// picker, and the "New group…" button beside it with its name prompt.
///
/// The picker lists `GroupPickerEntries` — depth-first, each group labelled
/// with its path ("Work / Prod") — because a `Picker` cannot indent, and two
/// groups named alike under different folders are told apart only by where
/// they sit.
///
/// A view of its own rather than a stretch of `ConnectionFormView.body`,
/// for the reason `SidebarGroupRow` is one: it owns state — whether its
/// prompt is up, and the name typed into it — that the form has no other
/// use for. It also keeps the form's `body` the shape two guards read it
/// as: one `.alert(`, the connect failure's (`DetailSurfaceWiringGuardTests`),
/// and no `Button(L10n.string(…))` inside its `ScrollView`, where only a
/// footer button that had slipped in would put one
/// (`ConnectionFormScrollGuardTests`).
///
/// Where the new group lands, the prompt's title and the selection
/// afterwards are `SessionEditorNewGroupPlan`'s, tested there.
struct SessionEditorGroupPicker: View {
    @Bindable var viewModel: ConnectionViewModel
    /// `ConnectionFormView.groups` — the session list's groups.
    let groups: [StoredGroup]
    let sessionList: SessionListViewModel
    /// The picker's accessibility label; the form row draws the visible one.
    let label: String

    @State private var isShowingNewGroupPrompt = false
    @State private var newGroupName = ""

    var body: some View {
        HStack(spacing: 8) {
            Picker(label, selection: $viewModel.selectedGroupID) {
                Text(L10n.string("sidebar.noGroup", "No group")).tag(UUID?.none)
                ForEach(GroupPickerEntries.build(groups: groups)) { entry in
                    Text(entry.path).tag(UUID?.some(entry.id))
                }
            }
            .labelsHidden()
            Button(L10n.string("sidebar.newGroup", "New group…")) {
                newGroupName = ""
                isShowingNewGroupPrompt = true
            }
            .fixedSize()
            .help(L10n.string(
                "connection.field.group.new.help",
                "Creates a group inside the chosen one, or at the top level when no group is chosen"))
        }
        // The group is created the moment Create is pressed — inside the
        // group the picker shows, at the top level for "No group" — and the
        // picker then shows it. It stays created if the editor is cancelled
        // afterwards, as a group made from the sidebar does (decided in
        // Task 5's brief).
        .alert(
            SessionEditorNewGroupPlan.title(
                forSelection: viewModel.selectedGroupID, groups: sessionList.groups),
            isPresented: $isShowingNewGroupPrompt
        ) {
            TextField(L10n.string("sidebar.newGroup.placeholder", "Group name"), text: $newGroupName)
            Button(L10n.string("sidebar.newGroup.create", "Create")) {
                SessionEditorNewGroupPlan.commit(
                    name: newGroupName, form: viewModel, sessionList: sessionList)
                newGroupName = ""
            }
            Button(L10n.string("common.cancel", "Cancel"), role: .cancel) {
                newGroupName = ""
            }
        }
    }
}
