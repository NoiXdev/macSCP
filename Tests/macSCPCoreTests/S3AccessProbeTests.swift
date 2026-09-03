import Foundation
import Testing

@testable import macSCPCore

/// The S3 half of the first two seam contributions (design §3): what the
/// session's own key may actually do against this endpoint.
///
/// Three signed calls, each reported with its status and the server's
/// `x-amz-request-id` — `HeadBucket` (may it see the bucket at all),
/// `ListObjectsV2` with `MaxKeys=1` (may it read the bucket's contents) and
/// `ListBuckets` (may it enumerate the account). The unit half drives a fake
/// transport, so what is measured is the request each call builds and the
/// line the step reports; the gated half asks the rig's MinIO and asserts
/// WHAT MINIO DOES — which is not what AWS would do, and is recorded as such
/// in `docs/superpowers/specs/2026-09-02-s3-bucket-browser-design.md`.
@Suite("S3 access probe")
struct S3AccessProbeTests {
    private static let config = S3ConnectionConfig(
        accessKeyID: "AK", secretAccessKey: "SK", region: "us-east-1",
        endpoint: "http://127.0.0.1:19000", bucket: "macscp-seed",
        usePathStyle: true, sessionToken: nil)

    /// The secret the leak check below substitutes. A named constant rather
    /// than a literal in the expectation: `#expect` reports the SOURCE TEXT
    /// of what it checks, so a secret written into an expectation leaks
    /// through the failure message — the very thing the test forbids
    /// (CLAUDE.md, "A value a test must not leak has two exits").
    private static let secretUnderTest = "s3-access-probe-secret-value"

    /// The userinfo halves of the endpoint the leak test below types. The
    /// password carries a `/` on purpose: that is the character
    /// `URLText.withoutUserinfo` cannot scan past, and therefore the shape
    /// that must not reach a row in the first place.
    private static let endpointUserinfoUser = "ENDPOINTKEYID"
    private static let endpointUserinfoPassword = "endpointpa/ssword"

    private static func reply(
        _ status: Int, requestID: String? = nil
    ) -> (Data, HTTPURLResponse) {
        var headers: [String: String] = [:]
        if let requestID { headers["x-amz-request-id"] = requestID }
        let response = HTTPURLResponse(
            url: URL(string: "http://127.0.0.1:19000/")!, statusCode: status,
            httpVersion: "HTTP/1.1", headerFields: headers)!
        return (Data(), response)
    }

    // MARK: - The line the step reports

    @Test func theDetailNamesEachCallItsStatusAndItsRequestID() async {
        let transport = FakeS3Transport(responses: [
            Self.reply(200, requestID: "REQ-HEAD"),
            Self.reply(200, requestID: "REQ-LIST"),
            Self.reply(403, requestID: "REQ-BUCKETS"),
        ])

        let results = await S3AccessProbe(config: Self.config, transport: transport).run()

        #expect(
            S3AccessProbe.detail(results) == "HeadBucket 200 (req REQ-HEAD) · "
                + "ListObjectsV2 200 (req REQ-LIST) · ListBuckets 403 (req REQ-BUCKETS)")
    }

    /// A server that answers nothing about its request ids still gets a row
    /// per call — the id is the server's to send, and a probe that dropped a
    /// measured status for want of one would report less than it measured.
    @Test func aCallWithoutARequestIDStillReportsItsStatus() async {
        let transport = FakeS3Transport(responses: [
            Self.reply(200), Self.reply(200), Self.reply(403),
        ])

        let results = await S3AccessProbe(config: Self.config, transport: transport).run()

        #expect(
            S3AccessProbe.detail(results)
                == "HeadBucket 200 · ListObjectsV2 200 · ListBuckets 403")
    }

    @Test func eachCallAddressesItsOwnResourceAndIsSigned() async throws {
        let transport = FakeS3Transport(responses: [
            Self.reply(200), Self.reply(200), Self.reply(200),
        ])

        _ = await S3AccessProbe(config: Self.config, transport: transport).run()

        let requests = await transport.requests
        guard requests.count == 3 else {
            Issue.record("the probe must send exactly three requests, sent \(requests.count)")
            return
        }

        #expect(requests[0].httpMethod == "HEAD")
        #expect(requests[0].url?.path == "/macscp-seed")
        #expect(requests[0].url?.query == nil)

        #expect(requests[1].httpMethod == "GET")
        #expect(requests[1].url?.path == "/macscp-seed")
        let listQuery = requests[1].url?.query ?? ""
        #expect(listQuery.contains("list-type=2"))
        #expect(listQuery.contains("max-keys=1"))

        #expect(requests[2].httpMethod == "GET")
        #expect(requests[2].url?.path == "/")
        #expect(requests[2].url?.query == nil)

        // Every one of them is a SIGNED request — an unsigned probe would
        // measure the endpoint, not the key.
        for request in requests {
            let authorization = request.value(forHTTPHeaderField: "Authorization") ?? ""
            #expect(authorization.hasPrefix("AWS4-HMAC-SHA256"))
        }
    }

    /// In bucket-list mode there is no one bucket to ask about, so the two
    /// bucket-level calls are not sent — and say why, rather than reporting a
    /// status nobody measured.
    @Test func bucketListModeSkipsTheTwoBucketCallsWithAReason() async throws {
        var config = Self.config
        config.startsAtBucketList = true
        let transport = FakeS3Transport(responses: [Self.reply(200, requestID: "REQ-BUCKETS")])

        let results = await S3AccessProbe(config: config, transport: transport).run()

        let requests = await transport.requests
        #expect(requests.count == 1)
        #expect(requests.first?.url?.path == "/")
        let skipped = S3AccessProbe.bucketListSkipReason
        #expect(
            S3AccessProbe.detail(results) == "HeadBucket skipped (\(skipped)) · "
                + "ListObjectsV2 skipped (\(skipped)) · ListBuckets 200 (req REQ-BUCKETS)")
    }

    // MARK: - The step's outcome

    /// The same rule the dials follow: a row is `ok` when the server ANSWERED,
    /// whatever it answered. A 403 to `ListBuckets` is the finding, not a
    /// failure of the check.
    @Test func aServerThatAnsweredMakesTheStepOKWhateverItAnswered() async {
        let transport = FakeS3Transport(responses: [
            Self.reply(403), Self.reply(403), Self.reply(403),
        ])

        let results = await S3AccessProbe(config: Self.config, transport: transport).run()

        #expect(S3AccessProbe.outcome(of: results) == .ok)
    }

    @Test func aTransportThatNeverReachedTheServerFailsTheStep() async {
        let results = await S3AccessProbe(
            config: Self.config, transport: ThrowingS3Transport()
        ).run()

        guard case .failed(let reason) = S3AccessProbe.outcome(of: results) else {
            Issue.record("a probe that reached nothing must fail the step")
            return
        }
        #expect(!reason.isEmpty)
        // The positive anchor: the line still names all three calls, so the
        // failure above is a verdict about the server rather than an empty row.
        #expect(S3AccessProbe.detail(results).contains("HeadBucket"))
        #expect(S3AccessProbe.detail(results).contains("ListBuckets"))
    }

    @Test func theProbeNeverWritesTheSecretIntoItsLine() async {
        let secret = Self.secretUnderTest
        var config = Self.config
        config.secretAccessKey = secret
        let transport = FakeS3Transport(responses: [
            Self.reply(200), Self.reply(200), Self.reply(200),
        ])

        let results = await S3AccessProbe(config: config, transport: transport).run()

        let detail = S3AccessProbe.detail(results)
        let leaks = detail.contains(secret)
        #expect(leaks == false)
        #expect(detail.contains("HeadBucket 200"))
    }

    /// The vector the substituted-secret test above cannot reach: a
    /// credential typed into the ENDPOINT field, which is ordinary input no
    /// schema here strips.
    ///
    /// Such an endpoint is not a usable URL, and the errors that say so
    /// interpolate it (`S3FileSystem`'s "Invalid S3 endpoint: …",
    /// `S3RequestSigning`'s "S3 endpoint has no host: …"). Printing those
    /// through `DialSupport.reason(for:)` would hand the row to
    /// `URLText.withoutUserinfo`, whose documented limit is exactly this
    /// shape: a password containing `/` ends the authority scan before the
    /// `@`, so `USER:pa` survives into a report written to be pasted in
    /// public (`DiagnosticStep.swift`, the `withoutUserinfo` doc comment).
    @Test func aCredentialTypedIntoTheEndpointNeverReachesTheRow() async throws {
        let user = Self.endpointUserinfoUser
        let password = Self.endpointUserinfoPassword
        let beforeTheSlash = String(password.prefix(while: { $0 != "/" }))
        var values = FieldValues()
        values[S3Field.endpoint] = "https://\(user):\(password)@127.0.0.1:9000"
        values[S3Field.region] = "us-east-1"
        values[S3Field.bucket] = "macscp-seed"
        values[S3Field.accessKeyID] = user

        let contribution = try #require(BackendDescriptor.descriptor(for: .s3).diagnostics.first)
        let step = await contribution.run(
            values,
            DiagnosticContext(
                secrets: FixedS3Secret(value: password), sessionID: UUID(),
                timeout: .seconds(2)))

        let printed = step.detail + " " + step.outcome.label
        let leaksPassword = printed.contains(password)
        let leaksAuthorityPrefix = printed.contains("\(user):\(beforeTheSlash)")
        let leaksUser = printed.contains(user)
        #expect(leaksPassword == false)
        #expect(leaksAuthorityPrefix == false)
        #expect(leaksUser == false)
        // The positive anchor: the row was measured and still names all three
        // calls, so the three checks above are not reading an empty step.
        #expect(step.detail.contains("HeadBucket"))
        #expect(step.detail.contains("ListObjectsV2"))
        #expect(step.detail.contains("ListBuckets"))
    }

    // MARK: - Against the rig's MinIO

    private static func rigConfig(
        accessKeyID: String, secretAccessKey: String, bucket: String
    ) -> S3ConnectionConfig {
        S3ConnectionConfig(
            accessKeyID: accessKeyID, secretAccessKey: secretAccessKey,
            region: "us-east-1", endpoint: "http://127.0.0.1:19000",
            bucket: bucket, usePathStyle: true, sessionToken: nil)
    }

    private static func runAgainstRig(_ config: S3ConnectionConfig) async -> [S3AccessResult] {
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        return await S3AccessProbe(
            config: config, transport: URLSessionHTTPTransport(session: session)
        ).run()
    }

    private static func status(of results: [S3AccessResult], _ call: S3AccessCall) -> Int? {
        guard case .answered(let status, _)? = results.first(where: { $0.call == call })?.answer
        else { return nil }
        return status
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["MACSCP_ITEST"] == "1"))
    func theRootKeyMayDoAllThree() async throws {
        let results = await Self.runAgainstRig(
            Self.rigConfig(
                accessKeyID: "macscp", secretAccessKey: "macscpsecretkey",
                bucket: "macscp-seed"))

        #expect(Self.status(of: results, .headBucket) == 200)
        #expect(Self.status(of: results, .listObjectsV2) == 200)
        #expect(Self.status(of: results, .listBuckets) == 200)
        // MinIO sends a request id on every one of them, and the line carries
        // it — that id is what a provider is asked to look up.
        #expect(S3AccessProbe.detail(results).contains("(req "))
    }

    /// The rig's scoped key is granted the seed bucket only, and its policy
    /// deliberately omits `s3:ListAllMyBuckets`. Measured against this MinIO
    /// release on 2026-09-02: the account listing is NOT refused — MinIO
    /// answers 200 with the FILTERED list. This asserts what the rig does,
    /// not what AWS would do.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MACSCP_ITEST"] == "1"))
    func theScopedKeyGetsAFilteredBucketListRatherThanARefusal() async throws {
        let results = await Self.runAgainstRig(
            Self.rigConfig(
                accessKeyID: "macscp-scoped", secretAccessKey: "macscpscopedsecret",
                bucket: "macscp-seed"))

        #expect(Self.status(of: results, .headBucket) == 200)
        #expect(Self.status(of: results, .listObjectsV2) == 200)
        #expect(Self.status(of: results, .listBuckets) == 200)
    }

    /// The refusal the same key DOES get: a bucket its policy does not name.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MACSCP_ITEST"] == "1"))
    func theScopedKeyIsRefusedTheBucketItsPolicyDoesNotName() async throws {
        let results = await Self.runAgainstRig(
            Self.rigConfig(
                accessKeyID: "macscp-scoped", secretAccessKey: "macscpscopedsecret",
                bucket: "macscp-second"))

        #expect(Self.status(of: results, .headBucket) == 403)
        #expect(Self.status(of: results, .listObjectsV2) == 403)
        #expect(Self.status(of: results, .listBuckets) == 200)
    }

    /// The whole seam, end to end: the descriptor carries the contribution,
    /// the contribution resolves the secret through the same source the
    /// connect uses, and the row it returns is the one the panel renders.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MACSCP_ITEST"] == "1"))
    func theDescriptorsContributionMeasuresTheKeyAgainstTheRig() async throws {
        var values = FieldValues()
        values[S3Field.endpoint] = "http://127.0.0.1:19000"
        values[S3Field.region] = "us-east-1"
        values[S3Field.bucket] = "macscp-seed"
        values[S3Field.accessKeyID] = "macscp"
        values[S3Field.usePathStyle] = "true"

        let descriptor = BackendDescriptor.descriptor(for: .s3)
        let contribution = try #require(descriptor.diagnostics.first)
        let step = await contribution.run(
            values,
            DiagnosticContext(
                secrets: FixedS3Secret(value: "macscpsecretkey"), sessionID: UUID(),
                timeout: .seconds(10)))

        #expect(step.id == contribution.id)
        #expect(step.titleKey == contribution.titleKey)
        #expect(step.outcome == .ok)
        #expect(step.detail.contains("HeadBucket 200"))
        #expect(step.detail.contains("ListBuckets 200"))
    }

    /// Without a secret there is nothing to sign with, and the row says so
    /// rather than measuring an unsigned request.
    @Test func theContributionSkipsWhenNoSecretIsAvailable() async throws {
        var values = FieldValues()
        values[S3Field.endpoint] = "http://127.0.0.1:19000"
        values[S3Field.region] = "us-east-1"
        values[S3Field.bucket] = "macscp-seed"
        values[S3Field.accessKeyID] = "macscp"

        let contribution = try #require(BackendDescriptor.descriptor(for: .s3).diagnostics.first)
        let step = await contribution.run(
            values, DiagnosticContext(secrets: nil, sessionID: nil, timeout: .seconds(5)))

        #expect(step.outcome == .skipped(DiagnosticReason.noSecret))
    }
}

/// A `SecretSource` that answers the same value for any session — the seam
/// the contribution resolves through, without a keychain.
private struct FixedS3Secret: SecretSource {
    let value: String
    var label: String { "fixed" }
    func secret(for sessionID: UUID) throws -> String? { value }
}
