import Foundation

/// Übersetzt SFTP-Attribut-Primitive in RemoteFileItem.
/// Bewusst frei von Citadel-Typen, damit pur testbar.
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

    static func item(
        name: String,
        directory: String,
        size: UInt64?,
        permissions: UInt32?,
        modifiedAt: Date?
    ) -> RemoteFileItem {
        RemoteFileItem(
            name: name,
            path: RemotePath.join(directory, name),
            kind: kind(fromPermissions: permissions),
            size: size,
            modifiedAt: modifiedAt,
            permissions: permissions.map { $0 & 0o7777 }
        )
    }
}
