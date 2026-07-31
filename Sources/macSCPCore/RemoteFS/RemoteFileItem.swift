import Foundation

public enum RemoteFileKind: Equatable, Sendable {
    case file
    case directory
    case symlink
    case other
}

public struct RemoteFileItem: Equatable, Sendable {
    public let name: String
    public let path: String
    public let kind: RemoteFileKind
    public let size: UInt64?
    public let modifiedAt: Date?
    /// POSIX permission bits without the file-type bits, e.g. 0o644
    public let permissions: UInt32?
    /// Owner NAME where one could be resolved (remote: parsed from the
    /// listing's `longname`; local: `.fileOwnerAccountNameKey`), otherwise
    /// the numeric uid as a string, otherwise `nil` (M11m). See
    /// `LongnameParser` and `SFTPAttributeMapper` for the exact precedence.
    public let owner: String?
    /// Group NAME/numeric gid/`nil`, same precedence as `owner` (M11m).
    public let group: String?

    public init(
        name: String,
        path: String,
        kind: RemoteFileKind,
        size: UInt64? = nil,
        modifiedAt: Date? = nil,
        permissions: UInt32? = nil,
        owner: String? = nil,
        group: String? = nil
    ) {
        self.name = name
        self.path = path
        self.kind = kind
        self.size = size
        self.modifiedAt = modifiedAt
        self.permissions = permissions
        self.owner = owner
        self.group = group
    }

    public var isDirectory: Bool { kind == .directory }
}

/// `Identifiable` conformance for sheet presentation (M7b): `.sheet(item:)`
/// needs a stable identity, and the path already is one (unique within a
/// directory listing).
extension RemoteFileItem: Identifiable {
    public var id: String { path }
}

/// Expects absolute, single-slash-normalized paths (e.g. "/home/user/docs").
/// Behavior on other input (relative paths, double slashes, etc.) is unspecified.
public enum RemotePath {
    public static func join(_ base: String, _ component: String) -> String {
        base.hasSuffix("/") ? base + component : base + "/" + component
    }

    public static func parent(of path: String) -> String {
        guard path != "/" else { return "/" }
        let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
        guard let idx = trimmed.lastIndex(of: "/") else { return "/" }
        let parent = String(trimmed[..<idx])
        return parent.isEmpty ? "/" : parent
    }

    /// Collapses any run of consecutive slashes and drops every trailing
    /// slash; the empty string and the root both normalize to `"/"`. Unlike
    /// every other function in this type, `normalizedAbsolute` is
    /// deliberately the ONE `RemotePath` function that IS safe on hostile,
    /// hand-typed input (repeated slashes, a trailing slash, the empty
    /// string) — the "behavior on other input is unspecified" caveat in this
    /// type's doc comment does not apply here. The path bar's completion
    /// (`PathCompletion.directoryToList`) and its `navigate(to:)` both route
    /// through this single normalizer instead of each carrying its own copy.
    public static func normalizedAbsolute(_ path: String) -> String {
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        return components.isEmpty ? "/" : "/" + components.joined(separator: "/")
    }
}
