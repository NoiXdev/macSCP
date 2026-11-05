/// The persisted, SECRET-FREE FTP parameters -- stored in
/// `StoredSession.ftp` and in exports. The password is never here; it lives
/// only in the Keychain (`SecretStore`), like every other backend's secret.
///
/// Public for the reason `StoredWebDAVConfig` is: `StoredSession` is public
/// and holds it. A sixth persisted field is a decision, which is why the
/// persistence test compares the encoded key set exactly.
public struct StoredFTPConfig: Equatable, Codable, Sendable {
    public var host: String
    public var port: Int
    public var username: String
    public var security: FTPSecurityMode
    /// The folder to open first; `nil` means whatever the server starts in.
    public var initialPath: String?

    public init(
        host: String, port: Int, username: String, security: FTPSecurityMode,
        initialPath: String? = nil
    ) {
        self.host = host
        self.port = port
        self.username = username
        self.security = security
        self.initialPath = initialPath
    }
}

/// The RUNTIME FTP connect config: the persisted fields PLUS the transient
/// secret. NOT Codable -- never persisted. A type that cannot be encoded
/// cannot encode a secret, which is why this is a second struct and not
/// `StoredFTPConfig` with an exclusion list.
///
/// **Public although the other FTP types are internal**: it is the associated
/// value of the public `ConnectionConfig.ftp`, and an enum case's payload
/// cannot be less accessible than the enum (`WebDAVConnectionConfig` is
/// public for the same reason).
public struct FTPConnectionConfig: Equatable, Sendable {
    public var host: String
    public var port: Int
    public var username: String
    public var security: FTPSecurityMode
    public var initialPath: String?
    /// Warning: plaintext secret -- never log, interpolate or persist it.
    /// Possibly empty (anonymous FTP), but always supplied: there is no
    /// default, so a call site cannot forget it.
    public var password: String

    public init(
        host: String, port: Int, username: String, security: FTPSecurityMode,
        initialPath: String? = nil, password: String
    ) {
        self.host = host
        self.port = port
        self.username = username
        self.security = security
        self.initialPath = initialPath
        self.password = password
    }
}
