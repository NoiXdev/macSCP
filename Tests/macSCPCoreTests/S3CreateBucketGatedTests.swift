import Foundation
import Testing

@testable import macSCPCore

/// Runs only with MACSCP_ITEST=1 and the Docker S3 rig up
/// (`docker compose -f docker/test-server/compose.yml up -d`).
///
/// Creates and deletes its OWN throwaway buckets, through `createBucket`
/// itself and raw signed requests for the removal; the rig's seeded buckets
/// (`macscp-seed`, `macscp-second`) and `macscp-probe-lock` are never named
/// here. Nothing is written into any bucket, so a lock-enabled bucket made
/// here has no locked object and stays deletable.
///
/// What the rig CANNOT show: that the request carries the right header and
/// order (`S3CreateBucketTests` pins them), and the `LocationConstraint` a
/// region other than `us-east-1` needs (the rig is `us-east-1`).
@Suite(
    "S3 create bucket against the Docker S3 rig",
    .enabled(if: ProcessInfo.processInfo.environment["MACSCP_ITEST"] == "1"),
    .serialized
)
struct S3CreateBucketGatedTests {
    /// What the store reports about a bucket this suite made.
    private struct Observed {
        var versioning: BucketVersioning?
        var hasObjectLock: Bool?
        var defaultRetention: Bool?
    }

    /// Creates `bucket` with the given switches, reads it back, and removes
    /// it whether or not the reads succeeded.
    private func createReadAndRemove(
        versioning: Bool, objectLock: Bool, purpose: String
    ) async throws -> (observed: Observed, failure: (any Error)?, deleted: Int?) {
        let fs = try await S3FileSystem.connect(S3SettingsRig.config)
        defer { Task { await fs.disconnect() } }
        let bucket = S3SettingsRig.throwawayBucketName(purpose: purpose)
        var observed = Observed()
        var failure: (any Error)?
        do {
            try await fs.createBucket(bucket, versioning: versioning, objectLock: objectLock)
            observed.versioning = try await fs.versioning(ofBucket: bucket)
            observed.hasObjectLock = try await fs.hasObjectLock(ofBucket: bucket)
            observed.defaultRetention = try await fs.objectLockDefault(ofBucket: bucket) != nil
        } catch {
            failure = error
        }
        // Cleanup runs whether or not the reads got to their end. A bucket
        // that was never created answers 404, which is reported as such.
        let deleted = try? await S3SettingsRig.bucketRequest("DELETE", bucket, in: fs)
        return (observed, failure, deleted)
    }

    @Test func bothSwitchesGiveAVersionedBucketWithObjectLock() async throws {
        let result = try await createReadAndRemove(
            versioning: true, objectLock: true, purpose: "create-both")
        #expect(result.failure == nil)
        #expect(result.observed.versioning == .enabled)
        #expect(result.observed.hasObjectLock == true)
        // Object Lock without a default retention: nothing locks until a
        // retention is set.
        #expect(result.observed.defaultRetention == false)
        #expect(result.deleted.map { (200..<300).contains($0) } == true)
    }

    @Test func versioningAloneGivesAVersionedBucketWithoutObjectLock() async throws {
        let result = try await createReadAndRemove(
            versioning: true, objectLock: false, purpose: "create-versioned")
        #expect(result.failure == nil)
        #expect(result.observed.versioning == .enabled)
        #expect(result.observed.hasObjectLock == false)
        #expect(result.deleted.map { (200..<300).contains($0) } == true)
    }

    @Test func neitherSwitchGivesAPlainBucket() async throws {
        let result = try await createReadAndRemove(
            versioning: false, objectLock: false, purpose: "create-plain")
        #expect(result.failure == nil)
        #expect(result.observed.versioning == BucketVersioning.never)
        #expect(result.observed.hasObjectLock == false)
        #expect(result.deleted.map { (200..<300).contains($0) } == true)
    }

    /// What the rig does with a second create of a bucket this key already
    /// owns, asked for with BOTH switches on a bucket made with neither
    /// (measured 2026-10-19): the create is ANSWERED WITH SUCCESS, the
    /// `x-amz-bucket-object-lock-enabled` header does NOT turn Object Lock on
    /// for the existing bucket, and the versioning request that follows DOES
    /// take effect. So `createBucket` on a name that exists is not an error
    /// here and is not a way to retrofit a lock, but it is a way to switch
    /// versioning on; a caller that means "a new bucket" checks that the
    /// name is free first. This is the RIG's answer: AWS answers a re-create
    /// differently by region (unmeasured here), and nothing in the call
    /// depends on either.
    @Test func recreatingABucketTheKeyOwnsDoesNotEnableObjectLockButDoesEnableVersioning() async throws {
        let fs = try await S3FileSystem.connect(S3SettingsRig.config)
        defer { Task { await fs.disconnect() } }
        let bucket = S3SettingsRig.throwawayBucketName(purpose: "create-twice")
        var second: (any Error)?
        var after: (versioning: BucketVersioning, hasLock: Bool)?
        var failure: (any Error)?
        do {
            try await fs.createBucket(bucket, versioning: false, objectLock: false)
            do {
                try await fs.createBucket(bucket, versioning: true, objectLock: true)
            } catch {
                second = error
            }
            after = (
                try await fs.versioning(ofBucket: bucket),
                try await fs.hasObjectLock(ofBucket: bucket)
            )
        } catch {
            failure = error
        }
        let deleted = try? await S3SettingsRig.bucketRequest("DELETE", bucket, in: fs)
        #expect(failure == nil)
        #expect(second == nil)
        #expect(after?.hasLock == false, "the header turned Object Lock on for an existing bucket")
        #expect(after?.versioning == .enabled)
        #expect(deleted.map { (200..<300).contains($0) } == true)
    }
}
