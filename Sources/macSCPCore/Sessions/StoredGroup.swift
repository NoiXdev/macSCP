import Foundation

/// A flat session group shown as a collapsible sidebar section.
/// Deleting a group DISSOLVES it: member sessions become ungrouped,
/// they are never deleted with the group.
public struct StoredGroup: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var name: String

    public init(id: UUID = UUID(), name: String) {
        self.id = id
        self.name = name
    }
}
