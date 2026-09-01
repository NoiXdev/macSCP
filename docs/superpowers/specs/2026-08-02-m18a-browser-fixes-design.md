# M18a — Browser fixes & "New File" (design/spec)

**Date:** 2026-08-02
**Status:** approved (maintainer), ready for writing-plans
**Branch:** `develop`
**Occasion:** maintainer bug report in dev build v1.8.0-dev + one small feature gap.

## Goal

Four small, independent points from everyday use: the hanging new-folder
dialog, its root cause in listing, a missing "New File" action, and an
observed off-screen window restoration.

## Finding (reproduced, proven)

**Symptom:** "When you create a folder, the dialog no longer goes away."

**Reproduced** in the running dev build (local pane, UI scripting): the
folder gets created, **no** error text appears, the dialog stays up with a
spinner (`isWorking == true`) — and closes correctly right away as soon as
three macOS **TCC permission dialogs** appearing in sequence ("access to
Desktop/Documents/Downloads") are confirmed.

**Root-cause chain:**
1. `RemoteBrowserViewModel.createFolder(named:)` (`Sources/macSCPCore/Presentation/RemoteBrowserViewModel.swift:464`) calls **`await load()`** after a successful `createDirectory`, before returning `nil`.
2. `load()` → `LocalFileSystem.list(path:)` (`Sources/macSCPCore/RemoteFS/LocalFileSystem.swift:59`) sends **every** entry through `item(for:)` → `ownerGroup(for:)` (`:302`) → a `FileManager.attributesOfItem` call **per entry** — regardless of whether the owner/group columns are even visible (M11m).
3. If this hits a TCC-protected folder (Desktop/Documents/Downloads), macOS blocks with system dialogs.
4. `NameEntrySheet.confirm()` (`Sources/MacSCPApp/BrowserSheets.swift:47`) awaits `await onConfirm(...)` and only calls `dismiss()` afterward → the dialog appears frozen.

**Ruled out:** not a SwiftUI `dismiss()` bug (the dialog closes correctly
as soon as `load()` returns); not a bug in `createFolder`'s return value
(tests green); not an issue with stacked `.sheet` modifiers (ContentView
stacks eight of them working correctly).

**Why now:** A freshly built dev build is a new app as far as TCC is
concerned — the prompts appear again. Presumably they went unnoticed
because the window was restored outside the visible area (see D).

## Scope

### A — Dialog no longer waits on the reload (the actual bug)

The folder is done as soon as `createDirectory` returns; reloading the
list is a pure display refresh. Tying the close to that hits a slow SFTP
server or a very large directory just as hard.

**Change (Core):** `createFolder(named:)` and `rename(_:to:)` will from
now on **only perform the operation** (including collision check and
audit event) and return immediately. Reloading, including selecting the
new entry, moves into its own, likewise awaitable method:

```swift
/// Refreshes the listing and selects `path` if present. Called after a
/// successful create/rename so dismissing the sheet never waits on a listing.
public func refreshAndSelect(path: String) async
```

**Change (App):** The `onConfirm` call in `BrowserPane` now only awaits
the operation; on success, `refreshAndSelect` is started in its own
`Task`, **without** awaiting it. The dialog thus closes immediately.

Both paths stay individually awaitable in Core and thus testable — the
existing tests are adjusted accordingly (operation and refresh checked
separately), not deleted.

### B — Fetch owner/group only when the columns are visible

`LocalFileSystem` gets `init(fetchesOwnerGroup: Bool = false)`. When it is
`false` (default), the `attributesOfItem` call per entry drops out
entirely: no unnecessary syscalls, no TCC prompts. The App sets it to "on"
when creating the local view **if** the owner or group column is visible
in settings.

The protocol stays unchanged (no `list` parameter): SFTP delivers
owner/group for free from the `longname` anyway, S3 has no such concept —
only local file access pays this cost.

### C — "New File…" in the context menu

New menu entry `newFile` (analogous to `newFolder`, also on clicking the
empty area), new Core action:

```swift
/// Creates an empty file in the current directory. Same collision probe and
/// error contract as `createFolder(named:)`.
public func createFile(named name: String) async -> String?
```

It creates the file via the `RemoteFileSystem`'s existing `write` path
with empty content — thus working the same for local, SFTP, and S3. UI:
the same `NameEntrySheet` as "New Folder" (title/confirmation text and
default name its own), the same no-waiting rule from A.

### D — Off-screen window restoration (investigate first)

Observed: the app window was restored at `{-101, -1386}` after a restart,
i.e. outside all screens. **Root cause not established** — it could be
macOS's own window restoration, or our own `window.setFrame`
(`Sources/MacSCPApp/ContentView.swift:1565`, growing to the remembered
browser size from M5c).

Approach: first establish who sets the frame. If it is our code, the
resulting frame gets clamped to the visible area (`NSScreen.visibleFrame`
of the nearest screen). If it is macOS's restoration, that gets documented
and **not** blindly worked around.

## Tests

- **A:** `createFolder`/`rename` return after the operation, **without**
  having loaded the list (fake FS counts `list` calls); `refreshAndSelect`
  updates and selects. The existing expectations (collision → error text,
  audit event, selection after refresh) are kept, just split across the
  two steps.
- **B:** `LocalFileSystem(fetchesOwnerGroup: false).list(...)` delivers
  entries **without** owner/group and does not call `attributesOfItem`
  (checkable via a directory whose entries would otherwise have
  owner/group); with `true` they are filled in.
- **C:** `createFile` creates an empty file, reports collisions with the
  same error contract as `createFolder`, and fires an audit event.
- **D:** depending on the finding — for our own code, a test of the
  clamping function (frame off-screen → corrected to the visible area).
- App: build-verified, catalog parity, idle-CPU smoke test.

## Invariants

- No changed error behavior: collisions and errors still appear **in**
  the dialog (which then stays open).
- Audit events (`newFolder`, `rename`, new `newFile`) are kept, or follow
  the same pattern.
- No new external dependency; no protocol change to `RemoteFileSystem`.
- UI strings EN/DE/FR/PL, typographic.

## Not in M18a

- Further owner/group optimizations for SFTP/S3 (the cost does not arise
  there).
- A general "action without waiting" rework for other sheets (info/
  permissions deliberately stay synchronous, they show their result in
  the dialog).

## Files affected

- `Sources/macSCPCore/Presentation/RemoteBrowserViewModel.swift` — **modify** (A: split operation/refresh; C: `createFile`).
- `Sources/macSCPCore/RemoteFS/LocalFileSystem.swift` — **modify** (B: `fetchesOwnerGroup`).
- `Sources/macSCPCore/Presentation/BrowserContextMenu.swift` — **modify** (C: `newFile` entry).
- `Sources/MacSCPApp/BrowserPane.swift` — **modify** (A: don't wait; C: sheet + trigger).
- `Sources/MacSCPApp/RemoteFileTableView.swift` — **modify** (C: render menu entry).
- `Sources/MacSCPApp/ContentView.swift` — **modify** (B: set flag; D: clamping if applicable).
- `Sources/MacSCPApp/Resources/{en,de,fr,pl}.lproj/Localizable.strings` — **modify**.
- `Tests/macSCPCoreTests/…` — tests for A, B, C (and D, if own code).
