### Task 6: Let an account with no buckets connect

**Files:**
- Modify: `Sources/macSCPCore/S3/S3FileSystem.swift` (`connect`)
- Test: `Tests/macSCPCoreTests/S3FileSystemTests.swift`

This is the plan's riskiest task: it relaxes a deliberate refusal whose comment reads *"an empty browser explains nothing"*. That reasoning held while an empty browser offered nothing; Task 11 gives it the one action that resolves it.

**Interfaces:**
- Produces: `connect` in `.bucketList` mode no longer throws `RemoteFSError.bucketListEmpty` for an empty account. `.bucket` mode is **unchanged** — a named bucket that does not exist is still a failed connect.

- [ ] **Step 1: Write the failing test**

```swift
@Test func anAccountWithNoBucketsConnectsInBucketListMode() async throws {
    let fs = try await S3FileSystem.connect(configWithNoBuckets, rootMode: .bucketList)
    #expect(try await fs.list(path: "/").isEmpty)
}

@Test func aNamedBucketThatDoesNotExistStillRefusesTheConnect() async {
    await #expect(throws: RemoteFSError.self) {
        try await S3FileSystem.connect(configNamingAMissingBucket, rootMode: .bucket("nope"))
    }
}
```

The second test is what keeps this relaxation from widening past its reason.

- [ ] **Step 2: Run them and watch the first fail**

Run: `swift test --filter S3FileSystemTests`
Expected: FAIL — the first throws `bucketListEmpty`.

- [ ] **Step 3: Remove the empty-list throw in `.bucketList` mode only**

Keep the `listBuckets()` call: it is still the readiness and authorisation probe, and `bucketListForbidden` must survive.

- [ ] **Step 4: Rewrite the comment above it**

The comment states today's reasoning and is now wrong. Replace it with what is true, quoting the withdrawn sentence, and name the action that makes an empty browser explain something.

- [ ] **Step 5: Run the suite and check `bucketListEmpty`'s other readers**

Run: `swift test`
If `RemoteFSError.bucketListEmpty` now has no producer, say so in the report rather than deleting the case in this task.

- [ ] **Step 6: Commit**

```bash
git add Sources/macSCPCore/S3/S3FileSystem.swift Tests/macSCPCoreTests/S3FileSystemTests.swift
git commit -m "fix(s3): let an account with no buckets connect, so one can be made"
```

---

