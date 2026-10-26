# S3 Metadata, ACL Display and the Connection Manager's Bucket Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Edit an object's metadata (saying what that costs), read its ACL without pretending to write one, and let a stored connection create a bucket.

**Architecture:** A second optional capability, `ObjectMetadataProvider`, queried with `as?`; `S3FileSystem` conforms beside its other two conformances. Metadata is written the only way S3 allows — a `REPLACE` copy of the object onto itself — and read back with a second `HEAD` before success is reported. The ACL half is read-only by measurement, not by caution. The connection manager gets exactly one entry, which opens a real tab rather than inventing a second owner of session state.

**Tech Stack:** Swift 6 (`.swiftLanguageMode(.v6)`), SwiftPM, Swift Testing, SwiftUI/AppKit, macOS 15 floor. No new dependency.

**Spec:** `docs/superpowers/specs/2026-10-23-s3-version-history-and-metadata-design.md` (goals 5–7, §§6.4–6.6, §11.2)

**Runs after** `2026-10-23-s3-version-history.md` (Plan A), which commits the spec into the tree and adds the `metadataChanged` audit kind this plan records with.

## Global Constraints

Identical to Plan A's, and they bind every task here too. Repeated in full because a task's implementer sees one plan:

- Swift 6 strict, all targets `.swiftLanguageMode(.v6)`, minimum macOS 15, no new dependency.
- `swift test`, **no `--build-system` flag**. Gated suites behind `MACSCP_ITEST=1` (Docker rig, started from the main checkout only).
- TDD red→green; the observed red is quoted verbatim in the commit body.
- **Every write is read back from the store**, never assumed from a 200. This plan is where that rule earns its keep: spec §4.6 measured a store answering `PUT ?acl` with 200 and keeping nothing.
- **macSCP sends no bypass header**, verbatim from `ObjectLockSheet`: *"macSCP sends no bypass (`S3BucketSettings.setRetention` says so), so within this app a governance retention can be extended and not shortened, and the sheet's own refusal sentence says as much."*
- Never hardcode a display string: `L10n.string(_:_:)` in `MacSCPAppKit`, `CoreL10n.string(_:)` in `macSCPCore`; catalogues `en`/`de`/`fr`/`pl` in both localized targets; the German catalogues address the user as **du**.
- No secret, key, credential, token or endpoint in any store, state, log, `reason:` string, audit `detail`, notification, test name or test failure message. A value a test must not leak lives in a named constant with the `Bool` computed before the expectation.
- Tests never block the cooperative pool: every wait is an `await`.
- No wall-clock ceiling in a test; floors are fine, hang bounds are `.timeLimit`.
- A negative source-scanning check ships with a positive check beside it.
- Conventional Commits; footer `Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>`.
- Commit/push only on explicit request; this plan commits, it does not push.

## Review Focus

1. **A `Grantee` element with no `ID` and no `DisplayName`** — measured on the rig (spec §4.6). It renders as an honest "the store named no holder", never as a blank row. Task 3.
2. **A store that answers `?acl` or `?ownershipControls` with `501`** — "this store does not offer this", not an error banner and not an auth failure. Task 2.
3. **A metadata write on a bucket whose default retention is COMPLIANCE** — the acknowledgement runs first, and declining it writes nothing. Task 4.
4. **A `REPLACE` copy the store refuses for size** (AWS's 5 GiB single-part ceiling; unmeasured above 8 MiB) — the store's own refusal is surfaced, not swallowed and not retried as multipart. Task 2.
5. **The connection-manager entry on a stored connection in single-bucket mode** — not offered at all, because a bucket created there would be invisible. Task 6.

---

## File Structure

**Core (`Sources/macSCPCore/`)**

- `RemoteFS/ObjectMetadataProvider.swift` — *new*. The capability, `ObjectMetadata`, `ObjectACL`, `ACLGrant`.
- `S3/S3ACLXML.swift` — *new*. Parsing `AccessControlPolicy`; sibling of `S3VersionsXML.swift`.
- `S3/S3FileSystem.swift` — *modify*. Conformance in the extension at the bottom.
- `Capabilities/BackendDescriptor.swift` — *modify*. The `s3.metadata` file action.
- `Sessions/AuditRecorder.swift` — *modify*. The recorder for `metadataChanged` (the kind itself is Plan A's Task 4).

**App (`Sources/MacSCPAppKit/`)**

- `ObjectMetadataSheet.swift` — *new*. The editor, its model, and the read-only ACL section.
- `SessionSidebar.swift` — *modify*. One context-menu entry on a stored S3 connection.
- `ContentView+Sheets.swift`, `ContentView+MenuActions.swift` — *modify*. Presentation and routing.
- Resources `en`/`de`/`fr`/`pl` `.lproj/Localizable.strings` in **both** localized targets.

---

### Task 1: `ObjectMetadataProvider` and its types

**Files:**
- Create: `Sources/macSCPCore/RemoteFS/ObjectMetadataProvider.swift`
- Test: `Tests/macSCPCoreTests/ObjectMetadataProviderTests.swift`

**Interfaces:**
- Produces:
  ```swift
  public struct ObjectMetadata: Sendable, Equatable {
      public var contentType: String?
      public var cacheControl: String?
      public var contentDisposition: String?
      /// Keys WITHOUT the `x-amz-meta-` prefix, which is transport.
      public var custom: [String: String]
      public let entityTag: String?
  }

  public struct ACLGrant: Sendable, Equatable {
      public let granteeID: String?
      public let granteeDisplayName: String?
      public let permission: String
      /// True when the store named a grant but no holder (measured on the rig,
      /// spec section 4.6). A UI must say so rather than draw a blank row.
      public var holderIsUnnamed: Bool { granteeID == nil && granteeDisplayName == nil }
  }

  public struct ObjectACL: Sendable, Equatable {
      public let ownerID: String?
      public let ownerDisplayName: String?
      public let grants: [ACLGrant]
  }

  public protocol ObjectMetadataProvider: Sendable {
      func metadata(ofKey key: String, inBucket bucket: String) async throws -> ObjectMetadata
      /// Replaces `key`'s metadata and reads it back; throws rather than
      /// reporting success it could not confirm.
      func setMetadata(_ metadata: ObjectMetadata, ofKey key: String, inBucket bucket: String) async throws
      /// `nil` when the store does not offer ACLs at all (`501`).
      func acl(ofKey key: String, inBucket bucket: String) async throws -> ObjectACL?
  }
  ```
  There is **no** `setACL`. Spec §3 says why, and a guard test in Task 3 holds the protocol to it.

- [ ] **Step 1: Write the failing test**

```swift
@Test func aGrantWithNeitherIdNorNameHasAnUnnamedHolder() {
    let g = ACLGrant(granteeID: nil, granteeDisplayName: nil, permission: "FULL_CONTROL")
    #expect(g.holderIsUnnamed)
}

@Test func customMetadataKeysCarryNoTransportPrefix() {
    let m = ObjectMetadata(
        contentType: nil, cacheControl: nil, contentDisposition: nil,
        custom: ["note": "x"], entityTag: nil)
    let carriesPrefix = m.custom.keys.contains { $0.hasPrefix("x-amz-meta-") }
    #expect(carriesPrefix == false)
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter ObjectMetadataProviderTests`
Expected: FAIL — `cannot find 'ACLGrant' in scope`

- [ ] **Step 3: Write the file with the four types above**

Doc comments in `S3BucketSettings.swift`'s register. The protocol header states why ACL has no write, quoting spec §4.6's measurement, and why reading the ACL lives in this protocol rather than a third one.

- [ ] **Step 4: Run to verify it passes**

- [ ] **Step 5: Commit**

```bash
git add Sources/macSCPCore/RemoteFS/ObjectMetadataProvider.swift Tests/macSCPCoreTests/ObjectMetadataProviderTests.swift
git commit -m "feat(core): an optional capability for an object's metadata and ACL"
```

---

### Task 2: `S3FileSystem` reads and replaces metadata, reads the ACL

**Files:**
- Create: `Sources/macSCPCore/S3/S3ACLXML.swift`
- Modify: `Sources/macSCPCore/S3/S3FileSystem.swift`
- Test: `Tests/macSCPCoreTests/S3ObjectMetadataTests.swift`, `Tests/macSCPCoreTests/S3ACLXMLTests.swift`

**Interfaces:**
- Consumes: Task 1; `S3FileSystem.mapErrorStatus` and the existing request signer.
- Produces: `extension S3FileSystem: ObjectMetadataProvider`, and
  ```swift
  enum S3ACLXML { static func parse(_ body: Data, status: Int) throws -> ObjectACL? }
  ```
  returning `nil` for `501`/`NotImplemented`, throwing `mapErrorStatus(...)` otherwise.

- [ ] **Step 1: Write the failing tests**

Fixtures are the bodies spec §4.6 measured, including the one whose `Grantee` is empty.

```swift
@Test func anEmptyGranteeParsesAsAnUnnamedHolderAndNotAsNothing() throws {
    let acl = try #require(try S3ACLXML.parse(Self.ownerOnlyEmptyGrantee, status: 200))
    #expect(acl.grants.count == 1)
    #expect(acl.grants[0].holderIsUnnamed)
    #expect(acl.ownerDisplayName != nil)
}

@Test func aStoreThatDoesNotImplementAclsAnswersNilAndNotAnError() throws {
    // Review Focus 2.
    #expect(try S3ACLXML.parse(Self.notImplementedBody, status: 501) == nil)
}

@Test func replacingMetadataSendsTheReplaceDirectiveAndTheFourFields() async throws {
    // Asserted on the BUILT request: x-amz-metadata-directive: REPLACE,
    // x-amz-copy-source naming the same key, content-type, cache-control,
    // content-disposition, and one x-amz-meta- header per custom pair.
}

@Test func metadataThatCannotBeReadBackIsNotReportedAsWritten() async throws {
    // The store answers 200 and the second HEAD disagrees: setMetadata throws.
}

@Test func aCopyTheStoreRefusesForSizeSurfacesItsOwnRefusal() async throws {
    // Review Focus 4: a stubbed 400/EntityTooLarge reaches the caller as a
    // mapped finding; nothing retries it as a multipart copy.
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --filter 'S3ObjectMetadataTests|S3ACLXMLTests'`
Expected: FAIL — `S3FileSystem` does not conform to `ObjectMetadataProvider`

- [ ] **Step 3: Implement the parser and the three methods**

`setMetadata` is `PUT` onto the same key with `x-amz-copy-source: /<bucket>/<key>`, `x-amz-metadata-directive: REPLACE`, the three typed headers and one `x-amz-meta-<name>` per custom pair; then a second `metadata(ofKey:inBucket:)` whose result must match what was sent, or it throws.

- [ ] **Step 4: Run to verify they pass**

- [ ] **Step 5: Commit**

---

### Task 3: The guard that no ACL write exists

**Files:**
- Test: `Tests/macSCPCoreTests/NoACLWriteGuardTests.swift`

**Interfaces:**
- Consumes: `SourceCorpus` (existing — `text(of:)`, `commentFree(of:)`, `code(of:)`).

**Why a guard and not a comment:** spec §3 removed the ACL write because the rig returns 200 and stores nothing, which is the one failure mode a later contributor cannot see by testing against the rig. A negative check is the only thing that notices it coming back.

- [ ] **Step 1: Write the failing test**

Negative and positive together, per the project's rule:

```swift
@Test func noS3SourceFileSendsAnAclWrite() throws {
    // Comments and string literals blanked, so a comment EXPLAINING the
    // absence cannot satisfy or break the scan.
    let offenders = try S3Sources.all.filter { file in
        let code = try SourceCorpus.code(of: file)
        return code.contains("?acl") || code.contains("x-amz-acl")
    }
    #expect(offenders.isEmpty)
}

@Test func theScanReachesTheFileThatWouldCarryOne() throws {
    // The positive beside it: without this, a renamed or moved S3 directory
    // turns the check above into a comment that runs.
    #expect(S3Sources.all.count >= 5)
    #expect(S3Sources.all.contains { $0.hasSuffix("S3FileSystem.swift") })
}

@Test func theScanCatchesAPlantedAclWrite() throws {
    // Self-test through the scan's own function, on a fixture outside the
    // scanned directory.
    #expect(S3Sources.wouldReject(ObjectACLWriteFixture.source))
}
```

- [ ] **Step 2: Run to verify it fails**, then implement the scan helper, then green.

- [ ] **Step 3: Mutation-probe it**

Run: `scripts/mutation-probe --filter NoACLWriteGuardTests --apply "<a command that plants a ?acl PUT in S3FileSystem.swift>"`
Expected: `RESULT: RED`, naming `noS3SourceFileSendsAnAclWrite`. **Run against a committed tree, and write nothing into the worktree while it runs.**

- [ ] **Step 4: Commit**, quoting the probe's verdict line verbatim.

---

### Task 4: The metadata sheet, with the COMPLIANCE acknowledgement

**Files:**
- Create: `Sources/MacSCPAppKit/ObjectMetadataSheet.swift`
- Modify: `Sources/MacSCPAppKit/ContentView+Sheets.swift`, `Sources/MacSCPAppKit/ContentView+MenuActions.swift`, `Sources/macSCPCore/Capabilities/BackendDescriptor.swift`, `Sources/macSCPCore/Sessions/AuditRecorder.swift`, the four catalogues in both targets
- Test: `Tests/macSCPAppKitTests/ObjectMetadataSheetTests.swift`

**Interfaces:**
- Consumes: Tasks 1–2; `S3BucketSettings.objectLockDefault(ofBucket:)` and `hasObjectLock(ofBucket:)`; Plan A's `metadataChanged` audit kind; the acknowledgement shape in `BucketObjectLockSheet.swift` (read its `acknowledgementStale` / `complianceNotAcknowledged` cases and follow them).
- Produces: `ObjectMetadataModel` with `func load() async`, `func save() async`, and
  ```swift
  enum SaveRefusal: Equatable { case complianceNotAcknowledged, acknowledgementStale, nothingChanged }
  ```
  plus `FileActionContribution(id: "s3.metadata", titleKey: "menu.s3.metadata", titleDefault: "Metadata…")`.

- [ ] **Step 1: Write the failing tests**

```swift
@Test func theSheetSaysAVersionWillBeAddedOnAVersionedBucket() async { … }
@Test func aComplianceDefaultBucketRefusesToSaveWithoutAnAcknowledgement() async {
    // Review Focus 3.
    #expect(await model.save() == .complianceNotAcknowledged)
}
@Test func theAcknowledgementNamesTheDateTheVersionBecomesUndeletable() async { … }
@Test func changingAFieldBackBeforeSavingWritesNothing() async {
    #expect(await model.save() == .nothingChanged)
}
@Test func aGovernanceDefaultBucketNeedsNoAcknowledgement() async { … }
@Test func aBucketWithoutObjectLockReadsNoDefaultAtAll() async {
    // Zero requests on a counting stub — the first half's D1 lesson.
}
@Test func theAuditLineForAMetadataChangeCarriesNoCredential() async {
    // Value in a named constant; the Bool computed before the expectation.
}
```

Layout bound per `BoundedViewLayoutGuardTests`, as the first half's sheets have.

- [ ] **Step 2–4: red, implement, green**

The bucket's Object Lock default is read **before** the write in every case; where it is COMPLIANCE the acknowledgement must be given and must not be stale.

- [ ] **Step 5: Commit**

---

### Task 5: The ACL section

**Files:**
- Modify: `Sources/MacSCPAppKit/ObjectMetadataSheet.swift`, the four catalogues in both targets
- Test: `Tests/macSCPAppKitTests/ObjectACLSectionTests.swift`

**Interfaces:**
- Consumes: Task 2's `acl(ofKey:inBucket:)`.
- Produces: a read-only section of the same sheet — spec §6.5 keeps it there because it is the same subject reached from the same place.

- [ ] **Step 1: Write the failing tests**

```swift
@Test func anUnnamedHolderIsSaidRatherThanDrawnBlank() async {
    // Review Focus 1: the row's text is the catalogue sentence for an
    // unnamed holder, and it is not empty.
}
@Test func aStoreWithoutAclsSaysSoInsteadOfShowingNoGrants() async {
    // nil from Core is "this store does not offer this", which is NOT the
    // same as a policy holding zero grants.
}
@Test func theSectionOffersNoControlThatWrites() async {
    // The counterpart of Task 3's source guard, at the view level.
}
```

- [ ] **Step 2–4: red, implement, green**

- [ ] **Step 5: Commit**

---

### Task 6: `New Bucket…` in the connection manager

**Files:**
- Modify: `Sources/MacSCPAppKit/SessionSidebar.swift`, `Sources/MacSCPAppKit/ContentView+Sheets.swift`, the four catalogues in both targets
- Test: `Tests/macSCPAppKitTests/SidebarNewBucketTests.swift`

**Interfaces:**
- Consumes: the first half's `CreateBucketSheet` and its `CreateBucketModel`; `SessionSidebar`'s existing input enum (read how `sidebar.connect` routes through `onInput(.contextMenuEntry, session)` and add a case the same way).
- Produces: one context-menu entry on a stored S3 connection, routed to: open a tab → connect → present `CreateBucketSheet`.

**Why a tab:** the architecture invariant is that connection and session state belongs to the window scope and never to anything app-wide, and `TabTeardown.run(_:reason:)` is the one place the teardown stages are spelled. A transient connection owned by the sidebar would be a second owner of exactly what that invariant keeps single (spec §6.6).

- [ ] **Step 1: Write the failing tests**

```swift
@Test func theEntryIsOfferedForAStoredS3ConnectionInBucketListMode() { … }
@Test func theEntryIsNotOfferedInSingleBucketMode() {
    // Review Focus 5: the first half restricted create-bucket to bucket-list
    // mode because "a bucket created there would be invisible".
}
@Test func theEntryIsNotOfferedForSftpOrWebdav() { … }
@Test func choosingItOpensATabRatherThanAnOwnerlessConnection() { … }
@Test func cancellingTheSheetLeavesAnOrdinaryConnectedTab() { … }
```

- [ ] **Step 2–4: red, implement, green**

- [ ] **Step 5: Commit**

---

### Task 7: Closeout — the rig, the docs, the backlog

**Files:**
- Create: `Tests/macSCPCoreTests/S3MetadataGatedTests.swift`
- Modify: `docs/BACKLOG.md`, the user docs repository

- [ ] **Step 1: Write the gated suite**

Behind `MACSCP_ITEST=1`, rig started **from the main checkout**. One case per measured row of spec §4.5, §4.6 and §4.10: the `REPLACE` copy applying and adding a version; the ETag staying identical; `PUT ?acl` answering 200 while `GET ?acl` is unchanged (**the measurement that removed the write — assert it, so the day the store starts honouring it, this test says so**); `?ownershipControls` answering 501. Buckets the suite creates and deletes itself; never `macscp-seed`, `macscp-second` or `macscp-probe-lock`; **no COMPLIANCE retention on any bucket the suite means to delete.**

- [ ] **Step 2: Run it**

Run: `MACSCP_ITEST=1 swift test --filter S3MetadataGatedTests`
Expected: PASS. Figures recorded in the commit body beside the commands.

- [ ] **Step 3: Update `docs/BACKLOG.md`**

The s3Manager row's "Still missing" list loses the metadata editor, the ACL display (as *display*, naming that the write is a non-goal with its measurement) and the connection-manager surface. **Every withdrawal quotes the wording it replaces**, and each figure travels with the command that produced it — inside a table cell that means no pipe at all, several `-e` patterns instead of one `-E` alternation. Run each command in the form it is committed, after writing the sentence.

- [ ] **Step 4: User documentation**

Pages in `noix-docs` for the metadata editor and the ACL display, marked as coming in the next version; the ACL page says plainly that macSCP shows permissions and does not change them. Own branch, own worktree, `npm run build` and `npm run check` both pass. **Not pushed or merged without the maintainer asking.**

- [ ] **Step 5: Commit**

---

## Self-Review

**Spec coverage.** Goal 5 → Tasks 1, 2, 4. Goal 6 → Tasks 1, 2, 3, 5. Goal 7 → Task 6. §6.4 → Task 4. §6.5 → Task 5. §6.6 → Task 6. §11.2 → Task 4. §3's "no ACL write" → Task 3, as a guard rather than a promise. §4.10's unmeasured ceiling → Task 2's refusal test plus Plan A's backlog row.

**Step scan.** Every code step carries a signature or names the file whose pattern to follow. Task 3's probe step carries the command and the verdict line expected of it.

**Type consistency.** `ObjectMetadata`, `ACLGrant`, `ObjectACL`, `SaveRefusal` are defined once (Tasks 1 and 4) and referenced by those names afterwards. `metadataChanged` is Plan A's kind, named as such in both plans.

**Review Focus.** All five have an owning task and a named test: 1 in Tasks 2 and 5, 2 in Tasks 2 and 5, 3 in Task 4, 4 in Task 2, 5 in Task 6.

**Proportion.** Seven tasks, well under the spec's length. No implementation bodies; the one algorithm pinned in prose is `setMetadata`'s header set, because the headers are the thing that must be exact.

**One thing this plan deliberately adds that the spec did not ask for:** Task 3, the source guard against an ACL write. The spec makes the no-write decision and explains it; nothing in it would notice the decision being quietly reversed, and the measurement that justified it (a store returning 200 and keeping nothing) is invisible to anyone testing against that store.
