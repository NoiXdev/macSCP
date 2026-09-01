# Switching panes from the tab menu — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The tab context menu shows and hides files and terminal, and offers the external terminal as its own entry.

**Basis:** `docs/superpowers/specs/2026-08-27-tab-areas-toggle-design.md`

**Architecture:** No new model. The states come from `PaneToggleState`, which the toolbar already reads; `TabContextMenu.entries` receives them as a finished answer, the way it already receives `supportsShell`. The one-sided "Open Terminal" entry goes away.

**Order:** first the value in Core, then the wiring.

## Global Constraints

- Code, comments, identifiers, test names, commit messages: **English
  only**; catalog values are translations, the German addresses the
  user as *du*.
- Conventional Commits; footer `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- **All four catalogs** (`en`, `de`, `fr`, `pl` under
  `Sources/MacSCPAppKit/Resources/`), same key sets.
- **Only show what is possible** — no `.disabled`, no greying out in the
  tab menu. An entry that does not apply **is absent** (maintainer, 2026-08-27).
- **`terminalTarget` stays out of this.** The pane toggles always mean
  the built-in pane, "Open External Terminal" always means external —
  exactly like the two entries of the "Terminal" menu, which deliberately
  never change with the setting, "so that switching it never takes a
  capability away."
- **`TerminalPanelViewModel.toggle()` stays the only write path** for
  terminal visibility; it owns the shell's lifecycle. No bare bool write.
- All six targets are on `.swiftLanguageMode(.v6)`; **CI goes red as soon
  as the number of distinct warning sites is above 1.**
- **No line numbers, no location references in comments.** Every number
  and every enumeration is counted in the pass that writes it.
- The app is not launched, nothing is pushed.

---

### Task 1: The entries in Core

**Files:**
- Modify: `Sources/macSCPCore/Presentation/TabContextMenu.swift`
- Modify: `Sources/macSCPCore/Presentation/PaneVisibility.swift` (one comment only)
- Test: `Tests/macSCPCoreTests/TabContextMenuTests.swift`

**Interfaces:**
- Consumes: `PaneToggle` (`.files`/`.terminal`) and `PaneToggleState`
  (`isOn`, `isEnabled`) from `PaneVisibility.swift`.
- Produces: `TabMenuEntry.pane(PaneToggle, PaneAction)` and
  `TabMenuEntry.openExternalTerminal`; `TabMenuEntry.openTerminal`
  **goes away**. New signature
  `entries(atIndex:ofTabCount:supportsShell:isAdHoc:isConnected:filesToggle:terminalToggle:)`.
  Task 2 renders from it.

**Measured current state:** `entries` today takes five facts and appends
`.openTerminal` on `supportsShell && isConnected`. `PaneToggleState`
delivers `isOn` and `isEnabled`; `toggleState(for:hasShell:)` already
folds in `hasShell` and reports `isEnabled == false` for the **only
still-visible** half.

- [ ] **Step 1: Write the test first.** Add to the existing suite:

```swift
    private static let bothVisible = PaneToggleState(isOn: true, isEnabled: true)
    private static let visibleAndLocked = PaneToggleState(isOn: true, isEnabled: false)
    private static let hidden = PaneToggleState(isOn: false, isEnabled: true)

    @Test func aVisiblePaneOffersHidingItAndAHiddenOneOffersShowing() {
        let entries = TabContextMenu.entries(
            atIndex: 0, ofTabCount: 1,
            supportsShell: true, isAdHoc: false, isConnected: true,
            filesToggle: Self.bothVisible, terminalToggle: Self.hidden)
        #expect(entries.contains(.pane(.files, .hide)))
        #expect(entries.contains(.pane(.terminal, .show)))
    }

    @Test func theOnlyVisibleHalfOffersNoEntryAtAll() {
        let entries = TabContextMenu.entries(
            atIndex: 0, ofTabCount: 1,
            supportsShell: true, isAdHoc: false, isConnected: true,
            filesToggle: Self.visibleAndLocked, terminalToggle: Self.hidden)
        #expect(!entries.contains(.pane(.files, .hide)))
        #expect(!entries.contains(.pane(.files, .show)))
        #expect(entries.contains(.pane(.terminal, .show)))
    }

    @Test func aDisconnectedTabOffersNoPaneEntries() {
        let entries = TabContextMenu.entries(
            atIndex: 0, ofTabCount: 1,
            supportsShell: true, isAdHoc: false, isConnected: false,
            filesToggle: Self.bothVisible, terminalToggle: Self.bothVisible)
        #expect(!entries.contains(.pane(.files, .hide)))
        #expect(!entries.contains(.pane(.terminal, .hide)))
        #expect(!entries.contains(.openExternalTerminal))
    }

    @Test func theExternalTerminalNeedsAShellAndAConnection() {
        #expect(TabContextMenu.entries(
            atIndex: 0, ofTabCount: 1,
            supportsShell: true, isAdHoc: false, isConnected: true,
            filesToggle: Self.bothVisible, terminalToggle: Self.hidden)
            .contains(.openExternalTerminal))
        #expect(!TabContextMenu.entries(
            atIndex: 0, ofTabCount: 1,
            supportsShell: false, isAdHoc: false, isConnected: true,
            filesToggle: Self.bothVisible, terminalToggle: Self.hidden)
            .contains(.openExternalTerminal))
    }

    @Test func bothHalvesVisibleOffersBothHidingEntries() {
        let entries = TabContextMenu.entries(
            atIndex: 0, ofTabCount: 1,
            supportsShell: true, isAdHoc: false, isConnected: true,
            filesToggle: Self.bothVisible, terminalToggle: Self.bothVisible)
        #expect(entries.contains(.pane(.files, .hide)))
        #expect(entries.contains(.pane(.terminal, .hide)))
    }

    @Test func theOrderIsFixedRegardlessOfWhichEntriesApply() {
        #expect(TabContextMenu.entries(
            atIndex: 1, ofTabCount: 3,
            supportsShell: true, isAdHoc: true, isConnected: true,
            filesToggle: Self.bothVisible, terminalToggle: Self.hidden)
            == [.close, .closeOthers, .move(.left), .move(.right),
                .pane(.files, .hide), .pane(.terminal, .show),
                .openExternalTerminal, .saveAsSession])
    }
```

  **The existing test of the same name (`theOrderIsFixed…`) is replaced**,
  because its expected list contains `.openTerminal`; likewise the two
  existing tests that check `.openTerminal`. When replacing them, count
  how many tests the suite has afterward, if you write that number down
  anywhere.

- [ ] **Step 2: Run it red.**

Run: `swift test --filter TabContextMenu`
Expected: FAIL — `type 'TabMenuEntry' has no member 'pane'`.

- [ ] **Step 3: Implement.** In `TabContextMenu.swift`:

```swift
/// Which way a pane entry points: the action the user can take right now.
/// One entry per pane with a changing label, never two entries of which one
/// is dead — this menu omits what does not apply instead of greying it.
public enum PaneAction: Equatable, Sendable {
    case show
    case hide
}
```

  In `TabMenuEntry`: **remove** `case openTerminal`, add instead

```swift
    /// Show or hide one of the window's two halves. Present only while the
    /// pane's own `PaneToggleState` reports `isEnabled` — which is false for
    /// the last visible half, so no entry here can empty the window.
    /// Always the built-in terminal; `SettingsStore.terminalTarget` has no
    /// say, for the same reason the Terminal menu's entries ignore it.
    case pane(PaneToggle, PaneAction)
    /// Open this session's shell in an external terminal. Always external,
    /// never the built-in pane. Needs a shell and a live connection.
    case openExternalTerminal
```

  And in `entries`, in place of the `.openTerminal` line:

```swift
        if isConnected && filesToggle.isEnabled {
            entries.append(.pane(.files, filesToggle.isOn ? .hide : .show))
        }
        if isConnected && terminalToggle.isEnabled {
            entries.append(.pane(.terminal, terminalToggle.isOn ? .hide : .show))
        }
        if supportsShell && isConnected { entries.append(.openExternalTerminal) }
```

  Extend the signature by the two parameters (`filesToggle:`,
  `terminalToggle:` at the end) and update the function's doc comment
  accordingly: it currently lists "three facts" — **count what holds
  true afterward.**

- [ ] **Step 4: Fix the stale comment.** In
  `PaneVisibility.swift` it reads:

  > This type only decides WHICH halves are visible. It says nothing about
  > `TerminalPanelViewModel.isVisible`, the existing terminal-only toggle —
  > reconciling the two is a later task's decision.

  This is outdated: `SessionTab.effectivePaneVisibility(terminalIsVisible:hasShell:)`
  is the one point of assembly, and its own comment says there must be
  only one. Write that there, instead of deferring a task that is already done.

- [ ] **Step 5: Run it green.** `swift test --filter TabContextMenu`
- [ ] **Step 6:** Full suite green, no new warning.
- [ ] **Step 7: Commit** — `feat(tabs): let the menu offer both panes, not just the terminal`

---

### Task 2: Wiring

**Files:**
- Modify: `Sources/MacSCPAppKit/ContentView+Lifecycle.swift`,
  `Sources/MacSCPAppKit/TabStripView.swift`
- Modify: all four `Localizable.strings`
- Test: `Tests/macSCPAppKitTests/TabContextMenuWiringGuardTests.swift`

**Interfaces:**
- Consumes: everything from Task 1.

**Measured current state:** `tabMenuEntries(for:)` looks up the index,
reads `BackendDescriptor…capabilities`, and calls `TabContextMenu.entries`.
`handleTabMenuEntry` branches over the cases; `openTerminalPane(in:)`
**only shows** and returns early if the terminal is already visible.
`SessionTab.paneToggleState(for:terminalIsVisible:hasShell:)` delivers
exactly what Task 1 needs — the same function the toolbar reads from.

- [ ] **Step 1: Get the facts.** `tabMenuEntries(for:)` passes the two
  states along, from `paneToggleState(for:terminalIsVisible:hasShell:)`.
  **Don't assemble them yourself** — the source says at
  `effectivePaneVisibility` that there must be only one assembly point,
  and a second one here would be exactly the mistake this work aims to avoid.
- [ ] **Step 2: The titles.** Five keys into all four catalogs:
  `tabs.menu.showFiles`, `tabs.menu.hideFiles`, `tabs.menu.showTerminal`,
  `tabs.menu.hideTerminal`, `tabs.menu.openExternalTerminal`. The old key
  `tabs.menu.openTerminal` **goes away in all four**. German addresses the
  user as *du*.
- [ ] **Step 3: The handlers.**
  - `.pane(.files, _)` calls the existing path for a click on the files
    toggle — find it via `applyingClick(on: .files, …)`, instead of
    building a second one.
  - `.pane(.terminal, _)` calls `session.terminal.toggle()` and then
    `persistActivePaneVisibility()`, the way `openTerminalPane` already
    does today — but **without** its `guard !session.terminal.isVisible`,
    since that was exactly what made the entry one-sided.
  - `.openExternalTerminal` calls `requestExternalTerminal(for: tab)`.
  - `openTerminalPane(in:)` goes away, provided no other caller remains —
    **count the callers before deleting.**
- [ ] **Step 4: Update the guard.** `TabContextMenuWiringGuardTests`
  anchors the menu entries and the pass-through path verbatim. The switch
  from `.openTerminal` to two new cases will turn it red — **that is
  intentional and the proof that it works.** Update it and then check
  whether its "What this guard does NOT catch" section still holds.
- [ ] **Step 5:** Full suite green, no new warning.
- [ ] **Step 6: Commit** — `feat(tabs): switch panes from the tab menu`

---

## What is explicitly out of scope

- No change to `terminalTarget`, to the toolbar, or to the menu bar's
  "Terminal" menu.
- No greying out in the tab menu.
- No change to how `TerminalPanelViewModel.isVisible` is written.
- No answer to I5 (saving overwrites a same-named entry).
