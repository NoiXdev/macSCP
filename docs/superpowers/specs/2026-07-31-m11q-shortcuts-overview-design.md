# M11q — Keyboard Shortcuts Overview Design

**Status:** approved (brainstorming 2026-07-31)
**Milestone:** M11q
**Language:** design doc EN; code/comments EN; UI localized EN/DE/FR/PL

## Goal

A **read-only** overview of all keyboard shortcuts in its own
settings tab "Shortcuts". The user sees, grouped, which key
triggers which action.

Maintainer decision from the brainstorming session:
- **Scope:** **overview only** (read-only). Rebinding stays its own,
  later milestone — it would need a new central keybinding model and
  a rework of all six definition sites (SwiftUI `.keyboardShortcut`,
  AppKit keyCodes, sheet default actions), conflict detection, and persistence.

## Context / current state

The shortcuts are scattered across **six sites**; there is **no** central
registry (inventory taken 2026-07-31):
1. **SwiftUI menu shortcuts** in `MacSCPApp.swift` `.commands`: ⌘N (New Tab),
   ⌘W (Close Tab), ⌘1–9 (Select Tab), ⌘⇧. (hidden files),
   ⌘⇧Y (Transfers), ⌘⇧K (Known Hosts), ⌘⇧L (Logins), ⌘⇧I (hidden
   imports). ⌘, (Preferences) is the SwiftUI framework default (no explicit
   registration).
2. **Toolbar** in `ContentView.swift`: ⌘T (terminal toggle button).
3. **AppKit `KeyboardDrivenTableView`** in `RemoteFileTableView.swift`
   (hardcoded keyCodes, M11j): ⌘↑ (go up), ⌘↓/⌘O (open), ⌘I (info &
   permissions), ⌘⌫ (delete), ␣ (transfer), ⏎ (rename), ⎋ (clear selection),
   ⌘F (search). Resolved via `BrowserKeyCommand.resolve` (Core), eligibility per
   selection via `BrowserContextMenu.entries`.
4. **`BrowserKeyCommand`** (Core) — only a resolver for the table keys,
   no enumerable table; does NOT cover menu/toolbar/sheets.
5. **Search/path bar** (M11k/M11i): ⌘F wiring, search Esc/Return,
   path completion (⇥/⇧⇥/⎋/⏎).
6. **Sheet default actions**: `.keyboardShortcut(.defaultAction)` (⏎ =
   confirm) on many sheets; Esc/⎋ via `role: .cancel`.

**Consequence:** An overview **cannot** be derived from an existing
source — it is a **hand-maintained table** that mirrors these sites.

**Settings structure:** `SettingsView.swift` — `TabView` (General/Transfers/
Open with/Terminal), fixed size `460×460`. New tabs slot in identically
(`.tabItem { Label(L10n.string(...), systemImage: ...) }`). L10n via
`L10n.string(key, "English default")`.

## Architecture

Purely app layer (labels go through `L10n`, which lives in the app layer).

### Catalog model (static, hand-maintained)

- New `Sources/MacSCPApp/KeyboardShortcutsCatalog.swift`:
  ```swift
  /// Read-only overview of the app's keyboard shortcuts (M11q). This is a
  /// HAND-MAINTAINED mirror — there is no central shortcut registry; the
  /// real bindings live across six sites: SwiftUI `.keyboardShortcut` in
  /// `MacSCPApp.swift` menus, the ⌘T toolbar button in `ContentView.swift`,
  /// the hardcoded keyCodes in `KeyboardDrivenTableView`
  /// (`RemoteFileTableView.swift`) resolved via `BrowserKeyCommand`, the
  /// ⌘F / search-Esc wiring, the path-bar completion keys (`PathBar.swift`),
  /// and sheet `.defaultAction`/`.cancel` roles. WHEN A SHORTCUT CHANGES AT
  /// ANY OF THOSE SITES, UPDATE THIS CATALOG TOO.
  enum KeyboardShortcutsCatalog {
      struct Row: Identifiable {
          let id = UUID()           // stable per build; only for ForEach
          let labelKey: String      // L10n key
          let labelDefault: String  // English fallback
          let shortcut: String      // display glyphs, e.g. "⌘⇧Y", "⌘↑", "␣"
      }
      struct Group: Identifiable {
          let id = UUID()
          let titleKey: String
          let titleDefault: String
          let rows: [Row]
      }
      static let groups: [Group] = [ … ]  // see content below
  }
  ```

### Content (groups → rows)

- **Tabs & Windows** (`settings.shortcuts.group.tabs`): ⌘N New Tab,
  ⌘W Close Tab, ⌘1–9 Select Tab, ⌘, Preferences.
- **View** (`settings.shortcuts.group.view`): ⌘⇧. Hidden Files,
  ⌘⇧Y Transfers, ⌘T Terminal.
- **Sessions** (`settings.shortcuts.group.sessions`): ⌘⇧K Known Hosts,
  ⌘⇧L Logins, ⌘⇧I Hidden Imports.
- **File Browser** (`settings.shortcuts.group.browser`): ⌘↑ Go Up,
  ⌘↓ / ⌘O Open, ⌘I Info & Permissions, ⌘⌫ Delete, ␣ Transfer,
  ⏎ Rename, ⎋ Clear Selection, ⌘F Search.
- **Path Bar** (`settings.shortcuts.group.pathbar`): ⇥ Complete,
  ⇧⇥ Cycle Backward, ⎋ Cancel, ⏎ Navigate.
- **Dialogs** (`settings.shortcuts.group.sheets`): ⏎ Confirm, ⎋ Cancel.

**Shortcut display strings** (`shortcut`) are fixed and **not localized**
(⌘⇧Y is universal). For compound cases like "⌘↓ / ⌘O" a single
string. Symbols: ⌘ ⇧ ⌥ ⌃, arrows ↑ ↓, ⌫ (Delete), ␣ (Space), ⏎ (Return),
⎋ (Esc), ⇥/⇧⇥ (Tab/Shift-Tab).

**Labels:** via `L10n`, **using dedicated `settings.shortcuts.label.*`
keys throughout** (not reusing the menu keys — this decouples the overview
from the menu wording and keeps it self-describing). The plan enumerates the
concrete key list; all new keys go into all four catalogs.

### UI

- New `Sources/MacSCPApp/SettingsView.swift` → `ShortcutsSettingsTab` (private,
  the same pattern as the other tabs): a `Form { … }` with one `Section` per
  `KeyboardShortcutsCatalog.Group` (header = localized group title), each
  row an `HStack { Text(label); Spacer(); Text(shortcut) }` — the
  shortcut string in `.monospaced()`/`.foregroundStyle(.secondary)`,
  right-aligned. Read-only, no interaction.
- In `SettingsView.body`'s `TabView` as the fifth tab "Shortcuts"
  (`.tabItem { Label(L10n.string("settings.tab.shortcuts", "Shortcuts"),
  systemImage: "keyboard") }`). The `Form` scrolls within the fixed
  `460×460` window; if the list gets uncomfortably tight, raise the window
  height moderately (the plan checks this visually).

## Edge cases / deliberate non-goals

- **Context-dependent double assignment is correct** and is not "de-duplicated":
  ⏎ = rename (table) vs. confirm (dialog); ⎋ = clear selection vs.
  cancel. The overview lists them separately per group.
- **No rebinding**, no conflict detection, no persistence — a later
  milestone.
- **Enabled/disabled per selection** (e.g. table actions only with a
  matching selection) is **not** displayed — the overview shows the
  *possible* action, not the current state.
- **Maintenance note:** the catalog is a mirror; the doc comment names the
  six locations, so shortcut changes get carried over here.

## Tests

- Purely static display data, no logic ⇒ **no app test target**.
  Verification:
  - `swift build` clean (no new warnings).
  - EN/DE/FR/PL catalog parity + `plutil -lint` OK; `LocalizableStringsTests`
    green (catches missing keys / a wrong quotation mark).
  - Full `swift test` stays green, unchanged (no new Core logic).
  - Read/trace: every catalog row has a label key that exists in all four
    catalogs; every `shortcut` string is non-empty.
- **Runtime idle-CPU smoke test** (fixed habit since M11n): start a dev
  build, open Preferences ▸ Shortcuts, idle CPU ~0%.
- **No uniqueness test** (context-dependent double assignment is intentional).

## Files

- New: `Sources/MacSCPApp/KeyboardShortcutsCatalog.swift`.
- Change: `Sources/MacSCPApp/SettingsView.swift` (`ShortcutsSettingsTab` +
  tab in the `TabView`, window height if needed).
- Change: `Sources/MacSCPApp/Resources/{en,de,fr,pl}.lproj/Localizable.strings`
  (tab title, group titles, label keys — in all four languages).

## Global Constraints

- Swift 6, `.swiftLanguageMode(.v5)`, min. macOS 15; no Core, no new
  logic ⇒ no new unit tests besides the L10n guard.
- Code/comments EN; UI strings via the `.strings` catalogs EN/DE/FR/PL,
  typographic quotation marks; **no ASCII `"`** in non-EN values.
- Shortcut display strings are fixed and not localized.
- New FR/PL strings are AI-generated, to be reviewed by a native speaker
  before release (consistent with M11p).
- **M11n lesson:** check new GUI paths via a runtime idle-CPU
  smoke test before shipping.
- Read-only — no rebinding (its own later milestone).
- No release/tag without explicit maintainer direction.
