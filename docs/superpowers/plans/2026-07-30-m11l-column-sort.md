# M11l — Sorting by column click: implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Sort the file list by name/size/date — a column click selects the key, clicking again flips the direction; folders stay on top.

**Architecture:** The existing sort authority `sortedForDisplay` is parameterized by key + direction (folders-first stays); `RemoteBrowserViewModel` holds the sort state and threads it through `displayItems`, so `load`/`refreshQuietly`/the M11k search all sort consistently. The table reports header clicks, the ViewModel remains the single sort authority.

**Tech Stack:** Swift 6 (`.swiftLanguageMode(.v5)`), SwiftUI + AppKit, Swift Testing.

**Spec:** `docs/superpowers/specs/2026-07-30-m11l-column-sort-design.md`

## Global Constraints

- Code and comments **English only**; display text via the catalogs.
- **Folders always stay on top** (grouping, independent of key and
  direction).
- Sorting is STABLE (name tiebreaker for equal size/date); missing
  size/missing date deterministic.
- Sort authority stays in ONE place (Core `sortedForDisplay`) — AppKit
  does NOT sort the NSTableView rows itself; the order comes from
  `items`.
- Sort state survives `refreshQuietly` and directory changes (a display
  preference of the pane); the M11k search resets on a directory change,
  sorting does NOT.
- The parameterless `sortedForDisplay` call remains, defaulting to
  `.name` ascending (nothing else breaks).
- Always check `swift build` from a CLEAN build directory.
- Tests: Swift Testing, TDD. Baseline: **826 tests / 58 suites**.
- No release, no merge to `main`, no tag.

---

### Task 1: Parameterized sorting + VM state (Core)

**Files:**
- Modify: `Sources/macSCPCore/Presentation/RemoteBrowserViewModel.swift`
- Create: `Sources/macSCPCore/Presentation/FileSortKey.swift` (or inside the VM file, if small)
- Test: `Tests/macSCPCoreTests/RemoteBrowserViewModelTests.swift` (extend), possibly `Tests/macSCPCoreTests/FileSortTests.swift`

**Interfaces:**
- Consumes: `RemoteFileItem` (`name`, `isDirectory`, size, modification date — check the exact property names in the type).
- Produces (T2 relies on this literally):
  - `public enum FileSortKey: Sendable, Equatable { case name, size, modified }`
  - `RemoteBrowserViewModel.sortedForDisplay(_:key:ascending:)` (static, key/ascending with defaults `.name`/`true`)
  - On the VM: `var sortKey: FileSortKey`, `var sortAscending: Bool` (@Observable, didSet → re-derive).

- [x] **Step 1: Failing tests** (pure, Core) for `sortedForDisplay(key:ascending:)`:
  - Folders-first for `.name`/`.size`/`.modified`, both up and down (folders
    stay on top even descending).
  - `.name` ascending == today's behavior; descending reverses within the
    groups.
  - `.size` NUMERIC: items with sizes 9, 10, 100 ⇒ order 9,10,100
    ascending (not lexicographic 10,100,9).
  - `.modified` by timestamp up/down.
  - Name tiebreaker: two files of equal size ⇒ sorted by name (stable,
    deterministic).
  - missing size/missing date: deterministic position (document which).

- [x] **Step 2: Prove red.** `swift test --filter <Sort>` → FAIL.

- [x] **Step 3: Implementation.** `sortedForDisplay` gets `key`/
  `ascending`; group by `isDirectory` first, then sort within groups by the
  key with a name tiebreaker; `ascending == false` reverses the inner
  order, the grouping stays. Doc comment: folders-first is a deliberate
  grouping.

- [x] **Step 4: Failing tests for the VM state**
  (`RemoteBrowserViewModelTests`, mock FS):
  - Setting `sortKey`/`sortAscending` re-orders `items`.
  - Survives `refreshQuietly` (fresh list, same sort).
  - Survives `load` on a new directory (sort stays, unlike the search).
  - Together with an active M11k filter: the filtered list is sorted.

- [x] **Step 5: Prove red, then implement.** `sortKey`/
  `sortAscending` on the VM, `displayItems(from:)` threads them through,
  didSet re-derives, same as for search.

- [x] **Step 6: Green + full suite.** `swift test` → 826 + new ones.

- [x] **Step 7: Commit.** `feat: sort the file listing by name, size or date`

---

### Task 2: Column sorting in the table (App)

**Files:**
- Modify: `Sources/MacSCPApp/RemoteFileTableView.swift` (sortDescriptorPrototypes, `sortDescriptorsDidChange`, coordinator dispatch, check the indicator in `PolishedHeaderCell`)

**Interfaces:**
- Consumes: `FileSortKey` and the VM sort state from T1.

- [x] **Step 1: `sortDescriptorPrototype`s** on the three columns
  (`name`/`size`/`modified`), key matching the `FileSortKey`. The table's
  initial state mirrors the VM default (`.name` ascending), so the
  triangle initially sits on the name column (or is deliberately invisible,
  if that matches the M5g look — note this in the report).

- [x] **Step 2: `tableView(_:sortDescriptorsDidChange:)`** in the
  coordinator: derive the `FileSortKey` from the new active
  `NSSortDescriptor` (key + `ascending`) and set
  `viewModel.sortKey`/`sortAscending`. Default direction when switching to
  a DIFFERENT column: name/date ascending, size descending (largest
  first). The NEW `items` order flows back through the existing
  reload/reconcile mechanism — do NOT let AppKit sort the rows itself.

- [x] **Step 3: Indicator.** Check that the native sort triangle (▲/▼) is
  visible on the active column and that `PolishedHeaderCell` draws it
  through without shifting the M5g header look (small caps, kerning,
  hairline, 22 pt). If the custom header cell swallows the indicator,
  make a minimal fix (only the triangle, not the typography).

- [x] **Step 4: Verification.** `swift build` from a clean directory (no
  new warnings), full `swift test`. Check both panes independently (the
  state hangs off the respective ViewModel).

- [x] **Step 5: Commit.** `feat: sort the file list by clicking column headers`

---

### Task 3: Closeout verification (coordinator)

- [x] Gated suites: `MACSCP_ITEST=1 MACSCP_KEYCHAIN=1 swift test` → green, zero skips.
- [x] Visual smoke test — maintainer (checklist: clicking name/size/date
  sorts; clicking again reverses direction; folders stay on top in both
  directions; size numeric, not lexicographic; the triangle sits on the
  active column; sorting survives directory changes and auto-refresh;
  works together with the ⌘F filter; both panes independent; M5g header
  look unshifted).
- [x] Plan checkboxes, ledger, Opus final review, fix rounds until "Yes",
  push develop, `gh run watch`, memory. NO release.
