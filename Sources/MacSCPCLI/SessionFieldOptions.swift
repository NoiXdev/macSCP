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
/// both verbs declare — every backend's flags side by side, with the rule
/// for which flag belongs to which backend written once.
///
/// (Withdrawn wording, verbatim: "the flags of all three backends side by
/// side". FTP is the fourth, and a sentence that counts backends is a
/// cardinality this project's rules say to count in the moment or not write.)
///
/// **No secret is here, and none can be added.** The S3 ACCESS KEY is a flag
/// because it is not a secret (it travels in every signed URL); the secret
/// access key, the SSH and FTP passwords and the key passphrase are not
/// flags, are
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

    @Option(name: .long, help: "SSH and FTP: the host to dial.")
    var host: String?

    @Option(
        name: .long,
        help: "SSH and FTP: the port to dial. Default 22 for SSH, the security mode's for FTP.")
    var port: Int?

    @Option(
        name: .long,
        help: "SSH, WebDAV and FTP: the user name to log in as. Omit it for anonymous FTP.")
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

    // MARK: FTP

    /// The two fields FTP does not share with another backend. Its host,
    /// port and user name are `--host`, `--port` and `--user` above; its
    /// password is nowhere, like every other secret here.
    ///
    /// No DEFAULT on either: a flag left out must change nothing, which is
    /// what `edited(_:removingTags:)` depends on. The defaults FTP does have
    /// are the schema's — explicit FTPS and that mode's own port
    /// (`FTPFieldSchema.defaults`) — and `newSession` reads them from there
    /// rather than restating them.
    @Option(
        name: .long,
        help: "FTP: how the connection is protected. Default explicitTLS.")
    var security: FTPSecurityMode?

    @Option(name: .long, help: "FTP: the folder this session opens in.")
    var initialPath: String?

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

    /// FTP's flag for one of its fields, or `nil` for a field the command
    /// line does not carry.
    ///
    /// EXHAUSTIVE over `FTPField`, which is FTP's single source for which
    /// fields exist (`FTPFieldSchema` reads all of its schemas, its config
    /// factory and its persistence adapter off it): a field added there does
    /// not compile until someone says whether it has a flag here. That is
    /// this project's rule about a guard spelling a symbol it could read
    /// instead, applied to the ownership table below — FTP's column is the
    /// image of every case of that enum under this function, not a second
    /// copy of the field list.
    ///
    /// The sentence above deliberately does NOT spell the expression that
    /// enumerates those cases, and the reason is measured rather than
    /// stylistic: `CLISessionsStoreEditingGuardTests
    /// .theFieldOptionsFileExistsAndCarriesTheKindOwnershipTable` scans this
    /// file for that expression, and while this comment quoted it the scan
    /// was satisfied by the COMMENT. A probe that replaced the real call
    /// with a written-out list of four flags was caught by two behavioural
    /// cases and NOT by the scan (`scripts/mutation-probe`, 2026-11-08, FTP
    /// plan Task 10). CLAUDE.md's "Source-scanning guards read comments
    /// too", happening in the same commit as the guard it is about.
    ///
    /// `username` is `--user`, the flag SSH and WebDAV already carry for the
    /// same thing; a third spelling of one concept is what sharing it
    /// avoids. `password` has NO flag and cannot be given one — see this
    /// type's own header, and `CLISessionsStoreEditingGuardTests`, which
    /// scans this file for the four APIs that could change that.
    private static func flag(for field: FTPField) -> String? {
        switch field {
        case .host: return "--host"
        case .port: return "--port"
        case .security: return "--security"
        case .initialPath: return "--initial-path"
        case .username: return "--user"
        case .password: return nil
        }
    }

    /// Which flags each backend owns.
    ///
    /// FTP's list is READ OFF `FTPField`; the other three are written out,
    /// because their field enums (`SSHField`, `S3Field`, `WebDAVField`) do
    /// not drive this command line — their flags predate the data-driven
    /// schemas and are not a one-to-one image of any field set. Converting
    /// them is a change of its own, not a thing to do in passing while
    /// adding a fourth backend.
    private static func flags(owning kind: ConnectionKind) -> [String] {
        switch kind {
        case .ssh: return ["--host", "--port", "--user", "--key", "--agent"]
        case .s3:
            return [
                "--endpoint", "--bucket", "--access-key", "--region",
                "--path-style", "--bucket-list",
            ]
        case .webdav: return ["--url", "--user", "--nextcloud"]
        case .ftp: return FTPField.allCases.compactMap(flag(for:))
        }
    }

    /// Every kind-specific flag, the kinds it applies to, and whether this
    /// invocation gave it.
    ///
    /// ONE table, read by the refusal below and by nothing else — the
    /// alternative is a `switch` per verb, and two of those disagree the
    /// first time a flag moves. The kinds come from `flags(owning:)` rather
    /// than being written beside each flag, so the two directions —
    /// "which flags does this kind own" and "which kinds own this flag" —
    /// cannot disagree. `--user` therefore names every kind that really
    /// carries it without the fact needing a second shape to live in.
    ///
    /// (Withdrawn wording, verbatim: "`--user` names two kinds because it
    /// really belongs to two; the entry carries a list rather than a single
    /// kind so that fact does not need a second shape to live in." The
    /// entries no longer carry a list — they are given one — and `--user`
    /// belongs to three kinds since FTP arrived, which is the count the old
    /// sentence fixed in place.)
    ///
    /// The COMMON flags (`--group`, `--tag`, `--pane`) are absent on purpose:
    /// they apply to every kind, so no invocation of them can be refused.
    private var kindSpecificFlags: [(flag: String, kinds: [ConnectionKind], given: Bool)] {
        let given: [(flag: String, given: Bool)] = [
            ("--host", host != nil),
            ("--port", port != nil),
            ("--user", user != nil),
            ("--key", key != nil),
            ("--agent", agent),
            ("--endpoint", endpoint != nil),
            ("--bucket", bucket != nil),
            ("--access-key", accessKey != nil),
            ("--region", region != nil),
            ("--path-style", pathStyle),
            ("--bucket-list", bucketList),
            ("--url", url != nil),
            ("--nextcloud", nextcloud),
            ("--security", security != nil),
            ("--initial-path", initialPath != nil),
        ]
        return given.map { entry in
            (entry.flag,
             ConnectionKind.allCases.filter { Self.flags(owning: $0).contains(entry.flag) },
             entry.given)
        }
    }

    /// Refuses a flag given for a kind it does not apply to.
    ///
    /// A refusal rather than a silent drop: `sessions add web --kind ssh
    /// --bucket backups` is a typed intention that cannot be carried out, and
    /// storing the session without the bucket would leave a person believing
    /// something the store does not say.
    ///
    /// A flag that appears in the `given` list above and in no
    /// `flags(owning:)` list would be refused for EVERY kind, which is the
    /// safe direction — nothing is stored half-specified — and it is not
    /// left to be noticed by reading: the message states the owners, so an
    /// unowned flag prints an empty list, and
    /// `kindFTPIsAcceptedAndItsFlagsAreOfferedForItAlone` asserts the whole
    /// sentence for both of FTP's own flags.
    func validateKindOwnership(_ kind: ConnectionKind) throws {
        for entry in kindSpecificFlags where entry.given && !entry.kinds.contains(kind) {
            throw ValidationError(
                "\(entry.flag) applies to --kind "
                    + entry.kinds.map(\.rawValue).joined(separator: ", "))
        }
    }

    /// Every string-valued flag, paired with the value THIS invocation gave
    /// it — absent flags are not in the list, which is what makes the check
    /// below "every field that was given" rather than "every field".
    ///
    /// `--tag` is not here and does not need to be: `TagList.normalized`
    /// drops an empty tag on the way into `StoredSession.tags`, so
    /// `--tag ""` carries nothing rather than storing nothing-as-a-tag.
    ///
    /// `--initial-path` is not here for a DIFFERENT reason, and it is the
    /// one field where an empty value is a legitimate state rather than a
    /// mistake: blank means "whatever folder the server starts in"
    /// (`StoredFTPConfig.initialPath` is `nil` for exactly that), so
    /// `--initial-path ""` is how a person clears one from the command
    /// line. Refusing it would make the field writable and not erasable —
    /// the shape the four `@Flag`s have and state as their own limit. Both
    /// writers below map a blank to `nil`.
    private var givenStringValues: [(flag: String, value: String)] {
        [
            ("--host", host), ("--user", user), ("--key", key),
            ("--endpoint", endpoint), ("--bucket", bucket), ("--access-key", accessKey),
            ("--region", region), ("--url", url), ("--group", group),
        ].compactMap { flag, value in value.map { (flag, $0) } }
    }

    /// The checks that are about the VALUES rather than about which flags may
    /// appear — and the shared path `add` and `edit` both run.
    ///
    /// Sharing it is the point. `add` used to be the only careful one: its
    /// required fields go through `required(_:_:for:)`, which refuses an
    /// empty string as well as a missing one, while `edit` wrote whatever it
    /// was handed — so `sessions edit web --host ""` exited 0 and stored a
    /// session with no host, a record `SessionStore` keeps and nothing can
    /// dial (round-1 review, I1). A check on one side only is a check that
    /// looks satisfied from the side that has it.
    ///
    /// The port range is Core's own, not a number invented here:
    /// `SSHConnectionConfig` refuses anything outside `1...65535` at connect
    /// time, and the app's forwarding form states the same bounds. Enforcing
    /// it at the moment the value is typed turns a later, further-away
    /// failure into a usage error.
    func validateGivenValues() throws {
        for given in givenStringValues
        where given.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ValidationError("\(given.flag) cannot be empty")
        }
        if let port, !(1...65535).contains(port) {
            throw ValidationError("--port must be between 1 and 65535")
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
        // The HOST and nothing else. FTP's port follows the security mode
        // when it is left out, and NEITHER credential field is required —
        // `FTPFieldSchema.credential` marks them optional because anonymous
        // FTP is the oldest real deployment this protocol has, and `add`
        // must not be stricter than the form it writes records for.
        case .ftp: return [("--host", host)]
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
        try validateGivenValues()
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
        case .ftp:
            // The two defaults are the SCHEMA's, read from it rather than
            // written here: explicit FTPS is what a new form starts in
            // (`FTPFieldSchema.defaults` — the safe mode is the one nobody
            // has to choose), and the port that mode listens on is
            // `FTPSecurityMode.defaultPort`. A `21` spelled here would be a
            // second copy of both, and wrong for implicit FTPS.
            //
            // (Withdrawn wording, verbatim: "Refused rather than written:
            // the flags and the required-field set for FTP are FTP plan
            // Task 10's, and a `newSession` that writes a half-specified
            // record is worse than one that refuses." Task 10 named them,
            // and this arm writes the record.)
            let mode = security ?? FTPFieldSchema.security(FTPFieldSchema.defaults)
            let path = initialPath?.trimmingCharacters(in: .whitespacesAndNewlines)
            session.ftp = StoredFTPConfig(
                host: try required(host, "--host", for: kind),
                port: port ?? mode.defaultPort,
                // Blank is anonymous FTP, not a missing field, so this one
                // does not go through `required(_:_:for:)`.
                username: user ?? "",
                security: mode,
                initialPath: (path?.isEmpty ?? true) ? nil : path)
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
    /// That contract has one edge worth stating for FTP: `--security` does
    /// NOT move `--port` with it. `newSession` applies the new mode's
    /// default port because nothing was there to keep; an edit has a stored
    /// port, and silently replacing one the person typed is the
    /// silent-wrong-port bug `FTPFieldSchema.port(_:for:)` documents. So
    /// changing to implicit FTPS on a session saved at 21 is two flags, and
    /// the one-flag form leaves a session that will not connect — visibly,
    /// at the next dial, rather than invisibly in the store.
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
        if var ftp = session.ftp {
            if let host { ftp.host = host }
            if let port { ftp.port = port }
            if let user { ftp.username = user }
            if let security { ftp.security = security }
            if let initialPath {
                // Blank CLEARS it (`validateGivenValues`' note above):
                // `nil` is "whatever folder the server starts in", which is
                // a state a person has to be able to get back to.
                let trimmed = initialPath.trimmingCharacters(in: .whitespacesAndNewlines)
                ftp.initialPath = trimmed.isEmpty ? nil : trimmed
            }
            session.ftp = ftp
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
