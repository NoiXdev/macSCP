/// How an FTP control connection is protected: not at all, upgraded after the
/// greeting, or wrapped from the first byte.
///
/// **Public, like the types that hold it.** `ConnectionConfig` is a public
/// enum, and an enum case's associated value cannot be less accessible than
/// the enum; `FTPConnectionConfig` therefore has to be public, and a public
/// struct's stored property cannot name an internal type. (Withdrawn wording,
/// verbatim: "Public although the other FTP types are internal." It was true
/// only of the wire types of Tasks 1-2 -- `FTPReply`, `FTPReplyError`,
/// `FTPReplyAccumulator`, `FTPListRefusal` and `FTPListParser` -- and not of
/// `FTPField`, `FTPFieldSchema` or `StoredFTPConfig`, which are public too.)
///
/// The raw values are the persisted spelling (`StoredFTPConfig` writes them),
/// so they are not to be renamed.
public enum FTPSecurityMode: String, Codable, Sendable, CaseIterable {
    /// No TLS anywhere: credentials and file contents cross the network in the
    /// clear. The only mode `PlaintextTransportGate` asks the user to confirm.
    case plain
    /// Explicit FTPS: the connection starts in the clear and `AUTH TLS`
    /// upgrades it before the credentials are sent.
    case explicitTLS
    /// Implicit FTPS: TLS from the first byte, conventionally on port 990.
    case implicitTLS

    /// The port a server of this kind listens on unless told otherwise.
    /// Explicit FTPS shares 21 with plain FTP because the upgrade happens
    /// after connecting; only implicit FTPS has a port of its own.
    public var defaultPort: Int {
        switch self {
        case .plain, .explicitTLS: return 21
        case .implicitTLS: return 990
        }
    }
}
