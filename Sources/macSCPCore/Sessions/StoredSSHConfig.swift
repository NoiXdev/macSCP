import Foundation

/// SSH's persisted, SECRET-FREE parameters (M23) — the sibling of
/// `StoredS3Config` and `StoredWebDAVConfig`.
///
/// These lived at the top level of `StoredSession` until M23, where they were
/// meaningless on every S3 and WebDAV session and had to be filled with the
/// literal `"unused"`. The password and the key passphrase are NOT here: they
/// live in the Keychain under the session's id.
public struct StoredSSHConfig: Codable, Equatable, Sendable {
    public var host: String
    public var port: Int
    public var username: String
    public var authKind: StoredSession.AuthKind
    /// Path to the private key (only set when authKind == .privateKey).
    public var keyPath: String?
    /// The jump host hop configured for this session, if any (M10c). Lives
    /// here rather than beside `kind` because a hop is an SSH concept: no
    /// other protocol tunnels.
    public var jump: StoredSession.JumpSpec?

    public init(
        host: String, port: Int = 22, username: String,
        authKind: StoredSession.AuthKind = .password,
        keyPath: String? = nil, jump: StoredSession.JumpSpec? = nil
    ) {
        self.host = host
        self.port = port
        self.username = username
        self.authKind = authKind
        self.keyPath = keyPath
        self.jump = jump
    }
}
