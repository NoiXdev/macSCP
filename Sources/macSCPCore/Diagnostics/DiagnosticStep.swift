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
/// contribution brings its own id; these three are the ones the runner
/// writes, and they are constants so a renderer or a test can name a row
/// without spelling it a second time.
public enum DiagnosticStepID {
    public static let resolve = "resolve"
    public static let tcp = "tcp"
    public static let dial = "dial"

    /// The catalogue key a step id renders under, DERIVED rather than spelled
    /// beside each id: a renamed id takes its key with it, instead of leaving
    /// a key that resolves to nothing while the row keeps drawing.
    public static func titleKey(for id: String) -> String { "diagnostics.step.\(id)" }
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

    public init(
        id: String, titleKey: String, started: Date, duration: Duration,
        outcome: DiagnosticOutcome, detail: String
    ) {
        self.id = id
        self.titleKey = titleKey
        self.started = started
        self.duration = duration
        self.outcome = outcome
        self.detail = detail
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

    public func finish(_ outcome: DiagnosticOutcome, _ detail: String) -> DiagnosticStep {
        DiagnosticStep(
            id: id, titleKey: titleKey, started: started,
            duration: mark.duration(to: ContinuousClock().now),
            outcome: outcome, detail: detail)
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
