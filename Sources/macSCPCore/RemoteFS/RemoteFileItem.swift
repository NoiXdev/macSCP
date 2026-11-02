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
    /// listing's `longname`; local: `FileManager.attributesOfItem(atPath:)`'s
    /// `.ownerAccountName`), otherwise the numeric uid as a string, otherwise
    /// `nil` (M11m). See `LongnameParser` and `SFTPAttributeMapper` for the
    /// exact precedence.
    public let owner: String?
    /// Group NAME/numeric gid/`nil`, same precedence as `owner` (M11m).
    public let group: String?
    /// Whether this row is an S3 bucket (Browser Type Column, 2026-09-04):
    /// `S3ListParser.parseBuckets` is the one place that sets it `true`. A
    /// bucket's `kind` is still `.directory` — a bucket IS a kind of
    /// directory — so `isBucket` is the only way to tell a bucket row apart
    /// from an ordinary folder; see `FileTypeLabel`, which checks it first.
    /// Defaults to `false` so every existing call site keeps compiling
    /// unchanged.
    public let isBucket: Bool
    /// The version id of the delete marker that hides this key, for a row
    /// that stands for a DELETED key (S3 version history, Task 10); `nil` for
    /// every ordinary row. Such a row exists only while the browser's
    /// `showDeletedFiles` switch is on, and removing that marker
    /// (`ObjectVersionProvider.liftDeleteMarker`) is what brings the key back,
    /// so the row carries the id and the restore needs no second listing.
    /// `isDeleted` is derived from it, so the two cannot disagree. Defaults to
    /// `nil` so every existing call site keeps compiling unchanged.
    public let deleteMarkerVersionID: String?

    public init(
        name: String,
        path: String,
        kind: RemoteFileKind,
        size: UInt64? = nil,
        modifiedAt: Date? = nil,
        permissions: UInt32? = nil,
        owner: String? = nil,
        group: String? = nil,
        isBucket: Bool = false,
        deleteMarkerVersionID: String? = nil
    ) {
        self.name = name
        self.path = path
        self.kind = kind
        self.size = size
        self.modifiedAt = modifiedAt
        self.permissions = permissions
        self.owner = owner
        self.group = group
        self.isBucket = isBucket
        self.deleteMarkerVersionID = deleteMarkerVersionID
    }

    public var isDirectory: Bool { kind == .directory }

    /// Whether this row stands for a key that a delete marker hides. Such a
    /// row has no content to read, rename, move or delete: the one thing that
    /// can be done with it is to lift the marker.
    public var isDeleted: Bool { deleteMarkerVersionID != nil }
}

extension RemoteFileItem {
    /// The rows for the deleted keys of ONE directory: `entries` are the keys
    /// directly under `keyPrefix` (`""` at the bucket root, otherwise the
    /// folder's key with its trailing `/`), and `path` is the directory's own
    /// path in the pane, so each row's path is the one the plain listing would
    /// have given the key.
    ///
    /// A row's name is the key after the prefix. An entry with no such part, one
    /// outside the prefix, or one that reaches into a sub-folder is not a row of
    /// this directory and is dropped: `S3FileSystem.deletedEntries` already
    /// refuses all three, and this is the second line of defence for another
    /// provider. A row is a file with no size; its date is the marker's, i.e. when
    /// the key was deleted.
    public static func deletedRows(
        from entries: [DeletedEntry], inDirectory path: String, keyPrefix: String
    ) -> [RemoteFileItem] {
        entries.compactMap { entry in
            guard entry.key.hasPrefix(keyPrefix) else { return nil }
            let name = String(entry.key.dropFirst(keyPrefix.count))
            guard !name.isEmpty, !name.contains("/") else { return nil }
            return RemoteFileItem(
                name: name, path: RemotePath.join(path, name), kind: .file,
                modifiedAt: entry.modifiedAt, deleteMarkerVersionID: entry.markerVersionId)
        }
    }
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
