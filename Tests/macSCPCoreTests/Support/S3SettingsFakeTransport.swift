import Foundation
@testable import macSCPCore

/// The set-up the bucket-settings suites share: a path-style connection
/// config, a canned response, and a `connect` that answers the probe
/// `S3FileSystem.connect` sends first so a test's own responses start at its
/// first real request. Lives here so that `S3BucketSettingsTests` and
/// `S3CORSTests` (and the settings suites that follow) do not each carry a
/// copy; `FakeS3Transport` itself is at the top of `S3FileSystemTests.swift`.
enum S3SettingsFake {
    static let config = S3ConnectionConfig(
        accessKeyID: "AK", secretAccessKey: "SK", region: "us-east-1",
        endpoint: "http://127.0.0.1:9000", bucket: "macscp-seed",
        usePathStyle: true, sessionToken: nil)

    /// An empty-but-valid ListObjectsV2 answer: what `connect`'s probe gets.
    static let emptyListingXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
            <IsTruncated>false</IsTruncated>
        </ListBucketResult>
        """

    static func httpResponse(status: Int) -> HTTPURLResponse {
        HTTPURLResponse(
            url: URL(string: "http://127.0.0.1:9000/other")!,
            statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
    }

    static func connect(responses: [(Data, HTTPURLResponse)]) async throws -> (S3FileSystem, FakeS3Transport) {
        let transport = FakeS3Transport(
            responses: [(Data(emptyListingXML.utf8), httpResponse(status: 200))] + responses)
        let fs = try await S3FileSystem.connect(config, transport: transport)
        return (fs, transport)
    }
}

/// The set-up the GATED bucket-settings suites share (`MACSCP_ITEST=1`, the
/// Docker S3 rig): the rig's connection config, and the raw signed
/// bucket-level request a suite uses to create and delete its OWN throwaway
/// bucket — there is no `createBucket` on the capability yet. The rig's
/// seeded buckets (`macscp-seed`, `macscp-second`) and `macscp-probe-lock`
/// are never named by a suite built on this.
enum S3SettingsRig {
    static let config = S3ConnectionConfig(
        accessKeyID: "macscp", secretAccessKey: "macscpsecretkey",
        region: "us-east-1", endpoint: "http://127.0.0.1:19000",
        bucket: "macscp-seed", usePathStyle: true, sessionToken: nil)

    /// A fresh bucket name, `macscp-<purpose>-<12 hex>`.
    static func throwawayBucketName(purpose: String) -> String {
        "macscp-\(purpose)-\(UUID().uuidString.lowercased().prefix(12))"
    }

    /// `method` (`PUT` creates, `DELETE` removes) on the bucket root; the
    /// HTTP status. `extraHeaders` are signed with the request: creating a
    /// bucket WITH Object Lock is a `PUT` carrying
    /// `x-amz-bucket-object-lock-enabled: true`.
    static func bucketRequest(
        _ method: String, _ bucket: String, extraHeaders: [String: String] = [:],
        in fs: S3FileSystem
    ) async throws -> Int {
        let request = try S3FileSystem.signedRequest(
            .bucketRoot(bucket: bucket), method: method, extraHeaders: extraHeaders,
            config: config)
        return try await fs.perform(request).1.statusCode
    }

    /// A raw signed request on one object, for what the capability does not
    /// offer: writing an object, and a `DELETE` that names a version (this
    /// half of the work sends none itself). Returns the whole answer.
    static func objectRequest(
        _ method: String, bucket: String, key: String,
        query: [(name: String, value: String)] = [],
        extraHeaders: [String: String] = [:], body: Data? = nil, in fs: S3FileSystem
    ) async throws -> (Data, HTTPURLResponse) {
        let request = try S3FileSystem.signedRequest(
            .objectKey(bucket: bucket, key: key), method: method, query: query,
            extraHeaders: extraHeaders, body: body,
            payloadHash: body.map { SigV4Signer.hexSHA256($0) } ?? SigV4Signer.emptyPayloadHash,
            config: config)
        return try await fs.perform(request)
    }
}
