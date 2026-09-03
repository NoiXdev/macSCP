import Foundation

/// A third-party program's saved-connection store, read-only. Cyberduck is
/// the first conformer (`CyberduckBookmarkSource`); FileZilla and Transmit
/// are planned to add one each without changing anything else in this file.
public protocol BookmarkSource: Sendable {
    /// Stable identifier for this source, e.g. `"cyberduck"`. Written into
    /// `ExternalBookmark.source` and, on import, into
    /// `StoredSession.importSource` — never derived from `displayNameKey`,
    /// which is allowed to change with localization.
    static var id: String { get }
    /// Catalog key for the source's human-readable name, looked up through
    /// `CoreL10n.string(_:)`/`L10n.string(_:_:)` at the call site.
    static var displayNameKey: String { get }
    /// The source's default bookmark folder under `home`, if it exists.
    /// Returns `nil` when the source is not installed, or the folder is
    /// simply absent — never throws, so a preview can fall back to a
    /// folder picker without special-casing "not installed" as an error.
    func locate(home: URL) -> URL?
    /// Reads every bookmark file in `folder`. A single unparseable file
    /// yields an `ExternalBookmark` with `unreadable` set rather than
    /// failing the whole read; this only throws when `folder` itself
    /// cannot be listed (missing, unreadable, not a directory).
    func read(from folder: URL) throws -> [ExternalBookmark]
}
