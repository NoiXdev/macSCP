import Foundation
import Testing

@testable import macSCPCore

/// Runs only with MACSCP_ITEST=1 and the Docker S3 rig up
/// (`docker compose -f docker/test-server/compose.yml up -d`).
///
/// Creates and deletes its OWN throwaway buckets; the rig's seeded buckets
/// (`macscp-seed`, `macscp-second`) and `macscp-probe-lock` (a COMPLIANCE
/// retention that cannot be removed before 2026-12-31) are never named here.
///
/// **No COMPLIANCE retention is ever set against the rig.** A locked object
/// in a bucket that cannot be emptied strands the bucket until its date; the
/// COMPLIANCE wire format is pinned in `S3ObjectLockTests` instead, where
/// nothing is stored. Everything locked here is GOVERNANCE or a legal hold,
/// and the cleanup lifts the hold and deletes with the governance bypass.
///
/// What the rig CANNOT show: that macSCP sends a `Content-MD5` on
/// `PUT ?object-lock` (the rig does not require it; `S3ObjectLockTests`
/// pins the request), and that Object Lock cannot be switched on for an
/// existing bucket (the rig allows it; the first test below shows macSCP
/// refusing it anyway).
@Suite(
    "S3 Object Lock against the Docker S3 rig",
    .enabled(if: ProcessInfo.processInfo.environment["MACSCP_ITEST"] == "1"),
    .serialized
)
struct S3ObjectLockGatedTests {
    private static let lockHeader = ["x-amz-bucket-object-lock-enabled": "true"]

    /// The rig would turn Object Lock on for this bucket (measured
    /// 2026-10-19); the call must not even try. The raw read afterwards is the
    /// evidence: the store still has no lock configuration.
    @Test func aBucketCreatedWithoutObjectLockIsNotGivenOneByTheDefaultCall() async throws {
        let fs = try await S3FileSystem.connect(S3SettingsRig.config)
        defer { Task { await fs.disconnect() } }
        let bucket = S3SettingsRig.throwawayBucketName(purpose: "lock-plain")
        let created = try await S3SettingsRig.bucketRequest("PUT", bucket, in: fs)
        #expect((200..<300).contains(created))
        guard (200..<300).contains(created) else { return }

        var before: (days: Int, mode: RetentionMode)?
        var refusal: (any Error)?
        var rawStatus: Int?
        var failure: (any Error)?
        do {
            before = try await fs.objectLockDefault(ofBucket: bucket)
            do {
                try await fs.setObjectLockDefault(days: 1, mode: .governance, ofBucket: bucket)
            } catch {
                refusal = error
            }
            let raw = try S3FileSystem.signedRequest(
                .bucketRoot(bucket: bucket), method: "GET",
                query: [(name: "object-lock", value: "")], config: S3SettingsRig.config)
            rawStatus = try await fs.perform(raw).1.statusCode
        } catch {
            failure = error
        }

        let deleted = try? await S3SettingsRig.bucketRequest("DELETE", bucket, in: fs)

        #expect(failure == nil)
        #expect(before == nil)
        #expect((refusal as? RemoteFSError) == .finding(.objectLockNotConfigured))
        #expect(rawStatus == 404, "the store now reports an Object Lock configuration")
        #expect(deleted.map { (200..<300).contains($0) } == true)
    }

    /// No object is written, so the default (which applies to objects
    /// written AFTER it is set) locks nothing and the bucket stays deletable.
    @Test func theBucketDefaultRoundTripsInABucketCreatedWithObjectLock() async throws {
        let fs = try await S3FileSystem.connect(S3SettingsRig.config)
        defer { Task { await fs.disconnect() } }
        let bucket = S3SettingsRig.throwawayBucketName(purpose: "lock-default")
        let created = try await S3SettingsRig.bucketRequest(
            "PUT", bucket, extraHeaders: Self.lockHeader, in: fs)
        #expect((200..<300).contains(created))
        guard (200..<300).contains(created) else { return }

        var initial: (days: Int, mode: RetentionMode)?
        var afterSet: (days: Int, mode: RetentionMode)?
        var afterChange: (days: Int, mode: RetentionMode)?
        var failure: (any Error)?
        do {
            // Object Lock on, no default: `nil`, and not a zero-day default.
            initial = try await fs.objectLockDefault(ofBucket: bucket)
            try await fs.setObjectLockDefault(days: 1, mode: .governance, ofBucket: bucket)
            afterSet = try await fs.objectLockDefault(ofBucket: bucket)
            try await fs.setObjectLockDefault(days: 3, mode: .governance, ofBucket: bucket)
            afterChange = try await fs.objectLockDefault(ofBucket: bucket)
        } catch {
            failure = error
        }

        let deleted = try? await S3SettingsRig.bucketRequest("DELETE", bucket, in: fs)

        #expect(failure == nil)
        #expect(initial == nil)
        #expect(afterSet?.days == 1 && afterSet?.mode == .governance)
        #expect(afterChange?.days == 3 && afterChange?.mode == .governance)
        #expect(deleted.map { (200..<300).contains($0) } == true)
    }

    /// The control comes first: an UNLOCKED object in the same bucket is
    /// deleted (`204`) before a locked one is asserted to be refused, so a
    /// store that refuses everything cannot read as a pass. The bucket has no
    /// default retention (a default would lock the control, which an earlier
    /// probe of this work did by accident), and every object is written
    /// before any lock is set.
    ///
    /// The deletes are VERSIONED, which is what meets the refusal: a plain
    /// `DELETE` of a locked object in this versioned bucket is `204` and a
    /// delete marker (measured 2026-10-19), so macSCP's own delete cannot
    /// provoke it yet. The refusal is handed to `refusalOfDelete`, the
    /// function the delete path reads it through.
    @Test func aLockedObjectIsRefusedAndNamedAfterAnUnlockedOneWasDeleted() async throws {
        let fs = try await S3FileSystem.connect(S3SettingsRig.config)
        defer { Task { await fs.disconnect() } }
        let bucket = S3SettingsRig.throwawayBucketName(purpose: "lock-enforce")
        let created = try await S3SettingsRig.bucketRequest(
            "PUT", bucket, extraHeaders: Self.lockHeader, in: fs)
        #expect((200..<300).contains(created))
        guard (200..<300).contains(created) else { return }

        var versions: [String: String] = [:]
        var failure: (any Error)?
        var controlReads: (hold: Bool, retention: ObjectRetention?)?
        var setRetention: ObjectRetention?
        var readRetention: ObjectRetention?
        var readByVersion: ObjectRetention?
        var holdReadBack: Bool?
        var controlStatus: Int?
        var governanceStatus: Int?
        var governanceError: RemoteFSError?
        var holdStatus: Int?
        var holdError: RemoteFSError?
        var bypassStatus: Int?

        do {
            for key in ["control", "governed", "held"] {
                let (_, response) = try await S3SettingsRig.objectRequest(
                    "PUT", bucket: bucket, key: key, body: Data("x".utf8), in: fs)
                versions[key] = response.value(forHTTPHeaderField: "x-amz-version-id")
            }
            let governed = ObjectRetention(
                mode: .governance,
                retainUntil: Date(timeIntervalSince1970: (Date().timeIntervalSince1970 + 3600).rounded(.down)))
            try await fs.setRetention(governed, ofKey: "governed", inBucket: bucket, versionId: nil)
            setRetention = governed
            readRetention = try await fs.retention(ofKey: "governed", inBucket: bucket, versionId: nil)
            readByVersion = try await fs.retention(
                ofKey: "governed", inBucket: bucket, versionId: versions["governed"])
            try await fs.setLegalHold(true, ofKey: "held", inBucket: bucket, versionId: nil)
            holdReadBack = try await fs.legalHold(ofKey: "held", inBucket: bucket, versionId: nil)

            controlReads = (
                try await fs.legalHold(ofKey: "control", inBucket: bucket, versionId: nil),
                try await fs.retention(ofKey: "control", inBucket: bucket, versionId: nil)
            )

            func versionedDelete(_ key: String, extraHeaders: [String: String] = [:]) async throws
                -> (Data, HTTPURLResponse)
            {
                try await S3SettingsRig.objectRequest(
                    "DELETE", bucket: bucket, key: key,
                    query: [(name: "versionId", value: versions[key] ?? "")],
                    extraHeaders: extraHeaders, in: fs)
            }

            // The control, established first.
            controlStatus = try await versionedDelete("control").1.statusCode

            let governedAnswer = try await versionedDelete("governed")
            governanceStatus = governedAnswer.1.statusCode
            governanceError = await fs.refusalOfDelete(
                status: governedAnswer.1.statusCode, body: governedAnswer.0, bucket: bucket, key: "governed")

            let heldAnswer = try await versionedDelete("held")
            holdStatus = heldAnswer.1.statusCode
            holdError = await fs.refusalOfDelete(
                status: heldAnswer.1.statusCode, body: heldAnswer.0, bucket: bucket, key: "held")

            // The bypass is honoured for GOVERNANCE (and is the cleanup).
            bypassStatus = try await versionedDelete(
                "governed", extraHeaders: ["x-amz-bypass-governance-retention": "true"]).1.statusCode
        } catch {
            failure = error
        }

        // Cleanup runs whether or not the run got to its end: lift the hold,
        // delete what is left of each version with the bypass, delete the
        // bucket.
        try? await fs.setLegalHold(false, ofKey: "held", inBucket: bucket, versionId: nil)
        for key in ["control", "governed", "held"] {
            if let version = versions[key] {
                _ = try? await S3SettingsRig.objectRequest(
                    "DELETE", bucket: bucket, key: key,
                    query: [(name: "versionId", value: version)],
                    extraHeaders: ["x-amz-bypass-governance-retention": "true"], in: fs)
            }
        }
        let deleted = try? await S3SettingsRig.bucketRequest("DELETE", bucket, in: fs)

        #expect(failure == nil)
        #expect(versions.count == 3 && versions.values.allSatisfy { !$0.isEmpty })
        // An object nobody locked reads as unlocked.
        #expect(controlReads?.hold == false)
        #expect(controlReads?.retention == nil)
        // The reads agree with what was written, with or without the version.
        #expect(setRetention != nil && readRetention == setRetention)
        #expect(readByVersion == setRetention)
        #expect(holdReadBack == true)
        // The control, then the refusals.
        #expect(controlStatus == 204, "the unlocked control was not deleted")
        #expect(governanceStatus == 403)
        #expect(governanceError == .finding(.objectUnderRetention(path: "/governed")))
        #expect(holdStatus == 403)
        #expect(holdError == .finding(.objectUnderLegalHold(path: "/held")))
        #expect(bypassStatus == 204)
        #expect(deleted.map { (200..<300).contains($0) } == true, "the throwaway bucket was left behind")
    }
}
