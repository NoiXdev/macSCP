import Foundation

/// Pure, testable projection from `SnippetMenuModel` to what a flat,
/// scrollable list needs per row (P3d, Task 1): the same tag grouping the
/// menu surfaces use, plus one decision no view body should make on its
/// own — whether a row's actions are available right now. Kept apart from
/// any view precisely so a test can assert against this shape directly; in
/// two earlier phases that same kind of decision, left inside a SwiftUI
/// body, produced an empty window and then made empty groups vanish.
///
/// Lives in Core, not beside `SnippetMenuPlan` (`MacSCPAppKit`): this
/// projection needs nothing SwiftUI provides — no `Menu`, no
/// `KeyEquivalent`, no menu-specific shortcut bookkeeping — so it stays
/// with `SnippetMenuModel` itself rather than crossing into the App layer
/// for no reason.
public enum SnippetListPlan {
    /// One row the flat list draws.
    public struct Row: Identifiable, Equatable, Sendable {
        public let snippet: Snippet
        /// The text a row shows for itself. Currently always
        /// `snippet.name`, carried as its own field (rather than making
        /// every caller reach into `snippet`) so a future naming rule
        /// (truncation, a fallback for an empty name) has one place to
        /// live.
        public let displayName: String
        /// Whether this row's actions (insert/execute) are available. Taken
        /// directly from `SnippetMenuModel.disabledReason` — see that
        /// type's `build` doc comment for how it decides `notConnected`
        /// versus `backendHasNoShell`; this projection does not re-derive
        /// that decision, only carries its result.
        public let isDisabled: Bool
        public var id: Snippet.ID { snippet.id }
    }

    /// One section of the flat list: a tag heading (`nil` for the trailing,
    /// untagged section) and its rows, in the same order
    /// `SnippetMenuModel.groups` already computed (tag-sorted, untagged
    /// last). Never produced with empty `rows` — a heading with nothing
    /// under it would be exactly the kind of view-body bug this type exists
    /// to prevent.
    public struct Section: Identifiable, Equatable, Sendable {
        public let tag: String?
        public let rows: [Row]
        public var id: String { tag ?? "" }
    }

    /// Projects `model.groups` into flat-list sections.
    ///
    /// `SnippetMenuModel` deliberately lists a snippet with two tags once
    /// per tag — in a menu that duplication is harmless, since the two
    /// occurrences live in two different submenus a user only ever sees
    /// one of at a time. `SnippetMenuPlan` (the menu's own projection)
    /// keeps that duplication for exactly that reason.
    ///
    /// A flat, scrollable list has no submenu boundary to explain a repeat:
    /// the same name and command would appear twice in one continuously
    /// visible list, which reads as a bug, not as grouping. It would also
    /// undercut arrow-key navigation (the spec's stated reason for making
    /// a single click select-only) — the same row would occupy two
    /// positions with no way to tell, from either one, that the other is
    /// "the same snippet". So THIS projection shows each snippet at most
    /// ONCE: on the first section that would otherwise have produced it
    /// (in `model.groups`' own order — tag-sorted alphabetically, untagged
    /// last), with later occurrences dropped. If dedup would leave a later
    /// section with no rows at all (every one of its snippets already
    /// surfaced earlier), that section is omitted rather than rendered
    /// empty.
    public static func build(model: SnippetMenuModel) -> [Section] {
        let isDisabled = model.disabledReason != nil
        var seen = Set<Snippet.ID>()
        return model.groups.compactMap { group -> Section? in
            let rows = group.snippets.compactMap { snippet -> Row? in
                guard seen.insert(snippet.id).inserted else { return nil }
                return Row(snippet: snippet, displayName: snippet.name, isDisabled: isDisabled)
            }
            guard !rows.isEmpty else { return nil }
            return Section(tag: group.tag, rows: rows)
        }
    }
}
