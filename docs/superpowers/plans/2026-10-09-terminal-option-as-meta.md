# Option as Meta, as a setting — implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the terminal a setting for whether Option acts as the Meta key, defaulting to off, so the characters a non-US keyboard composes with Option reach the shell.

**Architecture:** One `Bool` in `SettingsStore`, handed to SwiftTerm's `optionAsMetaKey` by `SSHTerminalView`. The hand-over is **gated** on a record held by the view's coordinator, so SwiftTerm's own `Option+Command+O` chord survives a routine SwiftUI re-render. A `Toggle` in the existing `.terminal` settings tab, with a footer that names the chord — which appears nowhere in the UI today.

**Tech Stack:** Swift 6 (`.swiftLanguageMode(.v6)`), SwiftPM, Swift Testing, SwiftUI + AppKit (`NSViewRepresentable`), SwiftTerm at the pinned revision `d5ee56e1c74777120f3af688600d336de4201bd2`.

**Spec:** `docs/superpowers/specs/2026-10-09-terminal-option-as-meta-design.md`, committed `4b20550e`.
**Base:** `develop` at `4b20550e`.
**Backlog row:** `docs/BACKLOG.md`, the row opening "BUG: the terminal swallows every character the Option key composes" — row 117 at `c21e9e77`. Task 4 closes it, and **prefer `grep` over the row number**: a row added above it moves it.

## Global Constraints

- **Code and comments: English only.** No German in source files.
- **Never hardcode a display string.** `L10n.string(_:_:)` in the App, `CoreL10n.string(_:)` in Core. Four catalogues: `en` (the source text), `de`, `fr`, `pl`. The German catalogue addresses the user as **du**.
- Tests: Swift Testing (`@Test`/`#expect`), **TDD red→green**. The observed red is **quoted in the commit message, never invented**. A red that is a BUILD failure is quoted as the compiler printed it.
- `swift test` and `swift build` take **no `--build-system` flag**.
- **No wall-clock ceiling in a test.** A floor is fine; a hang bound is `.timeLimit`.
- **In test targets every wait is an `await`** — no `syncShutdownGracefully()`, no `futureResult.wait()`, no `DispatchSemaphore.wait()`.
- **A negative source-scanning check needs a positive check beside it.** This plan's guard is positive-only by construction (Task 2, Step 3) — if an implementer adds a negative check, it owes a positive neighbour.
- **A guard that spells a symbol it could read instead is waiting for a rename.** Derive where you can.
- **A scripted replacement asserts its anchor is unique** before writing.
- **Never bare `git stash` / `git stash pop`** — the stack is shared with other sessions. **Never `git checkout -- <file>`** — it restores from the index and takes uncommitted edits with it. A mutation probe goes through `scripts/mutation-probe`.
- Conventional Commits. Footer on every commit: `Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>`
- **Commit freely; push only when the maintainer asks.**
- **Do not launch the GUI/app binary.** The one check that needs a running app is Task 4, Step 5, and it belongs to the maintainer.
- `docs/BACKLOG.md` is a measurement record: **a correction quotes verbatim what it withdraws**, a figure travels with the command that produced it, a cell carries **no pipe at all**, and the command is **re-run after the sentence is written**.
- `/Users/noidee/_dev/noix-docs` is **shared with other products and other sessions**. Its main checkout is on someone else's branch (`ddev-sync` at `6ee4bf6`, measured 2026-10-09). Work in a **new worktree on a new branch off `origin/main`**; never touch a branch or working tree someone else has open. Push or merge only when the maintainer asks.

## File Structure

| File | Change | Responsible for |
|---|---|---|
| `Sources/macSCPCore/Settings/SettingsStore.swift` | Modify | The persisted `Bool`: `Keys`, `Defaults`, the property |
| `Tests/macSCPCoreTests/SettingsStoreTests.swift` | Modify | Default-off and independent round-trip |
| `Sources/MacSCPAppKit/SSHTerminalView.swift` | Modify | Handing the value to SwiftTerm, and the gate that keeps the chord |
| `Tests/macSCPAppKitTests/TerminalKeyboardWiringGuardTests.swift` | Create | Pins the wiring, the gate, the binding and the four catalogues |
| `Sources/MacSCPAppKit/SettingsView.swift` | Modify | The `Toggle` and its footer in `TerminalSettingsTab` |
| `Sources/MacSCPAppKit/Resources/{en,de,fr,pl}.lproj/Localizable.strings` | Modify | The two new strings |
| `docs/BACKLOG.md` | Modify | Row 117 corrected in place, with its withdrawals quoted |
| `src/content/docs/macscp/guide/terminal.md` (noix-docs) | Modify | The user-facing description |
| `src/content/docs/macscp/reference/changelog.md` (noix-docs) | Modify | One row under `## Unreleased` |

Execution order: 1 → 2 → 3 → 4.

---

### Task 1: The persisted value

**Files:**
- Modify: `Sources/macSCPCore/Settings/SettingsStore.swift`
- Test: `Tests/macSCPCoreTests/SettingsStoreTests.swift`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `public var terminalOptionAsMetaKey: Bool` on `SettingsStore`, default `false`. Tasks 2 and 3 read and bind it. The storage key string is `"terminalOptionAsMetaKey"`.

- [ ] **Step 1: Write the failing tests**

In `Tests/macSCPCoreTests/SettingsStoreTests.swift`, immediately **after** the closing brace of `terminalCopyOnSelectAndPasteOnRightClickRoundtripIndependently` and **before** the `// MARK: - Notifications` line:

```swift
    // MARK: - Option as Meta (plan of 2026-10-09)

    /// Default OFF, which is the opposite of SwiftTerm's own default for
    /// the property this feeds. While Option is Meta, the characters a
    /// non-US keyboard composes with Option never reach the shell.
    @Test func terminalOptionAsMetaKeyDefaultsOff() {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SettingsStore(directory: dir)
        #expect(store.terminalOptionAsMetaKey == false)
    }

    /// Its own switch: it survives a reload on its own, and flipping it
    /// moves neither mouse switch.
    @Test func terminalOptionAsMetaKeyRoundtripsWithoutMovingTheMouseSwitches() {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SettingsStore(directory: dir)
        store.terminalOptionAsMetaKey = true
        let afterOn = SettingsStore(directory: dir)
        #expect(afterOn.terminalOptionAsMetaKey == true)
        #expect(afterOn.terminalCopyOnSelect == false)
        #expect(afterOn.terminalPasteOnRightClick == false)

        store.terminalOptionAsMetaKey = false
        let afterOff = SettingsStore(directory: dir)
        #expect(afterOff.terminalOptionAsMetaKey == false)
    }
```

- [ ] **Step 2: Run them to verify they fail**

Run: `swift test --filter terminalOptionAsMetaKey`

Expected: the red is a **build failure**, not a failing assertion — `SettingsStore` has no such member yet. Quote what the compiler actually printed. Do not paraphrase it, and do not write a plausible message in its place.

- [ ] **Step 3: Add the key, the default and the property**

In `Sources/macSCPCore/Settings/SettingsStore.swift`, in the `Keys` block, on the line after `static let terminalPasteOnRightClick = "terminalPasteOnRightClick"`:

```swift
        static let terminalOptionAsMetaKey = "terminalOptionAsMetaKey"
```

In the `Defaults` block, on the line after `static let terminalPasteOnRightClick = false`:

```swift
        static let terminalOptionAsMetaKey = false
```

And immediately after the closing brace of the `terminalPasteOnRightClick` property:

```swift
    /// Whether the terminal treats Option as the Meta key — SwiftTerm's
    /// `optionAsMetaKey`, which `SSHTerminalView` feeds from here.
    ///
    /// Default OFF, and that is the **opposite** of SwiftTerm's own
    /// default: while it is ON, Option sends an ESC prefix instead of the
    /// character it composes, and on a German keyboard that swallows the
    /// vertical bar, `@`, `~`, `\`, `{`, `}`, `[` and `]`. Someone running
    /// Emacs over SSH wants it ON, and turns it on (maintainer decision,
    /// 2026-10-09). SwiftTerm's `Option+Command+O` toggles the view's own
    /// flag for one open terminal without changing this value.
    public var terminalOptionAsMetaKey: Bool {
        get {
            boolValue(for: Keys.terminalOptionAsMetaKey, default: Defaults.terminalOptionAsMetaKey)
        }
        set { setBool(newValue, for: Keys.terminalOptionAsMetaKey) }
    }
```

- [ ] **Step 4: Run them to verify they pass**

Run: `swift test --filter terminalOptionAsMetaKey`
Expected: 2 tests, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add Sources/macSCPCore/Settings/SettingsStore.swift Tests/macSCPCoreTests/SettingsStoreTests.swift
git commit -F - <<'MSG'
feat(settings): a stored switch for Option as the Meta key

<< the red from Step 2, pasted exactly as the compiler printed it. This is
the one thing in this plan nobody can write in advance, and inventing a
plausible message in its place is the failure this project has a rule
about. >>

The default is off, which is the opposite of SwiftTerm's own default at the
pinned revision: while Option is Meta it sends an ESC prefix instead of the
character it composes, and the characters a non-US keyboard composes with
Option never reach the shell.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
MSG
```

---

### Task 2: Handing it to SwiftTerm, through a gate

**Files:**
- Modify: `Sources/MacSCPAppKit/SSHTerminalView.swift`
- Create: `Tests/macSCPAppKitTests/TerminalKeyboardWiringGuardTests.swift`

**Interfaces:**
- Consumes: `SettingsStore.terminalOptionAsMetaKey` (Task 1).
- Produces: `Coordinator.appliedOptionAsMetaKey: Bool?`, and in `updateNSView` the local `desiredOptionAsMetaKey`. Task 3 adds no code here; its guard tests live in the same new file.

**Why a gate at all, and why not the shape its two neighbours use.** `updateNSView` assigns `copyOnSelect` and `pasteOnRightClick` on **every** render, and the comment above them says why that is free: "Two plain flags read at the moment of a click, so assigning them on every render costs nothing and restarts nothing." That reasoning does **not** carry to this flag. SwiftTerm's `Option+Command+O` flips `optionAsMetaKey` inside the view (`MacTerminalView.keyDown`, two sites at `:1103` and `:1139` of the pinned revision), and an unconditional write here would undo the user's chord on the next unrelated re-render. So this flag takes the gate `appliedCursorStyle` and `appliedTheme` already use in this file — **and do not extend the two-flags comment over the new line.**

The record holds **what the setting last dictated, not what the view carries.** That asymmetry is the behaviour: a chord moves the view and not the record, so no later render writes back; a changed setting differs from the record, so the setting wins.

- [ ] **Step 1: Write the failing guard — the wrapper half**

Create `Tests/macSCPAppKitTests/TerminalKeyboardWiringGuardTests.swift`:

```swift
import Foundation
import MacSCPTestSupport
import Testing

@testable import MacSCPAppKit

/// Guards the wiring of the terminal's one keyboard setting (plan of
/// 2026-10-09): the SwiftUI wrapper handing `optionAsMetaKey` to the view,
/// the GATE that keeps SwiftTerm's own `Option+Command+O` chord effective,
/// and the Settings tab binding the toggle through the catalogue keys.
///
/// Structural claims read the source with comments AND string literals
/// blanked (`SourceCorpus.code`), so a comment quoting a line of code
/// cannot satisfy them. Catalogue-key claims are claims about literals and
/// read the comments-blanked view (`SourceCorpus.commentFree`).
///
/// EVERY check here is POSITIVE: a `contains` that fails the moment the
/// thing it names moves, or a count that must match. There is no
/// `!contains` and no filter expected to come back empty — the only kind
/// of check that can go stale in silence — so none of these needs a
/// positive check propping it up. The one claim that reads as a
/// prohibition, "there is no second, ungated assignment", is written as a
/// count for exactly that reason.
///
/// Known blind spot, and it is the load-bearing one: SOURCE TEXT only.
/// That the gate really leaves a pressed `Option+Command+O` standing is
/// NOT established here. It needs a running app, which this project does
/// not launch from a session; the plan of 2026-10-09 assigns that check to
/// the maintainer by hand.
@Suite("Terminal keyboard setting wiring guard")
struct TerminalKeyboardWiringGuardTests {
    private static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    private static func path(_ relative: String) -> URL {
        repoRoot.appendingPathComponent(relative)
    }

    private static let wrapperFile = "Sources/MacSCPAppKit/SSHTerminalView.swift"
    private static let settingsViewFile = "Sources/MacSCPAppKit/SettingsView.swift"
    private static let settingsTab = "private struct TerminalSettingsTab: View"

    private static let keys = [
        "settings.terminal.optionAsMeta",
        "settings.terminal.optionAsMeta.footer",
    ]

    private static func views(_ relative: String) throws -> (code: String, withLiterals: String) {
        (try SourceCorpus.code(of: path(relative)),
         try SourceCorpus.commentFree(of: path(relative)))
    }

    private static func catalog(_ locale: String) throws -> [String: String] {
        let relative = "Sources/MacSCPAppKit/Resources/\(locale).lproj/Localizable.strings"
        let data = try Data(contentsOf: path(relative))
        return try #require(
            try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String])
    }

    /// OCCURRENCES, not lines. `grep -c` counts lines and would report 1
    /// where the count is 2; this project has a rule about that, and the
    /// rule binds a test as much as a record.
    private static func occurrences(of needle: String, in haystack: String) -> Int {
        haystack.components(separatedBy: needle).count - 1
    }

    // MARK: - The SwiftUI wrapper

    /// `makeNSView` hands the setting over once, and records what it handed
    /// over on the coordinator.
    @Test func theWrapperAppliesTheSettingWhenItBuildsTheView() throws {
        let code = try Self.views(Self.wrapperFile).code
        let make = try TransferQueueBarCancelGuardTests.declarationBody(
            of: "func makeNSView(", in: code)
        #expect(make.contains("terminal.optionAsMetaKey = settingsStore.terminalOptionAsMetaKey"))
        #expect(make.contains(
            "context.coordinator.appliedOptionAsMetaKey = settingsStore.terminalOptionAsMetaKey"))
    }

    /// `updateNSView` writes only through the gate. Four anchors spell the
    /// gate, and the count forbids a second assignment beside it: one that
    /// read the store directly would defeat the gate while every anchor
    /// above still matched.
    @Test func theWrapperWritesTheSettingOnlyThroughTheGate() throws {
        let code = try Self.views(Self.wrapperFile).code
        let update = try TransferQueueBarCancelGuardTests.declarationBody(
            of: "func updateNSView(", in: code)
        #expect(update.contains(
            "let desiredOptionAsMetaKey = settingsStore.terminalOptionAsMetaKey"))
        #expect(update.contains(
            "if context.coordinator.appliedOptionAsMetaKey != desiredOptionAsMetaKey"))
        #expect(update.contains("terminal.optionAsMetaKey = desiredOptionAsMetaKey"))
        #expect(update.contains(
            "context.coordinator.appliedOptionAsMetaKey = desiredOptionAsMetaKey"))
        #expect(Self.occurrences(of: "terminal.optionAsMetaKey =", in: update) == 1)
    }
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `swift test --filter TerminalKeyboardWiringGuardTests`
Expected: both cases red — the wrapper does not mention the property yet. Quote the actual failure text.

- [ ] **Step 3: Wire it, gated**

In `Sources/MacSCPAppKit/SSHTerminalView.swift`, in `makeNSView`, immediately after the line `terminal.pasteOnRightClick = settingsStore.terminalPasteOnRightClick`:

```swift
        terminal.optionAsMetaKey = settingsStore.terminalOptionAsMetaKey
        context.coordinator.appliedOptionAsMetaKey = settingsStore.terminalOptionAsMetaKey
```

In `updateNSView`, **after** the two ungated assignments and **before** the `context.coordinator.onRunSnippet = onRunSnippet` line:

```swift
        // NOT assigned on every render, unlike the two above. SwiftTerm's
        // own Option-Command-O chord flips this flag inside the view, and
        // an unconditional write here would undo it on the next unrelated
        // re-render. The record on the coordinator holds what the SETTING
        // last said — not what the view carries — so a chord moves the
        // view without moving the record, and only a changed setting
        // reaches the view.
        let desiredOptionAsMetaKey = settingsStore.terminalOptionAsMetaKey
        if context.coordinator.appliedOptionAsMetaKey != desiredOptionAsMetaKey {
            terminal.optionAsMetaKey = desiredOptionAsMetaKey
            context.coordinator.appliedOptionAsMetaKey = desiredOptionAsMetaKey
        }
```

In the `Coordinator` class, immediately after the `appliedTheme` property:

```swift
        /// Last value of `optionAsMetaKey` the SETTINGS dictated (plan of
        /// 2026-10-09) — deliberately not what the view currently carries.
        /// `Option+Command+O` flips the view's own flag inside SwiftTerm,
        /// and this record does not move with it, so `updateNSView` sees no
        /// difference and a routine re-render leaves the chord standing. A
        /// changed setting does differ, and then the setting wins.
        var appliedOptionAsMetaKey: Bool?
```

- [ ] **Step 4: Run it to verify it passes**

Run: `swift test --filter TerminalKeyboardWiringGuardTests`
Expected: 2 tests, 0 failures. (Task 3 adds four more cases to this file.)

- [ ] **Step 5: Prove the count anchor is sensitive**

Through the harness, never by hand — it refuses a dirty tree and reverts index-safely, which `git checkout -- <file>` does not. The plant goes in a file OUTSIDE the worktree, so it cannot become an untracked file in the tree the harness is about to measure; these are three plain commands, not one chain:

```bash
cat > "$TMPDIR/plant-option-as-meta.py" <<'PY'
import io
p='Sources/MacSCPAppKit/SSHTerminalView.swift'
s=io.open(p,encoding='utf-8').read()
old='        let desiredOptionAsMetaKey = settingsStore.terminalOptionAsMetaKey'
assert s.count(old)==1, 'anchor not unique: %d' % s.count(old)
s=s.replace(old, '        terminal.optionAsMetaKey = settingsStore.terminalOptionAsMetaKey\n'+old)
io.open(p,'w',encoding='utf-8').write(s)
PY
```

```bash
scripts/mutation-probe --filter TerminalKeyboardWiringGuardTests --apply "python3 -I $TMPDIR/plant-option-as-meta.py"
```

```bash
rm -f "$TMPDIR/plant-option-as-meta.py"
```

**Corrected 2026-10-09 by Task 4, and this withdraws the command this step first committed**, quoted verbatim as it stood:

```bash
scripts/mutation-probe --filter TerminalKeyboardWiringGuardTests --apply "python3 -I -c \"
import io
p='Sources/MacSCPAppKit/SSHTerminalView.swift'
s=io.open(p,encoding='utf-8').read()
old='        let desiredOptionAsMetaKey = settingsStore.terminalOptionAsMetaKey'
assert s.count(old)==1, 'anchor not unique: %d' % s.count(old)
s=s.replace(old, '        terminal.optionAsMetaKey = settingsStore.terminalOptionAsMetaKey\n'+old)
io.open(p,'w',encoding='utf-8').write(s)
\""
```

That form does not run here. The session's worktree guard refuses it — "this command is too complex to verify that it stays inside the worktree ... Split it into plain, separate commands" — so Task 2's implementer ran the identical plant from a script file instead and disclosed the deviation in `0b16e7be`'s body and in the Task 2 report. A command that has to be repaired before it runs invites the next reader to repeat the author's assumption while repairing it, which is the failure this project's "a number travels with the command that produced it" rule exists for, so the step now commits the form that ran. The python is byte-identical to the python the withdrawn inline form carried — same anchor, same `assert s.count(old)==1`, same replacement; `diff` against the file Task 2 passed to `--apply` reported no difference. Only the delivery changed: a file instead of `-c`, written under `$TMPDIR` rather than into a session scratchpad whose path no reader shares.

Task 4 ran the three commands above in exactly the form committed here, from the repository root at `5aaa9f65`, with a clean tree, and the harness printed:

```
── plant
   Sources/MacSCPAppKit/SSHTerminalView.swift | 1 +
   1 file changed, 1 insertion(+)
── (baseline: staged tree at 5aaa9f65)
── build
── test --filter TerminalKeyboardWiringGuardTests
RESULT: RED — 6 test(s) ran, and the plant was caught by:
  macSCPAppKitTests.TerminalKeyboardWiringGuardTests/theWrapperWritesTheSettingOnlyThroughTheGate()/TerminalKeyboardWiringGuardTests.swift:85:6
── revert
```

Six tests, not the two Task 2 saw, because Task 3 added four cases to the same file; the case that catches the plant is the same one. `git status --porcelain` printed nothing afterwards, so the revert was clean.

(`scripts/mutation-probe --filter <regex> --apply <shell command>` is the form its own usage line commits, so `--filter` comes first.)

Expected: RED on `theWrapperWritesTheSettingOnlyThroughTheGate`, because the body now holds two assignments to the flag while every `contains` anchor still matches.

Three outcomes are **not** passes and the harness names each one separately: `BUILD FAILED` (zero tests ran), `PLANT FAILED` (the apply command exited non-zero — which is what the `assert` above does when the anchor is not unique) and `PLANT CHANGED` (the apply matched nothing, a silent no-op). Any of the three means the probe proved nothing, not that the guard is fine. Record the outcome verbatim in the report.

- [ ] **Step 6: Commit**

```bash
git add Sources/MacSCPAppKit/SSHTerminalView.swift Tests/macSCPAppKitTests/TerminalKeyboardWiringGuardTests.swift
git commit -F - <<'MSG'
feat(terminal): the Option-as-Meta setting reaches the terminal view

<< the red from Step 2, pasted as the run printed it >>

The value is applied through a record on the coordinator rather than on
every render, unlike the two mouse flags beside it: SwiftTerm's own
Option-Command-O chord flips the flag inside the view, and an unconditional
write would undo it on the next unrelated re-render.

<< the outcome of the probe in Step 5, with the command >>

What the suite does not establish: that the gate really leaves a pressed
Option-Command-O standing. That needs a running app, and the plan assigns
the check to the maintainer.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
MSG
```

---

### Task 3: The switch, and the four catalogues

**Files:**
- Modify: `Sources/MacSCPAppKit/SettingsView.swift`
- Modify: `Sources/MacSCPAppKit/Resources/en.lproj/Localizable.strings`
- Modify: `Sources/MacSCPAppKit/Resources/de.lproj/Localizable.strings`
- Modify: `Sources/MacSCPAppKit/Resources/fr.lproj/Localizable.strings`
- Modify: `Sources/MacSCPAppKit/Resources/pl.lproj/Localizable.strings`
- Modify: `Tests/macSCPAppKitTests/TerminalKeyboardWiringGuardTests.swift`

**Interfaces:**
- Consumes: `SettingsStore.terminalOptionAsMetaKey` (Task 1); the helpers `views`, `catalog`, `keys`, `settingsTab` already declared in the guard file (Task 2).
- Produces: the catalogue keys `settings.terminal.optionAsMeta` and `settings.terminal.optionAsMeta.footer`.

- [ ] **Step 1: Write the failing guard — the settings half**

Append inside `TerminalKeyboardWiringGuardTests`, after `theWrapperWritesTheSettingOnlyThroughTheGate`:

```swift
    // MARK: - Settings tab

    @Test func theSettingsTabBindsTheToggleThroughTheCatalogueKeys() throws {
        let views = try Self.views(Self.settingsViewFile)
        let range = try TransferQueueBarCancelGuardTests.declarationBodyRange(
            of: Self.settingsTab, in: views.code)
        let code = TransferQueueBarCancelGuardTests.slice(range, of: views.code)
        let literals = TransferQueueBarCancelGuardTests.slice(range, of: views.withLiterals)
        #expect(code.contains("$store.terminalOptionAsMetaKey"))
        for key in Self.keys {
            #expect(literals.contains("\"\(key)\""), "TerminalSettingsTab does not use \(key)")
        }
    }

    @Test func bothKeysAreInAllFourCatalogues() throws {
        for locale in ["en", "de", "fr", "pl"] {
            let entries = try Self.catalog(locale)
            for key in Self.keys {
                #expect(entries[key] != nil, "\(locale) has no \(key)")
            }
        }
    }

    @Test func theGermanFooterAddressesTheUserAsDu() throws {
        let footer = try #require(
            try Self.catalog("de")["settings.terminal.optionAsMeta.footer"])
        #expect(footer.contains(" du "))
    }

    /// The footer exists largely to say the chord out loud: it works today
    /// and the UI mentions it nowhere. All four catalogues name it.
    ///
    /// A weak anchor, deliberately: `-O` is what survives translating
    /// "Option-Command-O" into four languages, and it would also match a
    /// hyphen before any word starting with O. It pins that the chord was
    /// not dropped in translation, not that the sentence around it is the
    /// right sentence — that one is the reviewer's to read.
    @Test func everyFooterNamesTheChord() throws {
        for locale in ["en", "de", "fr", "pl"] {
            let footer = try #require(
                try Self.catalog(locale)["settings.terminal.optionAsMeta.footer"])
            #expect(footer.contains("-O"), "\(locale) footer does not name the chord")
        }
    }
```

- [ ] **Step 2: Run it to verify it fails**

Run: `swift test --filter TerminalKeyboardWiringGuardTests`
Expected: the four new cases red (the two from Task 2 stay green). Quote the actual failures.

- [ ] **Step 3: Add the section**

In `Sources/MacSCPAppKit/SettingsView.swift`, inside `TerminalSettingsTab`'s `Form`, immediately **after** the closing brace of the `Section` whose footer is `settings.terminal.pasteOnRightClick.footer` and **before** the comment line beginning `// Plan of 2026-09-19, Task 4.`:

```swift
                // Keyboard, not mouse — its own section because the one
                // above carries a mouse footer. Plan of 2026-10-09.
                Section {
                    Toggle(
                        L10n.string(
                            "settings.terminal.optionAsMeta", "Use Option as the Meta key"),
                        isOn: $store.terminalOptionAsMetaKey)
                } footer: {
                    Text(L10n.string(
                        "settings.terminal.optionAsMeta.footer",
                        "Off, the Option key composes characters — on many keyboards that is how you type @, the vertical bar and the braces. On, Option sends an ESC prefix first, which programs like Emacs read as Meta. Option-Command-O switches it for the terminal you are looking at, until you change this setting or reopen the tab."))
                        .foregroundStyle(.secondary)
                }
```

- [ ] **Step 4: Add the strings to all four catalogues**

`en.lproj/Localizable.strings`, after the `settings.terminal.pasteOnRightClick.footer` line:

```
"settings.terminal.optionAsMeta" = "Use Option as the Meta key";
"settings.terminal.optionAsMeta.footer" = "Off, the Option key composes characters — on many keyboards that is how you type @, the vertical bar and the braces. On, Option sends an ESC prefix first, which programs like Emacs read as Meta. Option-Command-O switches it for the terminal you are looking at, until you change this setting or reopen the tab.";
```

`de.lproj` — du-form, and it must contain `" du "` for the test above:

```
"settings.terminal.optionAsMeta" = "Wahltaste als Meta-Taste verwenden";
"settings.terminal.optionAsMeta.footer" = "Ausgeschaltet komponiert die Wahltaste Zeichen — auf einer deutschen Tastatur tippst du so @, den senkrechten Strich und die Klammern. Eingeschaltet schickt die Wahltaste ein ESC voraus, was Programme wie Emacs als Meta lesen. Mit Wahl-Befehl-O schaltest du es für das Terminal um, das du gerade vor dir hast — bis du diese Einstellung änderst oder den Tab neu öffnest.";
```

`fr.lproj`:

```
"settings.terminal.optionAsMeta" = "Utiliser Option comme touche Meta";
"settings.terminal.optionAsMeta.footer" = "Désactivé, la touche Option compose des caractères — sur de nombreux claviers, c'est ainsi que l'on tape @, la barre verticale et les accolades. Activé, Option envoie d'abord un préfixe ESC, que des programmes comme Emacs lisent comme Meta. Option-Commande-O le change pour le terminal affiché, jusqu'à ce que vous modifiiez ce réglage ou rouvriez l'onglet.";
```

`pl.lproj`:

```
"settings.terminal.optionAsMeta" = "Używaj klawisza Option jako Meta";
"settings.terminal.optionAsMeta.footer" = "Wyłączone — klawisz Option składa znaki; na wielu klawiaturach tak wpisuje się @, kreskę pionową i nawiasy klamrowe. Włączone — Option najpierw wysyła przedrostek ESC, co programy takie jak Emacs odczytują jako Meta. Option-Command-O przełącza to dla widocznego terminala, dopóki nie zmienisz tego ustawienia lub nie otworzysz karty ponownie.";
```

- [ ] **Step 5: Run the guard, then the whole suite**

Run: `swift test --filter TerminalKeyboardWiringGuardTests`
Expected: 6 tests, 0 failures.

Run: `swift test`
Expected: 0 failures. The localization checks compare the catalogues against each other, so a key missing from one of the four fails there rather than here — if that happens, the missing catalogue is the bug, not the check.

- [ ] **Step 6: Commit**

```bash
git add Sources/MacSCPAppKit/SettingsView.swift Sources/MacSCPAppKit/Resources Tests/macSCPAppKitTests/TerminalKeyboardWiringGuardTests.swift
git commit -F - <<'MSG'
feat(settings): the Terminal tab offers Option as the Meta key

<< the red from Step 2, pasted as the run printed it >>

The footer names Option-Command-O, which works today and appeared nowhere
in the UI.

<< the whole-suite figure from Step 5, beside the command that produced it >>

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
MSG
```

---

### Task 4: Closeout — the record, the docs, and the check the suite cannot make

**Files:**
- Modify: `docs/BACKLOG.md`
- Modify (noix-docs worktree): `src/content/docs/macscp/guide/terminal.md`, `src/content/docs/macscp/reference/changelog.md`

**Interfaces:** consumes everything above; produces nothing code reads.

- [ ] **Step 1: Correct backlog row 117 in place, quoting both withdrawals**

Find it by content, not by number:

```bash
/usr/bin/grep -n 'BUG: the terminal swallows every character' docs/BACKLOG.md
```

Two claims in that row are falsified by Tasks 1–3 and **both must be withdrawn with their wording quoted**:

1. Its status `**Open, recorded 2026-10-09**` becomes closed, dated, naming the commits.
2. Its verification command. The row says `grep -rln optionAsMetaKey Sources/` "returns NOTHING, which is the checkable form of this claim" — and after Task 2 it returns files. That sentence falsifies itself the moment the fix lands, so the correction quotes it verbatim and replaces it with the command's new output. **Run the command again after writing the sentence**; a row that cites its own file is the exact trap this project has measured twice.

Its `**Not a default to flip, a setting to add.**` stands and is not touched. Its closing sentence — "the decision a taker owes is which way it defaults and whether it is per-session or global" — is quoted and replaced by the three decisions with their date.

The cell takes **no pipe character at all**: name the vertical bar in words, as the row already does, and use several `-e` patterns rather than one `-E` alternation in any command written into it.

- [ ] **Step 2: Verify the row**

```bash
awk -F'|' '/BUG: the terminal swallows every character/ {print NF}' docs/BACKLOG.md
```

Expected: the same field count every other row of that table has — check one neighbour with the same command. A cell that gained a pipe shows up here as a different number.

- [ ] **Step 3: Commit the record**

```bash
git add docs/BACKLOG.md
git commit -F - <<'MSG'
docs(backlog): close the swallowed-Option row and withdraw its two stale claims

<< name both withdrawn passages and quote each one verbatim, and give the
field count from Step 2 beside the command that produced it >>

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
MSG
```

- [ ] **Step 4: The user documentation**

The docs repository is shared. Its main checkout is on `ddev-sync`, someone else's branch — **do not touch it**. Make a new worktree off `origin/main`:

```bash
cd /Users/noidee/_dev/noix-docs && git fetch origin && git worktree add ../noix-docs-option-as-meta -b docs/macscp-option-as-meta origin/main
```

In that worktree, `src/content/docs/macscp/guide/terminal.md`, add a subsection under **The integrated terminal** (after its `:::note` about WebDAV and S3) describing the setting, its default, and the chord. Mark it unreleased in the spelling this repo already uses — `:::note[Coming in the next version]` — because the current release is v1.6.0 and this is not in it.

Add one row to the `## Unreleased` table in `src/content/docs/macscp/reference/changelog.md`, in the style of the rows already there (area, then what changed, and what it was up to and including v1.6.0).

No tech-stack terms: user docs are public texts. Do not name SwiftTerm, the property, or the revision — say what the app does.

Then, in that worktree:

```bash
npm install && npm run build && npm run check
```

Both must pass. Commit on that branch. **Do not push and do not merge** — the maintainer decides that, and said so for the archive docs branch already on `origin`.

One thing to expect rather than be surprised by: `docs/macscp-archives` is an unmerged branch that also adds to the same `## Unreleased` table. Two branches adding rows to one table conflict trivially at merge time; say so in the report rather than reaching into that branch.

- [ ] **Step 5: The check the suite cannot make — the maintainer's**

**Do not mark this step done, and do not launch the app.** Write it into the report as outstanding, addressed to the maintainer:

1. Open a session, open the terminal, and type the characters Option composes — `@`, the vertical bar, the braces, the brackets. They should arrive.
2. Press `⌥⌘O`, then press Option with a letter. Meta should now reach the shell (in `bash`, `Esc`-prefixed input shows readline's argument display).
3. With the chord still flipped, switch tabs and come back, or change an unrelated setting. **The chord should still be flipped** — this is the gate, and it is the one claim no test here establishes.
4. Now change the setting itself. The setting should win over the chord.

If step 3 fails, the gate is wrong and the record on the coordinator is the place to look.

- [ ] **Step 6: Report**

Written from the diff, not from the intent: read back what changed before describing it as done. State the whole-suite figure with its command, the mutation-probe outcome from Task 2, that `npm run build` and `npm run check` both passed, and that Step 5 is outstanding and belongs to the maintainer.
