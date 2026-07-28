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

    /// A jump host ("ProxyJump") hop configured for a session (M10c): the
    /// SSH connection dials this host first, then tunnels the session's own
    /// connection through it. Contains NO secrets — a manual jump's secret
    /// lives in the SecretStore under `secretID` (its own slot; the
    /// session's own `id` slot belongs to the target).
    public struct JumpSpec: Codable, Equatable, Sendable {
        public var host: String
        public var port: Int
        public var username: String
        public var authKind: AuthKind
        /// Path to the private key (only set when authKind == .privateKey).
        public var keyPath: String?
        /// The login set this jump's credentials come from, if any. `nil` =
        /// "manual" mode — the jump carries its own secret under `secretID`.
        public var loginSetID: UUID?
        /// Keychain slot for a MANUAL jump secret (password or key
        /// passphrase). Always present, even in set mode, where it stays
        /// unused/orphan-cleaned rather than absent.
        public var secretID: UUID

        public init(
            host: String,
            port: Int = 22,
            username: String,
            authKind: AuthKind = .password,
            keyPath: String? = nil,
            loginSetID: UUID? = nil,
            secretID: UUID = UUID()
        ) {
            self.host = host
            self.port = port
            self.username = username
            self.authKind = authKind
            self.keyPath = keyPath
            self.loginSetID = loginSetID
            self.secretID = secretID
        }
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
    /// The jump host hop configured for this session, if any (M10c).
    /// Optional so legacy JSON without this field keeps decoding as `nil`
    /// (nil = direct connection, no jump).
    public var jump: JumpSpec?

    public init(
        id: UUID = UUID(),
        name: String,
        host: String,
        port: Int = 22,
        username: String,
        authKind: AuthKind = .password,
        keyPath: String? = nil,
        groupID: UUID? = nil,
        loginSetID: UUID? = nil,
        jump: JumpSpec? = nil
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
        self.jump = jump
    }
}
