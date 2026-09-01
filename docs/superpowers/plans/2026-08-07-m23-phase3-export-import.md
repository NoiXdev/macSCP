# M23 Phase 3 — Export and Import Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Finish the milestone — the export format derives its columns from the schema instead of listing them per protocol, the import builds its session through the same write adapter, and the last compile-forcing `ConnectionKind` switch outside the backend registry disappears.

**Architecture:** `ExportedSession`'s per-protocol column blocks (`s3*`, `webdav*`, and the flat SSH triple) collapse into one `fields: [String: String]` bag, written from `descriptor.sessionValues(session).raw` and read back through `descriptor.apply`. The export format version goes to 2, so an older macSCP refuses a newer file with a clear `unsupportedVersion` instead of half-understanding it. `duplicateKey` stops naming per-protocol fields by hand and keys off the same bag.

**Tech Stack:** Swift 6 toolchain in `.swiftLanguageMode(.v5)`, SwiftPM, macOS 15+, SwiftUI, Swift Testing.

**Spec:** `docs/superpowers/specs/2026-08-07-m23-sitzungs-lebenszyklus-design.md`
**Phase 1 close:** `docs/superpowers/specs/2026-08-07-m23-phase1-abschluss.md`
**Phase 2 close:** `docs/superpowers/specs/2026-08-07-m23-phase2-abschluss.md`

## Global Constraints

- **Code and comments: English only.** No German in source files, test names or `reason:` strings.
- **App UI is localized** across four catalogs (`en`/`de`/`fr`/`pl`) with identical key sets, enforced by a guard test. App strings live in the App target's catalog; Core's are `Sources/macSCPCore/Resources/<lang>.lproj/Localizable.strings`. French uses the typographic apostrophe (U+2019). **CLI output is English-only and not localized.**
- Swift tools 6.0, all targets `.swiftLanguageMode(.v5)`, minimum macOS 15.
- Tests: Swift Testing (`@Test`/`#expect`), TDD red→green.
- Unit suite: `swift test`. Gated: `MACSCP_ITEST=1`, `MACSCP_KEYCHAIN=1`.
- Docker rig: `docker compose -f docker/test-server/compose.yml up -d`, **always from the main checkout.**
- **Never commit key material or secrets.** Secrets live only in the Keychain and travel through export *only* in the encrypted path. A frozen fixture must contain no real key material.
- **TOFU is a hard stop.** Nothing here goes near host-key or certificate validation.
- Conventional Commits, English messages, footer `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`. **Commit only; never push.**
- Do not launch the GUI app.

## Starting state

Phases 1 and 2 are complete: `d499f26..ee26b7f`, 1553 tests in 129 suites green, gated suites green, 37 unpushed commits on `develop`.

The fourth-backend probe (add `case ftp`, build, revert) currently forces edits at `BackendDescriptor.swift` (7 sites — the registry, where it belongs) and **`SessionImportPlanner.swift:359`**. That last one is what this phase removes.

## The maintainer decision this phase is built on

**The export format takes a hard cut: a generic field bag, version 2.**

This is possible here and was not possible for `sessions.json` in Phase 1, because `ExportEnvelopeCodec` already validates the header before decoding the payload and throws `unsupportedVersion` for anything newer than it knows. An older macSCP therefore **refuses a v2 file with a clear message** rather than misreading it.

**The price, to be stated in the release notes:** exchanging `.macscp` files with older installations stops working entirely. Today's format is additive, so an older build can read a newer export minus the backends it does not know. After this, it cannot read it at all.

## File structure

**Modified**

| File | Change |
|---|---|
| `Sources/macSCPCore/Sessions/SessionExportCodec.swift` | `ExportedSession` loses its per-protocol columns and gains `fields`; `currentVersion` → 2. |
| `Sources/macSCPCore/Presentation/SessionListViewModel.swift` | `exportPayload` fills `fields` from `sessionValues`; its three kind branches go. |
| `Sources/macSCPCore/Sessions/SessionImportPlanner.swift` | `makePlanned` builds through `descriptor.apply`; `duplicateKey` keys off the bag; the `:359` switch goes. |
| `Sources/macSCPCore/Sessions/ImportConflict.swift` | Gains `Reason`, so the sheet can say what actually collided. |
| `Sources/MacSCPApp/ImportConflictSheet.swift` | Renders both reasons. |
| App + Core catalogs | New keys in all four. |

**Created**

| File | Responsibility |
|---|---|
| `Tests/macSCPCoreTests/Fixtures/legacy-export-v1.macscp.json` | A frozen v1 export. The only test that proves nobody's existing export file stops importing. |

---

### Task 1: The export format becomes a field bag

**Files:**
- Modify: `Sources/macSCPCore/Sessions/SessionExportCodec.swift`
- Modify: `Sources/macSCPCore/Presentation/SessionListViewModel.swift` (`exportPayload`, ~`:760-860`)
- Modify: `Sources/macSCPCore/Sessions/SessionImportPlanner.swift` (`makePlanned`, ~`:230-300`)
- Create: `Tests/macSCPCoreTests/Fixtures/legacy-export-v1.macscp.json`
- Test: `Tests/macSCPCoreTests/SessionExportCodecTests.swift`, `SessionImportPlannerTests.swift`

**Interfaces:**
- Consumes: `BackendDescriptor.sessionValues(_:) -> FieldValues`, `.apply: (FieldValues, inout StoredSession) -> Void`, `FieldValues.raw: [String: String]`, `FieldValues.setRaw(_:to:)`.
- Produces: `ExportedSession.fields: [String: String]`; `ExportedSession.legacy*` decode-only columns; `SessionExportCodec.currentVersion == 2`.

**The shape.** `ExportedSession` keeps everything that is *not* a backend field — `id`, `name`, `groupID`, `kind`, `password`, the jump block, `s3SecretAccessKey` — and replaces `host`/`port`/`username`/`authKind`/`keyPath` and both per-protocol blocks with:

```swift
    /// Every backend field this session carries, keyed exactly as
    /// `FieldValues` keys them (`"<namespace>.<fieldID>"`).
    ///
    /// Replaced the per-protocol column blocks in M23/P3. Those had to grow a
    /// block per backend — the thing this milestone exists to stop — and they
    /// carried SSH's flat triple at the top level, where a pre-M23 export
    /// wrote the literal `"unused"` for every S3 and WebDAV session.
    ///
    /// SECRET-FREE by construction: `sessionValues` reads a `StoredSession`,
    /// which never holds a secret. Secrets travel in `password` /
    /// `s3SecretAccessKey` / `jumpPassword`, and only in the encrypted path.
    public var fields: [String: String]
```

**Reading a v1 file is still required.** Keep the old columns as **decode-only** properties, renamed with a `legacy` prefix and marked as such, and add a `CodingKeys` mapping so they still decode from the original key names. `SessionExportCodec.decode` upgrades a v1 payload into the bag before the planner ever sees it. Do **not** put the upgrade in the planner — the planner should only ever see one shape.

- [ ] **Step 1: Write the frozen v1 fixture**

`Tests/macSCPCoreTests/Fixtures/legacy-export-v1.macscp.json` — a **v1** payload in today's exact shape, unencrypted, with one session of each kind, a group, and a jump. Model it on what `SessionExportCodec.encode` produces today: run the existing export path once in a scratch test to see the real key names and envelope shape, then hand-write the fixture from that. **Never regenerate it from the new model** — the moment you do, it stops being evidence.

It must contain **no real key material**: a `password` field may hold `"not-a-real-secret"`, and the file must be the unencrypted variant so no crypto material is involved at all.

- [ ] **Step 2: Write the failing tests**

Add to `Tests/macSCPCoreTests/SessionExportCodecTests.swift`:

```swift
/// The one test that proves an export file somebody already has still
/// imports. Everything else about this phase is provable by argument; this
/// is a fact about bytes on disk.
@Test func aV1ExportStillDecodesIntoTheFieldBag() throws {
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/legacy-export-v1.macscp.json")
    let payload = try SessionExportCodec.decode(try Data(contentsOf: url))

    let prod = try #require(payload.sessions.first { $0.name == "Prod" })
    #expect(prod.kind == .ssh)
    #expect(prod.fields["SSHField.host"] == "prod.example.com")
    #expect(prod.fields["SSHField.port"] == "2222")
    #expect(prod.fields["SSHField.username"] == "deploy")

    let archive = try #require(payload.sessions.first { $0.name == "Archive" })
    #expect(archive.kind == .s3)
    #expect(archive.fields["S3Field.bucket"] == "archive")
    #expect(archive.fields["S3Field.usePathStyle"] == "true")
    // The v1 file carried SSH's flat triple for every kind, holding the
    // literal placeholder. It must NOT survive into the bag.
    #expect(archive.fields["SSHField.host"] == nil)

    let cloud = try #require(payload.sessions.first { $0.name == "Cloud" })
    #expect(cloud.kind == .webdav)
    #expect(cloud.fields["WebDAVField.baseURL"] == "https://cloud.example.com/remote.php/dav")
}

/// A v2 file round-trips through the bag with no column-shaped loss.
@Test(arguments: ConnectionKind.allCases)
func aSessionRoundTripsThroughTheBag(kind: ConnectionKind) throws {
    let session: StoredSession
    switch kind {
    case .ssh: session = sshSession(
        name: "s", host: "h.example.com", port: 2222, username: "u",
        authKind: .privateKey, keyPath: "/k")
    case .s3: session = s3Session(name: "s")
    case .webdav: session = webdavSession(name: "s")
    }

    let descriptor = BackendDescriptor.descriptor(for: kind)
    var exported = ExportedSession(
        id: session.id, name: session.name, kind: kind,
        fields: descriptor.sessionValues(session).raw)
    exported.groupID = nil

    var rebuilt = StoredSession(
        id: session.id, name: session.name, kind: kind)
    var values = FieldValues()
    for (key, value) in exported.fields { values.setRaw(key, to: value) }
    descriptor.apply(values, &rebuilt)

    #expect(rebuilt == session)
}
```

**`ExportedSession`'s initializer is currently memberwise with many parameters.** Give it whatever shape makes these two tests read cleanly; if the memberwise initializer becomes unwieldy, add an explicit one. Say in your report what you chose.

- [ ] **Step 3: Run them to verify they fail**

Run: `swift test --filter SessionExportCodec 2>&1 | tail -20`
Expected: compile failure — `ExportedSession` has no `fields`.

- [ ] **Step 4: Reshape `ExportedSession` and bump the version**

Remove `host`, `port`, `username`, `authKind`, `keyPath`, `s3AccessKeyID`, `s3Region`, `s3Endpoint`, `s3Bucket`, `s3UsePathStyle`, `webdavBaseURL`, `webdavUsername`, `webdavUseNextcloudPath` from the encoded surface; add `fields`. Keep them as decode-only `legacy*` properties with a `CodingKeys` mapping to the original names, so a v1 payload still decodes.

Set `SessionExportCodec.currentVersion = 2`, and write a comment at that line stating what the bump buys and what it costs — an older macSCP refuses a v2 file with `unsupportedVersion` instead of half-reading it, and `.macscp` interchange with older installations ends.

Add the v1→bag upgrade inside `SessionExportCodec.decode`, so the planner only ever sees the bag. **The upgrade must not carry SSH's flat triple onto a non-SSH session** — a v1 file holds the literal `"unused"` there, and importing it would resurrect exactly the placeholder Phase 1 removed. Build the SSH keys only when `kind == .ssh` (absent `kind` means `.ssh`, as today).

- [ ] **Step 5: Fill the bag on the export side**

In `SessionListViewModel.exportPayload`, replace the three `if session.kind == …` blocks with one `descriptor.sessionValues(session).raw`. The jump block, the group mapping, and the three secret slots are **not** backend fields and stay exactly as they are.

**Read the existing body before deleting it.** It resolves a set-bound login into the set's own values at export time (sets are never exported) — that resolution must survive. If it happens outside the three branches you are deleting, nothing to do; if inside, carry it over and say so in your report.

- [ ] **Step 6: Build through the adapter on the import side**

In `SessionImportPlanner.makePlanned`, replace the `s3`/`webdav`/`ssh` block construction with:

```swift
        var values = FieldValues()
        for (key, value) in fileSession.fields { values.setRaw(key, to: value) }
        var session = StoredSession(id: id, name: name, groupID: groupID, kind: kind)
        BackendDescriptor.descriptor(for: kind).apply(values, &session)
```

then attach the jump to `session.ssh` afterwards, exactly as today — `apply` does not own it, and a jump must still land only on an `.ssh` session.

- [ ] **Step 7: Run everything**

```bash
swift build 2>&1 | tail -3
swift test 2>&1 | tail -3
```

Baseline before this task: **1553 tests in 129 suites.** Several import/export tests construct `ExportedSession` by hand and will need their fixtures reshaped — reshape them, do not weaken their assertions. If a test's *subject* was a per-protocol column, its subject is now a bag key; that is a relocation, not a deletion.

Then the gated suite, because the export/import round trip has one there:

```bash
docker compose -f docker/test-server/compose.yml up -d
MACSCP_ITEST=1 swift test 2>&1 | tail -5
```

- [ ] **Step 8: Commit**

```bash
git add Sources Tests
git commit -m "feat(core): export every backend field as one schema-keyed bag

ExportedSession's per-protocol column blocks collapse into fields:
[String: String], written from descriptor.sessionValues and read back
through descriptor.apply. A fourth backend now costs zero export columns.

The format version goes to 2, which the envelope already checks: an older
macSCP refuses a v2 file with unsupportedVersion instead of half-reading
it. The price is that .macscp interchange with older installations ends —
that belongs in the release notes.

A frozen v1 fixture proves an export somebody already has still imports,
and that the flat SSH triple a v1 file carried for every kind — holding
the literal \"unused\" — does not survive into the bag.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: `duplicateKey` off the bag — the last compile-forcing site

**Files:**
- Modify: `Sources/macSCPCore/Sessions/SessionImportPlanner.swift` (`duplicateKey`, both overloads, ~`:334-380`)
- Test: `Tests/macSCPCoreTests/SessionImportPlannerTests.swift`

**Interfaces:**
- Consumes: `BackendDescriptor.sessionValues(_:)`, `ExportedSession.fields` (Task 1).
- Produces: a single `duplicateKey` taking `(kind:fields:)` instead of the eight hand-named parameters.

**Why this is the phase's structural payoff.** `duplicateKey` currently has two overloads and an eight-parameter signature naming `host`, `port`, `username`, `s3Endpoint`, `s3Bucket`, `s3AccessKeyID`, `webdavBaseURL`, `webdavUsername`, plus a `switch kind` at `:359` — the one compile-forcing `ConnectionKind` site left outside the backend registry. Keyed off the bag it becomes kind-prefix plus a stable rendering of the identifying fields.

**What must not change:** the doc comment on the current implementation records hard-won semantics — SSH keeps the endpoint triple byte for byte; the keys are kind-prefixed so an S3 and a WebDAV session can never share one; values are taken verbatim with no case folding, because a URL path, a bucket name and an access key ID are all case-sensitive. **Read that comment in full and preserve every rule it states.** Carry the reasoning forward rather than deleting it.

**The open question, which you answer with evidence rather than a guess:** which fields identify a connection, per backend? Today: SSH `host`+`port`+`username`; S3 `endpoint`+`bucket`+`accessKeyID`; WebDAV `baseURL`+`username`. Those are *not* simply "all fields" — S3's `region` and `usePathStyle` are excluded, and rightly: two sessions differing only in `usePathStyle` are the same connection.

So the bag alone does not answer it. Decide between:
- **(a)** a new declaration on `ConnectionField` — e.g. `isIdentifying: Bool` — so each backend states which of its fields make a connection distinct, checked by a guard test that every backend marks at least one; or
- **(b)** keeping a small per-backend list in the descriptor.

**(a) is the shape this milestone has used throughout** and makes a fourth backend declare its answer instead of inheriting a default. Prefer it unless you find a reason it does not work, and say what you found either way.

- [ ] **Step 1: Write the failing tests**

**Five cases, one per rule the old doc comment records.** `duplicateKey` is private, so these go through `SessionImportPlanner.plan(...)` — **follow the shape of the 19 existing tests in `Tests/macSCPCoreTests/SessionImportPlannerTests.swift`**, which already drive duplicate behaviour that way.

| Test | Setup | Expected |
|---|---|---|
| `twoSessionsToTheSameSSHEndpointCollide` | two `.ssh` entries, **different names**, same host/port/username | the second raises a conflict |
| `aDifferentPortIsADifferentConnection` | two `.ssh` entries, same host/username, ports 22 and 2222 | both import, no conflict |
| `anS3AndAWebDAVSessionNeverShareAKey` | one `.s3` and one `.webdav` whose remaining identifying values are contrived to match | both import, no conflict |
| `caseIsNotFoldedInABucketNameOrAURLPath` | two `.s3` entries differing only by `archive` vs `Archive` | both import, no conflict |
| `twoS3SessionsDifferingOnlyInPathStyleCollide` | two `.s3` entries, identical but for `usePathStyle` | the second raises a conflict |

The last one is the case that motivates (a) over "key on every field": `usePathStyle` is a transport detail, not an identity.

**A deliberate deviation, and why.** I am specifying these as cases rather than pasting Swift. Across the two previous phases, four defects came from plan-authored test code I had written but never compiled — a wrong `requiresSecret` guard, a missing `values[SSHField.host]`, a single-line `grep`, a discriminator that discriminated nothing. The table above is unambiguous about setup and expectation and points at the file whose shape to copy; inventing a `plan(...)` call signature I have not run would be the less reliable of the two. If any case turns out not to be expressible through `plan`, say so rather than reshaping the rule to fit.

- [ ] **Step 2: Run to verify they fail, then implement**

Whichever of (a)/(b) you chose, `duplicateKey` ends up as one function over `(kind, fields)` with no `switch kind` in its body.

- [ ] **Step 3: Prove the compile-forcing site is gone**

```bash
# add `case ftp` to ConnectionKind, then:
swift build 2>&1 | grep -E 'error:' | sort -u
```

Expected: errors **only** in `Sources/macSCPCore/Capabilities/BackendDescriptor.swift`. If `SessionImportPlanner` still appears, the task is not done. **Revert the probe and confirm `git status` is clean**, and quote the exact list in your report.

- [ ] **Step 4: Run everything and commit**

`swift test` green, then `MACSCP_ITEST=1 swift test`. Commit with a message naming which rules the new key preserves.

---

### Task 3: The conflict sheet says what actually collided

**Files:**
- Modify: `Sources/macSCPCore/Sessions/ImportConflict.swift`
- Modify: `Sources/macSCPCore/Sessions/SessionImportPlanner.swift:157`, `Sources/macSCPCore/Sessions/LoginSetImportPlanner.swift:101`
- Modify: `Sources/MacSCPApp/ImportConflictSheet.swift:61,64`
- Modify: all four App catalogs
- Test: `Tests/macSCPCoreTests/ImportConflictTests.swift`

**The defect, verified in the code rather than assumed.** The sheet says **"Name Already Exists"** and *"'%@' already exists"* with the item's name. For a **login set** that is true — `LoginSetImportPlanner:88` keys on `normalizedKey(fileSet.name)`. For a **session** it is false: `SessionImportPlanner:141` keys on `duplicateKey`, the endpoint. So importing a session named "Backup Server" that points at the same host as a stored "prod" raises a dialog claiming the *name* is taken, and the user — seeing a name they do not recognise as theirs — reaches for Replace. That is the wording that made the old shared-key defect destructive.

`ImportConflict`'s own doc comment repeats the falsehood: *"an incoming item's name already matches something in the existing store."*

**The fix:** `ImportConflict` says which it is.

```swift
public struct ImportConflict: Equatable, Sendable {
    public var itemName: String
    public var kindLabel: String
    /// What made this a collision. Two planners share this type and collide on
    /// different things — a login set on its NAME, a session on its
    /// CONNECTION — and one message for both told the name story for both.
    public var reason: Reason

    public enum Reason: Equatable, Sendable {
        /// The incoming item's name is already taken.
        case name
        /// A stored item already points at the same place. `existing`
        /// identifies it the way the sidebar does, so the user can tell
        /// which of their connections is about to be replaced.
        case sameConnection(existing: String)
    }
}
```

`existing` comes from `descriptor.displaySummary(descriptor.sessionValues(session))` — the same one-line identity the sidebar and the audit trail already use, so the phase's own mechanism supplies it.

**Copy, English (the other three are yours to translate consistently with the existing catalog register):**

| Case | Title | Message |
|---|---|---|
| `.name` | Name Already Exists | "%@" already exists. |
| `.sameConnection` | Connection Already Exists | "%@" points at the same server as "%@". |

Do not reuse `import.conflict.title`/`import.conflict.message` for the new case — add new keys, so a translator sees both strings and the old ones keep their meaning for login sets.

- [ ] **Step 1: Write the failing test**

Two cases. Both drive the real planners through an `ImportConflictArbiter` whose decider **captures the `ImportConflict` it is handed** and returns `.skip` — the existing tests in `SessionImportPlannerTests.swift` and `LoginSetImportPlannerTests.swift` already build a capturing decider that way; reuse it rather than inventing one.

| Test | Setup | Expected |
|---|---|---|
| `aSessionConflictReportsTheConnectionItCollidedWith` | import two `.ssh` sessions with **different names** and the same host/port/username | the captured conflict's `reason` is `.sameConnection`, and its `existing` string is the stored session's `displaySummary` (`deploy@prod.example.com:2222`) — assert the exact string, not merely non-empty |
| `aLoginSetConflictReportsTheName` | import two login sets with the same name | the captured conflict's `reason` is `.name` |

Same deviation and same reason as Task 2 Step 1: the cases are stated precisely and point at the existing shape, rather than pasting a decider signature I have not compiled.

- [ ] **Step 2: Run to verify they fail, then implement**

Then correct `ImportConflict`'s own doc comment — it currently states the falsehood this task removes. **This milestone has found nine instances of a claim written into the tree that nobody traced; do not let the fix add a tenth.** Check every sentence you write against the two planners.

- [ ] **Step 3: Catalogs, then run**

Add both new keys to all four App catalogs. `swift test` green — the key-set guard test will fail if a catalog is missed.

- [ ] **Step 4: Commit**

---

### Task 4: Phase close and milestone close

- [ ] **Step 1: Prove the milestone's headline criterion**

Run the fourth-backend probe one last time. Expected: **only `BackendDescriptor.swift`.** That is the milestone's whole claim — a fourth `ConnectionKind` is declared in the registry and nowhere else. Quote the exact list. Revert, confirm clean.

If anything outside the registry still appears, that is the finding, and it goes to the maintainer rather than into a workaround.

- [ ] **Step 2: Sweep the conveniences Phase 1 left**

Phase 1 added six read-only accessors on `StoredSession` (`host`, `port`, `username`, `authKind`, `keyPath`, `jump`) as scaffolding, with an explicit deprecation intent and ~25 callers. Tasks 1 and 2 remove the export/import ones. List every remaining caller and judge each: legitimately "the host, if there is one", or treating `""` as a real host. Delete the ones that are now unused; for the rest, record in the close file which are legitimate and why. **Do not delete an accessor that still has a legitimate caller just to reach zero.**

- [ ] **Step 3: Full matrix**

```bash
swift build 2>&1 | tail -2
swift test 2>&1 | tail -2
docker compose -f docker/test-server/compose.yml up -d
MACSCP_ITEST=1 swift test 2>&1 | tail -2
MACSCP_KEYCHAIN=1 swift test --filter Keychain 2>&1 | tail -2
for lang in en de fr pl; do
  plutil -lint "Sources/macSCPCore/Resources/$lang.lproj/Localizable.strings"
done
```

- [ ] **Step 4: Whole-phase review**

Dispatch a fresh reviewer over the phase diff. The questions that matter:

1. **Can a v1 export lose data?** Compare the upgrade path field by field against what v1 wrote. Specifically: does a v1 S3 or WebDAV session's flat SSH triple stay out of the bag, and does its per-protocol block arrive intact?
2. **Does `duplicateKey` still enforce every rule its old doc comment recorded?** One test per rule, and each would fail if the rule were dropped.
3. **Is the conflict copy true for both planners?** A reviewer should read both and confirm the reason matches what each actually keys on.
4. **The usual sweep:** anything the phase built that goes unused; two mechanisms for one job; a doc comment a later task made false.

- [ ] **Step 5: Write the close record**

Write `docs/superpowers/specs/2026-08-07-m23-abschluss.md` and, because this closes M23, a short **milestone** summary: the criteria table across all three phases, the consolidated release-notes list (Phase 1's `sessions-v2.json` divergence and anonymous WebDAV; Phase 2's four items; Phase 3's end of `.macscp` interchange), and the follow-ups nobody owns yet.

**Do not push.**

---

## Self-review

**Spec coverage.** Phase 3's spec section names three things: `ExportedSession` deriving its columns from the schema (Task 1), the import building through the write adapter (Task 1, Step 6), and the misleading conflict sheet (Task 3). Task 2 is not in the spec by name — it is there because Phase 2's close record identified `SessionImportPlanner:359` as the last compile-forcing site, and success criterion 1 is not met while it stands.

**Two places this plan deliberately does not decide for the implementer**, because Phase 1 and 2 both showed that plan-authored answers to questions I have not tested are the least reliable part of a plan:
- Task 2's identifying-fields question. I state the evidence (which fields the current key uses and which it excludes), name the two shapes, say which I prefer and why, and require the implementer to report what they found.
- Task 1 Step 2's `ExportedSession` initializer shape. The test code I wrote assumes one; the real one may not fit, and I would rather the implementer choose than transcribe something that does not compile.

**A stated deviation from the no-placeholders rule.** Tasks 2 and 3 specify their tests as tables of (name, setup, expectation) plus a pointer to the file whose shape to copy, instead of pasted Swift. That is a deliberate trade, argued at both sites: four of the defects found across Phases 1 and 2 came from plan-authored test code that had never been compiled. A table that is unambiguous about setup and expectation is more reliable than a call signature I would be inventing. Task 1's tests *are* written out, because there I could derive the shapes from types I had read.

**Known risk.** Task 1's frozen v1 fixture must be hand-written from a real v1 export, not from the new model. If it is generated from the new code it proves nothing, and it is the only test standing between this change and somebody's existing export file. The step says so twice for that reason.

**Not covered, on purpose.** The CLI still refuses a login-set-bound or jump-configured session (`loginSetSessionsNotSupported`, `jumpSessionsNotSupported`). That predates the milestone and no phase claims to change it.
