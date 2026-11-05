/// The RUNTIME FTP connect config.
///
/// **Public although the other FTP types are internal**: it is the associated
/// value of the public `ConnectionConfig.ftp`, and an enum case's payload
/// cannot be less accessible than the enum (`WebDAVConnectionConfig` is
/// public for the same reason).
///
/// **`password` is the one field that is not persisted.** WebDAV splits this
/// into a stored, secret-free struct and a runtime one; FTP has one struct,
/// and `CodingKeys` below is what keeps the secret out of any encoding of it.
/// `makeConfig` receives the resolved secret and has nowhere else to put it,
/// because `ConnectionConfig.ftp` carries exactly one payload. The empty
/// default is also what a decoded value reads, so a config that came off disk
/// holds no password until a caller resolves one.
///
/// Warning: `password` is a plaintext secret -- never log, interpolate or
/// persist it.
public struct FTPConnectionConfig: Sendable, Equatable, Codable {
    public var host: String
    public var port: Int
    public var username: String
    public var security: FTPSecurityMode
    /// The folder to open first; `nil` means whatever the server starts in.
    public var initialPath: String?
    public var password: String = ""

    public init(
        host: String, port: Int, username: String, security: FTPSecurityMode,
        initialPath: String? = nil, password: String = ""
    ) {
        self.host = host
        self.port = port
        self.username = username
        self.security = security
        self.initialPath = initialPath
        self.password = password
    }

    /// Every stored property except `password`. A case added above without a
    /// line here is not encoded, which is why the persistence test compares
    /// the encoded keys with this list rather than trusting it.
    private enum CodingKeys: String, CodingKey {
        case host, port, username, security, initialPath
    }
}
