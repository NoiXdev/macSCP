import Foundation

/// A stored connection — contains NO secrets.
/// Passwords live exclusively in the SecretStore (keychain), addressed via
/// the session id.
public struct StoredSession: Codable, Equatable, Identifiable, Sendable {
    /// M3b: password + privateKey; M10d added ssh-agent as a third kind.
    public enum AuthKind: String, Codable, Sendable {
        case password
        case privateKey
        /// Authenticate through the local ssh-agent (M10d): no secret is
        /// ever stored for this kind — `keyPath` stays nil and the
        /// SecretStore slot (session id / jump `secretID`) is never written.
        case agent
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
        /// The saved session this jump references, if any (M11a). Non-nil =
        /// "session" mode: `host`/`port`/`username`/`authKind`/`keyPath`/
        /// `loginSetID` above are inactive (kept only as a data carrier for
        /// delete-restoration) and the referenced session's own host/port
        /// and login are used instead. Optional so legacy JSON without this
        /// field keeps decoding as `nil` (no custom decoder, same pattern as
        /// `groupID`/`loginSetID`/`jump`).
        public var sessionID: UUID?

        public init(
            host: String,
            port: Int = 22,
            username: String,
            authKind: AuthKind = .password,
            keyPath: String? = nil,
            loginSetID: UUID? = nil,
            secretID: UUID = UUID(),
            sessionID: UUID? = nil
        ) {
            self.host = host
            self.port = port
            self.username = username
            self.authKind = authKind
            self.keyPath = keyPath
            self.loginSetID = loginSetID
            self.secretID = secretID
            self.sessionID = sessionID
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
    /// The protocol this session speaks (M12). Legacy JSON without the key
    /// decodes as `.ssh` — synthesized Codable does NOT apply property
    /// defaults to missing keys, so decode is done explicitly below.
    public var kind: ConnectionKind = .ssh
    /// Persisted, SECRET-FREE S3 parameters when `kind == .s3` (M12). `nil`
    /// for SSH sessions and on legacy JSON. The secret access key is NOT here
    /// (Keychain only) — this is `StoredS3Config`, not the runtime config.
    public var s3: StoredS3Config? = nil
    /// Persisted, SECRET-FREE WebDAV parameters when `kind == .webdav` (M21).
    /// `nil` for SSH/S3 sessions and on legacy JSON. The password is NOT here
    /// (Keychain only) -- this is `StoredWebDAVConfig`, not the runtime config.
    public var webdav: StoredWebDAVConfig? = nil

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
        jump: JumpSpec? = nil,
        kind: ConnectionKind = .ssh,
        s3: StoredS3Config? = nil,
        webdav: StoredWebDAVConfig? = nil
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
        self.kind = kind
        self.s3 = s3
        self.webdav = webdav
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, host, port, username, authKind, keyPath, groupID, loginSetID, jump, kind, s3, webdav
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        host = try c.decode(String.self, forKey: .host)
        port = try c.decode(Int.self, forKey: .port)
        username = try c.decode(String.self, forKey: .username)
        authKind = try c.decode(AuthKind.self, forKey: .authKind)
        keyPath = try c.decodeIfPresent(String.self, forKey: .keyPath)
        groupID = try c.decodeIfPresent(UUID.self, forKey: .groupID)
        loginSetID = try c.decodeIfPresent(UUID.self, forKey: .loginSetID)
        jump = try c.decodeIfPresent(JumpSpec.self, forKey: .jump)
        kind = try c.decodeIfPresent(ConnectionKind.self, forKey: .kind) ?? .ssh
        s3 = try c.decodeIfPresent(StoredS3Config.self, forKey: .s3)
        webdav = try c.decodeIfPresent(StoredWebDAVConfig.self, forKey: .webdav)
    }

}
