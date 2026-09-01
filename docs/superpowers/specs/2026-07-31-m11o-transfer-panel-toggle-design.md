# M11o — Transfer bar show/hide design

**Status:** approved (brainstorming 2026-07-31)
**Milestone:** M11o
**Language:** design doc EN; code/comments/strings EN (app UI localized EN+DE)

## Goal

The transfer bar (active + completed transfers) should be shown/hidden via
a toolbar icon **next to the terminal icon** — plus a menu item and a
keyboard shortcut. Today the bar only shows/hides itself automatically
(on `items.isEmpty`); there is no manual switch.

Maintainer decisions from the brainstorming:
- **Behavior:** auto-show stays; the icon can additionally open the bar
  **even when empty** (empty state "No transfers"), to review/clean up
  completed ones. The icon always has a visible effect.
- **Auto-show:** **every** newly enqueued transfer re-expands the bar
  (even after it was manually collapsed).
- **Controls:** toolbar icon **+** menu item **+** keyboard shortcut.
- **Icon:** `tray.full`. **Shortcut:** ⌘⇧Y. **Menu location:** with the
  view toggles (same group as "Show/Hide Hidden Files").
- The new shortcut is to be added later to the planned **keyboard-shortcut
  overview in settings** (its own milestone); that overview is **not**
  part of M11o.

## Context / current state

- **`TransferQueueBar`** (`Sources/MacSCPApp/TransferQueueBar.swift`): shows
  active + completed transfers. Rendered in `ContentView` as the last
  element of the per-tab `VStack(spacing: 0)` (at the bottom of the
  window, full width). **Current visibility condition:** `if
  viewModel.items.isEmpty { EmptyView() }` — pure auto-hide, no bool.
  `items` contains active **and** completed entries; "clean up"
  (`clearCompleted()`) empties them.
- **Terminal toggle (model):**
  - Toolbar icon in `ContentView`'s native `.toolbar`,
    `ToolbarItemGroup(placement: .primaryAction)` — children: Upload →
    Download → **terminal button** → disconnect. The group renders
    **only with an active session** (`if let session = activeTab.session`).
    SF Symbol `"terminal"`,
    `.keyboardShortcut("t", modifiers: .command)`, help text.
  - Menu item in `MacSCPApp` `.commands`, `CommandMenu("Terminal")`,
    `tabCommands.toggleTerminal?()`, disabled unless
    `tabCommands.isActiveTabConnected`.
  - **State:** `session.terminal.isVisible` (`var` on
    `TerminalPanelViewModel`), **per tab**, **not persisted**.
- **View-toggle menu group:** `CommandGroup(after: .sidebar)` in
  `MacSCPApp` contains "Show/Hide Hidden Files" ⌘⇧. — the new entry goes
  here.
- **`TabCommands`** (app-wide menu bridge): `MacSCPApp` builds the menus
  without a `ContentView` reference; `ContentView` sets the closures in
  `.task` and mirrors state (`isActiveTabConnected`) via `.onChange`.
  Model for a new `toggleTransfers` closure + mirrored active state.
- **`SessionTab`** (`@Observable`): holds `session`, `transferQueue:
  TransferQueueViewModel` (per tab). Natural place for the new visibility
  bool.
- **L10n:** `L10n.string(key, "English default")`; catalogs
  `Sources/MacSCPApp/Resources/{en,de}.lproj/Localizable.strings`,
  typographic quotation marks/`…`, no ASCII `"` in DE values. Model:
  `"browser.terminalToggle"`, `"browser.terminalToggleHelp"`,
  `"menu.terminal.toggle"`.

## Architecture

Pure app layer; no Core change.

### State (per tab, not persisted)

- New `var transfersPanelVisible = false` on `SessionTab` — mirrors the
  pattern of `TerminalPanelViewModel.isVisible` (per tab, in-memory, no
  `SettingsStore` key).

### Visibility of the bar

- `TransferQueueBar` is rendered when `activeTab.transfersPanelVisible ==
  true` — **independent** of content. The previous
  `items.isEmpty` self-hiding no longer stands alone as the condition.
- Visible **and** empty ⇒ empty state: a slim row "No transfers" (same
  header height/look as otherwise, just without a list).
- The toggle site in `ContentView` (last `VStack` element) stays; only the
  condition changes from "not empty" to "bool visible."

### Auto-show

- `ContentView` observes `activeTab.transferQueue.items.count` via
  `.onChange`; if the value **increases** (a new transfer enqueued), it
  sets `activeTab.transfersPanelVisible = true`. This reproduces today's
  "appears as soon as something is transferring" and covers "every new
  transfer re-expands it."
- Only the active tab is observed this way (the bar shows the active tab
  anyway). Cross-tab destination transfers (M8b) into a background tab do
  not re-expand that tab's bar — deliberately outside v1.

### Toggle

- The toolbar icon and the menu item call the same action: `activeTab
  .transfersPanelVisible.toggle()`.

## UI

### Toolbar icon

- New `Button`/`Label` in the same `ToolbarItemGroup(.primaryAction)`,
  **directly next to the terminal button** (connection-gated, so it only
  appears with an active session).
- SF Symbol **`tray.full`**. Shows the on/off state (highlighted active
  when `activeTab.transfersPanelVisible`), analogous to the terminal
  button.
- `.keyboardShortcut("y", modifiers: [.command, .shift])`.
- Help text (localized): "Show/hide transfers (⌘⇧Y)".

### Menu item

- In `MacSCPApp` `.commands`, `CommandGroup(after: .sidebar)` (next to
  "Show/Hide Hidden Files"): "Show/Hide Transfers",
  `tabCommands.toggleTransfers?()`,
  `.keyboardShortcut("y", modifiers: [.command, .shift])`, disabled unless
  `tabCommands.isActiveTabConnected`.
- `TabCommands` gains `var toggleTransfers: (() -> Void)?`; `ContentView`
  sets it in `.task` to `{ activeTab.transfersPanelVisible.toggle() }`.

### Localization (new keys, EN + DE)

- `"browser.transfersToggle"` = "Transfers" / "Übertragungen"
- `"browser.transfersToggleHelp"` = "Show/hide transfers (⌘⇧Y)" /
  "Übertragungen ein-/ausblenden (⌘⇧Y)"
- `"menu.transfers.toggle"` = "Show/Hide Transfers" / "Übertragungen
  ein-/ausblenden"
- `"transfers.empty"` = "No transfers" / "Keine Übertragungen"

## Edge cases

- **Not connected:** the toolbar group is absent → no icon; the menu item
  is disabled (like terminal). Per-tab state is moot.
- **Tab switch:** each tab has its own `transfersPanelVisible`; switching
  shows the state of that particular tab.
- **"Clean up" while the bar is visible:** the list becomes empty, the
  bar stays visible in its empty state until manually collapsed.
- **Collapsed + new transfer:** it re-expands (auto-show).
- **Teardown/disconnect:** the tab is torn down, the state goes with it.

## Tests

- Pure app-layer wiring with no Core logic ⇒ like all app-only milestones,
  **no** app test target. Verification:
  - `swift build` clean (no new warnings).
  - EN/DE catalog parity + `plutil -lint` OK; `LocalizableStringsTests` green.
  - Full `swift test` unchanged and green (no new/changed Core logic).
  - Read/trace the wiring (toolbar button, menu item+shortcut,
    `TabCommands` closure, `.onChange` auto-show, visibility condition
    + empty state).
- **Runtime smoke test (fixed habit since the M11n incident):** launch
  the dev build and check idle CPU (must be ~0%) before shipping it —
  catches SwiftUI layout storms that reviews/CI don't see.

## Files

- Modify: `Sources/MacSCPApp/SessionTab.swift` (`transfersPanelVisible`).
- Modify: `Sources/MacSCPApp/TransferQueueBar.swift` (empty state instead
  of `EmptyView` for an empty list — visibility itself is now controlled
  by `ContentView`).
- Modify: `Sources/MacSCPApp/ContentView.swift` (visibility condition,
  `.onChange` auto-show, toolbar button, `toggleTransfers` closure in
  `.task`).
- Modify: `Sources/MacSCPApp/MacSCPApp.swift` (menu item + shortcut).
- Modify: `Sources/macSCPCore/…`? **No** — `TabCommands` lives in the
  app layer (`MacSCPApp.swift`); `toggleTransfers` is added there.
- Modify: `Sources/MacSCPApp/Resources/{en,de}.lproj/Localizable.strings`.

## Global Constraints

- Swift 6, `.swiftLanguageMode(.v5)`, min. macOS 15; Swift Testing, TDD
  where logic is created (here: no new Core logic).
- Code/comments/`reason:` strings EN; UI strings via the `.strings`
  catalogs EN default + DE, typographic quotation marks; no ASCII `"` in
  DE values.
- Visibility is **per tab** (no app-wide singleton), mirroring the
  terminal `isVisible` pattern; not persisted.
- **AppKit/SwiftUI menu-bar lesson (M11n):** no new `MenuBarExtra`; this
  feature does not touch it. Check runtime idle CPU before shipping.
- No release/tag without explicit maintainer instruction.
