import Foundation

/// What is known about the host key of the machine a session dials.
///
/// Three states, not two: "we have never met this host" and "this protocol
/// has no host key to remember" are different sentences, and a view that
/// collapsed them would tell an S3 user their host key is unknown.
public enum HostKeyStatus: Sendable, Equatable {
    /// The key type and the SHA256 fingerprint of the remembered key —
    /// exactly what `KnownHostKey` already derives, never the blob itself.
    case known(type: String, fingerprint: String)
    /// An SSH session whose host is not in the known-hosts store: the next
    /// connect runs the TOFU prompt.
    case unknown
    /// A backend with no TOFU host key at all.
    case notApplicable
}

/// Everything the read-only session overview shows, derived from what is
/// stored (design: `docs/superpowers/specs/2026-09-04-session-overview-design.md`).
///
/// **No secret reaches this type.** The credential question is answered by
/// `SecretPresence`, which returns a `Bool` and has no way of carrying a
/// value; the two URL-shaped fields a user can type
/// `scheme://KEY:SECRET@host` into are stripped through
/// `URLText.withoutUserinfo` before they become a fact. Both halves are
/// pinned by `SessionOverviewModelTests`, which plants a value in each field
/// and asserts that no rendered text carries it.
///
/// A value, not an observable object: it is rebuilt from the store whenever
/// the selection changes, and holding it as state would be a second copy of
/// the session record that can go stale.
public struct SessionOverviewModel: Sendable, Equatable {
    /// One labelled line of the facts grid.
    ///
    /// `labelKey` is resolved by the App, out of its own catalogs — Core
    /// stays bundle-free for labels, exactly as `ConnectionField.labelKey`
    /// does. `text` is the VALUE, and it is data wherever a datum exists
    /// (a user name, a path, a host, a URL); only where the value is itself
    /// an enumerated word — an auth kind, a pane arrangement, a yes/no — is
    /// it looked up, and then out of Core's own catalog through `CoreL10n`,
    /// which is where Core's user-facing text lives.
    public struct Fact: Sendable, Equatable, Identifiable {
        public let id: String
        public let labelKey: String
        public let text: String
        /// Whether the value is a machine token (a path, a host, a
        /// fingerprint) that must not be re-wrapped or ligatured by a
        /// proportional face.
        public let isMonospaced: Bool

        public init(id: String, labelKey: String, text: String, isMonospaced: Bool = false) {
            self.id = id
            self.labelKey = labelKey
            self.text = text
            self.isMonospaced = isMonospaced
        }
    }

    public let name: String
    public let kind: ConnectionKind
    /// `host:port` as the descriptor itself resolves it
    /// (`BackendDescriptor.endpoint(_:)`), so a fourth backend needs no line
    /// here. Empty when the stored record names no address at all — an
    /// incomplete session, which the head shows as blank rather than as a
    /// fabricated default.
    public let endpointText: String
    public let facts: [Fact]
    public let hostKey: HostKeyStatus
    /// Whether a secret is stored for this session's slot, or `nil` when the
    /// backend needs none.
    ///
    /// `nil` is a third answer, not a missing one: ssh-agent holds the key
    /// material, so nothing is stored and nothing was asked. Reporting
    /// `false` there would read as "you forgot to save your password" for a
    /// login that never wanted one. The question is asked through
    /// `BackendDescriptor.requiresSecret`, so the agent case is the
    /// descriptor's answer rather than an `authKind` branch here.
    public let hasStoredSecret: Bool?
    public let history: [ConnectionHistory.Row]
    public let snippets: [Snippet]

    /// - Parameters:
    ///   - knownKey: what `KnownHostsStore.find(host:port:)` answered for
    ///     this session's endpoint, or `nil` for a host that is not
    ///     remembered — and `nil` for the two backends that have no host key
    ///     to look up, which resolve to `.notApplicable` regardless.
    ///   - secrets: the presence seam. Production hands it
    ///     `KeychainSecretPresence`; tests hand it a fake, and no test in
    ///     this project reads the real keychain.
    ///   - events: the session's audit log
    ///     (`AuditLogStore.events(for:)`), append order.
    ///   - groupName: the name of the group `session.groupID` points at, or
    ///     `nil` when the session is ungrouped or the caller could not
    ///     resolve it. A name, because `StoredSession` carries only the id
    ///     and a rendered UUID is worse than no row at all.
    ///   - loginSetName: the name of the login set that owns this session's
    ///     credential (`session.loginSetID`), or `nil` in manual mode. Same
    ///     reasoning as `groupName`.
    ///
    /// There is no `now`: nothing here renders a relative time. An open
    /// session's duration is `nil` rather than "elapsed so far" (see
    /// `ConnectionHistory.Row.Outcome`), and the import date is formatted
    /// absolutely, so a clock had no reader on either side of the call.
    public init(
        session: StoredSession, descriptor: BackendDescriptor, knownKey: KnownHostKey?,
        secrets: any SecretPresence, events: [AuditEvent], snippets: [Snippet],
        groupName: String? = nil, loginSetName: String? = nil
    ) {
        let values = descriptor.sessionValues(session)

        name = session.name
        kind = descriptor.kind
        endpointText = descriptor.endpoint(values)?.text ?? ""
        hostKey = Self.hostKeyStatus(kind: descriptor.kind, knownKey: knownKey)
        hasStoredSecret =
            descriptor.requiresSecret(values) ? secrets.hasSecret(for: session.secretSlot) : nil
        history = ConnectionHistory.rows(from: events)
        self.snippets = snippets
        facts = Self.facts(
            for: session, descriptor: descriptor, groupName: groupName,
            loginSetName: loginSetName)
    }

    // MARK: - Host key

    /// SSH is the only backend here with a TOFU host key, and there is no
    /// capability axis that says so — `ProtocolCapabilities` describes what
    /// a file system can do, not what a transport remembers — so this is a
    /// `kind` branch on purpose rather than by omission. It is exhaustive,
    /// so a fourth backend has to answer the question before this compiles.
    private static func hostKeyStatus(
        kind: ConnectionKind, knownKey: KnownHostKey?
    ) -> HostKeyStatus {
        switch kind {
        case .ssh:
            guard let knownKey else { return .unknown }
            return .known(type: knownKey.keyType, fingerprint: knownKey.fingerprintSHA256)
        case .s3, .webdav:
            return .notApplicable
        }
    }

    // MARK: - Facts

    /// The label keys the App resolves. Written here rather than spelled at
    /// each construction below, so the view's catalogue and this file agree
    /// by construction.
    private static func label(_ id: String) -> String { "overview.fact.\(id)" }

    /// The Core catalogue key for an auth kind's WORD.
    ///
    /// Internal rather than private so `SessionOverviewModelTests` can hold
    /// the resolved text against the key itself — `CoreL10n.string` returns
    /// the key when no catalogue declares it, and a test that spelled the
    /// key by hand would be a second copy of it.
    ///
    /// Exhaustive: a fourth `AuthKind` does not compile until it has a word.
    static func authTextKey(for authKind: StoredSession.AuthKind) -> String {
        switch authKind {
        case .password: return "core.overview.auth.password"
        case .privateKey: return "core.overview.auth.privateKey"
        case .agent: return "core.overview.auth.agent"
        }
    }

    private static func yesNo(_ value: Bool) -> String {
        CoreL10n.string(value ? "core.overview.value.yes" : "core.overview.value.no")
    }

    private static func paneText(_ panes: PaneVisibility) -> String {
        // `PaneVisibility` forbids "neither half visible", so three states
        // are all there are — the `else` below is the files-only one.
        if panes.showsFiles && panes.showsTerminal {
            return CoreL10n.string("core.overview.panes.both")
        }
        return CoreL10n.string(
            panes.showsTerminal ? "core.overview.panes.terminal" : "core.overview.panes.files")
    }

    private static func facts(
        for session: StoredSession, descriptor: BackendDescriptor,
        groupName: String?, loginSetName: String?
    ) -> [Fact] {
        var facts = backendFacts(
            for: session, descriptor: descriptor, loginSetName: loginSetName)

        if let groupName, !groupName.isEmpty {
            facts.append(Fact(id: "group", labelKey: label("group"), text: groupName))
        }
        if !session.tags.isEmpty {
            facts.append(
                Fact(id: "tags", labelKey: label("tags"), text: session.tags.joined(separator: ", ")))
        }
        facts.append(
            Fact(id: "panes", labelKey: label("panes"), text: paneText(session.paneVisibility)))
        if let source = session.importSource, !source.isEmpty {
            facts.append(
                Fact(id: "importedFrom", labelKey: label("importedFrom"), text: importText(source, session.importedAt)))
        }
        return facts
    }

    /// The source's id, plus WHEN it was imported where that is recorded.
    /// The date is formatted in the reader's own locale at the moment the
    /// model is built; the two are one sentence, so they are one fact rather
    /// than a fact and an orphaned timestamp.
    private static func importText(_ source: String, _ importedAt: Date?) -> String {
        guard let importedAt else { return source }
        return "\(source) — \(importedAt.formatted(date: .abbreviated, time: .shortened))"
    }

    /// The per-backend half, in the order the design lists it. Exhaustive
    /// over `ConnectionKind`, so a fourth backend has to say what it shows.
    private static func backendFacts(
        for session: StoredSession, descriptor: BackendDescriptor, loginSetName: String?
    ) -> [Fact] {
        switch descriptor.kind {
        case .ssh: return sshFacts(session, loginSetName)
        case .s3: return s3Facts(session, loginSetName)
        case .webdav: return webdavFacts(session, loginSetName)
        }
    }

    /// The set that owns this session's credential, where one does.
    ///
    /// Built here rather than at each of the three call sites so the three
    /// cannot drift on the id or the key. It is placed by each backend
    /// rather than appended centrally, because the design puts it directly
    /// after the credential facts — which for SSH means BEFORE the jump
    /// host, a second login that is not part of this one.
    private static func loginSetFact(_ name: String?) -> Fact? {
        guard let name, !name.isEmpty else { return nil }
        return Fact(id: "loginSet", labelKey: label("loginSet"), text: name)
    }

    /// Nothing at all for a `.ssh` record with no stored block. That shape
    /// cannot reach the app — `SessionStore.load()` drops it — but the model
    /// must answer rather than fabricate a host of `""` and a port of 22,
    /// which is the `"unused"` placeholder M23 removed, in a new spelling.
    private static func sshFacts(_ session: StoredSession, _ loginSetName: String?) -> [Fact] {
        guard let ssh = session.ssh else { return [] }
        var facts: [Fact] = []
        if !ssh.username.isEmpty {
            facts.append(
                Fact(id: "username", labelKey: label("username"), text: ssh.username, isMonospaced: true))
        }
        facts.append(
            Fact(
                id: "authentication", labelKey: label("authentication"),
                text: CoreL10n.string(authTextKey(for: ssh.authKind))))
        if let keyPath = ssh.keyPath, !keyPath.isEmpty {
            facts.append(
                Fact(id: "keyPath", labelKey: label("keyPath"), text: keyPath, isMonospaced: true))
        }
        if let fact = loginSetFact(loginSetName) { facts.append(fact) }
        if let jump = ssh.jump {
            // The HOST and the port, and nothing else — the same rule
            // `AuditRecorder.recordConnected(host:username:viaJumpHost:)`
            // keeps for the audit trail: a bastion's own login is a second
            // credential, and it has no business on a read-only overview.
            facts.append(
                Fact(
                    id: "jump", labelKey: label("jump"), text: "\(jump.host):\(jump.port)",
                    isMonospaced: true))
        }
        return facts
    }

    private static func s3Facts(_ session: StoredSession, _ loginSetName: String?) -> [Fact] {
        guard let s3 = session.s3 else { return [] }
        var facts: [Fact] = []
        // A connection rooted at the account's bucket list names no single
        // bucket, so the bucket fact says which of the two this is rather
        // than showing a bucket the session does not open at. A session that
        // is rooted at neither — no bucket, no bucket list — is an
        // incomplete record, and it gets NO row rather than a labelled blank
        // one, like every other empty datum here.
        if s3.startsAtBucketList {
            facts.append(
                Fact(
                    id: "bucket", labelKey: label("bucket"),
                    text: CoreL10n.string("core.overview.s3.bucketList")))
        } else if !s3.bucket.isEmpty {
            facts.append(
                Fact(id: "bucket", labelKey: label("bucket"), text: s3.bucket, isMonospaced: true))
        }
        if !s3.region.isEmpty {
            facts.append(
                Fact(id: "region", labelKey: label("region"), text: s3.region, isMonospaced: true))
        }
        if !s3.endpoint.isEmpty {
            facts.append(
                Fact(
                    id: "endpoint", labelKey: label("endpoint"),
                    text: URLText.withoutUserinfo(s3.endpoint), isMonospaced: true))
        }
        facts.append(
            Fact(id: "pathStyle", labelKey: label("pathStyle"), text: yesNo(s3.usePathStyle)))
        if let fact = loginSetFact(loginSetName) { facts.append(fact) }
        return facts
    }

    private static func webdavFacts(_ session: StoredSession, _ loginSetName: String?) -> [Fact] {
        guard let webdav = session.webdav else { return [] }
        var facts: [Fact] = []
        if !webdav.baseURL.isEmpty {
            // The one field a user can type `https://user:secret@host` into
            // and have it work, so it is stripped before it is shown. The
            // helper documents the one shape it cannot strip (a credential
            // containing a `/`); that hole is why the planted-secret tests
            // check the WHOLE rendered set rather than this fact alone.
            facts.append(
                Fact(
                    id: "baseURL", labelKey: label("baseURL"),
                    text: URLText.withoutUserinfo(webdav.baseURL), isMonospaced: true))
        }
        if !webdav.username.isEmpty {
            facts.append(
                Fact(
                    id: "username", labelKey: label("username"), text: webdav.username,
                    isMonospaced: true))
        }
        facts.append(
            Fact(
                id: "nextcloudPath", labelKey: label("nextcloudPath"),
                text: yesNo(webdav.useNextcloudPath)))
        if let fact = loginSetFact(loginSetName) { facts.append(fact) }
        return facts
    }
}
