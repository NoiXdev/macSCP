import Foundation
import Testing
@testable import macSCPCore

/// Runs only with MACSCP_ITEST=1 and the Docker S3 rig up
/// (`docker compose -f docker/test-server/compose.yml up -d`).
///
/// Creates and deletes its OWN throwaway bucket; the rig's seeded buckets
/// and `macscp-probe-lock` are never named here.
///
/// What this CANNOT show is that macSCP refuses a bad method: the rig stores
/// `FETCH` and reads it back (measured 2026-10-19). That refusal is pinned in
/// `S3CORSTests`, before the transport. The `FETCH` step below only confirms
/// the refusal also holds with a live store on the other end, and that
/// nothing was stored.
@Suite(
    "S3 bucket CORS against the Docker S3 rig",
    .enabled(if: ProcessInfo.processInfo.environment["MACSCP_ITEST"] == "1"),
    .serialized
)
struct S3CORSGatedTests {
    @Test func theFullSchemaRoundTripsAndAFetchRuleNeverReachesTheStore() async throws {
        let fs = try await S3FileSystem.connect(S3SettingsRig.config)
        defer { Task { await fs.disconnect() } }
        let bucket = S3SettingsRig.throwawayBucketName(purpose: "cors")
        let created = try await S3SettingsRig.bucketRequest("PUT", bucket, in: fs)
        #expect((200..<300).contains(created))
        guard (200..<300).contains(created) else { return }

        let rule = CORSRule(
            id: "rule-one",
            allowedOrigins: ["https://a.example.com", "https://b.example.com"],
            allowedMethods: ["GET", "PUT"],
            allowedHeaders: ["x-amz-meta-foo"],
            exposeHeaders: ["ETag", "x-amz-version-id"],
            maxAgeSeconds: 3600)
        let fetch = CORSRule(
            id: "fetch", allowedOrigins: ["*"], allowedMethods: ["FETCH"],
            allowedHeaders: [], exposeHeaders: [], maxAgeSeconds: nil)

        var before: [CORSRule]?
        var after: [CORSRule]?
        var afterRefusal: [CORSRule]?
        var refusal: (any Error)?
        var failure: (any Error)?
        do {
            before = try await fs.cors(ofBucket: bucket)
            try await fs.setCORS([rule], ofBucket: bucket)
            after = try await fs.cors(ofBucket: bucket)
            do {
                try await fs.setCORS([fetch], ofBucket: bucket)
            } catch {
                refusal = error
            }
            afterRefusal = try await fs.cors(ofBucket: bucket)
        } catch {
            failure = error
        }

        // Cleanup runs whether or not the round trip got to its end.
        let deleted = try? await S3SettingsRig.bucketRequest("DELETE", bucket, in: fs)

        #expect(failure == nil)
        // A bucket nothing was written to has no configuration at all.
        #expect(before == nil)
        #expect(after == [rule])
        // The refusal is macSCP's, and the stored configuration is untouched.
        if case .protocolError? = (refusal as? RemoteFSError) {
        } else {
            Issue.record("expected the FETCH rule to be refused locally, got \(String(describing: refusal))")
        }
        #expect(afterRefusal == [rule])
        #expect(deleted.map { (200..<300).contains($0) } == true)
    }
}
