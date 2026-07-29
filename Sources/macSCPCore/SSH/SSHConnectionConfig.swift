import Foundation

public struct SSHConnectionConfig: Equatable, Sendable {
    /// Connection parameters incl. auth (password or OpenSSH key).
    public enum AuthMethod: Equatable, Sendable {
        /// Warning: plaintext password — never log/interpolate it.
        case password(String)
        /// OpenSSH key (M3b: ed25519). Passphrase nil/empty = unencrypted key.
        /// Warning: plaintext passphrase — never log/interpolate it.
        case privateKey(keyPath: String, passphrase: String?)
        /// Authenticate through the local ssh-agent (M10d): no secret is
        /// stored by macSCP — signatures are forwarded to the agent process
        /// listening on `SSH_AUTH_SOCK`.
        case agent
    }

    /// Optional intermediate hop (ProxyJump, M10c). Exactly one hop —
    /// chains are out of scope by design.
    public struct Jump: Equatable, Sendable {
        public let host: String
        public let port: Int
        public let username: String
        public let auth: AuthMethod

        // No throwing init of its own — validation happens in the Config
        // init, so ConfigError stays the ONE source of validation errors.
        public init(host: String, port: Int = 22, username: String, auth: AuthMethod) {
            self.host = host
            self.port = port
            self.username = username
            self.auth = auth
        }
    }

    public enum ConfigError: Error, Equatable, Sendable {
        case emptyHost
        case emptyUsername
        case invalidPort(Int)
        case emptyJumpHost
        case emptyJumpUsername
        case invalidJumpPort(Int)
        /// The private key path is empty, which would make
        /// `SSHCommandBuilder` emit a bare `-i ''` to ssh.
        case emptyKeyPath
        /// The jump host's private key path is empty (mirrors `emptyKeyPath`
        /// for the target).
        case emptyJumpKeyPath
        /// `ssh -J` splits its destination-spec value on `,` to chain
        /// multiple jump hosts. A jump host containing a comma would insert
        /// an extra, unapproved hop that ssh contacts *first* — this is
        /// rejected outright rather than passed through.
        case invalidJumpHost
        /// Mirrors `invalidJumpHost`: the jump username also sits inside the
        /// comma-split `-J` destination spec.
        case invalidJumpUsername
    }

    public let host: String
    public let port: Int
    public let username: String
    public let auth: AuthMethod
    public let jump: Jump?

    public init(host: String, port: Int = 22, username: String, auth: AuthMethod, jump: Jump? = nil) throws {
        guard !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ConfigError.emptyHost }
        guard (1...65535).contains(port) else { throw ConfigError.invalidPort(port) }
        guard !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ConfigError.emptyUsername }
        if case .privateKey(let keyPath, _) = auth {
            guard !keyPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ConfigError.emptyKeyPath
            }
        }
        if let jump {
            guard !jump.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ConfigError.emptyJumpHost
            }
            guard !jump.host.contains(",") else { throw ConfigError.invalidJumpHost }
            guard (1...65535).contains(jump.port) else { throw ConfigError.invalidJumpPort(jump.port) }
            guard !jump.username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ConfigError.emptyJumpUsername
            }
            guard !jump.username.contains(",") else { throw ConfigError.invalidJumpUsername }
            if case .privateKey(let jumpKeyPath, _) = jump.auth {
                guard !jumpKeyPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw ConfigError.emptyJumpKeyPath
                }
            }
        }
        self.host = host
        self.port = port
        self.username = username
        self.auth = auth
        self.jump = jump
    }
}
