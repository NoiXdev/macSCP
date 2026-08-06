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

    public static let connection = ConnectionFieldSchema(
        fields: [
            ConnectionField(id: SSHField.host.rawValue,
                            labelKey: "connection.field.host",
                            labelDefault: "Host", kind: .text),
            ConnectionField(id: SSHField.port.rawValue,
                            labelKey: "connection.field.port",
                            labelDefault: "Port", kind: .number),
            ConnectionField(id: SSHField.username.rawValue,
                            labelKey: "connection.field.username",
                            labelDefault: "Username", kind: .text),
            ConnectionField(id: SSHField.authKind.rawValue,
                            labelKey: "connection.field.authMethod",
                            labelDefault: "Authentication",
                            kind: .picker(.fixed(authOptions))),
            ConnectionField(id: SSHField.keyPath.rawValue,
                            labelKey: "connection.field.keyPath",
                            labelDefault: "Key path", kind: .text,
                            visibleWhen: onPrivateKey),
            // The options come from `ManagedKeyStore`, which lives in the App;
            // the schema names the source and the App resolves it.
            ConnectionField(id: SSHField.managedKeyID.rawValue,
                            labelKey: "keys.picker.managed",
                            labelDefault: "Managed key",
                            kind: .picker(.managedKeys), visibleWhen: onPrivateKey),
            ConnectionField(id: SSHField.jump.rawValue, labelKey: "form.jump.label",
                            labelDefault: "Jump host", kind: .group(jumpLeaves)),
        ],
        presets: [])

    /// What a login set carries: the credentials, not the host. Rendered by
    /// the login-set editor with the same generic code as the form.
    ///
    /// The secret is two DIFFERENT fields, not one slot with two meanings —
    /// which is what the login-set editor has rendered since M10d: a
    /// "Password" row under `.password`, a "Passphrase (optional)" row under
    /// `.privateKey`, and NO secret row at all under `.agent` (spec §5.2).
    /// Two conditional fields describe that exactly; one unconditional field
    /// would grow a meaningless secret box for agent logins.
    public static let credential = ConnectionFieldSchema(
        fields: [
            ConnectionField(id: SSHField.username.rawValue,
                            labelKey: "connection.field.username",
                            labelDefault: "Username", kind: .text),
            ConnectionField(id: SSHField.authKind.rawValue,
                            labelKey: "connection.field.authMethod",
                            labelDefault: "Authentication",
                            kind: .picker(.fixed(authOptions))),
            ConnectionField(id: SSHField.password.rawValue,
                            labelKey: "connection.auth.password",
                            labelDefault: "Password", kind: .secret,
                            visibleWhen: onPassword),
            ConnectionField(id: SSHField.passphrase.rawValue,
                            labelKey: "connection.field.passphrase",
                            labelDefault: "Passphrase (optional)", kind: .secret,
                            visibleWhen: onPrivateKey),
            ConnectionField(id: SSHField.keyPath.rawValue,
                            labelKey: "connection.field.keyPath",
                            labelDefault: "Key path", kind: .text,
                            visibleWhen: onPrivateKey),
            ConnectionField(id: SSHField.managedKeyID.rawValue,
                            labelKey: "keys.picker.managed",
                            labelDefault: "Managed key",
                            kind: .picker(.managedKeys), visibleWhen: onPrivateKey),
        ],
        presets: [])

    public static func makeConfig(
        _ values: FieldValues, _ secret: String
    ) throws -> ConnectionConfig {
        // Switching over the field enum is what makes the compiler check that
        // a newly added field was considered here. Unlike S3 and WebDAV, SSH
        // validates nothing in this loop: `SSHConnectionConfig.init` is the
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
            port: Int(values[SSHField.port]) ?? 22,
            username: values[SSHField.username]
                .trimmingCharacters(in: .whitespacesAndNewlines),
            auth: auth))
    }

    /// User name and host — what identifies an SSH connection to a human.
    public static func displaySummary(_ values: FieldValues) -> String {
        "\(values[SSHField.username])@\(values[SSHField.host])"
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
        var values = FieldValues()
        values[SSHField.host] = session.host
        values[SSHField.port] = String(session.port)
        values[SSHField.username] = session.username
        values[SSHField.authKind] = session.authKind.rawValue
        values[SSHField.keyPath] = session.keyPath ?? ""
        return values
    }

    /// Writes ONLY the fields `SSHField` covers. `StoredSession` carries far
    /// more — group, login-set binding, jump spec, per-protocol configs — and
    /// rebuilding it from these values would silently drop them.
    public static func apply(_ values: FieldValues, to session: inout StoredSession) {
        session.host = values[SSHField.host]
        session.port = Int(values[SSHField.port]) ?? 22
        session.username = values[SSHField.username]
        if let kind = StoredSession.AuthKind(rawValue: values[SSHField.authKind]) {
            session.authKind = kind
        }
        // A key path belongs to private-key auth: switching away from it must
        // clear the path rather than leave a stale one on disk.
        let path = values[SSHField.keyPath].trimmingCharacters(in: .whitespacesAndNewlines)
        session.keyPath = (session.authKind == .privateKey && !path.isEmpty) ? path : nil
    }
}
