import Foundation

/// Thrown by `StoredSessionConnectionConfig.build` when a stored session
/// cannot be turned into a runtime `ConnectionConfig` from the pieces on hand
/// (M20).
public enum StoredSessionConnectionError: Error, Equatable, Sendable {
    /// The session's credentials come from a login set. Resolving a set-bound
    /// login needs `LoginResolver` plus the `LoginSetStore` the App layer has
    /// in scope — the CLI's session-reference flow does not thread that
    /// through (yet), so this fails honestly instead of guessing at
    /// credentials that were never actually on the session.
    case loginSetSessionsNotSupported
    /// The session dials through a jump host. Same reasoning as above:
    /// resolving a jump's own login (manual, set-bound, or "session" mode)
    /// needs machinery the CLI does not yet wire up.
    case jumpSessionsNotSupported
    /// `kind == .s3` but `s3` is `nil` — inconsistent stored data.
    case missingS3Configuration
    /// `kind == .webdav` but `webdav` is `nil` — inconsistent stored data.
    case missingWebDAVConfiguration
    /// The session needs an actual secret (password, key passphrase, or S3
    /// secret access key) and none of the staged sources produced one.
    case secretRequired
    /// `authKind == .privateKey` but `keyPath` is empty or `nil`.
    case missingKeyPath
}

/// Builds the RUNTIME `ConnectionConfig` for a stored session — the CLI's
/// analogue of what `ConnectionViewModel.connect()` builds from its form
/// fields, minus the UI state (M20). Lives in Core rather than the CLI
/// target: the CLI has no test target, and this mapping is exactly the kind
/// of decision logic the M20 design says must stay testable.
///
/// Deliberately narrower than `ConnectionViewModel`: a session bound to a
/// login set or configured with a jump host needs `LoginResolver` and the
/// session/login-set lists the App layer already has in scope. A plain SSH
/// or S3 session with manual credentials and no jump — the common case for a
/// session reachable by `name:/path` — is fully supported.
public enum StoredSessionConnectionConfig {
    public static func build(for session: StoredSession, secret: String?) throws -> ConnectionConfig {
        guard session.loginSetID == nil else {
            throw StoredSessionConnectionError.loginSetSessionsNotSupported
        }
        guard session.jump == nil else {
            throw StoredSessionConnectionError.jumpSessionsNotSupported
        }
        switch session.kind {
        case .ssh:
            return .ssh(try buildSSH(for: session, secret: secret))
        case .s3:
            return .s3(try buildS3(for: session, secret: secret))
        case .webdav:
            return .webdav(try buildWebDAV(for: session, secret: secret))
        }
    }

    private static func buildSSH(for session: StoredSession, secret: String?) throws -> SSHConnectionConfig {
        let auth: SSHConnectionConfig.AuthMethod
        switch session.authKind {
        case .password:
            guard let secret, !secret.isEmpty else {
                throw StoredSessionConnectionError.secretRequired
            }
            auth = .password(secret)
        case .privateKey:
            // Trimmed the same way `ConnectionViewModel.connectSSH()` trims
            // its own `keyPath` field before checking it -- a whitespace-only
            // path must fail with OUR typed error, not fall through to
            // `SSHConnectionConfig`'s own (differently-shaped) validation.
            let keyPath = (session.keyPath ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !keyPath.isEmpty else {
                throw StoredSessionConnectionError.missingKeyPath
            }
            // Empty/nil secret means an unencrypted key -- same convention
            // `ConnectionViewModel.connectSSH()` uses for its own `password`
            // field in `.privateKey` mode.
            auth = .privateKey(keyPath: keyPath, passphrase: (secret?.isEmpty == false) ? secret : nil)
        case .agent:
            // Agent auth needs no secret at all -- the call site skips
            // secret resolution entirely for this case (see `connect(to:
            // options:)` in the CLI), so `secret` is ignored here too.
            auth = .agent
        }
        return try SSHConnectionConfig(
            host: session.host, port: session.port, username: session.username, auth: auth)
    }

    private static func buildS3(for session: StoredSession, secret: String?) throws -> S3ConnectionConfig {
        guard let stored = session.s3 else {
            throw StoredSessionConnectionError.missingS3Configuration
        }
        guard let secret, !secret.isEmpty else {
            throw StoredSessionConnectionError.secretRequired
        }
        return S3ConnectionConfig(stored: stored, secretAccessKey: secret)
    }

    private static func buildWebDAV(
        for session: StoredSession, secret: String?
    ) throws -> WebDAVConnectionConfig {
        guard let stored = session.webdav else {
            throw StoredSessionConnectionError.missingWebDAVConfiguration
        }
        guard let secret, !secret.isEmpty else {
            throw StoredSessionConnectionError.secretRequired
        }
        return WebDAVConnectionConfig(stored: stored, password: secret)
    }
}
