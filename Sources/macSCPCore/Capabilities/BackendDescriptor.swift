/// The static, connection-free description of a protocol (M12): its
/// capabilities, its connection-form schema/presets, a badge label, and its
/// (currently empty) contribution lists. One per `ConnectionKind`.
public struct BackendDescriptor: Sendable {
    public let kind: ConnectionKind
    public let capabilities: ProtocolCapabilities
    public let connectionSchema: ConnectionFieldSchema
    public let credentialSchema: ConnectionFieldSchema

    /// Turns collected form values plus the resolved secret into a runtime
    /// config. The backend switches over its OWN field enum inside here, so
    /// the compiler checks that a newly added field is handled.
    public let makeConfig: @Sendable (FieldValues, String) throws -> ConnectionConfig

    /// A human label for the sidebar, the tab title and the audit trail.
    /// Before M22 those built `user@host` from fields S3 and WebDAV never
    /// fill, which is why the audit log carried `host: "unused"`.
    public let displaySummary: @Sendable (FieldValues) -> String

    /// Opens a connection. Living here rather than in a central dispatcher
    /// is what lets `BackendConnector` disappear (Task 10).
    public let connect: @Sendable (
        ConnectionConfig,
        @escaping ConnectionViewModel.HostKeyDecider,
        @escaping WebDAVSessionDelegate.CertificateDecider
    ) async throws -> any RemoteFileSystem

    public let badgeLabelKey: String
    public let badgeLabelDefault: String

    /// The environment variable the CLI reads this backend's secret from.
    /// S3 uses the AWS-conventional name so existing pipelines need not
    /// relearn one; nil means the backend needs no secret.
    public let secretEnvironmentVariable: String?

    /// Whether connecting needs a secret at all.
    ///
    /// A closure, not a `Bool`, because for SSH the answer depends on the
    /// chosen auth kind: agent authentication needs none. A static `true`
    /// would make the CLI refuse an agent-auth connection for a missing
    /// `MACSCP_PASSWORD` that ssh-agent never wanted — which is exactly the
    /// guard `CLISecretSources` carries today and Task 10 must preserve.
    public let requiresSecret: @Sendable (FieldValues) -> Bool

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
        connectionSchema: SSHFieldSchema.connection,
        credentialSchema: SSHFieldSchema.credential,
        makeConfig: { values, secret in try SSHFieldSchema.makeConfig(values, secret) },
        displaySummary: { values in SSHFieldSchema.displaySummary(values) },
        connect: { config, decider, _ in
            guard case .ssh(let ssh) = config else {
                throw RemoteFSError.protocolError(reason: "wrong config for the SSH backend")
            }
            return try await CitadelFileSystem.connect(
                config: ssh,
                knownHosts: KnownHostsStore(directory: SessionStore.defaultDirectory),
                onUnknownHostKey: decider)
        },
        badgeLabelKey: "connection.badge.ssh", badgeLabelDefault: "SSH",
        secretEnvironmentVariable: "MACSCP_PASSWORD",
        // The one backend whose answer depends on the values: ssh-agent holds
        // the key material, so nothing may be asked of the user or the
        // environment for it.
        requiresSecret: { values in
            values[SSHField.authKind] != StoredSession.AuthKind.agent.rawValue
        },
        fileActions: [], connectionActions: [])

    static let s3Descriptor = BackendDescriptor(
        kind: .s3,
        capabilities: ProtocolCapabilities(
            supportsShell: false, permissionModel: .none, supportsSymlinks: false,
            atomicRename: false, directoriesAreReal: false, resumeMode: .rangeGet,
            supportsPresignedURL: true, transport: .optionalTLS),
        connectionSchema: S3FieldSchema.connection,
        credentialSchema: S3FieldSchema.credential,
        makeConfig: { values, secret in try S3FieldSchema.makeConfig(values, secret) },
        displaySummary: { values in S3FieldSchema.displaySummary(values) },
        connect: { config, _, _ in
            guard case .s3(let s3) = config else {
                throw RemoteFSError.protocolError(reason: "wrong config for the S3 backend")
            }
            return try await S3FileSystem.connect(s3)
        },
        badgeLabelKey: "connection.badge.s3", badgeLabelDefault: "S3",
        secretEnvironmentVariable: "AWS_SECRET_ACCESS_KEY", requiresSecret: { _ in true },
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
        connectionSchema: WebDAVFieldSchema.connection,
        credentialSchema: WebDAVFieldSchema.credential,
        makeConfig: { values, secret in try WebDAVFieldSchema.makeConfig(values, secret) },
        displaySummary: { values in WebDAVFieldSchema.displaySummary(values) },
        connect: { config, _, certificateDecider in
            guard case .webdav(let webdav) = config else {
                throw RemoteFSError.protocolError(reason: "wrong config for the WebDAV backend")
            }
            return try await WebDAVFileSystem.connect(
                webdav,
                trustStore: TrustedCertificateStore(directory: SessionStore.defaultDirectory),
                decider: certificateDecider)
        },
        badgeLabelKey: "connection.badge.webdav", badgeLabelDefault: "WebDAV",
        secretEnvironmentVariable: "MACSCP_PASSWORD", requiresSecret: { _ in true },
        fileActions: [], connectionActions: [])
}
