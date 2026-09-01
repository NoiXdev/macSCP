# M11j — Keyboard control in the file browser: implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Drive the file list from the keyboard (Finder-style), through the same actions and the same validity as the context menu.

**Architecture:** A pure, testable Core function maps `(key, selection, pane side)` to an action or "nothing" and shares its validity with `BrowserContextMenu.entries`. An `NSTableView` subclass intercepts the keys and routes permitted actions to exactly the closures double-click and the context menu already use.

**Tech Stack:** Swift 6 (`.swiftLanguageMode(.v5)`), AppKit, Swift Testing.

**Spec:** `docs/superpowers/specs/2026-07-30-m11j-browser-keyboard-design.md`

## Global Constraints

- Code and comments **English only**; display text via the catalogs.
- Keyboard and context menu share validity (`BrowserContextMenu.entries`) —
  no second validity path.
- Both panes identical; transfer direction comes from `side`.
- **⌘ keys run through `performKeyEquivalent`, modifier-less ones through
  `keyDown`** — do not mix these up.
- Plain ⌫ stays unassigned (no accidental delete); disallowed keys fall
  through to `super` (type-select is preserved).
- Read the selection BY VALUE at keypress time (no stale index).
- Collision check against existing app menu shortcuts; report a collision,
  do not silently reassign.
- Always verify `swift build` from a CLEAN build directory.
- Tests: Swift Testing, TDD. Baseline: **786 tests / 56 suites**.
- No release, no merge to `main`, no tag.

---

### Task 1: Pure key resolution (Core)

**Files:**
- Create: `Sources/macSCPCore/Presentation/BrowserKeyCommand.swift`
- Test: `Tests/macSCPCoreTests/BrowserKeyCommandTests.swift`

**Interfaces:**
- Consumes: `RemoteFileItem`, `BrowserPaneSide`, `BrowserContextMenu.entries(for:side:)`.
- Produces (T2 relies on this verbatim):
  - `public enum BrowserKey: Sendable { case returnKey, commandDown, commandO, commandUp, commandDelete, commandI, space, escape }`
  - `public enum BrowserKeyAction: Equatable, Sendable { case open(RemoteFileItem); case goUp; case rename(RemoteFileItem); case info(RemoteFileItem); case delete([RemoteFileItem]); case transfer([RemoteFileItem]); case clearSelection }`
  - `public enum BrowserKeyCommand { public static func resolve(key: BrowserKey, selection: [RemoteFileItem], side: BrowserPaneSide) -> BrowserKeyAction? }`

- [x] **Step 1: Failing tests** (`BrowserKeyCommandTests`):
  - `.returnKey` + single selection ⇒ `.rename(item)`; + multi-selection ⇒ `nil`; + empty selection ⇒ `nil`.
  - `.commandDown` and `.commandO` + single selection ⇒ `.open(item)`; + multi-selection ⇒ `nil`; + empty ⇒ `nil`.
  - `.commandUp` ⇒ `.goUp` (always, even with an empty selection).
  - `.commandDelete` + non-empty selection ⇒ `.delete(selection)`; + empty ⇒ `nil`.
  - `.commandI` + a single file ⇒ `.info(item)`; + a single SYMLINK ⇒ `nil`; + multi-selection ⇒ `nil`.
  - `.space` + a transferable selection (at least one non-symlink) ⇒ `.transfer(selection)`; + a selection of symlinks only ⇒ `nil` (the menu doesn't offer Transfer there either); + empty ⇒ `nil`. `side` affects ONLY the later direction, not the resolution here — both sides yield `.transfer`.
  - `.escape` ⇒ `.clearSelection` (always).

- [x] **Step 2: Prove red.** `swift test --filter BrowserKeyCommand` → FAIL.

- [x] **Step 3: Implementation.** `resolve` asks
  `BrowserContextMenu.entries(for: selection, side: side)` for the
  selection-dependent cases and only derives an action when the matching
  `BrowserMenuEntry` is present: `.rename` → `.rename`,
  `.infoAndPermissions` → `.info`, `.delete` → `.delete`,
  `.transferToOtherPane` → `.transfer`. `.open` applies for exactly ONE
  selected item (the focused row); `.goUp` and `.clearSelection` are always
  valid. Doc comment: why validity is shared via `entries` (menu and
  keyboard must never diverge).

- [x] **Step 4: Green.** `swift test --filter BrowserKeyCommand` → PASS, then full `swift test`.

- [x] **Step 5: Commit.** `feat: resolve browser keyboard commands against the menu model`

---

### Task 2: NSTableView subclass + dispatch (App)

**Files:**
- Modify: `Sources/MacSCPApp/RemoteFileTableView.swift` (subclass + coordinator dispatch + wiring), possibly `Sources/MacSCPApp/BrowserPane.swift` / `Sources/MacSCPApp/ContentView.swift` (goUp/transfer closure, if not already present)

**Interfaces:**
- Consumes: `BrowserKey`/`BrowserKeyAction`/`BrowserKeyCommand.resolve` (T1); the existing closures `onOpen`, `onOpenFile`, `onOpenSymlink` (M11h), `onMenuAction`, `onSelect`; `viewModel.goUp()`.

- [x] **Step 1: `NSTableView` subclass** (private in
  `RemoteFileTableView.swift`) with a weak reference to the coordinator.
  `makeNSView` instantiates this subclass instead of `NSTableView()`.

- [x] **Step 2: `performKeyEquivalent(_:)`** for the ⌘ keys
  (⌘↓/⌘O/⌘↑/⌘⌫/⌘I). Map modifiers and `charactersIgnoringModifiers` /
  `keyCode` (arrows ⌘↓/⌘↑ via `keyCode` 125/126) onto `BrowserKey`, call
  `BrowserKeyCommand.resolve` with the current selection (BY VALUE),
  dispatch on an action and return `true`; otherwise `super`/`false`.

- [x] **Step 3: `keyDown(_:)`** for Return / space / Esc. Same resolution;
  unhandled keys go to `super` (type-select is preserved).

- [x] **Step 4: Dispatch.** A coordinator method
  `perform(_ action: BrowserKeyAction)`:
  - `.open(item)` → **exactly the same path as `doubleClicked`** (folder →
    `onOpen`, file → `onOpenFile`, symlink → `onOpenSymlink`, `.other`
    no-op) — do not duplicate, reuse/share the existing branching.
  - `.goUp` → `viewModel.goUp()` (or the closure that already exists for
    it).
  - `.rename(item)` → `onMenuAction(.rename, [item])`.
  - `.info(item)` → `onMenuAction(.infoAndPermissions, [item])`.
  - `.delete(sel)` → `onMenuAction(.delete, sel)`.
  - `.transfer(sel)` → `onMenuAction(.transferToOtherPane, sel)` (the
    direction already follows from the pane there).
  - `.clearSelection` → `onSelect([])` and clear the table selection.

- [x] **Step 5: Collision check.** Verify that ⌘↓/⌘↑/⌘O/⌘I/⌘⌫ collide with
  no app menu shortcut (⌘N/W/1–9, ⌘⇧., ⌘⇧K/L/I, ⌘T, ⌘,). Record it in the
  report. (⌘A/select-all and arrows remain native.)

- [x] **Step 6: Verification.** `swift build` from a clean directory (no
  new warnings; four pre-existing expected), full `swift test`.

- [x] **Step 7: Commit.** `feat: drive the file browser from the keyboard`

---

### Task 3: Final verification (coordinator)

- [x] Gated suites: `MACSCP_ITEST=1 MACSCP_KEYCHAIN=1 swift test` → green, zero skips.
- [x] Visual smoke test — maintainer (checklist: Return renames; ⌘↓/⌘O
  opens folder/file/follows symlink; ⌘↑ goes up; ⌘⌫ deletes with
  confirmation; ⌘I info, not for a symlink; space transfers in the correct
  direction per pane; ⌘A selects all, Esc clears; plain ⌫ does nothing;
  disallowed keys with the wrong selection do nothing; type-select by
  typing is preserved; both panes).
- [x] Plan checkboxes, ledger, Opus final review, fix rounds until "Yes",
  push to develop, `gh run watch`, memory. NO release.
