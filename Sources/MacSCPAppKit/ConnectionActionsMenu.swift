import SwiftUI
import macSCPCore

/// The toolbar menu that renders the active session's connection-level
/// actions (S3 bucket settings, Task 7): the list its backend's descriptor
/// carries in `connectionActions`, titled from the catalogue.
///
/// The view reads the descriptor and nothing else -- never a `ConnectionKind`
/// -- so a fourth backend that fills its own list appears here without a line
/// changing. A backend with an empty list draws NOTHING: `isPresented(for:)`
/// is what the toolbar asks before it constructs this view at all, because an
/// empty `Menu` is a capsule with nothing behind it.
///
/// Declares no width of its own, so it is not a `BoundedView`: the toolbar
/// sizes a menu from its label, and the rows are sized by AppKit.
struct ConnectionActionsMenu: View {
    let descriptor: BackendDescriptor

    /// Whether THIS row can be carried out now. A row for which it answers
    /// `false` is DISABLED rather than enabled and inert -- an entry that
    /// looks live and does nothing is the worse of the two failures
    /// (`PaneToggleState` makes the same choice for the pane toggles).
    ///
    /// Per row, not one flag for the menu: the rows are wired one at a time,
    /// and a row's availability can depend on the connection. The window
    /// answers it from `ConnectionActionRoute`.
    let isAvailable: (ConnectionActionContribution) -> Bool

    /// What choosing an action does. Called only for a row `isAvailable`
    /// allowed, since a disabled button does not fire.
    let onSelect: (ConnectionActionContribution) -> Void

    /// The catalogue keys of the menu's own label and its tooltip. Named here
    /// so the tests that hold them to all four languages read them rather than
    /// spell them.
    static let labelKey = "connection.actions.menu"
    static let helpKey = "connection.actions.menuHelp"

    /// Whether the toolbar draws this menu for `descriptor` at all.
    static func isPresented(for descriptor: BackendDescriptor) -> Bool {
        !descriptor.connectionActions.isEmpty
    }

    var body: some View {
        Menu {
            ForEach(descriptor.connectionActions) { action in
                Button {
                    onSelect(action)
                } label: {
                    Label(
                        L10n.string(action.titleKey, action.titleDefault),
                        systemImage: action.systemImage)
                }
                .disabled(!isAvailable(action))
            }
        } label: {
            Label(
                L10n.string(Self.labelKey, "Connection Actions"),
                systemImage: "ellipsis.circle")
        }
        .help(L10n.string(Self.helpKey, "Manage this connection"))
    }
}
