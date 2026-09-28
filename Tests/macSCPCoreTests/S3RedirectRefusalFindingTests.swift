import Foundation
import Testing

@testable import macSCPCore

/// What a REFUSED redirect is, once it is a named finding, and what it still
/// reads as.
///
/// `S3HTTPChannel.refusedRedirect()` is the one site in the 2026-09-28
/// typed-findings plan that constructed `RemoteFSError.connectionFailed`
/// rather than `.protocolError`, so it is the one whose conversion could
/// change behaviour: `isConnectionFailure` is what
/// `TransferQueueViewModel` reads to classify a mid-transfer failure as
/// resumable rather than failed, and `DialSupport` reads the same property
/// for the diagnostics row's kind. Both are pinned here.
///
/// The three refusals are driven through the delegate's own
/// `URLSessionTaskDelegate` method and read back through the channel,
/// because that is the whole path a caller meets — the delegate records,
/// the channel reports. A stub session is enough: the method is answered
/// synchronously and nothing is ever sent.
///
/// What this cannot see: whether a real endpoint produces any of these
/// three shapes. `S3RedirectControlTests` drives the foreign-origin refusal
/// end to end over loopback; these three are reached by handing the
/// decision point the request `URLSession` would hand it.
@Suite("S3 redirect refusals as findings")
struct S3RedirectRefusalFindingTests {

    // MARK: - The property the whole conversion turns on

    /// The load-bearing one. Written before the conversion and green then
    /// too: `RemoteFSFinding.readsAsConnectionFailure` was built for this in
    /// Task 1, and this is what says the three redirect findings are the
    /// ones it is true for.
    @Test("a refused redirect still reads as a connection failure")
    func aRefusedRedirectStillReadsAsAConnectionFailure() {
        for finding in Self.redirectFindings {
            #expect(RemoteFSError.finding(finding).isConnectionFailure)
        }
        // The positive beside it: a finding that is not a redirect does not.
        #expect(RemoteFSError.finding(.outOfStorage).isConnectionFailure == false)
    }

    /// The second consumer of the same property. A refused redirect reached
    /// the diagnostic log as `.connectionFailed` before it was typed, and
    /// still does; only the sentence improves, from the kind's generic one
    /// to the finding's own.
    @Test("the dial keeps the connectionFailed kind for every redirect refusal")
    func theDialKeepsTheConnectionFailedKindForEveryRedirectRefusal() {
        for finding in Self.redirectFindings {
            let error = RemoteFSError.finding(finding)
            #expect(DialSupport.failureKind(for: error) == .connectionFailed)
            #expect(DialSupport.reason(for: error) == finding.logSentence)
        }
        // The positive beside it: a finding from a `.protocolError` site
        // gets the other kind, so the check above is not reading a function
        // that answers `.connectionFailed` for everything.
        #expect(
            DialSupport.failureKind(for: RemoteFSError.finding(.outOfStorage))
                == .serverAnswerUnusable)
    }

    private static let redirectFindings: [RemoteFSFinding] = [
        .redirectUnreadable, .redirectBodyNotResendable, .redirectNotResignable,
    ]

    // MARK: - The three refusals, delegate to channel

    /// The origin the stub delegate is configured for. Port and host are a
    /// loopback address nothing listens on: no request is made at all, the
    /// delegate's decision point is called directly.
    private static let endpointOrigin = "http://127.0.0.1:9000"

    private static func config() -> S3ConnectionConfig {
        S3ConnectionConfig(
            accessKeyID: "AKIAREDIRECTFINDING", secretAccessKey: "redirect-finding-secret",
            region: "us-east-1", endpoint: endpointOrigin,
            bucket: "bucket-redirect-finding", usePathStyle: true, sessionToken: nil)
    }

    /// One run of the delegate's decision point, read back the way a caller
    /// reads it: through the channel that carries the delegate.
    ///
    /// Returns the answer the delegate gave `URLSession` as well, so a test
    /// can assert the redirect was REFUSED (a `nil` request) beside asserting
    /// what was recorded — a recording read alone would look the same if the
    /// hop had been followed anyway.
    private static func refusal(
        leaving current: URL, proposing proposed: URLRequest
    ) -> (recorded: RemoteFSError?, answered: URLRequest?, decided: Bool) {
        let delegate = S3RedirectSessionDelegate(config: config())
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: URLRequest(url: current))
        let response = HTTPURLResponse(
            url: current, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: nil)!

        var answered: URLRequest?
        var decided = false
        delegate.urlSession(
            session, task: task, willPerformHTTPRedirection: response, newRequest: proposed
        ) { request in
            answered = request
            decided = true
        }

        let channel = S3HTTPChannel(
            transport: URLSessionHTTPTransport(session: session), redirectPolicy: delegate,
            cancel: {}, finish: {})
        return (channel.refusedRedirect(), answered, decided)
    }

    @Test("a redirect whose target cannot be read is the unreadable finding")
    func aRedirectWithNoReadableTargetIsTheUnreadableFinding() throws {
        let current = try #require(URL(string: "\(Self.endpointOrigin)/bucket/?list-type=2"))
        var proposed = URLRequest(url: current)
        // `URLRequest.url` is optional, and a proposal with none is exactly
        // what this arm exists for: there is nothing to judge an origin by.
        proposed.url = nil

        let outcome = Self.refusal(leaving: current, proposing: proposed)

        // Positives first: the decision point really ran, and it refused.
        #expect(outcome.decided)
        #expect(outcome.answered == nil)
        #expect(outcome.recorded == .finding(.redirectUnreadable))
    }

    @Test("a redirect of a streamed body is the not-resendable finding")
    func aRedirectOfAStreamedBodyIsTheNotResendableFinding() throws {
        let current = try #require(URL(string: "\(Self.endpointOrigin)/bucket/object"))
        // Same origin, so the decision is `reSignAndFollow` and the body
        // check below it is what refuses. A body that exists only as a
        // stream cannot be read a second time.
        var proposed = URLRequest(url: current)
        proposed.httpMethod = "PUT"
        proposed.httpBodyStream = InputStream(data: Data("payload".utf8))

        let outcome = Self.refusal(leaving: current, proposing: proposed)

        #expect(outcome.decided)
        #expect(outcome.answered == nil)
        #expect(outcome.recorded == .finding(.redirectBodyNotResendable))
    }

    @Test("a redirect that cannot be re-signed is the not-resignable finding")
    func aRedirectThatCannotBeReSignedIsTheNotResignableFinding() throws {
        let base = try #require(URL(string: "\(Self.endpointOrigin)/bucket/"))
        // A RELATIVE target: `S3RedirectDecision` resolves its origin
        // against the base and sees the endpoint's own, so the decision is
        // `reSignAndFollow` — while `S3RequestSigning.reSigned` reads the
        // target's components WITHOUT resolving the base (deliberately: it
        // signs what it was given), finds no host in them, and throws. The
        // one shape that reaches this arm without a seam of its own.
        let relative = try #require(URL(string: "sub/object", relativeTo: base))
        var proposed = URLRequest(url: base)
        proposed.url = relative

        let outcome = Self.refusal(leaving: base, proposing: proposed)

        #expect(outcome.decided)
        #expect(outcome.answered == nil)
        #expect(outcome.recorded == .finding(.redirectNotResignable))
    }

    // MARK: - The refusal that is NOT a finding

    /// The fourth refusal, and the reason `lastRefusedRedirect` carries a
    /// `RemoteFSError` rather than a `RemoteFSFinding`: a redirect to a
    /// FOREIGN origin is refused with a sentence naming both origins, and
    /// those two origins are text a server chose by writing a `Location`
    /// header. A finding carries no foreign words, so this one stays a
    /// `.connectionFailed` with the localized two-origin sentence it has had
    /// since 2026-08-29.
    ///
    /// The positive beside the three findings above: without it, a
    /// conversion that turned every refusal into one finding would pass them
    /// all.
    @Test("a foreign-origin refusal stays the two-origin sentence, not a finding")
    func aForeignOriginRefusalStaysTheTwoOriginSentence() throws {
        let current = try #require(URL(string: "\(Self.endpointOrigin)/bucket/"))
        let elsewhere = "http://127.0.0.1:9001"
        let proposed = URLRequest(url: try #require(URL(string: "\(elsewhere)/bucket/")))

        let outcome = Self.refusal(leaving: current, proposing: proposed)

        #expect(outcome.decided)
        #expect(outcome.answered == nil)
        let recorded = try #require(outcome.recorded)
        guard case .connectionFailed(let reason) = recorded else {
            Issue.record("expected .connectionFailed, got \(recorded)")
            return
        }
        // Asserted on the two origins rather than on a whole translated
        // sentence: the host's preferred language decides which catalog
        // answers. `S3RedirectDecisionTests.theRefusalKeyResolves` is what
        // says the key resolves to real text at all.
        let namesTheEndpoint = reason.contains(Self.endpointOrigin)
        let namesTheTarget = reason.contains(elsewhere)
        #expect(namesTheEndpoint)
        #expect(namesTheTarget)
        // And it reads as a lost connection, exactly as the three findings do.
        #expect(recorded.isConnectionFailure)
    }

    /// First refusal wins, across the two kinds a refusal can be. The
    /// property predates the conversion; what is new is that `record` now
    /// has two entry points, so the one lock and the one `alreadyRecorded`
    /// gate have to serve both.
    @Test("the first refusal wins, whichever kind the later one is")
    func theFirstRefusalWinsAcrossBothKinds() throws {
        let base = try #require(URL(string: "\(Self.endpointOrigin)/bucket/"))
        let delegate = S3RedirectSessionDelegate(config: Self.config())
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: URLRequest(url: base))
        let response = HTTPURLResponse(
            url: base, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: nil)!

        let channel = S3HTTPChannel(
            transport: URLSessionHTTPTransport(session: session), redirectPolicy: delegate,
            cancel: {}, finish: {})

        func offer(_ proposed: URLRequest) {
            delegate.urlSession(
                session, task: task, willPerformHTTPRedirection: response,
                newRequest: proposed
            ) { _ in }
        }

        var unreadable = URLRequest(url: base)
        unreadable.url = nil
        offer(unreadable)
        // The positive: the first refusal was recorded at all.
        #expect(channel.refusedRedirect() == .finding(.redirectUnreadable))

        offer(URLRequest(url: try #require(URL(string: "http://127.0.0.1:9001/bucket/"))))
        #expect(channel.refusedRedirect() == .finding(.redirectUnreadable))
    }
}
