import Foundation

/// A stored connection — contains NO secrets.
/// Passwords live exclusively in the SecretStore (keychain), addressed via
/// the session id.
public struct StoredSession: Codable, Equatable, Identifiable, Sendable {
    /// M3b: password + privateKey; ssh-agent still open (M3e).
    public enum AuthKind: String, Codable, Sendable {
        case password
        case privateKey
    }

    public let id: UUID
    public var name: String
    public var host: String
    public var port: Int
    public var username: String
    public var authKind: AuthKind
    /// Path to the private key (only set when authKind == .privateKey).
    public var keyPath: String?
    /// The flat group this session belongs to, if any. Optional so legacy
    /// JSON without this field keeps decoding as `nil` (no custom decoder).
    public var groupID: UUID?
    /// The login set this session's credentials come from, if any (M10b).
    /// Optional so legacy JSON without this field keeps decoding as `nil`
    /// (nil = the session carries its own credentials, "manual" mode).
    public var loginSetID: UUID?

    public init(
        id: UUID = UUID(),
        name: String,
        host: String,
        port: Int = 22,
        username: String,
        authKind: AuthKind = .password,
        keyPath: String? = nil,
        groupID: UUID? = nil,
        loginSetID: UUID? = nil
    ) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.username = username
        self.authKind = authKind
        self.keyPath = keyPath
        self.groupID = groupID
        self.loginSetID = loginSetID
    }
}
