### Task 1: The store's refusal, said honestly

**Files:**
- Create: `Sources/macSCPCore/S3/S3ErrorCode.swift`
- Modify: `Sources/macSCPCore/RemoteFS/RemoteFSFinding.swift`, `Sources/macSCPCore/S3/S3FileSystem.swift` (`mapErrorStatus`, and its call sites' error path)
- Modify: `Sources/macSCPCore/Resources/<locale>.lproj/Localizable.strings` ×4
- Test: `Tests/macSCPCoreTests/S3ErrorCodeTests.swift`

**Interfaces:**
- Produces: `enum S3ErrorCode { static func parse(_ body: Data) -> String? ; static func finding(forCode: String, status: Int, path: String) -> RemoteFSError? }`, and five new `RemoteFSFinding` cases: `objectUnderLegalHold`, `objectUnderRetention`, `objectLockNotConfigured`, `bucketNotEmpty`, `operationNotSupported`.

**Why only five.** Each named code costs a finding case, a `Name` case, a `name` switch arm and four catalogue sentences. These five are the ones a user of this feature can actually provoke; everything else keeps today's behaviour.

- [ ] **Step 1: Write the failing tests**

```swift
@Test func anErrorBodyYieldsItsCode() {
    let body = Data("""
    <?xml version="1.0" encoding="UTF-8"?><Error><Code>AccessDenied</Code>\
    <Message>Object has a legal hold and cannot be deleted.</Message></Error>
    """.utf8)
    #expect(S3ErrorCode.parse(body) == "AccessDenied")
}

@Test func aBodyWithNoCodeYieldsNil() {
    #expect(S3ErrorCode.parse(Data("not xml".utf8)) == nil)
}

@Test func anUnnamedCodeKeepsTodaysMapping() {
    let mapped = S3ErrorCode.finding(forCode: "SignatureDoesNotMatch", status: 403, path: "/b/k")
    #expect(mapped == nil)   // nil means: fall through to mapErrorStatus
}

@Test(arguments: [
    ("ObjectLockConfigurationNotFoundError", 404, RemoteFSFinding.Name.objectLockNotConfigured),
    ("BucketNotEmpty", 409, RemoteFSFinding.Name.bucketNotEmpty),
    ("NotImplemented", 501, RemoteFSFinding.Name.operationNotSupported),
])
func anamedCodeBecomesItsFinding(code: String, status: Int, expected: RemoteFSFinding.Name) throws {
    let mapped = try #require(S3ErrorCode.finding(forCode: code, status: status, path: "/b/k"))
    guard case .finding(let finding) = mapped else { Issue.record("not a finding"); return }
    #expect(finding.name == expected)
}

@Test func noNewFindingCarriesTheServersSentence() {
    // The store's message is the thing that must NOT travel. Compute the Bool
    // before the expectation so neither the sentence nor its spelling can
    // reach a failure message.
    let serverSentence = "Object has a legal hold and cannot be deleted."
    let finding = RemoteFSFinding.objectUnderLegalHold(path: "/b/k")
    let leaks = finding.logSentence.contains(serverSentence)
    #expect(leaks == false)
}
```

- [ ] **Step 2: Run them and watch them fail**

Run: `swift test --filter S3ErrorCodeTests`
Expected: FAIL — `cannot find 'S3ErrorCode' in scope`.

- [ ] **Step 3: Add the five cases to `RemoteFSFinding`**

Each needs: the case (payload `path: String` where the object is named, none otherwise), its `Name` case, its arm in the `name` switch, and its `logSentence`. The key is derived from the `Name`, so nothing spells it.

- [ ] **Step 4: Implement `S3ErrorCode` in `Sources/macSCPCore/S3/S3ErrorCode.swift`**

`parse` reads the first `<Code>` element out of the body; reuse the project's existing XML reading rather than adding a dependency. `finding(forCode:status:path:)` returns `nil` for anything unnamed, which is the signal to fall through.

The legal-hold / retention split cannot be read from `<Code>` alone — both are `AccessDenied`. Distinguish by the operation's own knowledge: a delete refused on a version whose `?legal-hold` reads `ON` is `objectUnderLegalHold`, otherwise `objectUnderRetention`. The caller that knows this is the delete path in Task 4; `S3ErrorCode` itself maps `AccessDenied` to `nil`.

- [ ] **Step 5: Route `mapErrorStatus` through it**

`mapErrorStatus(_:path:)` gains the response body. Where `S3ErrorCode.finding` returns a value, it is thrown; otherwise today's mapping stands unchanged, so no existing behaviour moves.

- [ ] **Step 6: Four catalogue sentences per new finding**

`core.finding.objectUnderLegalHold` etc. in both `macSCPCore` catalogues ×4 locales. German in du-form.

- [ ] **Step 7: Run the suite**

Run: `swift test --filter "S3ErrorCode|RemoteFSFinding|LocalizationParity"`
Expected: PASS, including `everyRemoteFSFindingHasItsOwnSentence`.

- [ ] **Step 8: Check the blast radius, and report it**

`.authenticationFailed` is branched on in `TransferQueueViewModel`, `RemoteBrowserViewModel` and `ConnectionViewModel`. Nothing here removes a `.authenticationFailed`; it only adds findings for codes that used to become one. Run the full suite and name any test whose expectation changed.

Run: `swift test`

- [ ] **Step 9: Commit**

```bash
git add Sources/macSCPCore/S3/S3ErrorCode.swift Sources/macSCPCore/RemoteFS/RemoteFSFinding.swift Sources/macSCPCore/S3/S3FileSystem.swift Sources/macSCPCore/Resources Tests/macSCPCoreTests/S3ErrorCodeTests.swift
git commit -m "feat(s3): name five refusals the store used to flatten into one"
```

---

