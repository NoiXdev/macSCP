import Foundation

/// The static, connection-free description of a protocol (M12): its
/// capabilities, its connection-form schema/presets, a badge label, and the
/// file actions it contributes to the context menu. One per `ConnectionKind`.
///
/// There is no connection-level action list: one shipped empty in M12 and was
/// still empty ten milestones later, so M22's final review removed it rather
/// than let an unused seam ossify. Diagnostics actions, if they ever land,
/// will be designed against a real caller.
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

    /// Opens a connection. Living here rather than in a central dispatcher is
    /// what dissolved the last `ConnectionKind` switch on the connect path
    /// (M22/T10): each backend brings its own trust store -- SSH its
    /// known-hosts store, WebDAV its trusted-certificate store -- and a
    /// mismatch in either is a hard stop the deciders below never get asked
    /// about.
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

    public static func descriptor(for kind: ConnectionKind) -> BackendDescriptor {
        switch kind {
        case .ssh: return .sshDescriptor
        case .s3: return .s3Descriptor
        case .webdav: return .webdavDescriptor
        }
    }

    /// The prefix this backend's field values are stored under — its field
    /// enum's own `namespace`, which the generic form renderer needs to build
    /// a key from a field id (M22/T8).
    public var fieldNamespace: String {
        switch kind {
        case .ssh: return SSHField.namespace
        case .s3: return S3Field.namespace
        case .webdav: return WebDAVField.namespace
        }
    }

    /// The values a brand-new form for this backend starts with (M22/T8) —
    /// SSH's port 22 and its `password` auth kind, the two toggles S3 and
    /// WebDAV render.
    ///
    /// A computed property rather than a stored member: adding one to the
    /// memberwise initializer would force every synthetic descriptor a test
    /// builds to name it, for a value only the form ever reads.
    public var defaultValues: FieldValues {
        switch kind {
        case .ssh: return SSHFieldSchema.defaults
        case .s3: return S3FieldSchema.defaults
        case .webdav: return WebDAVFieldSchema.defaults
        }
    }

    /// Field ids the generic form renderer must NOT draw because the App
    /// draws them itself (`SchemaFormView.skipping`).
    ///
    /// Declared here rather than in the view so it can be GUARDED: the App has
    /// no test target, and `skipping` is matched against top-level ids by
    /// string, so a renamed or restructured field would turn a skip into a
    /// silent no-op — or, worse, keep skipping a field nobody draws any more,
    /// which removes a row from the form with nothing failing anywhere.
    /// `BackendDescriptorTests` pins that every id in here is a real declared
    /// field AND a `.group`, the one shape today's vocabulary cannot express
    /// (see `SchemaFormView.skipping` for what would let the jump join the
    /// generically rendered fields).
    public static let customRenderedFieldIDs: Set<String> = [SSHField.jump.rawValue]

    /// The credential values a login set carries, in this backend's own field
    /// vocabulary (M22/T9) — the shape the credential schema renders and
    /// `LoginResolver.resolve` returns.
    ///
    /// A computed member for the same reason as `defaultValues`: adding it to
    /// the memberwise initializer would force every synthetic descriptor a
    /// test builds to name it.
    public func loginSetValues(_ set: LoginSet) -> FieldValues {
        switch kind {
        case .ssh: return SSHFieldSchema.values(from: set)
        case .s3: return S3FieldSchema.values(from: set)
        case .webdav: return WebDAVFieldSchema.values(from: set)
        }
    }

    /// A STORED session in this backend's own field vocabulary (M22/T10) —
    /// the shape `requiresSecret` reads, so the CLI can ask "does this session
    /// need a secret at all" without a `kind` branch of its own.
    ///
    /// Only the connection fields the backend persists are filled; the secret
    /// never is (it lives in the Keychain). A session whose `kind` says one
    /// thing but whose stored configuration block is missing yields the empty
    /// bag rather than trapping — reporting that inconsistency is
    /// `StoredSessionConnectionConfig.build`'s job
    /// (`missingBackendConfiguration`), not this adapter's.
    public func sessionValues(_ session: StoredSession) -> FieldValues {
        switch kind {
        case .ssh: return SSHFieldSchema.values(from: session)
        case .s3: return session.s3.map { S3FieldSchema.values(from: $0) } ?? FieldValues()
        case .webdav:
            return session.webdav.map { WebDAVFieldSchema.values(from: $0) } ?? FieldValues()
        }
    }

    /// The inverse: the set a filled-in credential form describes. This is
    /// what lets the login-set editor save a set of ANY kind without knowing
    /// one — including the WebDAV kind it refused to build before M22/T9.
    public func loginSet(id: UUID, name: String, from values: FieldValues) -> LoginSet {
        switch kind {
        case .ssh: return SSHFieldSchema.loginSet(id: id, name: name, from: values)
        case .s3: return S3FieldSchema.loginSet(id: id, name: name, from: values)
        case .webdav: return WebDAVFieldSchema.loginSet(id: id, name: name, from: values)
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
        fileActions: [])

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
        ])

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
        // No S3-style conventional variable name exists for WebDAV -- it
        // authenticates with a plain password (or a Nextcloud-style "app
        // password"), the same shape as SSH password auth, so this reuses the
        // SSH variable name rather than inventing a third one.
        secretEnvironmentVariable: "MACSCP_PASSWORD", requiresSecret: { _ in true },
        fileActions: [])
}
