import Foundation

/// A session group shown as a collapsible sidebar section, and — since
/// `parentID` — a node in a tree of arbitrary depth.
/// Deleting a group DISSOLVES it: member sessions become ungrouped,
/// they are never deleted with the group.
public struct StoredGroup: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var name: String
    /// The group this group sits inside, if any. `nil` = top level.
    ///
    /// No artificial depth limit, which is what buys the cycle check in
    /// `GroupTree`: a group must never become its own ancestor. A parent that
    /// is absent from the same list is not an error either — `GroupTree`
    /// lifts such a group to the top level rather than dropping it.
    public var parentID: UUID?
    /// Rank among the siblings under the same parent, renumbered on write.
    ///
    /// Deliberately a number ON the element rather than the array order of
    /// the file: `SessionListViewModel.save` upserts by NAME and import and
    /// filtering rebuild the list wholesale, so array order is a property of
    /// a code path nobody promised and no test would notice breaking.
    public var position: Int

    public init(id: UUID = UUID(), name: String, parentID: UUID? = nil, position: Int = 0) {
        self.id = id
        self.name = name
        self.parentID = parentID
        self.position = position
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, parentID, position
    }

    /// Explicit rather than synthesized, and the reason is `position` alone.
    ///
    /// Synthesized `Codable` does NOT fall back to a property's default value
    /// for a MISSING key — it throws `keyNotFound`. Every `sessions-v2.json`
    /// on disk today predates this field, so a synthesized decoder plus
    /// `var position: Int = 0` would make the store unreadable for every
    /// existing installation. `decodeIfPresent ?? 0` is what makes this
    /// migration additive, and it is why the format needs no new file name.
    ///
    /// The alternative — an optional stored property behind a non-optional
    /// computed accessor — was not taken: it would move the `?? 0` from one
    /// place in the decoder to the type's surface, and `StoredSession` next
    /// door already spells this same default for `kind` and `paneVisibility`
    /// in exactly this way.
    ///
    /// `parentID` needs no such care: an Optional decodes as `nil` when its
    /// key is absent, and `decodeIfPresent` here only says so out loud.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        parentID = try c.decodeIfPresent(UUID.self, forKey: .parentID)
        position = try c.decodeIfPresent(Int.self, forKey: .position) ?? 0
    }
}
