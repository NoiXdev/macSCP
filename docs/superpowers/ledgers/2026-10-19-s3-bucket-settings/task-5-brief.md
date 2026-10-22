### Task 5: Create bucket

**Files:**
- Create: `Sources/macSCPCore/S3/S3BucketName.swift`
- Modify: `Sources/macSCPCore/RemoteFS/S3BucketSettings.swift`, `S3FileSystem.swift`
- Test: `Tests/macSCPCoreTests/S3BucketNameTests.swift`

**Interfaces:**
- Produces:

```swift
public enum BucketNameProblem: Equatable, Sendable {
    case tooShort, tooLong, uppercase, invalidCharacter(Character), looksLikeAnIPAddress, badEdge
}
public enum S3BucketName { public static func problem(with name: String) -> BucketNameProblem? }

extension S3BucketSettings {
    func createBucket(_ name: String, versioning: Bool, objectLock: Bool) async throws
}
```

`objectLock: true` sends `x-amz-bucket-object-lock-enabled: true` on the `CreateBucket` **and** implies versioning, which S3 requires; the call sets versioning itself rather than relying on the store.

- [ ] **Step 1: Write the failing tests**

```swift
@Test(arguments: [
    ("ab", BucketNameProblem.tooShort),
    ("My-Bucket", .uppercase),
    ("my_bucket", .invalidCharacter("_")),
    ("192.168.0.1", .looksLikeAnIPAddress),
    ("-leading", .badEdge),
    ("trailing-", .badEdge),
])
func aNameSThreeWouldRejectIsRefusedHere(name: String, expected: BucketNameProblem) {
    #expect(S3BucketName.problem(with: name) == expected)
}

@Test(arguments: ["macscp-seed", "a-b-c", "bucket123", String(repeating: "a", count: 63)])
func aValidNamePasses(name: String) {
    #expect(S3BucketName.problem(with: name) == nil)
}
```

The second case is the positive control for the first: a refusal list with no acceptance list beside it cannot be shown to refuse only what it should.

- [ ] **Step 2: Run them and watch them fail**

Run: `swift test --filter S3BucketNameTests`
Expected: FAIL — `cannot find 'S3BucketName' in scope`.

- [ ] **Step 3: Implement `S3BucketName.problem(with:)` and `createBucket`**

`createBucket` calls `problem(with:)` first and throws before any request.

- [ ] **Step 4: Run the unit tests, then the gated creation**

Run: `swift test --filter S3BucketNameTests`
Run: `MACSCP_ITEST=1 swift test --filter S3CreateBucketGated` — creates with both switches, reads versioning back as `.enabled` and the lock configuration as present, then deletes.

- [ ] **Step 5: Commit**

```bash
git add Sources/macSCPCore Tests/macSCPCoreTests/S3BucketNameTests.swift
git commit -m "feat(s3): create a bucket, with versioning and object lock"
```

---

