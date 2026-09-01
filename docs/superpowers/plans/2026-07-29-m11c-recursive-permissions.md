# M11c — Set permissions recursively Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Apply permissions to an entire subtree — the same permissions for everything, or separate ones for files and folders — with progress, cancellation, an honest result tally, and symlink safety.

**Architecture:** A pure `PermissionsTreeApplier` against `any RemoteFileSystem` (this makes it apply to both panes without backend duplication; the caller supplies the root's kind), plus `PosixPermissions.directoryDefault(from:)` as a pure derivation; the VM wraps the call, reload, audit and progress callback; the existing permissions sheet gets a switch, a second grid, a confirmation, progress.

**Tech Stack:** Swift 6 / `.swiftLanguageMode(.v5)`, Swift Testing, SwiftUI.

## Global Constraints

- Spec: `docs/superpowers/specs/2026-07-29-m11c-recursive-permissions-design.md` — binding. Branch: **develop**.
- **SYMLINK SAFETY (security invariant):** symlinks are NEVER subjected to `setPermissions` and NEVER entered — `setPermissions` follows the symlink on both backends (M7a finding), a violation changes permissions OUTSIDE the tree. The walk detects types exclusively via `list()` (reports unresolved), never via `stat`.
- Count errors instead of aborting (the `applyImport` pattern); the walk does NOT throw, it returns numbers.
- Cooperatively cancellable between entries; on cancellation, permissions already set stay set (documented, no rollback).
- No protocol extension of `RemoteFileSystem` (the walk is a pure function over it).
- No entry into the transfer queue; no multi-selection; no undo.
- All new UI text EN/DE in BOTH App catalogs, Core messages in both Core catalogs; code + comments English ONLY; no new dependencies.
- Conventional Commits (English), footer: `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- `swift build` + full `swift test` green after every task (starting point 652 tests / 49 suites); gated suites in T4; tests run SYNCHRONOUSLY in the foreground; TDD red→green for Core.
- Docker rig only `start`/`stop` from the main checkout.
- NO release, no merge to main.

## Schedule

T1 (Core: derivation + walk) → T2 (VM: action, audit, progress) → T3 (App: dialog) → T4 wrap-up (coordinator).

---

### Task 1: directoryDefault + PermissionsTreeApplier (Core, RISK)

**Files:**
- Modify: `Sources/macSCPCore/Presentation/PosixPermissions.swift` (derivation)
- Create: `Sources/macSCPCore/RemoteFS/PermissionsTreeApplier.swift`
- Test: `Tests/macSCPCoreTests/PosixPermissionsTests.swift` (existing file — find via grep), `Tests/macSCPCoreTests/PermissionsTreeApplierTests.swift` (new)

**Interfaces:**
- Consumes: `RemoteFileSystem` (`list(path:)`, `setPermissions(path:permissions:)`), `RemoteFileItem`/`RemoteFileKind`, the mock from the existing tests (grep `MockFileSystem`, or the double used in the browser tests — reuse the matching one, or add a recording double locally).
- Produces (T2/T3 rely on this exactly):
  - `PosixPermissions.directoryDefault(from raw: UInt32) -> UInt32` (static OR an instance property — the implementer chooses and documents it; assumed static in the plan)
  - `PermissionsTreeResult: Equatable, Sendable` (`changed: Int`, `skippedSymlinks: Int`, `failed: Int`, `firstErrorMessage: String?`, `cancelled: Bool`)
  - `PermissionsTreeApplier.apply(root:kind:filePermissions:directoryPermissions:on:progress:) async -> PermissionsTreeResult` — `progress: (@Sendable (PermissionsTreeResult) -> Void)? = nil` is called with the running tally after EVERY entry (this is how the UI counts along)

**Behavior requirements (spec §1/§2, binding):**
1. `directoryDefault`: in every triplet, set the x bit IF r is set there; carry the special bits (setuid/setgid/sticky, the upper four bits) unchanged. 0o644⇒0o755, 0o600⇒0o700, 0o640⇒0o750, 0o2644⇒0o2755.
2. Root `.symlink` ⇒ do NOTHING, result `skippedSymlinks == 1`, everything else 0.
3. Root `.directory` ⇒ first `setPermissions(directoryPermissions)` on the root, then recurse via `list()`. Root `.file` (or anything else) ⇒ only `setPermissions(filePermissions)` on the root.
4. Per entry from `list()`: `.symlink` ⇒ skip + count, NEVER `setPermissions`, NEVER enter. `.directory` ⇒ `setPermissions(directoryPermissions)`, then descend recursively. Otherwise ⇒ `setPermissions(filePermissions)`.
5. An error from `setPermissions` ⇒ `failed += 1`, first message into `firstErrorMessage` (`String(describing:)`, or the localized `RemoteFSError` message if available — choose the smaller solution and document it), the walk continues. An error from `list` ⇒ likewise `failed += 1` and continue with the rest (the subdirectory is not entered).
6. `Task.checkCancellation()` before every entry; on cancellation, return immediately with `cancelled: true` and the partial counts (no throw).
7. `progress` is called with the current running tally after every count change (including on skipped and failed entries).

- [x] **Step 1: Failing tests**

```swift
    // PosixPermissionsTests (Ergänzung):
    // directoryDefaultAddsExecuteWhereReadable: 0o644->0o755, 0o600->0o700,
    //   0o640->0o750, 0o2644->0o2755 (Sonderbits bleiben), 0o000->0o000.
    //
    // PermissionsTreeApplierTests (Recording-Mock: merkt sich alle
    // setPermissions-Aufrufe als (path, permissions) und liefert gestellte
    // Listings; kann pro Pfad einen Fehler werfen):
    // appliesSeparatePermissionsAcrossTree: Baum /r (dir) mit /r/a.txt,
    //   /r/sub (dir), /r/sub/b.txt -> Aufrufe: /r und /r/sub mit dirPerms,
    //   /r/a.txt und /r/sub/b.txt mit filePerms; changed == 4.
    // samePermissionsModeUsesOneValue: filePerms == dirPerms -> alle vier
    //   Aufrufe mit demselben Wert.
    // neverTouchesSymlinks: Baum mit /r/link (symlink) und /r/dirlink
    //   (symlink auf ein Verzeichnis) -> KEIN setPermissions-Aufruf mit
    //   diesen Pfaden (Aufzeichnung prüfen), kein list() auf /r/dirlink,
    //   skippedSymlinks == 2.
    // rootSymlinkDoesNothing: kind .symlink -> keine Aufrufe,
    //   skippedSymlinks == 1, changed == 0.
    // rootFileAppliesFilePermissionsOnly: kind .file -> genau ein Aufruf.
    // failedEntryCountsAndContinues: setPermissions wirft für /r/a.txt ->
    //   failed == 1, firstErrorMessage != nil, /r/sub/b.txt trotzdem
    //   gesetzt (changed enthält die übrigen).
    // failedListingCountsAndContinues: list wirft für /r/sub -> failed == 1,
    //   /r/a.txt trotzdem gesetzt; kein Absturz.
    // cancellationStopsAndReportsPartial: Abbruch nach dem ersten Eintrag
    //   (Mock löst im setPermissions-Callback Task-Cancellation aus bzw.
    //   der Test cancelt den umgebenden Task) -> cancelled == true,
    //   changed < Gesamtzahl.
    // emptyDirectoryOnlySetsItself: /r ohne Inhalt -> changed == 1.
    // progressReportsAfterEachEntry: Callback-Aufrufe == Anzahl der
    //   verarbeiteten Einträge (inkl. übersprungener/fehlgeschlagener).
```

- [x] **Step 2: Prove red.** `swift test --filter PermissionsTree` and `--filter PosixPermissions` → FAIL.
- [x] **Step 3: Implementation** (derivation first, then the walk).
- [x] **Step 4: Green + full suite.** `swift test` → 652 + new, 0 failures.
- [x] **Step 5: Commit.** `feat: apply permissions across a directory tree`

---

### Task 2: VM action + audit + progress (Core)

**Files:**
- Modify: `Sources/macSCPCore/Presentation/RemoteBrowserViewModel.swift`
- Test: `Tests/macSCPCoreTests/RemoteBrowserViewModelTests.swift` (or the file with `applyPermissionsFailureFiresIsErrorPermissionsEvent` — via grep)

**Interfaces:**
- Consumes (T1): `PermissionsTreeApplier.apply(...)`, `PermissionsTreeResult`, `PosixPermissions.directoryDefault(from:)`.
- Produces (T3):
  - `RemoteBrowserViewModel.applyPermissionsRecursively(filePermissions:directoryPermissions:to item:progress:) async -> PermissionsTreeResult`

**Behavior requirements (spec §3, binding):**
1. Calls the walk with `item.path` and `item.kind`, forwards the progress callback, afterward reloads the listing ONCE (`load()`), even on errors and after cancellation.
2. Writes EXACTLY ONE audit entry: detail `chmod -R <fileOctal>/<dirOctal> <pfad>` plus the counts (changed/skipped/failed, additionally marked as cancelled on cancellation); `isError` ONLY when `failed > 0`; on errors `errorMessage` carries the first message.
3. Returns the result unchanged (the UI formulates the display).
4. The existing `applyPermissions` (single object) stays unchanged.

- [x] **Step 1: Failing tests**

```swift
    // recursiveApplyWritesOneAuditEventWithCounts: Mock-FS mit kleinem Baum
    //   -> genau EIN Audit-Event, Detail enthält "chmod -R", die Oktalwerte
    //   und die Zahlen; isError == false.
    // recursiveApplyMarksErrorWhenAnyEntryFailed: ein Eintrag scheitert ->
    //   isError == true, errorMessage == erste Meldung, Ergebnis failed == 1.
    // recursiveApplyReloadsListing: nach dem Lauf wurde list() erneut
    //   gerufen (Mock zählt).
    // recursiveApplyForwardsProgress: Callback-Aufrufe kommen an.
```

- [x] **Step 2: Red.** **Step 3: Implementation.** **Step 4: Green + full suite.** **Step 5: Commit** `feat: expose a recursive permissions action with audit and progress`.

---

### Task 3: Dialog (App)

**Files:**
- Modify: `Sources/MacSCPApp/InfoPermissionsSheet.swift` (or the file with the permissions sheet — via grep `InfoPermissions`), possibly `Sources/MacSCPApp/BrowserPane.swift` (call wiring), `Sources/MacSCPApp/Resources/en.lproj/Localizable.strings` + `de.lproj`
- Test: none (App target; smoke test in T4)

**Interfaces:**
- Consumes (T2): `applyPermissionsRecursively(filePermissions:directoryPermissions:to:progress:)`, `PermissionsTreeResult`; existing: the permissions grid and the octal input from M7b (do NOT change the octal input's ONE-WAY behavior — an M7b review finding), the confirmation-dialog style from the delete flow.

**Behavior requirements (spec §4, binding):**
1. A switch "Apply to all enclosed items" — visible ONLY when `item.kind == .directory`.
2. Switched on: segments `Same permissions | Separate`. "Same permissions": the existing grid applies to files AND folders. "Separate": two grids labeled files/folders; preset = current permissions for files and `PosixPermissions.directoryDefault(from:)` for folders; both freely editable (including the existing octal input per grid).
3. In recursive mode the apply button reads "Apply Recursively" and FIRST shows a confirmation with the target path and mode (EN "Apply permissions to every item inside %@? This cannot be undone." / DE „Rechte auf alle Objekte in %@ anwenden? Das lässt sich nicht rückgängig machen.").
4. During the run: the sheet shows a progress line (running counts from the callback) and a "Cancel" button that cancels the task; the remaining controls are locked. Afterward the result line: "%lld changed, %lld skipped, %lld failed" (symlink note in the text: skipped = symlinks), on cancellation additionally the note that it was cancelled; on errors, the first message in red.
5. The single-object path (switch off) stays exactly as it is today.
6. All new keys EN/DE in both App catalogs; grep cross-check.

- [x] **Step 1:** Switch + segments + second grid. **Step 2:** Confirmation + call + progress/cancel. **Step 3:** Result line. **Step 4:** L10n + cross-check. **Step 5:** `swift build` (0 errors, no new warnings) + full `swift test`. **Step 6:** Commit `feat: apply permissions recursively from the info sheet`.

---

### Task 4: Final verification (coordinator)

- [x] Add a gated rig test: create a tree on the server (a directory, a file, a subdirectory with a file, a symlink to a file OUTSIDE the tree), apply 644/755 recursively, then verify via `docker exec stat`: permissions inside the tree correct, **symlink target outside UNCHANGED**, `skippedSymlinks == 1`.
- [x] Rig `start`, `MACSCP_ITEST=1 MACSCP_KEYCHAIN=1 swift test` → all green, zero skips, no leftovers; rig `stop`.
- [ ] Visual smoke — delegated to the maintainer (checklist: switch only on folders, both modes, preset 644⇒755, confirmation, progress + cancel, result line, local side).
- [x] Plan checkboxes, ledger, Opus final review (package via `git merge-base origin/develop HEAD`), fix rounds until "Yes", push develop, `gh run watch`, memory, summary. NO release.
