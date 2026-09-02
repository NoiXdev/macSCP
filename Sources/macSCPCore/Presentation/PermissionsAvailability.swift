import Foundation

/// Whether a backend can be OFFERED the permissions editor at all.
///
/// This reads `ProtocolCapabilities.permissionModel` and nothing else, the
/// way `ChecksumAvailability` reads `supportsRemoteChecksum`: as a named
/// function, so that "the offer follows the capability" is a property a
/// test can hold, instead of a habit a view is trusted to keep. Until it
/// existed the flag was declared by every descriptor and read by no
/// surface — an S3 or WebDAV file was offered "Info & Permissions" like any
/// other, and only the accident of those listings leaving
/// `RemoteFileItem.permissions` nil kept an editor from appearing whose
/// Apply the backend would have refused.
///
/// Pinned to `.posixMode`, not to `!= .none`, because the editor is a POSIX
/// one — an rwx grid and an octal field — and that is what it can apply. A
/// backend declaring `.acl` would need an editor this app does not have;
/// offering it the POSIX one would be the same lie in another shape.
///
/// Where the answer is `false` the info sheet shows the sentence that says
/// so, never a greyed-out grid. The menu entry itself stays, titled "Info"
/// rather than "Info & Permissions": the sheet it opens is still where
/// size, dates and checksum live, and those are as true of an object in a
/// bucket as of a file over SFTP.
public enum PermissionsAvailability {
    public static func isOffered(for kind: ConnectionKind) -> Bool {
        BackendDescriptor.descriptor(for: kind).capabilities.permissionModel == .posixMode
    }

    /// The LOCAL pane's answer, which cannot be the one above: "local" is
    /// not a `ConnectionKind`, so there is no descriptor and no flag to
    /// read. What stands in its place is the local file system's own
    /// declaration, read here rather than restated at the call site.
    public static var isOfferedByTheLocalFileSystem: Bool {
        LocalFileSystem.permissionModel == .posixMode
    }
}
