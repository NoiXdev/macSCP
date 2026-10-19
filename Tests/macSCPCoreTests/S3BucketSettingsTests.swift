import Foundation
import Testing
@testable import macSCPCore

/// `S3FileSystem`'s `S3BucketSettings` conformance, against the canned
/// transport: the request each call signs and how each answer is mapped.
/// No network; the rig half is `S3BucketSettingsGatedTests`.
@Suite("S3FileSystem bucket settings")
struct S3BucketSettingsTests {
    @Test func theConnectionIsOfferedTheCapabilityThroughAnOptionalCast() async throws {
        let (fs, _) = try await S3SettingsFake.connect(responses: [])
        let backend: any RemoteFileSystem = fs
        #expect((backend as? any S3BucketSettings) != nil)
    }

    @Test func versioningIsAGetOnTheNamedBucketsVersioningSubresource() async throws {
        let body = Data("<VersioningConfiguration><Status>Enabled</Status></VersioningConfiguration>".utf8)
        let (fs, transport) = try await S3SettingsFake.connect(responses: [(body, S3SettingsFake.httpResponse(status: 200))])
        let state = try await fs.versioning(ofBucket: "other")
        #expect(state == .enabled)
        let sent = try #require(await transport.requests.last)
        #expect(sent.httpMethod == "GET")
        #expect(sent.url?.path == "/other")
        #expect(sent.url?.query == "versioning=")
    }

    @Test func settingAStateIsAPutOfItsBodyWithTheBodysHash() async throws {
        let (fs, transport) = try await S3SettingsFake.connect(responses: [(Data(), S3SettingsFake.httpResponse(status: 200))])
        try await fs.setVersioning(.suspended, ofBucket: "other")
        let sent = try #require(await transport.requests.last)
        #expect(sent.httpMethod == "PUT")
        #expect(sent.url?.path == "/other")
        #expect(sent.url?.query == "versioning=")
        let body = try #require(sent.httpBody)
        #expect(String(data: body, encoding: .utf8)?.contains("<Status>Suspended</Status>") == true)
        #expect(
            sent.value(forHTTPHeaderField: "x-amz-content-sha256") == SigV4Signer.hexSHA256(body))
    }

    /// AWS marks `Content-MD5` REQUIRED for `PutBucketVersioning`
    /// (https://docs.aws.amazon.com/AmazonS3/latest/API/API_PutBucketVersioning.html),
    /// and the SDKs that compute it for a caller are not in the path here.
    /// The rig accepts the request without it, so a gated round trip proves
    /// nothing about the header; this asserts that macSCP SENDS it, and that
    /// it is a SIGNED header. The expected values are literals, the base64
    /// MD5 of each exact body, not a call to the code that computes them.
    @Test(arguments: [
        (BucketVersioning.enabled, "IjhtHf5gnkMYmEeiwoaHWg=="),
        (BucketVersioning.suspended, "zsURZSA06S13UA4zV6WnyQ=="),
    ])
    func settingAStateSendsASignedContentMD5OfItsBody(
        state: BucketVersioning, expectedMD5: String
    ) async throws {
        let (fs, transport) = try await S3SettingsFake.connect(responses: [(Data(), S3SettingsFake.httpResponse(status: 200))])
        try await fs.setVersioning(state, ofBucket: "other")
        let sent = try #require(await transport.requests.last)
        #expect(sent.value(forHTTPHeaderField: "Content-MD5") == expectedMD5)
        let authorization = try #require(sent.value(forHTTPHeaderField: "Authorization"))
        #expect(authorization.lowercased().contains("content-md5"))
    }

    @Test func settingNeverSendsNothing() async throws {
        let (fs, transport) = try await S3SettingsFake.connect(responses: [])
        let before = await transport.requests.count
        await #expect(throws: RemoteFSError.self) {
            try await fs.setVersioning(.never, ofBucket: "other")
        }
        #expect(await transport.requests.count == before)
    }

    @Test func aNonSuccessAnswerIsMappedThroughTheSharedStatusMapping() async throws {
        let (fs, _) = try await S3SettingsFake.connect(responses: [(Data(), S3SettingsFake.httpResponse(status: 403))])
        do {
            _ = try await fs.versioning(ofBucket: "other")
            Issue.record("a 403 returned a state")
        } catch {
            #expect((error as? RemoteFSError) == .authenticationFailed)
        }
    }

    @Test func aNamedRefusalInTheBodyBecomesItsFinding() async throws {
        let body = Data(
            "<Error><Code>NotImplemented</Code><Message>no</Message></Error>".utf8)
        let (fs, _) = try await S3SettingsFake.connect(responses: [(body, S3SettingsFake.httpResponse(status: 501))])
        do {
            try await fs.setVersioning(.enabled, ofBucket: "other")
            Issue.record("a 501 was reported as success")
        } catch {
            #expect((error as? RemoteFSError) == .finding(.operationNotSupported))
        }
    }
}
