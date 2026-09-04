import Foundation
import NIOCore

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

    /// Writes collected form values back into a stored session — the write
    /// counterpart to the read-only `sessionValues(_:)` (M23).
    ///
    /// MUTATES IN PLACE, never reconstructs. `StoredSession` carries group
    /// assignment, login-set binding and per-protocol blocks that a rebuilding
    /// adapter would silently drop; `BackendApplyTests` pins that for all
    /// three backends by populating exactly those fields before applying.
    ///
    /// A stored member rather than a computed `switch` (unlike `sessionValues`)
    /// for consistency with its sibling closures `makeConfig`, `displaySummary`
    /// and `connect` — not because a test needs a synthetic adapter to exercise
    /// (the one synthetic descriptor, in `SchemaConformanceTests`, passes an
    /// empty `apply` that is never called; `BackendApplyTests` and friends
    /// call the three real descriptors' own `apply` directly).
    public let apply: @Sendable (FieldValues, inout StoredSession) -> Void

    /// Opens a connection. Living here rather than in a central dispatcher is
    /// what dissolved the last `ConnectionKind` switch on the connect path
    /// (M22/T10): each backend brings its own trust store -- SSH its
    /// known-hosts store, WebDAV its trusted-certificate store -- and a
    /// mismatch in either is a hard stop the deciders below never get asked
    /// about.
    /// The last argument is the connection-establishment timeout in seconds
    /// (`SettingsStore.connectTimeoutSeconds`). Only the SSH closure below
    /// actually uses it (forwarded to `CitadelFileSystem.connect`).
    ///
    /// Unlike a host-key decider, which is genuinely SSH-only (S3 and
    /// WebDAV have their own, separate certificate decider), a connect
    /// timeout is a meaningful setting for EVERY
    /// backend — S3 and WebDAV's own HTTP clients have connect-timeout
    /// knobs of their own. Their closures below currently drop this
    /// argument on the floor and keep using their transport's own default,
    /// which means the value the user configured is silently ignored for
    /// those two backends. That gap is real, out of this task's scope, and
    /// tracked separately rather than fixed here — the parameter is
    /// declared on the shared closure type now so wiring it into S3/WebDAV
    /// later is a one-line change per backend, not a signature change.
    ///
    /// Module-internal, unlike the descriptor's other stored members: see
    /// `openConnection(_:hostKey:certificate:timeoutSeconds:)` below for why
    /// the closure itself is out of reach from outside Core.
    let connect: @Sendable (
        ConnectionConfig,
        HostKeyDecider,
        WebDAVSessionDelegate.CertificateDecider,
        Int
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

    /// The host and port a diagnosis probes for these values, read from the
    /// backend's own fields (design §2).
    ///
    /// This is what keeps `ConnectionDiagnostics` free of any mention of a
    /// `ConnectionKind`: the resolve and TCP steps ask the descriptor where
    /// to point, and a fourth backend answers the same question without a
    /// line changing in the runner. `nil` when the values name no address at
    /// all — an incomplete form, which the runner reports as a step it could
    /// not run rather than as a server that is down.
    public let endpoint: @Sendable (FieldValues) -> Endpoint?

    /// The backend's OWN connection attempt, as one diagnostic row — the
    /// step between the universal probes and the contributions. `nil` for a
    /// backend that has nothing to dial.
    ///
    /// Its own member rather than the first element of `diagnostics` below,
    /// because the order is fixed by the design and the network trace lands
    /// BETWEEN the dial and the contributions (design §2.5, Task 3): a dial
    /// hidden inside the contribution list could not be placed there without
    /// the runner counting elements.
    public let dial: DiagnosticContribution?

    /// The protocol's own probes, run after the dial (design §3).
    ///
    /// S3 and WebDAV each carry one (`ContributionProbes`): what the key may
    /// do, and what the server claims to be. SSH carries none — its question
    /// is the negotiation NIOSSH already knows after a connect (KEX,
    /// host-key type, cipher, which auth method succeeded), and the fork
    /// exposes no observer to read it from yet, so the row would have to
    /// guess at exactly the thing somebody opened the panel to check.
    public let diagnostics: [DiagnosticContribution]

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

    /// What the EDIT form starts from before the stored session's own values
    /// are merged on top -- `ConnectionViewModel.beginEditing` -- as opposed
    /// to `defaultValues` above, which is what a brand-new form starts from.
    ///
    /// Identical to `defaultValues` for SSH and WebDAV, where a form always
    /// has real values to merge in (an S3-style "assumed" default has no
    /// equivalent there yet). S3 is the one exception: its region default is
    /// an ASSUMPTION about third-party servers that belongs on a blank new
    /// form, never silently substituted for a saved session's own (possibly
    /// missing) region -- see `S3FieldSchema.editBaseline`. A session whose
    /// S3 block is missing must show an EMPTY region and fail Save with
    /// `core.connect.s3RegionRequired`, not resurrect the assumed default.
    public var editBaseline: FieldValues {
        switch kind {
        case .ssh: return SSHFieldSchema.defaults
        case .s3: return S3FieldSchema.editBaseline
        case .webdav: return WebDAVFieldSchema.defaults
        }
    }

    /// The field values a BARE ENDPOINT makes for this backend — `--host`
    /// and `--port` on `macscp-cli diagnose`, which points a diagnosis at a
    /// machine nobody has saved a session for.
    ///
    /// `editBaseline` with this backend's own address field(s) written, so
    /// the answer is `endpoint(_:)`'s input by construction: SSH carries a
    /// host and a port as two fields, S3 and WebDAV carry one URL-shaped
    /// string each, and the caller needs to know none of that.
    ///
    /// `port` is optional and means "whatever this backend's address field
    /// says by itself": SSH keeps `editBaseline`'s 22, and the two
    /// URL-shaped fields keep the 443 their `https` scheme implies
    /// (`Endpoint(url:)`). `BackendDescriptorEndpointValuesTests` pins the
    /// round trip through `endpoint(_:)` for all three, with and without a
    /// port.
    ///
    /// Lives here and not in the CLI for the reason `CLIErrorMapping` and
    /// `secretSources(for:passwordCommand:)` do: the CLI target has no test
    /// target, and "which field carries the host" is a per-backend decision
    /// that would otherwise be a second place a fourth backend has to be
    /// mentioned.
    public func endpointValues(host: String, port: Int?) -> FieldValues {
        var values = editBaseline
        switch kind {
        case .ssh:
            values[SSHField.host] = host
            if let port { values[SSHField.port] = String(port) }
        case .s3:
            values[S3Field.endpoint] = S3FieldSchema.endpointSpelling(host: host, port: port)
        case .webdav:
            values[WebDAVField.baseURL] = WebDAVFieldSchema.baseURLSpelling(
                host: host, port: port)
        }
        return values
    }

    /// Field ids the generic form renderer must NOT draw because the App
    /// draws them itself (`SchemaFormView.skipping`).
    ///
    /// Declared here rather than in the view: the App DOES have a test
    /// target (`Tests/macSCPAppKitTests`), but declaring the set in Core
    /// lets both Core and App guard it, and `skipping` is matched against
    /// top-level ids by string, so a renamed or restructured field would
    /// turn a skip into a silent no-op — or, worse, keep skipping a field
    /// nobody draws any more, which removes a row from the form with
    /// nothing failing anywhere.
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
    /// never is (it lives in the Keychain).
    ///
    /// A session whose `kind` says one thing but whose stored configuration
    /// block is missing yields the empty bag for all three backends
    /// (`SSHFieldSchema.values(from:)` guards on `session.ssh` since M26,
    /// matching the `session.s3`/`session.webdav` optionals `.s3`/`.webdav`
    /// always had). Callers still ask `hasStoredConfiguration(_:)` BEFORE
    /// reading values rather than inferring the answer from an empty bag
    /// (M23/P2): an empty bag is also what a hand-built `FieldValues` with no
    /// fields set looks like, so it is not on its own proof of a missing
    /// block.
    public func sessionValues(_ session: StoredSession) -> FieldValues {
        switch kind {
        case .ssh: return SSHFieldSchema.values(from: session)
        case .s3: return session.s3.map { S3FieldSchema.values(from: $0) } ?? FieldValues()
        case .webdav:
            return session.webdav.map { WebDAVFieldSchema.values(from: $0) } ?? FieldValues()
        }
    }

    /// Whether this session actually carries the stored block its `kind`
    /// claims (M23/P2).
    ///
    /// A computed answer rather than a check at each call site, because the
    /// three call sites disagreed: `buildS3` and `buildWebDAV` threw
    /// `missingBackendConfiguration`, while the SSH path had no such arm at
    /// all and surfaced a blank host as `ConfigError.emptyHost` instead. The
    /// shape is representable on disk on purpose — `StoredSession.init(from:)`
    /// accepts a record with no block so that one bad entry cannot fail the
    /// whole file — so every reader needs the same answer to the same question.
    public func hasStoredConfiguration(_ session: StoredSession) -> Bool {
        switch kind {
        case .ssh: return session.ssh != nil
        case .s3: return session.s3 != nil
        case .webdav: return session.webdav != nil
        }
    }

    /// The secret field this stored session currently shows, or nil when it
    /// needs none (M25).
    ///
    /// The schema's answer to "does this login carry a secret at all", asked
    /// via `sessionValues(_:)` and its `SSHField.authKind`/equivalent key
    /// rather than a raw `AuthKind` read — the placeholder M23 set out to
    /// remove. For a session that HAS its SSH block, only ssh-agent shows no
    /// secret field, so among those the nil case IS the agent case; it never
    /// arises for the other two backends at all, in or out of block, because
    /// neither declares a `visibleWhen` on its secret field.
    ///
    /// Deliberately does NOT ask `hasStoredConfiguration` itself. Its three
    /// callers want different things from a session whose block is missing —
    /// the CLI refuses it, both view-model paths carry on — and a member that
    /// guards sometimes would be worse than three callers asking their own
    /// question. Since M26 that missing-block case is symmetric across all
    /// three backends: `sessionValues(_:)` yields the empty bag, which this
    /// member reads no differently than any other bag with no `authKind` key
    /// set — the credential schema's own `visibleSecretField` decides what an
    /// absent key means. A blockless `.ssh` session therefore ALSO yields nil
    /// here, alongside the ssh-agent case above — but that shape is
    /// unreachable through the app: `SessionStore.load()` drops any `.ssh`
    /// record with no block before it is ever handed to a caller (the
    /// `removeAll(where: Self.dropsOnLoad)` sweep in `load()`), so only a
    /// test building `StoredSession`
    /// directly can observe it
    /// (`anSSHSessionWithoutItsBlockYieldsTheEmptyBag` in
    /// `BackendDescriptorTests`).
    public func visibleSecretField(for session: StoredSession) -> ConnectionField? {
        credentialSchema.visibleSecretField(
            in: sessionValues(session), namespace: fieldNamespace)
    }

    /// The login set's currently visible secret field, or nil when the set
    /// needs no secret at all (M28).
    ///
    /// The twin of the `StoredSession` question above, over `loginSetValues`
    /// instead of `sessionValues`. Both exist because "which field is the
    /// secret right now" is a schema question, and a login set answers it from
    /// its own values -- never from `LoginSet.authKind`, which is a separate
    /// column from `kind` (both are stored properties of `LoginSet`) and is
    /// copied verbatim out of an imported file
    /// (`LoginSetImportPlanner.makeSet` passes `fileSet.authKind` and
    /// `fileSet.kind` through unexamined), so the two can disagree. Only SSH's
    /// schema conditions anything on the auth kind, and only
    /// `SSHFieldSchema.values(from set:)` writes that key -- an `.s3` set's bag
    /// carries no `authKind` at all, so its unconditioned, required
    /// `secretAccessKey` field stays visible whatever the column says.
    public func visibleSecretField(for set: LoginSet) -> ConnectionField? {
        credentialSchema.visibleSecretField(
            in: loginSetValues(set), namespace: fieldNamespace)
    }

    /// The English label of the field a namespaced `FieldValues` key names, or
    /// the key itself when nothing matches (M23/P2).
    ///
    /// English rather than localized: the one caller renders CLI output, which
    /// is not localized. The fallback keeps a caller from printing nothing at
    /// all if a key ever arrives that no schema declares.
    public func fieldLabel(forKey key: String) -> String {
        let fields = connectionSchema.fields + credentialSchema.fields
        return fields.first { "\(fieldNamespace).\($0.id)" == key }?.labelDefault ?? key
    }

    /// The fields that make a connection of this backend DISTINCT (M23/P3) —
    /// what `SessionImportPlanner` builds its duplicate key from, in this
    /// order. Each one carries its own `identity`, saying how its value is
    /// compared.
    ///
    /// Both schemas are walked, connection first, because identity spans them:
    /// SSH's `username` and S3's `accessKeyID` live in the CREDENTIAL schema,
    /// and two logins to the same server are two connections, not one. Schema
    /// declaration order is the key's field order, so the rendering is stable
    /// without anyone maintaining a second list that could fall out of step
    /// with the schemas.
    ///
    /// Top-level fields only: a `.group` is a second login with its own
    /// Keychain slot (SSH's jump), and which bastion a connection is dialled
    /// through does not change WHICH connection it is.
    public var identifyingFields: [ConnectionField] {
        var result: [ConnectionField] = []
        for field in connectionSchema.fields where field.identity != nil {
            result.append(field)
        }
        for field in credentialSchema.fields where field.identity != nil {
            result.append(field)
        }
        return result
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

    /// The first rule these values break across BOTH of this backend's
    /// schemas (M23) — connection fields first, then credentials, which is the
    /// order the form renders them in, so the reported field is the topmost
    /// offending row rather than an arbitrary one.
    ///
    /// CALL-ORDER CONTRACT (M23/T7). The credential schema is walked
    /// unconditionally, including while the form is in login-set mode — where
    /// the App SUBSTITUTES that whole block with a kind-filtered picker
    /// (`FormBlock.loginSetPicker`). A violation reported against, say,
    /// `SSHField.password` would then outline a row that is not on screen.
    ///
    /// That cannot happen only because the App fills the selected set's values
    /// into the form BEFORE validating: `ConnectionFormView`'s Connect/Save
    /// actions run `resolveLoginSetForSubmit` first and proceed only when its
    /// refusal list is empty (M29-P2: `SessionListViewModel.prepareForSubmit(form:)`,
    /// which reaches `SessionListViewModel.resolveTargetLoginSet` ->
    /// `ConnectionViewModel.applyResolvedCredentials`; a dangling or
    /// wrong-kind set returns a refusal and never reaches validation at
    /// all). By the time `connect()`/`validateForEditSave()`
    /// call in here, the credential fields hold the set's own values.
    ///
    /// So this is a call-ORDER guarantee, not a structural one, and nothing
    /// tests the ordering. A future submit path that reaches `connect()` or
    /// `validateForEditSave()` without going through `resolveLoginSetForSubmit`
    /// reintroduces the off-screen highlight — as would a set that is itself
    /// incomplete (the login-set editor disables Save while a required field is
    /// empty, but an imported `logins.json` is not bound by that).
    public func firstViolation(
        in values: FieldValues, requireSecrets: Bool
    ) -> (messageKey: String, fieldKey: String)? {
        connectionSchema.firstViolation(
            in: values, namespace: fieldNamespace, requireSecrets: requireSecrets)
            ?? credentialSchema.firstViolation(
                in: values, namespace: fieldNamespace, requireSecrets: requireSecrets)
    }

    static let sshDescriptor = BackendDescriptor(
        kind: .ssh,
        capabilities: ProtocolCapabilities(
            supportsShell: true, permissionModel: .posixMode, supportsSymlinks: true,
            atomicRename: true, directoriesAreReal: true, resumeMode: .append,
            supportsPresignedURL: false, supportsRemoteChecksum: true,
            transport: .alwaysEncrypted),
        connectionSchema: SSHFieldSchema.connection,
        credentialSchema: SSHFieldSchema.credential,
        makeConfig: { values, secret in try SSHFieldSchema.makeConfig(values, secret) },
        displaySummary: { values in SSHFieldSchema.displaySummary(values) },
        apply: { values, session in SSHFieldSchema.apply(values, to: &session) },
        connect: { config, decider, _, connectTimeoutSeconds in
            guard case .ssh(let ssh) = config else {
                throw RemoteFSError.protocolError(reason: "wrong config for the SSH backend")
            }
            return try await CitadelFileSystem.connect(
                config: ssh,
                connectTimeout: .seconds(Int64(connectTimeoutSeconds)),
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
        fileActions: [],
        endpoint: { values in SSHFieldSchema.endpoint(values) },
        dial: .sshConnect, diagnostics: [])

    static let s3Descriptor = BackendDescriptor(
        kind: .s3,
        capabilities: ProtocolCapabilities(
            supportsShell: false, permissionModel: .none, supportsSymlinks: false,
            atomicRename: false, directoriesAreReal: false, resumeMode: .rangeGet,
            supportsPresignedURL: true, supportsRemoteChecksum: true,
            transport: .optionalTLS),
        connectionSchema: S3FieldSchema.connection,
        credentialSchema: S3FieldSchema.credential,
        makeConfig: { values, secret in try S3FieldSchema.makeConfig(values, secret) },
        displaySummary: { values in S3FieldSchema.displaySummary(values) },
        apply: { values, session in S3FieldSchema.apply(values, to: &session) },
        connect: { config, _, _, _ in
            guard case .s3(let s3) = config else {
                throw RemoteFSError.protocolError(reason: "wrong config for the S3 backend")
            }
            return try await S3FileSystem.connect(s3)
        },
        badgeLabelKey: "connection.badge.s3", badgeLabelDefault: "S3",
        secretEnvironmentVariable: "AWS_SECRET_ACCESS_KEY", requiresSecret: { _ in true },
        fileActions: [
            FileActionContribution(id: "s3.presignedURL", titleKey: "browser.action.presignedURL", titleDefault: "Share Link…"),
        ],
        endpoint: { values in S3FieldSchema.endpoint(values) },
        dial: .s3EndpointHead, diagnostics: [.s3AccessLevel])

    /// The capability axes that deliberately differ from S3 (M21): real
    /// directories and atomic rename, the two WebDAV actually has and S3
    /// does not -- and, the other way round, the two S3 has and WebDAV does
    /// not: presigned URLs and an answerable checksum question (S3 has the
    /// ETag; WebDAV publishes no digest this project reads, and
    /// `OC-Checksum` is an extension and its own case). The remaining five
    /// axes mirror S3: no shell, no POSIX permissions, no symlinks,
    /// range-GET resume, and optional TLS (WebDAV is commonly run over
    /// plain HTTP on a home NAS).
    static let webdavDescriptor = BackendDescriptor(
        kind: .webdav,
        capabilities: ProtocolCapabilities(
            supportsShell: false, permissionModel: .none, supportsSymlinks: false,
            atomicRename: true, directoriesAreReal: true, resumeMode: .rangeGet,
            supportsPresignedURL: false, supportsRemoteChecksum: false,
            transport: .optionalTLS),
        connectionSchema: WebDAVFieldSchema.connection,
        credentialSchema: WebDAVFieldSchema.credential,
        makeConfig: { values, secret in try WebDAVFieldSchema.makeConfig(values, secret) },
        displaySummary: { values in WebDAVFieldSchema.displaySummary(values) },
        apply: { values, session in WebDAVFieldSchema.apply(values, to: &session) },
        connect: { config, _, certificateDecider, _ in
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
        fileActions: [],
        endpoint: { values in WebDAVFieldSchema.endpoint(values) },
        dial: .webdavOptions, diagnostics: [.webdavClaims])
}

extension BackendDescriptor {
    /// The one way to open a connection from outside this module.
    ///
    /// `connect` itself is module-internal so that "dialing past the shared
    /// path" is not a violation a test has to find, but something that does
    /// not compile. Core's own tests import `@testable` and keep their
    /// access; the app and the command line do not have it.
    ///
    /// Routing stays where it was — `descriptor(for:)` picks the backend and
    /// the backend's own closure carries its trust store — so a mismatch is
    /// still a hard stop inside the backend and reaches no decider here.
    public static func openConnection(
        _ config: ConnectionConfig,
        hostKey: HostKeyDecider,
        certificate: WebDAVSessionDelegate.CertificateDecider,
        timeoutSeconds: Int
    ) async throws -> any RemoteFileSystem {
        try await descriptor(for: config.kind)
            .connect(config, hostKey, certificate, timeoutSeconds)
    }
}
