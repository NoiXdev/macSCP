import Foundation

/// Thrown when a session references a login set that no longer exists —
/// the connect must fail honestly instead of silently guessing (spec §2).
public enum LoginResolveError: Error, Equatable {
    case missingSet
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
            let secret = (try? secrets.password(for: spec.secretID)) ?? nil
            return ResolvedLogin(
                username: spec.username, authKind: spec.authKind,
                keyPath: spec.keyPath, secret: secret)
        }
        guard let set = sets.first(where: { $0.id == setID }) else {
            throw LoginResolveError.missingSet
        }
        let secret = (try? secrets.password(for: set.id)) ?? nil
        return ResolvedLogin(
            username: set.username, authKind: set.authKind,
            keyPath: set.keyPath, secret: secret)
    }
}
