# P2: Terminal edition — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The terminal gets the edge the rest of the app already uses, and
both window halves — files and terminal — become independently switchable
from the toolbar, with a state that survives the session.

**Architecture:** The decision of which halves are visible and which switch
is locked lives as a testable type in Core; the toolbar and the layout read
from it. The state moves as an optional field onto `StoredSession` —
alongside `groupID`, not into the backend field bag, because it is not a
connection property.

**Tech Stack:** Swift 6, `.swiftLanguageMode(.v5)`, SwiftPM, macOS 15+,
SwiftUI, Swift Testing, two test targets.

## Global Constraints

- **Code, comments, test names: English.** Internal docs (`docs/`) German.
- **Every new L10n key in all four catalogs** (en/de/fr/pl), identical key
  sets; proved via a guard test and
  `for f in $(git ls-files '*.strings'); do plutil -lint "$f"; done`.
- **Never a line number in a comment.**
- **No secret in a log, error, or test failure message.**
- **This plan's prose is a claim to be checked.** In the previous phase,
  five of eleven tasks had a real error in the brief.
- **Two probes before every commit**, not one:
  1. Would a test stay green if the function returned a constant?
  2. **Which claim in my doc comment does no test observe?**
     The second found seven real gaps in P1, the first found none of them.
- **The GUI is not started.** `scripts/package-app` is allowed.
- Conventional Commits, English, footer:
  `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`
- Full suite green before every commit. Starting point: **1881 tests in 159
  suites** — remeasure, never copy from elsewhere.

---

### Task 1: The edge — one value, two readers

**Measured current state:** `SSHTerminalView` gets **no** inset at all in
`terminalPanel` and sits flush against the edge. The `.ended` text block in
the same panel uses `.padding(.vertical, 8).padding(.horizontal, 14)`. The
`TerminalPanelHeader` built in P1 uses `12/6`.

**Files:**
- Modify: `Sources/MacSCPAppKit/DesignTokens.swift`
- Modify: `Sources/MacSCPAppKit/ContentView+Detail.swift`
- Create: `Tests/macSCPAppKitTests/TerminalPanelInsetTests.swift`

- [ ] **Step 1: Remeasure, don't believe**

Check the three values above yourself against the code. If one deviates,
**the plan** is wrong — report it, don't adjust it silently.

- [ ] **Step 2: Name the value**

A pair of named constants in `DesignTokens` (the file today holds only
colors — so the doc comment must say why a dimension now lives there too:
because two views have to agree on it).

- [ ] **Step 3: The test that is worth something**

A test on "the number is 14" only checks that someone typed 14. The test
that carries weight is the **coupling**: header and terminal surface read
the same value. Write it so it goes red if either of the two spots gets its
own number again.

If that isn't possible without view instantiation: say so, and pin instead
what is possible — e.g. that there is exactly **one** source (a guard test
over the source, like P1's shortcut guard).

- [ ] **Step 4: Apply**

Terminal surface and header read the constants. **The `.ended` block stays
as it is** — it already has the values; if you switch it over, only to the
same constant, without changing the number.

- [ ] **Step 5: Full suite, commit**

```bash
swift test
git commit -m "feat(app): give the terminal the inset the rest of the panel already uses"
```

---

### Task 2: `PaneVisibility` (Core) — the decision

**Files:**
- Create: `Sources/macSCPCore/Presentation/PaneVisibility.swift`
- Create: `Tests/macSCPCoreTests/PaneVisibilityTests.swift`

**Interfaces:**
```swift
public struct PaneVisibility: Equatable, Sendable, Codable {
    public var showsFiles: Bool
    public var showsTerminal: Bool
}
public enum PaneToggle: Equatable, Sendable { case files, terminal }
public struct PaneToggleState: Equatable, Sendable {
    public let isOn: Bool
    public let isEnabled: Bool
}
```
plus a function that, from `PaneVisibility` **and** whether the backend has
a shell, produces a `PaneToggleState` for each of the two switches, and one
that applies a click.

- [ ] **Step 1: The failing tests**

```swift
/// Both halves visible is the ordinary state, and both toggles are live.
@Test func withBothVisibleEitherCanBeTurnedOff() { … }

/// The last visible half cannot be turned off — the window would be empty.
/// The toggle is disabled rather than silently doing nothing, so the user
/// can see why the click does not land.
@Test func theLastVisibleHalfIsLocked() { … }

/// A backend without a shell has no terminal to show. Files is then the
/// only half, and therefore locked — the same rule as above, reached by a
/// different road.
@Test func withoutAShellFilesIsTheOnlyHalfAndIsLocked() { … }

/// Turning a half back on unlocks the other one again — the lock is a
/// consequence of the state, never a latch that stays set.
@Test func turningTheOtherHalfBackOnUnlocksBoth() { … }

/// A stored state that says "no halves visible" cannot be trusted — a
/// hand-edited sessions.json could carry it, and it would render an empty
/// window. Decoding repairs it rather than propagating it.
@Test func aStoredStateWithNothingVisibleIsRepaired() { … }
```

The last one is the important one: the same shape as the line-break rule on
`Snippet` — **the repair belongs in the model**, not in the view, because a
hand-edited file would otherwise bypass it.

- [ ] **Step 2: Red, implement, green**

- [ ] **Step 3: Both probes, then commit**

Answer in the report: which test goes red if `isEnabled` is constantly
`true`? And: which claim in your doc comments does no test observe?

```bash
git commit -m "feat(core): decide pane visibility and which toggle is locked"
```

---

### Task 3: The toolbar and the layout

**Files:**
- Modify: `Sources/MacSCPAppKit/ContentView+Lifecycle.swift` (toolbar)
- Modify: `Sources/MacSCPAppKit/ContentView+Detail.swift` (`detail`)
- Modify: `Sources/MacSCPAppKit/SessionTab.swift` (state on the tab)
- Modify: the four catalogs

**Measured current state:** The toolbar has two switches — "Terminal"
(⌘T, disabled when `!activeTabSupportsShell`) and "Transfers". `detail`
holds a `VSplitView` with an `HSplitView` of two `BrowserPane`, and below
it `if session.terminal.isVisible { terminalPanel(session) }`.

- [ ] **Step 1: Remeasure**

- [ ] **Step 2: The second switch**

"Files" next to "Terminal", both reading their `PaneToggleState` from
Task 2. **No new keyboard shortcut** — ⌘T stays with the terminal, "Files"
gets none as long as nobody asks for one.

- [ ] **Step 3: The layout**

The `HSplitView` with the two panes gets hooked up to `showsFiles`, the way
the terminal already hooks into its own visibility. **The existing
terminal visibility is the source for `showsTerminal`** — don't build a
second piece of state alongside it that can drift out of sync. If that
can't be cleanly merged, that is a finding: report it.

- [ ] **Step 4: Suite, catalogs, commit**

```bash
git commit -m "feat(app): switch both window halves from the toolbar"
```

---

### Task 4: The state survives the session

**Files:**
- Modify: `Sources/macSCPCore/Sessions/StoredSession.swift`
- Modify: the session export/import path
- Modify/Create: the associated tests

**Measured current state:** `StoredSession.init(from:)` uses
`decodeIfPresent` for all optional fields — a new optional field is thus
migration-free. `groupID` is the precedent for a field that belongs to the
session but is **not a connection property**. Pane visibility belongs in
the same category, **not** in the backend field bag (`FieldValues`, keyed
`"<namespace>.<fieldID>"`), which carries a protocol's schema fields.

- [ ] **Step 1: Follow the precedent, don't guess**

Look at what export/import does with `groupID` — whether it is carried
along, dropped, or rewritten — and **do the same**. Write in the report
what you found. If `groupID` is deliberately dropped on export (say,
because groups are resolved anew on the target side), then the same intent
applies here, and that is the answer — no reason to build a special case
for visibility.

- [ ] **Step 2: The field**

Optional, `decodeIfPresent` with a default that means "both visible" — a
file without the field behaves exactly as it does today.

- [ ] **Step 3: The tests**

- A `sessions.json` **without** the field loads and yields "both visible".
  Against a literal legacy file, not against something freshly encoded.
- An export round trip carries the value along (or deliberately drops it —
  depending on what step 1 found; pin whichever applies).
- A file that claims "nothing visible" is repaired (Task 2's rule applies
  here too — check that it does, rather than assuming it).

- [ ] **Step 4: Suite, commit**

```bash
git commit -m "feat(core): remember which window halves a saved session shows"
```

---

### Task 5: Phase completion

**Files:**
- Create: `docs/superpowers/specs/2026-08-12-p2-abschluss.md`

- [ ] **Step 1: Measure**

```bash
swift test 2>&1 | tail -3
for f in $(git ls-files '*.strings'); do plutil -lint "$f"; done
MACSCP_VERSION="1.2.0-dev" MACSCP_BUILD="$(git rev-list --count HEAD)" ./scripts/package-app
```
The build takes several minutes — **start it in the background and keep
working**, then check afterward (`lipo -archs` on both binaries, both
resource bundles, all four `.lproj`, `plutil -lint` on the Info.plist).
**The app is not started.**

- [ ] **Step 2: Report**

It states the measured numbers; what is held by tests and what is only by
review; what export does with the new field and why; and **explicitly**
that the GUI was not started — with the list of what the maintainer must
look at: the new edge, the two switches, the locked last switch, and
whether a reopened session actually comes up the way it last stood.

- [ ] **Step 3: Commit**

```bash
git commit -m "docs(app): record the terminal chrome phase"
```

---

## Self-review of this plan

**Spec coverage:** Edge 14/8 → Task 1. Two switches + lock → Tasks 2/3.
No terminal switch without a shell → Task 2 (rule) and Task 3 (display).
State per saved session including export → Task 4.

**Three places where this plan deliberately does not guess**, but has
things measured instead: the three edge values (Task 1, step 1), whether
the existing terminal visibility can cleanly serve as the source (Task 3,
step 3), and what export currently does with `groupID` (Task 4, step 1).
All three are marked "report rather than adjust".

**Not part of this:** host tags, sidebar filter, import/export of snippets
(P3); the bulk runner; multi-line commands; multi-window (v2).
