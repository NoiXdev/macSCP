# S3 Version History and Deleted Files Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** One file's version history in a sheet, with five actions on a row, and a switch that makes a deleted file visible in the browser again.

**Architecture:** A new optional capability, `ObjectVersionProvider`, queried with `as?` like `PresignedURLProvider` and `S3BucketSettings`; `S3FileSystem` conforms in the extension at the bottom of its file. `RemoteFileSystem` is not touched — a version id reaches the store only through the new capability, never through a path. The sheet is the audit log's shape; the browser switch is `showHiddenFiles`'s shape with a re-list behind it.

**Tech Stack:** Swift 6 (`.swiftLanguageMode(.v6)`), SwiftPM, Swift Testing, SwiftUI/AppKit, macOS 15 floor. No new dependency.

**Spec:** `docs/superpowers/specs/2026-10-23-s3-version-history-and-metadata-design.md` (§§1–11; this plan implements goals 1–4 and §§5–6.3)

**Plan B** (`2026-10-23-s3-metadata-and-acls.md`) implements goals 5–7 and runs after this one.

## Global Constraints

- Swift 6 strict, all targets `.swiftLanguageMode(.v6)`, minimum macOS 15, no new dependency.
- `swift test`, **no `--build-system` flag**. Gated suites behind `MACSCP_ITEST=1` (Docker rig, started from the main checkout only).
- TDD red→green; the observed red is quoted verbatim in the commit body.
- **Every write is read back from the store**, never assumed from a 200.
- **macSCP sends no bypass header.** Verbatim from `ObjectLockSheet`: *"macSCP sends no bypass (`S3BucketSettings.setRetention` says so), so within this app a governance retention can be extended and not shortened, and the sheet's own refusal sentence says as much."*
- **A version id is opaque.** Nothing parses one. A continuation marker is percent-encoded on the way back (spec §4.9).
- Never hardcode a display string: `L10n.string(_:_:)` in `MacSCPAppKit`, `CoreL10n.string(_:)` in `macSCPCore`; catalogues `en`/`de`/`fr`/`pl` in both localized targets; the German catalogues address the user as **du**.
- No secret, key, credential, token or endpoint in any store, state, log, `reason:` string, audit `detail`, notification, test name or test failure message. A value a test must not leak lives in a named constant with the `Bool` computed before the expectation.
- Tests never block the cooperative pool: no `syncShutdownGracefully()`, no `futureResult.wait()`, no `DispatchSemaphore.wait()`. Every wait is an `await`.
- No wall-clock ceiling in a test. A floor (`elapsed >= …`) is fine; a hang bound is `.timeLimit`.
- A negative source-scanning check ships with a positive check beside it.
- Each new write path gets its own `AuditEvent.Kind`.
- Conventional Commits; footer `Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>`.
- Commit/push only on explicit request; this plan commits, it does not push.

## Review Focus

Five conditions the spec implies that no happy path exercises. Each has its test named in the owning task.

1. **`prefix=<key>` over-matches a sibling key.** `?versions&prefix=doc.txt` also returns `doc.txt.bak`, so one file's history must be filtered on exact `Key` equality, not on the prefix the request sent. Task 2.
2. **A `NextKeyMarker` carrying `[`, `]`, `,` and `:`** (spec §4.9 measured RustFS returning an internal walker token inside the marker) — percent-encoded on the way back, and never parsed. Task 2.
3. **A store that does not implement `?versions` at all** (`501`, or `NotImplemented` in the body) — explained as unsupported, never surfaced as an authentication failure. Task 2.
4. **A version whose lock state is not yet known** — the destructive action stays disabled; "not yet known" is not "unlocked". Task 8.
5. **Toggling `showDeletedFiles` where it cannot apply** (local pane, non-S3 connection, bucket-list root, bucket without versioning) — no re-list, no error, no empty list. Task 10.

---

## File Structure

**Core (`Sources/macSCPCore/`)**

- `RemoteFS/ObjectVersionProvider.swift` — *new*. The capability protocol, `ObjectVersion`, `ObjectVersionPage`, `DeletedEntry`.
- `S3/S3VersionsXML.swift` — *new*. Parsing `ListVersionsResult`; sibling of `S3SettingsXML.swift`.
- `S3/S3FileSystem.swift` — *modify*. Conformance in the extension at the bottom, beside `S3BucketSettings`.
- `RemoteFS/RemoteFileItem.swift` — *modify*. One optional field.
- `Presentation/RemoteBrowserViewModel.swift` — *modify*. The merged listing behind the switch.
- `Presentation/TransferQueueViewModel.swift` — *modify*. One version-aware entry point.
- `Sessions/AuditEvent.swift`, `Sessions/AuditRecorder.swift` — *modify*. Four kinds and their recorders.
- `Capabilities/BackendDescriptor.swift` — *modify*. The `s3.versions` file action.
- `Settings/SettingsStore.swift` — *modify*. `showDeletedFiles`.

**App (`Sources/MacSCPAppKit/`)**

- `BucketVersioningCache.swift` — *new*. Sibling of `ObjectLockStateCache.swift`.
- `ObjectVersionsSheet.swift` — *new*. The sheet, its model, its row states.
- `RemoteFileTableView.swift` — *modify*. Per-row availability for backend file actions.
- `ContentView+Sheets.swift`, `ContentView+MenuActions.swift`, `ContentView+Transfers.swift` — *modify*. Presentation, routing, the version-aware download and read-only open.
- `SettingsView.swift`, `MacSCPCommands.swift` — *modify*. The switch and its menu command.
- `Comparison.swift` — *modify*. Comparing a version against current.
- Resources `en`/`de`/`fr`/`pl` `.lproj/Localizable.strings` in **both** localized targets.

---

### Task 1: `ObjectVersionProvider` and its types

**Files:**
- Create: `Sources/macSCPCore/RemoteFS/ObjectVersionProvider.swift`
- Test: `Tests/macSCPCoreTests/ObjectVersionProviderTests.swift`

**Interfaces:**
- Consumes: `RemoteFSError`, `ObjectRetention`, `RetentionMode` (existing, `S3BucketSettings.swift`).
- Produces:
  ```swift
  public struct ObjectVersion: Sendable, Equatable, Identifiable {
      public let versionId: String
      public let key: String
      public let isLatest: Bool
      public let isDeleteMarker: Bool
      public let size: UInt64?
      public let modifiedAt: Date?
      public let entityTag: String?
      public var id: String { versionId }
  }

  public struct ObjectVersionPage: Sendable, Equatable {
      public let versions: [ObjectVersion]
      public let nextKeyMarker: String?
      public let nextVersionIdMarker: String?
      public var isTruncated: Bool { nextKeyMarker != nil }
  }

  public struct DeletedEntry: Sendable, Equatable {
      public let key: String
      public let markerVersionId: String
      public let modifiedAt: Date?
  }

  public protocol ObjectVersionProvider: Sendable {
      func versions(ofKey key: String, inBucket bucket: String) async throws -> [ObjectVersion]
      func deletedEntries(inBucket bucket: String, prefix: String) async throws -> [DeletedEntry]
      func readStream(ofKey key: String, inBucket bucket: String, versionId: String) async throws -> RemoteReadStream
      func restore(key: String, inBucket bucket: String, toVersionId versionId: String) async throws
      func deleteVersion(ofKey key: String, inBucket bucket: String, versionId: String) async throws
      func liftDeleteMarker(ofKey key: String, inBucket bucket: String, markerVersionId: String) async throws
  }
  ```
  `RemoteReadStream` is whatever `RemoteFileSystem.readStream` already returns — read that signature and use the same type; do not introduce a second stream type.

- [ ] **Step 1: Write the failing test**

```swift
@Test func anObjectVersionIsIdentifiedByItsVersionId() {
    let v = ObjectVersion(
        versionId: "abc", key: "doc.txt", isLatest: true, isDeleteMarker: false,
        size: 19, modifiedAt: nil, entityTag: nil)
    #expect(v.id == "abc")
}

@Test func aPageWithoutANextKeyMarkerIsNotTruncated() {
    let page = ObjectVersionPage(versions: [], nextKeyMarker: nil, nextVersionIdMarker: nil)
    #expect(page.isTruncated == false)
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter ObjectVersionProviderTests`
Expected: FAIL — `cannot find 'ObjectVersion' in scope`

- [ ] **Step 3: Write the file with the three types and the protocol above**

Doc comments follow `S3BucketSettings.swift`'s register: say what each method answers, and what `nil` means where it is returned. State in the protocol's own header why it is NOT named for S3 (spec §5) and that `RemoteFileSystem` is deliberately untouched.

- [ ] **Step 4: Run to verify it passes**

Run: `swift test --filter ObjectVersionProviderTests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/macSCPCore/RemoteFS/ObjectVersionProvider.swift Tests/macSCPCoreTests/ObjectVersionProviderTests.swift
git commit -m "feat(core): an optional capability for one object's versions"
```

---

### Task 2: Parsing `ListVersionsResult`

**Files:**
- Create: `Sources/macSCPCore/S3/S3VersionsXML.swift`
- Test: `Tests/macSCPCoreTests/S3VersionsXMLTests.swift`

**Interfaces:**
- Consumes: Task 1's `ObjectVersion`, `ObjectVersionPage`, `DeletedEntry`; `S3FileSystem.mapErrorStatus` (existing).
- Produces:
  ```swift
  enum S3VersionsXML {
      static func parsePage(_ body: Data, status: Int) throws -> ObjectVersionPage
      // WITHDRAWN 2026-11-02 during Task 2's review; see the amendment under
      // this block. The line read verbatim:
      //     static func markerQueryValue(_ marker: String) -> String
  }
  ```
  `parsePage` throws `S3FileSystem.mapErrorStatus(...)` for any non-2xx — there is no "not configured" answer to forgive here, unlike `parseObjectLockState`. `markerQueryValue` percent-encodes a marker for a query value. **[WITHDRAWN 2026-11-02 — see the amendment below; this sentence is kept as what the plan asked for, and the function does not exist.]**

**Amendment 2026-11-02, from Task 2's review: `markerQueryValue` is WITHDRAWN and was never merged.** (**Corrected 2026-11-02 in the same re-review**, having read “was never shipped”: the function was committed on this branch and existed at `ea1cadd9`, so “shipped” overstates what it never did. It was never merged and never released.) The sentence above stands as what this plan asked for; what it asked for was wrong, and the measurement is this. The function as written was the same algorithm as `SigV4Signer.rfc3986Encode` — the same unreserved set spelled with the same `UInt8(ascii:)` ranges, the same `String(format: "%%%02X", byte)`, the same `reserveCapacity` — and `SigV4Signer.canonicalQueryString(query:)` maps `rfc3986Encode` over BOTH the name and the value of every pair, so this module's request path already takes raw values and encodes them exactly once. Six call sites go through it (`S3FileSystem` x3, `SigV4Signer` x2, `S3RequestSigning` x1), and no query-building path here skips it: `presignedQuery` goes through it too, and so does `reSigned` (`S3RequestSigning.swift`, which parses the redirect target's query with `queryPairs(from:)` and re-encodes it through `canonicalQueryString` — it is the `S3RequestSigning x1` site this sentence counts). **Corrected 2026-11-02 by Task 2's fix-round re-review, which caught a false claim in this amendment**: the clause read “and `reSigned` reproduces a redirect target verbatim rather than building a query.” That is wrong, and it was wrong in a way worth recording, because it weakened the argument it was part of: `reSigned` re-encodes through the same function, so it is further evidence that nothing here skips the encoding rather than an exception to it. The false clause came from transplanting a true statement about a different subject — `SigV4Signer`'s own doc comment says `reSigned` “starts from a redirect TARGET whose path it must reproduce verbatim rather than derive from a shape”, which is a claim about the PATH and about deriving from a shape, not about building a query. The conclusion is unchanged and is now carried by six sites instead of five. So a Task 3 that followed the house path and passed `markerQueryValue(marker)` as a query value would have sent `%255B` where the store issued `[` — a marker the store never issued, and a failure no retry fixes. `canonicalQueryString`'s own doc comment records the precedent: it was widened to internal "keeping the signed and sent queries byte-identical (see M12 review I-1: a `URLComponents`-encoded wire query left `+` un-escaped, so it diverged from what was signed here whenever a value — e.g. a base64 `continuation-token` — contained one)", and a continuation marker is that same kind of value. **What satisfies the spec instead:** §4.9 requires the marker to be percent-encoded on the way back and never concatenated into a URL by hand, which the house path already does. The spec never required a function by this name. **Task 3 therefore passes markers RAW as query pair values**, and the encoding coverage moved to `canonicalQueryString` over a raw walker token — the path Task 3 actually uses.

- [ ] **Step 1: Write the failing tests**

Fixtures are the bodies the spec's §4.8/§4.9 measured. Keep each fixture in a `static let` and build it from a raw string; do not fetch anything.

```swift
@Test func aVersionAndADeleteMarkerAreBothRead() throws {
    let page = try S3VersionsXML.parsePage(Self.twoVersionsOneMarker, status: 200)
    #expect(page.versions.count == 3)
    #expect(page.versions.filter(\.isDeleteMarker).count == 1)
    #expect(page.versions.first(where: \.isLatest)?.isDeleteMarker == true)
}

@Test func aSiblingKeyTheRequestsPrefixAlsoMatchedIsStillParsed() throws {
    // `prefix=doc.txt` matches `doc.txt.bak` at the store; the parser reports
    // what arrived and the CALLER filters (Task 3). Review Focus 1.
    let page = try S3VersionsXML.parsePage(Self.keyAndSiblingKey, status: 200)
    #expect(Set(page.versions.map(\.key)) == ["doc.txt", "doc.txt.bak"])
}

@Test func aTruncatedPageCarriesBothMarkers() throws {
    let page = try S3VersionsXML.parsePage(Self.truncatedFirstPage, status: 200)
    #expect(page.isTruncated)
    #expect(page.nextVersionIdMarker != nil)
}

@Test func aMarkerCarryingAnInternalTokenIsEncodedNotParsed() {
    // Measured 2026-10-23 (spec §4.9): RustFS returns the walker handle inside
    // the marker. Review Focus 2.
    let marker = "k1.txt[rustfs_cache:v2,id:58bdf6cd,src:walker,gen:live]"
    // WITHDRAWN 2026-11-02 with the function: this line read
    //     let encoded = S3VersionsXML.markerQueryValue(marker)
    // The shipped test asserts the same two properties over
    // `SigV4Signer.canonicalQueryString`, which is the path Task 3 uses.
    let leaksABracket = encoded.contains("[") || encoded.contains("]")
    #expect(leaksABracket == false)
    #expect(encoded.contains("%5B"))
}

@Test func aStoreThatDoesNotImplementTheCallIsNotAnAuthFailure() {
    // Review Focus 3.
    #expect(throws: RemoteFSError.self) {
        try S3VersionsXML.parsePage(Self.notImplementedBody, status: 501)
    }
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --filter S3VersionsXMLTests`
Expected: FAIL — `cannot find 'S3VersionsXML' in scope`

- [ ] **Step 3: Implement `S3VersionsXML` in `Sources/macSCPCore/S3/S3VersionsXML.swift`**

Parse with the same mechanism `S3SettingsXML` uses — read that file and follow it; do not add a second XML approach to the target. `DeleteMarker` elements become `ObjectVersion` with `isDeleteMarker: true` and `size: nil`.

- [ ] **Step 4: Run to verify they pass**

Run: `swift test --filter S3VersionsXMLTests`
Expected: PASS (5 tests)

- [ ] **Step 5: Commit**

```bash
git add Sources/macSCPCore/S3/S3VersionsXML.swift Tests/macSCPCoreTests/S3VersionsXMLTests.swift
git commit -m "feat(core): parse ListVersionsResult, markers included"
```

---

### Task 3: `S3FileSystem` lists one key's versions

**Files:**
- Modify: `Sources/macSCPCore/S3/S3FileSystem.swift` (the extension at the bottom, beside the `S3BucketSettings` conformance)
- Test: `Tests/macSCPCoreTests/S3ObjectVersionsTests.swift`

**Interfaces:**
- Consumes: Tasks 1 and 2; `S3FileSystem`'s existing request signer (read how `S3BucketSettings`'s methods build and sign a request and use the same path).
- Produces: `extension S3FileSystem: ObjectVersionProvider` — `versions(ofKey:inBucket:)` and `deletedEntries(inBucket:prefix:)` in this task; the other four in Tasks 4 and 5.

- [ ] **Step 1: Write the failing tests**

Against a stubbed transport, not the rig (the rig half is Task 11).

```swift
@Test func oneKeysHistoryIsOneRequestWithThePrefix() async throws { … }

@Test func aSiblingKeyThePrefixMatchedIsNotInTheHistory() async throws {
    // Review Focus 1: the request sends prefix=doc.txt, the store answers with
    // doc.txt and doc.txt.bak, and the history holds doc.txt only.
    let versions = try await fs.versions(ofKey: "doc.txt", inBucket: "b")
    #expect(Set(versions.map(\.key)) == ["doc.txt"])
}

@Test func aTruncatedHistoryIsFollowedToTheEnd() async throws {
    // Two stubbed pages; the second request must carry key-marker and
    // version-id-marker, both percent-encoded.
}

@Test func deletedEntriesAreTheLatestMarkersOnly() async throws {
    // A key whose marker is IsLatest is deleted; a key with an older marker
    // under a newer version is NOT.
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --filter S3ObjectVersionsTests`
Expected: FAIL — `S3FileSystem` does not conform to `ObjectVersionProvider`

- [ ] **Step 3: Implement both methods**

`versions(ofKey:inBucket:)` sends `?versions&prefix=<key>`, follows `nextKeyMarker`/`nextVersionIdMarker` while truncated, and filters `Key == key`. `deletedEntries(inBucket:prefix:)` sends `?versions&prefix=<prefix>&delimiter=/` and keeps delete markers with `isLatest` true.

- [ ] **Step 4: Run to verify they pass**

Run: `swift test --filter S3ObjectVersionsTests`
Expected: PASS

- [ ] **Step 5: Commit**

---

### Task 4: Restore, delete one version, lift a marker — with read-back and audit

**Files:**
- Modify: `Sources/macSCPCore/S3/S3FileSystem.swift`, `Sources/macSCPCore/Sessions/AuditEvent.swift`, `Sources/macSCPCore/Sessions/AuditRecorder.swift`
- Test: `Tests/macSCPCoreTests/S3VersionActionsTests.swift`, `Tests/macSCPCoreTests/AuditEventKindTests.swift` (existing file — extend)

**Interfaces:**
- Consumes: Tasks 1–3.
- Produces: the remaining `ObjectVersionProvider` methods, plus four `AuditEvent.Kind` cases — `versionRestored`, `versionDeleted`, `deleteMarkerLifted`, `metadataChanged` (the last is Plan B's; it is added here so `AuditLogSheet.Filter.segment(of:)`'s exhaustive switch is extended once) — and recorders following `recordVersioningChanged(bucket:to:failure:)`'s shape.

- [ ] **Step 1: Write the failing tests**

```swift
@Test func restoringAnOldVersionIsReadBackAsTheNewCurrent() async throws { … }
@Test func aRestoreThatCannotBeConfirmedIsNotReportedAsDone() async throws { … }
@Test func deletingAVersionUnderRetentionIsRefusedWithoutABypassHeader() async throws {
    // The request this builds carries NO x-amz-bypass-governance-retention.
    // Assert on the built request's headers, not on a store's answer.
}
@Test func liftingAMarkerIsOneDeleteOfThatMarkersVersionId() async throws { … }
```

Audit: one case per new kind in the existing exhaustive-switch test, and a check that no `detail` carries the endpoint or the key's credentials.

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --filter 'S3VersionActionsTests|AuditEventKindTests|AuditLogSheet'`
Expected: FAIL, including a non-exhaustive-switch build error in `AuditLogSheet.Filter.segment(of:)` once the cases exist — that build failure is the guard working, and the new cases go under `.fileOps`.

- [ ] **Step 3: Implement the three calls, the four kinds and their recorders**

`restore` is `PUT` with `x-amz-copy-source: /<bucket>/<key>?versionId=<id>` and reads back with `versions(ofKey:inBucket:)`, confirming a new `isLatest` whose `entityTag` matches the source version's. `deleteVersion` and `liftDeleteMarker` are `DELETE ?versionId=`, read back by absence.

- [ ] **Step 4: Run to verify they pass**

- [ ] **Step 5: Commit**

---

### Task 5: The version-aware read, download and read-only open

**Files:**
- Modify: `Sources/macSCPCore/S3/S3FileSystem.swift`, `Sources/macSCPCore/Presentation/TransferQueueViewModel.swift`, `Sources/MacSCPAppKit/ContentView+Transfers.swift`
- Test: `Tests/macSCPCoreTests/S3VersionReadTests.swift`, `Tests/macSCPAppKitTests/VersionDownloadTests.swift`

**Interfaces:**
- Consumes: Task 1's `readStream(ofKey:inBucket:versionId:)`.
- Produces:
  ```swift
  // TransferQueueViewModel
  public func enqueueAndWaitVersion(
      fileName: String, source: any ObjectVersionProvider, bucket: String,
      key: String, versionId: String,
      destination: any RemoteFileSystem, destinationDirectory: String
  ) async throws
  ```
  plus `VersionLocalName.forDownload(fileName:versionId:) -> String`, the distinguishing suffix (spec §5.1 leaves the spelling to the builder; fix it here and test it).

- [ ] **Step 1: Write the failing tests**

```swift
@Test func twoVersionsOfOneKeyDoNotCollideOnDisk() {
    let a = VersionLocalName.forDownload(fileName: "doc.txt", versionId: "abc")
    let b = VersionLocalName.forDownload(fileName: "doc.txt", versionId: "def")
    #expect(a != b)
    #expect(a.hasSuffix(".txt"))
}

@Test func aVersionIdThatIsAPathSeparatorCannotEscapeTheName() {
    let name = VersionLocalName.forDownload(fileName: "doc.txt", versionId: "../../etc/x")
    let escapes = name.contains("/")
    #expect(escapes == false)
}

@Test func openingAnOldVersionRegistersNoUploadDestination() async throws {
    // Spec §11.1: read-only. The edit session must NOT be used for a version.
}
```

- [ ] **Step 2–4: red, implement, green**

Open for a version downloads through the queue into a temp directory and hands the file to `NSWorkspace`/`EditorResolver` **without** `EditSessionManager.beginEditing`, which is what carries `destinationForUploads`.

- [ ] **Step 5: Commit**

---

### Task 6: The versioning cache and per-row availability

**Files:**
- Create: `Sources/MacSCPAppKit/BucketVersioningCache.swift`
- Modify: `Sources/MacSCPAppKit/RemoteFileTableView.swift`, `Sources/macSCPCore/Capabilities/BackendDescriptor.swift`, the four catalogues in both targets
- Test: `Tests/macSCPAppKitTests/BucketVersioningCacheTests.swift`, `Tests/macSCPAppKitTests/FileActionAvailabilityTests.swift`

**Interfaces:**
- Consumes: `S3BucketSettings.versioning(ofBucket:)`.
- Produces: `BucketVersioningCache.versioning(_ bucket: String) async throws -> BucketVersioning`, owned by `BrowserSession` beside `objectLockStates`; `RemoteFileTableView` gains `let isFileActionAvailable: (FileActionContribution) -> Bool` and `let fileActionUnavailableReason: (FileActionContribution) -> String?`; the descriptor gains `FileActionContribution(id: "s3.versions", titleKey: "browser.action.versions", titleDefault: "Show Versions…")`.

**Corrected 2026-11-02, before Task 6 was dispatched.** (Withdrawn wording, verbatim: `titleKey: "menu.s3.versions"`.) There is no `menu.s3.` namespace in the catalogues: `grep -c 'menu.s3' Sources/MacSCPAppKit/Resources/en.lproj/Localizable.strings` prints 0 where `browser.action` prints 3, and the three existing file actions all use that namespace (`browser.action.presignedURL`, `.retention`, `.legalHold` in `BackendDescriptor`), each present in all four catalogues, checked per locale. **And nothing would have caught the wrong key:** `BackendContributionTests` asserts only `!action.titleKey.isEmpty`, and no test pins a `FileActionContribution.titleKey` to the catalogues, so a key with no entry falls back to the English `titleDefault` in de, fr and pl with the suite green. Task 6 therefore also adds that guard, parameterised over the contributions the descriptor declares and the four languages, the way `SnippetAuditWiringGuardTests.everyKindHasACatalogLabel` does it for `audit.kind.*`.

**Why a closure and not a Core field:** `ConnectionActionsMenu` already answers availability with an App-side closure (`let isAvailable: (ConnectionActionContribution) -> Bool`), and the row is `.disabled(!isAvailable(action))`. This mirrors it. **Correction to the spec, 2026-10-23:** spec §6.1 claimed the precedent is "disabled with the reason beside it"; it is not — the existing precedent disables with no reason text at all. The reason is therefore carried as the `NSMenuItem`'s `toolTip`, which is new behaviour, not a copied pattern, and the spec has been corrected to say so.

- [ ] **Step 1: Write the failing tests**

Cache: an answer is cached and a failure is not; two asks share one read (both mirror `ObjectLockStateCacheTests` — read them and follow). Availability: a row whose availability is `false` renders disabled and carries a tooltip; a row that is available carries none. Pair the negative with a positive: assert the menu contains the `s3.versions` row at all.

- [ ] **Step 2–4: red, implement, green**

- [ ] **Step 5: Commit**

---

### Task 7: The version sheet

**Files:**
- Create: `Sources/MacSCPAppKit/ObjectVersionsSheet.swift`
- Modify: `Sources/MacSCPAppKit/ContentView+Sheets.swift`, `Sources/MacSCPAppKit/ContentView+MenuActions.swift`, `Sources/MacSCPAppKit/BrowserPane.swift`, `Sources/MacSCPAppKit/BucketVersioningCache.swift`, `Sources/MacSCPAppKit/BucketVersioningSheet.swift`, the four `MacSCPAppKit` catalogues
- Test: `Tests/macSCPAppKitTests/ObjectVersionsSheetTests.swift`, `Tests/macSCPAppKitTests/BucketVersioningCacheTests.swift`

**Interfaces:**
- Consumes: Tasks 1–6.
- Produces: `ObjectVersionsSheet`, and `ObjectVersionsModel` with
  ```swift
  @MainActor final class ObjectVersionsModel {
      enum RowState: Equatable {
          case current, plain, deleteMarker, metadataOnly
          case locked(until: Date, mode: RetentionMode), legalHold
          case lockUnknown, lockUnreadable
      }
      func load() async
      func rowState(of version: ObjectVersion) -> RowState
  }
  ```

**Amended 2026-11-02, after Task 6's review.** Four requirements come here from that task,
and one correction to the line above.

**The correction.** (Withdrawn wording, verbatim: `the four catalogues in both targets`.) The
keys this task adds are view strings in a `MacSCPAppKit` view, and that target is where its
siblings' are: run from the repository root,
`grep -c 'versioning\.' Sources/MacSCPAppKit/Resources/en.lproj/Localizable.strings` prints 15
against 0 for `Sources/macSCPCore/Resources/en.lproj/Localizable.strings`, and `browser.action`
prints 5 against 0 — the three existing file actions plus Task 6's two keys. A zero printed by
`grep -c` exits 1, and that exit is part of the answer, not a failed command. Touch Core's
catalogues only if this task adds a Core-layer message, which the sheet is not. This is the
same defect Task 6's brief carried for its `titleKey`, in the same plan, found the same way:
by checking a task's identifiers against the tree they land in rather than against the spec.

**1. Thread both availability closures, and make them required once they are threaded.**
Task 6 left `RemoteFileTableView.isFileActionAvailable` and `.fileActionUnavailableReason` as
`var … = { _ in true }` / `{ _ in nil }` so the existing call sites kept compiling, and nothing
forwards them. `BrowserPane.swift` is the only place that constructs `RemoteFileTableView`
(`grep -rln 'RemoteFileTableView(' Sources` prints that one file); the path upward from there to
the session that owns the cache is for this task to establish, and this plan does not pretend to
know it. **Once the closures are forwarded, drop the defaults** so a later call site must answer
rather than inheriting "available": a permissive default is a fail-open guard, and the unwired
state should fail to compile instead of shipping a live row that does nothing.

**2. Route the id, and write the test that an unrouted id cannot be offered.** Backend file
actions are an `if`-chain in `ContentView+MenuActions.swift` with no `else`, so `s3.versions`
currently matches nothing and the row is enabled and inert on every S3 file. The connection side
has the boundary this side lacks: `ConnectionActionRoute` (`ConnectionActionRoute.swift:57`) is
`String, CaseIterable`, `init?(action:)` is nil for an id it has no case for, and the menu
disables that row — the route enum IS the table. Follow that shape here if it is cheap; what is
required either way is that choosing the row opens the sheet, and that a declared
`FileActionContribution` the handler does not route is not offered as available.

**3. A bucket whose versioning has not been read yet OFFERS the row.** The menu builds
synchronously and `BucketVersioningCache.versioning(_:)` is `async`, so this task needs a
synchronous accessor that answers only from what was already read — `nil` for "not asked" — and
a policy for that `nil`. The policy is: offer the row, and let the sheet report an absent or
empty history when it opens, which this task already has a test for
(`anEmptyHistorySaysSoRatherThanLookingLikeAFailure`). Disabling while unknown is the reading to
reject: nothing triggers the read, so the row could not become enabled by waiting, and a dead
end is worse than a slow one. This matches `objectLockStates`, which `ObjectLockSheet` also asks
only when it opens. **The limitation it leaves, stated rather than designed around:** the
disabled row and its reason are then reachable only for a bucket whose versioning was read
earlier in the session, so in a fresh session the per-row unavailability is mostly latent. The
fix is a prefetch on entering a bucket, its cost is one `GET ?versioning` per navigation, and
that trade goes to Task 11 as a backlog row rather than into this plan's code.

**4. The cache must be able to take a write.** `BucketVersioningSheet.apply(_:bucket:via:locks:recorder:)`
sends `setVersioning` and reads the state back, and never tells the cache. So once the row is
wired, four clicks produce a wrong answer in one session: the row is evaluated on a `.never`
bucket, the user enables versioning in the Versioning sheet, and for the rest of the session the
row stays disabled saying the bucket never had versioning turned on. Give the cache
`invalidate(_ bucket: String)` (or a `record`), and have `apply` call it **after a successful
write only** — a write that failed changed nothing, and invalidating on failure throws away a
good answer because a request failed. `apply` already takes `locks: ObjectLockStateCache`, so
the cache threads in the way its sibling already does. Tests: a write then an ask reads again,
and a positive control that a write to one bucket does not invalidate another.
**Why the lock cache needs none of this:** Object Lock on a bucket is effectively one-way and
the app offers no un-setting of it, so no write the app sends can make that cache lie.
Versioning is a three-state toggle the app writes. The precedent does not carry.

**5. Test the threading itself.** Task 6's review found that the closure assignments in
`makeCoordinator` and `updateNSView` are exercised by no test — dropping the `updateNSView` line
leaves the suite green while the table keeps stale closures after a state change. That was
untested because nothing passed the closures; once this task does, a test pins it.

- [ ] **Step 1: Write the failing tests**

```swift
@Test func theLatestVersionIsTheCurrentRow() async { … }
@Test func aDeleteMarkerRowIsNotAContentRow() async { … }
@Test func aVersionWithTheSameETagAsItsPredecessorIsMetadataOnly() async {
    // Spec §4.5 measured the ETag staying identical across a REPLACE copy.
}
@Test func aListingThatSucceededIsNotEmptiedByALockReadThatCouldNotApply() async {
    // The first half's D1 lesson. Bucket without Object Lock: rows show,
    // state is .plain/.current, nothing reports failure.
}
@Test func anEmptyHistorySaysSoRatherThanLookingLikeAFailure() async { … }
```

Layout bound: follow `BoundedViewLayoutGuardTests` as the versioning and CORS sheets do — the columns and the footer must fit the sheet's own width.

- [ ] **Step 2–4: red, implement, green**

Table, `Picker` filter, `SheetSearchField` with `sheetSearchPredicate(text:isRegex:)`, counting footer — all four read off `AuditLogSheet.swift`, which is the shape the maintainer chose.

- [ ] **Step 5: Commit**

---

### Task 8: The bounded lock read

**Files:**
- Modify: `Sources/MacSCPAppKit/ObjectVersionsSheet.swift`
- Test: `Tests/macSCPAppKitTests/ObjectVersionsLockReadTests.swift`

**Interfaces:**
- Consumes: `S3BucketSettings.retention(ofKey:inBucket:versionId:)`, `legalHold(ofKey:inBucket:versionId:)`, Task 6's cache.
- Produces: `ObjectVersionsModel.readLocks(forVisible rows: [ObjectVersion]) async`.

- [ ] **Step 1: Write the failing tests**

```swift
@Test func aRowWhoseLockIsNotYetKnownDisablesTheDestructiveAction() async {
    // Review Focus 4: .lockUnknown is not .plain.
}
@Test func noLockIsReadOnABucketWithoutObjectLock() async {
    // Zero requests, asserted on a counting stub.
}
@Test func closingTheSheetCancelsTheLockReadsStillOutstanding() async {
    // `.timeLimit(.minutes(1))` as the hang bound; no wall-clock ceiling.
}
@Test func atMostTheConcurrencyLimitOfLockReadsRunAtOnce() async {
    // A counting stub records its own high-water mark.
}
```

**Amended 2026-11-02, after Task 7's review. Three of these four properties are already
pinned, and this task is what remains.** Task 7 built the bounded read itself — `ConcurrencyGate`,
`readLockState(of:)`, `readLockStates(of:)` and the state cell's `.task(id:)` — because the
`RowState` cases this plan gave Task 7 (`.locked`, `.legalHold`, `.lockUnknown`,
`.lockUnreadable`) cannot be answered without reading. Do not rebuild any of it, and do not
re-dispatch what the following tests already hold:

- "a row whose lock is not yet known is not treated as unlocked" → `aBucketWithALockHasEachRowsLockReadAndUnreadRowsAreUnknownNotUnlocked`,
  which asserts `.lockUnknown` for every row before any read and the three distinct outcomes
  after.
- "zero lock requests on a bucket without Object Lock, on a counting stub" →
  `aListingThatSucceededIsNotEmptiedByALockReadThatCouldNotApply`, across three backings, reading
  the count off `FakeBucketSettings`' own record. The positive control the zero needs is in the
  same case: the rows are asserted present and `.loaded`.
- "at most the concurrency limit at once" → `theGateRunsAtMostItsLimitAtOnceAndAllOfThem`
  measures the peak through an external probe. The model-level case's floor was too weak to pin
  parallelism and was raised in Task 7's fix round 1, so this task does not touch it either.

**What remains is the one property nothing pins, and it is work and not only a test.** No test
closes the sheet with reads still outstanding, and `ConcurrencyGate`'s waiters are not
cancellation-aware by design. So on a long history behind a limit-4 gate, a sheet dismissed while
rows are queued leaves the waiters to wake and send their reads against the store after the
surface that wanted them is gone. Decide whether that is a leak worth closing — a request the
user cannot see the answer to is a request they did not ask for — and either make the gate's wait
cancellation-aware or record, with the reasoning, why the reads are harmless. Either way the
property gets the test the plan named.

`readLocks(forVisible:)` as a signature is withdrawn. (Withdrawn wording, verbatim:
`ObjectVersionsModel.readLocks(forVisible rows: [ObjectVersion]) async`.) Task 7 answered the
"visible" half better than a parameter could: each state cell asks for its own row in `.task(id:)`,
so nothing off-screen is read and no caller has to compute what is visible. The name in the tree
is `readLockStates(of:)`.

**And the bound above is wrong by this project's own rule.** (Withdrawn wording, verbatim:
`` `.timeLimit(.minutes(1))` as the hang bound; no wall-clock ceiling. ``) A `.timeLimit` is a
wall-clock ceiling too, and 60 s sits below this suite's own run duration, so it does not measure
the test at all — the 110 such bounds in `Tests/` were raised to `.minutes(5)` on 2026-10-30 after
two runs of the same image, two commits apart, reddened 148 cases on it. Use
`.timeLimit(.minutes(5))`. Task 7 already measured a fresh instance of why the bound is not the
thing to lean on: a plant that trapped the runner spun the main actor for ~30 minutes and starved
the `.timeLimit` enforcing it, because the timer needs a thread the starved pool would not give.

- [ ] **Step 2–4: red, implement, green**

- [ ] **Step 5: Commit**

---

### Task 9: The five row actions

**Files:**
- Modify: `Sources/MacSCPAppKit/ObjectVersionsSheet.swift`, `Sources/MacSCPAppKit/Comparison.swift`, the four `MacSCPAppKit` catalogues
- Test: `Tests/macSCPAppKitTests/ObjectVersionActionsTests.swift`

**Interfaces:**
- Consumes: Tasks 4, 5, 8; `ComparisonRequest` (existing).
- Produces: `ObjectVersionsModel.action(_:on:) async`, and `ObjectVersionsModel.isEnabled(_ action: VersionRowAction, on: ObjectVersion) -> Bool` with `enum VersionRowAction { case open, compareWithCurrent, download, restore, deleteVersion }`.

- [ ] **Step 1: Write the failing tests**

One per disabled condition from spec §6.2's table, each asserting `isEnabled` is `false` and the happy sibling `true`:

```swift
@Test func compareIsNotOfferedOnTheCurrentRowOrOnADeleteMarker() { … }
@Test func downloadIsNotOfferedOnADeleteMarker() { … }
@Test func restoreIsNotOfferedOnTheCurrentRow() { … }
@Test func deleteIsNotOfferedOnALockedRowOrOneWhoseLockIsUnknown() { … }
@Test func restoreStatesThatItWritesANewVersionBeforeItRuns() { … }
@Test func deletingAVersionAsksForConfirmationFirst() { … }
```

- [ ] **Step 2–4: red, implement, green**

Delete takes an ordinary confirmation (spec §6.2, maintainer's decision of 2026-10-23) — **not** the COMPLIANCE acknowledgement, which is Plan B's.

**Amended 2026-11-02, before Task 9 was dispatched.** (Withdrawn wording, verbatim:
`the four catalogues in both targets`.) **Third time in this plan for the same defect**, after
Task 6's `titleKey` and Task 7's own file list: every string this task adds is a view string in
an `MacSCPAppKit` view, and both files it modifies are in that target. Run from the repository
root, `grep -c 'versions\.' Sources/MacSCPAppKit/Resources/en.lproj/Localizable.strings` prints
27 against 0 for `Sources/macSCPCore/Resources/en.lproj/Localizable.strings` — the sheet's own
family, measured for this task rather than inherited from Task 7's figure, because the families
differ even where the answer does not. The zero exits 1, and that exit is part of the answer.
Touch Core's catalogues only for a Core-layer message, which none of these is.

Six things this task inherits from the tasks before it, none of them derivable from the step above:

1. **Restore is gated on `.enabled` ALONE**, not on `VersionsRowAvailability`. The sheet opens on
   `.suspended` too, because a suspended bucket still has a history — but a write to a suspended
   bucket REPLACES the `null` version instead of adding one, so a restore there destroys the
   current content rather than preserving it. The sheet's availability and this action's gate are
   different questions with different answers, and conflating them is the one mistake here that
   loses data.
2. **"Open" is not offered on a delete marker**, and the refusal is a typed finding rather than a
   bare `false` — a marker has no content to open, and the user asking deserves the reason.
3. **An unconfirmed restore is not worded as a failure.** Task 4's read-back confirms by ETag, and
   a multipart or opaque source ETag cannot be compared, so the honest outcome is "could not be
   confirmed", which is a different fact from "failed" and the user acts differently on it. Task
   11's rig measurement 1 is the one that could turn this into a real failure; until it runs, the
   weak path fails toward *done*.
4. **"Is this the current version" is `version.isLatest`, never `rowState(of:) == .current`.**
   Task 7's precedence puts the lock states ahead of `.current`, so a locked newest version is
   `.locked`, and a gate written against `.current` would silently offer restore on the row it
   must refuse. Use `isMetadataOnly(_:)` for the metadata-only note in the same way.
5. **A version id can literally be the four characters `null`** — a real, displayable id, never a
   missing value, and every action must accept it as a target.
6. **Each of the four `…IsNotOfferedOn…` negatives takes its positive beside it**, which the step
   above already asks for ("the happy sibling `true`"): a negative check is the only kind that can
   go stale in silence, and four of them in a row with nothing asserting the actions exist at all
   is a suite that passes when the action enum is emptied.

- [ ] **Step 5: Commit**

---

### Task 10: `showDeletedFiles`

**Files:**
- Modify: `Sources/macSCPCore/Settings/SettingsStore.swift`, `Sources/macSCPCore/Presentation/RemoteBrowserViewModel.swift`, `Sources/macSCPCore/RemoteFS/RemoteFileItem.swift`, `Sources/MacSCPAppKit/SettingsView.swift`, `Sources/MacSCPAppKit/MacSCPCommands.swift`, `Sources/MacSCPAppKit/RemoteFileTableView.swift`, `Sources/macSCPCore/Presentation/BrowserContextMenu.swift`, the four catalogues in both targets
- Test: `Tests/macSCPCoreTests/DeletedEntryListingTests.swift`, `Tests/macSCPAppKitTests/ShowDeletedFilesTests.swift`

**Interfaces:**
- Consumes: Task 3's `deletedEntries(inBucket:prefix:)`, Task 4's `liftDeleteMarker`.
- Produces: `RemoteFileItem.deleteMarkerVersionID: String?` (defaulting to `nil`, with `isDeleted` derived), `SettingsStore.showDeletedFiles`, `RemoteBrowserViewModel.showDeletedFiles`, and `BrowserContextMenu.Entry.restoreDeleted`.

- [ ] **Step 1: Write the failing tests**

```swift
@Test func aDeletedKeyBecomesARowCarryingItsMarkerVersionId() async throws { … }
@Test func everyExistingCallSiteOfRemoteFileItemStillCompiles() {
    // The positive beside the default: an item built with the old argument
    // list has `isDeleted == false`.
    let item = RemoteFileItem(name: "a", path: "/a", kind: .file)
    #expect(item.isDeleted == false)
}
@Test func theSwitchChangesWhatIsFetchedAndNotOnlyWhatIsShown() async throws {
    // Unlike showHiddenFiles: a counting stub sees a SECOND listing request
    // when the switch is on, and one when it is off.
}
@Test func togglingWhereItCannotApplyNeitherReListsNorErrors() async throws {
    // Review Focus 5, four cases: local pane, non-S3 backend, bucket-list
    // root, versioning off. Zero extra requests, state unchanged, no error.
}
@Test func restoringFromTheBrowserRowUsesTheMarkerIdTheRowCarries() async throws {
    // No second listing round trip: the stub counts one DELETE and no GET.
}
```

- [ ] **Step 2–4: red, implement, green**

The merged listing lives beside `displayItems(from:)` in `RemoteBrowserViewModel`, whose comment already states that the hidden-files filter is presentation-only — extend that comment to say why this one is not, and that the caller re-`load()`s.

- [ ] **Step 5: Commit**

---

### Task 11: Closeout — the rig, the docs, the backlog

**Files:**
- Create: `Tests/macSCPCoreTests/S3VersionsGatedTests.swift`
- Modify: `docs/BACKLOG.md`, `docs/superpowers/specs/2026-10-23-s3-version-history-and-metadata-design.md`, the user docs repository
- Commit: the spec itself, which until now has lived outside the tree

- [ ] **Step 1: Commit the spec into the tree**

It was approved on 2026-10-23 and written outside the worktree so the first half's merge tree stayed clean. It belongs at `docs/superpowers/specs/2026-10-23-s3-version-history-and-metadata-design.md`.

- [ ] **Step 2: Write the gated suite**

Behind `MACSCP_ITEST=1`, against the rig started **from the main checkout**. One case per measured row of spec §4.1–§4.3 and §4.8–§4.9, each asserting what that row recorded.

**Amended 2026-11-02, after Tasks 3 and 4.** The sentence above is kept and not withdrawn — those rows are still cases — but it was the whole of this step, and five measurements have since been carried here by decisions those two tasks had to make without a store. Each is named below with the decision that depends on it, because a measurement that lives only in the SDD ledger dies with the plan's gitignored workspace, and one of these is already promised by a doc comment in shipped source (`S3FileSystem.restore` names this task). Spec §4.4 is the row that covers the copy; it was not named above and is now.

1. **Does the store honour `versionId` in `x-amz-copy-source`?** (spec §4.4) `restore` is a self-copy naming a non-current version. If the store ignores the version id and copies the CURRENT content onto the key, the restore is wrong — and on the weak confirmation path (a multipart or opaque source ETag) it is reported as **done**. This is the one carried measurement whose failure direction is unsafe; the other four fail toward "could not be confirmed".
2. **Is a copy onto the same key accepted at all when it names a source version?** AWS refuses a self-copy that changes nothing; with a source `versionId` on a versioned bucket it is the standard restore idiom. Assumed legal in Task 4, unmeasured.
3. **Is a version delete visible to the immediately following read-back?** `deleteVersion` and `liftDeleteMarker` confirm by ABSENCE. A store whose delete is not yet visible to the next read reports a successful delete as failed.
4. **What does `delimiter=/` do on `?versions`?** `deletedEntries` sends it and does not read `CommonPrefixes`. Task 4's fix round made the one-level reading hold whatever the store answers, so this no longer decides correctness — it decides whether the delimiter is buying anything.
5. **Does a last page carry a `NextKeyMarker`?** The paging loop FOLLOWS a marker beside `IsTruncated=false`, which costs one extra request per listing. Measure whether that request is ever needed here.
6. **What does a version download's extra `ListObjectVersions` cost?** (added after Task 5) `VersionDownloadSource.stat` reads the history to size the transfer, so every version download pays one listing request before a byte moves. Unmeasured against a real store.

Buckets the suite creates and deletes itself; never `macscp-seed`, `macscp-second` or `macscp-probe-lock`; and **no COMPLIANCE retention on any bucket the suite means to delete.**

- [ ] **Step 3: Run it**

Run: `MACSCP_ITEST=1 swift test --filter S3VersionsGatedTests`
Expected: PASS. Record the figures in the commit body beside the commands that produced them.

- [ ] **Step 4: Backlog rows**

One row for the 5 GiB single-part copy ceiling (spec §3, unmeasured above 8 MiB). One row for anything this plan's reviews parked.

**Amended 2026-11-02, after Task 6's review.** One row for the availability prefetch: with the
unknown-offers-the-row policy ruled in Task 7, a bucket's versioning is read only when a surface
asks, so the disabled "Show Versions…" row and its reason are latent in a fresh session. The row
weighs that against one `GET ?versioning` per bucket navigation — a per-navigation request this
plan declined to add unmeasured — and names the cheaper half-measure too: seeding the cache from
the answer the Versioning sheet already reads.

**Amended 2026-11-02, after Task 5.** One row for `TransferFailureLabel`'s counted comment: Task 5's recount was its **seventh**, and the figure has been wrong on arrival every time (68, 69, 63, 57, 81, 78, now 91/29). CLAUDE.md's own answer to a property that keeps buying one spelling and revealing another is a structural boundary rather than another anchor, so the row argues for a TEST that counts those call sites — or for dropping the figure and keeping the recipes — not for an eighth recount. The row is the place to decide that; this plan does not.

- [ ] **Step 5: User documentation**

A `guide/` page in `noix-docs` under `src/content/docs/macscp/`, on its own branch in its own worktree, marked as coming in the next version. `npm run build` and `npm run check` both pass. **Not pushed or merged without the maintainer asking.**

- [ ] **Step 6: Commit**

---

## Self-Review

**Spec coverage.** Goal 1 → Tasks 1–3, 7. Goal 2 → Tasks 6, 8, 9. Goal 3 → Tasks 4, 5, 9. Goal 4 → Task 10. §5.1 → Tasks 1, 5. §5.2 → Task 10. §5.3 → Task 6. §6.1 → Tasks 7, 8. §6.2 → Task 9. §6.3 → Task 10. §7 constraints → Global Constraints. §11.1 → Task 5. Goals 5–7 and §§6.4–6.6 are Plan B's, named in the header. **One gap found and closed while checking:** nothing covered the audit kinds, which are now Task 4; and `AuditLogSheet.Filter.segment(of:)`'s exhaustive switch is named there, because adding a kind breaks that build on purpose.

**Step scan.** Every code step carries a signature or names the file to read for the pattern; no step says "handle edge cases". Two steps deliberately carry no body: Task 3's implementation and Task 7's, because the signature plus the tests fix them.

**Type consistency.** `ObjectVersion`, `ObjectVersionPage`, `DeletedEntry`, `RowState`, `VersionRowAction` are each defined once, in Tasks 1, 7 and 9, and referenced by those names afterwards. `deleteMarkerVersionID` is spelled the same in Task 10 and in spec §5.2.

**Review Focus.** All five lines have an owning task and a named test: 1 and 2 in Tasks 2–3, 3 in Task 2, 4 in Task 8, 5 in Task 10.

**Proportion.** Eleven tasks, and the plan is shorter than the spec. The code blocks are test names with assertions and one protocol definition — no implementation bodies, except where an algorithm is pinned in prose.
