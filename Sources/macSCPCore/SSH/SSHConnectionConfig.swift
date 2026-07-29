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
        /// The jump host contains a character outside the strict whitelist
        /// (ASCII letters/digits, `.`, `-`, `_`, `:`, `%`; no leading `-`).
        /// `ssh -J` turns a jump host into an implicit `ProxyCommand` that it
        /// executes via `/bin/sh -c` WITHOUT validating it for shell
        /// metacharacters (unlike the target host/user, which ssh does
        /// validate) — a comma-only guard is not enough: `$(...)`,
        /// backticks, or a bare space (smuggling in an extra `-o` option)
        /// all achieve local command execution through a hostile jump host.
        /// Rejected outright at the one source of Jump validation rather
        /// than passed through to `ssh`.
        case invalidJumpHost
        /// Mirrors `invalidJumpHost`: the jump username sits in the same
        /// unvalidated `-J` destination spec, so it gets the same strict
        /// whitelist (ASCII letters/digits, `.`, `-`, `_`; no leading `-`).
        case invalidJumpUsername
        /// Defense in depth (M11d final review, C-1): the same host
        /// whitelist as `invalidJumpHost`, applied to the TARGET host too,
        /// so macSCP does not depend on the local `ssh` build's own
        /// argument handling to keep a hostile host from being
        /// misinterpreted.
        case invalidHost
        /// Defense in depth: the same username whitelist as
        /// `invalidJumpUsername`, applied to the TARGET username.
        case invalidUsername
    }

    /// Strict whitelist for `host`/`jump.host`: ASCII letters, digits, `.`,
    /// `-`, `_`, `:` (IPv6 literals), `%` (IPv6 zone id) — no leading `-`
    /// (which `ssh`/getopt could otherwise mistake for an option). Every
    /// other character (whitespace, control characters, quotes, `$`,
    /// backtick, `;`, `&`, `<`, `>`, `|`, `(`, `)`, `{`, `}`, `\`, `,`, `/`)
    /// is rejected. This is the ONE place either host whitelist is defined.
    private static func isValidHost(_ value: String) -> Bool {
        guard let first = value.first, first != "-" else { return false }
        return value.allSatisfy { char in
            (char.isASCII && (char.isLetter || char.isNumber))
                || char == "." || char == "-" || char == "_" || char == ":" || char == "%"
        }
    }

    /// Strict whitelist for `username`/`jump.username`: ASCII letters,
    /// digits, `.`, `-`, `_` — no leading `-`.
    private static func isValidUsername(_ value: String) -> Bool {
        guard let first = value.first, first != "-" else { return false }
        return value.allSatisfy { char in
            (char.isASCII && (char.isLetter || char.isNumber)) || char == "." || char == "-" || char == "_"
        }
    }

    public let host: String
    public let port: Int
    public let username: String
    public let auth: AuthMethod
    public let jump: Jump?

    public init(host: String, port: Int = 22, username: String, auth: AuthMethod, jump: Jump? = nil) throws {
        guard !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ConfigError.emptyHost }
        guard Self.isValidHost(host) else { throw ConfigError.invalidHost }
        guard (1...65535).contains(port) else { throw ConfigError.invalidPort(port) }
        guard !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ConfigError.emptyUsername }
        guard Self.isValidUsername(username) else { throw ConfigError.invalidUsername }
        if case .privateKey(let keyPath, _) = auth {
            guard !keyPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ConfigError.emptyKeyPath
            }
        }
        if let jump {
            guard !jump.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ConfigError.emptyJumpHost
            }
            guard Self.isValidHost(jump.host) else { throw ConfigError.invalidJumpHost }
            guard (1...65535).contains(jump.port) else { throw ConfigError.invalidJumpPort(jump.port) }
            guard !jump.username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ConfigError.emptyJumpUsername
            }
            guard Self.isValidUsername(jump.username) else { throw ConfigError.invalidJumpUsername }
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
