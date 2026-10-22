### Task 10: The Object Lock sheets

**Files:**
- Create: `Sources/MacSCPAppKit/BucketObjectLockSheet.swift`, `Sources/MacSCPAppKit/ObjectLockSheet.swift`
- Modify: `Sources/macSCPCore/Capabilities/BackendDescriptor.swift` (two `fileActions`), `ContentView+MenuActions.swift`
- Test: `Tests/macSCPAppKitTests/ObjectLockSheetTests.swift`

**Interfaces:**
- Consumes: `ObjectRetention`, `RetentionMode`, the six Object Lock methods.
- Produces: `FileActionContribution` ids `s3.retention` and `s3.legalHold`.

- [ ] **Step 1: Write the failing tests**

```swift
@MainActor @Test func complianceCannotBeRunUntilItIsAcknowledged() {
    let model = ObjectLockModel(bucketHasLock: true)
    model.mode = .compliance
    model.retainUntil = Date(timeIntervalSince1970: 1_798_761_600)
    #expect(model.canRun == false)
    model.acknowledged = true
    #expect(model.canRun == true)
}

@MainActor @Test func governanceNeedsNoAcknowledgement() {
    let model = ObjectLockModel(bucketHasLock: true)
    model.mode = .governance
    #expect(model.canRun == true)
}

@MainActor @Test func theAcknowledgementNamesTheDate() {
    let model = ObjectLockModel(bucketHasLock: true)
    model.mode = .compliance
    model.retainUntil = Date(timeIntervalSince1970: 1_798_761_600)
    #expect(model.acknowledgementKey == "s3.objectLock.complianceAcknowledgement %@")
    #expect(model.acknowledgementDateText.isEmpty == false)
}

@MainActor @Test func aBucketWithoutObjectLockOffersNoLockAtAll() {
    // Review Focus 5: the rig would accept the enabling call, so the refusal
    // is macSCP's own.
    let model = ObjectLockModel(bucketHasLock: false)
    #expect(model.canRun == false)
    #expect(model.unavailableReasonKey == "s3.objectLock.notEnabledOnThisBucket")
}
```

- [ ] **Step 2: Run them and watch them fail**

Run: `swift test --filter ObjectLockSheetTests`
Expected: FAIL — `cannot find 'ObjectLockModel' in scope`.

- [ ] **Step 3: Implement both sheets**

The per-file sheet carries mode, date, legal-hold toggle, and — for COMPLIANCE only — a checkbox naming the exact date beyond which nobody can undo it (maintainer decision 2026-10-19). Use `CheckboxRow(_:isOn:wraps:)` from `RigidControls.swift` with `wraps: true`, since the sentence is long.

- [ ] **Step 4: Read the bucket's lock state lazily, and cache it for the session**

Spec §8: Object Lock is the one call with a hard "not configured" answer
(`404`), and in bucket-list mode every bucket differs, so it is read per
bucket when a surface that needs it opens and kept for the session.

```swift
@MainActor @Test func theLockStateIsReadOncePerBucket() async throws {
    let probe = CountingBucketSettings()          // counts calls
    let cache = ObjectLockStateCache(settings: probe)
    _ = try await cache.hasObjectLock("b")
    _ = try await cache.hasObjectLock("b")
    #expect(probe.hasObjectLockCalls == 1)
    _ = try await cache.hasObjectLock("other")
    #expect(probe.hasObjectLockCalls == 2)
}
```

**Corrected 2026-10-21, before dispatch.** These two expectations first read
`#expect(probe.objectLockDefaultCalls == 1)` and
`#expect(probe.objectLockDefaultCalls == 2)`, which would have had the cache
call the wrong method and would have broken the feature this task exists for.
Core distinguishes the two deliberately, and says so at
`S3BucketSettings.swift:142-152`: `objectLockDefault` is `nil` for **two
different bucket states** — a bucket with no Object Lock at all, and a bucket
that has Object Lock but no default retention yet — while `hasObjectLock`
answers the first question alone, `false` only on the store's `404`
`ObjectLockConfigurationNotFoundError` and never on any other failure.

The doc comment names the consequence of confusing them: "a lock-enabled bucket
with no default is exactly where a first retention is set, and reading it as
'no Object Lock' would hide that." A cache built on `objectLockDefault` would
therefore show `notEnabledOnThisBucket` on precisely the bucket where the user
is about to set their first retention. Build the cache on
`hasObjectLock(ofBucket:)`.

`ObjectLockStateCache` is owned by the session, so it dies with it. A `404` is
cached as "no lock", not as a failure to retry.

- [ ] **Step 5: Add the two `fileActions` and their dispatch arms**

- [ ] **Step 6: Run the tests, catalogue entries, commit**

```bash
git commit -m "feat(app): set a retention or a legal hold, and make compliance deliberate"
```

---

