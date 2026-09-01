# M11k — Search in the file list: implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Filter or jump to a match (togglable) in the current directory listing, optionally by regex; field on ⌘F, Esc closes it.

**Architecture:** A pure, testable Core matcher (substring/regex, with its own invalid case) and a pure derivation (list + query + mode ⇒ visible items / match indices / error); `RemoteBrowserViewModel` holds the search state and calls the derivation. The App shows a search field per pane, ⌘F via the focus-scoped M11j path.

**Tech Stack:** Swift 6 (`.swiftLanguageMode(.v5)`), SwiftUI + AppKit, Swift Testing.

**Spec:** `docs/superpowers/specs/2026-07-30-m11k-file-search-design.md`

## Global Constraints

- Code and comments **English only**; display text via the catalogs
  (EN default + DE, typographic quotation marks in German).
- Search acts ONLY on the currently loaded list — no recursive/server
  search.
- Invalid regex ⇒ its OWN error case, the list stays as it was (do not
  pretend "0 matches").
- `load()` on a new directory RESETS the search; `refreshQuietly()`
  keeps it.
- Only the file name is searched.
- Always verify `swift build` from a CLEAN build directory.
- Tests: Swift Testing, TDD. Baseline: **806 tests / 57 suites**.
- No release, no merge to `main`, no tag.

---

### Task 1: Matcher + derivation + VM search state (Core)

**Files:**
- Create: `Sources/macSCPCore/Presentation/FileSearch.swift`
- Modify: `Sources/macSCPCore/Presentation/RemoteBrowserViewModel.swift`
- Modify: `Sources/macSCPCore/Resources/{en,de}.lproj/Localizable.strings` (only if a Core error message lives there; otherwise the App layer)
- Test: `Tests/macSCPCoreTests/FileSearchTests.swift`, `Tests/macSCPCoreTests/RemoteBrowserViewModelTests.swift` (extend)

**Interfaces:**
- Consumes: `RemoteFileItem` (`name`, `path`), `RemoteBrowserViewModel.items`/`displayItems`.
- Produces (T2 relies on this verbatim):
  - `public enum FileSearchMode: Sendable { case filter, jump }`
  - `public enum FileSearchError: Error, Equatable, Sendable { case invalidRegex }`
  - `public enum FileSearch`
    - `public static func compile(query: String, isRegex: Bool) -> Result<FileSearchPredicate, FileSearchError>` (empty query ⇒ "everything matches")
    - `public struct FileSearchPredicate: Sendable { public func matches(_ name: String) -> Bool; public var isEmpty: Bool }`
    - `public struct Derivation: Equatable, Sendable { public let visible: [RemoteFileItem]; public let matchPaths: [String]; public let matchCount: Int; public let totalCount: Int }`
    - `public static func derive(all: [RemoteFileItem], query: String, isRegex: Bool, mode: FileSearchMode) -> Result<Derivation, FileSearchError>`
  - On `RemoteBrowserViewModel`: `searchQuery`, `searchIsRegex`, `searchMode`, `searchError: FileSearchError?`, `searchMatchCount`, `searchTotalCount`, plus jump navigation `focusNextMatch()`/`focusPreviousMatch()` (set `selectedItems` to the next/previous match, with wraparound) and `clearSearch()`.

- [x] **Step 1: Failing tests for `FileSearch`** (`FileSearchTests`):
  - `compile("", isRegex: false)` ⇒ a predicate with `isEmpty == true`, `matches` returns `true` for everything.
  - Substring case-insensitive: `compile("log", false)` matches `Access.LOG`, not `readme`.
  - Regex valid: `compile("\\.log$", true)` matches `a.log`, not `a.log.1`; anchors `^var` etc.
  - Regex INVALID: `compile("[", true)` ⇒ `.failure(.invalidRegex)`.
  - `derive` filter mode: `visible` = matches only, `matchCount`/`totalCount` correct; empty query ⇒ everything visible.
  - `derive` jump mode: `visible` == `all` (full), `matchPaths` = paths of the matches in list order.
  - `derive` with an invalid regex ⇒ `.failure(.invalidRegex)` (the caller then leaves `items` as they are).
  - Unicode/umlaut: `compile("müller", false)` matches `Müller.txt` (case-insensitive, diacritics as in an NSString comparison — document what applies).

- [x] **Step 2: Prove red.** `swift test --filter FileSearch` → FAIL.

- [x] **Step 3: Implement `FileSearch`** (pure). Compile the regex once
  (`NSRegularExpression`, `.caseInsensitive`), substring via
  `localizedCaseInsensitiveContains`. `derive` builds the four fields per
  mode from the compiled predicate.

- [x] **Step 4: Green.** `swift test --filter FileSearch` → PASS.

- [x] **Step 5: Failing tests for the VM search state**
  (`RemoteBrowserViewModelTests`, mock FS):
  - Filter mode: setting `searchQuery` reduces `items`, `searchMatchCount`/
    `searchTotalCount` correct; clearing it ⇒ everything again.
  - Jump mode: `items` stays full; `focusNextMatch()` sets
    `selectedItems` to the first/next match, wraps at the end;
    `focusPreviousMatch()` backward.
  - Invalid regex: `searchError == .invalidRegex`, `items` UNCHANGED
    (not cleared).
  - `load()` on a new directory: `searchQuery` empty, `searchError` nil,
    `items` full.
  - `refreshQuietly()` with an active filter: applies it to the fresh
    list (matches stay filtered), selection semantics unchanged.

- [x] **Step 6: Prove red, then implement.** Introduce `displayedAll` as
  a stored base (set by `load`/`refreshQuietly`); derive `items` from
  `FileSearch.derive`; the search setters trigger a re-derivation.
  `load()` calls `clearSearch()` BEFORE deriving. The existing `items`
  consumers (M7b actions, selection) stay correct, because `items`
  continues to be the displayed list.

- [x] **Step 7: Green + full suite.** `swift test` → 806 + new.

- [x] **Step 8: Commit.** `feat: search the current directory listing`

---

### Task 2: Search field, mode/regex, ⌘F, Esc (App)

**Files:**
- Create: `Sources/MacSCPApp/FileSearchBar.swift`
- Modify: `Sources/MacSCPApp/BrowserPane.swift` (search field above the table, state to the view model), `Sources/MacSCPApp/RemoteFileTableView.swift` (⌘F via `performKeyEquivalent`), `Sources/MacSCPApp/Resources/{en,de}.lproj/Localizable.strings`

**Interfaces:**
- Consumes: the VM search from T1; the focus-scoped `performKeyEquivalent`
  from M11j.

- [x] **Step 1: `FileSearchBar`** — a search field (SwiftUI) bound to the
  VM search fields: a text field, a mode switch (filter/jump), a regex
  switch, on the right the match count ("%1$lld of %2$lld" or "Match k/N"
  in jump mode) OR, when `searchError == .invalidRegex`, a red, specific
  message. Subtle styling, matching the existing pane-header dimensions
  (do not shift M5g).

- [x] **Step 2: Show it in `BrowserPane`.** The search field appears above
  the file list when the search is active for that pane (a bound
  `@State` bool). When it is off, nothing changes about the pane's resting
  state.

- [x] **Step 3: ⌘F.** In the `performKeyEquivalent` of
  `KeyboardDrivenTableView` (focus-scoped from M11j), intercept ⌘+"f":
  show that pane's search and set focus into the field. Only the focused
  table reacts (the guard is already there). Collision check: ⌘F is
  unclaimed.

- [x] **Step 4: Enter/⇧Enter in jump mode.** In the field: Enter ⇒
  `focusNextMatch()`, ⇧Enter ⇒ `focusPreviousMatch()`; the table scrolls
  the match into the visible area (the selection is set by the VM, the
  table view follows the `selectedItems` reconciliation — verify the
  match becomes visible, using `scrollRowToVisible` if needed).

- [x] **Step 5: Esc.** Closes the field, calls `clearSearch()` (everything
  is shown again), focus returns to the table.

- [x] **Step 6: EN/DE.** New keys in BOTH catalogs (match-count formats,
  mode/regex labels, the regex error message), English first.
  `plutil -lint` OK, `LocalizableStringsTests` green.

- [x] **Step 7: Verification.** `swift build` from a clean directory
  (no new warnings), full `swift test`.

- [x] **Step 8: Commit.** `feat: add the file-list search bar`

---

### Task 3: Final verification (coordinator)

- [x] Gated suites: `MACSCP_ITEST=1 MACSCP_KEYCHAIN=1 swift test` → green, zero skips.
- [x] Visual smoke — maintainer (checklist: ⌘F opens the field in the
  focused pane; filtering reduces live with "N of M"; jumping leaves the
  list full and Enter/⇧Enter moves through the matches with wraparound;
  regex switch on, `\.log$` filters; an invalid expression shows the red
  message instead of "0 matches", the list stays as it was; Esc closes and
  shows everything; changing directory resets the search; both panes
  independent; the table's type-select untouched).
- [x] Plan checkboxes, ledger, Opus final review, fix rounds until "Yes",
  push develop, `gh run watch`, memory. NO release.
