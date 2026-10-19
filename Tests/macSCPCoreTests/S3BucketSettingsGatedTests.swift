import Foundation
import Testing
@testable import macSCPCore

/// Runs only with MACSCP_ITEST=1 and the Docker S3 rig up
/// (`docker compose -f docker/test-server/compose.yml up -d`).
///
/// Creates and deletes its OWN throwaway bucket; the rig's seeded buckets
/// (`macscp-seed`, `macscp-second`) and `macscp-probe-lock` are never named
/// here. There is no `createBucket` on the capability yet (a later task adds
/// it), so the bucket is made and removed with raw signed requests.
@Suite(
    "S3BucketSettings against the Docker S3 rig",
    .enabled(if: ProcessInfo.processInfo.environment["MACSCP_ITEST"] == "1"),
    .serialized
)
struct S3BucketSettingsGatedTests {
    private static let config = S3ConnectionConfig(
        accessKeyID: "macscp", secretAccessKey: "macscpsecretkey",
        region: "us-east-1", endpoint: "http://127.0.0.1:19000",
        bucket: "macscp-seed", usePathStyle: true, sessionToken: nil)

    private func bucketRequest(_ method: String, _ bucket: String, in fs: S3FileSystem) async throws -> Int {
        let request = try S3FileSystem.signedRequest(
            .bucketRoot(bucket: bucket), method: method, config: Self.config)
        return try await fs.perform(request).1.statusCode
    }

    @Test func versioningRoundTripsThroughTheStore() async throws {
        let fs = try await S3FileSystem.connect(Self.config)
        defer { Task { await fs.disconnect() } }
        let bucket = "macscp-versioning-\(UUID().uuidString.lowercased().prefix(12))"
        let created = try await bucketRequest("PUT", bucket, in: fs)
        #expect((200..<300).contains(created))
        guard (200..<300).contains(created) else { return }

        var observed: [BucketVersioning] = []
        var failure: (any Error)?
        do {
            observed.append(try await fs.versioning(ofBucket: bucket))
            try await fs.setVersioning(.enabled, ofBucket: bucket)
            observed.append(try await fs.versioning(ofBucket: bucket))
            try await fs.setVersioning(.suspended, ofBucket: bucket)
            observed.append(try await fs.versioning(ofBucket: bucket))
        } catch {
            failure = error
        }

        // Cleanup runs whether or not the round trip got to its end.
        let deleted = try? await bucketRequest("DELETE", bucket, in: fs)

        #expect(failure == nil)
        #expect(observed == [.never, .enabled, .suspended])
        #expect(deleted.map { (200..<300).contains($0) } == true)
    }
}
