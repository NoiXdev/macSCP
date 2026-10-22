### Task 3: CORS, with macSCP's own validation

**Files:**
- Modify: `Sources/macSCPCore/RemoteFS/S3BucketSettings.swift`, `Sources/macSCPCore/S3/S3SettingsXML.swift`, `S3FileSystem.swift`
- Test: `Tests/macSCPCoreTests/S3CORSTests.swift`

**Interfaces:**
- Produces:

```swift
public struct CORSRule: Sendable, Equatable, Identifiable {
    public let id: String?          // the rule's own <ID>, not an identity
    public var allowedOrigins: [String]
    public var allowedMethods: [String]
    public var allowedHeaders: [String]
    public var exposeHeaders: [String]
    public var maxAgeSeconds: Int?
}

public enum CORSValidation: Equatable, Sendable {
    case ok
    case methodNotAllowed(String)
    case noOrigin
    case noMethod
}

extension S3BucketSettings {
    func cors(ofBucket: String) async throws -> [CORSRule]?   // nil = none configured
    func setCORS(_ rules: [CORSRule], ofBucket: String) async throws
}
```

`CORSRule.validate() -> CORSValidation` is macSCP's own gate. **The allowed method set is exactly `GET`, `PUT`, `POST`, `DELETE`, `HEAD`.** The rig stores `FETCH` (spec §4), so this refusal is pinned against macSCP and never against the store.

- [ ] **Step 1: Write the failing tests**

```swift
@Test func theFullRuleSchemaRoundTrips() throws {
    let rule = CORSRule(id: "rule-one",
                        allowedOrigins: ["https://a.example.com", "https://b.example.com"],
                        allowedMethods: ["GET", "PUT"],
                        allowedHeaders: ["x-amz-meta-foo"],
                        exposeHeaders: ["ETag", "x-amz-version-id"],
                        maxAgeSeconds: 3600)
    let body = try S3SettingsXML.corsBody([rule])
    #expect(try S3SettingsXML.parseCORS(body) == [rule])
}

@Test func anAbsentConfigurationIsNilAndNotAnEmptyList() throws {
    // Review Focus 3: NoSuchCORSConfiguration is "none set", which is not
    // the same as a configuration holding zero rules.
    #expect(try S3SettingsXML.parseCORSResponse(status: 404, body: Data(
        "<Error><Code>NoSuchCORSConfiguration</Code></Error>".utf8)) == nil)
    #expect(try S3SettingsXML.parseCORSResponse(status: 200, body: Data(
        "<CORSConfiguration/>".utf8)) == [])
}

@Test func anInvalidMethodIsRefusedHereAndNotByTheStore() {
    let rule = CORSRule(id: nil, allowedOrigins: ["*"], allowedMethods: ["FETCH"],
                        allowedHeaders: [], exposeHeaders: [], maxAgeSeconds: nil)
    #expect(rule.validate() == .methodNotAllowed("FETCH"))
}

@Test func aRuleNeedsAnOriginAndAMethod() {
    let noOrigin = CORSRule(id: nil, allowedOrigins: [], allowedMethods: ["GET"],
                            allowedHeaders: [], exposeHeaders: [], maxAgeSeconds: nil)
    #expect(noOrigin.validate() == .noOrigin)
    let noMethod = CORSRule(id: nil, allowedOrigins: ["*"], allowedMethods: [],
                            allowedHeaders: [], exposeHeaders: [], maxAgeSeconds: nil)
    #expect(noMethod.validate() == .noMethod)
}
```

- [ ] **Step 2: Run them and watch them fail**

Run: `swift test --filter S3CORSTests`
Expected: FAIL — `cannot find 'CORSRule' in scope`.

- [ ] **Step 3: Implement `CORSRule`, `validate()`, and the three XML functions**

`setCORS` calls `validate()` on every rule and throws before any request when one fails.

- [ ] **Step 4: Run the unit tests**

Run: `swift test --filter S3CORSTests`
Expected: PASS.

- [ ] **Step 5: Add the gated round trip**

Write the full-schema rule to a throwaway bucket, read it back, compare. Then assert that `setCORS` with a `FETCH` method throws **without** reaching the store — the rig would accept it.

Run: `MACSCP_ITEST=1 swift test --filter S3CORSGated`

- [ ] **Step 6: Commit**

```bash
git add Sources/macSCPCore Tests/macSCPCoreTests/S3CORSTests.swift
git commit -m "feat(s3): read and write a bucket's CORS rules, validated here"
```

---

