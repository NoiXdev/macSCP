# M11f — Hidden imports: Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Imported entries from `~/.ssh/config` can be hidden from the sidebar and brought back via their own sheet — without the config file ever being touched.

**Architecture:** A dedicated JSON store (`hidden-imports.json`) holds the hidden aliases; a pure Core function splits the loaded config entries into visible / hidden / orphaned; the app shows a context menu in the sidebar and a management sheet in the Sessions menu.

**Tech Stack:** Swift 6 (`.swiftLanguageMode(.v5)`), SwiftUI, Swift Testing.

**Spec:** `docs/superpowers/specs/2026-07-29-m11f-hidden-imports-design.md`

## Global Constraints

- Code and comments **English only**; display text via the catalogs
  (`Localizable.strings`, EN default + DE), never hardcoded.
- `~/.ssh/config` is **never** written — in any variant.
- Only the **alias** is stored, no host/user/path.
- Alias comparison is **exact**, not case-insensitive.
- The hide list does **not** travel with the sessions export (M9a).
- No audit entry (a purely visual setting).
- Tests: Swift Testing, TDD red→green. Baseline before T1: **720 tests / 52 suites**.
- No release, no merge to `main`, no tag.

---

### Task 1: HiddenImportStore + pure split function (Core)

**Files:**
- Create: `Sources/macSCPCore/Sessions/HiddenImportStore.swift`
- Test: `Tests/macSCPCoreTests/HiddenImportStoreTests.swift`

**Interfaces:**
- Consumes: `SSHConfigHost` (`Sources/macSCPCore/Sessions/SSHConfigParser.swift`), `SessionStore.defaultDirectory`.
- Produces (T2 relies on this literally):
  - `public struct HiddenImportStore: Sendable`
    - `public init(directory: URL)`
    - `public func allHidden() throws -> [String]` — alphabetical, `localizedCaseInsensitiveCompare`
    - `public func hide(_ alias: String) throws`
    - `public func unhide(_ alias: String) throws`
    - `public func isHidden(_ alias: String) throws -> Bool`
  - `public enum ImportedHostPartition`
    - `public struct Result: Equatable, Sendable { public let visible: [SSHConfigHost]; public let hidden: [SSHConfigHost]; public let orphaned: [String] }`
    - `public static func split(hosts: [SSHConfigHost], hiddenAliases: [String]) -> Result`

- [x] **Step 1: Write failing tests** (`Tests/macSCPCoreTests/HiddenImportStoreTests.swift`)

Structure like `LoginSetStoreTests`: a fresh temporary directory per test, cleaned up at the end.

Store cases:
- missing file ⇒ `allHidden()` returns `[]`, `isHidden("x") == false`
- `hide("a")` then `allHidden() == ["a"]`, `isHidden("a") == true`
- `hide("a")` twice ⇒ still exactly one entry (idempotent)
- `unhide("a")` ⇒ empty; `unhide("nichtda")` does not throw and changes nothing
- Sorting: `hide("zulu")`, `hide("alpha")` ⇒ `["alpha", "zulu"]`
- exact comparison: `hide("Prod")` ⇒ `isHidden("prod") == false`
- forward compatibility: a file with an extra unknown field
  (`{"aliases":["a"],"futureField":42}`) loads and returns `["a"]`
- empty file structure `{}` ⇒ `[]`

Partition cases (pure, no file access — hosts via
`SSHConfigHost(alias:hostName:user:port:identityFile:)`):
- none hidden ⇒ `visible` equals the input, `hidden`/`orphaned` empty
- one alias hidden ⇒ it is missing from `visible`, appears in `hidden`
- a hidden alias missing from the hosts ⇒ appears in `orphaned`, not in `hidden`
- ordering: `visible` keeps the input order (the importer already sorts)
- rename case: hosts `["neu"]`, hidden `["alt"]` ⇒ `visible == ["neu"]`, `orphaned == ["alt"]`

- [x] **Step 2: Prove red.** `swift test --filter HiddenImportStore` → FAIL (type does not exist).

- [x] **Step 3: Implementation** (`HiddenImportStore.swift`)

Pattern taken literally from `LoginSetStore`: private `StoreFile: Codable` with
`var aliases: [String] = []`, `load()` returns an empty `StoreFile` when the
file is missing, `persist` creates the directory and writes
`.atomic` with `outputFormatting = [.prettyPrinted, .sortedKeys]`,
file name `hidden-imports.json`.

`ImportedHostPartition.split` is pure: a `Set` of the hidden aliases
for the membership check, `visible` = hosts not in the set (order
preserved), `hidden` = hosts in the set, `orphaned` = aliases of the set
with no matching host, sorted alphabetically.

Doc comments (English) must record: only the alias is
stored (the list should not become a second, staling copy of the
config); the comparison is exact because ssh treats `Host` aliases as
exact strings, and a looser rule would hide entries nobody meant.

- [x] **Step 4: Green.** `swift test --filter HiddenImportStore` → PASS, then full `swift test` → 720 + new tests.

- [x] **Step 5: Commit.** `feat: remember which imported hosts are hidden`

---

### Task 2: Context menu, sheet, menu entry (App)

**Files:**
- Create: `Sources/MacSCPApp/HiddenImportsSheet.swift`
- Modify: `Sources/MacSCPApp/SessionSidebar.swift` (importedSection), `Sources/MacSCPApp/ContentView.swift` (state, filtering, sheet, tabCommands), `Sources/MacSCPApp/MacSCPApp.swift` (Sessions menu), `Sources/MacSCPApp/Resources/{en,de}.lproj/Localizable.strings`

**Interfaces:**
- Consumes: everything from Task 1 (`HiddenImportStore`, `ImportedHostPartition`), `SessionStore.defaultDirectory`, the existing `tabCommands` pattern (see `showKnownHosts`).
- Produces: nothing for later tasks.

- [x] **Step 1: ContentView — data and filtering.**
  `@State private var importedHosts` continues to hold the VISIBLE hosts
  (the sidebar's wiring stays unchanged). Add a state for the
  full loaded set and the hidden aliases. A private method
  `refreshImportedHosts()` reads the store, calls
  `ImportedHostPartition.split`, and sets both states; `ContentView.task`
  calls it instead of today's direct assignment. It is called again
  after hiding/unhiding — **without** re-reading the config file (the
  full set lives in state).

- [x] **Step 2: Sidebar context menu.**
  In `importedSection`, every row gets a `.contextMenu` with exactly
  one entry "Hide" (`sidebar.imported.hide`), which calls a new
  closure parameter `onHideImported: (SSHConfigHost) -> Void`.
  No confirmation dialog. The existing `onTapGesture` and the `.help`
  stay unchanged.

- [x] **Step 3: Sheet** (`HiddenImportsSheet.swift`).
  Layout and dimensions like `KnownHostsSheet` (copy that, don't
  reinvent it): title, list, Close button with `.keyboardShortcut(.defaultAction)`,
  `PolishedButtonStyle`. Each row shows the alias and "Unhide".
  Orphaned aliases additionally carry a secondary text "no longer in
  ~/.ssh/config" and, instead, "Remove from list" — both paths
  call `unhide`. Empty state: a sentence explaining how entries get here
  (right-click in the sidebar → Hide).
  Errors from the store are displayed, not swallowed.

- [x] **Step 4: Menu entry.**
  In `CommandMenu("Sessions")` after "Logins…", an entry "Hidden
  Imports…" with `.keyboardShortcut("i", modifiers: [.command, .shift])`,
  wired via `tabCommands.showHiddenImports` following the pattern of
  `showKnownHosts` (including the key-window guard in `ContentView.task`).
  As long as something is hidden, the title carries the count
  (`menu.hiddenImports %@` with a format argument) — without this hint
  the way back would be undiscoverable once the IMPORTED section is
  empty. The same entry additionally in the sidebar's
  `backgroundMenu` (Known Hosts and Logins already sit there).

- [x] **Step 5: EN/DE catalogs.**
  All new keys in BOTH app catalogs, English first, German with
  typographic quotation marks („…") — an ASCII `"` invalidates the
  entire German file (M11d blocker). `plutil -lint` on all four
  catalogs must be OK and `LocalizableStringsTests` must stay green.

- [x] **Step 6: Verification.**
  `swift build` (0 errors, no new warnings), full `swift test`,
  `plutil -lint` on all four catalogs.

- [x] **Step 7: Commit.** `feat: hide imported hosts and manage them in a sheet`

---

### Task 3: Closing verification (coordinator)

- [x] Gated suites at the final state: `MACSCP_ITEST=1 MACSCP_KEYCHAIN=1 swift test` → all green, zero skips.
- [x] Visual smoke — delegated to the maintainer (checklist: hiding via right-click takes effect immediately; the menu entry carries the count; the sheet unhides again; an alias renamed in `~/.ssh/config` appears as orphaned and can be removed; `~/.ssh/config` is byte-identical after all of it — before/after via `md5`).
- [x] Plan checkboxes, ledger, Opus final review (package based on `git merge-base origin/develop HEAD`), fix rounds until "Yes", push develop, `gh run watch`, memory. NO release.
