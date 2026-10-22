### Task 4: Object Lock — the bucket default, and the per-object locks

**Files:**
- Modify: `Sources/macSCPCore/RemoteFS/S3BucketSettings.swift`, `S3SettingsXML.swift`, `S3FileSystem.swift`
- Test: `Tests/macSCPCoreTests/S3ObjectLockTests.swift`

**Interfaces:**
- Produces:

```swift
public enum RetentionMode: String, Sendable, CaseIterable { case governance = "GOVERNANCE", compliance = "COMPLIANCE" }
public struct ObjectRetention: Sendable, Equatable { public var mode: RetentionMode; public var retainUntil: Date }

extension S3BucketSettings {
    func objectLockDefault(ofBucket: String) async throws -> (days: Int, mode: RetentionMode)?  // nil = not configured
    func setObjectLockDefault(days: Int, mode: RetentionMode, ofBucket: String) async throws
    func retention(ofKey: String, inBucket: String, versionId: String?) async throws -> ObjectRetention?
    func setRetention(_ retention: ObjectRetention, ofKey: String, inBucket: String, versionId: String?) async throws
    func legalHold(ofKey: String, inBucket: String, versionId: String?) async throws -> Bool
    func setLegalHold(_ on: Bool, ofKey: String, inBucket: String, versionId: String?) async throws
}
```

`versionId` is carried from the start and is `nil` everywhere in this half — the second half supplies it (spec §5).

**There is no call to enable Object Lock on an existing bucket, and there must never be one.** The rig would accept it; AWS refuses it (spec §4).

- [ ] **Step 1: Write the failing tests**

```swift
@Test func anAbsentLockConfigurationIsNilAndNotAZeroDayDefault() throws {
    #expect(try S3SettingsXML.parseObjectLockResponse(status: 404, body: Data(
        "<Error><Code>ObjectLockConfigurationNotFoundError</Code></Error>".utf8)) == nil)
}

@Test func aBucketDefaultRoundTrips() throws {
    let body = try S3SettingsXML.objectLockBody(days: 1, mode: .governance)
    let parsed = try #require(try S3SettingsXML.parseObjectLockResponse(status: 200, body: body))
    #expect(parsed.days == 1)
    #expect(parsed.mode == .governance)
}

@Test func theProtocolOffersNoWayToEnableLockOnAnExistingBucket() {
    // Review Focus 5 and spec §4: the rig would say 200 to this, so the
    // guard is a positive assertion about macSCP's own surface. Paired with
    // the positive check that the four real lock methods ARE there, so the
    // scan cannot go stale in silence.
    let surface = S3BucketSettingsSurface.methodNames
    #expect(surface.contains("setObjectLockDefault(days:mode:ofBucket:)"))
    #expect(surface.contains(where: { $0.contains("enableObjectLock") }) == false)
}
```

`S3BucketSettingsSurface.methodNames` is a test-support constant listing the protocol's methods, read from the protocol's own declaration in `SourceCorpus` rather than retyped.

- [ ] **Step 2: Run them and watch them fail**

Run: `swift test --filter S3ObjectLockTests`
Expected: FAIL — the parse functions do not exist.

- [ ] **Step 3: Implement the six methods and their XML**

- [ ] **Step 4: Teach the delete path to tell the two refusals apart**

When a delete is refused with `AccessDenied` on a bucket that has Object Lock, read `?legal-hold` for that key: `ON` means `objectUnderLegalHold`, otherwise `objectUnderRetention`. This is the caller Task 1 Step 4 names.

- [ ] **Step 5: Run the unit tests**

Run: `swift test --filter "S3ObjectLock|S3ErrorCode"`
Expected: PASS.

- [ ] **Step 6: Add the gated enforcement test**

In a throwaway lock-enabled bucket: set a GOVERNANCE retention, assert the delete is refused and arrives as `objectUnderRetention`; set a legal hold, assert `objectUnderLegalHold`. The control runs first — an unlocked object in the same bucket deletes — so a blanket refusal cannot read as a pass.

Run: `MACSCP_ITEST=1 swift test --filter S3ObjectLockGated`

- [ ] **Step 7: Commit**

```bash
git add Sources/macSCPCore Tests/macSCPCoreTests/S3ObjectLockTests.swift
git commit -m "feat(s3): read and write object lock, per bucket and per object"
```

---

