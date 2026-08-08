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
    /// A jump's `sessionID` points at a session that is not an SSH
    /// connection. Only SSH tunnels: an object-storage or WebDAV session has
    /// no host to dial through, and reading one's host/port yields
    /// `StoredSession`'s SSH fallbacks ("" and 22) — a bastion nobody can
    /// reach, offered without complaint.
    ///
    /// Distinct from `kindMismatch`, which is about a session and its LOGIN
    /// SET disagreeing. Naming that one here would report the wrong cause.
    case jumpSessionNotSSH
    /// A session's `kind` (M12) does not match the login set it references
    /// -- e.g. an SSH session bound to an S3 set. Binding must fail honestly
    /// rather than resolve credentials shaped for the wrong protocol.
    case kindMismatch
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
    /// Resolves a session's login into the SAME `FieldValues` shape the
    /// connection form produces (M22/T9): `nil` for a manual session
    /// (loginSetID == nil — the caller uses the session's own data), the
    /// set's credentials otherwise. A dangling reference throws.
    ///
    /// One function for every protocol. It replaced `resolve` (SSH-shaped)
    /// and `resolveS3` (S3-shaped), which is what made a WebDAV login set
    /// impossible to resolve without a third copy — and what makes a fourth
    /// backend need none at all: the values come from the backend's own
    /// adapter, and the secret goes into whichever field the backend's
    /// credential schema says is visible.
    public static func resolve(
        session: StoredSession, sets: [LoginSet], secrets: any SecretStore
    ) throws -> FieldValues? {
        guard let setID = session.loginSetID else { return nil }
        guard let set = sets.first(where: { $0.id == setID }) else {
            throw LoginResolveError.missingSet
        }
        // M12: a session must not bind to a set of a different protocol
        // (e.g. an SSH session referencing an S3 set) -- fail honestly
        // rather than resolve credentials shaped for the wrong kind.
        guard set.kind == session.kind else {
            throw LoginResolveError.kindMismatch
        }
        return credentials(of: set, secrets: secrets)
    }

    /// A set's credential values plus its Keychain secret, keyed by the
    /// backend's own fields.
    ///
    /// The agent short-circuit (M10d: "agent sets carry no secret and no key
    /// path, the keychain is never read for them") survives here as a
    /// STRUCTURAL property rather than an `if`: SSH's credential schema shows
    /// neither `password` nor `passphrase` when the auth kind is `.agent`, so
    /// `visibleSecretField` returns nil and the `guard` below exits before
    /// `secrets` is ever touched. `agentSetResolvesWithoutKeychainRead` pins
    /// it with a store that fails the test on any read.
    static func credentials(
        of set: LoginSet, secrets: any SecretStore
    ) -> FieldValues {
        let descriptor = BackendDescriptor.descriptor(for: set.kind)
        var values = descriptor.loginSetValues(set)
        guard let secretField = descriptor.credentialSchema.visibleSecretField(
            in: values, namespace: descriptor.fieldNamespace)
        else { return values }
        guard let secret = (try? secrets.password(for: set.id)) ?? nil else { return values }
        values.setRaw("\(descriptor.fieldNamespace).\(secretField.id)", to: secret)
        return values
    }

    /// The SSH-shaped login a session's set supplies, or `nil` for a manual
    /// session (M22/T9). Same guards as `resolve`.
    ///
    /// Kept beside the generic resolver for the paths that speak
    /// username/authKind/keyPath/secret and nothing else: restoring a deleted
    /// bastion's login onto the sessions that jumped through it, and the
    /// session export format, whose `ExportedSession` has carried exactly
    /// those four columns since M9a.
    public static func sshLogin(
        session: StoredSession, sets: [LoginSet], secrets: any SecretStore
    ) throws -> ResolvedLogin? {
        guard let setID = session.loginSetID else { return nil }
        guard let set = sets.first(where: { $0.id == setID }) else {
            throw LoginResolveError.missingSet
        }
        guard set.kind == session.kind else {
            throw LoginResolveError.kindMismatch
        }
        return sshLogin(from: set, secrets: secrets)
    }

    /// The SSH-shaped view of a set, for the JUMP path only (M22/T9).
    ///
    /// A jump host is an SSH concept — it has a host, a port and one login,
    /// and no other backend has anything to say about it — so `resolveJump`
    /// keeps returning `ResolvedLogin` and this stays a typed read of the
    /// set's SSH columns rather than a `FieldValues`.
    private static func sshLogin(from set: LoginSet, secrets: any SecretStore) -> ResolvedLogin {
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
        return sshLogin(from: set, secrets: secrets)
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
    ///   existing `sshLogin(session:sets:secrets:)`, which already covers
    ///   its set/manual/agent cases; it returns `nil` for a manual
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
        // The kind check comes before the chain check because it is the more
        // fundamental objection: a bucket is not a bastion whether or not it
        // also happens to carry a jump. `JumpSessionEligibility` keeps new
        // configurations from getting here; this covers the ones already on
        // disk, which no picker filter can reach.
        guard referenced.kind == .ssh else {
            throw LoginResolveError.jumpSessionNotSSH
        }
        guard sessionID != referencingSessionID, referenced.jump == nil else {
            throw LoginResolveError.jumpChainNotSupported
        }

        let login: ResolvedLogin
        if let resolved = try sshLogin(session: referenced, sets: sets, secrets: secrets) {
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
