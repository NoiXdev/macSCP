# P3b: Exporting and Importing Snippets — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Snippets can be written to a file and read back — via the same
envelope as sessions and login sets, always without a password.

**Architecture:** A codec on top of `ExportEnvelopeCodec` with its own
format name, a planner on the **shared** `ImportConflictArbiter`, and two
sheets following the pattern of the existing ones. Nothing about the
envelope itself is touched.

**Tech Stack:** Swift 6, `.swiftLanguageMode(.v5)`, SwiftPM, macOS 15+,
SwiftUI, Swift Testing, two test targets.

Spec: `docs/superpowers/specs/2026-08-18-p3-order-design.md`, section P3b.

## Global Constraints

- **Code, comments, test names: English.** Internal docs (`docs/`) German.
- **Every new L10n key in all four catalogs** (en/de/fr/pl), identical key
  sets. Proof:
  `for f in $(git ls-files '*.strings'); do plutil -lint "$f"; done`
- **Never a line number in a comment.**
- **No secret in a log, error, or test failure message.** Snippets contain
  none — and this format gets **no crypto path** that would suggest
  otherwise.
- **This plan's prose is a claim to be checked.** In the previous phase,
  **five** task descriptions contained a factual error about the code. If
  something diverges, **the plan** is wrong — report it, do not adapt.
- **Two probes before every commit**, both:
  1. Would a test stay green if the function returned a constant?
  2. **Which claim of my doc comment is observed by no test?**
     This question has found something every time in the last three
     phases, twice a plainly false statement.
- **The GUI is not started.** `scripts/package-app` is allowed,
  `scripts/release` is not.
- Conventional Commits, English, footer:
  `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`
- Full suite green before every commit. Starting state: **2024 tests in 174
  suites** — measure it yourself, never copy it from here.

## Measured current state

Verified myself before writing the plan — check it anyway:

- `ExportEnvelopeCodec` is already generic:
  `encode<P: Codable>(_:format:version:password:)`, `probe`, `decode`.
  With `password == nil`, a plaintext payload with `encrypted: false`
  results. **A plaintext path already exists.**
- Two formats use it: `SessionExportCodec` (`macscp-sessions`) and
  `LoginSetExportCodec` (`macscp-logins`). Both consist of
  `static let formatName`, `static let currentVersion`, and three thin
  `encode/probe/decode` wrappers around the envelope.
- `LoginSetImportPlanner` is the precedent for **name-based** duplicates:
  `plan(existing:incoming:arbiter:) async -> LoginSetImportPlan`,
  collision key **trimmed, case-insensitive name**, `takenNames`
  pre-seeded with the existing stock and extended on every name assigned,
  `replacedExistingIDs` against double replacement, and **cancellation
  discards the whole run**, not just the rest.
- `ImportConflict(itemName:kindLabel:reason:)` with `reason: .name`.
- `SnippetStore` writes `snippets.json` as a **bare array with no version
  field**; methods `all() throws`, `save(_:) throws`, `remove(id:) throws`.
  No export or import path exists.
- `SnippetsLoad` (app) distinguishes `.loaded([Snippet])` from
  `.unreadable`.
- The UTTypes live in `Sources/MacSCPAppKit/SessionExportImportSheets.swift`
  as `UTType(exportedAs: "dev.noix.macscp.…", conformingTo: .json)`.

## Files

| File | Responsible for |
|---|---|
| `Sources/macSCPCore/Terminal/SnippetExportCodec.swift` (new) | payload + format `macscp-snippets` |
| `Sources/macSCPCore/Terminal/SnippetImportPlanner.swift` (new) | duplicates by name, shared arbiter |
| `Sources/MacSCPAppKit/SessionExportImportSheets.swift` | new UTType |
| `Sources/MacSCPAppKit/SnippetsSheet.swift` | export/import buttons |
| the four `Localizable.strings` | new keys |

---

### Task 1: The exchange format

**Files:**
- Create: `Sources/macSCPCore/Terminal/SnippetExportCodec.swift`
- Create: `Tests/macSCPCoreTests/SnippetExportCodecTests.swift`

**Interfaces:**
- Produces:
```swift
public struct SnippetExportPayload: Codable, Equatable, Sendable {
    public var snippets: [Snippet]
    public init(snippets: [Snippet])
}

public enum SnippetExportCodec {
    public static func encode(_ payload: SnippetExportPayload) throws -> Data
    public static func probe(_ data: Data) throws -> Bool
    public static func decode(_ data: Data) throws -> SnippetExportPayload
}
```

**Note the asymmetry with the two existing codecs:** their `encode`/`decode`
take a `password: String?`. **This one does not.** The format carries no
secrets, and a password parameter would be an invitation to later offer an
encryption that protects nothing. Internally, `password: nil` is passed —
**and that is exactly what must be pinned**, not merely commented.

- [ ] **Step 1: Tests first**

```swift
@Test func aRoundTripPreservesNameCommandAndTags() throws {
    let snippet = Snippet(name: "Clean up", command: "docker system prune -f",
                          tags: ["docker"])!
    let data = try SnippetExportCodec.encode(SnippetExportPayload(snippets: [snippet]))
    let restored = try SnippetExportCodec.decode(data)
    #expect(restored.snippets == [snippet])
}

@Test func theWrittenFileIsPlainTextAndSaysSoInsteadOfClaimingEncryption() throws {
    let snippet = Snippet(name: "Clean up", command: "docker system prune -f")!
    let data = try SnippetExportCodec.encode(SnippetExportPayload(snippets: [snippet]))
    let text = String(decoding: data, as: UTF8.self)
    #expect(text.contains("docker system prune -f"))
    let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    #expect(json?["encrypted"] as? Bool == false)
}

@Test func probeAcceptsOurFormatAndRejectsASessionExport() throws {
    let ours = try SnippetExportCodec.encode(SnippetExportPayload(snippets: []))
    #expect(try SnippetExportCodec.probe(ours))
    // Eine Login-Set- oder Sitzungsdatei bauen und ablehnen lassen; die
    // genaue Bau-Stelle am Code ablesen, nicht raten.
}

@Test func aFileWithADamagedSnippetFailsTheWholeDecodeRatherThanDroppingItSilently() throws {
    // Snippet.init(from:) verweigert einen mehrzeiligen Befehl.
    // Wörtliches JSON verwenden, nicht neu kodiertes.
}
```

**Spell out** the last two once you have read the actual construction
sites. A draft that stays as a draft is a plan defect.

- [ ] **Step 2: Red, then the codec**

Following the pattern of `LoginSetExportCodec`: `formatName = "macscp-snippets"`,
`currentVersion = 1`, three thin wrappers around `ExportEnvelopeCodec` with
`password: nil`.

- [ ] **Step 3: Pin the password, don't just comment it**

A test that goes red if someone later passes a password through after all.
**How** you make that checkable is your call — via the generated
`encrypted` field, via a source guard following the existing pattern, or
otherwise. Justify the choice in the report; a guard is explicitly **not**
the only option here, and the project already has seven of them.

- [ ] **Step 4: Full suite + commit**

```bash
swift test
git commit -m "feat(core): give snippets an exchange format without a crypto path"
```

---

### Task 2: The import planner

**Files:**
- Create: `Sources/macSCPCore/Terminal/SnippetImportPlanner.swift`
- Create: `Tests/macSCPCoreTests/SnippetImportPlannerTests.swift`

**Interfaces:**
- Consumes: `SnippetExportPayload`, `ImportConflictArbiter`, `ImportConflict`
- Produces:
```swift
public struct PlannedSnippet: Equatable, Sendable {
    public var snippet: Snippet
    public var replacesExisting: Bool
}

public struct SnippetImportPlan: Equatable, Sendable {
    public var snippetsToImport: [PlannedSnippet]
    public var skipped: [String]
    public var replaced: [String]
    public var renamed: [String]
    public var cancelled: Bool
}

public enum SnippetImportPlanner {
    public static let kindLabel = "snippet"
    public static func plan(
        existing: [Snippet], incoming: SnippetExportPayload,
        arbiter: ImportConflictArbiter
    ) async -> SnippetImportPlan
}
```

**Read `LoginSetImportPlanner` in full before you start.** It is the
precedent, and it solves four problems you would otherwise hit one at a
time: the collision key is the **trimmed, case-insensitive** name;
`takenNames` is pre-seeded with the existing stock **and extended on every
name assigned**, so that two renamed entries from the same file do not
collide with each other; an existing entry may be replaced **at most once**
per run; and **cancellation discards the entire run**, not just the rest.
Adopt all four, or justify in the report why one does not apply to
snippets.

**Why case-insensitive, even though tags are case-sensitive:** a snippet
*name* is a name like a login-set name, not a tag. The two import flows
should feel the same, and the conflict sheet shows both.

- [ ] **Step 1: Tests first**

```swift
private func snippet(_ name: String, _ command: String = "echo hi") -> Snippet {
    Snippet(name: name, command: command)!
}

@Test func aFreshNameImportsWithoutAskingAnybody() async {
    let plan = await SnippetImportPlanner.plan(
        existing: [], incoming: SnippetExportPayload(snippets: [snippet("Clean up")]),
        arbiter: arbiterThatMustNotBeAsked())
    #expect(plan.snippetsToImport.map(\.snippet.name) == ["Clean up"])
}

@Test func aNameCollidingOnlyByCaseAndWhitespaceStillCollides() async {
    let plan = await SnippetImportPlanner.plan(
        existing: [snippet("Clean up")],
        incoming: SnippetExportPayload(snippets: [snippet("  clean UP ")]),
        arbiter: arbiterAnswering(.skip))
    #expect(plan.snippetsToImport.isEmpty)
    #expect(plan.skipped == ["clean UP"])
}

@Test func cancellingDiscardsEverythingIncludingWhatWasAlreadyPlanned() async {
    let plan = await SnippetImportPlanner.plan(
        existing: [snippet("B")],
        incoming: SnippetExportPayload(snippets: [snippet("A"), snippet("B")]),
        arbiter: arbiterAnswering(nil))
    #expect(plan.cancelled)
    #expect(plan.snippetsToImport.isEmpty)   // "A" war schon geplant
}

@Test func twoRenamedSnippetsFromOneFileDoNotCollideWithEachOther() async {
    // Zwei eingehende Einträge desselben Namens, beide "umbenennen".
    // Die vergebenen Namen müssen sich unterscheiden.
}
```

**Spell out** the arbiter helpers and the last test after you have read
how `LoginSetImportPlannerTests` builds its arbiter.

- [ ] **Step 2: Red, then the planner**

- [ ] **Step 3: Full suite + commit**

```bash
swift test
git commit -m "feat(core): plan a snippet import on the shared conflict arbiter"
```

---

### Task 3: Exporting from the snippet sheet

**Files:**
- Modify: `Sources/MacSCPAppKit/SessionExportImportSheets.swift` (UTType)
- Modify: `Sources/MacSCPAppKit/SnippetsSheet.swift`
- Modify: the four `Localizable.strings`

**Measured current state:** `SnippetsSheet` already has a search field, a
tag filter row, and error display, and reads the store via `SnippetsLoad`,
which distinguishes `.loaded` from `.unreadable`. Look at how the session
sheet calls its `fileExporter`, and follow that.

- [ ] **Step 1: UTType**

`dev.noix.macscp.snippets`, conforming to `.json`, following the pattern
of the two existing ones.

- [ ] **Step 2: The export**

A button in the snippet sheet that exports the **currently visible**
snippets — i.e. what the search and tag filter leave behind. That is the
selection mechanism the sheet already has; a second selection UI would be
redundant.

**No export may be offered in the `.unreadable` state** — writing an empty
file from an unreadable store would be silent data loss in file form.
Check how the sheet displays this state today, and follow suit.

New keys (all four catalogs):
- `snippets.export` — "Export…"
- `snippets.export.filename` — the file's suggested name

- [ ] **Step 3: Catalog proof + full suite + commit**

```bash
for f in $(git ls-files '*.strings'); do plutil -lint "$f"; done
swift test
git commit -m "feat(app): export the visible snippets to a file"
```

---

### Task 4: Importing, with the shared conflict sheet

**Files:**
- Modify: `Sources/MacSCPAppKit/SnippetsSheet.swift`
- Modify: the four `Localizable.strings`
- Modify/Create: tests

**Measured current state:** The shared conflict sheet from M19 is already
used by two import flows. Find it, see how the session or login-set import
hooks it up to the `ImportConflictArbiter`, and do the same.
`SnippetImportPlanner.kindLabel` is the stable identifier the app maps to a
translated label — Core knows no display language.

- [ ] **Step 1: The import**

`fileImporter` → `probe` → `decode` → `plan` → apply. Applying writes via
`SnippetStore.save(_:)`; a `replace` must hit the existing entry, not place
a second snippet next to it. **Check the store to see how `save` handles an
existing entry**, rather than assuming it.

New keys (all four catalogs):
- `snippets.import` — "Import…"
- `snippets.import.error` — error text for an unreadable file
- `snippets.import.result %lld` — how many were imported
- the translated label for `kindLabel` in the conflict sheet

- [ ] **Step 2: What happens when the file doesn't fit**

A session or login-set file must get an understandable rejection, no
crash, and no empty import. `probe` answers this; wire the answer up.

- [ ] **Step 3: Catalog proof + full suite + commit**

```bash
for f in $(git ls-files '*.strings'); do plutil -lint "$f"; done
swift test
git commit -m "feat(app): import snippets through the shared conflict sheet"
```

---

### Task 5: Phase closeout

**Files:**
- Create: `docs/superpowers/specs/2026-08-18-p3b-closeout.md`

- [ ] **Step 1: Measure**

```bash
swift test 2>&1 | tail -3
for f in $(git ls-files '*.strings'); do plutil -lint "$f"; done
MACSCP_VERSION="1.2.0-dev" MACSCP_BUILD="$(git rev-list --count HEAD)" ./scripts/package-app
```

Start the build **in the background** and keep working; afterward check
both binaries (`lipo -archs`), both resource bundles, all four `.lproj`
directories, and `plutil -lint` on the Info.plist. **The app is not
started.**

- [ ] **Step 2: Report**

It states the measured numbers; what is held by tests and what is only by
review; how the missing password was pinned and why that way; whether the
planner adopted all four properties of the login-set precedent; and
**explicitly** that the GUI was not started — with the list of what the
maintainer needs to look at: export with an active filter, import of a file
with a name conflict, and the rejection on a session file.

- [ ] **Step 3: Commit**

```bash
git commit -m "docs(app): record the snippet exchange phase"
```

---

## Self-review of this plan

**Spec coverage:** format without a crypto path → Task 1. Duplicate by name
on the shared arbiter → Task 2. Own UTType, sheets following the existing
pattern, selection at export time → Tasks 3 and 4.

**Placeholders:** four tests are deliberately marked as drafts, because
their fixtures depend on construction sites that must be read from the
code. Each says so explicitly and requires spelling out — a draft that
stays a draft is a plan defect.

**Type consistency:** `SnippetExportPayload` matches across Tasks 1 and 2;
`SnippetImportPlanner.plan(existing:incoming:arbiter:)` defined once;
`kindLabel` spelled the same in Tasks 2 and 4.
