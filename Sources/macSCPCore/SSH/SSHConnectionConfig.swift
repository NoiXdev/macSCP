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
        /// The target host contains a character on the ban list (M11d fix3,
        /// re-review finding I-3). Unlike the jump host, the target host
        /// never enters ssh's `ProxyCommand` string — it is positional
        /// behind the `--` `SSHCommandBuilder` emits, so ssh itself is the
        /// one that parses it as a hostname. A whitelist as strict as the
        /// jump one bought little safety here but rejected real IDN hosts
        /// (e.g. `münchen.de`), so this only bans characters that are
        /// actually shell-dangerous or could be misread by `ssh`/getopt: a
        /// leading `-`, whitespace/control characters, and shell
        /// metacharacters — everything else, including non-ASCII, is
        /// allowed. See `isValidTargetHost` for the exact ban list.
        case invalidHost
        /// The target username contains a character on the ban list (M11d
        /// fix3, re-review finding I-3). Like the target host, the target
        /// username never enters ssh's `ProxyCommand` string — it is passed
        /// as a literal `-l` argv, so the strict jump whitelist bought
        /// little there and cost a capability that existed since M1: a
        /// user whose SFTP username is `user@install` (a documented WP
        /// Engine-style format) or `DOMAIN\user` (an AD account on a
        /// Windows SSH server) could no longer connect at all. This ban
        /// list therefore permits `@` and `\` in addition to everything
        /// `isValidTargetHost` allows. See `isValidTargetUsername` for the
        /// exact ban list.
        case invalidUsername
    }

    /// Strict whitelist for `jump.host`: ASCII letters, digits, `.`, `-`,
    /// `_`, `:` (IPv6 literals), `%` (IPv6 zone id) — no leading `-` (which
    /// `ssh`/getopt could otherwise mistake for an option). Every other
    /// character (whitespace, control characters, quotes, `$`, backtick,
    /// `;`, `&`, `<`, `>`, `|`, `(`, `)`, `{`, `}`, `\`, `,`, `/`) is
    /// rejected. This is the ONE place the jump host whitelist is defined.
    /// Unlike the target host (`isValidTargetHost`), the jump host DOES
    /// enter ssh's implicit `ProxyCommand` string, so it keeps this strict
    /// whitelist rather than the target's more permissive ban list.
    private static func isValidJumpHost(_ value: String) -> Bool {
        guard !startsWithHyphen(value) else { return false }
        return value.allSatisfy { char in
            (char.isASCII && (char.isLetter || char.isNumber))
                || char == "." || char == "-" || char == "_" || char == ":" || char == "%"
        }
    }

    /// Strict whitelist for `jump.username`: ASCII letters, digits, `.`,
    /// `-`, `_` — no leading `-`. Unlike the target username
    /// (`isValidTargetUsername`), the jump username DOES enter ssh's
    /// implicit `ProxyCommand` string, so it keeps this strict whitelist.
    private static func isValidJumpUsername(_ value: String) -> Bool {
        guard !startsWithHyphen(value) else { return false }
        return value.allSatisfy { char in
            (char.isASCII && (char.isLetter || char.isNumber)) || char == "." || char == "-" || char == "_"
        }
    }

    /// Whether `value` starts with a `-`, which `ssh`/getopt could mistake
    /// for an option. Read as a SCALAR, not as `value.first`: a `Character`
    /// is an extended grapheme cluster, so `-` followed by U+0308 is one
    /// symbol that compares unequal to `"-"` — `"-̈x.com"` and `"-̈l"` were
    /// accepted while their undecorated forms were rejected, and getopt sees
    /// the `-` byte either way. The ban lists below moved onto scalars a
    /// round earlier; this guard sat one line above them and did not.
    ///
    /// The whitelists above keep asking their question in `Character`s, and
    /// that is not the same oversight: an ALLOW list survives the wrong
    /// alphabet by construction, because a decorated cluster is simply not
    /// on it (`Character.isASCII` is false for every one of them). A BAN
    /// list — and a `first != "-"` guard is one — does not.
    private static func startsWithHyphen(_ value: String) -> Bool {
        value.unicodeScalars.first == "-"
    }

    /// Characters rejected outright anywhere in a control character check:
    /// whitespace, newlines, and ASCII control characters (including NUL
    /// and DEL) — shared by both target predicates below.
    /// Walked over `Unicode.Scalar`s, not `Character`s — see `ShellScalar`.
    /// A space carrying a combining mark is one `Character` whose
    /// `isWhitespace` is false, and a check that misses it is a check an
    /// attacker chooses the input for.
    private static func hasWhitespaceOrControlCharacter(_ value: String) -> Bool {
        value.unicodeScalars.contains { scalar in
            ShellScalar.isAnyUnicodeWhitespace(scalar) || scalar.value < 0x20
                || scalar.value == 0x7F
        }
    }

    /// Scalars no target host or username may contain. A **ban** list, which
    /// is why it is matched scalar by scalar: an allow list survives being
    /// read in the wrong alphabet (a decorated character simply is not on
    /// it — which is why the two jump whitelists above need no change),
    /// while a ban list read in `Character`s silently lets through every
    /// banned character that carries a combining mark. `'` followed by
    /// U+0308 is one `Character` that is not in a `Set<Character>` of
    /// metacharacters, and it is an apostrophe to every shell there is.
    private static func containsBannedScalar(
        _ value: String, banned: Set<Unicode.Scalar>
    ) -> Bool {
        value.unicodeScalars.contains { banned.contains($0) }
    }

    /// Ban list for the target `host` (M11d fix3, finding I-3): rejects an
    /// empty string, a leading `-` (which `ssh`/getopt could otherwise
    /// mistake for an option — the `--` in `SSHCommandBuilder` is a second
    /// layer, not the only one), any whitespace/newline/control character,
    /// and any of `' " \` $ & ; | < > ( ) { } [ ] \ , * ? ! # ~ ^ = @ /`.
    /// Everything else is allowed — notably non-ASCII (IDN hosts like
    /// `münchen.de`), `.`, `-`, `_`, `:` (IPv6), `%` (IPv6 zone id), `+`.
    /// The target host is positional behind `--` and never enters ssh's
    /// `ProxyCommand` string (unlike the jump host, see `isValidJumpHost`),
    /// so a ban list closes the real shell-injection risks without
    /// rejecting legitimate values the way the old whitelist did.
    private static func isValidTargetHost(_ value: String) -> Bool {
        guard !startsWithHyphen(value) else { return false }
        guard !hasWhitespaceOrControlCharacter(value) else { return false }
        let banned: Set<Unicode.Scalar> = [
            "'", "\"", "`", "$", "&", ";", "|", "<", ">", "(", ")", "{", "}", "[", "]",
            "\\", ",", "*", "?", "!", "#", "~", "^", "=", "@", "/",
        ]
        return !containsBannedScalar(value, banned: banned)
    }

    /// Ban list for the target `username` (M11d fix3, finding I-3): the
    /// same shape as `isValidTargetHost` (leading `-`, whitespace/newline/
    /// control characters, and a metacharacter ban list), but the ban set
    /// OMITS `@` and `\` because `user@install` (a documented WP
    /// Engine-style SFTP username) and `DOMAIN\user` (an AD account on a
    /// Windows SSH server) are real usernames, and neither character can do
    /// harm in an `-l` argv (the target username never enters ssh's
    /// `ProxyCommand` string, unlike the jump username — see
    /// `isValidJumpUsername`).
    private static func isValidTargetUsername(_ value: String) -> Bool {
        guard !startsWithHyphen(value) else { return false }
        guard !hasWhitespaceOrControlCharacter(value) else { return false }
        let banned: Set<Unicode.Scalar> = [
            "'", "\"", "`", "$", "&", ";", "|", "<", ">", "(", ")", "{", "}", "[", "]",
            ",", "*", "?", "!", "#", "~", "^", "/",
        ]
        return !containsBannedScalar(value, banned: banned)
    }

    public let host: String
    public let port: Int
    public let username: String
    public let auth: AuthMethod
    public let jump: Jump?

    public init(host: String, port: Int = 22, username: String, auth: AuthMethod, jump: Jump? = nil) throws {
        guard !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ConfigError.emptyHost }
        guard Self.isValidTargetHost(host) else { throw ConfigError.invalidHost }
        guard (1...65535).contains(port) else { throw ConfigError.invalidPort(port) }
        guard !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ConfigError.emptyUsername }
        guard Self.isValidTargetUsername(username) else { throw ConfigError.invalidUsername }
        if case .privateKey(let keyPath, _) = auth {
            guard !keyPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ConfigError.emptyKeyPath
            }
        }
        if let jump {
            guard !jump.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ConfigError.emptyJumpHost
            }
            guard Self.isValidJumpHost(jump.host) else { throw ConfigError.invalidJumpHost }
            guard (1...65535).contains(jump.port) else { throw ConfigError.invalidJumpPort(jump.port) }
            guard !jump.username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ConfigError.emptyJumpUsername
            }
            guard Self.isValidJumpUsername(jump.username) else { throw ConfigError.invalidJumpUsername }
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

    /// Non-throwing initializer for values DERIVED from an already-valid
    /// config. It skips validation deliberately: every stored field either
    /// comes through unchanged from a value the throwing init already
    /// validated, or is a secret payload that no validation rule inspects.
    /// Private, so the throwing init stays the ONE gate for externally
    /// supplied values.
    private init(validatedHost host: String, port: Int, username: String, auth: AuthMethod, jump: Jump?) {
        self.host = host
        self.port = port
        self.username = username
        self.auth = auth
        self.jump = jump
    }

    /// A copy with every plaintext secret emptied, for the two situations
    /// where a config must outlive the call that resolved it: the
    /// external-terminal password hint holds one in view state while its
    /// alert is open, and `ConnectionViewModel.lastConnectedConfig` holds one
    /// for the whole duration of a connected session -- neither `disconnect`
    /// nor `ConnectionViewModel.clearRetainedSecrets()` reaches the former,
    /// and the latter is exactly what `clearRetainedSecrets()` used to exist
    /// to scrub before this redaction existed.
    ///
    /// Nothing is lost by handing the redacted copy to either path:
    /// `SSHCommandBuilder` reads only host, port, username, key *path* and
    /// jump destination, and passes no secret to `ssh` at all (see its own
    /// doc comment) — `ssh` prompts for the password itself.
    ///
    /// MUST NEVER be handed to a connector/dialer. The result looks like a
    /// usable config -- same host, port, username, jump, and auth CASE -- but
    /// cannot authenticate: `.password("")` in particular would not fail to
    /// dial, it would dial WITH an empty password, producing a real login
    /// attempt against the server that fails confusingly and counts against
    /// the user server-side (e.g. a fail2ban strike) instead of failing
    /// locally and obviously the way a missing config would.
    public func redactingSecrets() -> SSHConnectionConfig {
        SSHConnectionConfig(
            validatedHost: host, port: port, username: username,
            auth: auth.redactingSecret(),
            jump: jump.map {
                Jump(
                    host: $0.host, port: $0.port, username: $0.username,
                    auth: $0.auth.redactingSecret())
            })
    }
}

extension SSHConnectionConfig.AuthMethod {
    /// Empties the plaintext payload while keeping the case itself: callers
    /// branch on WHICH method a config uses (`if case .password`), so
    /// erasing the case would change behaviour, whereas erasing the payload
    /// cannot — only the dialer ever reads it.
    fileprivate func redactingSecret() -> SSHConnectionConfig.AuthMethod {
        switch self {
        case .password:
            return .password("")
        case .privateKey(let keyPath, _):
            return .privateKey(keyPath: keyPath, passphrase: nil)
        case .agent:
            return .agent
        }
    }
}
