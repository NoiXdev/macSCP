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
    /// The flat group this session belongs to, if any. Optional so legacy
    /// JSON without this field keeps decoding as `nil` (no custom decoder).
    public var groupID: UUID?
    /// The login set this session's credentials come from, if any (M10b).
    /// Optional so legacy JSON without this field keeps decoding as `nil`
    /// (nil = the session carries its own credentials, "manual" mode).
    public var loginSetID: UUID?
    /// The protocol this session speaks (M12). Legacy JSON without the key
    /// decodes as `.ssh` — synthesized Codable does NOT apply property
    /// defaults to missing keys, so decode is done explicitly below.
    public var kind: ConnectionKind = .ssh
    /// Persisted, SECRET-FREE SSH parameters when `kind == .ssh` (M23). `nil`
    /// for S3/WebDAV sessions, which is what ends the `"unused"` placeholder
    /// at the storage layer: host/port/username/authKind/keyPath/jump lived
    /// flat at the top level until M23 and were meaningless on every
    /// non-SSH session. The password and key passphrase are NOT here
    /// (Keychain only).
    public var ssh: StoredSSHConfig? = nil
    /// Persisted, SECRET-FREE S3 parameters when `kind == .s3` (M12). `nil`
    /// for SSH sessions and on legacy JSON. The secret access key is NOT here
    /// (Keychain only) — this is `StoredS3Config`, not the runtime config.
    public var s3: StoredS3Config? = nil
    /// Persisted, SECRET-FREE WebDAV parameters when `kind == .webdav` (M21).
    /// `nil` for SSH/S3 sessions and on legacy JSON. The password is NOT here
    /// (Keychain only) -- this is `StoredWebDAVConfig`, not the runtime config.
    public var webdav: StoredWebDAVConfig? = nil
    /// Which window halves (files/terminal) were last shown for this session
    /// (P2 terminal-chrome milestone, Task 4). Belongs in the same category
    /// as `groupID` above: a fact about the SESSION, not a connection
    /// property, so it lives at the top level rather than in a backend's
    /// field bag. Coded the same way `kind` is (`?? .bothVisible` below,
    /// mirroring `kind`'s `?? .ssh`): a missing key means a file that
    /// predates this field, or a session that was never toggled away from
    /// the default, and either way decodes as `.bothVisible` -- exactly how
    /// every session behaved before this field existed.
    public var paneVisibility: PaneVisibility = .bothVisible

    public init(
        id: UUID = UUID(),
        name: String,
        groupID: UUID? = nil,
        loginSetID: UUID? = nil,
        kind: ConnectionKind = .ssh,
        ssh: StoredSSHConfig? = nil,
        s3: StoredS3Config? = nil,
        webdav: StoredWebDAVConfig? = nil,
        paneVisibility: PaneVisibility = .bothVisible
    ) {
        self.id = id
        self.name = name
        self.groupID = groupID
        self.loginSetID = loginSetID
        self.kind = kind
        self.ssh = ssh
        self.s3 = s3
        self.webdav = webdav
        self.paneVisibility = paneVisibility
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, groupID, loginSetID, kind, ssh, s3, webdav, paneVisibility
    }

    /// Explicit rather than synthesized because `kind` needs its `?? .ssh`
    /// default: synthesized Codable does NOT apply a property default to a
    /// missing key, and a `sessions-v2.json` written by an earlier build of
    /// this same milestone may not carry one. `paneVisibility` needs the
    /// same treatment for the same reason.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        groupID = try c.decodeIfPresent(UUID.self, forKey: .groupID)
        loginSetID = try c.decodeIfPresent(UUID.self, forKey: .loginSetID)
        kind = try c.decodeIfPresent(ConnectionKind.self, forKey: .kind) ?? .ssh
        ssh = try c.decodeIfPresent(StoredSSHConfig.self, forKey: .ssh)
        s3 = try c.decodeIfPresent(StoredS3Config.self, forKey: .s3)
        webdav = try c.decodeIfPresent(StoredWebDAVConfig.self, forKey: .webdav)
        paneVisibility = try c.decodeIfPresent(PaneVisibility.self, forKey: .paneVisibility) ?? .bothVisible
    }

    // DEPRECATION INTENT: these exist to keep M23 Phase 1 reviewable. Phase 3
    // removes the ones export/import uses; anything still reading them after
    // that is a caller that should be asking the descriptor's `displaySummary`
    // or `sessionValues` instead.

    /// Read-only conveniences over `ssh` (M23), so callers that read SSH's
    /// fields off a session read one property instead of unwrapping.
    ///
    /// `keyPath` and `jump` return Optionals and stay `public`: `nil` is an
    /// honest answer for a session with no SSH block, and every one of their
    /// roughly 18 readers across `macSCPCore`, `MacSCPApp` and `MacSCPCLI` is
    /// a legitimate `guard let` / `if let` / `??` unwrap — there is no
    /// endorsed-vs-defect split to draw here.
    ///
    /// `host`, `port`, `username` and `authKind` used to live here too, each
    /// fabricating `""` / `22` / `""` / `.password` for a session with no SSH
    /// block — the pre-M23 `"unused"` placeholder, in a new spelling. M26
    /// deletes them: every former reader now unwraps `ssh` itself, and a
    /// record whose `kind` says `.ssh` but carries no block is dropped when
    /// the store loads, so the fabricated values had no honest caller left.
    ///
    /// Anything that WRITES must go through `ssh` directly, so that writing
    /// to a session with no SSH block is a compile error rather than a
    /// silent no-op.
    public var keyPath: String? { ssh?.keyPath }
    public var jump: JumpSpec? { ssh?.jump }
}
