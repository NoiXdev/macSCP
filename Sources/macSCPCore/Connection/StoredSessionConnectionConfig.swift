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
    /// The session's `kind` says one protocol but the matching stored
    /// configuration block is `nil` — inconsistent stored data. One case for
    /// every backend (M22/T10), carrying the kind rather than one case per
    /// protocol, so a fourth protocol adds none.
    case missingBackendConfiguration(kind: ConnectionKind)
    /// The session needs an actual secret (password, key passphrase, or S3
    /// secret access key) and none of the staged sources produced one.
    case secretRequired
    /// A field the stored session needs is blank or unparsable — which field
    /// is named by its ENGLISH label (`ConnectionField.labelDefault`), not a
    /// localization key, because CLI output is not localized.
    ///
    /// Replaced the SSH-specific `missingKeyPath` in M23/P2: naming a field by
    /// protocol meant an `authKind == .privateKey` branch inside a function
    /// whose whole point is not to have one. The schema already knows which
    /// fields are required and when, so this case carries the answer instead
    /// of re-deriving it.
    ///
    /// Carries a LABEL, never a value — a secret's contents must never reach
    /// an error message, a log line or the CLI's output.
    case incompleteConfiguration(field: String)
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

        let descriptor = BackendDescriptor.descriptor(for: session.kind)
        guard descriptor.hasStoredConfiguration(session) else {
            throw StoredSessionConnectionError.missingBackendConfiguration(kind: session.kind)
        }

        let values = descriptor.sessionValues(session)
        // The guards stay even though the factory would build without them:
        // failing here says which field is wrong, while failing at the server
        // says "access denied" with nothing pointing at the cause.
        //
        // `secretIsMandatory` is what keeps this from being a protocol branch
        // -- it already answers "can this backend build a config without a
        // secret at all", including SSH's agent case (no secret exists) and
        // its unencrypted-key case (a passphrase is looked for but not
        // demanded), where refusing would be wrong.
        if descriptor.secretIsMandatory(for: values), secret?.isEmpty != false {
            throw StoredSessionConnectionError.secretRequired
        }
        // `requireSecrets: false` because the secret is not IN `values` -- it
        // arrives as the parameter and was just checked above. This call is
        // for the non-secret fields: a private-key session with no key path, a
        // blank host, an unparsable port.
        if let violation = descriptor.firstViolation(in: values, requireSecrets: false) {
            throw StoredSessionConnectionError.incompleteConfiguration(
                field: descriptor.fieldLabel(forKey: violation.fieldKey))
        }
        return try descriptor.makeConfig(values, secret ?? "")
    }
}
