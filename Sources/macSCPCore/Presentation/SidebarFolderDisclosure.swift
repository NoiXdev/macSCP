import Foundation

/// Whether one sidebar folder draws open, and what the remembered collapse
/// state becomes when the user works its disclosure triangle (D3).
///
/// Two states meet here and the whole point is that they stay apart: "the
/// user closed this folder", which is remembered, and "the tree is drawn open
/// because a search is narrowing it", which is not. The search OVERLAYS the
/// remembered state — it is ignored while the search field carries a query
/// that filters, and it is back the moment the field is empty.
///
/// That separation is the condition the maintainer's ruling rests on: a
/// search that permanently unfolded someone's folders would have rearranged
/// their sidebar without them asking. It lives here rather than inside a
/// `Binding` in a view body because a rule written into a closure is a rule
/// no test reaches — the same reason `SidebarVisibility` exists at all.
public enum SidebarFolderDisclosure {
    /// Whether the folder draws open.
    ///
    /// `expandsFolders` (from `SidebarVisibility`) wins over anything
    /// remembered: a match inside a folder the user closed is filtered and
    /// still invisible, which is the one thing nesting made worse about
    /// filtering.
    public static func isOpen(
        _ groupID: UUID, collapsed: Set<UUID>, expandsFolders: Bool
    ) -> Bool {
        expandsFolders || !collapsed.contains(groupID)
    }

    /// The remembered collapse state after the user opened or closed one
    /// folder — or `nil` when nothing may be written at all.
    ///
    /// `nil` is not "collapse nothing": it is "do not write". While a search
    /// draws the tree open, every folder reports itself open, so a triangle
    /// working against that would record a collapse the user never made
    /// against a folder they never saw closed. Returning the decision instead
    /// of mutating in place is what lets the caller have no opinion of its
    /// own about when to write.
    public static func collapsed(
        _ collapsed: Set<UUID>, setting groupID: UUID, open: Bool, expandsFolders: Bool
    ) -> Set<UUID>? {
        guard !expandsFolders else { return nil }
        var updated = collapsed
        if open {
            updated.remove(groupID)
        } else {
            updated.insert(groupID)
        }
        return updated
    }
}
