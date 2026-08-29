import Foundation
import Testing

@testable import macSCPCore

/// The redirect rule as a value, asked directly.
///
/// Everything decidable about a redirect is decidable here, without a
/// session and without a socket — which is why the rule is a value and not
/// a branch inside a delegate method. `S3RedirectControlTests` then shows
/// the delegate carrying out these same answers over loopback; between them
/// the cases a stub cannot produce (an `https` downgrade, an unknown
/// scheme) are still covered.
@Suite("S3 redirect decision")
struct S3RedirectDecisionTests {

    private func url(_ text: String) throws -> URL {
        try #require(URL(string: text))
    }

    // MARK: - Same origin

    @Test("a different path on the same origin is re-signed and followed")
    func sameOriginDifferentPath() throws {
        #expect(S3RedirectDecision.decide(
            from: try url("https://s3.example.com/bucket?list-type=2"),
            to: try url("https://s3.example.com/bucket/elsewhere")) == .reSignAndFollow)
    }

    /// A spelled-out default port is the same origin as an omitted one.
    /// Comparing `url.port` raw would make `https://h/` and `https://h:443/`
    /// foreign to each other and refuse a redirect that never left.
    @Test("a spelled-out default port is the same origin as an omitted one")
    func defaultPortIsFilledIn() throws {
        #expect(S3RedirectDecision.decide(
            from: try url("https://s3.example.com/bucket"),
            to: try url("https://s3.example.com:443/bucket/hop")) == .reSignAndFollow)
        #expect(S3RedirectDecision.decide(
            from: try url("http://s3.example.com:80/bucket"),
            to: try url("http://s3.example.com/bucket/hop")) == .reSignAndFollow)
    }

    /// Scheme and host are case-insensitive by definition, so a `Location`
    /// that shouts is still the same origin.
    @Test("scheme and host compare case-insensitively")
    func caseDoesNotMakeAnOriginForeign() throws {
        #expect(S3RedirectDecision.decide(
            from: try url("https://s3.example.com/bucket"),
            to: try url("HTTPS://S3.Example.COM/bucket/hop")) == .reSignAndFollow)
    }

    @Test("a same-origin decision carries no refusal message")
    func followingSaysNothing() throws {
        let decision = S3RedirectDecision.decide(
            from: try url("https://s3.example.com/bucket"),
            to: try url("https://s3.example.com/bucket/hop"))
        #expect(decision.refusalMessage == nil)
    }

    // MARK: - Foreign origin

    /// Each of the three parts of an origin, alone, makes a target foreign
    /// — RFC 6454, applied without discretion. The `https` → `http` row is
    /// the one this definition was chosen for: a redirect that takes the
    /// encryption away is the one least worth following, and a host-only
    /// comparison would have followed it.
    @Test("any one of scheme, host or port makes the target foreign",
          arguments: [
            ("https://s3.example.com/bucket", "https://s3.example.com:8443/bucket", "port"),
            ("https://s3.example.com/bucket", "https://attacker.example/bucket", "host"),
            ("https://s3.example.com/bucket", "http://s3.example.com/bucket", "scheme"),
          ])
    func foreignOrigins(from: String, to: String, part: String) throws {
        let decision = S3RedirectDecision.decide(from: try url(from), to: try url(to))
        guard case .refuse = decision else {
            Issue.record("a target differing in \(part) was not refused: \(decision)")
            return
        }
    }

    /// Fails closed on a target it cannot read as an origin. A scheme with
    /// no default port has no port to compare, and a URL with no host has
    /// no host — neither is a match, and neither may be guessed into one.
    @Test("a target that is not an http origin is refused",
          arguments: ["ftp://s3.example.com/bucket", "file:///etc/passwd", "mailto:a@b.example"])
    func unreadableTargetsAreRefused(target: String) throws {
        let decision = S3RedirectDecision.decide(
            from: try url("https://s3.example.com/bucket"), to: try url(target))
        guard case .refuse = decision else {
            Issue.record("\(target) was not refused: \(decision)")
            return
        }
    }

    // MARK: - What a refusal says

    /// The port is spelled out even when it is the scheme's default,
    /// because the downgrade case is exactly where two origins would
    /// otherwise print the same name twice and the message would say
    /// nothing.
    @Test("a refusal names both origins, scheme and port included")
    func refusalNamesBothOrigins() throws {
        let decision = S3RedirectDecision.decide(
            from: try url("https://s3.example.com/bucket?list-type=2"),
            to: try url("http://s3.example.com/bucket"))
        guard case .refuse(let from, let to) = decision else {
            Issue.record("expected a refusal, got \(decision)")
            return
        }
        #expect(from == "https://s3.example.com:443")
        #expect(to == "http://s3.example.com:80")
        #expect(from != to, "the two origins print the same name; the message says nothing")
    }

    /// Origin only: the endpoint wrote the `Location` header, and what a
    /// reader needs from it is which server, not which object. The path of
    /// the target must therefore not appear.
    @Test("a refusal quotes no path and no query from the target")
    func refusalQuotesNoPath() throws {
        let decision = S3RedirectDecision.decide(
            from: try url("https://s3.example.com/bucket"),
            to: try url("https://attacker.example/collect?note=run-this"))
        let message = try #require(decision.refusalMessage)
        #expect(message.contains("https://attacker.example:443"))
        #expect(message.contains("/collect") == false, "the refusal quotes the target's path")
        #expect(message.contains("run-this") == false, "the refusal quotes the target's query")
    }

    /// The message is a catalog entry, so it can be missing from the
    /// catalogs and still compile, print the raw key, and pass every
    /// assertion above. The key is read from the type rather than spelled
    /// here, so a rename cannot leave this checking a name nothing uses.
    @Test func theRefusalKeyResolves() {
        let key = S3RedirectDecision.refusalMessageKey
        #expect(CoreL10n.string(key) != key, "\(key) is in no catalog")
    }

    /// And the resolved sentence really is what a refusal reports — the
    /// check above would pass just as well if `refusalMessage` ignored the
    /// catalog and returned something of its own.
    @Test func theRefusalMessageIsTheCatalogSentence() throws {
        let decision = S3RedirectDecision.decide(
            from: try url("http://127.0.0.1:1/bucket"), to: try url("http://127.0.0.1:2/bucket"))
        let expected = String(
            format: CoreL10n.string(S3RedirectDecision.refusalMessageKey),
            "http://127.0.0.1:1", "http://127.0.0.1:2")
        #expect(decision.refusalMessage == expected)
    }
}
