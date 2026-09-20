import Foundation
import Synchronization
import Testing

@testable import macSCPCore

/// The internet speed test (`DiagnosticScope.internet`, `InternetSpeedProbe`)
/// over an injected transport and an injected clock: what a request carries,
/// what the rate is computed from, what a refused or stalled service reads
/// as, and that the scope runs nothing else.
///
/// **Nothing here reaches the network.** Every case hands the probe a
/// transport of its own, and the one walk that goes through
/// `ConnectionDiagnostics` uses the internal initializer, whose
/// `internetSpeed` defaults to `.off` for exactly this reason. Live runs
/// against Cloudflare or Apple are not part of this suite.
///
/// **The rate IS asserted here**, unlike the throughput test's, and that is
/// not a wall-clock ceiling: the clock is a stub (`TickingClock`), so
/// `bytes / elapsed` is arithmetic over two numbers this file chose. Nothing
/// below measures how long the machine took.
@Suite("The internet speed test", .timeLimit(.minutes(2)))
struct InternetSpeedProbeTests {
    static func timer() -> DiagnosticStepTimer {
        DiagnosticStepTimer(
            id: DiagnosticStepID.internet,
            titleKey: DiagnosticStepID.titleKey(for: DiagnosticStepID.internet))
    }

    /// Settings with small payloads, so a case that generates an upload body
    /// generates kilobytes and not mebibytes.
    static func settings(
        _ service: InternetSpeedService = .cloudflare,
        download: Int = 4 * 1024 * 1024, upload: Int = 1024 * 1024,
        legTimeout: Duration = .seconds(30)
    ) -> DiagnosticInternetSpeedSettings {
        var settings = DiagnosticInternetSpeedSettings(service: service)
        settings.downloadBytes = download
        settings.uploadBytes = upload
        settings.legTimeout = legTimeout
        return settings
    }

    // MARK: - The rate, from bytes and an injected clock

    /// 4 MiB in 2 s and 1 MiB in 4 s. Both rates are arithmetic: 4 MiB / 2 s
    /// is 2 MiB/s, 1 MiB / 4 s is 256 KiB/s — written out as the numbers
    /// they are, not read back through the formatter this file is checking.
    @Test func theRateIsTheBytesOverTheElapsedTimeOfTheInjectedClock() async throws {
        let transport = RecordingTransport()
        let clock = TickingClock(offsets: [.zero, .seconds(2), .seconds(2), .seconds(6)])

        let step = await InternetSpeedProbe.measure(
            settings: Self.settings(), transport: transport.transport, now: clock.now,
            seed: 7, timer: Self.timer())

        #expect(step.outcome == .ok, "\(step.outcome.label)")
        let table = try #require(step.table)
        #expect(table.columns == DiagnosticInternetSpeedColumn.all)
        #expect(table.rows.count == 2, "\(table.rows)")
        #expect(
            table.rows[0] == [
                DiagnosticInternetSpeedColumn.down, "\(4 * 1024 * 1024)", "2000.0 ms", "2 MB/s",
            ], "\(table.rows[0])")
        #expect(
            table.rows[1] == [
                DiagnosticInternetSpeedColumn.up, "\(1024 * 1024)", "4000.0 ms", "256 KB/s",
            ], "\(table.rows[1])")
    }

    /// The clock is read exactly twice per leg — the contract the stub
    /// above depends on, and the thing that would silently change a rate if
    /// a third reading were added between them.
    @Test func theClockIsReadTwicePerLeg() async throws {
        let clock = TickingClock(offsets: [.zero, .seconds(1), .seconds(1), .seconds(2)])

        _ = await InternetSpeedProbe.measure(
            settings: Self.settings(), transport: RecordingTransport().transport, now: clock.now,
            seed: 7, timer: Self.timer())

        #expect(clock.readings == 4)
    }

    // MARK: - What a request carries

    /// Both `URLRequest`s, field by field: the method, the URL, every
    /// header THIS code sets, and where the body came from.
    ///
    /// One layer, named: `URLSession` adds `Host`, `Accept`, `User-Agent`,
    /// `Accept-Language`, `Cache-Control` and `Connection` of its own on
    /// the way out, which a case holding the `URLRequest` cannot see.
    /// `InternetSpeedLiveTransportTests.theHeadOnTheWireCarriesOursAndNoCredential`
    /// is the case that reads the head a server really receives.
    ///
    /// The negative half — no credential, no host of the user's, no session —
    /// is asserted as an EQUALITY over the header dictionary rather than as a
    /// list of `!contains`, because a negative check that names a header is a
    /// check that goes quiet when a different one is added
    /// (CLAUDE.md, "Guards that name what they watch"). Equality cannot: a
    /// header this file does not list turns it red.
    @Test func theRequestsCarryNothingOfTheSession() async throws {
        let transport = RecordingTransport()

        _ = await InternetSpeedProbe.measure(
            settings: Self.settings(download: 1000, upload: 500),
            transport: transport.transport, seed: 7, timer: Self.timer())

        let sent = transport.sent
        #expect(sent.count == 2, "\(sent.map(\.url))")
        let download = try #require(sent.first)
        #expect(download.method == "GET")
        #expect(download.url == "https://speed.cloudflare.com/__down?bytes=1000")
        #expect(
            download.headers == ["Accept-Encoding": "identity", "Accept-Language": "*"],
            "\(download.headers)")
        #expect(download.body == nil)

        let upload = try #require(sent.last)
        #expect(upload.method == "POST")
        #expect(upload.url == "https://speed.cloudflare.com/__up")
        #expect(
            upload.headers == [
                "Accept-Encoding": "identity", "Accept-Language": "*",
                "Content-Type": "application/octet-stream",
            ], "\(upload.headers)")
        // Generated from the seed and nothing else — the same pattern the
        // throughput test writes to the user's own server, which is derived
        // from a number and carries no text at all.
        #expect(upload.body == ThroughputPattern.bytes(seed: 7, offset: 0, count: 500))
    }

    /// The leg's bound reaches the request layer. `URLRequest`'s own
    /// timeout is not what bounds a leg — `DetachedProbe` is, and it bounds
    /// a slow drip that Foundation's idle timeout would not — but a
    /// settable field that silently does not reach the request is a field
    /// whose value is a lie, and a request left running past the bound that
    /// abandoned it is a request still holding a socket.
    @Test func eachRequestCarriesTheLegsOwnBound() async throws {
        let transport = RecordingTransport()

        _ = await InternetSpeedProbe.measure(
            settings: Self.settings(download: 1000, upload: 500, legTimeout: .seconds(7)),
            transport: transport.transport, seed: 7, timer: Self.timer())

        #expect(transport.sent.map(\.timeoutSeconds) == [7, 7], """
            \(transport.sent.map(\.timeoutSeconds))
            """)
    }

    /// Apple asks for its size with a range over a fixed body, not in the
    /// query — measured 2026-09-20, and recorded in
    /// `InternetSpeedService.apple`.
    @Test func theAlternativeServiceAsksForItsSizeWithARange() async throws {
        let transport = RecordingTransport()

        _ = await InternetSpeedProbe.measure(
            settings: Self.settings(.apple, download: 1000, upload: 500),
            transport: transport.transport, seed: 7, timer: Self.timer())

        let download = try #require(transport.sent.first)
        #expect(download.url == "https://mensura.cdn-apple.com/api/v1/gm/large")
        #expect(
            download.headers == [
                "Accept-Encoding": "identity", "Accept-Language": "*", "Range": "bytes=0-999",
            ], "\(download.headers)")
        #expect(try #require(transport.sent.last).url == "https://mensura.cdn-apple.com/api/v1/gm/slurp")
    }

    /// Every service in the set points at its own host and nowhere else —
    /// the positive check beside the equality above, so a URL edited to
    /// point somewhere new is red rather than quietly becoming what the row
    /// says was measured. `off` is the one case with nothing to point at.
    @Test(arguments: InternetSpeedService.allCases)
    func everyServiceReachesItsOwnHostAndNothingElse(service: InternetSpeedService) throws {
        guard service != .off else {
            #expect(service.endpoints == nil)
            return
        }
        let endpoints = try #require(service.endpoints)
        #expect(endpoints.downloadURL.host() == endpoints.host, "\(endpoints.downloadURL)")
        #expect(endpoints.uploadURL.host() == endpoints.host, "\(endpoints.uploadURL)")
        #expect(endpoints.downloadURL.scheme == "https")
        #expect(endpoints.uploadURL.scheme == "https")
    }

    /// The detail line says which service, which host, what each request is
    /// and that it carries nothing of the session — the sentence the brief
    /// asks the report to state.
    @Test func theDetailSaysWhichServiceAndWhatTheRequestsCarry() async throws {
        let step = await InternetSpeedProbe.measure(
            settings: Self.settings(download: 1000, upload: 500),
            transport: RecordingTransport().transport, seed: 7, timer: Self.timer())

        #expect(step.detail.contains(InternetSpeedService.cloudflare.rawValue), "\(step.detail)")
        #expect(step.detail.contains("speed.cloudflare.com"), "\(step.detail)")
        #expect(step.detail.contains("GET /__down?bytes=1000"), "\(step.detail)")
        #expect(step.detail.contains("POST /__up with 500 generated bytes"), "\(step.detail)")
        #expect(step.detail.contains(InternetSpeedProbe.carriesNothing), "\(step.detail)")
    }

    // MARK: - Off sends nothing

    @Test func theOffServiceBuildsNoRequestAtAll() async throws {
        let transport = RecordingTransport()

        let step = await InternetSpeedProbe.measure(
            settings: Self.settings(.off), transport: transport.transport, seed: 7,
            timer: Self.timer())

        #expect(step.outcome == .unavailable(DiagnosticReason.internetSpeedOff))
        #expect(transport.sent.isEmpty, "\(transport.sent.map(\.url))")
        #expect(step.table == nil)
    }

    // MARK: - A service that refuses, or stalls

    /// A refused service is `unavailable`, never `failed`: `failed` in this
    /// report is a finding about the user's SERVER, and a free service
    /// answering 429 to this Mac is not one.
    @Test func aRefusedServiceReadsUnavailableAndNeverFailed() async throws {
        let transport = RecordingTransport(answer: { _ in throw InternetSpeedRefusal.status(429) })

        let step = await InternetSpeedProbe.measure(
            settings: Self.settings(download: 1000, upload: 500),
            transport: transport.transport, seed: 7, timer: Self.timer())

        let isFailed: Bool
        switch step.outcome {
        case .failed: isFailed = true
        default: isFailed = false
        }
        #expect(isFailed == false, "\(step.outcome.label)")
        #expect(step.outcome == .unavailable(
            DiagnosticReason.internetSpeedLegFailed(
                DiagnosticInternetSpeedColumn.down, "the service answered HTTP 429")))
        // The upload is not asked once the download did not finish.
        #expect(transport.sent.count == 1, "\(transport.sent.map(\.url))")
        #expect(step.table == nil, "a header over no rows claims a measurement nobody made")
    }

    /// A service that never answers is abandoned at the bound and reads
    /// `unavailable`. The fake PARKS — it waits on a latch nobody raises,
    /// which returns only on cancellation — so nothing here finishes on its
    /// own while the deadline races it.
    @Test func aStalledServiceIsBoundedAndReadsUnavailable() async throws {
        let parked = AsyncSignal()
        let transport = RecordingTransport(answer: { _ in
            _ = await parked.wait()
            return 0
        })

        let step = await InternetSpeedProbe.measure(
            settings: Self.settings(download: 1000, upload: 500, legTimeout: .milliseconds(50)),
            transport: transport.transport, seed: 7, timer: Self.timer())

        #expect(step.outcome == .unavailable(DiagnosticReason.internetSpeedTooSlow))
        #expect(transport.sent.count == 1, "the upload ran after the download was abandoned")
    }

    /// A refused redirect is its own reason, not the transport's sentence:
    /// a fixed one, so the panel can render it in the reader's language,
    /// and the two origins go into the detail beside the service that was
    /// asked — so the row names WHO was asked and where they tried to send
    /// it, which is the whole point of refusing loudly
    /// (`S3RedirectDecision.refuse`).
    @Test func aRefusedRedirectReadsUnavailableWithItsOwnReason() async throws {
        let transport = RecordingTransport(answer: { _ in
            throw InternetSpeedRefusal.redirect(
                from: "https://speed.cloudflare.com:443", to: "http://10.0.0.1:80")
        })

        let step = await InternetSpeedProbe.measure(
            settings: Self.settings(download: 1000, upload: 500),
            transport: transport.transport, seed: 7, timer: Self.timer())

        #expect(step.outcome == .unavailable(DiagnosticReason.internetSpeedRedirectRefused))
        #expect(step.detail.contains("speed.cloudflare.com"), "\(step.detail)")
        #expect(step.detail.contains("http://10.0.0.1:80"), "\(step.detail)")
        #expect(step.detail.contains(InternetSpeedService.cloudflare.rawValue), "\(step.detail)")
        #expect(transport.sent.count == 1, "the upload was asked after a refused redirect")
    }

    /// A service that answers with nothing has no rate to report.
    @Test func aServiceThatSendsNoBytesReadsUnavailable() async throws {
        let transport = RecordingTransport(answer: { _ in 0 })

        let step = await InternetSpeedProbe.measure(
            settings: Self.settings(download: 1000, upload: 500),
            transport: transport.transport, seed: 7, timer: Self.timer())

        #expect(step.outcome == .unavailable(DiagnosticReason.internetSpeedNoBytes))
    }

    /// An upload that fails after the download finished keeps the download's
    /// row: the half that was measured is reported, and the half that was
    /// not is the reason.
    @Test func aDownloadThatFinishedIsReportedEvenWhenTheUploadDoesNot() async throws {
        let transport = RecordingTransport(answer: { request in
            guard request.httpMethod == "POST" else { return 1000 }
            throw InternetSpeedRefusal.status(503)
        })

        let step = await InternetSpeedProbe.measure(
            settings: Self.settings(download: 1000, upload: 500),
            transport: transport.transport, seed: 7, timer: Self.timer())

        #expect(step.outcome == .unavailable(
            DiagnosticReason.internetSpeedLegFailed(
                DiagnosticInternetSpeedColumn.up, "the service answered HTTP 503")))
        let table = try #require(step.table)
        #expect(table.rows.map { $0[0] } == [DiagnosticInternetSpeedColumn.down])
    }

    // MARK: - The scope runs nothing else

    /// The shipping payload pair and bound, pinned where the docs quote
    /// them: 10 MiB down, 1 MiB up, a fixed pair and not a setting, each
    /// leg bounded at 45 s.
    @Test func theShippingPayloadIsTenMebibytesDownAndOneUp() {
        #expect(DiagnosticInternetSpeedSettings.defaultDownloadBytes == 10 * 1024 * 1024)
        #expect(DiagnosticInternetSpeedSettings.defaultUploadBytes == 1024 * 1024)
        #expect(DiagnosticInternetSpeedSettings.defaultService == .cloudflare)
        #expect(DiagnosticInternetSpeedSettings.defaultLegTimeout == .seconds(45))
    }

    /// Only the `internet` scope runs the internet step, and only that
    /// scope skips the session entirely — the two halves of "the scope runs
    /// nothing else", derived from `allCases` so an eighth scope is red
    /// rather than silently joining either side.
    @Test func onlyTheInternetScopeRunsItAndOnlyItSkipsTheSession() {
        for scope in DiagnosticScope.allCases {
            #expect(
                scope.runs(.internet) == (scope == .internet),
                "\(scope.rawValue) runs the internet step: \(scope.runs(.internet))")
            #expect(
                scope.measuresTheSession == (scope != .internet),
                "\(scope.rawValue) measures the session: \(scope.measuresTheSession)")
        }
        #expect(DiagnosticScope.internet.resolvesASecret == false)
    }

    /// The walk: one row, no endpoint and no jump host in the report, and
    /// nothing else measured.
    @Test func theWalkProducesOneRowAndNamesNoServer() async throws {
        let transport = RecordingTransport()
        let diagnostics = Self.diagnostics(transport: transport, service: .cloudflare)

        let report = await diagnostics.run(scope: .internet)

        #expect(report.steps.map(\.id) == [DiagnosticStepID.internet])
        #expect(report.endpoint == nil, "the report names a server the run never touched")
        #expect(report.jump == nil)
        #expect(report.scope == .internet)
        #expect(report.completion == .complete)
        // The positive check beside the two `nil`s above: the run really did
        // measure something, so the absent header is an omission and not an
        // empty report.
        #expect(transport.sent.count == 2, "\(transport.sent.map(\.url))")
        // And the host the session names reaches nothing that was sent.
        #expect(!transport.sent.contains { $0.url.contains(Self.sessionHost) })
        #expect(!report.plainText().contains(Self.sessionHost), "\(report.plainText())")
    }

    /// A walk that asks for anything BUT the internet scope sends no
    /// request. The complete walk is the one that matters: it is what the
    /// Run button means by default.
    @Test func theCompleteScopeSendsNoRequestToAnySpeedService() async throws {
        let listener = try #require(LoopbackSocket.listening())
        defer { listener.close() }
        let transport = RecordingTransport()
        let diagnostics = Self.diagnostics(
            transport: transport, service: .cloudflare, port: listener.port)

        let report = await diagnostics.run(scope: .complete)

        #expect(!report.steps.contains { $0.id == DiagnosticStepID.internet })
        #expect(report.steps.contains { $0.id == DiagnosticStepID.tcp }, "the walk ran nothing")
        #expect(transport.sent.isEmpty, "\(transport.sent.map(\.url))")
    }

    // MARK: - Cancelling the walk

    /// Cancelled BEFORE the step starts: no row, no announcement, and the
    /// report says how far it got. Nothing of this step outlives it —
    /// there is no file on anybody's server to name — so, unlike the
    /// throughput row, there is no row a cancel keeps.
    @Test func aWalkCancelledBeforeTheStepAnnouncesNothingAndMeasuresNothing() async throws {
        let transport = RecordingTransport()
        let diagnostics = Self.diagnostics(transport: transport, service: .cloudflare)
        let starts = StepStarts()
        let entered = AsyncSignal()
        let parked = AsyncSignal()

        let run = Task {
            entered.signal()
            // Returns `.cancelled` the moment the test cancels this task,
            // so the walk below begins in an already-cancelled task —
            // deterministically, rather than by racing `cancel()` against
            // the walk's first line.
            _ = await parked.wait()
            return await diagnostics.run(scope: .internet, observer: starts.observer)
        }
        #expect(await entered.wait() == .signalled)
        run.cancel()
        let report = await run.value

        #expect(report.steps.isEmpty)
        #expect(report.completion == .cancelled(afterSteps: 0))
        #expect(starts.announced.isEmpty, "\(starts.announced)")
        #expect(transport.sent.isEmpty, "a cancelled walk sent a request anyway")
    }

    /// Cancelled while the step is in flight: the step is announced and
    /// finishes — its own bound sees the cancellation — but the row is
    /// never published, because a cut-short measurement must not be
    /// reported as one.
    ///
    /// The transport PARKS on a latch nobody raises, so nothing here
    /// finishes on its own while the cancellation races it.
    @Test func aWalkCancelledDuringTheStepKeepsNoRow() async throws {
        let reached = AsyncSignal()
        let parked = AsyncSignal()
        let transport = RecordingTransport(answer: { _ in
            reached.signal()
            _ = await parked.wait()
            return 0
        })
        let diagnostics = Self.diagnostics(transport: transport, service: .cloudflare)
        let starts = StepStarts()

        let run = Task { await diagnostics.run(scope: .internet, observer: starts.observer) }
        #expect(await reached.wait() == .signalled)
        run.cancel()
        let report = await run.value

        #expect(report.steps.isEmpty, "\(report.steps.map(\.id))")
        #expect(report.completion == .cancelled(afterSteps: 0))
        // The positive check beside those two: the step really was
        // announced and really was reached, so the empty list above is a
        // dropped row and not a walk that never started.
        #expect(starts.announced == [DiagnosticStepID.internet], "\(starts.announced)")
        #expect(transport.sent.count == 1, "\(transport.sent.count)")
    }

    /// The CLI's JSON gains a key and renames none: the internet table
    /// arrives under `internet`, built from the table's own column names.
    @Test func theCLIJSONCarriesTheTableUnderItsOwnKey() async throws {
        let step = await InternetSpeedProbe.measure(
            settings: Self.settings(download: 1000, upload: 500),
            transport: RecordingTransport().transport, seed: 7, timer: Self.timer())

        let object = DiagnoseRendering.jsonObject(for: step)
        #expect(object["hops"] == nil)
        #expect(object["throughput"] == nil)
        let rows = try #require(object["internet"] as? [[String: String]])
        #expect(rows.count == 2)
        #expect(rows.allSatisfy { Set($0.keys) == ["direction", "bytes", "duration", "rate"] },
            "\(rows)")
        #expect(rows.map { $0["direction"] } == [
            DiagnosticInternetSpeedColumn.down, DiagnosticInternetSpeedColumn.up,
        ])
    }

    // MARK: - Fixtures

    /// A host no test may send anywhere. `.test` is reserved (RFC 6761), so
    /// this is not a real host name of anybody's.
    static let sessionHost = "session.invalid.test"

    static func diagnostics(
        transport: RecordingTransport, service: InternetSpeedService, port: Int = 22
    ) -> ConnectionDiagnostics {
        var values = SSHFieldSchema.defaults
        values[SSHField.host] = port == 22 ? Self.sessionHost : "127.0.0.1"
        values[SSHField.port] = String(port)
        values[SSHField.username] = "tester"
        values[SSHField.authKind] = StoredSession.AuthKind.agent.rawValue
        let ssh = BackendDescriptor.descriptor(for: .ssh)
        let descriptor = BackendDescriptor(
            kind: .ssh, capabilities: ssh.capabilities,
            connectionSchema: ssh.connectionSchema, credentialSchema: ssh.credentialSchema,
            makeConfig: ssh.makeConfig, displaySummary: ssh.displaySummary, apply: ssh.apply,
            connect: { _, _, _, _ in throw RemoteFSError.protocolError(reason: "unused") },
            badgeLabelKey: "b", badgeLabelDefault: "B", secretEnvironmentVariable: nil,
            requiresSecret: { _ in false }, fileActions: [],
            endpoint: ssh.endpoint, dial: nil, diagnostics: [])
        var settings = DiagnosticInternetSpeedSettings(service: service)
        settings.downloadBytes = 1000
        settings.uploadBytes = 500
        return ConnectionDiagnostics(
            descriptor: descriptor, values: values, secrets: nil, sessionID: UUID(),
            jump: nil, jumpDialer: JumpDialerThatIsNeverCalled.dialer,
            lookups: ResolveLookups(reverse: { _, _ in nil }, forward: { _, _, _ in nil }),
            throughput: DiagnosticThroughputSettings(),
            internetSpeed: settings, internetSpeedTransport: transport.transport,
            stepTimeout: .seconds(2), traceTimeout: .seconds(2), appVersion: "test")
    }
}

/// The step ids a walk announced, in order.
final class StepStarts: Sendable {
    private let ids = Mutex<[String]>([])

    var announced: [String] { ids.withLock { $0 } }

    var observer: DiagnosticRunObserver {
        DiagnosticRunObserver(onStepStarted: { [self] id, _ in ids.withLock { $0.append(id) } })
    }
}

extension InternetSpeedTransport {
    /// The transport for a suite that runs no `.internet` scope.
    ///
    /// `ConnectionDiagnostics`'s internal initializer requires a transport
    /// with no default, so that a caller cannot reach `.live` by omission
    /// (that initializer's doc comment says why). What such a caller means
    /// is "nothing asks this", and this value SAYS so: it records an issue
    /// before it throws, so a suite that starts asking finds out loudly
    /// rather than reading a refusal as an ordinary failure.
    static let neverAsked = InternetSpeedTransport { _ in
        Issue.record("a suite that runs no internet speed test reached its transport")
        throw RemoteFSError.protocolError(reason: "no internet speed test in this suite")
    }
}

/// What one request looked like, in fields — never the `URLRequest`, so a
/// case can compare a whole header dictionary for equality and a value can
/// be printed in a failure message without anything of a session in it.
struct SentSpeedRequest: Sendable, Equatable {
    let method: String
    let url: String
    let headers: [String: String]
    let body: Data?
    let timeoutSeconds: TimeInterval

    init(_ request: URLRequest) {
        method = request.httpMethod ?? "GET"
        url = request.url?.absoluteString ?? ""
        headers = request.allHTTPHeaderFields ?? [:]
        body = request.httpBody
        timeoutSeconds = request.timeoutInterval
    }
}

/// The internet speed test's transport, recorded. Answers the requested
/// byte count by default — a download's from its query or its range, an
/// upload's from its body — so a case that is not about failure gets two
/// finished legs.
final class RecordingTransport: Sendable {
    private let recorded = Mutex<[SentSpeedRequest]>([])
    private let answer: @Sendable (URLRequest) async throws -> Int

    init(answer: @escaping @Sendable (URLRequest) async throws -> Int = RecordingTransport.echo) {
        self.answer = answer
    }

    var sent: [SentSpeedRequest] { recorded.withLock { $0 } }

    /// The closure captures `self` and not the `Mutex`: a `Mutex` is
    /// non-copyable, so a capture list that names it consumes it.
    var transport: InternetSpeedTransport {
        InternetSpeedTransport { [self] request in
            recorded.withLock { $0.append(SentSpeedRequest(request)) }
            return try await answer(request)
        }
    }

    /// As many bytes as the request asked for: the body's count for an
    /// upload, and for a download the `bytes=` query or the end of the
    /// `Range` plus one.
    static let echo: @Sendable (URLRequest) async throws -> Int = { request in
        if let body = request.httpBody { return body.count }
        if let query = request.url?.query(),
            let value = query.split(separator: "=").last.flatMap({ Int($0) })
        {
            return value
        }
        if let range = request.value(forHTTPHeaderField: "Range"),
            let last = range.split(separator: "-").last.flatMap({ Int($0) })
        {
            return last + 1
        }
        return 0
    }
}

/// A clock that returns a written-down sequence of instants, so a rate is
/// arithmetic rather than a measurement of the machine.
///
/// `offsets` are measured from one instant taken at construction; the last
/// one repeats if anything reads past the end, which is what keeps a
/// miscounted read from crashing instead of failing.
final class TickingClock: Sendable {
    private let base = ContinuousClock().now
    private let offsets: [Duration]
    private let index = Mutex(0)

    init(offsets: [Duration]) {
        self.offsets = offsets
    }

    /// How many times the clock has been read — the contract
    /// `theClockIsReadTwicePerLeg` holds.
    var readings: Int { index.withLock { $0 } }

    /// Captures `self`, for `RecordingTransport.transport`'s reason.
    var now: @Sendable () -> ContinuousClock.Instant {
        { [self] in
            let position = index.withLock { position -> Int in
                defer { position += 1 }
                return position
            }
            return base.advanced(by: offsets[min(position, offsets.count - 1)])
        }
    }
}
