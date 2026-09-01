# M11n — Menu Bar Status (NSStatusItem/MenuBarExtra) Design

**Status:** approved (brainstorming 2026-07-31)
**Milestone:** M11n
**Language:** design doc EN; code/comments/strings EN (app UI localized EN+DE)

## Goal

An app-wide menu bar icon that shows the status of active SSH connections and
running transfers outside the main window. A click opens a panel; clicking a
connection brings the main window forward and activates its tab.

Maintainer decisions from the brainstorming session:
- **Interactivity:** display **+ bring window forward** (no cancel/delete
  from the panel in v1).
- **Visibility:** always visible, with a **hide toggle** in settings (default
  on). The icon subtly signals a running transfer.
- **Transfer display:** **grouped per connection**, one compact summary line
  per tab (not every file individually).
- **Technology:** SwiftUI `MenuBarExtra` in panel style (`.window`), no
  AppKit app delegate.

## Context / current state

- Single `WindowGroup`, multiple tabs (multi-window is v2). All
  connection/queue state lives **per tab**, aggregated only in
  `ContentView`'s `@State tabsModel: TabsViewModel<SessionTab>`
  (`ContentView.swift`). There is **no** app-wide registry — project rule
  (CLAUDE.md): session state belongs in the window scope, no app-wide
  singleton.
- No `NSStatusItem`/`MenuBarExtra` exists — greenfield.
- Precedent for "an app-wide Observable fed from tab state":
  `TabCommands` (`MacSCPApp.swift`) — `MacSCPApp` builds menus but holds no
  `ContentView` reference; `ContentView` sets closures in `.task` and mirrors
  state via `.onChange`. `UpdateCheckModel` is the precedent for a
  deliberately app-global `@Observable`.
- Per-tab data (all `@Observable`): `SessionTab.displayTitle`/`isConnected`,
  `SessionTab.connectionViewModel.state` (`ConnectionViewModel.State`:
  `.idle`/`.connecting`/`.failed`; "connected" = `isConnected`),
  `SessionTab.transferQueue: TransferQueueViewModel`.
- `TransferQueueViewModel` (Core, `@Observable`): `items: [Item]`, `isActive`,
  `pendingCount`, `displayDirection: TransferDirection?`. Per-item progress
  in `Item.Status.running(TransferProgress)`; `TransferProgress` has
  `bytesTransferred: UInt64`, `totalBytes: UInt64?`, `bytesPerSecond: Double?`,
  `etaSeconds: Double?`, `fraction: Double?`. **No** app-wide or
  queue-wide total exists — it has to be newly derived.
- L10n: `.strings` files (not `.xcstrings`) under
  `Sources/MacSCPApp/Resources/{en,de}.lproj/Localizable.strings`; lookup via
  `L10n.string(key, "English default")` / `L10n.text(...)`. Typographic
  quotation marks `„ "` / `…` in strings; one ASCII `"` in a German line
  invalidates the whole DE catalogue.
- Settings: `SettingsStore` (Core, `@Observable`, JSON, forward-compatible).
  Bool pattern: key in `Keys`, default in `Defaults`, computed `var` over
  `boolValue(for:default:)`/`setBool(_:for:)` (e.g. `updateCheckEnabled`).

## Architecture

Split by testability: the **aggregation logic** (condensing a tab's items
into a compact summary) lives in **Core** and is covered there by unit
tests; the app layer only renders and keeps the bridge current.

### Core (new, tested)

**`TransferActivitySummary`** — `Sendable` value type:
- `runningCount: Int` — number of running items.
- `pendingCount: Int` — number of waiting (queued, not yet running) items.
- `fraction: Double?` — byte-weighted overall progress over **running**
  items with known `totalBytes` only (Σ `bytesTransferred` / Σ `totalBytes`);
  `nil` if no running item knows a total size.
- `bytesPerSecond: Double?` — sum of `bytesPerSecond` over running items
  that report a rate; `nil` if none report one.
- `direction: TransferDirection?` — from the queue's `displayDirection`.

**`TransferQueueViewModel.activitySummary: TransferActivitySummary?`** —
computed:
- `nil` when `!isActive` (neither running nor waiting).
- otherwise folded from `items` per the rules above.

### App (bridge + rendering)

**`MenuBarStatusModel`** (`@MainActor @Observable`, app-wide, `@State` in
`MacSCPApp`):
- `var tabsSnapshot: [SessionTab]` — kept in sync by `ContentView`.
- `var focusTab: (UUID) -> Void` — set by `ContentView` in `.task`.
- `var showMainWindow: () -> Void` — bring the window forward without
  forcing a tab (footer button).
- derived: `var anyTransferActive: Bool` = `tabsSnapshot.contains {
  $0.transferQueue.activitySummary?.runningCount ?? 0 > 0 }` (for the icon).

**Live updates without an extra timer:** the panel and icon are SwiftUI
views that read `tab.displayTitle`, `tab.connectionViewModel.state`,
`tab.isConnected`, `tab.transferQueue.activitySummary` **directly**. Since
all of these are `@Observable`, SwiftUI observation updates the panel and
icon live during a transfer. The bridge only needs to catch up when a tab
is added/removed/reordered (`.onChange` on `tabsModel.tabs`), not on every
progress tick.

**`MacSCPApp`** gets a second scene alongside `WindowGroup`:
```
MenuBarExtra(isInserted: $settingsStore.menuBarEnabled) {
    MenuBarStatusPanel(model: menuBarModel)  // .menuBarExtraStyle(.window)
} label: {
    MenuBarStatusLabel(model: menuBarModel)
}
```
`isInserted` bound to `settingsStore.menuBarEnabled` → show/hide without a
restart.

**`ContentView`** (existing, extended):
- in `.task`: `menuBarModel.focusTab = { id in … }`,
  `menuBarModel.showMainWindow = { … }`.
- via `.onChange(of: tabsModel.tabs)`: `menuBarModel.tabsSnapshot = tabsModel.tabs`
  (also set once initially in `.task`).

**`focusTab(id)`:** `NSApplication.shared.activate(ignoringOtherApps: true)`;
main window `makeKeyAndOrderFront(nil)`; `tabsModel.activate(id)`.
**`showMainWindow()`:** identical, without the `activate(id)` step.

## UI

### Menu bar icon (`MenuBarStatusLabel`)

An SF Symbol with two states, driven by `model.anyTransferActive`:
- **Idle:** `arrow.up.arrow.down` (normal tint).
- **Active:** `arrow.up.arrow.down.circle.fill` (app tint). No jitter/no
  animation — just a calm state change.

### Panel (`MenuBarStatusPanel`, `.window` style, design tokens)

- **Header:** title „macSCP", with the count of open connections shown
  discreetly on the right (`tabsSnapshot.filter(\.isConnected).count`).
- **Connection list**, one row/card per tab in `tabsSnapshot` order:
  - Row 1: `displayTitle` + status indicator:
    - **connected** (`isConnected`) — green dot.
    - **connecting…** (`state == .connecting`) — yellow/spinner.
    - **failed** (`state == .failed`) — red dot.
    - otherwise (`.idle`, not connected) — neutral dot ("ready"/empty).
  - Row 2 (only when `activitySummary != nil`): direction arrow (↑/↓ from
    `direction`) + compact: `runningCount>0` → „n überträgt · [x % ·] Rate"
    (percent omitted when `fraction == nil`), rate/ETA via
    `TransferRateFormatting.compactLabel(...)`; waiting only → „n in
    Warteschlange".
  - entire row clickable → `model.focusTab(tab.id)`; hover highlight.
- **Empty state:** no tabs/connections → a calm row „Keine aktiven
  Verbindungen".
- **Footer:** button „macSCP anzeigen" → `model.showMainWindow()`.
  Deliberately **no** quit action (the app menu remains the place for that).

### Localization

New strings EN + DE, typographic quotation marks/`…`:
- Status labels: connected / connecting… / failed / ready.
- Transfer: „%d überträgt", „%d in Warteschlange", header counter
  („%d Verbindungen").
- Empty state „Keine aktiven Verbindungen".
- Footer button „macSCP anzeigen".
- Settings toggle „Menüleisten-Symbol anzeigen".

### Setting

`SettingsStore.menuBarEnabled: Bool` (default **true**), following the
existing Bool pattern (`Keys`/`Defaults`/computed `var` over
`boolValue`/`setBool`). In `SettingsView` ▸ General a toggle „Menüleisten-
Symbol anzeigen". The `SettingsStore` is already passed through to both
`ContentView` and the `Settings` scene; `MacSCPApp` reads it for the
`isInserted` binding.

## Edge cases

- **No tab / no connection:** panel empty state; icon stays idle
  (default on).
- **Tab closes while panel is open:** `tabsSnapshot` catches up via
  `.onChange`; the row disappears, no crash.
- **`.connecting`/`.failed`:** status label mirrors `state`; no transfer
  row for unconnected tabs.
- **Window minimized/hidden on click:** `activate` + `makeKeyAndOrderFront`
  brings it forward, then switches tab.
- **Interrupted transfers:** in v1 **not** separately marked in the panel —
  the existing resume bar in the window remains the place for that (YAGNI).

## Tests

- **Core (new, red→green):** `TransferQueueViewModel.activitySummary` with
  seeded items:
  - empty / `!isActive` ⇒ `nil`.
  - one running item with known `totalBytes` ⇒ `runningCount==1`, `fraction`
    == its `fraction`, `bytesPerSecond` == its rate.
  - several running items, all with a total ⇒ byte-weighted `fraction`
    (Σ/Σ), summed `bytesPerSecond`.
  - running item without `totalBytes` ⇒ `fraction == nil`, `runningCount`
    still counts it.
  - running item without a rate ⇒ the rate only counts the ones reporting;
    none reporting ⇒ `nil`.
  - waiting items only ⇒ `runningCount==0`, `pendingCount>0`, `fraction==nil`.
  - `direction` == `displayDirection`.
- **App:** as with all app-only milestones, **no** app test target — the
  bridge synchronization (`ContentView` → `menuBarModel`), the
  `isInserted` binding, and the `focusTab`/`showMainWindow` wiring are
  evidenced by build + read + trace. The risky logic lives in Core and is
  tested there.

## Files

- New Core: `Sources/macSCPCore/Presentation/TransferActivitySummary.swift`
  (or added into `TransferQueueViewModel.swift` — the computed `var`
  belongs there anyway; the struct gets its own small file).
- Change Core: `Sources/macSCPCore/Presentation/TransferQueueViewModel.swift`
  (`activitySummary`), `Sources/macSCPCore/Settings/SettingsStore.swift`
  (`menuBarEnabled`).
- New App: `Sources/MacSCPApp/MenuBarStatusModel.swift`,
  `Sources/MacSCPApp/MenuBarStatusPanel.swift` (panel + label + row views).
- Change App: `Sources/MacSCPApp/MacSCPApp.swift` (`MenuBarExtra` scene +
  `@State menuBarModel`), `Sources/MacSCPApp/ContentView.swift` (feed the
  bridge), `Sources/MacSCPApp/SettingsView.swift` (toggle),
  `Sources/MacSCPApp/Resources/{en,de}.lproj/Localizable.strings`.
- New tests: `Tests/macSCPCoreTests/TransferActivitySummaryTests.swift`.

## Global Constraints

- Swift 6, `.swiftLanguageMode(.v5)`, min. macOS 15; Swift Testing, TDD
  red→green.
- Code/comments/`reason:` strings EN; UI strings via the `.strings`
  catalogues EN default + DE, typographic quotation marks; no ASCII `"` in
  DE values.
- No app-wide singletons for session state: the menu bar entry holds
  **no** connection state of its own, only mirrors `tabsModel.tabs` via
  the `TabCommands`-like bridge.
- No release/tag without explicit maintainer direction.
