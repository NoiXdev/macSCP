# S3 Bucket Settings Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give an S3 connection its own actions menu in the window toolbar, and put a bucket's versioning, CORS and Object Lock settings behind it — plus per-file retention and legal hold in the context menu, and refusals that say what they are.

**Architecture:** A new optional Core capability protocol (`S3BucketSettings`), queried with `as?` exactly like `PresignedURLProvider`, carries every call. A new connection-level contribution list on `BackendDescriptor` carries the menu, rebuilt only because five real callers exist. The App renders one capsule and five sheets.

**Tech Stack:** Swift 6 (`.swiftLanguageMode(.v6)`), SwiftPM, SwiftUI, Swift Testing, URLSession + SigV4.

**Spec:** `docs/superpowers/specs/2026-10-19-s3-bucket-settings-design.md`

## Global Constraints

- Swift 6 strict, all targets `.swiftLanguageMode(.v6)`, minimum macOS 15.
- Tests: Swift Testing (`@Test`/`#expect`), TDD red→green, the red quoted verbatim in the commit.
- `swift test` with **no** `--build-system` flag.
- Never hardcode a display string: `L10n.string(_:_:)` in `MacSCPAppKit`, `CoreL10n.string(_:)` in `macSCPCore`. Catalogues `en`, `de`, `fr`, `pl`; the German catalogues address the user as **du**.
- No secret in any store, state, log, `reason:` string, notification or test failure message.
- `RemoteFSFinding` carries no foreign text: HTTP status codes, caller-supplied paths and this project's own counted values only. `RemoteFSFindingTests.noFindingCarriesForeignText` enforces it.
- Every new `RemoteFSFinding` case owes four catalogue entries at `core.finding.<name>`, pinned by `LocalizationParityTests.everyRemoteFSFindingHasItsOwnSentence`.
- Every new `AuditEvent.Kind` owes four catalogue entries, pinned by `everyKindHasACatalogLabel` over `Kind.allCases`.
- Commit footer on every commit: `Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>`. Conventional Commits.
- Every written artifact is English. Commit/push only on explicit request.
- Gated rig suites run under `MACSCP_ITEST=1`; the rig is started **from the main checkout only**.
- **The rig is more permissive than AWS in one measured way** (spec §4): it stores a CORS method of `FETCH`, which AWS refuses. That refusal is macSCP's own and must be pinned against macSCP, never against the store's answer. **Corrected 2026-10-19:** this line first read “more permissive than AWS in **two** measured ways … it accepts Object Lock on an existing bucket, and it stores a CORS method of `FETCH`. **Both** refusals are macSCP's own”. The Object Lock half is withdrawn — AWS allows enabling Object Lock on an existing versioned bucket, so the rig does not diverge there (spec §4).

## Review Focus

Five conditions the spec implies that no task's happy path exercises. Each has its test named in the owning task.

1. **A bucket name S3 would reject** (uppercase, underscore, 2 characters, dotted-IP shape) — refused in macSCP before any request. Task 5.
2. **A store that does not implement a call at all** (`501`, or `NotImplemented` in the body) — explained as unsupported, never surfaced as an authentication failure. Task 1.
3. **A bucket with no CORS configuration at all** (`NoSuchCORSConfiguration`) — read as "none set", which is not the same as "an empty rule list". Task 3.
4. **Suspending versioning on a bucket that was never versioned** — offered only where it means something; a never-versioned bucket's switch has no "suspend". Task 2.
5. **A retention or legal hold aimed at a bucket without Object Lock** — unreachable in the UI, and refused by Core if reached anyway, because the rig would accept the enabling call. Task 4.

---

## File Structure

**Core — new**
- `Sources/macSCPCore/RemoteFS/S3BucketSettings.swift` — the optional capability protocol and its value types. One responsibility: what a bucket's settings *are*, free of transport.
- `Sources/macSCPCore/S3/S3SettingsXML.swift` — serialise and parse the five configurations. Sits beside `S3ListParser`/`S3MultipartXML`, which already own the other XML.
- `Sources/macSCPCore/S3/S3ErrorCode.swift` — the store's `<Code>` out of an error body, and its mapping to a finding.
- `Sources/macSCPCore/S3/S3BucketName.swift` — bucket-name validation, macSCP's own.

**Core — modified**
- `Sources/macSCPCore/S3/S3FileSystem.swift` — `mapErrorStatus`, `connect`, and the `S3BucketSettings` conformance.
- `Sources/macSCPCore/RemoteFS/RemoteFSFinding.swift` — new cases.
- `Sources/macSCPCore/Capabilities/BackendContributions.swift` — `ConnectionActionContribution`.
- `Sources/macSCPCore/Capabilities/BackendDescriptor.swift` — `connectionActions`, and S3's entries.
- `Sources/macSCPCore/Sessions/AuditEvent.swift` + `AuditRecorder.swift` — new kinds.

**App — new**
- `Sources/MacSCPAppKit/ConnectionActionsMenu.swift` — the toolbar capsule.
- `Sources/MacSCPAppKit/BucketVersioningSheet.swift`
- `Sources/MacSCPAppKit/BucketCORSSheet.swift`
- `Sources/MacSCPAppKit/BucketObjectLockSheet.swift`
- `Sources/MacSCPAppKit/CreateBucketSheet.swift`
- `Sources/MacSCPAppKit/ObjectLockSheet.swift` — per-file retention and legal hold.

**App — modified**
- `Sources/MacSCPAppKit/ContentView+Lifecycle.swift` — the capsule in the toolbar.
- `Sources/MacSCPAppKit/ContentView+MenuActions.swift` — the two new contribution ids.
- The four `Localizable.strings`, both targets.

---

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

**There is no call to enable Object Lock on an existing bucket, and there must never be one** — for scope and irreversibility: the maintainer asked for the two switches at bucket creation, retrofitting a lock is a change nobody requested, and it can never be undone. **Corrected 2026-10-19:** the rationale here first read “The rig would accept it; AWS refuses it (spec §4)”. That is withdrawn — AWS permits it on an existing versioned bucket. The restriction is unchanged; only its reason is.

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
    enum BucketProtection: Sendable { case none, versioned, lockedAndVersioned }
    func createBucket(_ name: String, protection: BucketProtection) async throws
}
```

`.lockedAndVersioned` sends `x-amz-bucket-object-lock-enabled: true` on the
`CreateBucket` and turns versioning on, which S3 requires; the call sets
versioning itself rather than relying on the store, because `CreateBucket` has
no versioning flag.

**Corrected 2026-10-19, during execution.** The interface above first read
"`func createBucket(_ name: String, versioning: Bool, objectLock: Bool) async
throws`", and this step first read "`objectLock: true` sends
`x-amz-bucket-object-lock-enabled: true` on the `CreateBucket` **and** implies
versioning, which S3 requires; the call sets versioning itself rather than
relying on the store." Two `Bool`s can express `objectLock: true,
versioning: false`, which S3 cannot do. The implementer refused that
combination at runtime; the controller ruled it should be unrepresentable
instead, which deletes the refusal, its test and a mutation probe that could
only ever be an equivalent mutant.

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

### Task 7: The connection-level action seam

**Files:**
- Modify: `Sources/macSCPCore/Capabilities/BackendContributions.swift`, `BackendDescriptor.swift`
- Create: `Sources/MacSCPAppKit/ConnectionActionsMenu.swift`
- Modify: `Sources/MacSCPAppKit/ContentView+Lifecycle.swift`
- Test: `Tests/macSCPCoreTests/BackendContributionTests.swift`, `Tests/macSCPAppKitTests/ConnectionActionsMenuTests.swift`

**Interfaces:**
- Produces:

```swift
public struct ConnectionActionContribution: Sendable, Equatable, Identifiable {
    public let id: String
    public let titleKey: String
    public let titleDefault: String
    public let systemImage: String
}
// on BackendDescriptor:
public let connectionActions: [ConnectionActionContribution]
```

S3's four entries: `s3.createBucket`, `s3.versioning`, `s3.cors`, `s3.objectLock`. SSH's and WebDAV's are `[]`.

**This is the seam M22 deleted for being empty.** It is rebuilt with four callers present. The guard below is what holds it to that.

- [ ] **Step 1: Write the failing tests**

```swift
@Test func onlyS3ContributesConnectionActions() {
    #expect(BackendDescriptor.sshDescriptor.connectionActions.isEmpty)
    #expect(BackendDescriptor.webDAVDescriptor.connectionActions.isEmpty)
    #expect(BackendDescriptor.s3Descriptor.connectionActions.count == 4)
}

@Test func theSeamIsNotEmptyInEveryBackend() {
    // The anti-goal, as a test: if every descriptor's list empties, the seam
    // has become the thing M22 removed and should go with it.
    let total = ConnectionKind.allCases
        .map(BackendDescriptor.descriptor(for:))
        .reduce(0) { $0 + $1.connectionActions.count }
    #expect(total > 0)
}

@MainActor @Test func aBackendWithNoActionsRendersNoCapsule() {
    #expect(ConnectionActionsMenu.isPresented(for: BackendDescriptor.sshDescriptor) == false)
    #expect(ConnectionActionsMenu.isPresented(for: BackendDescriptor.s3Descriptor) == true)
}
```

- [ ] **Step 2: Run them and watch them fail**

Run: `swift test --filter "BackendContribution|ConnectionActionsMenu"`
Expected: FAIL — `value of type 'BackendDescriptor' has no member 'connectionActions'`.

- [ ] **Step 3: Add `ConnectionActionContribution` and the descriptor member**

Every existing `BackendDescriptor(...)` construction gains `connectionActions:`.

**Corrected 2026-10-20, during execution, and this is the third site of the same
error.** This step first read "A synthetic descriptor exists in
`SchemaConformanceTests` and needs it too." There are **eight** synthetic
descriptors in tests, not one, and `SchemaConformanceTests` is one of them;
`grep -rn 'BackendDescriptor(' Sources Tests --include='*.swift'` prints 12
lines, of which one is a test function name
(`theBadgeNamesTheProtocolThroughTheBackendDescriptor()`), leaving 11 real
construction sites: 3 production and 8 synthetic. The plan did not invent the
singular — it copied it from a doc comment on `apply` that said "the one
synthetic descriptor, in `SchemaConformanceTests`", which Task 7 corrected in
`46bfdebb`. A wrong count in a comment became a wrong count in a plan, which is
the whole argument for counting in the moment you write a number.

- [ ] **Step 4: Build `ConnectionActionsMenu`**

A `Menu` rendering the active session's descriptor's `connectionActions`, titled from `L10n.string(titleKey, titleDefault)`. `isPresented(for:)` is `!descriptor.connectionActions.isEmpty`. The view is a `BoundedView` if it declares a width.

- [ ] **Step 5: Place it in the toolbar**

In `ContentView+Lifecycle.swift`'s `ToolbarItemGroup(placement: .primaryAction)`, **before** the existing buttons, so it lands in the free area left of the icon group (spec §5, the maintainer's screenshot of 2026-10-19). Rendered only when `isPresented(for:)`.

- [ ] **Step 6: Run the tests**

Run: `swift test --filter "BackendContribution|ConnectionActionsMenu"`
Expected: PASS.

- [ ] **Step 7: Four catalogue entries per action title, ×4 locales**

- [ ] **Step 8: Commit**

```bash
git add Sources/macSCPCore/Capabilities Sources/MacSCPAppKit Tests
git commit -m "feat(app): a connection's own actions, as one list per backend"
```

---

### Task 8: The versioning sheet

**Files:**
- Create: `Sources/MacSCPAppKit/BucketVersioningSheet.swift`
- Modify: `Sources/MacSCPAppKit/ContentView+MenuActions.swift`
- Modify: `Sources/MacSCPAppKit/ContentView+Lifecycle.swift` (**added 2026-10-20
  — see "This task owns the handler seam" below**)
- Test: `Tests/macSCPAppKitTests/BucketVersioningSheetTests.swift`

**This task owns the handler seam, added 2026-10-20 from Task 7's review (I2).**
Task 7 built the menu but had no handler to give it, so
`ContentView+Lifecycle.swift` passes `onSelect: nil` and all four rows render
disabled. No later task's file list touched that file, so without this
assignment every row would stay disabled for the rest of the plan — a menu that
is placed, localized, tested and permanently dead.

Replace the `nil` with a dispatcher that routes by contribution **id**, the way
`ContentView+MenuActions.swift` already dispatches file actions, and give it
**per-row availability** rather than one flag for the menu: the call site in
`ContentView+Lifecycle.swift` is the only place that knows both the descriptor
and the session's root mode, which is what Task 11's gate needs (I3, recorded
there). Wire `s3.versioning` to this task's sheet; the other three ids stay
unavailable until Tasks 9, 10 and 11 add their arms, and a row with no arm
stays disabled rather than enabled-and-inert.

A test pins that a wired id is enabled and an unwired id is not — the positive
beside the negative, since "disabled" is the state a broken dispatcher also
produces.

**You will break a guard, and this is the one, named here so you do not discover
it as a mystery red.** Task 7's fix round added
`ConnectionActionsMenuTests.theRowsAreDisabledWhileThereIsNoHandler`
(`Tests/macSCPAppKitTests/ConnectionActionsMenuTests.swift:186`). It requires a
`.disabled(...)` inside the `ForEach` conditioned on the handler being `nil`,
reading the handler's name from the view's own declaration, and it exists because
without it the whole user-visible behaviour of that commit was unpinned — a
plant deleting the line came back GREEN during review.

Replacing `.disabled(onSelect == nil)` with per-row availability makes that test
red **correctly**: the property it names stops being the property the code has.
Rewrite it to the new rule — a row is disabled when its own id has no arm —
rather than deleting it, and keep both halves it was built with: the condition is
read, not merely present (a `.disabled(false)` plant must stay red), and the
handler's name is derived, not spelled. Say in your report which plants you
re-ran against the rewritten guard.

**Added 2026-10-20, from Task 7's re-review.** This obligation was missing when
Task 8 was given the handler seam earlier the same day: the amendment named the
file to change and not the guard that change invalidates, which is the plan-level
form of the mistake this project has a rule about for comments.

**Interfaces:**
- Consumes: `S3BucketSettings.versioning(ofBucket:)`, `BucketVersioning`, `ConnectionActionContribution` id `s3.versioning`.

- [ ] **Step 1: Write the failing tests**

```swift
@MainActor @Test func aNeverVersionedBucketOffersOnlyEnabling() {
    // Review Focus 4: "suspend" means nothing on a bucket that never kept
    // versions, and offering it would ask for a call that cannot be made.
    let model = BucketVersioningModel(current: .never)
    #expect(model.offeredStates == [.enabled])
}

@MainActor @Test func anEnabledBucketCanBeSuspendedAndNotUnset() {
    let model = BucketVersioningModel(current: .enabled)
    #expect(model.offeredStates == [.suspended])
}

@MainActor @Test func suspendingSaysWhatItDoesNotDo() {
    let model = BucketVersioningModel(current: .enabled)
    #expect(model.warningKey == "s3.versioning.suspendKeepsVersions")
}
```

- [ ] **Step 2: Run them and watch them fail**

Run: `swift test --filter BucketVersioningSheetTests`
Expected: FAIL — `cannot find 'BucketVersioningModel' in scope`.

- [ ] **Step 3: Implement the model and the sheet**

The sheet shows the current state, the one state it can move to, and the warning that suspension keeps every stored version and its cost.

- [ ] **Step 4: Wire the contribution id**

In `ContentView+MenuActions.swift`, beside the existing `s3.presignedURL` arm.

- [ ] **Step 5: Run the tests, add the catalogue entries, commit**

Run: `swift test --filter BucketVersioningSheetTests`

```bash
git commit -m "feat(app): turn a bucket's versioning on, and say what suspending keeps"
```

---

### Task 9: The CORS sheet, form and text

**Files:**
- Create: `Sources/MacSCPAppKit/BucketCORSSheet.swift`
- Modify: `Sources/MacSCPAppKit/ConnectionActionRoute.swift`,
  `ContentView+MenuActions.swift`, `ContentView.swift`,
  `ContentView+Sheets.swift` (**added 2026-10-20** — see "Wiring" below)
- Test: `Tests/macSCPAppKitTests/BucketCORSSheetTests.swift`,
  `Tests/macSCPAppKitTests/BoundedViewRegistry.swift`

**Wiring, added 2026-10-20 — without it this task builds a sheet nothing opens.**
Task 8 built the dispatcher: `ConnectionActionRoute` is a `String`-raw enum whose
`switch` in `handleConnectionAction` has **no `default`**, so adding a case
without an arm does not compile. Add the case, its arm, and the sheet's
presentation the way Task 8 did for `s3.versioning` —
`ConnectionActionRoute.swift` (the case), `ContentView+MenuActions.swift` (the
arm), `ContentView.swift` (the sheet item), `ContentView+Sheets.swift` (the
presentation) — plus the `BoundedViewRegistry` entries and the
`BoundedViewCoverageTests` floor, which Task 8 also had to raise. Until the case
exists the row stays disabled, which is correct but is not this task's
deliverable.

This is the third and fourth instance of one plan defect: Task 7 shipped a menu
with no handler (review I2), Task 11's gate had no caller (review I3), and
Tasks 9 and 11 each listed a sheet and its test and nothing that opens them.
A rule, a view or a seam with no caller is the same defect wearing different
clothes, and this plan produced it four times.


**Interfaces:**
- Consumes: `CORSRule`, `CORSValidation`, `S3BucketSettings.cors(ofBucket:)`.

- [ ] **Step 1: Write the failing tests**

```swift
@MainActor @Test func theFormAndTheTextShowTheSameRules() throws {
    let model = BucketCORSModel(rules: [.init(id: "r", allowedOrigins: ["*"],
        allowedMethods: ["GET"], allowedHeaders: [], exposeHeaders: [], maxAgeSeconds: 60)])
    #expect(try S3SettingsXML.parseCORS(Data(model.text.utf8)) == model.rules)
}

@MainActor @Test func anInvalidMethodBlocksSavingAndNamesItself() {
    let model = BucketCORSModel(rules: [])
    model.text = "<CORSConfiguration><CORSRule><AllowedOrigin>*</AllowedOrigin>"
        + "<AllowedMethod>FETCH</AllowedMethod></CORSRule></CORSConfiguration>"
    #expect(model.canSave == false)
    #expect(model.problem == .methodNotAllowed("FETCH"))
}

@MainActor @Test func aConfigurationTheFormCannotShowDisablesTheForm() {
    // The honest edge (spec §6.3). Measured as near-unreachable — the store
    // refuses undocumented elements — so this is the fallback, not the norm.
    let model = BucketCORSModel(rules: [])
    model.text = "<CORSConfiguration><CORSRule><AllowedOrigin>*</AllowedOrigin>"
        + "<AllowedMethod>GET</AllowedMethod><Unknown>x</Unknown></CORSRule></CORSConfiguration>"
    #expect(model.formIsAvailable == false)
    #expect(model.formUnavailableReasonKey == "s3.cors.formCannotShowThis")
}
```

- [ ] **Step 2: Run them and watch them fail**

Run: `swift test --filter BucketCORSSheetTests`
Expected: FAIL — `cannot find 'BucketCORSModel' in scope`.

- [ ] **Step 3: Implement the model and the sheet**

Two panes behind one segmented control, built with `SegmentedChoice` from `RigidControls.swift` so the control cannot be squeezed. Editing either pane updates the other; the text is the source of truth, and the form disables itself when the text holds something it cannot represent.

- [ ] **Step 4: Run the tests, catalogue entries, commit**

```bash
git commit -m "feat(app): edit a bucket's CORS rules as fields or as text"
```

---

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

### Task 11: The create-bucket sheet

**Files:**
- Create: `Sources/MacSCPAppKit/CreateBucketSheet.swift`
- Modify: `Sources/MacSCPAppKit/ConnectionActionRoute.swift`,
  `ContentView+MenuActions.swift`, `ContentView.swift`,
  `ContentView+Sheets.swift`, `ContentView+Lifecycle.swift` (the row's
  availability — see the gate note below) (**added 2026-10-20**)
- Test: `Tests/macSCPAppKitTests/CreateBucketSheetTests.swift`,
  `Tests/macSCPAppKitTests/BoundedViewRegistry.swift`

**Wiring, added 2026-10-20 — without it this task builds a sheet nothing opens.**
Task 8 built the dispatcher: `ConnectionActionRoute` is a `String`-raw enum whose
`switch` in `handleConnectionAction` has **no `default`**, so adding a case
without an arm does not compile. Add the case, its arm, and the sheet's
presentation the way Task 8 did for `s3.versioning` —
`ConnectionActionRoute.swift` (the case), `ContentView+MenuActions.swift` (the
arm), `ContentView.swift` (the sheet item), `ContentView+Sheets.swift` (the
presentation) — plus the `BoundedViewRegistry` entries and the
`BoundedViewCoverageTests` floor, which Task 8 also had to raise. Until the case
exists the row stays disabled, which is correct but is not this task's
deliverable.

This is the third and fourth instance of one plan defect: Task 7 shipped a menu
with no handler (review I2), Task 11's gate had no caller (review I3), and
Tasks 9 and 11 each listed a sheet and its test and nothing that opens them.
A rule, a view or a seam with no caller is the same defect wearing different
clothes, and this plan produced it four times.


**Interfaces:**
- Consumes: `S3BucketName.problem(with:)`, `createBucket(_:protection:)`, Task 6's empty-account connect, and Task 8's per-row availability hook in `ContentView+Lifecycle.swift`. (**Corrected 2026-10-19:** first read `createBucket(_:versioning:objectLock:)` — see Task 5. **Extended 2026-10-20:** the availability hook, see below.)

**The bucket-list gate needs a consumer, added 2026-10-20 from Task 7's review
(I3).** Spec §6.1 says create bucket is offered in bucket-list mode only, and
this task's `CreateBucketModel.isOffered(rootIsContainerList:)` is that rule —
but as the
plan stood, nothing rendered it: the file list was sheet plus test, and the menu
row had no route to a `RootMode` at all. A rule with no caller is the same
defect as an empty seam.

So this task also supplies the `s3.createBucket` row's availability through the
hook Task 8 builds, and `isOffered(rootIsContainerList:)` is what the hook asks.

**Corrected 2026-10-20, raised by Task 8's implementer against its own work.**
Both signatures above first read `isOffered(rootMode:)`, and the test below first
read `isOffered(rootMode: .bucketList)` / `isOffered(rootMode: .bucket("x"))`.
**The App cannot name a `RootMode` in production code**: `S3FileSystem.RootMode`
is internal to Core, so a plan that asks the App to switch on it asks for
something that does not compile outside a test with `@testable import`. Task 8
built `ConnectionActionContext` with a `rootIsContainerList: Bool` taken from
`RemoteFileSystem.rootIsContainerList` — a member that already exists and that
the App already read **six times across four files** before this task
(`git grep -n 'rootIsContainerList' dda95109 -- 'Sources/MacSCPAppKit/*.swift'`
prints seven lines, one of them a comment at `ContentView+Detail.swift:544`) — so the gate asks the question the App
can actually answer. Note what this costs and what it does not: the predicate no
longer knows WHICH bucket, only whether the root is a list of them, which is all
§6.1's rule needs.

Note this
is a **different** gate from `aNameAlreadyInTheListBlocksTheButton` below: that
one is inside the sheet and refuses a name the account already owns; this one
decides whether the row can be chosen at all. Both are required, and neither
substitutes for the other.

- [ ] **Step 1: Write the failing tests**

```swift
@MainActor @Test func aNameTheStoreWouldRejectBlocksTheButtonAndSaysWhy() {
    let model = CreateBucketModel()
    model.name = "My_Bucket"
    #expect(model.canCreate == false)
    #expect(model.problem == .uppercase)
}

@MainActor @Test func objectLockIsFinalAndTheSheetSaysSo() {
    // The note says Object Lock can never be turned off again and freezes
    // versioning with it — NOT that it can only be set at creation, which
    // spec §6.1 withdrew on 2026-10-19. The honest sentence is "if you say
    // yes, you cannot undo it", not "you must decide now".
    let model = CreateBucketModel()
    #expect(model.objectLockNoteKey == "s3.createBucket.objectLockIsFinal")
}

@MainActor @Test func objectLockImpliesVersioning() {
    let model = CreateBucketModel()
    model.objectLock = true
    #expect(model.versioning == true)
    #expect(model.versioningIsLocked == true)
}

@MainActor @Test func theModelHandsCoreTheOneChoiceCoreAccepts() {
    // **Added 2026-10-21 by the controller, from a pre-dispatch read.** Core
    // deliberately has no pair of `Bool`s here:
    // `createBucket(_:protection:)` takes `BucketProtection`, and its doc
    // comment says why — "two independent `Bool`s would let a caller write
    // the combination that cannot exist", and an earlier shape that took two
    // and refused `objectLock: true, versioning: false` with
    // `.protocolError` was replaced by the enum so the contradiction cannot
    // be written at all.
    //
    // The two tests above reintroduce that pair in the App, which is right
    // — two checkboxes is what the user sees — but nothing above checks
    // which `BucketProtection` reaches Core. The sheet is where the pair is
    // folded back into the one choice, so that is where it is pinned.
    let model = CreateBucketModel()
    #expect(model.protection == .none)
    model.versioning = true
    #expect(model.protection == .versioned)
    model.objectLock = true
    #expect(model.protection == .lockedAndVersioned)
    model.versioning = false          // refused: the lock holds it on
    #expect(model.protection == .lockedAndVersioned)
}

@MainActor @Test func theActionIsOfferedOnlyInBucketListMode() {
    // Author's call, spec §6.1: a bucket made in single-bucket mode would be
    // invisible afterwards.
    #expect(CreateBucketModel.isOffered(rootIsContainerList: true) == true)
    #expect(CreateBucketModel.isOffered(rootIsContainerList: false) == false)
}

@MainActor @Test func aNameAlreadyInTheListBlocksTheButton() {
    // **Added 2026-10-19 from Task 5's review.** MEASURED on the rig: a
    // second `createBucket` of a bucket the key already owns SUCCEEDS, the
    // Object Lock header does not retrofit, and the versioning request DOES
    // take effect. Since `.never` is unrepresentable at the store, that is a
    // one-way door opened on a bucket the user did not mean to touch, and the
    // sheet reports "created".
    //
    // Core cannot tell created-from-already-owned apart on a 200, so the
    // check lives here: this sheet is offered only in bucket-list mode, so it
    // already holds the list and the check costs no request.
    let model = CreateBucketModel(existingNames: ["macscp-seed", "macscp-second"])
    model.name = "macscp-seed"
    #expect(model.canCreate == false)
    #expect(model.problem == nil)            // the NAME is valid; it is taken
    #expect(model.nameIsTakenKey == "s3.createBucket.nameIsTaken")
    model.name = "macscp-third"
    #expect(model.canCreate == true)         // the positive control
}

@MainActor @Test func theRowIsLiveOnlyWhileThePaneIsSHOWINGTheBucketList() {
    // **Added 2026-10-21 by the controller, from a pre-dispatch read.** See
    // "Where `existingNames` comes from" below; this is the gate that makes
    // the taken-name check above mean anything.
    #expect(CreateBucketModel.isOffered(rootIsContainerList: true, paneBucket: nil) == true)
    #expect(CreateBucketModel.isOffered(rootIsContainerList: true, paneBucket: "macscp-seed") == false)
    #expect(CreateBucketModel.isOffered(rootIsContainerList: false, paneBucket: nil) == false)
}
```

**Where `existingNames` comes from, and the trap in it. Added 2026-10-21 by the
controller, from a pre-dispatch read of the wiring.** The taken-name test above
is justified in this plan by the sentence "this sheet is offered only in
bucket-list mode, so it already holds the list and the check costs no request."
That conflates two different things, and the difference is a silent defect.

`rootIsContainerList` is a property of the **connection**, not of where the
remote pane is standing. On such a connection the user can navigate **into** a
bucket, and `session.remote`'s current listing is then that bucket's **objects**,
not the account's buckets. Feeding those as `existingNames` would check a
proposed bucket name against object names: it would let through exactly the
duplicate `createBucket` this test exists to prevent — measured on the rig as a
success that silently opens a one-way door on a bucket the user did not mean to
touch — and would block a valid name that happens to match some object's.

**Ruling: the row is live only while the pane is SHOWING the bucket list**, so
`existingNames` is always the real one and the claim that the check costs no
request stays true. The context already answers this and needs no new field:
`ConnectionActionContext.bucket` returns the first path component when
`rootIsContainerList`, so `rootIsContainerList && bucket == nil` means "the pane
is at the bucket list right now". Hence the signature changes to
`isOffered(rootIsContainerList:paneBucket:)` and the route's arm reads
`context.settings != nil && context.rootIsContainerList && context.bucket == nil`.

The alternative — offer the row anywhere on a bucket-list connection and fetch
the bucket list for the check — costs a request and makes this plan's own
"costs no request" false. It was not taken. Spec §6.1's reason for the gate
(a bucket made in single-bucket mode would be invisible) is untouched by this:
it argues about the connection, and narrowing to the pane only narrows further.

**And the arm you will be tempted to copy is the wrong one.** All three existing
arms in `ConnectionActionRoute.isAvailable(in:)` read
`context.settings != nil && context.bucket != nil`, because each is a
**bucket-level** action and `bucket` is `nil` at the list. This row is the
inverse: it is live exactly where they are dead. Copying a neighbouring arm
gives a row that can never be chosen — a view with no reachable route, which is
the defect this plan has already produced seven times. Task 8's implementer saw
it coming and left the note in that function's own doc comment: "a later row's
condition (a bucket-list-only gate) is an arm of its own."

The four rows then partition cleanly: versioning, CORS and Object Lock live
inside a bucket; create-bucket lives at the list. A test that asserts no two of
the four are live at the same place would say that, and is worth writing.

**A sentence Task 10 already ships depends on this task landing, carried here
2026-10-21 from Task 10's review (Minor).** `s3.objectLock.notEnabledOnThisBucket`
reads, in `en`:

> "Object Lock is not switched on for this bucket, so nothing in it can be
> locked. macSCP does not switch it on for a bucket that already exists; it can
> be chosen when a bucket is created."

Its last clause is a promise about a choice that does not exist yet. It becomes
true when this task's Object Lock checkbox lands, and it is wrong in every build
until then — Task 10's reviewer raised it as a Minor and I deferred it to here
rather than hedging a sentence that is about to be correct. So: when the checkbox
exists, check that clause against what the sheet actually offers, in all four
catalogues, and say in your report that you did. If this task's checkbox ends up
spelled differently from what that sentence describes, the sentence is the thing
that moves.

- [ ] **Step 2–5: Red, implement, catalogue entries, commit**

Run: `swift test --filter CreateBucketSheetTests`

```bash
git commit -m "feat(app): create a bucket, with the two switches that are final"
```

---

### Task 11b: The versioning switch does not offer what Object Lock forbids

**Added 2026-10-21 by the controller, from a pre-dispatch read of the tree
before Task 11.** Task 8's `BucketVersioningModel.offeredStates` returns
`[.suspended]` for `.enabled` unconditionally
(`Sources/MacSCPAppKit/BucketVersioningSheet.swift`, the `offeredStates`
symbol). Spec §4 says of a bucket with Object Lock that "once on it can never
be turned off and versioning can never be suspended again" — sourced to AWS's
own configuration guide, not measured here. So on a lock-bearing bucket the
sheet offers the one action the spec says cannot succeed, and the user learns
it from a store refusal rather than from macSCP.

This is not a new rule. It is the rule Task 8's own first test already states,
quoted verbatim from its comment: "'suspend' means nothing on a bucket that
never kept versions, and offering it would ask for a call that cannot be
made." Task 8 applied it to the never-versioned case and not to the
lock-bearing one, because when Task 8 ran nothing in the App could answer
"does this bucket have a lock". Task 10 built that answer:
`ObjectLockStateCache`, owned by the session.

Spec §6.2 is silent on Object Lock, which is why the plan inherited the gap;
§4 is where the fact lives. The task is small and is scheduled after Task 11
rather than folded into it, because Task 11's subject is a different sheet and
its dispatch is already large.

**Files:**
- Modify: `Sources/MacSCPAppKit/BucketVersioningSheet.swift`, the four
  `Localizable.strings` catalogues, and the sheet's call site (whichever of
  `ContentView+Sheets.swift` / `ContentView.swift` constructs
  `BucketVersioningModel` — read it, do not assume).
- Test: `Tests/macSCPAppKitTests/BucketVersioningSheetTests.swift`,
  `Tests/macSCPAppKitTests/BoundedViewRegistry.swift`

**Interfaces:**
- Consumes: Task 10's `ObjectLockStateCache` and
  `BrowserSession.objectLockStates` — read both before writing anything; the
  cache's method is `hasObjectLock`, and it is the member that is `false` only
  on the store's 404, never on another failure.

- [ ] **Step 1: Write the failing tests**

```swift
@MainActor @Test func aLockBearingBucketIsNotOfferedSuspension() {
    let model = BucketVersioningModel(current: .enabled, bucketHasObjectLock: true)
    #expect(model.offeredStates == [])
    #expect(model.blockedReasonKey == "s3.versioning.objectLockKeepsItOn")
}

@MainActor @Test func aBucketWithoutALockIsStillOfferedSuspension() {
    // The positive control. Without it the test above passes on a model that
    // offers nothing to anybody.
    let model = BucketVersioningModel(current: .enabled, bucketHasObjectLock: false)
    #expect(model.offeredStates == [.suspended])
    #expect(model.blockedReasonKey == nil)
}

@MainActor @Test func anUnreadLockStateOffersNothingAndSaysNothingAboutLocks() {
    // The third state is the one that bites: the cache has not answered yet.
    // Offering suspension here would be the old behaviour under a new name,
    // and naming Object Lock here would assert a fact nobody has read.
    let model = BucketVersioningModel(current: .enabled, bucketHasObjectLock: nil)
    #expect(model.offeredStates == [])
    #expect(model.blockedReasonKey == nil)
}

@MainActor @Test func enablingIsNeverBlockedByALock() {
    // A never-versioned bucket cannot carry a lock, but a suspended one that
    // somehow reads as locked must still be offered the way back ON.
    for lock in [true, false] {
        let suspended = BucketVersioningModel(current: .suspended, bucketHasObjectLock: lock)
        #expect(suspended.offeredStates == [.enabled])
    }
}
```

- [ ] **Step 2: Run them and watch them fail**

Run: `swift test --filter BucketVersioningSheetTests`
Expected: FAIL — `BucketVersioningModel` has no `bucketHasObjectLock:`
parameter. Quote the compiler's line verbatim in the report.

- [ ] **Step 3: Make the parameter explicit at every construction site**

`bucketHasObjectLock` is a `Bool?`, and it takes **no default value**. Count
the construction sites first and spell it at each one — that is the same
ruling the controller made for `BackendDescriptor.connectionActions`, and for
the same reason: a default is what lets a new call site silently keep the old
behaviour. Write the count into the report beside the command that produced
it.

- [ ] **Step 4: Add the catalogue entry in all four languages**

`s3.versioning.objectLockKeepsItOn`. It says what is true and no more: this
bucket uses Object Lock, so its versioning cannot be switched off. It must
**not** claim the store refuses it — the fact is AWS's documentation, not a
measurement from this project's rig, and the spec marks it that way.
German in du-form.

- [ ] **Step 5: Wire the call site to the session's cache**

The sheet's opener reads `BrowserSession.objectLockStates` for the bucket. A
state not yet read is `nil`, not `false` — the whole point of the third test.
Do not add a blocking read to open the sheet.

**The two reads must land together, or the sheet has a window in which it
offers nothing and explains nothing.** `offeredStates` is already `[]` while
`current` is `nil`, and the sheet shows its action only once the versioning
read returns; if the lock read returns later, the user sees a loaded sheet
whose only button has vanished for no stated reason. Fold the lock read into
the same load as the versioning read — one `load` state covering both — rather
than letting a second answer arrive after the sheet has settled. Decide this
by reading the opener; the plan does not know which shape that file wants.

- [ ] **Step 6: Probe it**

Two plants through `scripts/mutation-probe`, on a committed tree: the lock
check removed from `offeredStates`, and `nil` treated as `false`. Both must go
RED, and the second is the one a careless fix leaves green.

- [ ] **Step 7: Run the tests and commit**

```bash
git commit -m "fix(app): a bucket under Object Lock is not offered a suspension it cannot have"
```

---

### Task 12: The audit trail

**Files:**
- Modify: `Sources/macSCPCore/Sessions/AuditEvent.swift`, `AuditRecorder.swift`, catalogues ×4
- Modify, **added 2026-10-21** — the App side, without which this task has no
  caller: the sites that apply each of the five operations. Read them; the plan
  does not name a line, because they moved in Tasks 8–11.
- Test: `Tests/macSCPAppKitTests/` — the existing `everyKindHasACatalogLabel` guard covers the new kinds

**This task had no caller, found 2026-10-21 by a pre-dispatch read.** The file
list above first named Core and the catalogues only, and the existing audit
sink does not reach these operations. `auditSink` is declared in exactly two
places, both in Core's Presentation layer —
`RemoteBrowserViewModel.auditSink` and `TransferQueueViewModel.auditSink`
(`grep -rn "auditSink" Sources/macSCPCore/`) — and the App wires the first of
them in one line, `ContentView+Lifecycle.swift`:
`tab.session?.remote.auditSink = { event in recorder.recordAction(event) }`.
The bucket-settings sheets do not go through `RemoteBrowserViewModel`: they
hold an `S3BucketSettings` and call it directly. So no existing sink carries
their events, and a Core-only Task 12 would have added four `Kind` cases and
four recorder methods that nothing calls — **the seventh instance on this
branch of a rule with no caller, and the one where it costs most, since this
task exists to leave a trace of the branch's only irreversible write.**

The App already has the other spelling for a sheet that records directly:
`ContentView.swift` takes `activeTab.auditRecorder` and calls
`recorder?.recordAction(...)`. Follow that, and prefer putting the recorder
where a new apply path **cannot compile without one** over a scan that looks
for the call — this project's rule about a scan that keeps buying one spelling
applies here, and five apply paths is where it starts to.

**Interfaces:**
- Produces: `AuditEvent.Kind` gains `bucketCreated`, `versioningChanged`, `corsChanged`, `objectLockChanged`, and `AuditRecorder` a method per kind.

A COMPLIANCE retention is the most irreversible thing macSCP can do; without this it is the only one leaving no trace (spec §8).

- [ ] **Step 1: Write the failing test**

**Corrected 2026-10-21, before dispatch.** This step first held one test, and
it was the only test of the task:

```swift
@Test func everyNewKindIsRecordedByTheActionThatCausesIt() {
    let recorded = Set(AuditEvent.Kind.allCases.map(\.rawValue))
    #expect(recorded.isSuperset(of: ["bucketCreated", "versioningChanged",
                                      "corsChanged", "objectLockChanged"]))
}
```

Its name claims what it does not check. `AuditEvent.Kind.allCases` contains
the cases the enum declares, so once the four cases are written the assertion
cannot fail — it is a second copy of the declaration, and it stays green on a
tree where not one of the five operations records anything. The name is the
claim the task actually owes, so the test has to be the thing the name says.

Write these instead, and keep the enum check as well — cheap, and it does pin
the raw spellings the catalogue keys are built from:

```swift
@Test func theFourNewKindsAreDeclaredWithTheSpellingsTheCatalogueUses() {
    let declared = Set(AuditEvent.Kind.allCases.map(\.rawValue))
    #expect(declared.isSuperset(of: ["bucketCreated", "versioningChanged",
                                      "corsChanged", "objectLockChanged"]))
}

@MainActor @Test func eachOperationRecordsExactlyOneEventOfItsOwnKind() async throws {
    // One case per operation, five in all: create, versioning, CORS, the
    // per-file retention/legal hold, the bucket default. Each drives the
    // sheet's own apply path against a fake and reads the recorder.
    // Parameterise it over the five rather than writing five bodies.
}

@MainActor @Test func aRefusedOperationRecordsTheFailureAndNotASuccess() async throws {
    // `AuditEvent` already carries `isError` and `errorMessage`; the existing
    // kinds use both. A refused apply must not read as done.
}

@MainActor @Test func anObjectLockLineNamesWhichOfTheThreeOperationsItWas() {
    // `objectLockChanged` covers three things: a per-file retention, a legal
    // hold, and the bucket default. Only one of them is irreversible, so a
    // trail in which they are indistinguishable does not do the job spec §8
    // asks of it. The kind cannot separate them; the detail must.
    //
    // A COMPLIANCE retention's line names the mode and the date. This is the
    // one assertion in the task that the maintainer's 2026-10-19 decision
    // rests on.
}
```

- [ ] **Step 2: Run it, watch it fail, implement, run the catalogue guard**

Run: `swift test --filter "Audit|everyKindHasACatalogLabel"`

**No detail in an audit line may be the store's words or carry a secret.** The detail is the bucket name and the action, both macSCP's own values.

**Added 2026-10-21:** a detail is also read back by a test, and `#expect`
prints the source text of the expression it checks, so a value that must not
leak goes in a named constant with the `Bool` computed before the
expectation. Nothing in these five operations is a secret — a bucket name, a
key, a mode, a date — but the rule binds the shape of the test either way,
and an access key must never reach a line through an error message copied
from a refusal.

- [ ] **Step 3: Commit**

```bash
git commit -m "feat(core): record the bucket settings in the audit trail"
```

---

### Task 13: Closeout — docs, backlog, and the rig's leftover

**Files:**
- Modify: `docs/BACKLOG.md` (the s3Manager wishlist row, and the row Task 6's
  fix round opened for the unreachable `bucketListEmpty`)
- Modify: `docs/superpowers/specs/2026-09-02-s3-bucket-browser-design.md` (§2
  table, row 2 — see Step 4)
- Create: a page under `/Users/noidee/_dev/noix-docs/src/content/docs/macscp/guide/`

- [ ] **Step 1: Write the user documentation**

One page covering what the new menu does, in plain language, **with no tech-stack terms**. Work in a git worktree on its own branch in `noix-docs`; never touch a branch someone else has open; push or merge only when the maintainer asks. `npm run build` and `npm run check` must both pass.

- [ ] **Step 2: Correct the backlog row in place**

Move create bucket, CORS, Object Lock and versioning from "Missing" to done, naming the commits. **Every withdrawal quotes the wording it replaces.** State what is still missing: metadata editor, ACLs, sync, the version history, and the connection-manager surface.

- [ ] **Step 3: Record the rig's leftover**

A row for `macscp-probe-lock` — the bucket left on the rig under a COMPLIANCE retention until 2026-12-31 — naming that a gated test asserting on the bucket **list** will see it until the volume is reset.

- [ ] **Step 4: Record what Task 6 made unreachable**

**Added 2026-10-19, from Task 6's review.** Task 6 removed the only thrower of
`RemoteFSError.bucketListEmpty`, so three kinds of artifact now describe an
outcome that cannot occur, and this task's file list did not cover any of them:

- `docs/superpowers/specs/2026-09-02-s3-bucket-browser-design.md:44` (§2 table,
  row 2) — a measurement record, so the correction quotes the wording it
  replaces rather than deleting it.
- The four `core.connect.s3BucketListEmpty` catalogue strings (`en`, `de`, `fr`,
  `pl`). **They are not deleted.** The enum case still has consumers — the CLI
  mapping, `DialProbes`, two view models, `TransferFailureKind`, two AppKit
  files — and the localization parity checks read every key a case declares.
  Deleting the strings while the case stands breaks the parity suite; deleting
  the case is a separate decision with its own review.
- The **six** comment sites that describe the case, which Task 6's fix round put
  in a `docs/BACKLOG.md` row rather than in a report only. This step checks that
  row still names them, and corrects it if the count has moved.

  **Corrected 2026-10-20, by Task 6's re-review and verified by the
  controller.** This bullet first read "The five comment sites naming `connect`
  as the case's single thrower". Both halves were wrong. The count was five when
  this bullet was written and became six in the same fix round, which found an
  older site the two reviews had missed (`RemoteFSError.swift` near line 16).
  And "naming `connect` as the case's single thrower" is literally true of only
  two of them — `ConnectionViewModel.swift` near 2310 ("`.bucketListEmpty` is
  connect-time only — `connect` is its single thrower") and
  `RemoteBrowserViewModel.swift` near 1278. The others make different claims:
  near 2307 it is reachability ("both reachable ONLY with `startsAtBucketList`
  on"), near 2319 it is a true description of an arm that is now dead, and
  `RemoteFSError.swift` near 24 describes what the case meant at the form. They
  are all stale, for different reasons, which is why the row names each by its
  opening words rather than under one heading.

The row records the decision, not a fix: keep the case or delete it with its
consumers in one pass. Either way the comments go with it.

- [ ] **Step 5: Pin the census section's live figure to a commit**

**Added 2026-10-19, measured by the controller while closing Task 6.** The
closing census section of `docs/BACKLOG.md` prints three comparable outputs. Two
name a commit and reproduce exactly — re-run on this date they still print
`opens-Open=90 shown=47 hidden=43` and `opens-Open=94 shown=51 hidden=43`, the
recorded figures. The third runs the same `awk` over the live `docs/BACKLOG.md`
and is recorded as `opens-Open=95 shown=52 hidden=43` with no date and no commit
beside it. Run as committed, that third command now prints
`docs/BACKLOG.md opens-Open=137 shown=92 hidden=45`.

So the one figure in that section a reader can check against the working tree is
the one that contradicts it, by 42. **39 of those 42 predate this branch**: the
same command over this branch's base prints `opens-Open=134 shown=89 hidden=45`.
Three are this branch's own rows, one of them Task 6's.

Pin it: give that third line a commit of its own, exactly as its two neighbours
have, and quote the withdrawn bare figure. Do **not** re-sweep the section's row
numbers — the section already names those as stale and says the fix "is a sweep
of its own", and that remains true.

- [ ] **Step 6: Open a row for the warning gate's macro-expansion blind spot**

**Added 2026-10-20, measured by the controller from Task 7's review (I4).** Seven
warnings exist in the Core test target at four sites —
`S3CreateBucketTests.swift:54:49`, `:65:56`, `:84:51` and
`ArchiveRunnerTests.swift:82:76`. They appear on the **default** build system,
measured cold into a fresh scratch path with no `--build-system` flag:

    swift build --target macSCPCoreTests --scratch-path <fresh dir>

`grep -c 'warning:'` over that log prints 14 (each diagnostic twice: once in the
caret diagram, once as its own header), and
`grep -o 'macro expansion #expect:1:[0-9]*' | sort -u | wc -l` prints 7.

CI's gate matches **none** of them. Its pattern is
`^[^[:space:]]+:[0-9]+:[0-9]+: warning:` (`.github/workflows/ci.yml`, the
"Unique warning locations" step), and neither route reaches it:

- The warning's own location is `macro expansion #expect:1:46:` — it contains a
  space, so `[^[:space:]]+` cannot match it.
- The real source location appears only on a `note: expanded code originates
  here` line, which says `note:` and not `warning:`, and begins with a backtick
  and a hyphen rather than a path.

**Corrected 2026-10-20 by Task 8's review, which found a second and more general
cause.** This step first read: "So `MAX_WARNINGS: 0` was never at risk from
these — but the reason is that the gate cannot see a diagnostic reported against
a macro-expansion buffer, and in this repository every test assertion is
`#expect`." That mechanism is real and still stands for this class of warning,
but it is not the only one, and the one it hid is worse.

**The compiler colours its diagnostics even when stdout is a file or a pipe**, so
an ordinary warning line reads `…:82:43: <ESC>[1;33mwarning: …` and the gate's
pattern, which expects `warning:` directly after the location, matches none of
them. Task 8's review measured four actor-isolation warnings in the AppKit test
target that way: **0 of 4** matched on the raw log and **4 of 4** only after
`perl -pe 's/\e\[[0-9;]*m//g'`. CI captures the same way
(`2>&1 | tee "$RUNNER_TEMP/test.log"`, `.github/workflows/ci.yml:123-124`).

The two causes are independent and hit different classes:

- An **ordinary** diagnostic is invisible because of the colour escape. Stripping
  ANSI makes it visible.
- A **macro-expansion** diagnostic is invisible for a second reason on top:
  its location is `macro expansion #expect:1:46:`, which contains a space, and
  the line carrying the real file says `note:` rather than `warning:`. Measured
  on the controller's Core-target log: the gate's pattern matches **0** raw and
  still **0** after stripping ANSI.

So, locally, the gate cannot see a compiler diagnostic at all. **Whether CI's
logs are coloured was not measured** — the reviewer says so explicitly — and
that is the first thing the row's investigation should settle, because it decides
whether `MAX_WARNINGS: 0` has ever held anything. What does not change either
way: the branch is pushable, since nothing it adds matches the gate however the
gate behaves.

Open the row with the commands above and both mechanisms; **do not fix the
warnings and do not edit `ci.yml` in this plan** — the gate's pattern is its own
change with its own review, and it is now a larger change than this step first
implied.

- [ ] **Step 7: Open the Core rows Task 9's review earned**

**Added 2026-10-20 from Task 9's review.** Three findings land in Core, which
Task 9's brief excluded, so each is a row rather than a late edit to a reviewed
task. All three are about `S3SettingsXML` / `CORSRule`:

1. **Move the lossy-parse check into Core.** Task 9 detects a lossy CORS parse in
   the App by re-serializing the parsed rules and comparing element-name and
   attribute-name counts (`ElementCensus`). The reviewer verified the mechanism
   against `CORSDelegate` and 28 constructed inputs — every element `corsBody`
   writes maps injectively back to a distinct consumed element, so equality holds
   **iff every element was consumed**, which is the property itself rather than a
   proxy for it. The problem is where it lives: its correctness depends on
   `CORSDelegate`'s depth bookkeeping one target away, so a change to `parseCORS`
   can falsify the App's check with nothing going red. That is this project's
   "comments that describe other code" failure with a scan standing in for the
   comment. Preferred shape, from the review: one Core function
   `S3SettingsXML.parseCORSReportingLoss(_:) -> (rules, isLossless)`, census
   private inside it, tested beside `S3CORSTests`.
2. **`corsBody` is documented as `parseCORS`'s inverse and is not, for a value
   holding a carriage return.** `<AllowedOrigin>a&#13;b</AllowedOrigin>` parses to
   `a\rb` and re-serializes as `a\nb`. Task 9 closes the user-visible half by
   asserting `parseCORS(canonical) == rules` beside the census; the doc comment's
   claim is still too strong and the asymmetry is Core's.
3. **`CORSRule.validate()` has no range check**, so a negative `MaxAgeSeconds`
   passes the pre-send gate and is refused by the store instead — the one place
   this sheet's validation is less strict than the thing it is protecting the
   user from.

- [ ] **Step 8: Run the full suite and both gated suites**

Run: `swift test`
Run: `MACSCP_ITEST=1 swift test`

- [ ] **Step 9: Commit**

```bash
git commit -m "docs: close the bucket-settings half of the s3Manager row"
```
