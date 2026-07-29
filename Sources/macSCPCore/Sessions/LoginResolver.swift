import Foundation

/// Thrown when a session references a login set that no longer exists —
/// the connect must fail honestly instead of silently guessing (spec §2).
public enum LoginResolveError: Error, Equatable {
    case missingSet
    /// A jump's `sessionID` (M11a) does not match any known session — the
    /// referenced connection was deleted or never existed.
    case missingJumpSession
    /// A jump referencing a saved session either points at a session that
    /// itself has a jump (chains are not supported — one hop only), or at
    /// itself (self-reference), which would be an infinite chain.
    case jumpChainNotSupported
}

/// Credentials resolved from a login set: what the connect flow needs to
/// fill the connection form. `secret` is the set's keychain entry
/// (password, or key passphrase for .privateKey), nil when absent.
public struct ResolvedLogin: Equatable, Sendable {
    public var username: String
    public var authKind: StoredSession.AuthKind
    public var keyPath: String?
    public var secret: String?

    public init(
        username: String, authKind: StoredSession.AuthKind,
        keyPath: String?, secret: String?
    ) {
        self.username = username
        self.authKind = authKind
        self.keyPath = keyPath
        self.secret = secret
    }
}

/// A jump host fully resolved: unlike `ResolvedLogin` alone, this also
/// carries the host/port to dial, because in "session" mode (M11a) those
/// come from the referenced session rather than the spec's own fields.
public struct ResolvedJump: Equatable, Sendable {
    public var host: String
    public var port: Int
    public var login: ResolvedLogin

    public init(host: String, port: Int, login: ResolvedLogin) {
        self.host = host
        self.port = port
        self.login = login
    }
}

public enum LoginResolver {
    /// Resolves a session's login: `nil` for manual sessions
    /// (loginSetID == nil — the caller uses the session's own data),
    /// the set's credentials otherwise. A dangling reference throws.
    public static func resolve(
        session: StoredSession, sets: [LoginSet], secrets: any SecretStore
    ) throws -> ResolvedLogin? {
        guard let setID = session.loginSetID else { return nil }
        guard let set = sets.first(where: { $0.id == setID }) else {
            throw LoginResolveError.missingSet
        }
        // Agent sets carry no secret and no key path (M10d) -- the keychain
        // is never read for them.
        guard set.authKind != .agent else {
            return ResolvedLogin(username: set.username, authKind: .agent, keyPath: nil, secret: nil)
        }
        let secret = (try? secrets.password(for: set.id)) ?? nil
        return ResolvedLogin(
            username: set.username, authKind: set.authKind,
            keyPath: set.keyPath, secret: secret)
    }

    /// Resolves a jump host's login (M10c): unlike `resolve`, this is ALWAYS
    /// non-nil — a jump either carries its own credentials (manual mode,
    /// secret read from `spec.secretID`) or a set's. A dangling
    /// `loginSetID` throws, same as `resolve`.
    public static func resolveJump(
        spec: StoredSession.JumpSpec, sets: [LoginSet], secrets: any SecretStore
    ) throws -> ResolvedLogin {
        guard let setID = spec.loginSetID else {
            // Agent jumps carry no secret and no key path (M10d) -- the
            // keychain is never read for them, even though `secretID` is
            // still present on the spec (unused in this mode).
            guard spec.authKind != .agent else {
                return ResolvedLogin(username: spec.username, authKind: .agent, keyPath: nil, secret: nil)
            }
            let secret = (try? secrets.password(for: spec.secretID)) ?? nil
            return ResolvedLogin(
                username: spec.username, authKind: spec.authKind,
                keyPath: spec.keyPath, secret: secret)
        }
        guard let set = sets.first(where: { $0.id == setID }) else {
            throw LoginResolveError.missingSet
        }
        guard set.authKind != .agent else {
            return ResolvedLogin(username: set.username, authKind: .agent, keyPath: nil, secret: nil)
        }
        let secret = (try? secrets.password(for: set.id)) ?? nil
        return ResolvedLogin(
            username: set.username, authKind: set.authKind,
            keyPath: set.keyPath, secret: secret)
    }

    /// Resolves a jump host fully, including host/port (M11a): when
    /// `spec.sessionID` is nil this is exactly `resolveJump(spec:sets:
    /// secrets:)` wrapped with the spec's own host/port (unchanged
    /// behavior, spec §4). When `spec.sessionID` is set ("session" mode),
    /// host/port and login instead come from the REFERENCED session:
    /// - missing from `sessions` -> `.missingJumpSession`
    /// - referencing itself, or a session that itself has a jump (chains
    ///   are not supported — one hop only) -> `.jumpChainNotSupported`
    /// - otherwise the referenced session's login is resolved through the
    ///   existing `resolve(session:sets:secrets:)`, which already covers
    ///   its set/manual/agent cases; `resolve` returns `nil` for a manual
    ///   session, in which case the session's own fields plus its keychain
    ///   secret are used directly (agent sessions read no keychain at all).
    public static func resolveJump(
        spec: StoredSession.JumpSpec, sets: [LoginSet], secrets: any SecretStore,
        sessions: [StoredSession], referencingSessionID: UUID?
    ) throws -> ResolvedJump {
        guard let sessionID = spec.sessionID else {
            let login = try resolveJump(spec: spec, sets: sets, secrets: secrets)
            return ResolvedJump(host: spec.host, port: spec.port, login: login)
        }
        guard let referenced = sessions.first(where: { $0.id == sessionID }) else {
            throw LoginResolveError.missingJumpSession
        }
        guard sessionID != referencingSessionID, referenced.jump == nil else {
            throw LoginResolveError.jumpChainNotSupported
        }

        let login: ResolvedLogin
        if let resolved = try resolve(session: referenced, sets: sets, secrets: secrets) {
            login = resolved
        } else if referenced.authKind == .agent {
            // Agent sessions carry no secret and never touch the keychain
            // (M10d rule), manual or not.
            login = ResolvedLogin(
                username: referenced.username, authKind: .agent, keyPath: nil, secret: nil)
        } else {
            let secret = (try? secrets.password(for: referenced.id)) ?? nil
            login = ResolvedLogin(
                username: referenced.username, authKind: referenced.authKind,
                keyPath: referenced.keyPath, secret: secret)
        }
        return ResolvedJump(host: referenced.host, port: referenced.port, login: login)
    }
}
