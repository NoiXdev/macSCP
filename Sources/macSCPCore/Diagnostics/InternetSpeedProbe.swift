import Foundation

// MARK: - Which service measures the line

/// The third-party service the internet speed test measures against — a
/// CLOSED set, and never a URL.
///
/// The maintainer's answer of 2026-09-19 is that the service is a setting,
/// default Cloudflare. A setting that held a URL would be a setting an
/// imported session, a pasted link or a page could fill in, and the step
/// would then send a request wherever that text pointed. So the setting
/// holds one of these names, the names map to URLs written down HERE, and
/// nothing outside this file decides where a request goes —
/// `InternetSpeedEndpoints` is the only place a host is spelled.
///
/// `rawValue` is the stable spelling three things build on: the settings
/// file (`SettingsStore.internetSpeedService`), `macscp-cli diagnose
/// --speed-service`, and the App's catalogue keys
/// (`settings.internetSpeed.service.<rawValue>`).
public enum InternetSpeedService: String, CaseIterable, Sendable {
    /// `speed.cloudflare.com`, the default. Measured 2026-09-20 with `curl`
    /// from this checkout: `GET /__down?bytes=100000` answered `200` with
    /// `Content-Type: application/octet-stream` and exactly 100000 bytes,
    /// and `POST /__up` with 100000 bytes of body answered `200`.
    case cloudflare
    /// `mensura.cdn-apple.com`, the endpoint macOS's own `networkQuality`
    /// measures against. Measured 2026-09-20 the same way: `GET
    /// /api/v1/gm/large` with `Range: bytes=0-999` answered `206` with
    /// `Content-Range: bytes 0-999/4294967296`, so the size is asked for
    /// with a range over a fixed 4 GiB body rather than in the query; `POST
    /// /api/v1/gm/slurp` with 100000 bytes of body answered `200`.
    ///
    /// Apple publishes those two URLs through a config document at
    /// `/api/v1/gm/config`, which this step deliberately does NOT fetch: a
    /// document that hands back URLs is a page choosing where the next
    /// request goes, which is the one thing the closed set above exists to
    /// prevent. The two URLs are written down from that document as it read
    /// on 2026-09-20, and a service that moves them reports `unavailable`
    /// with the status it answered — a visible failure, not a request
    /// somewhere else.
    case apple
    /// No internet speed test. The scope still exists and still runs; its
    /// row says the test is switched off and NOTHING is sent
    /// (`InternetSpeedProbe.measure`'s first guard, before any request is
    /// built).
    case off

    /// Where this service's two requests go, or `nil` for `off`.
    var endpoints: InternetSpeedEndpoints? {
        switch self {
        case .cloudflare:
            return InternetSpeedEndpoints(
                host: "speed.cloudflare.com",
                downloadURL: URL(string: "https://speed.cloudflare.com/__down")!,
                uploadURL: URL(string: "https://speed.cloudflare.com/__up")!,
                sizing: .query(name: "bytes"))
        case .apple:
            return InternetSpeedEndpoints(
                host: "mensura.cdn-apple.com",
                downloadURL: URL(string: "https://mensura.cdn-apple.com/api/v1/gm/large")!,
                uploadURL: URL(string: "https://mensura.cdn-apple.com/api/v1/gm/slurp")!,
                sizing: .range)
        case .off:
            return nil
        }
    }
}

/// How a service is asked for a download of a given size.
///
/// Two shapes because the two services differ, and the difference is
/// measured rather than assumed (`InternetSpeedService`'s cases carry the
/// measurement).
enum InternetSpeedSizing: Sendable, Equatable {
    /// `?<name>=<bytes>` appended to the download URL.
    case query(name: String)
    /// `Range: bytes=0-<bytes - 1>` over a fixed, much larger body.
    case range
}

/// The two URLs one service's step talks to, and nothing else.
///
/// `host` is stated rather than read back off `downloadURL`: it is what the
/// row prints and what a test pins both URLs against, so a URL edited to
/// point somewhere else is red rather than silently renaming the row.
struct InternetSpeedEndpoints: Sendable, Equatable {
    let host: String
    let downloadURL: URL
    let uploadURL: URL
    let sizing: InternetSpeedSizing
}

// MARK: - What the step measures, and under what bound

/// What the internet speed test moves and which service it moves it
/// against — the value the caller hands the runner, the way
/// `DiagnosticThroughputSettings` is.
///
/// Core reads no settings file. The app passes the service from Settings,
/// `macscp-cli diagnose` its `--speed-service`.
public struct DiagnosticInternetSpeedSettings: Sendable {
    /// Cloudflare, the maintainer's answer of 2026-09-19.
    public static let defaultService = InternetSpeedService.cloudflare

    /// **A FIXED PAIR, not a setting.** 10 MiB down and 1 MiB up: large
    /// enough that the transfer and not the round trips around it is what
    /// the rate measures, small enough to be a polite visit to somebody
    /// else's free service — which is the difference from the throughput
    /// test's payload, where the server is the user's own and the size is
    /// theirs to choose. Asymmetric because domestic lines are: an upload
    /// leg the size of the download leg would spend most of the step on the
    /// slower half.
    ///
    /// **The upload figure is measured, not guessed.** 2 MiB was the first
    /// choice and it was wrong: on the maintainer's line on 2026-09-20,
    /// Cloudflare's `__up` took 35.5 s for 2 MiB (59 kB/s, measured with
    /// `curl`) while the 10 MiB download finished in 1.2 s — so the upload
    /// leg hit the bound and reported nothing on a line that works. 1 MiB
    /// is about 18 s there, inside the bound below with room to spare.
    public static let defaultDownloadBytes = 10 * 1024 * 1024
    public static let defaultUploadBytes = 1024 * 1024

    /// What bounds one leg. A slow line cannot run for ever: each leg is
    /// abandoned at this point and reported as such
    /// (`DiagnosticReason.internetSpeedTooSlow`), and the step stops at the
    /// first leg that does not finish — so the whole step is bounded by two
    /// of these, and by one when the line is down.
    ///
    /// 45 s rather than 30: the measurement above is what decided it. A
    /// line whose uplink is half a megabit is not a broken line, and a
    /// bound that reports one as unmeasurable is a bound that measures the
    /// bound. The worst case is therefore 90 s for a step nobody runs
    /// without choosing it by name, with Cancel beside it.
    public static let defaultLegTimeout = Duration.seconds(45)

    /// Which service, or `off` for none.
    public let service: InternetSpeedService
    /// The download leg's size in bytes.
    var downloadBytes = defaultDownloadBytes
    /// The upload leg's size in bytes.
    var uploadBytes = defaultUploadBytes
    /// One leg's bound. Internal and settable so the suite can reach the
    /// bound without spending the production forty-five seconds on it.
    var legTimeout = defaultLegTimeout

    public init(service: InternetSpeedService = defaultService) {
        self.service = service
    }
}

/// The internet table's four columns — as catalogue keys, which is what a
/// `DiagnosticTable` carries — and the words its cells are written in.
///
/// Keys here rather than in the App for the reason `DiagnosticTraceColumn`
/// gives: the table is Core's, and the App resolves the names.
public enum DiagnosticInternetSpeedColumn {
    public static let direction = "diagnostics.internet.column.direction"
    public static let bytes = "diagnostics.internet.column.bytes"
    public static let duration = "diagnostics.internet.column.duration"
    public static let rate = "diagnostics.internet.column.rate"

    /// Every column key, in the order the cells are written.
    public static let all = [direction, bytes, duration, rate]

    /// The two direction words, taken from the throughput table rather than
    /// spelled a second time: the panel maps ONE pair of words
    /// (`diagnostics.throughput.direction.*`), and a second spelling of
    /// "up" here would be a second copy of a name — the thing this
    /// project's rules about second copies forbid in a comment and forbid
    /// here for the same reason.
    public static let up = DiagnosticThroughputColumn.up
    public static let down = DiagnosticThroughputColumn.down
}

// MARK: - The one seam

/// Performs one speed-test request — the internet step's ONLY way out of
/// this process, and the suite's seam.
///
/// It takes a whole `URLRequest` rather than a URL and a size, so what a
/// test inspects is exactly what is sent: the method, the URL, every header
/// and the body. That is what makes "no credential, no host, no session
/// data reaches the request" a property a test can hold rather than a
/// sentence in a comment.
struct InternetSpeedTransport: Sendable {
    /// Performs `request` and answers how many PAYLOAD bytes crossed the
    /// link: the response body's count for a download, the request body's
    /// for an upload.
    var perform: @Sendable (URLRequest) async throws -> Int

    /// The live one: an EPHEMERAL `URLSession` per request, with a
    /// redirect delegate.
    ///
    /// Ephemeral for what it does not have. It shares no cookie jar, no
    /// credential storage and no cache with anything else in the process,
    /// so nothing this app has ever authenticated to can be attached to a
    /// request by Foundation on its way out, and a response cannot be
    /// served out of a cache and reported as a transfer that never
    /// happened — which Apple's download URL invites, since it answers
    /// `Cache-Control: max-age=86400` (measured 2026-09-20).
    ///
    /// **The delegate is what keeps the closed set closed.** Without one,
    /// Foundation follows redirects — measured for the S3 path on
    /// 2026-08-28 and written down as `S3RedirectDecision`. A 30x from the
    /// service, or from anything that can answer for it, would then send
    /// the next request — and on a 307 or 308 the upload body with it — to
    /// a host that response chose, including an `http://` downgrade or a
    /// private address. The whole argument of `InternetSpeedService` is
    /// that one property decides where a request goes; without this
    /// delegate, the far end decides instead.
    ///
    /// The refusal is read BEFORE the status, because refusing a redirect
    /// is not an error at the `URLSession` level: the 3xx is handed back as
    /// if it were the answer, and would otherwise be reported as a plain
    /// "HTTP 307" with nothing saying a redirect was declined. Same
    /// arrangement, and the same reason, as
    /// `S3RedirectSessionDelegate.lastRefusedRedirect`.
    static let live = InternetSpeedTransport { request in
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        let redirects = InternetSpeedRedirectDelegate()
        if let body = request.httpBody {
            // `upload(for:from:)` wants the body OFF the request, and
            // rejects one that carries both.
            var post = request
            post.httpBody = nil
            let (_, response) = try await session.upload(
                for: post, from: body, delegate: redirects)
            try redirects.throwIfRefused()
            try check(response)
            return body.count
        }
        let (data, response) = try await session.data(for: request, delegate: redirects)
        try redirects.throwIfRefused()
        try check(response)
        return data.count
    }

    /// A status outside 200–299 is the service refusing, and it is reported
    /// as the service's — never as the session's.
    private static func check(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200...299).contains(http.statusCode) else {
            throw InternetSpeedRefusal.status(http.statusCode)
        }
    }
}

/// What the live transport throws when the service answered, and said no.
///
/// A named error rather than an `NSError`, so the row's sentence is this
/// project's own and carries the status the service sent.
enum InternetSpeedRefusal: Error, Equatable, LocalizedError {
    case status(Int)
    /// The service answered a redirect pointing away from its own origin,
    /// and nothing was sent there. Both origins travel with the case, as
    /// text, for `S3RedirectDecision.refuse`'s reason: a reader told only
    /// "it did not work" cannot tell that the service tried to send their
    /// upload somewhere else, and that is the fact worth having.
    case redirect(from: String, to: String)

    var errorDescription: String? {
        switch self {
        case .status(let code): return "the service answered HTTP \(code)"
        case .redirect(let from, let to): return "a redirect from \(from) to \(to) was refused"
        }
    }
}

/// The internet speed test's answer to "the service wants to send this
/// request somewhere else": it asks `S3RedirectDecision` and carries out
/// the answer.
///
/// **The rule is reused, not rewritten.** `S3RedirectDecision.decide` is
/// the measurement this repository already made (2026-08-28) and the only
/// place origin comparison is spelled: same scheme, host and port by
/// RFC 6454, with `https` → `http` counting as foreign, and a failure to
/// read either side counting as foreign too. A second copy of that rule
/// here would be a second thing to keep in step, and this project's rule
/// about second copies applies to policies as much as to comments. What is
/// NOT reused is the carrying-out: S3 re-signs a same-origin hop because
/// Foundation strips its `Authorization`; this step signs nothing and
/// carries nothing, so Foundation's own proposed request is followed as it
/// stands.
///
/// `@unchecked Sendable` for `S3RedirectSessionDelegate`'s reason: the one
/// piece of mutable state is a recorded refusal behind an `NSLock`.
final class InternetSpeedRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var refusal: InternetSpeedRefusal?

    /// Throws the first refused redirect, if there was one. Sticky and
    /// first-wins: the first refusal is what explains any that follow.
    func throwIfRefused() throws {
        let refusal = lock.withLock { self.refusal }
        if let refusal { throw refusal }
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        // The origin being LEFT is the one that answered, not the one first
        // asked, so a chain of same-origin hops is judged hop by hop —
        // `S3RedirectSessionDelegate` reads it the same way.
        let current = response.url ?? task.currentRequest?.url ?? task.originalRequest?.url
        guard let current, let target = request.url else {
            record(.redirect(from: "an unreadable origin", to: "an unreadable target"))
            completionHandler(nil)
            return
        }
        guard case .refuse(let from, let to) = S3RedirectDecision.decide(from: current, to: target)
        else {
            completionHandler(request)
            return
        }
        record(.redirect(from: from, to: to))
        completionHandler(nil)
    }

    private func record(_ refusal: InternetSpeedRefusal) {
        lock.withLock { if self.refusal == nil { self.refusal = refusal } }
    }
}

// MARK: - The measurement

/// The internet speed test: a generated payload downloaded from and
/// uploaded to a service named in Settings, timed, and reported as a rate.
///
/// **What it is not.** It measures nothing about the session — not its
/// host, not its login, not its server. That is the throughput step's job
/// (`ThroughputProbe`), and the two are separate scopes for exactly that
/// reason. Nothing here reads a credential, and there is no code path from
/// a session's field values into a request.
///
/// **What a request carries**, stated here and printed in every row
/// (`carriesNothing`). What THIS code sets: a method, one of the two URLs
/// `InternetSpeedEndpoints` spells, `Accept-Encoding: identity` so the
/// bytes counted are the bytes that crossed, and — for the upload — a
/// `Content-Type` and a body of pseudorandom bytes from
/// `ThroughputPattern`. No cookie, no `Authorization`, no referrer, no host
/// name of the user's, no session id, no path.
/// `InternetSpeedProbeTests.theRequestsCarryNothingOfTheSession` holds the
/// `URLRequest`'s whole header dictionary to that, by equality.
///
/// **`URLSession` adds its own on the way out**, which that case cannot
/// see. Measured on the wire 2026-09-20 (macOS 25.6.0, CFNetwork
/// 3860.700.1): `Host`, `Cache-Control: no-cache` from this step's cache
/// policy, `Accept: */*`, a `User-Agent` of the process name plus the
/// CFNetwork and Darwin versions, `Accept-Language` carrying the viewer's
/// preferred languages, and `Connection: keep-alive`. None of it is session
/// data; `Accept-Language` is the one item that is about the PERSON rather
/// than the request, and it is the same header every web page they open
/// receives. `InternetSpeedLiveTransportTests
/// .theHeadOnTheWireCarriesOursAndNoCredential` is the case one layer down.
///
/// **Reported, never judged**, like the throughput step: a rate is a number
/// in a row. Nothing here decides that a line is fast enough.
///
/// **A service that refuses or stalls is `unavailable`, never `failed`.**
/// `failed` in this report means a finding about the user's server, and a
/// free service that rate-limits a request from this Mac is not that. The
/// CLI's exit code follows: `unavailable` leaves `diagnose` at 0.
enum InternetSpeedProbe {
    /// The sentence every row prints about its own requests. A constant
    /// because the panel and the report both show it and neither may
    /// paraphrase it.
    ///
    /// It says what this app puts in a request, which is what a reader is
    /// asking about; `URLSession`'s own additions are listed in this type's
    /// doc comment and carry nothing of the session either.
    static let carriesNothing =
        "the requests carry no session, host, user name, credential or cookie"

    /// The whole measurement, finished as a row by `timer`.
    ///
    /// `now` is the clock, injected: the rate is bytes over the elapsed
    /// time between two readings of it, and the suite hands a reading
    /// sequence so a rate can be asserted exactly rather than measured off
    /// the machine the tests run on. It is read exactly TWICE per leg —
    /// once before the request and once after — which is the contract a
    /// stub depends on.
    ///
    /// `seed` picks the upload's bytes; a fresh one per run, so no two runs
    /// send the same body, and a fixed one in the suite.
    static func measure(
        settings: DiagnosticInternetSpeedSettings,
        transport: InternetSpeedTransport,
        now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock().now },
        seed: UInt64 = UInt64.random(in: .min ... .max),
        timer: DiagnosticStepTimer
    ) async -> DiagnosticStep {
        // BEFORE any request is built, which is what makes "off" mean
        // nothing was sent rather than nothing was reported.
        guard let endpoints = settings.service.endpoints else {
            return timer.finish(.unavailable(DiagnosticReason.internetSpeedOff), "")
        }

        let download = downloadRequest(
            endpoints, bytes: settings.downloadBytes, timeout: settings.legTimeout)
        let body = ThroughputPattern.bytes(seed: seed, offset: 0, count: settings.uploadBytes)
        let upload = uploadRequest(endpoints, body: body, timeout: settings.legTimeout)

        var parts = [
            "\(settings.service.rawValue); \(endpoints.host); "
                + "\(summary(of: download)); \(summary(of: upload)); \(carriesNothing)"
        ]
        var legs: [Leg] = []
        var refusal: String?
        var notes: [String] = []

        switch await run(
            DiagnosticInternetSpeedColumn.down, download, transport, settings.legTimeout, now)
        {
        case .measured(let leg): legs.append(leg)
        case .refused(let reason, let note):
            refusal = reason
            if let note { notes.append(note) }
        }
        // Stops at the first leg that did not finish. A service that
        // refused the download will refuse the upload, and asking anyway
        // would double the time a broken line costs the reader for a second
        // copy of the same answer.
        if refusal == nil {
            switch await run(
                DiagnosticInternetSpeedColumn.up, upload, transport, settings.legTimeout, now)
            {
            case .measured(let leg): legs.append(leg)
            case .refused(let reason, let note):
                refusal = reason
                if let note { notes.append(note) }
            }
        }
        if let refusal {
            parts.append(refusal)
            parts.append(contentsOf: notes)
        }
        return timer.finish(
            refusal.map(DiagnosticOutcome.unavailable) ?? .ok,
            parts.joined(separator: "; "), table: table(legs))
    }

    // MARK: The legs

    /// One timed direction.
    struct Leg: Equatable, Sendable {
        let direction: String
        let bytes: Int
        let duration: Duration
    }

    /// How one leg ended: measured, or refused with the sentence the row
    /// reports and, where there is more to say than the sentence carries,
    /// a note for the detail line. Not `Result`, because the failure side
    /// is a REASON — a sentence a reader is shown — and `Result`'s failure
    /// side must be an `Error`, which would mean wrapping a sentence in a
    /// type nothing throws and nothing catches.
    enum LegOutcome: Sendable {
        case measured(Leg)
        case refused(String, note: String?)
    }

    /// What one bounded request answered: the byte count, the transport's
    /// sentence, or a redirect this step refused. Carried out of
    /// `DetachedProbe.run`, so `Sendable`.
    ///
    /// The redirect is its own case rather than another sentence: it is the
    /// one transport failure with a FIXED reason (the panel renders it in
    /// the reader's language) and a variable note (the two origins), and
    /// collapsing it into `failed` would make the row say "the download leg
    /// failed: …" about a refusal this app made on purpose.
    private enum Answer: Sendable {
        case bytes(Int)
        case failed(String)
        case redirectRefused(from: String, to: String)
    }

    /// One leg, bounded.
    ///
    /// `DetachedProbe.run` rather than the walk's own task, and the
    /// opposite decision from the throughput step's: what this abandons is
    /// an HTTP request to a third party, which leaves nothing anywhere for
    /// anyone to clean up — where an abandoned throughput test would leave
    /// a file on the user's server.
    private static func run(
        _ direction: String, _ request: URLRequest, _ transport: InternetSpeedTransport,
        _ timeout: Duration, _ now: @escaping @Sendable () -> ContinuousClock.Instant
    ) async -> LegOutcome {
        let started = now()
        let answer = await DetachedProbe.run(timeout: timeout) { () -> Answer in
            do {
                return .bytes(try await transport.perform(request))
            } catch InternetSpeedRefusal.redirect(let from, let to) {
                return .redirectRefused(from: from, to: to)
            } catch {
                return .failed(DialSupport.reason(for: error))
            }
        }
        let elapsed = started.duration(to: now())
        switch answer {
        case nil:
            // The deadline, or the user's Cancel. The walk drops the row on
            // a cancel (`ConnectionDiagnostics`), so what this sentence
            // reaches a reader as is the deadline.
            return .refused(DiagnosticReason.internetSpeedTooSlow, note: nil)
        case .redirectRefused(let from, let to)?:
            return .refused(
                DiagnosticReason.internetSpeedRedirectRefused,
                note: "the \(direction) leg was redirected: \(from) → \(to)")
        case .failed(let reason)?:
            return .refused(
                DiagnosticReason.internetSpeedLegFailed(direction, reason), note: nil)
        case .bytes(let bytes)?:
            guard bytes > 0 else {
                return .refused(DiagnosticReason.internetSpeedNoBytes, note: nil)
            }
            return .measured(Leg(direction: direction, bytes: bytes, duration: elapsed))
        }
    }

    // MARK: The requests

    /// The shape BOTH requests share, and the whole of what either carries
    /// beyond its own method and body.
    ///
    /// `Accept-Encoding: identity` so a compressing proxy cannot make the
    /// count of bytes received differ from the count that crossed the link.
    /// `httpShouldHandleCookies = false` is the per-request half of the
    /// ephemeral session's own refusal — belt and braces, because the
    /// suite's transport is not a `URLSession` and this is the object the
    /// suite inspects.
    private static func baseRequest(_ url: URL, timeout: Duration) -> URLRequest {
        var request = URLRequest(
            url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
            timeoutInterval: timeout.seconds)
        request.httpShouldHandleCookies = false
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        return request
    }

    /// The download request for `bytes`, asked for the way this service
    /// takes it (`InternetSpeedSizing`).
    static func downloadRequest(
        _ endpoints: InternetSpeedEndpoints, bytes: Int,
        timeout: Duration = DiagnosticInternetSpeedSettings.defaultLegTimeout
    ) -> URLRequest {
        switch endpoints.sizing {
        case .query(let name):
            var components = URLComponents(url: endpoints.downloadURL, resolvingAgainstBaseURL: false)
            components?.queryItems = [URLQueryItem(name: name, value: "\(bytes)")]
            var request = baseRequest(components?.url ?? endpoints.downloadURL, timeout: timeout)
            request.httpMethod = "GET"
            return request
        case .range:
            var request = baseRequest(endpoints.downloadURL, timeout: timeout)
            request.httpMethod = "GET"
            request.setValue("bytes=0-\(bytes - 1)", forHTTPHeaderField: "Range")
            return request
        }
    }

    /// The upload request carrying `body`.
    static func uploadRequest(
        _ endpoints: InternetSpeedEndpoints, body: Data,
        timeout: Duration = DiagnosticInternetSpeedSettings.defaultLegTimeout
    ) -> URLRequest {
        var request = baseRequest(endpoints.uploadURL, timeout: timeout)
        request.httpMethod = "POST"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        return request
    }

    /// What a request is, in the row: its method, its path and query, its
    /// range if it has one, and its body size if it has one.
    ///
    /// Read OFF the request rather than composed beside it, so the sentence
    /// the reader is shown cannot describe a request other than the one
    /// that was sent — the failure mode CLAUDE.md's "A report says what the
    /// diff shows" names, one layer down.
    static func summary(of request: URLRequest) -> String {
        var text = request.httpMethod ?? "GET"
        if let url = request.url {
            text += " " + url.path()
            if let query = url.query() { text += "?" + query }
        }
        if let range = request.value(forHTTPHeaderField: "Range") { text += " Range: \(range)" }
        if let body = request.httpBody { text += " with \(body.count) generated bytes" }
        return text
    }

    // MARK: The row

    /// The legs that finished, one row each — or `nil` when none did,
    /// because a header over no rows claims a measurement nobody made
    /// (`ConnectionDiagnostics.traceTable(_:)` states the rule).
    static func table(_ legs: [Leg]) -> DiagnosticTable? {
        guard !legs.isEmpty else { return nil }
        let posix = Locale(identifier: "en_US_POSIX")
        return DiagnosticTable(
            columns: DiagnosticInternetSpeedColumn.all,
            rows: legs.map { leg in
                let seconds = leg.duration.seconds
                let rate =
                    seconds > 0
                    ? TransferRateFormatting.rateString(
                        bytesPerSecond: Double(leg.bytes) / seconds, locale: posix)
                    : nil
                return [
                    leg.direction, "\(leg.bytes)", DurationText.milliseconds(leg.duration),
                    rate ?? DiagnosticThroughputColumn.none,
                ]
            })
    }
}
