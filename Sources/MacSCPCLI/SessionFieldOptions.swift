import ArgumentParser
import Foundation
import macSCPCore

/// Which panes a session opens with, as a flag value. `PaneVisibility` is a
/// pair of `Bool`s in Core and a two-value choice here: the command line
/// offers the two combinations a session is ever SAVED in, not the four the
/// type can express (`terminalOnly` is a live toggle state, never a stored
/// starting point).
enum PaneOption: String, CaseIterable, ExpressibleByArgument {
    case files
    case filesAndTerminal = "files-and-terminal"

    var visibility: PaneVisibility {
        switch self {
        case .files: return .filesOnly
        case .filesAndTerminal: return .bothVisible
        }
    }
}

/// The fields `sessions add` and `sessions edit` write, as one option group
/// both verbs declare — the flags of all three backends side by side, with
/// the rule for which flag belongs to which backend written once.
///
/// **No secret is here, and none can be added.** The S3 ACCESS KEY is a flag
/// because it is not a secret (it travels in every signed URL); the secret
/// access key, the SSH password and the key passphrase are not flags, are
/// not read from stdin, and are not written to the keychain by this tool at
/// all. A password-authenticated session created here is asked for its
/// password by the app on first connect, or answered by
/// `--password-command`/the environment on the command line's own
/// connections. `CLISessionsStoreEditingGuardTests` scans this file for the
/// four APIs that could break that.
///
/// Login sets and jump hosts are deliberately absent: both are app-side
/// concepts with their own sheets and their own secret slots, and neither
/// has a spelling here to get wrong.
struct SessionFieldOptions: ParsableArguments {
    // MARK: SSH

    @Option(name: .long, help: "SSH: the host to dial.")
    var host: String?

    @Option(name: .long, help: "SSH: the port to dial. Default 22.")
    var port: Int?

    @Option(name: .long, help: "SSH and WebDAV: the user name to log in as.")
    var user: String?

    @Option(name: .long, help: "SSH: path to a private key; the session authenticates with it.")
    var key: String?

    @Flag(name: .long, help: "SSH: authenticate through the local ssh-agent.")
    var agent = false

    // MARK: S3

    @Option(name: .long, help: "S3: the endpoint origin, e.g. https://s3.example.com.")
    var endpoint: String?

    @Option(name: .long, help: "S3: the bucket this session opens in.")
    var bucket: String?

    @Option(name: .long, help: "S3: the access key id. The secret key is never taken here.")
    var accessKey: String?

    @Option(name: .long, help: "S3: the region. Default us-east-1.")
    var region: String?

    @Flag(name: .long, help: "S3: address objects path-style (endpoint/bucket/key).")
    var pathStyle = false

    @Flag(name: .long, help: "S3: open at the account's bucket list rather than the bucket.")
    var bucketList = false

    // MARK: WebDAV

    @Option(name: .long, help: "WebDAV: the base URL, e.g. https://dav.example.com.")
    var url: String?

    @Flag(name: .long, help: "WebDAV: append the Nextcloud files path to the base URL.")
    var nextcloud = false

    // MARK: Every kind

    @Option(
        name: .long,
        help: #"File under this group path, e.g. "Work / Prod". Missing groups are created."#,
        completion: GroupTagCompletion.group)
    var group: String?

    @Option(
        name: .long, help: "A tag to carry. Repeat for several.",
        completion: GroupTagCompletion.tag)
    var tag: [String] = []

    @Option(name: .long, help: "Which panes this session opens with.")
    var pane: PaneOption?

    init() {}

    // MARK: - Which flag belongs to which backend

    /// Every kind-specific flag, the kinds it applies to, and whether this
    /// invocation gave it.
    ///
    /// ONE table, read by the refusal below and by nothing else — the
    /// alternative is a `switch` per verb, and two of those disagree the
    /// first time a flag moves. `--user` names two kinds because it really
    /// belongs to two; the entry carries a list rather than a single kind so
    /// that fact does not need a second shape to live in.
    ///
    /// The COMMON flags (`--group`, `--tag`, `--pane`) are absent on purpose:
    /// they apply to every kind, so no invocation of them can be refused.
    private var kindSpecificFlags: [(flag: String, kinds: [ConnectionKind], given: Bool)] {
        [
            ("--host", [.ssh], host != nil),
            ("--port", [.ssh], port != nil),
            ("--user", [.ssh, .webdav], user != nil),
            ("--key", [.ssh], key != nil),
            ("--agent", [.ssh], agent),
            ("--endpoint", [.s3], endpoint != nil),
            ("--bucket", [.s3], bucket != nil),
            ("--access-key", [.s3], accessKey != nil),
            ("--region", [.s3], region != nil),
            ("--path-style", [.s3], pathStyle),
            ("--bucket-list", [.s3], bucketList),
            ("--url", [.webdav], url != nil),
            ("--nextcloud", [.webdav], nextcloud),
        ]
    }

    /// Refuses a flag given for a kind it does not apply to.
    ///
    /// A refusal rather than a silent drop: `sessions add web --kind ssh
    /// --bucket backups` is a typed intention that cannot be carried out, and
    /// storing the session without the bucket would leave a person believing
    /// something the store does not say.
    func validateKindOwnership(_ kind: ConnectionKind) throws {
        for entry in kindSpecificFlags where entry.given && !entry.kinds.contains(kind) {
            throw ValidationError(
                "\(entry.flag) applies to --kind "
                    + entry.kinds.map(\.rawValue).joined(separator: ", "))
        }
    }

    /// The two ways to name an SSH login are alternatives, not layers.
    func validateAuthChoice() throws {
        guard key != nil, agent else { return }
        throw ValidationError("--key and --agent name two logins; give one")
    }

    // MARK: - What `add` writes

    /// The fields a kind cannot be stored without, in the order the design's
    /// table lists them — which is the order the refusals come in, so a
    /// script filling flags in reading order is told about the first one it
    /// is missing.
    private func requiredFields(for kind: ConnectionKind) -> [(flag: String, value: String?)] {
        switch kind {
        case .ssh: return [("--host", host), ("--user", user)]
        case .s3: return [("--endpoint", endpoint), ("--bucket", bucket), ("--access-key", accessKey)]
        case .webdav: return [("--url", url), ("--user", user)]
        }
    }

    func validateRequiredFields(for kind: ConnectionKind) throws {
        for field in requiredFields(for: kind) {
            _ = try required(field.value, field.flag, for: kind)
        }
    }

    private func required(_ value: String?, _ flag: String, for kind: ConnectionKind) throws -> String {
        guard let value, !value.isEmpty else {
            throw ValidationError("\(flag) is required for --kind \(kind.rawValue)")
        }
        return value
    }

    /// The session `add` writes.
    ///
    /// Throws the same `ValidationError`s the two checks above throw, so a
    /// caller may run it from `validate()` and discard the result — which is
    /// exactly what `SessionsAddCommand` does, because a usage error must
    /// leave with ArgumentParser's 64 rather than through `run()`, where
    /// `CLIErrorMapping` would read it as a connection failure.
    func newSession(named name: String, kind: ConnectionKind) throws -> StoredSession {
        try validateKindOwnership(kind)
        try validateAuthChoice()
        try validateRequiredFields(for: kind)

        var session = StoredSession(name: SessionNameRule.asSaved(name), kind: kind)
        switch kind {
        case .ssh:
            session.ssh = StoredSSHConfig(
                host: try required(host, "--host", for: kind),
                port: port ?? 22,
                username: try required(user, "--user", for: kind),
                authKind: authKind,
                keyPath: key)
        case .s3:
            session.s3 = StoredS3Config(
                accessKeyID: try required(accessKey, "--access-key", for: kind),
                region: region ?? "us-east-1",
                endpoint: try required(endpoint, "--endpoint", for: kind),
                bucket: try required(bucket, "--bucket", for: kind),
                usePathStyle: pathStyle,
                startsAtBucketList: bucketList)
        case .webdav:
            session.webdav = StoredWebDAVConfig(
                baseURL: try required(url, "--url", for: kind),
                username: try required(user, "--user", for: kind),
                useNextcloudPath: nextcloud)
        }
        session.tags = tag
        if let pane { session.paneVisibility = pane.visibility }
        return session
    }

    /// Password unless a key or the agent was named: the app asks for the
    /// password on first connect and stores it in its own slot, which is the
    /// one thing this tool cannot do for it.
    private var authKind: StoredSession.AuthKind {
        if key != nil { return .privateKey }
        if agent { return .agent }
        return .password
    }

    // MARK: - What `edit` changes

    /// The same session with EXACTLY the named fields changed.
    ///
    /// A flag left out changes nothing — which is why every field above is an
    /// Optional rather than a value with a default. The four `@Flag`s are the
    /// stated limit of that: a flag can be given or absent, never given as
    /// false, so `--path-style` turns path-style ON and there is no
    /// `--no-path-style` to turn it off again from here. The app's own form
    /// has the toggle; adding negative twins for four flags to a command line
    /// nobody has asked to turn them off from is a bigger surface than the
    /// gap.
    ///
    /// `--group` is NOT applied here: filing under a group path may have to
    /// CREATE groups, which is a store write, and this function is pure so
    /// `validate()` can run it. `SessionsEditCommand` applies the group.
    func edited(_ session: StoredSession, removingTags removed: [String]) -> StoredSession {
        var session = session
        if var ssh = session.ssh {
            if let host { ssh.host = host }
            if let port { ssh.port = port }
            if let user { ssh.username = user }
            if let key {
                ssh.keyPath = key
                ssh.authKind = .privateKey
            }
            if agent {
                ssh.keyPath = nil
                ssh.authKind = .agent
            }
            session.ssh = ssh
        }
        if var s3 = session.s3 {
            if let endpoint { s3.endpoint = endpoint }
            if let bucket { s3.bucket = bucket }
            if let accessKey { s3.accessKeyID = accessKey }
            if let region { s3.region = region }
            if pathStyle { s3.usePathStyle = true }
            if bucketList { s3.startsAtBucketList = true }
            session.s3 = s3
        }
        if var webdav = session.webdav {
            if let url { webdav.baseURL = url }
            if let user { webdav.username = user }
            if nextcloud { webdav.useNextcloudPath = true }
            session.webdav = webdav
        }

        // Removals first, so `--no-tag eu --tag eu` in one invocation ends
        // with the tag present rather than depending on which loop ran last.
        // Compared without case, the way `SessionCatalog`'s own `--tag`
        // filter compares: a tag a person cannot filter for by the spelling
        // they typed is not a tag they can remove by it either.
        var tags = session.tags
        tags.removeAll { existing in
            removed.contains { $0.caseInsensitiveCompare(existing) == .orderedSame }
        }
        tags.append(contentsOf: tag)
        // `StoredSession.tags`' own `didSet` trims and de-duplicates.
        session.tags = tags

        if let pane { session.paneVisibility = pane.visibility }
        return session
    }
}
