# Three small usability points — implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Eliminate three independent backlog annoyances, each individually testable and immediately noticeable.

**Basis:** `docs/superpowers/specs/2026-08-20-backlog-sitzungen-tabs-seitenleiste.md` (C1, D4) and `2026-08-20-backlog-verwaltungs-sheets.md` (item 3).

**Order:** from smallest blast radius to largest. The three tasks do not depend on each other; each can be deferred on its own.

## Global Constraints

- Code, comments, identifiers, test names, commit messages: **English only**; catalog values are translations, German uses "du".
- Conventional Commits; footer `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- All four catalogs for new strings, same key sets.
- No line numbers, no location references in comments; every number counted in the same pass.
- **No test reaches a real keychain, session store, or configuration.** `ContentView` takes injected stores.
- Guards: **mutation tests prove sensitivity, never scope.** Before choosing an anchor, ask *where* the property could be violated from.
- The app is not launched, nothing is pushed.

---

### Task 1: Single click selects, double click connects

**Files:**
- Modify: `Sources/MacSCPAppKit/SessionSidebar.swift`
- Test: `Tests/macSCPAppKitTests/`

**The measured current state:** the row hangs off `.onTapGesture { if !isRenaming { onSelect() } }`, and `onSelect` passes through `ContentView+Detail.swift` to `connectFromSidebar(stored)` — **one click establishes a connection.**

**What saves the path:** the same row's context menu already carries an entry **"Verbinden"**. So the connect path is not lost when the tap becomes selection.

- [x] **Step 1 (answered 2026-08-26):** The sidebar knows **no**
  selection. `selection` in `SessionSidebar.swift` belongs exclusively to
  the tag filter (`HostTagFilterRow`); a session row has only `onSelect`,
  and that leads straight into connecting.

  **Consequence for scoping:** the selection is the actual substance of
  this task, not the gesture. Merely defusing the single click without
  putting anything in its place turns it into a dead gesture — that would
  be worse than today. This task therefore covers:

  1. a selection state for the row (which session is meant),
  2. its visible highlight,
  3. double click and the Return key as connect paths,
  4. the existing context menu stays the third path.

  Point 3 is the reason point 1 carries any weight at all: a selection
  that no key acts on is just a coloring.
- [ ] **Step 2:** Test first: a single click does **not** connect, a double click does. Where that is not possible without a rendering environment, pull the decidable part into a testable value and let the view only display it.
- [ ] **Step 3:** Red. — [ ] **Step 4:** Implement. — [ ] **Step 5:** Full suite green.
- [ ] **Step 6: Commit** — `fix(sidebar): connect on double-click, select on single`

---

### Task 2: Drag and remember the sidebar width

**Files:**
- Modify: `Sources/MacSCPAppKit/ContentView+Detail.swift`, `Sources/macSCPCore/Settings/SettingsStore.swift`
- Test: `Tests/macSCPCoreTests/SettingsStoreTests.swift`

**The measured current state:** `.frame(minWidth: 170, idealWidth: 190, maxWidth: 260)`. The **upper bound 260** is why the bar cannot be dragged further right; nothing is saved.

- [ ] **Step 1:** Test first, following the pattern of `autoRefreshIntervalSeconds`: **both getter and setter clamp**, so a hand-edited `settings.json` cannot produce an unusable width. Name and justify the bounds.
- [ ] **Step 2:** Red. — [ ] **Step 3:** Add the property, wire the binding in the view, read and write the width.
- [ ] **Step 4:** Full suite green.
- [ ] **Step 5: Commit** — `feat(sidebar): remember how wide you dragged it`

---

### Task 3: Column sorting on the known-hosts sheet

**Files:**
- Modify: `Sources/MacSCPAppKit/KnownHostsSheet.swift`
- Test: `Tests/macSCPAppKitTests/`

**Why this is the cheapest point:** the sheet is already a `Table` with six columns. SwiftUI provides sorting via a `sortOrder` binding and `KeyPathComparator` — no Core involvement needed.

- [ ] **Step 1:** Decide, and justify in the report, whether the sort order is remembered across sessions. If yes, a field is added to `SettingsStore` and Task 2's pattern applies here too; if no, say why.
- [ ] **Step 2:** Test first on the **decidable** part — which comparison rule belongs to which column —, not on the drawing. In particular: a field that can be missing must not slide to an arbitrary spot when sorting.
- [ ] **Step 3:** Red. — [ ] **Step 4:** Implement. — [ ] **Step 5:** Full suite green.
- [ ] **Step 6: Commit** — `feat(knownhosts): sort the table by its columns`

---

## What explicitly does not belong here

- No conversion of Logins or SSH keys to `Table` — **rejected** by the maintainer on 2026-08-20.
- No quick filter, no three-dot menu, no nested folders: separate entries, separate decisions.
- No change to the file table's sorting.
