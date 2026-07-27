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

    public init(
        name: String,
        path: String,
        kind: RemoteFileKind,
        size: UInt64? = nil,
        modifiedAt: Date? = nil,
        permissions: UInt32? = nil
    ) {
        self.name = name
        self.path = path
        self.kind = kind
        self.size = size
        self.modifiedAt = modifiedAt
        self.permissions = permissions
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
}
