# Import Planner: an Unusable Field Bag Is Rejected, Not Imported — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A file entry whose field bag cannot make a dialable session — the
bag has only `SSHField.keyPath`, or is empty but carries jump fields — is
counted under `rejected` like the empty-bag case already is, instead of
being imported as a record that is visible but not selectable.

**Architecture:** `SessionImportPlanner` today lets a bag through as soon as
it is not empty (`if !fileSession.fields.isEmpty` in `makePlanned`, gate in
the loop via `wouldBeDroppedByStore`). The new gate asks the backend's own
schema — `BackendDescriptor.descriptor(for: kind).firstViolation(in:requireSecrets: false)`,
the same check the connection form's Save runs — over the bag laid on top
of the schema's defaults (so an entry without a `port` key is still fine:
`apply` would have defaulted it anyway). A violation means the entry is
rejected before `makePlanned` builds anything. This is one rule for both
forms named in the backlog entry: the half bag, and the jump-only twin
(whose bag is empty, so it fails the same check — the jump attachment can
no longer rescue it, because the check runs before the attachment).

**Tech Stack:** Swift 6, Swift Testing; `Tests/macSCPCoreTests/SessionImportPlannerTests.swift`.

**Source:** `docs/superpowers/specs/2026-08-19-backlog-import-planner.md`.

## Global Constraints

- Code, comments, identifiers, test names, commit messages: **English only**.
  Conventional Commits; footer exactly `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- **The store's rule is not copied.** `SessionStore.dropsOnLoad` stays the
  judge for "would be dropped"; the schema stays the judge for "cannot be
  dialed". No third rule that spells required field names.
- **No secret reaches a report.** The rejected list holds names only, as
  today. The probe's `PlannedSession` (which carries the password) is
  never built for a rejected entry — that is a property, test it.
- Non-`.ssh` kinds get the same treatment through their own descriptor
  (`.s3` without a bucket key: the S3 schema requires bucket and region
  since 2026-09-02, with `region` defaulted — test one S3 case, one WebDAV
  case).
- `.swiftLanguageMode(.v6)`; warning budget 1 on a fresh scratch path.
- TDD red first. One commit for Task 1, one for Task 2. Do not push.

---

### Task 1: The gate

**Files:**
- Modify: `Sources/macSCPCore/Sessions/SessionImportPlanner.swift`
  (`wouldBeDroppedByStore` ~line 378 and its caller ~line 232; the long
  comment block ~lines 437-448 that documents the jump-only remainder —
  it stops being a remainder, so the comment is rewritten, not appended to)
- Test: `Tests/macSCPCoreTests/SessionImportPlannerTests.swift`

**Interfaces:**
- Produces: `private static func isUnusable(_ fileSession: ExportedSession) -> Bool`
  beside `wouldBeDroppedByStore`; the loop rejects when either is true.

- [ ] **Step 1: Red.** Five tests (the suite builds `ExportedSession` values
  by hand — follow the neighbours): (a) SSH entry whose bag holds only
  `SSHField.keyPath` → `rejected == [name]`, `sessionsToImport` empty;
  (b) SSH entry with an empty bag plus `jumpHost`/`jumpUsername` →
  rejected; (c) SSH entry with `SSHField.host` and `SSHField.username`
  but NO `SSHField.port` key → imported, session port 22 (this pins the
  defaults overlay — without it the numeric check reads `""` as
  unparsable); (d) S3 entry whose bag has endpoint + access key but no
  `S3Field.bucket` → rejected; (e) WebDAV entry without `WebDAVField.url`
  (read the schema for the exact required id) → rejected. The rejected
  count for the mixed file is the sum, and the entries around them are
  still imported.
- [ ] **Step 2: Implement.** `isUnusable`: start from
  `BackendDescriptor.descriptor(for: kind).defaultValues` (the plain defaults —
  NOT `editBaseline`, which is the edit form's toggle-only baseline and
  lacks the S3 region), overlay `fileSession.fields` via `setRaw`, and
  return `descriptor.firstViolation(in: values, requireSecrets: false) != nil`.
  Gate in the loop: `guard !wouldBeDroppedByStore(fileSession), !isUnusable(fileSession) else { rejected.append(trimmedName); continue }`.
  Doc comment: why the schema and not a field list; why defaults are
  overlaid; why `requireSecrets: false` (the secret travels in its own
  column and its absence is a legal import).
- [ ] **Step 3: The comment at ~437-448** now says the jump-only shape is
  rejected by `isUnusable` before the attachment runs, and that
  `wouldBeDroppedByStore` still exists for the empty-bag-no-jump shape
  only because the store's rule is the store's — the two overlap on that
  shape and that is fine. Search the tests for comments naming the old
  remainder (`grep -rn "out-of-scope remainder\|jump-only" Sources Tests`) and
  fix them in the same commit.
- [ ] **Step 4: Run** `swift test --filter SessionImportPlannerTests`, then the full unit suite; warnings on a fresh scratch path.
- [ ] **Step 5: Commit** — `fix(import): reject a field bag the backend's own schema cannot dial`

---

### Task 2: The entry closes

**Files:**
- Modify: `docs/superpowers/specs/2026-08-19-backlog-import-planner.md`, `docs/BACKLOG.md` (its row)

- [ ] **Step 1:** Append "Done 2026-09-02": the rule (schema over defaults,
  `requireSecrets: false`), both forms covered by one gate, the five test
  shapes, the commit hash. Index row to match.
- [ ] **Step 2: Commit** — `docs(backlog): the import planner rejects what it cannot dial`

## What is explicitly not in this plan

- No repair of half bags (no guessing a host). Reject and count.
- No change to `SessionStore.dropsOnLoad`.
- No user-facing text change: the `rejected` count already has its sentence.
