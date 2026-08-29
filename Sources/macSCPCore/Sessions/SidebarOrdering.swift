import Foundation

/// One row of the sidebar tree, named the only way a drop can name it: by
/// identity. A folder and a connection are the two things that can be picked
/// up and the two things that can be dropped on, and every ordering question
/// below is asked in terms of this type rather than in terms of a row number.
public enum SidebarItem: Hashable, Identifiable, Sendable {
    case group(UUID)
    case session(UUID)

    /// Group ids and session ids are drawn from disjoint sets, so the bare id
    /// identifies the row on its own — which is what lets a view use this as
    /// its `ForEach` identity without inventing a second one.
    public var id: UUID {
        switch self {
        case .group(let id), .session(let id): id
        }
    }
}

/// Where the sidebar's rows sit and in which order — computed as pure values,
/// written by nobody but the caller.
///
/// ## Why nothing here takes an index
///
/// The tab strip answered this question first, and the answer is binding
/// rather than stylistic: `TabsViewModel.move(tabID:to:)` and
/// `move(tabID:onto:)` derive the destination from two identities because the
/// index carried through a view WAS the defect class — a number can be
/// shifted by a step, shadowed by a name, or clamped in an initializer, and
/// each of those changes where a row lands while the surrounding code reads
/// exactly as it did. An identity has no arithmetic. Both gestures the design
/// names — dropping between two siblings and dropping onto a folder — arrive
/// here as a pair of identities, and the position is derived in the same
/// instant it is used.
///
/// ## What "position" promises
///
/// `StoredGroup.position` and `StoredSession.position` rank a row among the
/// children of ONE parent, and a write renumbers the parents it touched so
/// their children run `0..<n`: gapless, unique, and therefore a total order
/// every later reader can rely on. A parent the write did not touch is left
/// exactly as it was — renumbering the whole file would rewrite the order of
/// folders the user never opened.
///
/// Every file on disk today predates the field and carries nothing but
/// zeroes. Equal positions therefore fall back to INPUT order, the same rule
/// `GroupTree.children(of:in:)` already states for groups, so an unordered
/// file reads back exactly as its caller handed it over.
public enum SidebarOrdering {
    /// The two arrays that make up the tree, carried together because every
    /// operation here answers about both: a folder and a connection are
    /// siblings under the same parent, and a move rewrites whichever of the
    /// two the dragged row belongs to.
    public struct Tree: Equatable, Sendable {
        public var groups: [StoredGroup]
        public var sessions: [StoredSession]

        public init(groups: [StoredGroup], sessions: [StoredSession]) {
            self.groups = groups
            self.sessions = sessions
        }
    }

    /// What a move did, said out loud. A refusal returns no tree at all, so a
    /// caller cannot mistake "nothing changed" for "changed into the same
    /// thing" — and cannot forget to tell the user which of the two happened.
    public enum MoveOutcome: Equatable, Sendable {
        case moved(Tree)
        case refused(MoveRefusal)
    }

    /// Why a move did not happen.
    ///
    /// `wouldCycle` is the only one a user can provoke on purpose and the
    /// only one worth a message: a folder cannot be moved inside itself. The
    /// other two are stale gestures — the dragged row or the row it was
    /// dropped on was deleted somewhere else while the drag was in the air —
    /// and they are ordinary outcomes, exactly as an out-of-range drop is for
    /// the tab strip.
    public enum MoveRefusal: Equatable, Sendable {
        case wouldCycle
        case noSuchItem
        case noSuchTarget
    }

    /// The direct children of `parentID` (`nil` = the top level), in the
    /// order the sidebar shows them: by position, and — for the zeroes an
    /// unordered file is full of — folders first, then connections, each in
    /// the order the caller passed them.
    public static func children(of parentID: UUID?, in tree: Tree) -> [SidebarItem] {
        let groups = GroupTree.children(of: parentID, in: tree.groups)
        let sessions = tree.sessions.enumerated()
            .filter { $0.element.groupID == parentID }
            .sorted {
                $0.element.position == $1.element.position
                    ? $0.offset < $1.offset
                    : $0.element.position < $1.element.position
            }
            .map(\.element)

        // Both lists are already ordered; merging on (position, kind) with
        // the within-list rank as the last key keeps that order intact.
        var rows: [(position: Int, kind: Int, rank: Int, item: SidebarItem)] = []
        for (rank, group) in groups.enumerated() {
            rows.append((group.position, 0, rank, .group(group.id)))
        }
        for (rank, session) in sessions.enumerated() {
            rows.append((session.position, 1, rank, .session(session.id)))
        }
        return rows
            .sorted { ($0.position, $0.kind, $0.rank) < ($1.position, $1.kind, $1.rank) }
            .map(\.item)
    }

    /// Moves `item` to the place `target` holds right now — the drop phrased
    /// in the only two things it knows: which row was picked up, and which
    /// row it was let go on. `item` lands immediately before `target` and
    /// adopts `target`'s parent, so one gesture expresses both reordering and
    /// moving between folders.
    public static func moved(
        _ item: SidebarItem, before target: SidebarItem, in tree: Tree
    ) -> MoveOutcome {
        guard let origin = parent(of: item, in: tree) else { return .refused(.noSuchItem) }
        // Dropping a row on itself is a gesture the user can make and means
        // nothing; it is not a stale target.
        guard item != target else { return .moved(tree) }
        guard let destination = parent(of: target, in: tree) else {
            return .refused(.noSuchTarget)
        }
        if refusesCycle(item, under: destination, in: tree) { return .refused(.wouldCycle) }

        var order = children(of: destination, in: tree).filter { $0 != item }
        guard let slot = order.firstIndex(of: target) else { return .refused(.noSuchTarget) }
        order.insert(item, at: slot)
        return .moved(rewritten(order, under: destination, leaving: origin, of: item, in: tree))
    }

    /// Moves `item` into `parentID` (`nil` = the top level), at the end of
    /// what is already there — the design's second gesture, dropping onto a
    /// folder rather than between two rows.
    public static func moved(
        _ item: SidebarItem, intoGroup parentID: UUID?, in tree: Tree
    ) -> MoveOutcome {
        guard let origin = parent(of: item, in: tree) else { return .refused(.noSuchItem) }
        if let parentID, !tree.groups.contains(where: { $0.id == parentID }) {
            return .refused(.noSuchTarget)
        }
        if refusesCycle(item, under: parentID, in: tree) { return .refused(.wouldCycle) }

        var order = children(of: parentID, in: tree).filter { $0 != item }
        order.append(item)
        return .moved(rewritten(order, under: parentID, leaving: origin, of: item, in: tree))
    }

    /// The one-shot sort: the IMMEDIATE children of `parentID` by name, their
    /// positions rewritten. Exactly one level deep — sorting the subtree
    /// behind a single menu entry would be a bulk change of folders the user
    /// cannot see from where they clicked.
    ///
    /// The comparison is not a new one. `SessionListViewModel.reload` sorts
    /// the sidebar's sessions with `localizedCaseInsensitiveCompare`, and
    /// that is what is used here; a second spelling of "by name" would be a
    /// second answer to the same question. Equal names keep their current
    /// order, so the result does not depend on the sort's stability.
    public static func sortedByName(childrenOf parentID: UUID?, in tree: Tree) -> Tree {
        let order = children(of: parentID, in: tree).enumerated()
            .sorted { lhs, rhs in
                let byName = name(of: lhs.element, in: tree)
                    .localizedCaseInsensitiveCompare(name(of: rhs.element, in: tree))
                return byName == .orderedSame ? lhs.offset < rhs.offset : byName == .orderedAscending
            }
            .map(\.element)
        var result = tree
        renumber(order, under: parentID, in: &result)
        return result
    }

    /// Dissolves a group: its members — sessions AND sub-folders — move to
    /// the group's own parent, into the slot the group occupied, and the
    /// receiving parent is renumbered around them.
    ///
    /// This is the flat rule written out rather than a new one. `groupID =
    /// nil` was never "no group" as such: for a top-level group it is one
    /// level up, and one level up from a nested group is its parent. Nothing
    /// is deleted here — not a session, not a sub-folder.
    ///
    /// Note what this is NOT: `GroupTree.repaired(_:)` lifts a BROKEN group
    /// to the top level, which is the right answer to damage and the wrong
    /// answer to a dissolve. A group whose members were lifted to the top
    /// level instead of to their parent would have moved somewhere the user
    /// did not ask for, silently.
    ///
    /// A `groupID` naming no group is not an error: whatever still points at
    /// it is moved to the top level, which is where the store's load-time
    /// hygiene puts it anyway.
    public static func dissolving(_ groupID: UUID, in tree: Tree) -> Tree {
        let destination = tree.groups.first { $0.id == groupID }?.parentID
        let lifted = children(of: groupID, in: tree)

        var result = tree
        result.groups.removeAll { $0.id == groupID }

        var order: [SidebarItem] = []
        var spliced = false
        for item in children(of: destination, in: tree) {
            if item == .group(groupID) {
                order.append(contentsOf: lifted)
                spliced = true
            } else {
                order.append(item)
            }
        }
        if !spliced { order.append(contentsOf: lifted) }

        renumber(order, under: destination, in: &result)
        return result
    }

    // MARK: - Deriving

    /// `item`'s parent, or `nil` when `item` names no row in this tree. The
    /// value is itself Optional — a row at the top level answers
    /// `.some(nil)` — which is how a lookup tells "top level" apart from "not
    /// here at all", the same distinction `GroupTree` draws for parents.
    private static func parent(of item: SidebarItem, in tree: Tree) -> UUID?? {
        switch item {
        case .group(let id): tree.groups.first { $0.id == id }.map(\.parentID)
        case .session(let id): tree.sessions.first { $0.id == id }.map(\.groupID)
        }
    }

    private static func name(of item: SidebarItem, in tree: Tree) -> String {
        switch item {
        case .group(let id): tree.groups.first { $0.id == id }?.name ?? ""
        case .session(let id): tree.sessions.first { $0.id == id }?.name ?? ""
        }
    }

    /// Only a folder can become its own ancestor, and only `GroupTree` says
    /// when — the import path answers to the same function, so the drag and a
    /// foreign file cannot disagree about what a cycle is.
    private static func refusesCycle(
        _ item: SidebarItem, under parentID: UUID?, in tree: Tree
    ) -> Bool {
        guard case .group(let id) = item else { return false }
        return GroupTree.wouldCycle(moving: id, under: parentID, in: tree.groups)
    }

    /// Applies `order` to `destination` and renumbers the parent `item` came
    /// from, which lost a member and would otherwise keep a gap where it sat.
    /// When both are the same parent, `order` already covers it.
    private static func rewritten(
        _ order: [SidebarItem], under destination: UUID?,
        leaving origin: UUID?, of item: SidebarItem, in tree: Tree
    ) -> Tree {
        var result = tree
        renumber(order, under: destination, in: &result)
        if origin != destination {
            renumber(children(of: origin, in: tree).filter { $0 != item }, under: origin, in: &result)
        }
        return result
    }

    /// Writes `order` out: every row named there sits under `parentID` at its
    /// own rank. This is the whole of the gapless-and-unique guarantee, and
    /// it is deliberately the only place that assigns a position.
    private static func renumber(_ order: [SidebarItem], under parentID: UUID?, in tree: inout Tree) {
        for (position, item) in order.enumerated() {
            switch item {
            case .group(let id):
                guard let index = tree.groups.firstIndex(where: { $0.id == id }) else { continue }
                tree.groups[index].parentID = parentID
                tree.groups[index].position = position
            case .session(let id):
                guard let index = tree.sessions.firstIndex(where: { $0.id == id }) else { continue }
                tree.sessions[index].groupID = parentID
                tree.sessions[index].position = position
            }
        }
    }
}
