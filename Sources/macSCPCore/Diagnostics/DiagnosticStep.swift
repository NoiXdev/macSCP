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

    /// The catalogue key a step id renders under, DERIVED rather than spelled
    /// beside each id: a renamed id takes its key with it, instead of leaving
    /// a key that resolves to nothing while the row keeps drawing.
    public static func titleKey(for id: String) -> String { "diagnostics.step.\(id)" }
}

/// How a URL is allowed to appear in a diagnosis.
///
/// A URL typed into a form can carry userinfo — `https://KEY:SECRET@host` is
/// ordinary input that no schema here strips, and this project has already
/// had one such credential reach a user-facing message
/// (`ConnectFailureSecrecyTests`). A report is written to be pasted into a
/// public issue, so a URL reaches one of its rows only through this type.
enum URLText {
    /// Host, port and path — never the scheme's userinfo, and never a query
    /// or fragment, both of which are also places a credential travels.
    static func hostPortPath(of url: URL) -> String {
        guard let endpoint = Endpoint(url: url) else { return "the configured URL" }
        let path = url.path()
        return path.isEmpty || path == "/" ? endpoint.text : endpoint.text + path
    }

    /// Strips `userinfo@` out of every `scheme://…` in a free-text string.
    ///
    /// The backstop for text this module did not compose — an `NSError`
    /// sentence, a server's own message — where a URL may be embedded
    /// anywhere. Scans authorities rather than replacing a pattern, because
    /// what has to go is "everything between `://` and the last `@` before
    /// the authority ends", which is not a literal.
    ///
    /// **What still defeats it, stated rather than implied.** A credential
    /// containing whitespace or a `/` still ends the authority scan before
    /// the `@` — and those two cannot be dropped from `endsAuthority` below,
    /// because they are also what ends a URL inside a sentence. In free text
    /// the two are indistinguishable. This is why the helper is a backstop
    /// and not the defence: no dial prints a URL it did not build itself
    /// (`hostPortPath(of:)`), and a contribution that interpolates a raw
    /// endpoint string into a message is the shape to refuse in review.
    static func withoutUserinfo(_ text: String) -> String {
        var output = ""
        var remainder = Substring(text)
        while let marker = remainder.range(of: "://") {
            output.append(contentsOf: remainder[..<marker.upperBound])
            let rest = remainder[marker.upperBound...]
            let end = rest.firstIndex(where: endsAuthority) ?? rest.endIndex
            let authority = rest[..<end]
            if let at = authority.lastIndex(of: "@") {
                output.append(contentsOf: authority[authority.index(after: at)...])
            } else {
                output.append(contentsOf: authority)
            }
            remainder = rest[end...]
        }
        output.append(contentsOf: remainder)
        return output
    }

    /// What ends an authority: the path, query and fragment delimiters, and
    /// whitespace.
    ///
    /// Deliberately NOT the sub-delimiters. `,` `)` `(` `'` `;` `"` `]` and
    /// their kin are permitted UNENCODED inside userinfo by RFC 3986, and
    /// while they were in this set a password containing one ended the
    /// authority before the `@` — leaving a span with no separator to cut at,
    /// which was then copied out whole. Under-stripping costs the whole
    /// credential; over-stripping costs at most some prose after a later `@`,
    /// so the set is chosen to fail in that direction. Removing `]` also
    /// FIXED the IPv6 case rather than breaking it: `u:p@[::1]:9000` now ends
    /// at the `/`, and its last `@` is the real separator.
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
/// The trace is the one step that measures a list of things — its hops — and
/// joining them into a detail line made the row people came to the panel for
/// the one row they could not read. A renderer cannot split
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
            columns: columns.map(URLText.withoutUserinfo),
            rows: rows.map { $0.map(URLText.withoutUserinfo) })
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
    /// than one — `nil` for every step but the trace.
    ///
    /// Beside `detail` rather than instead of it: the trace's detail keeps
    /// the markers that say the walk STOPPED LOOKING, which are statements
    /// about the walk and not rows of it.
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

    /// Seconds as a `Double`, for `DispatchQueue.asyncAfter` and
    /// `URLRequest.timeoutInterval`.
    var seconds: Double {
        let components = self.components
        return Double(components.seconds)
            + Double(components.attoseconds) / 1_000_000_000_000_000_000
    }
}
