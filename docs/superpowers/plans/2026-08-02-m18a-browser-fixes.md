# M18a — Browser Fixes & "New File" Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The New Folder dialog no longer hangs on reloading the listing, owner/group are only fetched when the columns are visible, "New File…" lands in the context menu, and a window frame restored off-screen is investigated.

**Architecture:** The core change is a split in Core: the file operation (fast, error-prone) and the subsequent listing refresh (slow, pure display) become two awaitable steps; the dialog now only waits on the first. Alongside that, a switch on `LocalFileSystem` makes the expensive owner/group lookup happen only when the columns are visible.

**Tech Stack:** Swift (SwiftPM, `.swiftLanguageMode(.v5)`), Swift Testing, SwiftUI + AppKit, macOS 15+.

## Global Constraints

- Swift `.swiftLanguageMode(.v5)`, minimum macOS 15; **no new external dependency**.
- **No protocol change** to `RemoteFileSystem` (no new `list` parameter).
- Error behavior unchanged: collisions/errors appear **inside** the dialog, which then stays open.
- Audit events are preserved (`newFolder`, `rename`) or follow the same pattern (`newFile`).
- Existing tests are **adapted, not deleted** — every expectation checked so far must keep being checked (split across two steps where needed).
- UI strings EN/DE/FR/PL, typographic characters in non-English values.
- Conventional Commits; footer: `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.

**Anchored facts (verified):** `RemoteBrowserViewModel.createFolder(named:)` sits at `Sources/macSCPCore/Presentation/RemoteBrowserViewModel.swift:464`, `rename(_:to:)` right before it (~445); both: operation → `await load()` → set selection → audit → `return nil`. `LocalFileSystem.list(path:)` (`:59`) maps each entry through `Self.item(for:)` (`:266`) → `ownerGroup(for:)` (`:302`, `FileManager.attributesOfItem` per entry). `LocalFileSystem()` is created in `ContentView.swift:1908` and `:1910` as well as `EditSessionManager.swift:39`. `NameEntrySheet.confirm()` (`Sources/MacSCPApp/BrowserSheets.swift:47`) calls `dismiss()` only after `await onConfirm(...)`. Menu trigger `case .newFolder: showNewFolderSheet = true` (`Sources/MacSCPApp/BrowserPane.swift:191`), sheet at `:257`. `BrowserMenuEntry` (`Sources/macSCPCore/Presentation/BrowserContextMenu.swift`) has, among others, `case newFolder` (:34); rendered in `RemoteFileTableView.swift:852`. Window `setFrame` at `ContentView.swift:1565`.

---

## Task 1: Core — split operation and listing refresh

**Files:**
- Modify: `Sources/macSCPCore/Presentation/RemoteBrowserViewModel.swift`
- Test: `Tests/macSCPCoreTests/RemoteBrowserViewModelTests.swift`

**Interfaces:**
- Produces: `public func refreshAndSelect(path: String) async`; `createFolder(named:)` and `rename(_:to:)` keep their signature (`async -> String?`), but no longer refresh the listing themselves.

- [ ] **Step 1: Write the failing test**

Add to `Tests/macSCPCoreTests/RemoteBrowserViewModelTests.swift`. Use the fake FS already present in this file (take the name from the file — **do not invent one**) and count its `list` calls; if the fake has no counter, add one (`private(set) var listCallCount`).

```swift
    // MARK: - Operation does not wait on the listing (M18a)

    @Test func createFolderReturnsWithoutRefreshingTheListing() async {
        let fs = /* Fake FS from this file, with a list counter */
        let vm = /* constructed as in the neighboring tests */
        await vm.load()
        let listsAfterLoad = await fs.listCallCount

        let error = await vm.createFolder(named: "fresh")
        #expect(error == nil)
        // The create must NOT have triggered another listing — dismissing the
        // sheet may not wait on it.
        #expect(await fs.listCallCount == listsAfterLoad)
    }

    @Test func refreshAndSelectRefreshesAndSelectsTheNewEntry() async {
        let fs = /* Fake FS */
        let vm = /* … */
        await vm.load()
        _ = await vm.createFolder(named: "fresh")

        await vm.refreshAndSelect(path: RemotePath.join(vm.currentPath, "fresh"))
        #expect(vm.items.contains { $0.name == "fresh" })
        #expect(vm.selectedItems.map(\.name) == ["fresh"])
    }
```

**Adapt** the existing test `createFolderRefreshesAndSelects` (do not delete it): going forward it calls `createFolder` **and** `refreshAndSelect` and checks the same expectations as before. Same for any rename counterpart test.

- [ ] **Step 2: Test red**

Run: `swift test --filter RemoteBrowserViewModelTests`
Expected: FAIL — `createFolderReturnsWithoutRefreshingTheListing` fails (the listing is still loaded) or `refreshAndSelect` does not exist.

- [ ] **Step 3: Rework `RemoteBrowserViewModel`**

`createFolder(named:)` (~464): replace the block after a successful `createDirectory`

```swift
        await load()
        if let created = items.first(where: { $0.path == path }) {
            selectedItems = [created]
        }
        auditSink?(AuditEvent(kind: .newFolder, detail: detail))
        return nil
```

with

```swift
        // The directory exists once `createDirectory` returns; refreshing the
        // listing is presentation only. Keeping it out of this method means
        // dismissing the sheet never waits on a listing — which can block on
        // a slow server, a huge directory, or a macOS permission prompt
        // (M18a). Callers refresh via `refreshAndSelect(path:)` afterwards.
        auditSink?(AuditEvent(kind: .newFolder, detail: detail))
        return nil
```

`rename(_:to:)` (~445) analogously: remove `await load()` + selection, audit + `return nil` stay.

Add a new method (next to `load()`):

```swift
    /// Refreshes the listing and selects `path` when present. Called after a
    /// successful create/rename so the sheet can dismiss immediately (M18a).
    public func refreshAndSelect(path: String) async {
        await load()
        if let entry = items.first(where: { $0.path == path }) {
            selectedItems = [entry]
        }
    }
```

- [ ] **Step 4: Test green + full suite**

Run: `swift test --filter RemoteBrowserViewModelTests` → PASS.
Then `swift build && swift test` → build 0 warnings, all tests green.

- [ ] **Step 5: Commit**

```bash
git add Sources/macSCPCore/Presentation/RemoteBrowserViewModel.swift Tests/macSCPCoreTests/RemoteBrowserViewModelTests.swift
git commit -m "fix: stop create and rename from waiting on a listing refresh

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Task 2: Core — owner/group only on request

**Files:**
- Modify: `Sources/macSCPCore/RemoteFS/LocalFileSystem.swift`
- Test: `Tests/macSCPCoreTests/LocalFileSystemTests.swift`

**Interfaces:**
- Produces: `LocalFileSystem.init(fetchesOwnerGroup: Bool = false)`.

- [ ] **Step 1: Failing test**

In `Tests/macSCPCoreTests/LocalFileSystemTests.swift` (file exists; reuse the neighboring tests' temp-directory pattern):

```swift
    // MARK: - Owner/group is opt-in (M18a)

    @Test func listOmitsOwnerAndGroupByDefault() async throws {
        let dir = /* Temp directory as in the neighboring tests */
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("x".utf8).write(to: dir.appendingPathComponent("a.txt"))

        let fs = LocalFileSystem()   // default: no owner/group lookup
        let items = try await fs.list(path: dir.path(percentEncoded: false))
        #expect(items.count == 1)
        #expect(items[0].owner == nil)
        #expect(items[0].group == nil)
    }

    @Test func listIncludesOwnerAndGroupWhenRequested() async throws {
        let dir = /* Temp directory */
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("x".utf8).write(to: dir.appendingPathComponent("a.txt"))

        let fs = LocalFileSystem(fetchesOwnerGroup: true)
        let items = try await fs.list(path: dir.path(percentEncoded: false))
        #expect(items[0].owner != nil)
        #expect(items[0].group != nil)
    }
```

Check the field names (`owner`/`group`) against `RemoteFileItem` and take them over exactly.

- [ ] **Step 2: Test red**

Run: `swift test --filter LocalFileSystemTests`
Expected: FAIL — `listOmitsOwnerAndGroupByDefault` fails (owner/group are populated) or the initializer does not exist.

- [ ] **Step 3: Implement**

`LocalFileSystem` gets a stored `let fetchesOwnerGroup: Bool` with
`init(fetchesOwnerGroup: Bool = false)`. Since `item(for:)` is `static` today,
the switch has to be threaded through to it — either extend `item(for:)` with
an extra parameter (`static func item(for url: URL, fetchesOwnerGroup: Bool)`)
and pass it at every call site (`list` ~59, `stat` ~71), or turn `item` into
an instance method. Pick whichever variant produces the smaller diff and
adapt **all** call sites.

In `ownerGroup(for:)`, run the `attributesOfItem` call only when the switch is
on; otherwise `(nil, nil)` with no syscall. Document **why** in the doc
comment: one syscall per entry, and on protected folders
(Desktop/Documents/Downloads) it triggers blocking macOS permission dialogs
(M18a finding).

- [ ] **Step 4: Test green + full suite**

Run: `swift test --filter LocalFileSystemTests` → PASS. Then `swift build && swift test` → 0 warnings, green.

- [ ] **Step 5: Commit**

```bash
git add Sources/macSCPCore/RemoteFS/LocalFileSystem.swift Tests/macSCPCoreTests/LocalFileSystemTests.swift
git commit -m "perf: look up local owner and group only when asked

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Task 3: Core — `createFile`

**Files:**
- Modify: `Sources/macSCPCore/Presentation/RemoteBrowserViewModel.swift`
- Modify: `Sources/macSCPCore/Presentation/BrowserContextMenu.swift` (menu entry `newFile`)
- Test: `Tests/macSCPCoreTests/RemoteBrowserViewModelTests.swift`

**Interfaces:**
- Consumes: `refreshAndSelect(path:)` (Task 1), `RemoteFileSystem.write(path:mode:contents:)`.
- Produces: `public func createFile(named name: String) async -> String?`; `BrowserMenuEntry.newFile`.

- [ ] **Step 1: Failing test**

```swift
    // MARK: - createFile (M18a)

    @Test func createFileCreatesAnEmptyFileAndReportsSuccess() async {
        let fs = /* Fake FS */
        let vm = /* … */
        await vm.load()

        let error = await vm.createFile(named: "notes.txt")
        #expect(error == nil)
        await vm.refreshAndSelect(path: RemotePath.join(vm.currentPath, "notes.txt"))
        #expect(vm.items.contains { $0.name == "notes.txt" })
    }

    @Test func createFileCollisionReturnsError() async {
        let fs = /* Fake FS with an existing entry "taken.txt" */
        let vm = /* … */
        await vm.load()
        let error = await vm.createFile(named: "taken.txt")
        #expect(error != nil)
    }
```

Also add an audit test analogous to `createFolderSuccessFiresNewFolderEventWithFullPath` (take the pattern from the same file).

- [ ] **Step 2: Test red**

Run: `swift test --filter RemoteBrowserViewModelTests`
Expected: FAIL — "value of type 'RemoteBrowserViewModel' has no member 'createFile'".

- [ ] **Step 3: Implement `createFile`**

Right next to `createFolder`, with the **same** collision check (`stat` probe,
because it also sees hidden entries) and the same error contract. Instead of
`createDirectory`, an empty file is written:

```swift
    /// Creates an empty file in the current directory. Same collision probe
    /// and error contract as `createFolder(named:)`; like it, this does NOT
    /// refresh the listing — callers use `refreshAndSelect(path:)` (M18a).
    public func createFile(named name: String) async -> String? {
        let path = RemotePath.join(currentPath, name)
        let detail = "create \(path)"
        if (try? await fs.stat(path: path)) != nil {
            let message = Self.message(
                for: RemoteFSError.protocolError(reason: "destination already exists: \(path)"),
                path: path)
            auditSink?(AuditEvent(kind: .newFile, detail: detail, isError: true, errorMessage: message))
            return message
        }
        do {
            let empty = AsyncThrowingStream<Data, Error> { $0.finish() }
            try await fs.write(path: path, mode: .overwrite, contents: empty)
        } catch {
            let message = Self.message(for: error, path: path)
            auditSink?(AuditEvent(kind: .newFile, detail: detail, isError: true, errorMessage: message))
            return message
        }
        auditSink?(AuditEvent(kind: .newFile, detail: detail))
        return nil
    }
```

Check the exact `write` signature and the empty stream against
`RemoteFileSystem` and existing callers (e.g. how `EditSessionManager`
writes) and take them over. `AuditEvent.Kind` needs a new case `newFile` —
add it and adapt **all** exhaustive `switch` sites (among others
`Sources/MacSCPApp/AuditLogSheet.swift:229`, where `.rename, .delete, .permissions, .newFolder`
are handled together).

- [ ] **Step 4: Menu entry in the model**

In `BrowserContextMenu.swift` add `case newFile` next to `case newFolder` (:34)
— the same availability rule (also on a click in the empty area). Extend the
place that assembles the entries accordingly, and carry along the
corresponding menu-assembly tests (find the file with the
`BrowserContextMenu` tests and add to the existing expectations).

- [ ] **Step 5: Test green + full suite**

Run: `swift test` → all green, build 0 warnings.

- [ ] **Step 6: Commit**

```bash
git add Sources/macSCPCore Tests/macSCPCoreTests
git commit -m "feat: create an empty file from the browser

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Task 4: App — stop the dialog from waiting, "New File…", owner/group flag

**Files:**
- Modify: `Sources/MacSCPApp/BrowserPane.swift`
- Modify: `Sources/MacSCPApp/RemoteFileTableView.swift`
- Modify: `Sources/MacSCPApp/ContentView.swift`
- Modify: `Sources/MacSCPApp/Resources/{en,de,fr,pl}.lproj/Localizable.strings`

**Interfaces:**
- Consumes: `refreshAndSelect(path:)`, `createFile(named:)`, `BrowserMenuEntry.newFile` (Tasks 1–3), `LocalFileSystem(fetchesOwnerGroup:)` (Task 2).

Pure app wiring — build-verified.

- [ ] **Step 1: New Folder sheet no longer waits**

In `BrowserPane.swift`, change the New Folder sheet's `onConfirm` (~257) so
that after success it refreshes **without waiting**:

```swift
                onConfirm: { name in
                    let error = await viewModel.createFolder(named: name)
                    if error == nil {
                        // Dismiss immediately; the listing refresh must not
                        // hold the sheet open (M18a).
                        let path = RemotePath.join(viewModel.currentPath, name)
                        Task { await viewModel.refreshAndSelect(path: path) }
                    }
                    return error
                })
```

Adapt the rename sheet (~250) analogously (its target path is
`RemotePath.join(viewModel.currentPath, newName)`).

- [ ] **Step 2: "New File…" sheet + trigger**

Add `@State private var showNewFileSheet = false`; in the menu callback add
`case .newFile: showNewFileSheet = true` (next to `.newFolder`, ~191); a
further `.sheet(isPresented: $showNewFileSheet)` with `NameEntrySheet`
(title `sheet.newFile.title`, confirm `sheet.newFile.confirm`,
default name `sheet.newFile.defaultName`) and the same non-waiting pattern
from Step 1, but using `viewModel.createFile(named:)`.

In `RemoteFileTableView.swift`, render the new case (at ~852 next to
`.newFolder`), title `menu.newFile`.

- [ ] **Step 3: Set the owner/group flag**

In `ContentView.swift`, at both `LocalFileSystem()` sites (:1908, :1910),
derive the switch from the visible columns, e.g.:

```swift
let wantsOwnerGroup = settingsStore.visibleColumns.contains(.owner)
    || settingsStore.visibleColumns.contains(.group)
```

and pass `LocalFileSystem(fetchesOwnerGroup: wantsOwnerGroup)`. Take the real
names of the column enum and the settings access from the code (check the
`FileColumn` cases). `EditSessionManager` (Core) stays on the default
(no owner/group needed).

- [ ] **Step 4: L10n**

New keys in **all four** catalogs (typographic, no ASCII quote in
non-English values):

EN:
```
"menu.newFile" = "New File…";
"sheet.newFile.title" = "New File";
"sheet.newFile.confirm" = "Create";
"sheet.newFile.defaultName" = "untitled.txt";
```
DE:
```
"menu.newFile" = "Neue Datei…";
"sheet.newFile.title" = "Neue Datei";
"sheet.newFile.confirm" = "Erstellen";
"sheet.newFile.defaultName" = "unbenannt.txt";
```
FR:
```
"menu.newFile" = "Nouveau fichier…";
"sheet.newFile.title" = "Nouveau fichier";
"sheet.newFile.confirm" = "Créer";
"sheet.newFile.defaultName" = "sans-titre.txt";
```
PL:
```
"menu.newFile" = "Nowy plik…";
"sheet.newFile.title" = "Nowy plik";
"sheet.newFile.confirm" = "Utwórz";
"sheet.newFile.defaultName" = "bez-nazwy.txt";
```

- [ ] **Step 5: Build + behavior**

Run: `swift build && swift test --filter Localizable`
Expected: 0 (new) warnings, parity green. Behavior via code reading: creating a
folder/file dismisses the dialog immediately; errors still keep it open; the
listing refreshes shortly after.

- [ ] **Step 6: Commit**

```bash
git add Sources/MacSCPApp
git commit -m "fix: dismiss the browser name sheet without waiting for the listing

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Task 5: Investigate the window frame (and clamp only if we caused it)

**Files:**
- Investigate/Modify: `Sources/MacSCPApp/ContentView.swift` (~1540–1570)

- [ ] **Step 1: Establish the cause**

A restored window frame at `{-101, -1386}` was observed (off every screen).
**First clarify who sets the frame:**
- Read the block around `window.setFrame(newFrame, display: true, animate: true)` (`ContentView.swift:1565`), including how `newFrame` is derived (M5c: growing to the remembered browser size). Can that produce a frame outside the visible area (e.g. because only the size is remembered, while the origin comes from the current window)?
- Check whether the app does its own window restoration or whether this is macOS' own restoration (search for `frameAutosaveName`, `NSWindowRestoration`, `restorationClass`, saved frame values in the SettingsStore).

Record in the report **what you established**.

- [ ] **Step 2: Clamp only if we caused it**

If it is our `setFrame`: clamp the target frame to the visible area before
setting it — screen via `window.screen ?? NSScreen.main`, area
`visibleFrame`, shift the origin so the frame lies fully visible (and, if
necessary, cap the size to the area). If the logic fits into a small pure
function (`func clamped(_ frame: NSRect, to visible: NSRect) -> NSRect`),
write it as such and test it:

```swift
    @Test func frameOutsideVisibleAreaIsMovedBack() {
        let visible = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let offscreen = NSRect(x: -101, y: -1386, width: 1200, height: 800)
        let result = clamped(offscreen, to: visible)
        #expect(visible.contains(result))
    }
```

If it is **macOS' own** restoration: **do not** work around it — document
this in the report and close this task with no code change.

- [ ] **Step 3: Build + commit (if changed)**

Run: `swift build && swift test`
Expected: 0 warnings, green.

```bash
git add Sources/MacSCPApp/ContentView.swift Tests/macSCPCoreTests
git commit -m "fix: keep the restored window frame on screen

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Task 6: Close-out

- [ ] **Step 1: Full suite + 0 warnings**

Run: `swift build && swift test && swift test --filter Localizable`
Expected: everything green, no new warnings.

- [ ] **Step 2: Runtime verification of the bug**

Build a dev build (`MACSCP_VERSION=1.8.1-dev scripts/package-app`), launch
it, and in the **local** pane create a folder **and** a file: the dialog must
close **immediately**, the entry then appears in the listing afterwards.
Also measure idle CPU (~0 %).

- [ ] **Step 3: Whole-milestone review**

Opus review over `git merge-base develop HEAD`..HEAD (base = `a496a66`),
focus: error behavior unchanged (errors keep the dialog open), audit
complete, no protocol change, tests adapted rather than deleted.

- [ ] **Step 4: Push + dev build (on maintainer instruction)**

---

## Self-Review

**1. Spec coverage:** A (dialog does not wait) → Task 1 + Task 4 Step 1 ✅ · B (owner/group opt-in) → Task 2 + Task 4 Step 3 ✅ · C ("New File") → Task 3 + Task 4 Steps 2/4 ✅ · D (window) → Task 5 ✅ · Tests → in every task ✅ · Invariants → Global Constraints + Task 6 ✅

**2. Placeholder scan:** Deliberately left open with a clear "take over the real names" instruction: fake-FS name and construction in the VM tests, `RemoteFileItem` field names, `write` signature/empty stream, column-enum cases, the `AuditEvent.Kind` switch sites, and the real cause in Task 5. No "TBD/TODO".

**3. Type consistency:** `refreshAndSelect(path:)`, `createFile(named:) -> String?`, `LocalFileSystem(fetchesOwnerGroup:)`, `BrowserMenuEntry.newFile`, `AuditEvent.Kind.newFile` — used consistently across all tasks.
