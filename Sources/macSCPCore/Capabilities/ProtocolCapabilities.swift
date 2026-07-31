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
    public var transport: TransportSecurity

    public init(supportsShell: Bool, permissionModel: PermissionModel,
                supportsSymlinks: Bool, atomicRename: Bool, directoriesAreReal: Bool,
                resumeMode: ResumeMode, supportsPresignedURL: Bool, transport: TransportSecurity) {
        self.supportsShell = supportsShell; self.permissionModel = permissionModel
        self.supportsSymlinks = supportsSymlinks; self.atomicRename = atomicRename
        self.directoriesAreReal = directoriesAreReal; self.resumeMode = resumeMode
        self.supportsPresignedURL = supportsPresignedURL; self.transport = transport
    }
}
