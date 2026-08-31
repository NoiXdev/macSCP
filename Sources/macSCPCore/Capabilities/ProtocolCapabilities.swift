/// How a backend expresses file permissions.
public enum PermissionModel: Sendable, Equatable { case posixMode, acl, none }
/// How a partially-transferred file is resumed.
public enum ResumeMode: Sendable, Equatable { case append, rangeGet, restOffset, none }
/// Transport confidentiality.
public enum TransportSecurity: Sendable, Equatable { case alwaysEncrypted, optionalTLS, plaintext }

/// Declarative capability matrix for a protocol (M12). The generic browser/
/// menu/info/gating layers read ONLY this — never the concrete kind — so a
/// new protocol is a new descriptor, not scattered `if kind ==` branches.
public struct ProtocolCapabilities: Sendable, Equatable {
    public var supportsShell: Bool
    public var permissionModel: PermissionModel
    public var supportsSymlinks: Bool
    public var atomicRename: Bool
    public var directoriesAreReal: Bool
    public var resumeMode: ResumeMode
    public var supportsPresignedURL: Bool
    /// Whether this protocol can answer the checksum question with a value
    /// at all (`RemoteChecksumProvider`). A statement about the PROTOCOL,
    /// and deliberately not about HOW the answer is obtained: SSH has the
    /// far side compute a digest, S3 reports the ETag its listing already
    /// carries, and whether a given value describes the file's content is
    /// carried by `FileChecksum.provenance` — never by this flag. WebDAV is
    /// the one that is false: it publishes no digest this project reads.
    ///
    /// A connection whose far side turns out to carry no checksum tool
    /// answers `.unavailableOnThisConnection`, which is what the surface
    /// then says. Both are needed — this one so a menu can exist at all
    /// without asking the connection anything, that one so the menu tells
    /// the truth about the server it is pointed at.
    public var supportsRemoteChecksum: Bool
    public var transport: TransportSecurity

    public init(supportsShell: Bool, permissionModel: PermissionModel,
                supportsSymlinks: Bool, atomicRename: Bool, directoriesAreReal: Bool,
                resumeMode: ResumeMode, supportsPresignedURL: Bool,
                supportsRemoteChecksum: Bool, transport: TransportSecurity) {
        self.supportsShell = supportsShell; self.permissionModel = permissionModel
        self.supportsSymlinks = supportsSymlinks; self.atomicRename = atomicRename
        self.directoriesAreReal = directoriesAreReal; self.resumeMode = resumeMode
        self.supportsPresignedURL = supportsPresignedURL
        self.supportsRemoteChecksum = supportsRemoteChecksum; self.transport = transport
    }
}
