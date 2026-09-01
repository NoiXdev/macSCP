# Terminal-Snippets (Implementation Plan)

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> superpowers:subagent-driven-development (recommended) or
> superpowers:executing-plans to implement this plan task-by-task. Steps use
> checkbox (`- [ ]`) syntax for tracking.

**Goal:** Reusable command lines, stored globally, inserted into the SSH
terminal panel from the Terminal menu — with the executing ones visibly
separated from the inserting ones.

**Architecture:** Core owns the model, the JSON store, and the byte encoding
(so the "insert vs. execute" difference is testable). The App owns a
management sheet and two menu sections. Nothing else changes.

**Tech Stack:** Swift 6 (`.swiftLanguageMode(.v5)`), SwiftPM, macOS 15+,
Swift Testing (`@Test`/`#expect`), SwiftTerm.

Spec: `../specs/2026-08-10-terminal-snippets-design.md`.

## Global Constraints

- **Code, comments, identifiers, test names: English only.** Catalog values
  are the exception; internal docs (`docs/`) may be German.
- Swift tools 6.0, **every target `.swiftLanguageMode(.v5)`**, macOS 15+.
- Tests: Swift Testing, TDD red→green.
- **Snippets never hold credentials.** The store is JSON; the project rule
  is that JSON stores contain no secrets. This is a documented property of
  the type, not a hope.
- **A secret's value is never printed, logged, or embedded in an error** —
  including a test failure message.
- **Never write a line number into a comment.** Name the thing.
- **A comment asserting something about the code needs the same verification
  as a test.** M29 shipped six false comment claims, most from plan prose —
  **treat this plan's prose as claims to verify.**
- Any new string lands in **all four** catalogs with identical key sets and
  `plutil -lint` clean. FR/PL are machine-provided; flag them as unreviewed.
- **Do NOT run `scripts/release`.** **Do NOT launch the GUI app.**
- Conventional Commits, English. Footer exactly:
  `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`
- **Commit, but never push.**
- Baseline: **1735 tests in 141 suites, green.**

## Verified against the source while writing this plan

- `TerminalPanelViewModel.send(_ bytes: [UInt8])` — public, the only seam
  needed to reach the shell.
- `MacSCPApp.swift` already declares `CommandMenu(L10n.string("menu.terminal",
  "Terminal"))` with two entries, both disabled by
  `!tabCommands.isActiveTabConnected || !tabCommands.activeTabSupportsShell`.
  **Snippets go into that menu and reuse that condition.**
- Stores are constructed as `XStore(directory: SessionStore.defaultDirectory)`
  at the App call sites.
- `ManagedKeyStore` is the closest template: a `Sendable` struct with
  `init(directory:)`, `all() throws -> [T]`, `add(_:) throws`, and a private
  `persist(_:)` writing with `.atomic`.
- `SheetSearchField` exists in the App layer. **Its initializer was not
  read** — the implementer reads it and adapts.

---

## File Structure

| File | Responsibility |
|---|---|
| `Sources/macSCPCore/Terminal/Snippet.swift` | **New.** The model and its one validity rule |
| `Sources/macSCPCore/Terminal/SnippetStore.swift` | **New.** `snippets.json`, same shape as `ManagedKeyStore` |
| `Sources/macSCPCore/Terminal/SnippetKeystrokes.swift` | **New.** Snippet → bytes, the insert/execute difference |
| `Sources/MacSCPAppKit/SnippetsSheet.swift` | **New.** List, search, add/edit/delete |
| `Sources/MacSCPAppKit/MacSCPApp.swift` | Two sections in the existing Terminal menu |
| `Sources/MacSCPAppKit/KeyboardShortcutsCatalog.swift` | The new shortcuts, hand-maintained |
| `Sources/*/Resources/*.lproj/Localizable.strings` | New keys, four catalogs each |

---

### Task 1: The model and its store

**Files:**
- Create: `Sources/macSCPCore/Terminal/Snippet.swift`
- Create: `Sources/macSCPCore/Terminal/SnippetStore.swift`
- Test: `Tests/macSCPCoreTests/SnippetStoreTests.swift`

**Interfaces:**
- Produces: `public struct Snippet: Identifiable, Codable, Equatable, Sendable`
  with `id: UUID`, `name: String`, `command: String`, `runsImmediately: Bool`,
  and a **failable or throwing** construction that rejects a command
  containing a line break.
- Produces: `public struct SnippetStore: Sendable` with `init(directory: URL)`,
  `all() throws -> [Snippet]`, `save(_ snippet: Snippet) throws`,
  `remove(id: UUID) throws`.

- [ ] **Step 1: Write the failing tests**

```swift
import Foundation
import Testing
@testable import macSCPCore

@Suite("SnippetStore")
struct SnippetStoreTests {
    private func makeStore() -> (SnippetStore, URL) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-snippets-\(UUID().uuidString)")
        return (SnippetStore(directory: dir), dir)
    }

    /// A store whose file does not exist yet is empty, not an error — the
    /// same promise `ManagedKeyStore` makes, and what every first launch
    /// hits.
    @Test func aMissingFileReadsAsAnEmptyList() throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        #expect(try store.all().isEmpty)
    }

    /// What goes in comes back out unchanged, including the flag that
    /// decides whether the snippet executes.
    @Test func aSavedSnippetSurvivesTheRoundTrip() throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let snippet = try #require(Snippet(name: "Disk", command: "df -h", runsImmediately: true))

        try store.save(snippet)

        #expect(try store.all() == [snippet])
    }

    /// Saving the same id twice replaces rather than duplicating.
    @Test func savingTheSameIdTwiceReplaces() throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        var snippet = try #require(Snippet(name: "Disk", command: "df -h", runsImmediately: false))
        try store.save(snippet)
        snippet.name = "Disk usage"

        try store.save(snippet)

        #expect(try store.all().count == 1)
        #expect(try store.all().first?.name == "Disk usage")
    }

    @Test func removingAnIdLeavesTheOthers() throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let keep = try #require(Snippet(name: "Keep", command: "uptime", runsImmediately: false))
        let drop = try #require(Snippet(name: "Drop", command: "whoami", runsImmediately: false))
        try store.save(keep)
        try store.save(drop)

        try store.remove(id: drop.id)

        #expect(try store.all() == [keep])
    }

    /// A command with an embedded line break is refused. Without this,
    /// "insert" would be a lie: every line but the last would run the
    /// moment it was inserted, with nobody pressing Return.
    @Test func aCommandWithALineBreakIsRefused() {
        #expect(Snippet(name: "Two", command: "echo a\necho b", runsImmediately: false) == nil)
        #expect(Snippet(name: "CR", command: "echo a\recho b", runsImmediately: false) == nil)
    }

    /// The rule is the MODEL's, not the form's: a hand-edited store file
    /// must not smuggle a multi-line command past it either.
    @Test func aHandEditedMultiLineCommandDoesNotDecode() throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let json = #"[{"id":"\#(UUID().uuidString)","name":"x","command":"a\nb","runsImmediately":false}]"#
        try Data(json.utf8).write(to: dir.appendingPathComponent("snippets.json"))

        #expect(throws: (any Error).self) { try store.all() }
    }
}
```

**Two things here are this plan's guesses.** The failable-initializer shape
(`Snippet(...)` returning `nil`) and the exact JSON literal in the last
test. If a throwing initializer fits the codebase better — check how other
Core models reject invalid input — use it and adjust the two tests' shape,
never their intent. **Say what you changed.**

- [ ] **Step 2: Run and watch them fail**

Run: `swift test --filter SnippetStore 2>&1 | tail -6`
Expected: compile failure — neither type exists.

- [ ] **Step 3: Write `Snippet`**

One stored property per spec field. The validity rule lives in the
initializer **and** in `init(from:)`, so decode cannot be a second,
un-normalized write path — `KnownHostKey` does exactly this and says why in
its own comment. Read it before writing yours.

Give the type a doc comment stating that it never holds credentials, and
why: the store is JSON, and the project keeps secrets only in the Keychain.

- [ ] **Step 4: Write `SnippetStore`**

Mirror `ManagedKeyStore`: `Sendable` struct, `init(directory:)`, a private
`fileURL` for `snippets.json`, `all()` returning `[]` when the file is
absent, and a private `persist(_:)` writing `.atomic` with
`.prettyPrinted, .sortedKeys`.

- [ ] **Step 5: Run the tests**

Run: `swift test --filter SnippetStore 2>&1 | tail -4`
Expected: all PASS.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "feat(core): store reusable terminal snippets"
```

---

### Task 2: The byte encoding, and the measured line terminator

**This task carries the feature's one real unknown.** The spec deliberately
does not say which byte submits a line, because Return on a terminal
normally sends **CR** (`0x0D`), not LF — and a wrong guess means a snippet
marked "run immediately" quietly does nothing.

**Files:**
- Create: `Sources/macSCPCore/Terminal/SnippetKeystrokes.swift`
- Test: `Tests/macSCPCoreTests/SnippetKeystrokesTests.swift`

**Interfaces:**
- Produces: `public enum SnippetKeystrokes` with
  `public static func bytes(for snippet: Snippet) -> [UInt8]`.

- [ ] **Step 1: Measure, before writing anything**

Find what this app's terminal actually sends for Return. Read
`SSHTerminalView` and the SwiftTerm API it drives, and follow the path an
ordinary keypress takes to `TerminalPanelViewModel.send`. **Write down what
you found and where.** If the evidence is ambiguous, say so and pick the
one the evidence best supports — do not pick the one that is easier to
type.

- [ ] **Step 2: Write the failing tests**

```swift
import Foundation
import Testing
@testable import macSCPCore

@Suite("SnippetKeystrokes")
struct SnippetKeystrokesTests {
    /// An inserting snippet lands in the input line and waits: the user
    /// still presses Return. Nothing may be appended, or "insert" would
    /// execute.
    @Test func anInsertingSnippetEndsWithoutATerminator() throws {
        let snippet = try #require(Snippet(name: "Disk", command: "df -h", runsImmediately: false))

        #expect(SnippetKeystrokes.bytes(for: snippet) == Array("df -h".utf8))
    }

    /// An executing snippet appends exactly what the Return key sends.
    /// The expected byte is MEASURED (see this suite's own doc comment),
    /// not assumed.
    @Test func anExecutingSnippetAppendsExactlyOneTerminator() throws {
        let snippet = try #require(Snippet(name: "Disk", command: "df -h", runsImmediately: true))

        let bytes = SnippetKeystrokes.bytes(for: snippet)

        #expect(bytes.dropLast() == ArraySlice("df -h".utf8))
        #expect(bytes.count == Array("df -h".utf8).count + 1)
    }

    /// Non-ASCII survives as UTF-8 — paths and messages are not ASCII-only.
    @Test func nonASCIICommandsAreEncodedAsUTF8() throws {
        let snippet = try #require(Snippet(name: "Echo", command: "echo Grüße", runsImmediately: false))

        #expect(SnippetKeystrokes.bytes(for: snippet) == Array("echo Grüße".utf8))
    }
}
```

Add **one further test** naming the measured terminator explicitly, e.g.
`theTerminatorIsCarriageReturn`, asserting `bytes.last == 0x0D` — with the
value from Step 1, not from this plan. That test is the record of the
measurement; write its doc comment to say where the evidence came from.

- [ ] **Step 3: Run and watch them fail**

Run: `swift test --filter SnippetKeystrokes 2>&1 | tail -6`
Expected: compile failure.

- [ ] **Step 4: Implement**

```swift
public enum SnippetKeystrokes {
    public static func bytes(for snippet: Snippet) -> [UInt8] {
        var bytes = Array(snippet.command.utf8)
        if snippet.runsImmediately { bytes.append(terminator) }
        return bytes
    }
}
```

`terminator` is the measured constant, with a doc comment naming the
evidence.

- [ ] **Step 5: Run the tests, then the whole suite**

Run: `swift test --filter SnippetKeystrokes 2>&1 | tail -4`, then
`swift test 2>&1 | tail -3`

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "feat(core): encode a snippet's keystrokes, terminator included"
```

---

### Task 3: The management sheet

**Files:**
- Create: `Sources/MacSCPAppKit/SnippetsSheet.swift`
- Modify: the four App catalogs

**Interfaces:**
- Consumes: `SnippetStore`, `Snippet`.
- Produces: `SnippetsSheet(store:)`, presented from the Terminal menu in
  Task 4.

- [ ] **Step 1: Read the two sheets this one follows**

`LoginSetsSheet` and `SSHKeysSheet`. Match their structure, their search
wiring (`SheetSearchField` — **read its initializer**, this plan did not),
their row layout and their button placement. Do not invent a third style.

- [ ] **Step 2: Build the sheet**

List of snippets with name and command, a search field filtering on both, and
add / edit / delete. The editor has: name, command, and a checkbox
"Run immediately". The command field rejects a line break — surface the
model's refusal, do not re-implement the rule.

**Include the credentials note**, with its reason rather than as a bare
prohibition: the file is plain JSON, so it holds no passwords; and a command
line is visible in `ps` and in the shell history on the far host anyway.

- [ ] **Step 3: Add the catalog keys**

Every new string in all four App catalogs, identical key sets,
`plutil -lint` clean. FR/PL machine-provided — say so in your report.

- [ ] **Step 4: Build and run the suite**

Run: `swift build 2>&1 | tail -3` then `swift test 2>&1 | tail -3`
Expected: build clean including the App target; suite green and unchanged
in count (this task adds no tests — it is view code, which this project
does not test; say so in your report rather than inventing a test that
asserts nothing).

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat(app): manage terminal snippets in their own sheet"
```

---

### Task 4: Two sections in the Terminal menu

**Files:**
- Modify: `Sources/MacSCPAppKit/MacSCPApp.swift`
- Modify: `Sources/MacSCPAppKit/KeyboardShortcutsCatalog.swift`
- Modify: the four App catalogs
- Possibly modify: `ContentView.swift` / the `tabCommands` bridge, if the
  sheet needs a window-scoped presentation path

**Interfaces:**
- Consumes: `SnippetStore`, `SnippetKeystrokes.bytes(for:)`,
  `TerminalPanelViewModel.send(_:)`, and the existing
  `tabCommands.isActiveTabConnected` / `activeTabSupportsShell`.

- [ ] **Step 1: Add the entries to the existing Terminal menu**

Two sections: the inserting snippets first, then a `Divider()` and the
executing ones under their own heading. **The grouping is the safety
feature** — it is what tells the user which entries are live, since the
choice was made when the snippet was authored. Do not replace it with an
icon.

Every entry disabled by the same condition the two existing entries use.

Add a "Manage Snippets…" entry opening Task 3's sheet, following how
"Manage logins…" reaches its sheet.

- [ ] **Step 2: Assign shortcuts and update the catalog**

⌘-shortcuts for the first few entries only. Then update
`KeyboardShortcutsCatalog` — it is a **hand-maintained mirror** and its own
doc comment names updating it as an obligation whenever a shortcut changes.
Add a group for snippets, and the new label keys to all four catalogs.

- [ ] **Step 3: Build and run the suite**

Run: `swift build 2>&1 | tail -3` then `swift test 2>&1 | tail -3`

`KeyboardShortcutsCatalogTests` already asserts that every label key
resolves — a missing catalog entry turns it red. That is the one automatic
check this task has.

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "feat(app): trigger snippets from the Terminal menu"
```

---

### Task 5: Verification and close record

**Files:**
- Create: `docs/superpowers/specs/2026-08-10-terminal-snippets-closeout.md`

- [ ] **Step 1: Run everything**

```bash
swift build 2>&1 | tail -3
swift test 2>&1 | tail -3
docker compose -f docker/test-server/compose.yml up -d
MACSCP_ITEST=1 swift test 2>&1 | tail -3
MACSCP_KEYCHAIN=1 swift test --filter Keychain 2>&1 | tail -2
for f in Sources/MacSCPAppKit/Resources/*.lproj/Localizable.strings Sources/macSCPCore/Resources/*.lproj/Localizable.strings; do printf "%s: " "$f"; plutil -lint "$f"; done
pgrep -fl swiftpm-testing-helper || echo "no orphans"
git status --porcelain
```

Docker rig from the **main checkout**, never a worktree.

- [ ] **Step 2: Write the close record**

German, following `2026-08-10-m29-p2-closeout.md`'s shape. It must carry:

- the commit list; unpushed and ahead-of-`origin/main` counts; test counts
  before and after;
- each of the ten success criteria with its evidence — and **criteria 6 and
  7 are Review points, not tests**: the menu grouping and the disabled state
  are view code, which this project does not test. Say that plainly rather
  than implying coverage;
- **how the line terminator was measured**, and where the evidence came
  from. That is the milestone's one genuine finding;
- what is NOT verified: the GUI was not launched, so neither the menu's two
  sections nor the sheet has been seen.

- [ ] **Step 3: Commit**

```bash
git add -A
git commit -m "docs: record the terminal-snippets close"
```

---

## Notes for the executing agent

- **Task 2 Step 1 is the milestone's one real question.** Everything else is
  a store and some view code. Measure it; do not let this plan's `0x0D`
  hint stand in for evidence.
- **The menu grouping is a safety feature, not styling.** It exists because
  the run-immediately choice is made when authoring and lands when
  triggering.
- **This plan's prose is a claim, not a fact.** Its two immediate
  predecessors shipped seven unverified statements between them, and every
  one traced back to plan prose rather than to an implementer's invention.
  Two guesses are already flagged above; assume there are more.
