# Sidebar Polish Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A compact sidebar mode as a setting, "Move to…" on a folder
and on a session, and a measured record of what the sidebar's drag and
drop can and cannot do today — the maintainer's items 3–6 of the
dictated notes (2026-09-02), re-raised 2026-09-04.

**Architecture:** Measured at HEAD 06baa7c4 before writing this plan:
session rows are `.draggable(dragPayload())` with `dropDestination`s
that call `viewModel.move(_:before:)` (reorder) and
`move(_:intoGroup:)` (between groups) — `SessionSidebar.swift:768-804,
1144-1145`; a drop on the sidebar's own title sends a row to the root
(`:390-396`, `drop(payload, intoGroup: nil)`). So drag & drop for
sessions and folder-to-root EXIST; the dictated items 3 and 4 describe
a gap this tree no longer has, or one the dev build will show — Task 1
measures rather than assumes. What is missing: a compact row mode
(`SettingsStore` has `sidebarWidth` and `sidebarTagFilterEnabled`, no
density), and a "Move to…" entry (the context menus at
`SessionSidebar.swift:447, 836, 1148, 1387` carry sort/dissolve/… but
no move-by-menu).

**Tech Stack:** Swift 6 strict, SwiftUI (macOS 15), Swift Testing,
`SettingsStore`, `SessionListViewModel.move(_:intoGroup:)`, the four
catalogs.

**Spec:** `docs/BACKLOG.md`, row "Sidebar: compact mode, drag & drop,
folder to root"; `docs/superpowers/specs/2026-09-02-backlog-maintainer-notes.md`
items 3–6.

## Global Constraints

- English only in the tree; user-facing strings only via `L10n.string` in all four catalogs (`en`, `de`, `fr`, `pl`; German du); Conventional Commits; footer exactly `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`; commit per task; zero warnings; do not push.
- No new way to move a session or group: "Move to…" calls the same `move(_:intoGroup:)` the drop calls, and refusals (`MoveRefusal`) surface through the same caption the drop uses.
- The compact mode changes row height, padding and the host subtitle's visibility only; it changes no ordering, no selection behaviour, no keyboard handling (`SessionRowActivation` untouched).
- Red first; no `#require` on a non-optional; no wall-clock ceiling; tests never block the pool; every existing sidebar guard (`SessionSidebarErrorGuardTests`, `SessionRowActivationWiringTests`, `HiddenImportsErrorDismissGuardTests`, the settings toggle guard) stays green; a negative check needs a positive beside it; comments quoting code near an anchor move the anchor; a number in a comment is counted.
- Do NOT launch the GUI; the dev build is the maintainer's sight check.

---

### Task 1: Measure the drag and drop, and write it down

**Files:**
- Test: `Tests/macSCPCoreTests/SessionListViewModelTests.swift` (or the sidebar ordering tests — find `move(_:before:)`'s tests): cases that pin what the tree does at HEAD — a session moved between two groups keeps its position rule; a session reordered before another in the same group; a group moved to the root (`intoGroup: nil`); a group dropped into its own descendant refused with the `MoveRefusal` the tree names; a session dropped onto itself is a no-op. Where a case already exists, name it in the report instead of duplicating.
- Modify: `docs/BACKLOG.md` (the row: what exists, with the test names; what Task 2/3 add)

- [x] **Step 1:** read `SidebarOrdering` (find the file: `grep -rn "enum MoveRefusal" Sources`) and `SessionListViewModel.move(_:before:)` / `move(_:intoGroup:)`; list every refusal and the drop targets in the view (`SessionSidebar.swift` `dropDestination` sites — count them).
- [x] **Step 2:** add the missing cases red-first where the behaviour is unpinned (say which were already pinned).
- [x] **Step 3: Commit** `test(sidebar): the drag-and-drop rules are pinned — reorder, between groups, to the root, refusals` (`6be9d8bc`).

---

### Task 2: Compact mode

**Files:**
- Modify: `Sources/macSCPCore/Settings/SettingsStore.swift` (`sidebarCompact: Bool`, default false, beside `sidebarTagFilterEnabled`; the key constant in `Keys`)
- Modify: `Sources/MacSCPAppKit/SettingsView.swift` (a toggle in the Appearance pane: `settings.appearance.sidebarCompact` = "Compact sidebar")
- Modify: `Sources/MacSCPAppKit/SessionSidebar.swift` (the row builder reads the setting: compact → single-line row, the host subtitle hidden, vertical padding 2 instead of 6, the kind badge kept; a group header the same one line; `@AppStorage` or the store's published value, whichever the sidebar already uses for `sidebarTagFilterEnabled`)
- Modify: the four catalogs
- Test: `Tests/macSCPCoreTests/SettingsStoreTests.swift` (round trip, default), `Tests/MacSCPAppKitTests/SettingsViewTransfersToggleGuardTests.swift`-shaped guard for the new toggle (the toggle is bound to the store's property and labelled through the catalogue key — copy that guard's shape into `SettingsViewAppearanceToggleGuardTests` or extend it), and a sidebar guard: the row builder reads `sidebarCompact` and the host subtitle is inside the non-compact branch (positive anchor + negative).

- [x] **Step 1: Red first** — the store test (`sidebarCompact` missing), the guard.
- [x] **Step 2: Implement**; `swift test` green; zero warnings.
- [x] **Step 3: Commit** `feat(sidebar): a compact mode, as a setting` (`dc9ce11c`, fix rounds `0ce0ca69`/`fbd31774`/`30b61e70`).

---

### Task 3: "Move to…"

**Files:**
- Modify: `Sources/MacSCPAppKit/SessionSidebar.swift` (a "Move to…" submenu in the session row's context menu and the group's: the root plus every group except the item itself and, for a group, its descendants; each entry calls `viewModel.move(item, intoGroup:)`; a refusal shows through the existing caption)
- Modify: the four catalogs (`sidebar.moveTo` = "Move to…", `sidebar.moveTo.root` = "Top level")
- Test: a sidebar wiring guard (the submenu's entries call `move(`, the root entry passes `nil`, the item's own group is excluded — derive the exclusion rule in a small Core function `SidebarOrdering.moveTargets(for:in:)` tested directly: a group excludes itself and its descendants; a session excludes its current group)

- [x] **Step 1: Red first** — `moveTargets` missing; the guard red.
- [x] **Step 2: Implement**; green; zero warnings.
- [x] **Step 3: Commit** `feat(sidebar): "Move to…" moves a folder without dragging, and both submenus share one target rule` (the coordinator's wording for what actually shipped: sessions already had this submenu per Task 1's measurement — the group submenu, and the shared `SidebarOrdering.moveTargets`, are what Task 3 added).
- [x] **Step 4:** `docs/BACKLOG.md` row → Done with the three commits and what the dev build should show.
