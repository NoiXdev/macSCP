import Foundation

/// Translates SFTP attribute primitives into RemoteFileItem.
/// Deliberately free of Citadel types, so it's purely testable.
enum SFTPAttributeMapper {
    private static let typeMask: UInt32 = 0o170000
    private static let directoryBits: UInt32 = 0o040000
    private static let symlinkBits: UInt32 = 0o120000
    private static let regularFileBits: UInt32 = 0o100000

    static func kind(fromPermissions permissions: UInt32?) -> RemoteFileKind {
        guard let permissions else { return .other }
        switch permissions & typeMask {
        case directoryBits: return .directory
        case symlinkBits: return .symlink
        case regularFileBits: return .file
        default: return .other
        }
    }

    /// Builds a `RemoteFileItem`, resolving `owner`/`group` per the M11m
    /// data-source rules: `longname`'s parsed NAMES win when available and
    /// parsable; otherwise the numeric `uidgid` as a string; otherwise
    /// `nil`. `longname` is only ever present on the readdir path (SFTP
    /// `stat`/`getAttributes` carries no longname) — callers on that path
    /// simply omit it, which falls straight through to the numeric case.
    static func item(
        name: String,
        directory: String,
        size: UInt64?,
        permissions: UInt32?,
        modifiedAt: Date?,
        longname: String? = nil,
        uidgid: (userId: UInt32, groupId: UInt32)? = nil
    ) -> RemoteFileItem {
        let (owner, group) = ownerGroup(longname: longname, uidgid: uidgid)
        return RemoteFileItem(
            name: name,
            path: path(directory: directory, name: name),
            kind: kind(fromPermissions: permissions),
            size: size,
            modifiedAt: modifiedAt,
            permissions: permissions.map { $0 & 0o7777 },
            owner: owner,
            group: group
        )
    }

    /// The root is the ONE entry whose basename is the path itself, so
    /// `CitadelFileSystem.stat("/")` hands us "/" as BOTH `name` and
    /// `directory` (`RemotePath.parent(of: "/")` is "/"). Joining those
    /// would yield "//", and because `RemoteFileItem.id` IS the path, that
    /// doubled slash would travel on into navigation, breadcrumbs and
    /// error messages. Every other entry composes normally — `join`
    /// already handles the trailing slash of a root `directory`.
    private static func path(directory: String, name: String) -> String {
        guard name != "/" else { return "/" }
        return RemotePath.join(directory, name)
    }

    /// The precedence rule itself (M11m design): a successfully parsed
    /// `longname` wins; a malformed/missing `longname` falls back to the
    /// numeric `uidgid`; neither present yields `nil`. Never a guess.
    private static func ownerGroup(
        longname: String?, uidgid: (userId: UInt32, groupId: UInt32)?
    ) -> (owner: String?, group: String?) {
        if let longname, let parsed = LongnameParser.ownerGroup(from: longname) {
            return (parsed.owner, parsed.group)
        }
        if let uidgid {
            return (String(uidgid.userId), String(uidgid.groupId))
        }
        return (nil, nil)
    }
}
