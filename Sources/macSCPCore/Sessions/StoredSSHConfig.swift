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
    /// This session's own terminal type (plan of 2026-09-19, Task 4), or
    /// `nil` for "use the global setting" (`SettingsStore.terminalType`) —
    /// which is what every file written before this field existed decodes
    /// as. Lives here rather than beside `paneVisibility` because the name
    /// travels in the SSH pty request: no other protocol opens a shell.
    ///
    /// Decoded leniently, see `init(from:)`: a name this build does not
    /// offer reads as `nil`, because `SessionStore` decodes its file in one
    /// piece and a throwing field would cost every session in it.
    public var terminalType: TerminalType?

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

    private enum CodingKeys: String, CodingKey {
        case host, port, username, authKind, keyPath, jump, terminalType
    }

    /// Explicit only for `terminalType`: synthesized decoding would throw on
    /// a name this build does not know (a later build's wider list, a hand
    /// edit), and with it the whole store file. Such a name reads as `nil`,
    /// "use the global setting". Every other field decodes exactly as the
    /// synthesized decoder did. Encoding stays synthesized.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        host = try c.decode(String.self, forKey: .host)
        port = try c.decode(Int.self, forKey: .port)
        username = try c.decode(String.self, forKey: .username)
        authKind = try c.decode(StoredSession.AuthKind.self, forKey: .authKind)
        keyPath = try c.decodeIfPresent(String.self, forKey: .keyPath)
        jump = try c.decodeIfPresent(StoredSession.JumpSpec.self, forKey: .jump)
        terminalType = (try? c.decodeIfPresent(String.self, forKey: .terminalType))
            .flatMap(TerminalType.init(rawValue:))
    }
}
