import SwiftUI

/// The file actions a management sheet's footer keeps behind its three-dot
/// menu (backlog 2026-08-20, point 5).
///
/// The rule that decides what belongs here: **selection actions stay
/// visible, file actions move under the menu.** New/Edit/Delete act on the
/// row selected in the list; Export/Import act on a file on disk. What
/// follows from it is the part worth writing down — "Delete…" would save
/// footer width just as well, but hiding a destructive action is the wrong
/// economy, so it stays a visible button.
///
/// That exception is why this is an enumeration and not a list of labels
/// each footer passes in: `SheetOverflowMenu` renders these cases and
/// nothing else, so a destructive entry has no representation to reach the
/// menu with. Two cases, counted in this pass.
enum SheetOverflowAction: String, CaseIterable, Identifiable {
    case export
    case `import`

    var id: String { rawValue }

    var labelKey: String {
        switch self {
        case .export: return "sheets.export"
        case .import: return "sheets.import"
        }
    }

    var labelDefault: String {
        switch self {
        case .export: return "Export…"
        case .import: return "Import…"
        }
    }

    /// The actions a footer can offer right now, in fixed order.
    ///
    /// An action that cannot apply is ABSENT, not disabled: the login sheet
    /// offers no export while a search matches nothing, and the keys sheet
    /// offers none at all — its per-key exports live in the row.
    static func offered(canExport: Bool, canImport: Bool) -> [SheetOverflowAction] {
        allCases.filter { action in
            switch action {
            case .export: return canExport
            case .import: return canImport
            }
        }
    }
}

/// The three-dot menu itself, drawn immediately left of a sheet footer's
/// "Close" button.
///
/// Symbol only, no word — which makes `help` and `accessibilityLabel`
/// mandatory rather than optional. They are different affordances sharing
/// one key, following `SettingsView`'s remove-rule button: the former
/// produces the hover tooltip, the latter is what VoiceOver announces
/// instead of the SF Symbol's name.
struct SheetOverflowMenu: View {
    /// `nonisolated`, because a `View` is `@MainActor` and these two are
    /// read by tests that are not. They are immutable strings with nothing
    /// actor-relevant about them, so the isolation buys nothing and costs a
    /// warning — and this project's CI fails above one warning location.
    nonisolated static let menuLabelKey = "sheets.moreActions"
    nonisolated static let menuLabelDefault = "More actions"

    let actions: [SheetOverflowAction]
    let perform: (SheetOverflowAction) -> Void

    private var menuLabel: String { L10n.string(Self.menuLabelKey, Self.menuLabelDefault) }

    var body: some View {
        // Nothing possible means no control at all, for the same reason an
        // impossible action is absent rather than greyed out: a menu that
        // opens onto nothing is a promise the footer cannot keep.
        if !actions.isEmpty {
            Menu {
                ForEach(actions) { action in
                    Button(L10n.string(action.labelKey, action.labelDefault)) { perform(action) }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuIndicator(.hidden)
            .fixedSize()
            .help(menuLabel)
            .accessibilityLabel(menuLabel)
        }
    }
}
