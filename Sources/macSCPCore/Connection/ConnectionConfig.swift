/// A connection's full, typed configuration (M12). Exhaustive over the
/// supported protocols; each backend's own `connect` closure unwraps its
/// own case (M22/T10).
public enum ConnectionConfig: Equatable, Sendable {
    case ssh(SSHConnectionConfig)
    case s3(S3ConnectionConfig)
    case webdav(WebDAVConnectionConfig)

    public var kind: ConnectionKind {
        switch self {
        case .ssh: return .ssh
        case .s3: return .s3
        case .webdav: return .webdav
        }
    }
}
