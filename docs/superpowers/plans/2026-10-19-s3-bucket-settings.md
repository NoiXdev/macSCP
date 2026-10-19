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

Every existing `BackendDescriptor(...)` construction gains `connectionActions:`. A synthetic descriptor exists in `SchemaConformanceTests` and needs it too.

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
- Test: `Tests/macSCPAppKitTests/BucketVersioningSheetTests.swift`

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
- Test: `Tests/macSCPAppKitTests/BucketCORSSheetTests.swift`

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
    #expect(probe.objectLockDefaultCalls == 1)
    _ = try await cache.hasObjectLock("other")
    #expect(probe.objectLockDefaultCalls == 2)
}
```

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
- Test: `Tests/macSCPAppKitTests/CreateBucketSheetTests.swift`

**Interfaces:**
- Consumes: `S3BucketName.problem(with:)`, `createBucket(_:protection:)`, Task 6's empty-account connect. (**Corrected 2026-10-19:** first read `createBucket(_:versioning:objectLock:)` — see Task 5.)

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

@MainActor @Test func theActionIsOfferedOnlyInBucketListMode() {
    // Author's call, spec §6.1: a bucket made in single-bucket mode would be
    // invisible afterwards.
    #expect(CreateBucketModel.isOffered(rootMode: .bucketList) == true)
    #expect(CreateBucketModel.isOffered(rootMode: .bucket("x")) == false)
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
```

- [ ] **Step 2–5: Red, implement, catalogue entries, commit**

Run: `swift test --filter CreateBucketSheetTests`

```bash
git commit -m "feat(app): create a bucket, with the two switches that are final"
```

---

### Task 12: The audit trail

**Files:**
- Modify: `Sources/macSCPCore/Sessions/AuditEvent.swift`, `AuditRecorder.swift`, catalogues ×4
- Test: `Tests/macSCPAppKitTests/` — the existing `everyKindHasACatalogLabel` guard covers the new kinds

**Interfaces:**
- Produces: `AuditEvent.Kind` gains `bucketCreated`, `versioningChanged`, `corsChanged`, `objectLockChanged`, and `AuditRecorder` a method per kind.

A COMPLIANCE retention is the most irreversible thing macSCP can do; without this it is the only one leaving no trace (spec §8).

- [ ] **Step 1: Write the failing test**

```swift
@Test func everyNewKindIsRecordedByTheActionThatCausesIt() {
    let recorded = Set(AuditEvent.Kind.allCases.map(\.rawValue))
    #expect(recorded.isSuperset(of: ["bucketCreated", "versioningChanged",
                                      "corsChanged", "objectLockChanged"]))
}
```

- [ ] **Step 2: Run it, watch it fail, implement, run the catalogue guard**

Run: `swift test --filter "Audit|everyKindHasACatalogLabel"`

**No detail in an audit line may be the store's words or carry a secret.** The detail is the bucket name and the action, both macSCP's own values.

- [ ] **Step 3: Commit**

```bash
git commit -m "feat(core): record the bucket settings in the audit trail"
```

---

### Task 13: Closeout — docs, backlog, and the rig's leftover

**Files:**
- Modify: `docs/BACKLOG.md` (the s3Manager wishlist row)
- Create: a page under `/Users/noidee/_dev/noix-docs/src/content/docs/macscp/guide/`

- [ ] **Step 1: Write the user documentation**

One page covering what the new menu does, in plain language, **with no tech-stack terms**. Work in a git worktree on its own branch in `noix-docs`; never touch a branch someone else has open; push or merge only when the maintainer asks. `npm run build` and `npm run check` must both pass.

- [ ] **Step 2: Correct the backlog row in place**

Move create bucket, CORS, Object Lock and versioning from "Missing" to done, naming the commits. **Every withdrawal quotes the wording it replaces.** State what is still missing: metadata editor, ACLs, sync, the version history, and the connection-manager surface.

- [ ] **Step 3: Record the rig's leftover**

A row for `macscp-probe-lock` — the bucket left on the rig under a COMPLIANCE retention until 2026-12-31 — naming that a gated test asserting on the bucket **list** will see it until the volume is reset.

- [ ] **Step 4: Run the full suite and both gated suites**

Run: `swift test`
Run: `MACSCP_ITEST=1 swift test`

- [ ] **Step 5: Commit**

```bash
git commit -m "docs: close the bucket-settings half of the s3Manager row"
```
