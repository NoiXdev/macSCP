import Foundation

/// The rules of the group tree, as pure values: who may move under whom,
/// what a damaged parent chain becomes, and in which order siblings appear.
///
/// No file access and no UI. `StoredGroup.parentID` allows arbitrary depth,
/// which is exactly what makes a cycle expressible — a group that is its own
/// ancestor — and a foreign file can carry one in without the sidebar ever
/// being involved. Deciding that here keeps the check testable, and keeps the
/// import path and the drag path answering to the same rule instead of two
/// spellings of it.
///
/// The repair rule follows the project's "additive, never destructive" line:
/// a group whose parent is missing, or whose parent chain closes a cycle, is
/// LIFTED to the top level. Nothing is ever discarded.
public enum GroupTree {
    /// Would making `newParentID` the parent of `groupID` make `groupID` its
    /// own ancestor?
    ///
    /// Moving to the top level (`newParentID == nil`) can never cycle, and a
    /// group cannot be its own parent.
    ///
    /// A cycle that ALREADY exists among the groups and does not contain
    /// `groupID` is not this function's business: the walk stops on it and
    /// answers `false`, because the proposed move is not what would create
    /// it. `repaired(_:)` is what removes such a cycle.
    public static func wouldCycle(
        moving groupID: UUID, under newParentID: UUID?, in groups: [StoredGroup]
    ) -> Bool {
        guard let newParentID else { return false }
        if newParentID == groupID { return true }
        let parents = parentByID(groups)
        var seen: Set<UUID> = []
        var cursor: UUID? = newParentID
        while let id = cursor {
            if id == groupID { return true }
            guard seen.insert(id).inserted else { return false }
            cursor = parents[id] ?? nil
        }
        return false
    }

    /// Does any group in `groups` reach itself by following `parentID`?
    public static func hasCycle(_ groups: [StoredGroup]) -> Bool {
        let parents = parentByID(groups)
        var settled: Set<UUID> = []
        for group in groups {
            var walked: [UUID] = []
            var seen: Set<UUID> = []
            var cursor: UUID? = group.id
            while let id = cursor {
                if settled.contains(id) { break }
                guard seen.insert(id).inserted else { return true }
                walked.append(id)
                cursor = parents[id] ?? nil
            }
            settled.formUnion(walked)
        }
        return false
    }

    /// The same groups, with every broken parent link lifted to the top
    /// level. NEVER drops a group: the returned array holds exactly the input
    /// groups, in input order, differing only in `parentID`.
    ///
    /// Two damages are repaired, and both arrive the same way — through an
    /// export written by another installation, or an older one written before
    /// `parentID` existed:
    ///
    /// - a `parentID` naming a group that is not in this list at all: the
    ///   child is lifted;
    /// - a cycle: the first member of it the walk reaches is lifted, which
    ///   breaks the ring while leaving every other link intact.
    ///
    /// Lifting the first member REACHED, rather than the group the walk
    /// started from, matters when the start is merely an innocent descendant
    /// hanging off a ring: it keeps its own parent, and only the ring is cut.
    public static func repaired(_ groups: [StoredGroup]) -> [StoredGroup] {
        var result = groups
        let known = Set(groups.map(\.id))
        var indexByID: [UUID: Int] = [:]
        for (index, group) in result.enumerated() { indexByID[group.id] = index }

        for index in result.indices {
            guard let parent = result[index].parentID, !known.contains(parent) else { continue }
            result[index].parentID = nil
        }

        // `settled` carries over between walks: an id whose chain has already
        // been proven to terminate cannot be part of a cycle, so a later walk
        // that reaches it can stop there.
        var settled: Set<UUID> = []
        for start in result.indices {
            var walked: [UUID] = []
            var seen: Set<UUID> = []
            var cursor: Int? = start
            while let index = cursor {
                let id = result[index].id
                if settled.contains(id) { break }
                guard seen.insert(id).inserted else {
                    result[index].parentID = nil
                    break
                }
                walked.append(id)
                cursor = result[index].parentID.flatMap { indexByID[$0] }
            }
            settled.formUnion(walked)
        }
        return result
    }

    /// The direct children of `parentID` (`nil` = the top level), in position
    /// order. Equal positions keep their order in `groups`, so the answer is
    /// deterministic even for a file whose positions were never written.
    public static func children(of parentID: UUID?, in groups: [StoredGroup]) -> [StoredGroup] {
        groups.enumerated()
            .filter { $0.element.parentID == parentID }
            .sorted {
                $0.element.position == $1.element.position
                    ? $0.offset < $1.offset
                    : $0.element.position < $1.element.position
            }
            .map(\.element)
    }

    /// `parentID` by group id. The value is itself Optional — a group present
    /// with no parent maps to `.some(nil)` — which is how a lookup tells "top
    /// level" apart from "not in this list".
    private static func parentByID(_ groups: [StoredGroup]) -> [UUID: UUID?] {
        var parents: [UUID: UUID?] = [:]
        for group in groups { parents[group.id] = group.parentID }
        return parents
    }
}
