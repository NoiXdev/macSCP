import Foundation
import Testing

@testable import macSCPCore

/// The WebDAV half of the first two seam contributions (design §3): what the
/// server CLAIMS to be.
///
/// `OPTIONS` on the session's root brings back the `DAV:` compliance classes
/// and the `Allow` list; a `Depth: 0` `PROPFIND` on the same URL brings back
/// the resource type. Unlike the dial's unauthenticated `OPTIONS`, this one
/// authenticates — through the same secret source the connect uses — so what
/// it reports is what this LOGIN sees.
@Suite("WebDAV claims probe")
struct WebDAVOptionsProbeTests {
    private static let base = WebDAVURL(
        baseURL: URL(string: "https://dav.example.com/dav")!, nextcloudUser: nil)

    private static let collectionBody = Data(
        """
        <?xml version="1.0" encoding="utf-8"?>
        <D:multistatus xmlns:D="DAV:">
        <D:response><D:href>/dav/</D:href><D:propstat><D:prop>
        <D:resourcetype><D:collection/></D:resourcetype>
        </D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>
        </D:multistatus>
        """.utf8)

    private static let fileBody = Data(
        """
        <?xml version="1.0" encoding="utf-8"?>
        <D:multistatus xmlns:D="DAV:">
        <D:response><D:href>/dav/a.txt</D:href><D:propstat><D:prop>
        <D:resourcetype/><D:getcontentlength>7</D:getcontentlength>
        </D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>
        </D:multistatus>
        """.utf8)

    private static let secretUnderTest = "webdav-claims-probe-secret-value"

    // MARK: - The line the step reports

    @Test func theDetailNamesTheClassesTheAllowListAndTheResourceType() async {
        let transport = FakeHTTPTransport(replies: [
            .init(
                status: 200, body: Data(),
                headers: ["DAV": "1,2", "Allow": "OPTIONS,GET,PROPFIND"]),
            .init(status: 207, body: Self.collectionBody, headers: [:]),
        ])

        let claims = await WebDAVClaimsProbe(base: Self.base, transport: transport).run()

        #expect(
            WebDAVClaimsProbe.detail(claims) == "OPTIONS 200 · DAV: 1,2 · "
                + "Allow: OPTIONS,GET,PROPFIND · PROPFIND 207 · the root is a collection")
    }

    /// A server that answers `OPTIONS` without being a DAV server at all is a
    /// finding, not an error — and the row says which header was missing
    /// rather than leaving a gap the reader has to interpret.
    @Test func aServerWithoutTheTwoHeadersSaysSoRatherThanLeavingAGap() async {
        let transport = FakeHTTPTransport(replies: [
            .init(status: 200, body: Data(), headers: [:]),
            .init(status: 207, body: Self.fileBody, headers: [:]),
        ])

        let claims = await WebDAVClaimsProbe(base: Self.base, transport: transport).run()

        #expect(
            WebDAVClaimsProbe.detail(claims) == "OPTIONS 200 · no DAV header · "
                + "no Allow header · PROPFIND 207 · the root is not a collection")
    }

    @Test func bothCallsAddressTheSessionsRootAndAskForDepthZero() async {
        let transport = FakeHTTPTransport(replies: [
            .init(status: 200, body: Data(), headers: ["DAV": "1"]),
            .init(status: 207, body: Self.collectionBody, headers: [:]),
        ])

        _ = await WebDAVClaimsProbe(base: Self.base, transport: transport).run()

        let requests = transport.requests
        #expect(requests.count == 2)
        #expect(requests.first?.httpMethod == "OPTIONS")
        #expect(requests.first?.url?.absoluteString == "https://dav.example.com/dav/")
        #expect(requests.last?.httpMethod == "PROPFIND")
        #expect(requests.last?.value(forHTTPHeaderField: "Depth") == "0")
        #expect(requests.last?.url?.absoluteString == "https://dav.example.com/dav/")
    }

    /// The Nextcloud accommodation is part of what a session's root IS, so
    /// the probe asks about the collection the session would actually browse.
    @Test func theNextcloudPathIsPartOfTheRootTheProbeAsksAbout() async {
        let base = WebDAVURL(
            baseURL: URL(string: "https://cloud.example.com")!, nextcloudUser: "testuser")
        let transport = FakeHTTPTransport(replies: [
            .init(status: 200, body: Data(), headers: ["DAV": "1"]),
            .init(status: 207, body: Self.collectionBody, headers: [:]),
        ])

        _ = await WebDAVClaimsProbe(base: base, transport: transport).run()

        #expect(
            transport.requests.first?.url?.absoluteString
                == "https://cloud.example.com/remote.php/dav/files/testuser/")
    }

    // MARK: - The step's outcome

    @Test func aServerThatAnsweredMakesTheStepOKWhateverItAnswered() async {
        let transport = FakeHTTPTransport(replies: [
            .init(status: 401, body: Data(), headers: [:]),
            .init(status: 401, body: Data(), headers: [:]),
        ])

        let claims = await WebDAVClaimsProbe(base: Self.base, transport: transport).run()

        #expect(WebDAVClaimsProbe.outcome(of: claims) == .ok)
    }

    @Test func aTransportThatNeverReachedTheServerFailsTheStep() async {
        let transport = FakeHTTPTransport(
            replies: [], transportError: URLError(.cannotConnectToHost))

        let claims = await WebDAVClaimsProbe(base: Self.base, transport: transport).run()

        guard case .failed(let reason) = WebDAVClaimsProbe.outcome(of: claims) else {
            Issue.record("a probe that reached nothing must fail the step")
            return
        }
        #expect(!reason.isEmpty)
        // The positive anchor: both calls are still named, so the failure is a
        // verdict about the server rather than an empty row.
        #expect(WebDAVClaimsProbe.detail(claims).contains("OPTIONS"))
        #expect(WebDAVClaimsProbe.detail(claims).contains("PROPFIND"))
    }

    @Test func theProbeNeverWritesTheSecretIntoItsLine() async throws {
        let secret = Self.secretUnderTest
        var values = FieldValues()
        values[WebDAVField.baseURL] = "http://127.0.0.1:1/dav"
        values[WebDAVField.username] = "testuser"

        let contribution = try #require(
            BackendDescriptor.descriptor(for: .webdav).diagnostics.first)
        let step = await contribution.run(
            values,
            DiagnosticContext(
                secrets: FixedWebDAVSecret(value: secret), sessionID: UUID(),
                timeout: .seconds(2)))

        let leaks = step.detail.contains(secret) || step.outcome.label.contains(secret)
        #expect(leaks == false)
        // The positive anchor: the row was really measured, so the check above
        // is not reading an empty step.
        #expect(step.detail.contains("OPTIONS"))
    }

    @Test func theContributionSkipsWhenNoSecretIsAvailable() async throws {
        var values = FieldValues()
        values[WebDAVField.baseURL] = "http://127.0.0.1:18080/dav"
        values[WebDAVField.username] = "testuser"

        let contribution = try #require(
            BackendDescriptor.descriptor(for: .webdav).diagnostics.first)
        let step = await contribution.run(
            values, DiagnosticContext(secrets: nil, sessionID: nil, timeout: .seconds(5)))

        #expect(step.outcome == .skipped(DiagnosticReason.noSecret))
    }

    // MARK: - Against the rig's Apache

    /// The rig's Basic-auth vhost on plain HTTP (`docker/test-server/compose.yml`,
    /// 18080 -> 8080), user `testuser`/`testpass`.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MACSCP_ITEST"] == "1"))
    func theRigsApacheNamesItsClassesAndItsRoot() async throws {
        var values = FieldValues()
        values[WebDAVField.baseURL] = "http://127.0.0.1:18080/dav"
        values[WebDAVField.username] = "testuser"

        let contribution = try #require(
            BackendDescriptor.descriptor(for: .webdav).diagnostics.first)
        let step = await contribution.run(
            values,
            DiagnosticContext(
                secrets: FixedWebDAVSecret(value: "testpass"), sessionID: UUID(),
                timeout: .seconds(10)))

        #expect(step.id == contribution.id)
        #expect(step.titleKey == contribution.titleKey)
        #expect(step.outcome == .ok)
        #expect(step.detail.contains("OPTIONS 200"))
        // Apache/mod_dav answers classes 1 and 2 and allows PROPFIND; the
        // PROPFIND itself is a 207 multistatus naming a collection.
        #expect(step.detail.contains("DAV: 1,2"))
        #expect(step.detail.contains("PROPFIND"))
        #expect(step.detail.contains("PROPFIND 207"))
        #expect(step.detail.contains("the root is a collection"))
    }
}

/// A `SecretSource` that answers the same value for any session — the seam
/// the contribution resolves through, without a keychain.
private struct FixedWebDAVSecret: SecretSource {
    let value: String
    var label: String { "fixed" }
    func secret(for sessionID: UUID) throws -> String? { value }
}
