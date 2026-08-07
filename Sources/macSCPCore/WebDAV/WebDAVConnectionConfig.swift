import Foundation

/// The persisted, SECRET-FREE WebDAV parameters — stored in
/// `StoredSession.webdav`/exports. The password is never here; it lives only
/// in the Keychain (`SecretStore`), like the SSH password and the S3 secret.
public struct StoredWebDAVConfig: Equatable, Codable, Sendable {
    /// Server origin, optionally with a base path
    /// (`https://dav.example.com/dav`). For Nextcloud the origin alone is
    /// enough — see `useNextcloudPath`.
    public var baseURL: String
    public var username: String
    /// Appends `/remote.php/dav/files/<username>/` to `baseURL`. Set by the
    /// Nextcloud preset; the one accommodation the design allows.
    public var useNextcloudPath: Bool

    public init(baseURL: String, username: String, useNextcloudPath: Bool) {
        self.baseURL = baseURL
        self.username = username
        self.useNextcloudPath = useNextcloudPath
    }
}

/// The RUNTIME WebDAV connect config: the persisted fields PLUS the transient
/// secret. NOT Codable — never persisted.
public struct WebDAVConnectionConfig: Equatable, Sendable {
    public var baseURL: String
    public var username: String
    public var useNextcloudPath: Bool
    /// Warning: plaintext secret — never log, interpolate or persist it.
    public var password: String

    public init(baseURL: String, username: String, useNextcloudPath: Bool, password: String) {
        self.baseURL = baseURL
        self.username = username
        self.useNextcloudPath = useNextcloudPath
        self.password = password
    }

    /// True when credentials would travel in the clear under Basic auth. Read
    /// by the App to require an explicit confirmation (spec §Klartext-HTTP).
    public var isPlaintextTransport: Bool {
        baseURL.lowercased().hasPrefix("http://")
    }
}
