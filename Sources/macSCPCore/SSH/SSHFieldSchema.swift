import Foundation

/// SSH's field identifiers — the single source for its two schemas, its
/// config factory and its persistence adapter (M22).
public enum SSHField: String, CaseIterable, BackendFieldID {
    case host, port, username, authKind, keyPath, managedKeyID, password, passphrase, jump

    public static let namespace = "SSHField"
}

/// The jump host's own login (M10c). A separate enum because a `.group` holds
/// `LeafField`, which cannot nest further — one level is all SSH needs.
///
/// What keeps the jump's `host` from overwriting the target's is the `jump.`
/// path segment, NOT this namespace: `FieldValues` stores a group member under
/// `"\(G.namespace).\(group).\(leaf)"` — the OWNER's namespace — so
/// `SSHJumpField.namespace` is never used for storage at all. It exists
/// because `BackendFieldID` requires it. Reading a jump field through the
/// one-argument subscript (`values[SSHJumpField.host]`) would therefore
/// address `SSHJumpField.host`, a key nothing ever writes; always subscript
/// with the pair (`values[SSHField.jump, SSHJumpField.host]`).
public enum SSHJumpField: String, CaseIterable, BackendFieldID {
    case host, port, username, authKind, keyPath, managedKeyID, password

    public static let namespace = "SSHJumpField"
}

/// SSH's data-driven registration (M22). Everything the generic layers need
/// to know about SSH lives here; nothing outside branches on `.ssh`.
public enum SSHFieldSchema {
    /// The three auth kinds, addressed by `StoredSession.AuthKind`'s raw
    /// values so a picked option is the persisted value, with no mapping
    /// table in between. Label keys and defaults are the ones the form has
    /// used since M3b/M10d, so no catalog entry has to be invented.
    private static let authOptions = [
        FieldOption(id: StoredSession.AuthKind.password.rawValue,
                    labelKey: "connection.auth.password", labelDefault: "Password"),
        FieldOption(id: StoredSession.AuthKind.privateKey.rawValue,
                    labelKey: "connection.auth.privateKey", labelDefault: "SSH key"),
        FieldOption(id: StoredSession.AuthKind.agent.rawValue,
                    labelKey: "connection.auth.agent", labelDefault: "Agent"),
    ]

    private static let onPrivateKey = FieldCondition(
        field: SSHField.authKind.rawValue,
        equals: StoredSession.AuthKind.privateKey.rawValue)

    private static let onPassword = FieldCondition(
        field: SSHField.authKind.rawValue,
        equals: StoredSession.AuthKind.password.rawValue)

    /// The jump host's login. Its leaves carry no condition today — but not
    /// because they may not: since M22/T7 a leaf's condition resolves against
    /// the GROUP-QUALIFIED namespace (`SSHField.jump`), which
    /// `ConnectionFieldSchema.visibleLeaves` builds from the owner rather than
    /// taking from its caller. A condition added here therefore keys off the
    /// JUMP's own field, never the target's. Nothing has needed one yet.
    private static let jumpLeaves: [LeafField] = [
        LeafField(id: SSHJumpField.host.rawValue, labelKey: "connection.field.host",
                  labelDefault: "Host", kind: .text),
        LeafField(id: SSHJumpField.port.rawValue, labelKey: "connection.field.port",
                  labelDefault: "Port", kind: .number),
        LeafField(id: SSHJumpField.username.rawValue, labelKey: "connection.field.username",
                  labelDefault: "Username", kind: .text),
        LeafField(id: SSHJumpField.authKind.rawValue, labelKey: "connection.field.authMethod",
                  labelDefault: "Authentication", kind: .picker(.fixed(authOptions))),
        // The one secret that stays in the connection schema. A nested login
        // has no credential schema of its own to move to — the credential
        // schema describes ONE login, and the jump is a second one.
        LeafField(id: SSHJumpField.password.rawValue, labelKey: "connection.auth.password",
                  labelDefault: "Password", kind: .secret),
        LeafField(id: SSHJumpField.keyPath.rawValue, labelKey: "connection.field.keyPath",
                  labelDefault: "Key path", kind: .text),
        LeafField(id: SSHJumpField.managedKeyID.rawValue, labelKey: "keys.picker.managed",
                  labelDefault: "Managed key", kind: .picker(.managedKeys)),
    ]

    /// What the connection itself owns: where to dial, and the optional hop
    /// to dial it through. Everything that identifies the LOGIN — user name,
    /// auth kind, key path, managed key, both secrets — lives in `credential`
    /// below, the same split S3 (M22/T4) and WebDAV (M22/T5) got.
    ///
    /// M22/T8 completed that split for SSH. Until the form rendered both
    /// schemas the overlap was invisible; once `formBlocks` concatenates them
    /// (connection, then the credential schema or the login-set picker that
    /// substitutes it), a field named by both draws TWO rows — and in
    /// login-set mode the connection copy would keep asking for credentials
    /// the chosen set already supplies.
    public static let connection = ConnectionFieldSchema(
        fields: [
            // `host` and `port` here, plus `username` in the credential
            // schema, are the endpoint triple the session importer has keyed
            // duplicates on since M9a — M23/P3 turned that from a `switch
            // kind` inside `SessionImportPlanner` into this declaration. The
            // host is the ONE case-folded identity anywhere: DNS is
            // case-insensitive, so `WEB-01` and `web-01` are one machine.
            ConnectionField(id: SSHField.host.rawValue,
                            labelKey: "connection.field.host",
                            labelDefault: "Host", kind: .text,
                            isRequired: true,
                            invalidMessageKey: "core.connect.emptyHost",
                            identity: .caseInsensitive),
            // A bastion reached on 2222 is not the box on 22.
            ConnectionField(id: SSHField.port.rawValue,
                            labelKey: "connection.field.port",
                            labelDefault: "Port", kind: .number,
                            format: .numeric,
                            invalidMessageKey: "core.connect.portNumeric",
                            identity: .verbatim),
            ConnectionField(id: SSHField.jump.rawValue, labelKey: "form.jump.label",
                            labelDefault: "Jump host", kind: .group(jumpLeaves)),
        ],
        presets: [])

    /// What a brand-new SSH form starts with. A port field the user has to
    /// fill in by hand would be a regression against every version since M2a,
    /// and an empty auth kind renders the picker blank with nothing selected.
    public static let defaults: FieldValues = {
        var values = FieldValues()
        values[SSHField.port] = "22"
        values[SSHField.authKind] = StoredSession.AuthKind.password.rawValue
        values[SSHField.jump, SSHJumpField.port] = "22"
        values[SSHField.jump, SSHJumpField.authKind] =
            StoredSession.AuthKind.password.rawValue
        return values
    }()

    /// What a login set carries: the credentials, not the host. Rendered by
    /// the login-set editor — and, since M22/T8, by the connection form too,
    /// as the block `formBlocks` places after the login-mode switcher. That
    /// is why `username`/`authKind`/`keyPath`/`managedKeyID` live HERE and
    /// only here: choosing a login set substitutes this whole block, and a
    /// second copy in `connection` would keep asking for what the set
    /// already supplies.
    ///
    /// The secret is two DIFFERENT fields, not one slot with two meanings —
    /// which is what the login-set editor has rendered since M10d: a
    /// "Password" row under `.password`, a "Passphrase (optional)" row under
    /// `.privateKey`, and NO secret row at all under `.agent` (spec §5.2).
    /// Two conditional fields describe that exactly; one unconditional field
    /// would grow a meaningless secret box for agent logins.
    public static let credential = ConnectionFieldSchema(
        fields: [
            // The third of the endpoint triple. VERBATIM, unlike the host:
            // POSIX user names are case-sensitive, and `root` is not `Root`.
            ConnectionField(id: SSHField.username.rawValue,
                            labelKey: "connection.field.username",
                            labelDefault: "Username", kind: .text,
                            isRequired: true,
                            invalidMessageKey: "core.connect.emptyUsername",
                            identity: .verbatim),
            ConnectionField(id: SSHField.authKind.rawValue,
                            labelKey: "connection.field.authMethod",
                            labelDefault: "Authentication",
                            kind: .picker(.fixed(authOptions))),
            ConnectionField(id: SSHField.password.rawValue,
                            labelKey: "connection.auth.password",
                            labelDefault: "Password", kind: .secret,
                            visibleWhen: onPassword,
                            isRequired: true,
                            invalidMessageKey: "core.connect.passwordEmpty",
                            secretRole: .credential),
            // The passphrase stays OPTIONAL: an unencrypted key has none, and
            // `makeConfig` already turns an empty secret into `nil` rather
            // than an empty passphrase. Its role is `.passphrase`, not
            // `.credential`: it unlocks the key file `keyPath` already names,
            // so it does not identify the login on its own.
            ConnectionField(id: SSHField.passphrase.rawValue,
                            labelKey: "connection.field.passphrase",
                            labelDefault: "Passphrase (optional)", kind: .secret,
                            visibleWhen: onPrivateKey,
                            secretRole: .passphrase),
            ConnectionField(id: SSHField.keyPath.rawValue,
                            labelKey: "connection.field.keyPath",
                            labelDefault: "Key path", kind: .text,
                            visibleWhen: onPrivateKey,
                            isRequired: true,
                            invalidMessageKey: "core.connect.keyPathEmpty"),
            ConnectionField(id: SSHField.managedKeyID.rawValue,
                            labelKey: "keys.picker.managed",
                            labelDefault: "Managed key",
                            kind: .picker(.managedKeys), visibleWhen: onPrivateKey),
        ],
        presets: [])

    /// The port these values name, or SSH's default.
    ///
    /// One reader for what used to be three identical parses (`makeConfig`,
    /// `displaySummary`, `apply`) plus a fourth in `endpoint(_:)` below. The
    /// trimming is the load-bearing half: a port of `"2222\n"` used to fail
    /// `Int(_:)` and fall through to 22, dialling the wrong port in silence
    /// (M23/T5 fix round 1).
    public static func port(_ values: FieldValues) -> Int {
        Int(values[SSHField.port].trimmingCharacters(in: .whitespacesAndNewlines)) ?? 22
    }

    /// Where a diagnosis points for this session (`BackendDescriptor
    /// .endpoint`): the TARGET's host and port, never the jump host's. A
    /// bastion is how the connection gets there; the endpoint is where it is
    /// going, and a resolve step that reported the bastion would be
    /// diagnosing a different machine than the one that failed.
    public static func endpoint(_ values: FieldValues) -> Endpoint? {
        let host = values[SSHField.host].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else { return nil }
        return Endpoint(host: host, port: port(values))
    }

    public static func makeConfig(
        _ values: FieldValues, _ secret: String
    ) throws -> ConnectionConfig {
        // The switch is exhaustive, so a case added to `SSHField` cannot reach
        // this factory without an arm here. That buys ACKNOWLEDGMENT, not
        // correctness: appending the new case to an existing `break` arm
        // satisfies the compiler while deciding nothing, which is why every
        // arm below states what it decided rather than falling silent.
        //
        // Unlike S3 and WebDAV, SSH validates
        // nothing in this loop: `SSHConnectionConfig.init` is the
        // ONE source of validation errors (its `ConfigError` cases are what
        // the App maps to localized messages), so re-checking here would
        // shadow those with an unlocalized reason.
        for field in SSHField.allCases {
            switch field {
            case .host, .port, .username, .keyPath:
                break  // validated by SSHConnectionConfig.init below
            case .authKind:
                break  // selects the auth branch below
            case .password, .passphrase:
                // Never read from values: the resolved secret arrives as the
                // parameter, and `authKind` below decides what it means.
                break
            case .managedKeyID:
                break  // a picker that writes `keyPath`; nothing of its own to build
            case .jump:
                // Deliberately NOT built here, and the returned config's
                // `jump` is therefore always nil: a jump host has its own
                // secret in a separate Keychain entry (`JumpSpec.secretID`)
                // and this factory takes exactly one secret, so it
                // structurally cannot resolve the second. The caller that can
                // attaches the jump after resolution. Pinned by
                // `makeConfigLeavesTheJumpToTheCaller` so a config that
                // silently bypassed a required bastion cannot slip in.
                break
            }
        }

        let auth: SSHConnectionConfig.AuthMethod
        switch values[SSHField.authKind] {
        case StoredSession.AuthKind.privateKey.rawValue:
            // An unencrypted key has no passphrase — an empty secret must
            // stay nil rather than become an empty one.
            auth = .privateKey(
                keyPath: values[SSHField.keyPath]
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                passphrase: secret.isEmpty ? nil : secret)
        case StoredSession.AuthKind.agent.rawValue:
            // Agent auth carries no secret: an empty one must not become an
            // empty password, which a server would reject confusingly.
            auth = .agent
        default:
            auth = .password(secret)
        }
        return .ssh(try SSHConnectionConfig(
            host: values[SSHField.host].trimmingCharacters(in: .whitespacesAndNewlines),
            // Trimmed like every other field here: a padded port used to fall
            // through to the 22 default and silently dial the wrong port.
            //
            // `.whitespacesAndNewlines`, matching what `firstViolation` trims
            // before its `.numeric` check (M23/T5 fix round 1). While this
            // trimmed only `.whitespaces`, a port of "2222\n" passed validation
            // and then fell through to the 22 default right here — the exact
            // silent-wrong-port bug the line above exists to prevent.
            port: port(values),
            username: values[SSHField.username]
                .trimmingCharacters(in: .whitespacesAndNewlines),
            auth: auth))
    }

    /// User name and host — what identifies an SSH connection to a human.
    ///
    /// The port is appended only when it differs from the default 22
    /// (M22/T11 fix round 1): the port is what tells apart two sessions to
    /// the SAME host on different ports — a bastion with a forwarded port is
    /// the ordinary case, e.g. `admin@homelab:22` next to
    /// `admin@homelab:2222` in the sidebar — while suppressing the default
    /// keeps a bare `:22` out of every ordinary tab title. Parsed the same
    /// way `makeConfig` parses the port (trimmed, falling back to 22), so an
    /// empty or unparsable port field — a hand-built `FieldValues` in a test,
    /// never `sessionValues`, which always writes `String(session.port)` —
    /// is treated as the default and never leaves a dangling trailing `:`.
    public static func displaySummary(_ values: FieldValues) -> String {
        let base = "\(values[SSHField.username])@\(values[SSHField.host])"
        let port = Self.port(values)
        return port == 22 ? base : "\(base):\(port)"
    }

    // MARK: - Persistence adapter

    /// The on-disk format is unchanged; this translates in both directions.
    ///
    /// Deliberately covers the flat connection fields only:
    /// * `password` and `passphrase` live in the Keychain, never in
    ///   `StoredSession`.
    /// * `managedKeyID` has no persisted home — picking a managed key writes
    ///   its file path into `keyPath`, which is the only thing stored.
    /// * `jump` is a second login with its own Keychain slot and its own
    ///   login-set/session bindings; it stays with the caller that owns those.
    public static func values(from session: StoredSession) -> FieldValues {
        // A record whose kind says `.ssh` but carries no block is dropped when
        // the store loads (M26), so this cannot be reached through the app --
        // it is the structural counterpart of that rule, and it puts SSH on
        // the same footing as the other two backends, whose `sessionValues`
        // has always returned the empty bag for a missing block.
        guard let ssh = session.ssh else { return FieldValues() }
        var values = FieldValues()
        values[SSHField.host] = ssh.host
        values[SSHField.port] = String(ssh.port)
        values[SSHField.username] = ssh.username
        values[SSHField.authKind] = ssh.authKind.rawValue
        values[SSHField.keyPath] = session.keyPath ?? ""
        return values
    }

    /// A login set's credentials in schema shape (M22/T9): exactly the fields
    /// `credential` renders, so the login-set editor, the connection form and
    /// the resolver all speak one vocabulary and a WebDAV set needs no code of
    /// its own anywhere.
    ///
    /// The SECRET is deliberately absent — it lives in the Keychain under the
    /// set's id, and `LoginResolver.resolve` writes it into whichever secret
    /// field the schema says is visible. `managedKeyID` has no persisted home
    /// either: picking a managed key writes its file path into `keyPath`.
    public static func values(from set: LoginSet) -> FieldValues {
        var values = FieldValues()
        values[SSHField.username] = set.username
        values[SSHField.authKind] = set.authKind.rawValue
        values[SSHField.keyPath] = set.keyPath ?? ""
        return values
    }

    /// The set a filled-in credential form describes. `id` and `name` are the
    /// editor's own bookkeeping rather than schema fields, so they come in
    /// from the caller.
    public static func loginSet(id: UUID, name: String, from values: FieldValues) -> LoginSet {
        let authKind = StoredSession.AuthKind(rawValue: values[SSHField.authKind]) ?? .password
        let keyPath = values[SSHField.keyPath].trimmingCharacters(in: .whitespacesAndNewlines)
        return LoginSet(
            id: id, name: name,
            username: values[SSHField.username]
                .trimmingCharacters(in: .whitespacesAndNewlines),
            authKind: authKind,
            // Same rule as `apply(_:to:)`: a key path belongs to private-key
            // auth, so switching away from it must clear the path rather than
            // leave a stale one on disk.
            keyPath: (authKind == .privateKey && !keyPath.isEmpty) ? keyPath : nil,
            kind: .ssh)
    }

    /// Writes ONLY the fields `SSHField` covers. `StoredSession` carries far
    /// more — group, login-set binding, jump spec, per-protocol configs — and
    /// rebuilding it from these values would silently drop them.
    ///
    /// Every text field is TRIMMED on the way in (M23/T7 fix round 1). The App
    /// used to trim host and user name at its save call sites; collapsing those
    /// onto this adapter moved the responsibility here, and `keyPath` below was
    /// already trimmed, so leaving the other two raw made this function
    /// inconsistent with itself. It is not cosmetic: `SessionImportPlanner`
    /// keys `.ssh` duplicates on the host/port/user triple byte for byte, so a
    /// trailing space turns a re-import into a silent duplicate instead of the
    /// conflict the user should be offered. No secret is trimmed here because
    /// none is written here — a `StoredSession` never holds one.
    /// Writing through `session.ssh` CREATES the SSH block when the session has
    /// none (M23/T8) — the jump spec is preserved because only the six fields
    /// below are overwritten, exactly as before the block existed.
    public static func apply(_ values: FieldValues, to session: inout StoredSession) {
        var ssh = session.ssh ?? StoredSSHConfig(host: "", username: "")
        ssh.host = values[SSHField.host].trimmingCharacters(in: .whitespacesAndNewlines)
        // `.whitespacesAndNewlines` like every other field here (M23/T8): the
        // port used to trim only `.whitespaces`, which disagreed with
        // `makeConfig` and `displaySummary` on a value carrying a newline.
        ssh.port = port(values)
        ssh.username = values[SSHField.username]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let kind = StoredSession.AuthKind(rawValue: values[SSHField.authKind]) {
            ssh.authKind = kind
        }
        // A key path belongs to private-key auth: switching away from it must
        // clear the path rather than leave a stale one on disk.
        let path = values[SSHField.keyPath].trimmingCharacters(in: .whitespacesAndNewlines)
        ssh.keyPath = (ssh.authKind == .privateKey && !path.isEmpty) ? path : nil
        session.ssh = ssh
    }
}
