import Foundation
import Testing
@testable import macSCPCore

/// Runs only with MACSCP_ITEST=1 and the Docker S3 rig up
/// (`docker compose -f docker/test-server/compose.yml up -d`).
///
/// Creates and deletes its OWN throwaway bucket; the rig's seeded buckets
/// (`macscp-seed`, `macscp-second`) and `macscp-probe-lock` are never named
/// here. The bucket is made and removed with raw signed requests, so that
/// this suite's set-up does not depend on `createBucket`, which
/// `S3CreateBucketGatedTests` exercises.
@Suite(
    "S3BucketSettings against the Docker S3 rig",
    .enabled(if: ProcessInfo.processInfo.environment["MACSCP_ITEST"] == "1"),
    .serialized
)
struct S3BucketSettingsGatedTests {
    @Test func versioningRoundTripsThroughTheStore() async throws {
        let fs = try await S3FileSystem.connect(S3SettingsRig.config)
        defer { Task { await fs.disconnect() } }
        let bucket = S3SettingsRig.throwawayBucketName(purpose: "versioning")
        let created = try await S3SettingsRig.bucketRequest("PUT", bucket, in: fs)
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
        let deleted = try? await S3SettingsRig.bucketRequest("DELETE", bucket, in: fs)

        #expect(failure == nil)
        #expect(observed == [.never, .enabled, .suspended])
        #expect(deleted.map { (200..<300).contains($0) } == true)
    }
}
