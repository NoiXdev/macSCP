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
    ///
    /// `checked` names which of the chain's four possible links
    /// (`SecretSourceKind`, `CLISecretSources.swift`) this attempt actually
    /// walked, in the order it walked them. It is the caller's own
    /// `checkedSources` argument to `build`, passed straight through — since
    /// fix round 2 there is no derivation step here at all: the caller's
    /// chain builder (`secretSources(for:passwordCommand:keychainStore:
    /// keyStore:)`, or the App's `TunnelSecretSources.chain(for:keys:
    /// secrets:)`) tags each link's kind at the moment it appends it
    /// (`SecretChain`, `CLISecretSources.swift`), so this can only ever
    /// carry what the caller actually built. It names PLACES only: never a
    /// value, a path, or an environment variable's name. Empty only when a
    /// caller passed `checkedSources: []` explicitly (the many call sites —
    /// mostly tests — that build a session directly from a literal `secret`
    /// and never exercise this case); `CLIErrorMapping` renders that case by
    /// omitting the parenthetical entirely rather than naming zero places or
    /// guessing at four.
    case secretRequired(checked: [SecretSourceKind])
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

extension StoredSessionConnectionError {
    /// What this refusal IS, as one English sentence — the single spelling
    /// two surfaces read.
    ///
    /// `CLIErrorMapping.message(for:)` prints it behind its own "Error: "
    /// prefix on stderr, and `DialSupport.reason(for:)` writes it into the
    /// diagnostic log's `reason=`. It lived only in `CLIErrorMapping` until
    /// 2026-09-25, which is why the log had nothing: `DialSupport.classify`
    /// had no arm for this type at all, so every case fell to its `default:`
    /// and bridged to `NSError` as "The operation couldn't be completed.
    /// (macSCPCore.StoredSessionConnectionError error N.)" — the case's
    /// declaration index, in the one artifact a user pastes into a bug
    /// report (`docs/BACKLOG.md`, "A forwarding's `.secretRequired` renders
    /// as a case index in the diagnostic log").
    ///
    /// English, like every sentence the log and the CLI produce: the App
    /// translates the typed value, never this text.
    ///
    /// **What reaches it**: a connection kind, a field's English LABEL, and
    /// the names of the places a secret was looked for. Never a secret,
    /// never a path, never an environment variable's name — each case's own
    /// doc comment above says why its payload is safe, and
    /// `SecretSourceKind` is payload-free, so `.secretRequired` could not
    /// carry a value even if a caller tried.
    public var sentence: String {
        switch self {
        case .loginSetSessionsNotSupported:
            return "this session's credentials come from a login set, "
                + "which the CLI does not resolve yet"
        case .jumpSessionsNotSupported:
            return "this session dials through a jump host, "
                + "which the CLI does not resolve yet"
        case .missingBackendConfiguration(let kind):
            // Names the protocol exactly as the two per-protocol messages
            // this replaced did (M22/T10) — the descriptor's badge label
            // is the one English name each backend already carries.
            return "the stored session is missing its "
                + "\(BackendDescriptor.descriptor(for: kind).badgeLabelDefault) configuration"
        case .secretRequired(let checked):
            return Self.secretRequiredSentence(checked: checked)
        case .incompleteConfiguration(let field):
            return "the stored session's \(field) is missing or invalid"
        }
    }

    /// The "no secret available" sentence for `.secretRequired(checked:)`.
    /// `checked` is the exact set of places this invocation's chain walked
    /// (`SecretSourceKind`, `CLISecretSources.swift`), in the order it
    /// walked them — this only renders that list, it never adds to or
    /// trims it. An empty `checked` means the caller had no chain to name
    /// at all (see `StoredSessionConnectionConfig.build`'s doc comment);
    /// the parenthetical is left off entirely rather than naming zero
    /// places or guessing at all four, either of which would claim
    /// something that did not happen.
    private static func secretRequiredSentence(checked: [SecretSourceKind]) -> String {
        guard !checked.isEmpty else { return "no secret available" }
        return "no secret available (checked \(Self.englishList(checked.map(Self.placeName(for:)))))"
    }

    /// The fixed English name for one link — never a value, a path, or an
    /// environment variable's name (that is exactly what `SecretSourceKind`
    /// exists to keep out of reach here: it carries no such thing to name).
    private static func placeName(for kind: SecretSourceKind) -> String {
        switch kind {
        case .passwordCommand: return "--password-command"
        case .environment: return "the environment"
        case .keychain: return "the keychain"
        case .managedKeyPassphrase: return "the managed key's passphrase"
        }
    }

    /// Oxford-comma English list — "a", "a and b", "a, b, and c" — the shape
    /// the fixed three- and four-link sentences already used, generalized to
    /// however many `items` `secretRequiredSentence` actually has (one to
    /// four; never called with zero, which is handled before this).
    private static func englishList(_ items: [String]) -> String {
        switch items.count {
        case 0: return ""
        case 1: return items[0]
        case 2: return "\(items[0]) and \(items[1])"
        default: return "\(items.dropLast().joined(separator: ", ")), and \(items.last!)"
        }
    }
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
    /// - Parameters:
    ///   - checkedSources: which places the caller's chain actually held
    ///     when it produced `secret` — `TunnelConnection.connect`'s
    ///     `secrets.kinds` or `SessionConnecting.connect`'s `chain.kinds`,
    ///     both already in scope at their call sites (`SecretChain`,
    ///     `CLISecretSources.swift`). Named straight into
    ///     `.secretRequired(checked:)` if that is thrown — never
    ///     re-derived, re-resolved, or re-checked. No default (fix round
    ///     2): the 26 call sites (`grep -rn 'checkedSources: \[\]'
    ///     Sources/ Tests/` minus its four prose mentions, recounted
    ///     2026-09-24) that build a session directly from a literal
    ///     `secret` and never reach `.secretRequired` pass `[]` explicitly,
    ///     so a future THIRD production caller cannot silently forget this
    ///     and get the parenthetical-free rendering without it showing up
    ///     as a compile error demanding a decision.
    public static func build(
        for session: StoredSession, secret: String?,
        checkedSources: [SecretSourceKind]
    ) throws -> ConnectionConfig {
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
        // The secret guard asks the SCHEMA, not `requiresSecret`. The two are
        // different questions and only the schema answers this one:
        // `requiresSecret` means "should the CLI go LOOKING for a secret",
        // which is true under private-key auth (an encrypted key's passphrase
        // sits in the Keychain) where refusing without one would reject every
        // UNENCRYPTED key. Its three other callers all ask it the lookup way.
        //
        // The schema's `isRequired` on the currently visible secret field
        // answers all five configurations without a `kind` branch:
        //   ssh password   -> `password`, required     -> refuse
        //   ssh privateKey -> `passphrase`, optional   -> allow (unencrypted key)
        //   ssh agent      -> no secret field visible  -> allow
        //   s3             -> `secretAccessKey`, req.  -> refuse
        //   webdav         -> `password`, optional     -> allow (anonymous share)
        //
        // The last one CHANGED behaviour in M23/P2 and is deliberate: an
        // anonymous WebDAV share answers 200 with no `Authorization` header,
        // so the old refusal was a false negative on a configuration the
        // maintainer explicitly chose to support (see `WebDAVFieldSchema`'s
        // `credential`), and one the CLI could not reach at all. When auth IS
        // required and absent, the server answers 401, which `CLIErrorMapping`
        // already renders as "authentication failed" -- legible without a
        // local guard. S3 is the opposite and keeps its refusal: an empty
        // secret still produces a syntactically valid SigV4 signature, so the
        // server cannot tell "no credentials" from "wrong credentials" and
        // answers `SignatureDoesNotMatch`; there is no anonymous shape
        // `S3ConnectionConfig` can express at all.
        //
        // THE COST, stated so it is found rather than discovered: a WebDAV
        // session whose Keychain entry has gone missing now silently
        // downgrades to anonymous instead of being refused. The 401 covers an
        // auth-required share; it does NOT cover a public-read /
        // authenticated-write share, where the lost password surfaces as a 403
        // part-way through a transfer rather than as a refusal up front.
        //
        // `credentialSchema` rather than both schemas: every backend declares
        // its secret there, and it is the same schema `LoginResolver` asks
        // when deciding which Keychain slot a login means. `visibleSecretField
        // (for:)` below (M25) is what actually makes that choice now — this
        // call site no longer spells out `credentialSchema.visibleSecretField
        // (in:namespace:)` itself, but the choice it hands off to is the one
        // justified above.
        let secretField = descriptor.visibleSecretField(for: session)
        if secretField?.isRequired == true, secret?.isEmpty != false {
            throw StoredSessionConnectionError.secretRequired(checked: checkedSources)
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
