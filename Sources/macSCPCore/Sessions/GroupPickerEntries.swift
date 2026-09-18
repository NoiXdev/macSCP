import Foundation

/// Every group, in the order the sidebar tree draws them, each labelled with
/// where it sits — the one list every place that CHOOSES a group reads.
///
/// A SwiftUI `Picker` cannot indent its rows, so a flat list of names says
/// nothing about where "Prod" sits when there are two of them. Each entry
/// therefore carries its full `path` ("Work / Prod") beside its `depth`, and
/// the choosing places label a row with the path.
///
/// Pure: no store, no UI. The rules are not restated here, they are read:
/// the parent-chain repair and the sibling order are `GroupTree`'s, the
/// exclusion of a folder's own subtree is `GroupTree.wouldCycle` (the check
/// `SidebarOrdering.moveTargets` applies, and which now reads this builder),
/// and the path separator is the one `SessionCatalog` prints for the CLI.
public enum GroupPickerEntries {
    public struct Entry: Sendable, Equatable, Identifiable {
        public let id: UUID
        /// 0 for a top-level group, one more per folder above it.
        public let depth: Int
        /// The group's own name.
        public let name: String
        /// Ancestors first, then the group itself, joined by
        /// `SessionCatalog.groupPathSeparator` — "Work / Prod".
        public let path: String
    }

    /// Every group in `groups`, depth-first, each level in
    /// `GroupTree.children` order.
    ///
    /// `groups` is repaired first (`GroupTree.repaired`): a group whose
    /// parent is missing, or whose parent chain closes a ring, is LIFTED to
    /// the top level rather than left unreachable by the walk — the rule the
    /// store applies on load, applied again here because this is a pure
    /// function and its caller need not hand it the store's own output.
    ///
    /// `excludedID` names a folder being moved: it and every group below it
    /// are left out, which is exactly the set `GroupTree.wouldCycle` refuses
    /// as a new parent for it. `nil`, the default, excludes nothing.
    public static func build(groups: [StoredGroup], excluding excludedID: UUID? = nil) -> [Entry] {
        let repaired = GroupTree.repaired(groups)
        var entries: [Entry] = []
        // `repaired` cuts every ring among distinct ids, but not one a
        // DUPLICATED id closes (two records named "A", one of them under a
        // child of the other): each id is listed, and walked, once.
        var listed: Set<UUID> = []
        func walk(_ parentID: UUID?, depth: Int, ancestry: [String]) {
            for group in GroupTree.children(of: parentID, in: repaired) {
                guard listed.insert(group.id).inserted else { continue }
                let names = ancestry + [group.name]
                if let excludedID,
                    GroupTree.wouldCycle(moving: excludedID, under: group.id, in: repaired)
                {
                    // Its subtree is excluded with it, and `wouldCycle` would
                    // say so of every descendant anyway: nothing to walk.
                    continue
                }
                entries.append(Entry(
                    id: group.id, depth: depth, name: group.name,
                    path: names.joined(separator: SessionCatalog.groupPathSeparator)))
                walk(group.id, depth: depth + 1, ancestry: names)
            }
        }
        walk(nil, depth: 0, ancestry: [])
        return entries
    }
}
