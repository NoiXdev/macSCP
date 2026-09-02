import Foundation
import macSCPCore

/// What the info sheet's permissions block IS, decided from the two answers
/// that feed it and from nothing else.
///
/// The two answers are different questions. Whether the BACKEND has a
/// permission model the editor speaks is the capability
/// (`PermissionsAvailability`), a statement about what `setPermissions` can
/// do. Whether THIS ENTRY came with bits is the listing. Each absence has
/// its own sentence, because "this server has no file permissions" and
/// "this entry did not come with any" are not the same fact — and the first
/// used to be shown as the second, by the accident of every S3 and WebDAV
/// listing leaving the field nil.
///
/// A value rather than an `if` in the view, for the reason `ChecksumDisplay`
/// gives: what the app says for each pair of answers is then decidable
/// without rendering anything (`PermissionsPresentationTests`), and the
/// Apply button and the block it belongs to read one decision instead of
/// two conditions that could drift apart.
enum PermissionsPresentation: Equatable, Sendable {
    /// The rwx grid, the octal field, and Apply.
    case editor
    /// The backend has no permission model the editor speaks. This wins
    /// over the entry: bits in a listing say nothing about what can be
    /// applied.
    case unavailableOnThisServer
    /// A POSIX backend whose listing carried no bits for this entry.
    case unavailableForThisEntry

    static func of(supportsPermissions: Bool, permissions: UInt32?) -> PermissionsPresentation {
        guard supportsPermissions else { return .unavailableOnThisServer }
        return permissions == nil ? .unavailableForThisEntry : .editor
    }

    /// The title of the menu entry that opens the sheet. It names what the
    /// sheet holds: "Info & Permissions" where the backend has a permission
    /// model, "Info" where it has none — the entry stays either way,
    /// because size, dates and checksum live in that sheet regardless, but
    /// a title promising an editor the sheet then explains away would be
    /// the disabled control in another place.
    static func infoMenuTitle(supportsPermissions: Bool) -> String {
        supportsPermissions
            ? L10n.string("menu.info", "Info & Permissions…")
            : L10n.string("menu.infoOnly", "Info…")
    }

    /// The sentence that stands where the editor would — or nil where the
    /// editor stands.
    var sentence: String? {
        switch self {
        case .editor:
            return nil
        case .unavailableOnThisServer:
            return L10n.string(
                "info.permissionsUnavailableOnThisServer",
                "This server does not have file permissions.")
        case .unavailableForThisEntry:
            return L10n.string(
                "info.permissionsUnavailable",
                "Permissions are not available for this entry.")
        }
    }
}
