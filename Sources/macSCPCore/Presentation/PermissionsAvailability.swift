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

    /// The same question of a LIVE CONNECTION, which is the only form that
    /// can be right for FTP.
    ///
    /// `setPermissions` maps to `SITE CHMOD` there, which is not in RFC 959
    /// and is a per-server extension, so `.posixMode` is true of the protocol
    /// and may be false of the server in front of you. The FTP design's §14
    /// settles that the editor is offered per connection for exactly that
    /// reason, "so a server that refuses `SITE CHMOD` shows no editor instead
    /// of an editor that always fails".
    ///
    /// **The capability is read FIRST and the probe only narrows it.** A
    /// backend whose `permissionModel` is not `.posixMode` is never asked:
    /// the editor it would be offered is a POSIX one, and no answer from a
    /// connection makes that the right editor for an ACL model or for none at
    /// all. So this can only ever be the same answer as the per-kind one, or
    /// a `false` where that one said `true`.
    ///
    /// `async`, because the first ask may be a round trip. A conformer
    /// remembers its answer (`FTPSiteChmodMemory`), so a surface that asks
    /// once per connection pays once — and a surface that asks per ROW would
    /// still pay only once, which is why the memory is the conformer's job
    /// and not the caller's.
    ///
    /// **Owed: the App does not read this yet.** The per-kind form above has
    /// exactly ONE call site, and it is inside a SwiftUI body and so
    /// synchronous; reading this one means holding the answer on the session
    /// and setting it when the connection opens. Until that is wired, an FTP
    /// server with no `SITE CHMOD` still shows the editor and its Apply fails
    /// per file — which is the behaviour before the probe existed, not a new
    /// one.
    ///
    /// The figure has to be READ and not counted, which is why the command is
    /// here with what it prints rather than a number on its own:
    ///
    ///     /usr/bin/grep -rn 'PermissionsAvailability\.isOffered(' Sources/MacSCPAppKit
    ///
    /// prints **two** lines, and one of them is `BrowserPane.swift`'s doc
    /// comment naming the function in prose. The call is
    /// `ContentView+Detail.swift`'s `supportsPermissions:`. Its neighbour at
    /// the LOCAL pane calls `isOfferedByTheLocalFileSystem`, a different
    /// function, and is not affected by any of this: "local" is not a
    /// connection.
    public static func isOffered(
        for kind: ConnectionKind, on connection: any RemoteFileSystem
    ) async -> Bool {
        guard isOffered(for: kind) else { return false }
        guard let probe = connection as? any PermissionEditingProbe else { return true }
        return await probe.offersPermissionEditing()
    }

    /// The LOCAL pane's answer, which cannot be the one above: "local" is
    /// not a `ConnectionKind`, so there is no descriptor and no flag to
    /// read. What stands in its place is the local file system's own
    /// declaration, read here rather than restated at the call site.
    public static var isOfferedByTheLocalFileSystem: Bool {
        LocalFileSystem.permissionModel == .posixMode
    }
}
