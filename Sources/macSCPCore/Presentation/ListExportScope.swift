import Foundation

/// What an "Export…" button in a list's footer covers.
///
/// One rule for every such footer: the selection when it is one of the rows
/// currently on screen, otherwise every row on screen. The membership check
/// is what keeps a selection the search has filtered away from silently
/// widening — or narrowing — the scope, since a list's selection outlives
/// its filter.
///
/// Lives here rather than in a sheet so the two sheets that offer this
/// button cannot drift apart: a rule that lived in only one of the two
/// sheets is how "Export" came to mean two different things.
public enum ListExportScope {
    public static func resolve<Item: Identifiable>(
        selectedID: Item.ID?, from visible: [Item]
    ) -> [Item] {
        guard let selectedID, let selected = visible.first(where: { $0.id == selectedID })
        else { return visible }
        return [selected]
    }
}
