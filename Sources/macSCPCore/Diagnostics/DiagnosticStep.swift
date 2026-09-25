import Foundation

/// Where a diagnosis is pointed: the host and port this session would dial.
///
/// Read off a backend's own field values through `BackendDescriptor.endpoint`
/// — the seam that keeps the universal half of the diagnosis from ever asking
/// which protocol it is looking at.
public struct Endpoint: Sendable, Equatable {
    public let host: String
    public let port: Int

    public init(host: String, port: Int) {
        self.host = host
        self.port = port
    }

    /// `host:port`, the one spelling the report and every detail line use.
    /// An IPv6 literal is bracketed, so `::1` reads as `[::1]:22` rather than
    /// as a host of `` with a port of `:1`.
    public var text: String {
        host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)"
    }

    /// The origin a URL names — its host, and its port or its scheme's
    /// default. Shared by the two URL-shaped backends (S3's endpoint, WebDAV's
    /// base URL) rather than written out twice.
    ///
    /// Anything that is not `http` defaults to 443. That covers `https` and
    /// is the safe direction for a scheme this reader does not know: a wrong
    /// 443 fails a probe visibly, while a wrong 80 would dial a port that is
    /// often open for something else entirely.
    public init?(url: URL) {
        guard let host = url.host(), !host.isEmpty else { return nil }
        self.init(host: host, port: url.port ?? (url.scheme?.lowercased() == "http" ? 80 : 443))
    }
}

/// How one diagnostic step ended.
///
/// `failed` and `ok` are the two answers a probe gives about the SERVER;
/// `timedOut` is the deadline's answer; `unavailable` and `skipped` are about
/// THIS build and this session — a probe this build cannot run, and a probe
/// there was nothing to run. Keeping the last two apart from `failed` is the
/// whole point: a row that says "not available in this build" must never read
/// as "your server is broken".
public enum DiagnosticOutcome: Sendable, Equatable {
    case ok
    case failed(String)
    case timedOut
    case unavailable(String)
    case skipped(String)

    /// The same outcome with any URL userinfo stripped out of its reason.
    /// `failed`, `unavailable` and `skipped` all carry free text that can
    /// name a URL, and every one of them is printed.
    var redacted: DiagnosticOutcome {
        switch self {
        case .ok, .timedOut: return self
        case .failed(let reason): return .failed(URLText.withoutUserinfo(reason))
        case .unavailable(let reason): return .unavailable(URLText.withoutUserinfo(reason))
        case .skipped(let reason): return .skipped(URLText.withoutUserinfo(reason))
        }
    }

    /// The word the report prints. Not localized, and deliberately: the
    /// report is a copy-and-paste artifact for a bug report, the same
    /// audience and the same English the command-line tool writes for
    /// (`BackendDescriptor.fieldLabel(forKey:)` states the precedent). What
    /// IS localized is the panel, which renders `DiagnosticStep.titleKey`
    /// through the App's catalogs.
    public var label: String {
        switch self {
        case .ok: return "ok"
        case .failed(let reason): return "failed (\(reason))"
        case .timedOut: return "timed out"
        case .unavailable(let reason): return "unavailable (\(reason))"
        case .skipped(let reason): return "skipped (\(reason))"
        }
    }
}

/// The stable ids of the steps the universal runner produces itself. A
/// contribution brings its own id; these are the ones the runner writes, and
/// they are constants so a renderer or a test can name a row without spelling
/// it a second time.
public enum DiagnosticStepID {
    public static let resolve = "resolve"
    public static let tcp = "tcp"
    public static let icmp = "icmp"
    public static let dial = "dial"
    public static let trace = "trace"
    /// The throughput test (`DiagnosticScope.throughput`): a payload written
    /// to the server over the session's own protocol and read back.
    public static let throughput = "throughput"
    /// The internet speed test (`DiagnosticScope.internet`): a payload
    /// downloaded from and uploaded to a third-party service named in
    /// Settings. The one step that measures NOTHING of the session — see
    /// `InternetSpeedProbe`.
    public static let internet = "internet"

    /// The steps of a session behind a jump host (`DiagnosticJump`): the jump
    /// itself first, from this Mac, then the target as the jump reaches it.
    ///
    /// Two prefixes, `jump.` and `target.`, so the report, the command line's
    /// rows and its JSON name which half a row belongs to in the one field
    /// every renderer already prints — the id — and none of them grows a
    /// column. A session without a jump never produces one of these; its
    /// walk keeps the ids above. The throughput step keeps its one id in
    /// both walks: it measures the server over the session's own connection,
    /// which behind a jump host is reached through it the way a tab reaches
    /// it.
    public static let jumpResolve = "jump.resolve"
    public static let jumpTCP = "jump.tcp"
    public static let jumpICMP = "jump.icmp"
    public static let jumpDial = "jump.dial"
    public static let jumpTrace = "jump.trace"
    public static let targetTCPViaJump = "target.tcpViaJump"
    /// The three measured ON the jump host, by a command run there over the
    /// jump connection (`JumpProbes.swift`): its name resolution of the
    /// target, its ping and its trace.
    public static let targetResolveOnJump = "target.resolveOnJump"
    public static let targetICMPFromJump = "target.icmpFromJump"
    public static let targetDialViaJump = "target.dialViaJump"
    public static let targetTraceFromJump = "target.traceFromJump"

    /// The catalogue key a step id renders under, DERIVED rather than spelled
    /// beside each id: a renamed id takes its key with it, instead of leaving
    /// a key that resolves to nothing while the row keeps drawing.
    public static func titleKey(for id: String) -> String { "diagnostics.step.\(id)" }
}

/// How a URL is allowed to appear in a diagnosis, a log line, the CLI or any
/// other rendering.
///
/// A URL typed into a form can carry userinfo — `https://KEY:SECRET@host` is
/// ordinary input, and this project has already had one such credential
/// reach a user-facing message (`ConnectFailureSecrecyTests`). The S3 parse
/// drops it (`S3FieldSchema.endpointComponents`); the WebDAV base URL keeps
/// it, because Foundation answers the server's challenge with it (measured
/// 2026-09-19, see `withoutUserinfo(typedURL:atMayFollowHost:)`). A report is written to be
/// pasted into a public issue, so a URL reaches one of its rows only
/// through this type.
enum URLText {
    /// Host, port and path — never the scheme's userinfo, and never a query
    /// or fragment, both of which are also places a credential travels.
    static func hostPortPath(of url: URL) -> String {
        guard let endpoint = Endpoint(url: url) else { return "the configured URL" }
        let path = url.path()
        return path.isEmpty || path == "/" ? endpoint.text : endpoint.text + path
    }

    /// A URL the user TYPED into a form — the S3 endpoint, the WebDAV base
    /// URL — with its userinfo removed. The one door every rendering of the
    /// typed TEXT goes through: the session overview, the CLI's session
    /// list, the connect log line, the import preview and the summaries'
    /// fallback (`TypedEndpointSecrecyTests` scans `Sources/` for a
    /// rendering that bypasses it). Renderings of what the endpoint was
    /// PARSED to — the sidebar summary's host, "Connects to", a diagnosis's
    /// endpoint — read `S3FieldSchema.endpointComponents` or `URL(string:)`
    /// instead, and do not come through here.
    ///
    /// `atMayFollowHost` is the one thing the two fields disagree on. A
    /// WebDAV base URL may carry an `@` in its path (Nextcloud names the
    /// files collection after the account, often an e-mail address), so it
    /// passes `true` and gets `hostStart(in:)`'s tie-break, with its known
    /// limit. An S3 endpoint may not — its path takes no part in any
    /// request, and `hasAtAfterHost(typedURL:)` makes one a validation
    /// error — so it passes `false`, and everything up to the LAST `@` is
    /// the userinfo, with no tie to break.
    ///
    /// `marker`, when not empty, is put where a userinfo was cut, so a
    /// rendering that must show THAT something was there (the import
    /// preview's "X → X") can.
    ///
    /// Unlike the free-text door below, the whole string is one URL, so a
    /// space does not end it, and a schemeless one (`KEY:SECRET@host:9000`,
    /// which S3 reads as `https`) has its userinfo from the first character.
    /// What the userinfo is, `hostStart(in:)` says.
    ///
    /// **The WebDAV base URL's userinfo is USED, which is why only its
    /// renderings go through here.** Measured 2026-09-19 with a local HTTP
    /// server and an ephemeral `URLSession` whose delegate answers every
    /// challenge: a `401` on `http://urluser:urlpass@…` was answered with
    /// `Basic` for `urluser:urlpass` WITHOUT the delegate being asked, so a
    /// base URL typed with a credential logs in with it. S3 signs with the
    /// Keychain's key and never reads the userinfo, so its parse drops it.
    static func withoutUserinfo(
        typedURL text: String, atMayFollowHost: Bool, marker: String = ""
    ) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)[...]
        var prefix: Substring = ""
        var rest = trimmed
        if let marker = trimmed.range(of: "://"), isScheme(trimmed[..<marker.lowerBound]) {
            prefix = trimmed[..<marker.upperBound]
            rest = trimmed[marker.upperBound...]
        }
        let host =
            atMayFollowHost
            ? hostStart(in: rest)
            : (rest.lastIndex(of: "@").map { rest.index(after: $0) } ?? rest.startIndex)
        let authorityEnd = rest[host...].firstIndex(where: endsAuthority) ?? rest.endIndex
        let mark = host == rest.startIndex ? "" : marker
        // A URL nested in the path or query is free text to this one.
        return String(prefix) + mark + String(rest[host..<authorityEnd])
            + withoutUserinfo(String(rest[authorityEnd...]))
    }

    /// Whether a typed URL carries an `@` anywhere after its host — in the
    /// path, the query or the fragment, i.e. after the first `/`, `?` or `#`
    /// that follows the scheme (or the start, when there is none).
    ///
    /// For an S3 endpoint that is never meaningful (the path is overwritten
    /// by every request) and always ambiguous: it is either a path nobody
    /// uses or a secret with a `/`, `?` or `#` in it, which no rule can tell
    /// apart (`hostStart(in:)`'s known limit). So S3 refuses it, in the
    /// editor (`FieldFormat.urlWithoutAtAfterHost`) and at the one parse
    /// (`S3FieldSchema.endpointComponents`), which closes both residues
    /// for S3.
    static func hasAtAfterHost(typedURL text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)[...]
        var rest = trimmed
        if let marker = trimmed.range(of: "://"), isScheme(trimmed[..<marker.lowerBound]) {
            rest = trimmed[marker.upperBound...]
        }
        guard let delimiter = rest.firstIndex(where: { "/?#".contains($0) }) else { return false }
        return rest[delimiter...].contains("@")
    }

    /// Strips `userinfo@` out of every `scheme://…` in a free-text string.
    ///
    /// The backstop for text this module did not compose — an `NSError`
    /// sentence, a server's own message — where a URL may be embedded
    /// anywhere. Each URL runs from its `://` to the next whitespace, and
    /// its userinfo is found by the same rule as a typed URL's
    /// (`hostStart(in:)`), so a `/` in the secret no longer ends the scan
    /// before the `@`.
    ///
    /// **What still defeats it, stated rather than implied.** A credential
    /// containing whitespace still ends the URL before the `@`, because in
    /// a sentence whitespace is also what ends a URL, and the two are
    /// indistinguishable. `hostStart(in:)` states the rule's own residue.
    /// This is why the helper is a backstop and not the defence: no dial
    /// prints a URL it did not build itself (`hostPortPath(of:)`), a typed
    /// URL is rendered through `withoutUserinfo(typedURL:atMayFollowHost:)`, and a
    /// contribution that interpolates a raw endpoint string into a message
    /// is the shape to refuse in review.
    static func withoutUserinfo(_ text: String) -> String {
        var output = ""
        var remainder = Substring(text)
        while let marker = remainder.range(of: "://") {
            output.append(contentsOf: remainder[..<marker.upperBound])
            let rest = remainder[marker.upperBound...]
            let url = rest[..<(rest.firstIndex(where: \.isWhitespace) ?? rest.endIndex)]
            let host = hostStart(in: url)
            let authorityEnd = url[host...].firstIndex(where: endsAuthority) ?? url.endIndex
            output.append(contentsOf: url[host..<authorityEnd])
            remainder = rest[authorityEnd...]
        }
        output.append(contentsOf: remainder)
        return output
    }

    /// Where the host begins in `rest` — a URL's text after its `://`, or a
    /// schemeless one from its first character: just past the userinfo's
    /// `@`, or `rest.startIndex` when there is no userinfo.
    ///
    /// **The rule.** With no `@`, there is no userinfo. When the last `@`
    /// comes before the first `/`, `?` or `#`, the userinfo is everything up
    /// to that last `@` — RFC 3986's reading, which also covers a secret
    /// holding `@`, `:`, `%` or a space. Otherwise the last `@` sits in what
    /// RFC 3986 would call the path, query or fragment, and that has two
    /// readings: a real `@` there (`/dav/files/alice@example.com/`, which
    /// Nextcloud users type), or a secret that contains a `/`, `?` or `#`
    /// (`KEY:wJal/rXUtn@host`, the shape of a real S3 secret key). The
    /// RFC reading is kept only when the text before the first delimiter —
    /// after its own last `@`, if it has one — is a SERVER ADDRESS
    /// (`isServerAddress`): a dotted name, `localhost`, or an IP literal,
    /// with at most a numeric port. A server always looks like that; the
    /// front of a secret with no `@` in it (`KEY:wJal`) rarely does — but
    /// the tested text starts after the head's own last `@`, so a secret
    /// that carries one decides what is tested (the known limit below).
    /// Anything else is cut at the LAST `@`.
    ///
    /// **Which way it fails, when the tested text is NOT a server address.**
    /// Toward the secret: a credential with a `/` beside an `@` in the path
    /// costs the path (`https://example.com/` instead of
    /// `https://cloud.example.com/files/alice@example.com/`) — a confused
    /// reader, not a published key. A dotless server name
    /// (`http://nas/dav/a@b/`) followed by an `@` in the path is cut the
    /// same way.
    ///
    /// **The known limit, the other way — a CLASS, not one shape** (review
    /// of the endpoint-leak fix, I-1). The rule tests the text between the
    /// last `@` before the first delimiter (or the start, when there is no
    /// such `@`) and that delimiter. Whenever the secret itself makes that
    /// text read as `host[:port]`, the RFC reading is kept, and everything
    /// of the secret after that point is rendered. Two ways a secret does
    /// it: an `@`, then something host-shaped, then a `/`, `?` or `#`
    /// (`user:pa@ss.word/more@dav.example.com/dav` renders as
    /// `https://ss.word/more@dav.example.com/dav`; so do `@localhost/`,
    /// `@1.2/`, `@[::1]/` and `@x.y:80?`); or a user name that looks like
    /// a dotted host followed by a secret whose text before its first `/`
    /// is a number up to 65535 (`first.last:1234/rest@host`). It is the
    /// same structure as the Nextcloud row the rule exists to keep, so no
    /// rule over the text alone can close it. What bounds it: Foundation
    /// reads the host the same way, so such a URL dials the wrong server
    /// and never connects; and S3 does not reach this rule at all
    /// (`atMayFollowHost: false`, and `hasAtAfterHost(typedURL:)` refuses
    /// the shape). A human-chosen WebDAV password is exposed to it.
    /// `TypedEndpointSecrecyTests` holds the rule to its table and pins
    /// today's output for the limit as a known leak.
    private static func hostStart(in rest: Substring) -> Substring.Index {
        guard let lastAt = rest.lastIndex(of: "@") else { return rest.startIndex }
        let headEnd = rest.firstIndex(where: { "/?#".contains($0) }) ?? rest.endIndex
        guard lastAt > headEnd else { return rest.index(after: lastAt) }
        let head = rest[..<headEnd]
        let headHost = head.lastIndex(of: "@").map { head.index(after: $0) } ?? head.startIndex
        return isServerAddress(head[headHost...]) ? headHost : rest.index(after: lastAt)
    }

    /// `host[:port]`, where the host is a bracketed IP literal, `localhost`,
    /// or a name of at least two dot-separated labels (an IPv4 address is
    /// one), and the port is 1 to 65535.
    private static func isServerAddress(_ text: Substring) -> Bool {
        var host = text
        if host.hasPrefix("[") {
            guard let close = host.firstIndex(of: "]") else { return false }
            let literal = host[host.index(after: host.startIndex)..<close]
            let isLiteral = literal.contains(":")
                && literal.allSatisfy { $0.isASCII && ($0.isHexDigit || ":.%".contains($0) || $0.isLetter || $0.isNumber) }
            let after = host[host.index(after: close)...]
            guard isLiteral else { return false }
            return after.isEmpty || (after.first == ":" && isPort(after.dropFirst()))
        }
        if let colon = host.lastIndex(of: ":") {
            guard isPort(host[host.index(after: colon)...]) else { return false }
            host = host[..<colon]
        }
        if host.lowercased() == "localhost" { return true }
        var labels = host.split(separator: ".", omittingEmptySubsequences: false)
        if labels.count > 2, labels.last?.isEmpty == true { labels.removeLast() }
        return labels.count >= 2
            && labels.allSatisfy { label in
                !label.isEmpty
                    && label.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
            }
    }

    private static func isPort(_ text: Substring) -> Bool {
        guard (1...5).contains(text.count), text.allSatisfy({ $0.isASCII && $0.isNumber }),
            let value = Int(text)
        else { return false }
        return (1...65_535).contains(value)
    }

    /// Whether `text` is a URL scheme — RFC 3986's
    /// `ALPHA *( ALPHA / DIGIT / "+" / "-" / "." )`. The same rule
    /// `S3FieldSchema.endpointComponents` decides "schemeless" by, so the
    /// parse and the renderings agree on where the userinfo starts.
    static func isScheme(_ text: Substring) -> Bool {
        guard let first = text.first, first.isLetter, first.isASCII else { return false }
        return text.allSatisfy { character in
            character.isASCII
                && (character.isLetter || character.isNumber || "+-.".contains(character))
        }
    }

    /// What ends an authority once its host has been found: the path, query
    /// and fragment delimiters, and whitespace.
    ///
    /// Deliberately NOT the sub-delimiters. `,` `)` `(` `'` `;` `"` `]` and
    /// their kin are permitted UNENCODED inside userinfo by RFC 3986, and
    /// while they were in this set a password containing one ended the
    /// authority before the `@` — leaving a span with no separator to cut at,
    /// which was then copied out whole. The userinfo is found before this
    /// set is consulted now (`hostStart(in:)`), and `]` still must not be
    /// in it: it closes an IPv6 literal, `[::1]:9000`, which the port
    /// follows.
    private static func endsAuthority(_ character: Character) -> Bool {
        character == "/" || character == "?" || character == "#" || character.isWhitespace
    }
}

/// One number format wherever a duration reaches a reader — the report's rows
/// and the TCP step's per-address detail.
///
/// Fixed to `en_US_POSIX` so a German locale's decimal comma cannot turn a
/// Markdown table cell into two, and so two people pasting the same run
/// produce the same text.
enum DurationText {
    static func milliseconds(_ duration: Duration) -> String {
        String(
            format: "%.1f ms", locale: Locale(identifier: "en_US_POSIX"),
            duration.milliseconds)
    }
}

/// A step's measurement when it is a GRID rather than a sentence.
///
/// The trace was the first step to measure a list of things — its hops — and
/// joining them into a detail line made the row people came to the panel for
/// the one row they could not read. The resolve step is the second, since
/// 2026-09-19: the name each address was given, and whether it leads back
/// (`DiagnosticNameColumn`). A renderer cannot split
/// `1 10.0.0.1 2.0 ms` back into cells without re-parsing text this module
/// composed, so the step carries the cells apart and each renderer joins them
/// its own way: aligned columns in the plain text, a Markdown table in the
/// Markdown, a `Grid` in the panel.
///
/// `columns` are catalogue KEYS, never text. Core does not decide what
/// language a window is in (`DiagnosticStep.titleKey` states the rule), so
/// the panel resolves them and the report — which is English by design —
/// prints each key's last component.
public struct DiagnosticTable: Sendable, Equatable {
    /// One catalogue key per column, in the order the cells are written.
    public let columns: [String]
    /// One entry per row, each with a cell per column.
    public let rows: [[String]]

    public init(columns: [String], rows: [[String]]) {
        self.columns = columns
        self.rows = rows
    }

    /// Every string in the table with any URL userinfo stripped out of it.
    /// Applied by `DiagnosticStep.init`, so a cell cannot become the second
    /// place a credential reaches a pasted report.
    var redacted: DiagnosticTable {
        DiagnosticTable(
            columns: columns.map(URLText.withoutUserinfo(_:)),
            rows: rows.map { $0.map(URLText.withoutUserinfo(_:)) })
    }
}

/// Told about each step the moment it finishes, before the next one starts.
///
/// `async` on purpose: the one real implementation is a `@MainActor` view
/// model appending a row, and awaiting it means the runner cannot outrun the
/// renderer or drop a step into a hop that never lands.
public typealias DiagnosticStepObserver = @Sendable (DiagnosticStep) async -> Void

/// One row of the diagnosis: what was tried, how long it took, how it ended.
public struct DiagnosticStep: Sendable, Equatable, Identifiable {
    /// `resolve`, `tcp`, `dial`, or a contribution's own id.
    public let id: String
    /// The catalogue key the panel renders as this row's title. A key rather
    /// than text: Core has no business deciding what language the window is
    /// in, and the report below prints `id` instead of resolving this.
    public let titleKey: String
    public let started: Date
    public let duration: Duration
    public let outcome: DiagnosticOutcome
    /// One line, technical: addresses, ports, HTTP statuses, error reasons.
    /// NEVER a credential — see `ConnectionDiagnosticsTests
    /// .theSSHDialNeverPutsTheSecretInTheReport`.
    public let detail: String
    /// The rows this step measured, when it measured a list of things rather
    /// than one — `nil` for every step but the three traces (`trace`,
    /// `jump.trace`, `target.traceFromJump`), whose rows are hops, the two
    /// resolves this Mac makes (`resolve`, `jump.resolve`), whose rows are
    /// the names of the addresses found, and the throughput step, whose rows
    /// are its two directions. Counted 2026-09-19 at the four places a step
    /// is finished with a table: `ConnectionDiagnostics`'s `trace` and
    /// `resolve`, `DiagnosticJumpStep.traceFromJump`, and
    /// `ThroughputProbe.row`.
    ///
    /// Beside `detail` rather than instead of it: the trace's detail keeps
    /// the markers that say the walk STOPPED LOOKING, which are statements
    /// about the walk and not rows of it, and the resolve's keeps the address
    /// list it always printed.
    public let table: DiagnosticTable?

    /// Every free-text field is stripped of URL userinfo on the way in.
    ///
    /// HERE, in the one initializer every step in the product passes through,
    /// rather than at each producer: `https://KEY:SECRET@host` is ordinary
    /// input in the S3 endpoint and WebDAV URL fields, a report is pasted
    /// into public issues, and a rule enforced at N call sites is a rule that
    /// the N+1st forgets. The two HTTP dials render their target through
    /// `URLText.hostPortPath(of:)` as well (the SSH dial has no URL to
    /// print), so the redaction below is a
    /// backstop for text this module did not compose — an `NSError` sentence,
    /// a server's own message — and not the first line of defence.
    public init(
        id: String, titleKey: String, started: Date, duration: Duration,
        outcome: DiagnosticOutcome, detail: String, table: DiagnosticTable? = nil
    ) {
        self.id = id
        self.titleKey = titleKey
        self.started = started
        self.duration = duration
        self.outcome = outcome.redacted
        self.detail = URLText.withoutUserinfo(detail)
        self.table = table?.redacted
    }
}

/// Starts a step's two clocks and closes it again.
///
/// A type rather than four arguments at each producer, because `started` and
/// `duration` are the two fields a hand-built step gets wrong in the same way
/// every time: taken at the END, they measure nothing. Reading the wall clock
/// AND a monotonic instant at construction is the only shape that cannot.
/// `Date` is what the report prints; `ContinuousClock` is what it measures
/// with, because the wall clock can step sideways mid-probe.
public struct DiagnosticStepTimer: Sendable {
    public let id: String
    public let titleKey: String
    public let started: Date
    private let mark: ContinuousClock.Instant

    public init(id: String, titleKey: String) {
        self.id = id
        self.titleKey = titleKey
        self.started = Date()
        self.mark = ContinuousClock().now
    }

    public func finish(
        _ outcome: DiagnosticOutcome, _ detail: String, table: DiagnosticTable? = nil
    ) -> DiagnosticStep {
        DiagnosticStep(
            id: id, titleKey: titleKey, started: started,
            duration: mark.duration(to: ContinuousClock().now),
            outcome: outcome, detail: detail, table: table)
    }
}

extension Duration {
    /// Milliseconds as a `Double`, for the report's one number format and for
    /// the socket calls that take a millisecond timeout.
    var milliseconds: Double {
        let components = self.components
        return Double(components.seconds) * 1000
            + Double(components.attoseconds) / 1_000_000_000_000_000
    }

    /// Seconds as a `Double`, for the `DispatchTime` a deadline is computed
    /// from (`DeadlineTimer.schedule(after:_:)`) and for the several
    /// URL-loading timeouts — `URLRequest.timeoutInterval` and
    /// `URLSessionConfiguration.timeoutIntervalForRequest` — that take one.
    /// It named `DispatchQueue.asyncAfter` until 2026-09-25, when the
    /// diagnostics deadline stopped being one.
    var seconds: Double {
        let components = self.components
        return Double(components.seconds)
            + Double(components.attoseconds) / 1_000_000_000_000_000_000
    }
}
