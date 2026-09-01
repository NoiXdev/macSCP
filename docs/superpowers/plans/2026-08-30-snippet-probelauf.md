# Snippet dry run and per-snippet opt-out — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make visible, before sending, what actually goes out over the
wire — and make the rejection bypassable with evidence rather than a
blanket promise.

**Basis:** `docs/superpowers/specs/2026-08-30-snippet-probelauf-design.md`

**Architecture:** The display is a pure value in `macSCPCore`, built
from the snippet, the values, and the send plan. Both entry points —
triggering and "Test" — show the same value. The opt-out is a field on
`Snippet` that export **does not know about**.

## Global Constraints

- Code, comments, identifiers, test names, commit messages: **English
  only**.
- Conventional Commits; footer `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- **The substituted value must appear in no log, no export, and no
  error message** — not even a test failure message. The audit log
  carries the template.
- **No change to `SnippetCommandSurvey`**, and none to `SnippetSendPlan`'s
  rejection of a multi-line insertion.
- User-visible text in **all four catalogs** (`en`, `de`, `fr`, `pl`
  under `Sources/MacSCPAppKit/Resources/<locale>.lproj/Localizable.strings`)
  via `L10n.string(_:_:)`; Core-side `CoreL10n.string(_:)`. **No String
  Catalog, no `String(localized:)`, no `Bundle.module`.** The German
  uses **du**.
- **Only show what is possible** — nothing gets greyed out.
- **No line numbers, no location references in comments.** Every number
  and every enumeration gets counted in the same pass that writes it.
- All six targets are on `.swiftLanguageMode(.v6)`; **CI goes red as
  soon as the count of distinct warning sites exceeds 1.** Warnings are
  measured on a **fresh** scratch path — an incremental build does not
  re-expand the `#expect` macro, and that has reported zero twice this
  week where a fresh build found two.
- One scratch path per agent, deleted after use. The app is not
  launched, nothing is pushed.

---

### Task 1: The export gets its own type

**Files:**
- Modify: `Sources/macSCPCore/Terminal/SnippetExportCodec.swift`,
  `Sources/macSCPCore/Terminal/SnippetImportPlanner.swift`
- Test: the existing export/import suites, plus new cases

**Why first:** the opt-out from Task 2 must not exist for a single
second without the boundary in place. The other way around, Task 2
would be a field that travels through export and import, and the very
bug this whole change exists to avoid would briefly be built in.

**The measured current state:** `SnippetExportPayload` carries
`[Snippet]` — the same type the store persists. Sessions solve this
differently (`ExportedGroup`, `ExportedSession`); **read
`SessionExportCodec` as the model**, including its comments on why an
executed identifier is file-local.

- [ ] **Step 1: Red first.** A test that proves a field on `Snippet`
  currently travels through a round trip. Use an **existing** field for
  this — the new one does not exist yet.
- [ ] **Step 2: Introduce `ExportedSnippet`.** Carries the fields that
  belong shared. Identifier re-keying follows what the session planner
  does; **look it up instead of inventing it.**
- [ ] **Step 3: The old form stays readable.** A file written by an
  earlier version imports unchanged. Test for it.
- [ ] **Step 4:** Full suite green, no new warning (fresh build).
- [ ] **Step 5: Commit** — `refactor(snippets): give the export its own type`

---

### Task 2: The opt-out

**Files:**
- Modify: `Sources/macSCPCore/Terminal/Snippet.swift`,
  `Sources/macSCPCore/Terminal/SnippetVariableSubstitution.swift` (or
  wherever the placement check is called — **verify this**), the snippet
  editor
- Test: new cases plus the existing substitution suites

- [ ] **Step 1: Red first.** A snippet with the opt-out set resolves a
  placeholder that the check would otherwise reject; without the
  opt-out it is still rejected. Both directions.
- [ ] **Step 2: The field.** Optional when decoding, with a default of
  "check on", so every existing file stays readable unchanged —
  `Codable` synthesizes no default value for a **missing** key, it
  throws. Verify this with real JSON that omits the key, not with a
  round trip through an in-memory value.
- [ ] **Step 3: It switches off only the placement check, nothing
  else.** `SnippetSendPlan`'s rejection of a multi-line insertion stays
  untouched — its own test.
- [ ] **Step 4: The mandatory proof.** An imported snippet **never**
  carries the opt-out. Prove it by trying to write it into an export
  file: it must be inexpressible. If the attempt compiles, Task 1 is
  incomplete and that must be reported.
- [ ] **Step 5: Visible in the editor**, with text that names **what**
  is being switched off. All four catalogs, the German uses du.
- [ ] **Step 6:** Full suite green, no new warning (fresh build).
- [ ] **Step 7: Commit** — `feat(snippets): let one snippet opt out of the placement check`

---

### Task 3: The dry run as a value

**Files:**
- Create: `Sources/macSCPCore/Terminal/SnippetDryRun.swift`
- Test: `Tests/macSCPCoreTests/SnippetDryRunTests.swift`

**Interfaces:**
- Produces: a value that describes, from the snippet, the values, and
  the send plan, what gets displayed. Task 4 calls it from **both**
  entry points.

- [ ] **Step 1: Red first.** What the value carries, in tests: the
  resolved command; which send form would be chosen; whether it was
  rejected and why; the highlighting via `SnippetHighlighter`.
- [ ] **Step 2: Implement.** The value **assembles**, the view does not.
- [ ] **Step 3: The case from the entry.** `P=neu echo "$P"` as a
  fixture — the resolved text must show it, because that is the case
  the dry run exists to make visible.
- [ ] **Step 4: Verify the commitment.** A test that proves the
  substituted value appears in **no** audit line and **no** error
  message. That is this change's promise, so it belongs in a test, not
  in a comment.
- [ ] **Step 5:** Full suite green, no new warning (fresh build).
- [ ] **Step 6: Commit** — `feat(snippets): describe what a dry run shows`

---

### Task 4: The two entry points

**Files:**
- Modify: the trigger path (`ContentView`, where `SnippetSendPlanner.plan`
  is called), the snippet editor
- Modify: all four `Localizable.strings`
- Test: `Tests/macSCPAppKitTests/`

**Interfaces:**
- Consumes: Task 3.

- [ ] **Step 1: The path on triggering.** If a snippet is rejected, the
  dry run appears with a reason and **"send anyway"**. Without a
  rejection, nothing about triggering changes — the dry run is not a
  confirmation step.
- [ ] **Step 2: The "Test" button in the editor.** Shows the same
  value, sends nothing. Uses **the same** value query as triggering; a
  second query form would be a second truth about what a value is.
- [ ] **Step 3: Remember nothing.** What the editor's dry run queries
  must **not** pre-fill the next real run. Its own test.
- [ ] **Step 4: A guard that pins both entry points to the same
  value** — with a **positive** check beside it that both call sites
  actually exist. A negative check alone goes stale silently, and this
  guard scans source: the **whole statement**, not a line, and it must
  not anchor on a comment.
- [ ] **Step 5:** Full suite green, no new warning (fresh build).
- [ ] **Step 6: Commit** — `feat(snippets): show the dry run from both entrances`

---

## What explicitly is not part of this

- **No global toggle** in settings.
- **No change to the allowlist** of `SnippetCommandSurvey`.
- **No dry run before every trigger.**
- **No remembering values from the editor's dry run.**
