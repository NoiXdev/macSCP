### Task 2: `S3BucketSettings`, and versioning through it

**Files:**
- Create: `Sources/macSCPCore/RemoteFS/S3BucketSettings.swift`, `Sources/macSCPCore/S3/S3SettingsXML.swift`
- Modify: `Sources/macSCPCore/S3/S3FileSystem.swift` (conformance)
- Test: `Tests/macSCPCoreTests/S3SettingsXMLTests.swift`, `Tests/macSCPCoreTests/S3BucketSettingsGatedTests.swift`

**Interfaces:**
- Consumes: Task 1's findings.
- Produces:

```swift
public enum BucketVersioning: String, Sendable, CaseIterable {
    case never, enabled, suspended
}

public protocol S3BucketSettings: Sendable {
    func versioning(ofBucket bucket: String) async throws -> BucketVersioning
    func setVersioning(_ state: BucketVersioning, ofBucket bucket: String) async throws
}
```

`setVersioning(.never, …)` is unrepresentable at the store and throws `RemoteFSError.finding(.operationNotSupported)`; `.never` exists only as a read result. The remaining nine protocol methods arrive on the same protocol: two in Task 3, six in Task 4, one in Task 5.

- [ ] **Step 1: Write the failing tests**

```swift
@Test func anAbsentVersioningElementReadsAsNever() throws {
    let xml = Data("<VersioningConfiguration xmlns=\"http://s3.amazonaws.com/doc/2006-03-01/\"/>".utf8)
    #expect(try S3SettingsXML.parseVersioning(xml) == .never)
}

@Test(arguments: [("Enabled", BucketVersioning.enabled), ("Suspended", BucketVersioning.suspended)])
func aStatusReadsAsItsState(text: String, expected: BucketVersioning) throws {
    let xml = Data("<VersioningConfiguration><Status>\(text)</Status></VersioningConfiguration>".utf8)
    #expect(try S3SettingsXML.parseVersioning(xml) == expected)
}

@Test func neverCannotBeWritten() {
    #expect(throws: RemoteFSError.self) { try S3SettingsXML.versioningBody(.never) }
}
```

Review Focus 4 — a never-versioned bucket offers no "suspend" — is a UI rule, pinned in Task 8; here it is only that `.never` has no body.

- [ ] **Step 2: Run them and watch them fail**

Run: `swift test --filter S3SettingsXMLTests`
Expected: FAIL — `cannot find 'S3SettingsXML' in scope`.

- [ ] **Step 3: Implement the protocol and the two XML functions**

`S3SettingsXML.parseVersioning(_ data: Data) throws -> BucketVersioning`, `S3SettingsXML.versioningBody(_ state: BucketVersioning) throws -> Data`.

- [ ] **Step 4: Conform `S3FileSystem`**

`extension S3FileSystem: S3BucketSettings`. The two calls are `GET`/`PUT` on `?versioning`, built with the existing `signedRequest`/`send` pair and the existing bucket-scoped `requestURL`.

- [ ] **Step 5: Run the unit tests**

Run: `swift test --filter "S3SettingsXML|S3FileSystem"`
Expected: PASS.

- [ ] **Step 6: Add the gated round trip**

In `S3BucketSettingsGatedTests.swift`, behind `MACSCP_ITEST`: create a throwaway bucket, read `.never`, set `.enabled`, read it back, set `.suspended`, read it back, delete the bucket. Every wait is an `await`; no wall-clock ceiling.

Run: `MACSCP_ITEST=1 swift test --filter S3BucketSettingsGatedTests`
Expected: PASS against the running rig.

- [ ] **Step 7: Commit**

```bash
git add Sources/macSCPCore/RemoteFS/S3BucketSettings.swift Sources/macSCPCore/S3/S3SettingsXML.swift Sources/macSCPCore/S3/S3FileSystem.swift Tests/macSCPCoreTests
git commit -m "feat(s3): read and write a bucket's versioning state"
```

---

