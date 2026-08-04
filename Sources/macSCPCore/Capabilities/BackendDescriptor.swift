/// The static, connection-free description of a protocol (M12): its
/// capabilities, its connection-form schema/presets, a badge label, and its
/// (currently empty) contribution lists. One per `ConnectionKind`.
public struct BackendDescriptor: Sendable, Equatable {
    public let kind: ConnectionKind
    public let capabilities: ProtocolCapabilities
    public let fieldSchema: ConnectionFieldSchema
    public let badgeLabelKey: String
    public let badgeLabelDefault: String
    public let fileActions: [FileActionContribution]
    public let connectionActions: [ConnectionActionContribution]

    public static func descriptor(for kind: ConnectionKind) -> BackendDescriptor {
        switch kind {
        case .ssh: return .sshDescriptor
        case .s3: return .s3Descriptor
        case .webdav: return .webdavDescriptor
        }
    }

    static let sshDescriptor = BackendDescriptor(
        kind: .ssh,
        capabilities: ProtocolCapabilities(
            supportsShell: true, permissionModel: .posixMode, supportsSymlinks: true,
            atomicRename: true, directoriesAreReal: true, resumeMode: .append,
            supportsPresignedURL: false, transport: .alwaysEncrypted),
        // SSH keeps its bespoke form sections (Task 7), so its schema is empty.
        fieldSchema: ConnectionFieldSchema(fields: [], presets: []),
        badgeLabelKey: "connection.badge.ssh", badgeLabelDefault: "SSH",
        fileActions: [], connectionActions: [])

    static let s3Descriptor = BackendDescriptor(
        kind: .s3,
        capabilities: ProtocolCapabilities(
            supportsShell: false, permissionModel: .none, supportsSymlinks: false,
            atomicRename: false, directoriesAreReal: false, resumeMode: .rangeGet,
            supportsPresignedURL: true, transport: .optionalTLS),
        fieldSchema: ConnectionFieldSchema(
            fields: [
                ConnectionField(id: "endpoint", labelKey: "connection.s3.endpoint", labelDefault: "Endpoint", kind: .text),
                ConnectionField(id: "region", labelKey: "connection.s3.region", labelDefault: "Region", kind: .text),
                ConnectionField(id: "bucket", labelKey: "connection.s3.bucket", labelDefault: "Bucket", kind: .text),
                ConnectionField(id: "accessKeyID", labelKey: "connection.s3.accessKey", labelDefault: "Access Key ID", kind: .text),
                ConnectionField(id: "secretAccessKey", labelKey: "connection.s3.secretKey", labelDefault: "Secret Access Key", kind: .secret),
                ConnectionField(id: "usePathStyle", labelKey: "connection.s3.pathStyle", labelDefault: "Use path-style URLs", kind: .toggle),
            ],
            presets: [
                ConnectionPreset(id: "aws", nameKey: "connection.s3.preset.aws", nameDefault: "Amazon S3",
                    values: ["endpoint": "https://s3.amazonaws.com", "usePathStyle": "false"]),
                ConnectionPreset(id: "hetzner", nameKey: "connection.s3.preset.hetzner", nameDefault: "Hetzner Object Storage",
                    values: ["endpoint": "https://fsn1.your-objectstorage.com", "usePathStyle": "true"]),
                ConnectionPreset(id: "custom", nameKey: "connection.s3.preset.custom", nameDefault: "Custom", values: [:]),
            ]),
        badgeLabelKey: "connection.badge.s3", badgeLabelDefault: "S3",
        fileActions: [
            FileActionContribution(id: "s3.presignedURL", titleKey: "browser.action.presignedURL", titleDefault: "Share Link…"),
        ], connectionActions: [])

    /// The two capability axes that deliberately flip against S3 (M21): real
    /// directories and atomic rename, the exact two WebDAV actually has and
    /// S3 does not. Everything else mirrors S3 -- no shell, no POSIX
    /// permissions, no symlinks, range-GET resume, no presigned URLs, and
    /// optional TLS (WebDAV is commonly run over plain HTTP on a home NAS).
    static let webdavDescriptor = BackendDescriptor(
        kind: .webdav,
        capabilities: ProtocolCapabilities(
            supportsShell: false, permissionModel: .none, supportsSymlinks: false,
            atomicRename: true, directoriesAreReal: true, resumeMode: .rangeGet,
            supportsPresignedURL: false, transport: .optionalTLS),
        fieldSchema: ConnectionFieldSchema(
            fields: [
                ConnectionField(id: "baseURL", labelKey: "connection.webdav.baseURL",
                                labelDefault: "Server URL", kind: .text),
                ConnectionField(id: "username", labelKey: "connection.webdav.username",
                                labelDefault: "User name", kind: .text),
                ConnectionField(id: "password", labelKey: "connection.webdav.password",
                                labelDefault: "Password", kind: .secret),
                ConnectionField(id: "useNextcloudPath", labelKey: "connection.webdav.nextcloudPath",
                                labelDefault: "Append Nextcloud path", kind: .toggle),
            ],
            presets: [
                // Sets only the toggle: the server origin is the user's, and a
                // preset that guessed at it would be wrong for everyone.
                ConnectionPreset(id: "nextcloud", nameKey: "connection.webdav.preset.nextcloud",
                                 nameDefault: "Nextcloud / ownCloud",
                                 values: ["useNextcloudPath": "true"]),
                ConnectionPreset(id: "custom", nameKey: "connection.webdav.preset.custom",
                                 nameDefault: "Custom",
                                 values: ["useNextcloudPath": "false"]),
            ]),
        badgeLabelKey: "connection.badge.webdav", badgeLabelDefault: "WebDAV",
        fileActions: [], connectionActions: [])
}
