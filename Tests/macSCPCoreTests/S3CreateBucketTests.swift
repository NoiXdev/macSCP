import Foundation
import Testing
@testable import macSCPCore

/// `createBucket(_:protection:)` on `S3FileSystem`, against the
/// canned transport: which requests go out, in which order, with what, and
/// which calls send nothing at all. No network; the rig half is
/// `S3CreateBucketGatedTests`.
@Suite("S3 create bucket")
struct S3CreateBucketTests {
    private static func ok() -> (Data, HTTPURLResponse) {
        (Data(), S3SettingsFake.httpResponse(status: 200))
    }

    /// The reason of the `.protocolError` a call throws, or a description of
    /// whatever else it threw (or `nil` when it threw nothing).
    private static func protocolReason(of work: () async throws -> Void) async -> String? {
        do {
            try await work()
            return nil
        } catch RemoteFSError.protocolError(let reason) {
            return reason
        } catch {
            return "unexpected: \(error)"
        }
    }

    // MARK: - Nothing is sent

    @Test(arguments: ["ab", "My-Bucket", "my_bucket", "192.168.0.1", "-leading", "trailing-"])
    func aNameThatFailsTheCheckSendsNothing(name: String) async throws {
        let (fs, transport) = try await S3SettingsFake.connect(responses: [])
        let before = await transport.requests.count
        let reason = await Self.protocolReason {
            try await fs.createBucket(name, protection: .lockedAndVersioned)
        }
        let problem = try #require(S3BucketName.problem(with: name))
        #expect(reason?.contains("\(problem)") == true, "\(String(describing: reason))")
        #expect(await transport.requests.count == before)
    }

    // MARK: - What goes out

    @Test func aPlainBucketIsOneBodylessPutOnTheBucketRoot() async throws {
        let (fs, transport) = try await S3SettingsFake.connect(responses: [Self.ok()])
        try await fs.createBucket("fresh-bucket", protection: .none)
        let requests = Array(await transport.requests.dropFirst())  // connect's probe
        #expect(requests.count == 1)
        let sent = try #require(requests.first)
        #expect(sent.httpMethod == "PUT")
        #expect(sent.url?.path == "/fresh-bucket")
        // No subresource. (The URL builder leaves a bare `?` on a bucket
        // root with no query, so "no query" is an empty one.)
        #expect((sent.url?.query ?? "").isEmpty)
        #expect(sent.value(forHTTPHeaderField: "x-amz-bucket-object-lock-enabled") == nil)
        #expect(sent.httpBody == nil || sent.httpBody?.isEmpty == true)
    }

    @Test func versioningIsASecondRequestAfterTheCreate() async throws {
        let (fs, transport) = try await S3SettingsFake.connect(responses: [Self.ok(), Self.ok()])
        try await fs.createBucket("fresh-bucket", protection: .versioned)
        let requests = Array(await transport.requests.dropFirst())
        try #require(requests.count == 2)
        #expect(requests[0].httpMethod == "PUT")
        #expect((requests[0].url?.query ?? "").isEmpty)
        #expect(requests[0].value(forHTTPHeaderField: "x-amz-bucket-object-lock-enabled") == nil)
        #expect(requests[1].httpMethod == "PUT")
        #expect(requests[1].url?.path == "/fresh-bucket")
        #expect(requests[1].url?.query == "versioning=")
        let body = try #require(requests[1].httpBody)
        #expect(String(data: body, encoding: .utf8)?.contains("<Status>Enabled</Status>") == true)
        // The existing `setVersioning` is what sent it, digest included.
        #expect(requests[1].value(forHTTPHeaderField: "Content-MD5") == "IjhtHf5gnkMYmEeiwoaHWg==")
    }

    @Test func objectLockRidesOnTheCreateAsASignedHeaderAndVersioningFollows() async throws {
        let (fs, transport) = try await S3SettingsFake.connect(responses: [Self.ok(), Self.ok()])
        try await fs.createBucket("fresh-bucket", protection: .lockedAndVersioned)
        let requests = Array(await transport.requests.dropFirst())
        try #require(requests.count == 2)
        let create = requests[0]
        #expect(create.httpMethod == "PUT")
        #expect(create.url?.path == "/fresh-bucket")
        #expect((create.url?.query ?? "").isEmpty)
        #expect(create.value(forHTTPHeaderField: "x-amz-bucket-object-lock-enabled") == "true")
        let authorization = try #require(create.value(forHTTPHeaderField: "Authorization"))
        #expect(authorization.contains("x-amz-bucket-object-lock-enabled"))
        // The store is not left to enable versioning on its own.
        #expect(requests[1].url?.query == "versioning=")
        let body = try #require(requests[1].httpBody)
        #expect(String(data: body, encoding: .utf8)?.contains("<Status>Enabled</Status>") == true)
    }

    /// `CreateBucket` outside `us-east-1` names the region in a
    /// `LocationConstraint` (see `S3SettingsXML.createBucketBody`). Pinned
    /// here and not measured against a store, because the rig is
    /// `us-east-1`.
    @Test func aRegionOtherThanUsEast1IsNamedInALocationConstraint() async throws {
        let config = S3ConnectionConfig(
            accessKeyID: "AK", secretAccessKey: "SK", region: "eu-central-1",
            endpoint: "http://127.0.0.1:9000", bucket: "macscp-seed",
            usePathStyle: true, sessionToken: nil)
        let transport = FakeS3Transport(responses: [
            (Data(S3SettingsFake.emptyListingXML.utf8), S3SettingsFake.httpResponse(status: 200)),
            Self.ok(),
        ])
        let fs = try await S3FileSystem.connect(config, transport: transport)
        try await fs.createBucket("fresh-bucket", protection: .none)
        let sent = try #require(await transport.requests.last)
        let body = try #require(sent.httpBody)
        let text = try #require(String(data: body, encoding: .utf8))
        #expect(text.contains("<LocationConstraint>eu-central-1</LocationConstraint>"))
        #expect(sent.value(forHTTPHeaderField: "x-amz-content-sha256") == SigV4Signer.hexSHA256(body))
    }

    // MARK: - Failures

    /// The two refusals a create is most likely to meet: the name is taken
    /// by someone else, or by this very account. Each keeps its own finding
    /// instead of "the server answered with status 409", and no versioning
    /// request follows a refused create.
    @Test(arguments: [
        ("BucketAlreadyExists", RemoteFSFinding.bucketNameTaken),
        ("BucketAlreadyOwnedByYou", RemoteFSFinding.bucketAlreadyOwnedByYou),
    ])
    func aRefusedCreateIsMappedToItsOwnFindingAndNoVersioningRequestFollows(
        code: String, expected: RemoteFSFinding
    ) async throws {
        let conflict = Data("<Error><Code>\(code)</Code></Error>".utf8)
        let (fs, transport) = try await S3SettingsFake.connect(responses: [
            (conflict, S3SettingsFake.httpResponse(status: 409))
        ])
        do {
            try await fs.createBucket("fresh-bucket", protection: .lockedAndVersioned)
            Issue.record("a 409 was reported as success")
        } catch {
            #expect((error as? RemoteFSError) == .finding(expected))
        }
        #expect(await transport.requests.count == 2)  // the probe, and the create
    }

    /// The control for the pair above: a 409 whose code is not one of the two
    /// is still the generic mapping, so the named findings are chosen by the
    /// code and not by the status.
    @Test func aConflictWithAnotherCodeKeepsTheGenericMapping() async throws {
        let conflict = Data("<Error><Code>OperationAborted</Code></Error>".utf8)
        let (fs, _) = try await S3SettingsFake.connect(responses: [
            (conflict, S3SettingsFake.httpResponse(status: 409))
        ])
        do {
            try await fs.createBucket("fresh-bucket", protection: .none)
            Issue.record("a 409 was reported as success")
        } catch {
            #expect((error as? RemoteFSError) == .finding(.unexpectedStatus(code: 409)))
        }
    }

    /// The create has succeeded by the time the versioning request fails, so
    /// the bucket exists. The error is the versioning request's own, not a
    /// success and not a rollback: a caller that sees it knows the bucket is
    /// there and can retry `setVersioning`.
    @Test func aFailedVersioningRequestAfterTheCreateIsReportedAsItself() async throws {
        let (fs, transport) = try await S3SettingsFake.connect(responses: [
            Self.ok(), (Data(), S3SettingsFake.httpResponse(status: 403)),
        ])
        do {
            try await fs.createBucket("fresh-bucket", protection: .versioned)
            Issue.record("a 403 was reported as success")
        } catch {
            #expect((error as? RemoteFSError) == .authenticationFailed)
        }
        #expect(await transport.requests.count == 3)  // the probe, the create, the versioning
    }
}
