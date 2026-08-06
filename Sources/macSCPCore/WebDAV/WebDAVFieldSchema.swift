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
                            labelDefault: "Server URL", kind: .text),
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

    /// What a login set carries: the credentials, not the server. Rendered
    /// by the login-set editor with the same generic code as the form.
    public static let credential = ConnectionFieldSchema(
        fields: [
            ConnectionField(id: WebDAVField.username.rawValue,
                            labelKey: "connection.webdav.username",
                            labelDefault: "User name", kind: .text),
            ConnectionField(id: WebDAVField.password.rawValue,
                            labelKey: "connection.webdav.password",
                            labelDefault: "Password", kind: .secret),
        ],
        presets: [])

    public static func makeConfig(
        _ values: FieldValues, _ secret: String
    ) throws -> ConnectionConfig {
        // Switching over the field enum is what makes the compiler check that
        // a newly added field was considered here.
        for field in WebDAVField.allCases {
            switch field {
            case .baseURL:
                guard !values[WebDAVField.baseURL].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                else { throw RemoteFSError.connectionFailed(reason: "Enter the server URL") }
            case .username, .password, .useNextcloudPath:
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

    public static func stored(from values: FieldValues) -> StoredWebDAVConfig {
        StoredWebDAVConfig(
            baseURL: values[WebDAVField.baseURL], username: values[WebDAVField.username],
            useNextcloudPath: values[bool: WebDAVField.useNextcloudPath])
    }
}
