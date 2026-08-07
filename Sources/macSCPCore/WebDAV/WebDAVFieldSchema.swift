import Foundation

/// WebDAV's field identifiers — the single source for its two schemas, its
/// config factory and its persistence adapter (M22).
public enum WebDAVField: String, CaseIterable, BackendFieldID {
    case baseURL, username, password, useNextcloudPath

    public static let namespace = "WebDAVField"
}

/// WebDAV's data-driven registration (M22). Everything the generic layers
/// need to know about WebDAV lives here; nothing outside branches on
/// `.webdav`.
public enum WebDAVFieldSchema {
    public static let connection = ConnectionFieldSchema(
        fields: [
            ConnectionField(id: WebDAVField.baseURL.rawValue,
                            labelKey: "connection.webdav.baseURL",
                            labelDefault: "Server URL", kind: .text,
                            isRequired: true,
                            invalidMessageKey: "core.connect.webdavFieldRequired"),
            ConnectionField(id: WebDAVField.useNextcloudPath.rawValue,
                            labelKey: "connection.webdav.nextcloudPath",
                            labelDefault: "Append Nextcloud path", kind: .toggle),
        ],
        presets: [
            // Sets only the toggle: the server origin is the user's, and a
            // preset that guessed at it would be wrong for everyone.
            ConnectionPreset(id: "nextcloud", nameKey: "connection.webdav.preset.nextcloud",
                             nameDefault: "Nextcloud / ownCloud",
                             values: [WebDAVField.useNextcloudPath.rawValue: "true"]),
            ConnectionPreset(id: "custom", nameKey: "connection.webdav.preset.custom",
                             nameDefault: "Custom",
                             values: [WebDAVField.useNextcloudPath.rawValue: "false"]),
        ])

    /// What a brand-new WebDAV form starts with (M22/T8) — see
    /// `S3FieldSchema.defaults` for why the toggle is written out.
    public static let defaults: FieldValues = {
        var values = FieldValues()
        values[bool: WebDAVField.useNextcloudPath] = false
        return values
    }()

    /// What a login set carries: the credentials, not the server. Rendered
    /// by the login-set editor with the same generic code as the form.
    public static let credential = ConnectionFieldSchema(
        fields: [
            ConnectionField(id: WebDAVField.username.rawValue,
                            labelKey: "connection.webdav.username",
                            labelDefault: "User name", kind: .text,
                            isRequired: true,
                            invalidMessageKey: "core.connect.webdavFieldRequired"),
            ConnectionField(id: WebDAVField.password.rawValue,
                            labelKey: "connection.webdav.password",
                            labelDefault: "Password", kind: .secret,
                            isRequired: true,
                            invalidMessageKey: "core.connect.webdavFieldRequired"),
        ],
        presets: [])

    public static func makeConfig(
        _ values: FieldValues, _ secret: String
    ) throws -> ConnectionConfig {
        // The switch is exhaustive, so a case added to `WebDAVField` cannot
        // reach this factory without an arm here. That buys ACKNOWLEDGMENT,
        // not correctness: appending the new case to the `break` arm below
        // satisfies the compiler while deciding nothing. Which is why that
        // arm says why each of its fields needs no check — a new case joining
        // it has to fit the stated reason or move out.
        for field in WebDAVField.allCases {
            switch field {
            case .baseURL:
                guard !values[WebDAVField.baseURL].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                else { throw RemoteFSError.connectionFailed(reason: "Enter the server URL") }
            case .username, .password, .useNextcloudPath:
                // `useNextcloudPath` is a toggle whose every value is valid.
                // The other two belong to the LOGIN, not the server address,
                // and the secret does not even come from `values` — it
                // arrives as the parameter, resolved from the Keychain or a
                // login set by the caller, so there is nothing here to check
                // it against.
                break
            }
        }
        return .webdav(WebDAVConnectionConfig(
            baseURL: values[WebDAVField.baseURL].trimmingCharacters(in: .whitespacesAndNewlines),
            username: values[WebDAVField.username].trimmingCharacters(in: .whitespacesAndNewlines),
            useNextcloudPath: values[bool: WebDAVField.useNextcloudPath],
            password: secret))
    }

    /// User name and host — what identifies a WebDAV connection to a human.
    public static func displaySummary(_ values: FieldValues) -> String {
        let host = URL(string: values[WebDAVField.baseURL])?.host() ?? values[WebDAVField.baseURL]
        return "\(values[WebDAVField.username]) @ \(host)"
    }

    // MARK: - Persistence adapter

    /// The on-disk format is unchanged; this translates in both directions.
    public static func values(from stored: StoredWebDAVConfig) -> FieldValues {
        var values = FieldValues()
        values[WebDAVField.baseURL] = stored.baseURL
        values[WebDAVField.username] = stored.username
        values[bool: WebDAVField.useNextcloudPath] = stored.useNextcloudPath
        // password deliberately absent: it lives in the Keychain.
        return values
    }

    /// A login set's credentials in schema shape (M22/T9) — see
    /// `SSHFieldSchema.values(from:)`.
    ///
    /// `LoginSet` needs no WebDAV column of its own: a WebDAV login is a user
    /// name plus a password, and those are exactly the shared `username`
    /// column and the shared Keychain slot every other backend already uses.
    /// `baseURL`/`useNextcloudPath` belong to the CONNECTION schema, i.e. to
    /// the session — a login set that carried a server URL would be a
    /// connection, not a login.
    public static func values(from set: LoginSet) -> FieldValues {
        var values = FieldValues()
        values[WebDAVField.username] = set.username
        return values
    }

    /// The set a filled-in credential form describes. `authKind` is SSH's
    /// column; `.password` is the only value that means anything for WebDAV
    /// and is what the row badge and the export format already read.
    public static func loginSet(id: UUID, name: String, from values: FieldValues) -> LoginSet {
        LoginSet(
            id: id, name: name,
            username: values[WebDAVField.username]
                .trimmingCharacters(in: .whitespacesAndNewlines),
            authKind: .password, keyPath: nil, kind: .webdav)
    }

    public static func stored(from values: FieldValues) -> StoredWebDAVConfig {
        StoredWebDAVConfig(
            baseURL: values[WebDAVField.baseURL], username: values[WebDAVField.username],
            useNextcloudPath: values[bool: WebDAVField.useNextcloudPath])
    }

    /// Writes ONLY the fields `WebDAVField` covers — same contract as
    /// `SSHFieldSchema.apply(_:to:)` and `S3FieldSchema.apply(_:to:)`.
    public static func apply(_ values: FieldValues, to session: inout StoredSession) {
        session.webdav = stored(from: values)
    }
}
