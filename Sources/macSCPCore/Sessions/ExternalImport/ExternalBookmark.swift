import Foundation

/// The protocol a `BookmarkSource` read from a third-party bookmark file,
/// translated to macSCP's own session kinds. `.unsupported` carries the
/// source's own protocol name (e.g. `"ftp"`, `"davs"`) so a preview can show
/// and count it without macSCP knowing what it means.
public enum ExternalProtocol: Sendable, Equatable {
    case sftp
    case s3
    case unsupported(String)
}

/// A single bookmark read from a third-party program, translated to the
/// source-independent shape `ImportPreviewPlanner` (Task 3) works with.
///
/// Contains NO secrets — passwords and S3 secret keys are never read from a
/// bookmark file; `CyberduckSecretReader` (Task 4) reads them from the
/// keychain separately, on request.
public struct ExternalBookmark: Sendable, Equatable, Identifiable {
    /// The source's own id for this bookmark (Cyberduck's `UUID`), or the
    /// file name when the file could not be parsed at all.
    public let id: String
    /// The `BookmarkSource.id` this bookmark came from (e.g. `"cyberduck"`).
    public let source: String
    /// `nil` when the file has no `Nickname` — the planner falls back to
    /// `host` for display; this reader never invents one.
    public let nickname: String?
    public let `protocol`: ExternalProtocol
    public let host: String
    /// `nil` when the file's `Port` is absent or not a valid integer.
    public let port: Int?
    public let username: String?
    /// Path to a private key file, referenced (never copied); only sftp
    /// bookmarks carry one.
    public let keyPath: String?
    /// The S3 bucket name; empty means bucket-list mode. `nil` for
    /// non-S3 bookmarks.
    public let path: String?
    public let labels: [String]
    /// The bookmark file's own name (e.g. `"11111111-....duck"`), kept
    /// alongside `id` so an unreadable row can still be shown and traced
    /// back to its file.
    public let fileName: String
    /// Set instead of the rest of the fields when the file could not be
    /// parsed as a bookmark at all (not a property list, not a dictionary).
    /// Carries the file name and the reason, e.g.
    /// `"malformed.duck: not a property list"`. Every other field is at
    /// its empty/nil default when this is set.
    public let unreadable: String?

    public init(
        id: String,
        source: String,
        nickname: String?,
        protocol: ExternalProtocol,
        host: String,
        port: Int?,
        username: String?,
        keyPath: String?,
        path: String?,
        labels: [String],
        fileName: String,
        unreadable: String?
    ) {
        self.id = id
        self.source = source
        self.nickname = nickname
        self.protocol = `protocol`
        self.host = host
        self.port = port
        self.username = username
        self.keyPath = keyPath
        self.path = path
        self.labels = labels
        self.fileName = fileName
        self.unreadable = unreadable
    }
}
