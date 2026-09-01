# M11m — Extra Columns: Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Toggleable permissions/owner/group/type columns in the file list, switchable on/off in settings, each sortable.

**Architecture:** `RemoteFileItem` gets `owner`/`group` (parsed from `longname`, numeric/`nil` fallback); a `FileColumn` model + persisted visibility in `SettingsStore`; `FileSortKey` (M11l) extended with the new keys; the table builds its columns dynamically from the setting.

**Tech Stack:** Swift 6 (`.swiftLanguageMode(.v5)`), SwiftUI + AppKit, Swift Testing.

**Spec:** `docs/superpowers/specs/2026-07-31-m11m-extra-columns-design.md`

## Global Constraints

- Code and comments **English only**; display text via the catalogs
  (EN default + DE, typographic quotation marks in German).
- Owner/group: `longname` names FIRST, then numeric `uidgid`, then
  `nil` — **never a guessed, wrong display**. The parser is
  pure/testable and defensive.
- No extra server round trip for name resolution.
- `name` is always visible; `size`/`modified` on by default;
  `permissions`/`owner`/`group`/`type` off by default.
- Forward compatibility: old `settings.json` ⇒ default columns.
- Recycling hygiene in the cells (set content on every reuse).
- M5g look of the three existing columns unchanged.
- Always check `swift build` from a CLEAN build directory.
- Tests: Swift Testing, TDD. Baseline: **847 tests / 59 suites**.
- No release, no merge to `main`, no tag.

---

### Task 1: Model, longname parser, mapper, column/sort/settings core (Core)

**Files:**
- Modify: `Sources/macSCPCore/RemoteFS/RemoteFileItem.swift` (owner/group), `Sources/macSCPCore/SSH/SFTPAttributeMapper.swift`, `Sources/macSCPCore/SSH/CitadelFileSystem.swift` (pass longname through), `Sources/macSCPCore/RemoteFS/LocalFileSystem.swift` (owner/group from stat), `Sources/macSCPCore/Presentation/RemoteBrowserViewModel.swift` (FileSortKey cases), `Sources/macSCPCore/Settings/SettingsStore.swift` (visible columns)
- Create: `Sources/macSCPCore/Presentation/FileColumn.swift` (FileColumn + formatters + longname parser, or split)
- Test: `Tests/macSCPCoreTests/` — new files for parser/formatters/columns, extensions to the mapper/VM/settings/Citadel ITests

**Interfaces:**
- Consumes: `RemoteFileItem`, Citadel's `SFTPPathComponent.longname`/`.attributes.uidgid`, `PosixPermissions` (M7b), `FileSortKey` (M11l).
- Produces (T2 relies on this literally):
  - `RemoteFileItem.owner: String?`, `.group: String?` (extend memberwise init, defaults `nil`)
  - `public enum FileColumn: String, Sendable, CaseIterable { case name, size, modified, permissions, owner, group, type }` with `isToggleable`/`defaultVisible`
  - `public enum LongnameParser { public static func ownerGroup(from longname: String) -> (owner: String, group: String)? }`
  - Formatters (pure): `FileColumn.text(for: RemoteFileItem) -> String?` or per column (rwx permissions, type per kind — the localized type/placeholder strings come from the App layer; Core provides the raw building blocks)
  - `FileSortKey` extended with `.permissions/.owner/.group/.type`
  - `SettingsStore.visibleColumns: [FileColumn]` (or Set), persisted, forward compatible

- [x] **Step 1: Failing tests for `LongnameParser`.** Standard `ls -l` line
  `-rw-r--r-- 1 www-data staff 2454 Jul 30 14:22 config.php` ⇒
  `(owner: "www-data", group: "staff")`; multiple whitespace; owner with
  special characters; too-short/broken line ⇒ `nil`; directory line `drwxr-xr-x`.
- [x] **Step 2: Red, then implement the parser** (defensive: after the first
  two fields — perms, link count — come owner and group; tolerant
  of whitespace; uncertain ⇒ `nil`).
- [x] **Step 3: Model + mapper.** `owner`/`group` on `RemoteFileItem`;
  `SFTPAttributeMapper.item` gets `longname`/`uidgid` and sets
  owner/group by the priority order (longname name → numeric → nil). Tests:
  longname wins; without longname numeric; without either nil.
- [x] **Step 4: Pass through Citadel + Local.** The readdir path passes
  `component.longname` and `component.attributes.uidgid` to the mapper; the
  single-`stat` path only `uidgid` (no longname). `LocalFileSystem` fills
  owner/group from `stat` (getpwuid/getgrgid), numeric fallback.
- [x] **Step 5: `FileColumn` + formatters + `FileSortKey` cases** with tests
  (rwx permissions, type per kind, owner/group/nil; sort cases including
  the name tiebreaker and nil position; the M11l rule "tiebreaker stays
  ascending" still applies).
- [x] **Step 6: `SettingsStore.visibleColumns`** persisted +
  forward compatible (old JSON ⇒ name/size/modified). Roundtrip test.
- [x] **Step 7: Gated rig test.** A listing against the Docker server
  returns owner/group (known rig values). `MACSCP_ITEST=1`.
- [x] **Step 8: Green + full suite.** `swift test` → 847 + new.
- [x] **Step 9: Commit.** `feat: carry owner/group and model selectable columns`

---

### Task 2: Dynamic columns + settings checkboxes (App)

**Files:**
- Modify: `Sources/MacSCPApp/RemoteFileTableView.swift` (columns built dynamically from the setting, cells for the new columns, sortDescriptor/indicator per column), `Sources/MacSCPApp/SettingsView.swift` (checkboxes), `Sources/MacSCPApp/BrowserPane.swift`/`ContentView.swift` (pass the setting through), `Sources/MacSCPApp/Resources/{en,de}.lproj/Localizable.strings`

**Interfaces:**
- Consumes: `FileColumn`, the formatters, `SettingsStore.visibleColumns`, `FileSortKey` (T1); the M11l sort/indicator pattern.

- [x] **Step 1: Dynamic columns.** `makeNSView` builds the columns from
  `visibleColumns` in a fixed order (Name, Size, Modified, Permissions,
  Owner, Group, Type — visible ones only); each with `PolishedHeaderCell`,
  localized title and `sortDescriptorPrototype`. When the setting
  changes, columns are rebuilt (in `updateNSView`, idempotent — only on an
  actual change, no flicker).
- [x] **Step 2: Cells.** `tableView(_:viewFor:row:)` gets the new
  column IDs: permissions (rwx, monospaced), owner/group (text), type
  (localized). Recycling hygiene: content MUST be set on every reuse;
  values via the Core formatters + App L10n.
- [x] **Step 3: Sort indicator** per column, continuing the M11l pattern (self-
  drawn ▲/▼).
- [x] **Step 4: Settings.** Checkbox for each toggleable column
  (Name fixed, cannot be turned off). Binds to `SettingsStore.visibleColumns`.
- [x] **Step 5: EN/DE.** Column titles + type strings + "—" placeholder in
  BOTH catalogs. `plutil -lint` OK, `LocalizableStringsTests` green.
- [x] **Step 6: Verification.** `swift build` clean (no new
  warnings), full `swift test`.
- [x] **Step 7: Commit.** `feat: show selectable file-list columns`

---

### Task 3: Final verification (coordinator)

- [x] Gated suites: `MACSCP_ITEST=1 MACSCP_KEYCHAIN=1 swift test` → green, zero skips.
- [ ] Visual smoke test — maintainer (checklist: checkboxes toggle
  columns on/off; owner/group show real names against the rig, "—" where
  unknown; permissions as rwx; type localized; new columns sortable with
  triangle; recycling without smearing while scrolling; M5g look of the old columns
  unmoved; light/dark; both panes).
- [x] Plan checkboxes, ledger, Opus final review, fix rounds until "Yes",
  push develop, `gh run watch`, memory. NO release.
