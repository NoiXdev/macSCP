# M11h — Mark symlinks: Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Symlinks are recognizable in the file list by an icon, and double-clicking a symlink that points to a directory opens it.

**Architecture:** An `NSImageView` in `RemoteFileTableView`'s name-cell setup, visible only when `kind == .symlink`; the double-click handler gets a third case that uses the same path as path entry (`navigate(to:)` from M11g).

**Tech Stack:** Swift 6 (`.swiftLanguageMode(.v5)`), SwiftUI + AppKit, Swift Testing.

**Spec:** `docs/superpowers/specs/2026-07-30-m11h-symlink-marker-design.md`

## Global Constraints

- Code and comments **English only**; display text via the catalogs
  (EN default + DE), never hardcoded. German text only with
  typographic quotation marks („…") — an ASCII `"` invalidates the entire
  German file (M11d blocker).
- **Row height and text position of the list do NOT change.** M5g matched
  both against a frozen mockup; a shift would be a silent design
  regression.
- Only `.symlink` gets an icon. `.file`, `.directory`, `.other` look
  as they do today — no icon, no placeholder, no indentation.
- Symlinks get **no** appended `/`, even when they point to a
  directory: without a `stat` per entry, that cannot be determined.
- No extra `stat`/`readlink` per list entry.
- No audit entry.
- Tests: Swift Testing, TDD red→green. Baseline before T1: **775 tests / 55 suites**.
- No release, no merge to `main`, no tag.

---

### Task 1: Icon, double-click, tooltip (App + small Core piece)

**Files:**
- Modify: `Sources/MacSCPApp/RemoteFileTableView.swift` (name cell + `doubleClicked`), `Sources/MacSCPApp/BrowserPane.swift` (forwarding, if needed), `Sources/MacSCPApp/Resources/{en,de}.lproj/Localizable.strings`
- Modify (only if the test requires it): `Sources/macSCPCore/Presentation/FileListFormatter.swift`
- Test: `Tests/macSCPCoreTests/FileListFormatterTests.swift`, `Tests/macSCPCoreTests/BrowserContextMenuTests.swift` (pin)

**Interfaces:**
- Consumes: `RemoteFileItem.kind` (`.file`/`.directory`/`.symlink`/`.other`), `RemoteBrowserViewModel.navigate(to:) async -> String?` (M11g), `DesignTokens.inkTertiaryNS`, the existing `onOpen`/`onOpenFile` pattern.
- Produces: nothing for later tasks.

- [x] **Step 1: Failing test — no `/` for symlinks.**
  In `FileListFormatterTests` (or wherever `displayName` is currently
  tested): an entry with `kind == .symlink` and name `current` must be
  formatted as `current`, NOT as `current/`. Add two regression cases
  alongside it: a directory keeps its `/`, a file gets none.
  First check whether `displayName` already behaves this way — it reads
  `item.isDirectory`, and `isDirectory` is `kind == .directory`, so
  the behavior is presumably already correct. **If the test is green
  immediately, say so in the report and leave it standing as a
  regression guard** — do not invent a change to `FileListFormatter`
  just to change something.

- [x] **Step 2: Pin the context-menu behavior.**
  In `BrowserContextMenuTests`, make sure that a symlink still shows
  NO transfer, editor, or permissions entry (M7b rule). If this test
  already exists, do not duplicate it — just verify and record it in
  the report.

- [x] **Step 3: Icon in the name column.**
  In `tableView(_:viewFor:row:)`, the `"name"` cell setup gets, next to
  the existing `NSTextField`, an `NSImageView` with
  `NSImage(systemSymbolName: "arrow.up.forward", accessibilityDescription:)`,
  `contentTintColor` = `DesignTokens.inkTertiaryNS`, icon size matched to
  12.5 pt text.

  Layout: the icon sits within the existing left inset, the text field
  stays at **12 pt** indent. That is: the icon is placed to the left of
  the text without shifting the text, and the row height stays
  unchanged. Check the existing constraints before adding new ones —
  there are already `leadingAnchor +12`,
  `trailingAnchor -12`, `centerYAnchor`.

  **Recycling hygiene (critical):** cells come from
  `makeView(withIdentifier:)`. The icon must be explicitly shown or
  hidden (`isHidden`) on EVERY assignment, otherwise it appears on the
  wrong row as soon as scrolling happens. The existing code
  unconditionally sets `stringValue` and font/color on every reuse —
  follow exactly that pattern.

- [x] **Step 4: Tooltip.**
  The name cell of a symlink row gets a `toolTip` with a localized
  text ("Symbolic link" / „Symbolischer Link"), which also serves as
  the icon's accessibility description. Other rows get
  `toolTip = nil` (recycling!).

- [x] **Step 5: Double-click.**
  `doubleClicked(_:)` gets a third branch: for `kind == .symlink`,
  the entry's path is passed to a new closure parameter (pattern like
  `onOpenFile`), which `BrowserPane`/`ContentView` forward to
  `viewModel.navigate(to: item.path)`. On success, the pane switches
  into it — with the **symlink's path**, not the resolved target
  (`navigate(to:)` already behaves this way, and a resolved path would
  send `goUp()` to a place the user never came from). On failure, the
  message from `navigate(to:)` is shown — use the spot where the pane
  already shows errors, rather than inventing a new one. `.other`
  stays a no-op.

- [x] **Step 6: EN/DE.**
  New keys in BOTH app catalogs, English first. `plutil -lint` on
  all four catalogs OK, `LocalizableStringsTests` green.

- [x] **Step 7: Verification.**
  `swift build` from a CLEAN build directory (an incremental run shows
  no warnings because nothing gets recompiled — only the clean run is
  an honest statement): no NEW warnings; the four pre-existing ones are
  expected (`BrowserPane` redundant `_`,
  `TransferEngine:137`, two Citadel Sendable). Full `swift test`.

- [x] **Step 8: Commit.** `feat: mark symlinks in the file list and follow them on double-click`

---

### Task 2: "Check now" in settings (App)

Maintainer request 2026-07-30: "would also like a check for updates in the
settings". Update checking has existed since M11b — the "Automatically
check for updates" toggle sits in the **General** tab, the manual check
in the menu **macSCP ▸ Check for Updates…**. What is missing from
settings is the immediate path plus a status display.

**Files:**
- Modify: `Sources/MacSCPApp/SettingsView.swift` (update-check section in the "General" tab), `Sources/MacSCPApp/Resources/{en,de}.lproj/Localizable.strings`
- Modify if needed: `Sources/macSCPCore/Settings/SettingsStore.swift` (only if the timestamp is not yet readable), `Sources/MacSCPApp/UpdateCheckModel.swift`

**Interfaces:**
- Consumes: `UpdateCheckModel` (M11b, already drives the manual check from the menu), `SettingsStore.updateCheckEnabled` and the last-check timestamp already stored there, `AppVersion`.

- [x] **Step 1: Read what exists, don't rebuild.** `UpdateCheckModel` and
  the menu entry already do the work. Find out how the menu entry
  triggers the check and how the result is displayed, and use exactly
  that same path — no second check path, no second result display.
  Record in the report which path you found.

- [x] **Step 2: The section.** Below the existing toggle in the
  "General" tab:
  - the running version (from the bundle, the way "About macSCP" reads it),
  - the time of the last check, or a sentence saying it has never been
    checked,
  - a "Check Now" button in `PolishedButtonStyle`, disabled while a
    check is running.
  The existing toggle and its footer text stay unchanged — the text
  about "at most once daily, no data about you" is a commitment this
  task must not water down.

- [x] **Step 3: Honest result.** Success with no update found, success
  with an update found (version + link, as the menu shows it), and
  failure (no network, rate limit) are three distinct states, each with
  its own text. No silent nothing after a click.

- [x] **Step 4: EN/DE + verification.** New keys in BOTH catalogs,
  `plutil -lint` OK, `LocalizableStringsTests` green, `swift build` from
  a clean build directory with no new warnings, full `swift test`.
  **No test may use the network** — M11b already enforces this with
  a loud stub failure; if you add tests, follow the same rule.

- [x] **Step 5: Commit.** `feat: check for updates from the settings window`

---

### Task 3: Closing verification (coordinator)

- [x] Gated suites at the final state: `MACSCP_ITEST=1 MACSCP_KEYCHAIN=1 swift test` → all green, zero skips. Plus a gated rig test: a symlink to a directory and one to a file, via `navigate(to:)` — the first succeeds, the second returns the message.
- [x] Visual smoke — delegated to the maintainer (checklist: the icon appears ONLY on symlinks; row height and text edge look as before; scrolling through a long list never moves an icon to the wrong row; tooltip appears; double-clicking a directory symlink opens it and the path bar shows the symlink's path; double-clicking a file symlink shows a message instead of doing nothing; light and dark).
- [x] Plan checkboxes, ledger, Opus final review, fix rounds until "Yes", push develop, `gh run watch`, memory. NO release.
