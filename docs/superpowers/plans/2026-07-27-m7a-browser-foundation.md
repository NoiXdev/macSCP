# M7a — Browser Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Three new FS APIs (`rename`, `setPermissions`, recursive `deleteTree`), Finder-like multi-select, and the "hidden files" switch — the foundation M7b builds the context menu on.

**Architecture:** Protocol extension on `RemoteFileSystem` with implementations in `LocalFileSystem` (FileManager) and `CitadelFileSystem` (SFTP rename/setstat + bottom-up walk); all test doubles follow along. Multi-select replaces `selectedItem` with an ordered `selectedItems` array (with `selectedItem` as a derived convenience). The hidden-files filter lives as a display filter in `RemoteBrowserViewModel`, fed from a new `SettingsStore` field; ⌘⇧. arrives as an app command (View menu).

**Tech Stack:** Swift 6 / `.swiftLanguageMode(.v5)`, Swift Testing, Citadel SFTP (`rename(at:to:)`, `setAttributes(at:to:)`), AppKit `NSTableView` in the representable.

## Global Constraints

- Spec: `docs/superpowers/specs/2026-07-27-m7a-browser-foundation-design.md` — binding. Branch: **develop**.
- `rename(from:to:)`: `to` is the FULL destination path; an existing destination ⇒ error, NO silent overwrite.
- `setPermissions`: only the low 12 bits (`permissions & 0o7777`), never write the type bits.
- `deleteTree`: symlinks are DELETED, NEVER followed; cooperatively cancellable (`Task.checkCancellation` per entry); a cancellation leaves a partially deleted tree (documented).
- Hidden filter: display layer (ViewModel), criterion `name.hasPrefix(".")`; `SettingsStore.showHiddenFiles` default `false`.
- Security/architecture/queue invariants untouched; code + comments English ONLY; new UI text cataloged EN/DE (app: `Sources/MacSCPApp/Resources/*/Localizable.strings`).
- Conventional Commits (English), footer: `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- `swift build` + full `swift test` green after every task (starting point 317 tests / 28 suites); gated suites (`MACSCP_ITEST=1`, Docker rig from the main checkout) ONLY at close-out.
- TDD: prove new logic red first.
- Environment note: bash errors "claude-opus-4-8 is temporarily unavailable … cannot determine the safety" are NOT permission denials — wait and retry identically.

## Schedule

T1 → T2 (core FS, T2 RISK) → T3 → T4 (app layer) → T5 close-out (coordinator).

---

### Task 1: FS APIs `rename` + `setPermissions`

**Files:**
- Modify: `Sources/macSCPCore/RemoteFS/RemoteFileSystem.swift` (protocol, after `delete` line 34)
- Modify: `Sources/macSCPCore/RemoteFS/LocalFileSystem.swift` (after `delete`, lines ~108–123 as pattern)
- Modify: `Sources/macSCPCore/SSH/CitadelFileSystem.swift` (after `delete` line ~290)
- Modify: `Tests/macSCPCoreTests/MockRemoteFileSystem.swift` (after `createDirectory` line ~104) and EVERY other `RemoteFileSystem`-conforming test double: grep `git grep -ln ": RemoteFileSystem" Tests` — currently `TransferQueueViewModelTests.swift` (`QueueTestFS`), `TransferEngineTests.swift`, `EditSessionManagerTests.swift`, `RemoteBrowserViewModelTests.swift` (conformance stubs analogous to `delete`)
- Test: `Tests/macSCPCoreTests/LocalFileSystemTests.swift`, `Tests/macSCPCoreTests/CitadelFileSystemIntegrationTests.swift` (gated)

**Interfaces:**
- Produces (T2/M7b rely on this exactly):
  - `func rename(from: String, to: String) async throws`
  - `func setPermissions(path: String, permissions: UInt32) async throws`

- [x] **Step 1: Extend the protocol** — in `RemoteFileSystem.swift` after `delete`:

```swift
    /// Renames/moves the entry at `from` to the FULL destination path `to`.
    /// An existing destination is an error (`RemoteFSError`) — this call
    /// never silently overwrites. The UI builds same-directory paths for a
    /// rename; the protocol stays generic (M7a).
    func rename(from: String, to: String) async throws

    /// Sets the POSIX permission bits of the entry at `path`. Only the low
    /// 12 bits (rwx for owner/group/other + setuid/setgid/sticky) are
    /// applied — file-type bits are never written (M7a).
    func setPermissions(path: String, permissions: UInt32) async throws
```

- [x] **Step 2: Failing unit tests (local)** — in `LocalFileSystemTests.swift` (reuse the file's existing tmp-dir pattern):

```swift
    @Test func renameMovesFileAndRefusesExistingDestination() async throws {
        let dir = try makeTempDir()
        let fs = LocalFileSystem()
        let a = dir.appendingPathComponent("a.txt").path(percentEncoded: false)
        let b = dir.appendingPathComponent("b.txt").path(percentEncoded: false)
        try Data("x".utf8).write(to: URL(fileURLWithPath: a))
        try await fs.rename(from: a, to: b)
        #expect(!FileManager.default.fileExists(atPath: a))
        #expect(FileManager.default.fileExists(atPath: b))
        // Existing destination must be refused, source stays put.
        try Data("y".utf8).write(to: URL(fileURLWithPath: a))
        await #expect(throws: RemoteFSError.self) {
            try await fs.rename(from: a, to: b)
        }
        #expect(FileManager.default.fileExists(atPath: a))
    }

    @Test func renameMissingSourceThrowsNotFound() async throws {
        let dir = try makeTempDir()
        let fs = LocalFileSystem()
        await #expect(throws: RemoteFSError.self) {
            try await fs.rename(
                from: dir.appendingPathComponent("missing").path(percentEncoded: false),
                to: dir.appendingPathComponent("target").path(percentEncoded: false))
        }
    }

    @Test func setPermissionsAppliesLow12BitsOnly() async throws {
        let dir = try makeTempDir()
        let fs = LocalFileSystem()
        let f = dir.appendingPathComponent("p.txt").path(percentEncoded: false)
        try Data("x".utf8).write(to: URL(fileURLWithPath: f))
        // Type bits in the argument must be ignored (0o100000 = regular file).
        try await fs.setPermissions(path: f, permissions: 0o100640)
        let mode = try FileManager.default.attributesOfItem(atPath: f)[.posixPermissions] as? Int
        #expect(mode == 0o640)
    }
```

(If the file has no `makeTempDir` helper, take over the file's existing tmp-setup style — assertions unchanged.)

- [x] **Step 3: Prove red** — `swift test --filter LocalFileSystemTests` ⇒ compile error (protocol conformers incomplete) = red.
- [x] **Step 4: Implement local** — in `LocalFileSystem.swift` (errors via the existing `Self.map(error, path:)`):

```swift
    /// Renames/moves to the FULL destination path. Refuses an existing
    /// destination — `moveItem` would too, but the explicit check yields a
    /// stable, mapped error instead of a Foundation-specific one.
    public func rename(from: String, to: String) async throws {
        guard FileManager.default.fileExists(atPath: from) else {
            throw RemoteFSError.notFound(path: from)
        }
        guard !FileManager.default.fileExists(atPath: to) else {
            throw RemoteFSError.protocolError(reason: "destination already exists: \(to)")
        }
        do {
            try FileManager.default.moveItem(atPath: from, toPath: to)
        } catch {
            throw Self.map(error, path: from)
        }
    }

    /// Applies only the low 12 permission bits; type bits are stripped.
    public func setPermissions(path: String, permissions: UInt32) async throws {
        guard FileManager.default.fileExists(atPath: path) else {
            throw RemoteFSError.notFound(path: path)
        }
        do {
            try FileManager.default.setAttributes(
                [.posixPermissions: Int(permissions & 0o7777)], ofItemAtPath: path)
        } catch {
            throw Self.map(error, path: path)
        }
    }
```

- [x] **Step 5: Implement Citadel** — in `CitadelFileSystem.swift` (errors via `Self.mapSFTPError(_:path:)`; explicit collision check because OpenSSH rename may overwrite depending on the server):

```swift
    /// Renames/moves to the FULL destination path. The explicit existence
    /// probe keeps the no-silent-overwrite contract server-independent
    /// (SFTP rename semantics differ between servers).
    public func rename(from: String, to: String) async throws {
        if (try? await sftp.getAttributes(at: to)) != nil {
            throw RemoteFSError.protocolError(reason: "destination already exists: \(to)")
        }
        do {
            try await sftp.rename(at: from, to: to)
        } catch {
            throw Self.mapSFTPError(error, path: from)
        }
    }

    /// Sets only the low 12 permission bits via SFTP setstat.
    public func setPermissions(path: String, permissions: UInt32) async throws {
        var attributes = SFTPFileAttributes()
        attributes.permissions = permissions & 0o7777
        do {
            try await sftp.setAttributes(at: path, to: attributes)
        } catch {
            throw Self.mapSFTPError(error, path: path)
        }
    }
```

(Check: if `SFTPFileAttributes` has no argument-less `public init`, use
`SFTPFileAttributes(size: nil, uidgid: nil, permissions: permissions & 0o7777, accessModificationTime: nil)`
or whichever init form actually exists — behavior identical, note it in the
report.)

- [x] **Step 6: Carry the doubles along** — `MockRemoteFileSystem` gets working in-memory variants (move the files dictionary; keep permissions in a `var permissionsByPath: [String: UInt32]`), the remaining test doubles get minimal stubs in the style of their existing `delete` (e.g. `throw RemoteFSError.protocolError(reason: "unsupported in this test double")` where it is never called).
- [x] **Step 7: Gated integration tests** — in `CitadelFileSystemIntegrationTests.swift` (file pattern: `MACSCP_ITEST` gate, own UUID path under `/config`, cleanup via docker-exec):

```swift
    @Test func renameAndSetPermissionsRoundtrip() async throws {
        // rename: upload a file, rename it, list shows only the new name;
        // renaming onto an existing name throws.
        // setPermissions: chmod 0o640, re-stat, permissions & 0o7777 == 0o640.
    }
```

The test is spelled out IN FULL (no comment scaffold) following the existing
`delete` integration tests in the same file; assertions: listing
before/after, `#expect(throws:)` for the collision, `stat` permissions
comparison.

- [x] **Step 8: Green** — full `swift test` (ungated; the gated tests compile but only run in T5).
- [x] **Step 9: Commit** — `feat: add rename and setPermissions to the file-system protocol`.

---

### Task 2: `deleteTree` (RISK)

**Files:**
- Modify: `Sources/macSCPCore/RemoteFS/RemoteFileSystem.swift`, `LocalFileSystem.swift`, `CitadelFileSystem.swift`, all test doubles (as in T1)
- Test: `Tests/macSCPCoreTests/LocalFileSystemTests.swift`, `Tests/macSCPCoreTests/MockRemoteFileSystemTests.swift`, `CitadelFileSystemIntegrationTests.swift` (gated)

**Interfaces:**
- Consumes: T1 merged (protocol state).
- Produces: `func deleteTree(at path: String) async throws` — M7b calls exactly this name.

- [x] **Step 1: Protocol** — after `setPermissions`:

```swift
    /// Recursively deletes the entry at `path` (file, symlink, or directory
    /// with its entire contents). Symlinks are deleted, NEVER followed — the
    /// walk cannot escape the subtree. Cooperatively cancellable per entry;
    /// a cancellation leaves a partially deleted tree in place (documented,
    /// M7a). A plain file behaves exactly like `delete`.
    func deleteTree(at path: String) async throws
```

- [x] **Step 2: Failing tests** — local (`LocalFileSystemTests.swift`):

```swift
    @Test func deleteTreeRemovesNestedDirectoryButNeverFollowsSymlinks() async throws {
        let dir = try makeTempDir()
        let fs = LocalFileSystem()
        // outside/victim.txt must SURVIVE: tree/link points at outside.
        let outside = dir.appendingPathComponent("outside", isDirectory: true)
        let victim = outside.appendingPathComponent("victim.txt")
        let tree = dir.appendingPathComponent("tree", isDirectory: true)
        let sub = tree.appendingPathComponent("sub", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: victim)
        try Data("x".utf8).write(to: sub.appendingPathComponent("f.txt"))
        try FileManager.default.createSymbolicLink(
            at: tree.appendingPathComponent("link"), withDestinationURL: outside)

        try await fs.deleteTree(at: tree.path(percentEncoded: false))

        #expect(!FileManager.default.fileExists(atPath: tree.path(percentEncoded: false)))
        #expect(FileManager.default.fileExists(atPath: victim.path(percentEncoded: false)))
    }
```

Mock (`MockRemoteFileSystemTests.swift`): build a tree in the in-memory mock,
`deleteTree`, `list` of the parent no longer shows the entry; plus a
cancellation test against the CITADEL walk belongs in the gated suite (Step 5).

- [x] **Step 3: Prove red**, then **implement local** (a symlink check BEFORE removeItem is unnecessary — `removeItem` does not follow symlinks, it deletes the link; document exactly that):

```swift
    /// Recursive delete. `FileManager.removeItem` is natively recursive and
    /// removes symlinks WITHOUT following them, which matches the protocol
    /// contract exactly. Cancellation granularity is the whole call here
    /// (Foundation offers no per-entry hook) — acceptable for local trees.
    public func deleteTree(at path: String) async throws {
        try Task.checkCancellation()
        guard FileManager.default.fileExists(atPath: path)
            || (try? FileManager.default.attributesOfItem(atPath: path)) != nil else {
            throw RemoteFSError.notFound(path: path)
        }
        do {
            try FileManager.default.removeItem(atPath: path)
        } catch {
            throw Self.map(error, path: path)
        }
    }
```

(Note for the implementer: `fileExists` follows symlinks — the secondary
`attributesOfItem` check catches dangling symlinks, which must still be
deletable.)

- [x] **Step 4: Implement Citadel** — bottom-up walk:

```swift
    /// Recursive delete via bottom-up walk: SFTP has no recursive remove.
    /// Files and symlinks go through `remove` (a symlink is removed as the
    /// link itself — never followed, the walk descends only into REAL
    /// directories per the listed entry kind); directories are emptied
    /// first, then removed with rmdir. Cooperatively cancellable per entry;
    /// cancellation leaves a partially deleted tree (documented).
    public func deleteTree(at path: String) async throws {
        try Task.checkCancellation()
        let entry: RemoteFileItem
        do {
            entry = try await stat(path: path)
        } catch {
            throw Self.mapSFTPError(error, path: path)
        }
        guard entry.kind == .directory else {
            try await delete(path: path)
            return
        }
        let children: [RemoteFileItem]
        do {
            children = try await sftp.listDirectory(atPath: path)
                .flatMap { $0.components }
                .filter { $0.filename != "." && $0.filename != ".." }
                .map { Self.item(fromComponent: $0, parent: path) }
        } catch {
            throw Self.mapSFTPError(error, path: path)
        }
        for child in children {
            try Task.checkCancellation()
            if child.kind == .directory {
                try await deleteTree(at: child.path)
            } else {
                try await delete(path: child.path)
            }
        }
        do {
            try await sftp.rmdir(at: path)
        } catch {
            throw Self.mapSFTPError(error, path: path)
        }
    }
```

IMPORTANT: the file already has a `list` implementation that maps components
to `RemoteFileItem` — reuse its existing mapping helper instead of
reinventing `Self.item(fromComponent:parent:)` (take the exact name from the
file; if no separate helper exists, call `list(path:)` itself). Check the
`rmdir` signature against Citadel (`rmdir(at:)` — take over the actual
parameter labels). Document any deviations in the report.

- [x] **Step 5: Gated tests** (`CitadelFileSystemIntegrationTests.swift`): (a) nested tree (2 levels, files + empty subdirectory + symlink POINTING at a file outside the tree, created via docker-exec `ln -s`) → `deleteTree` → tree gone, symlink TARGET still exists (docker-exec `test -f`); (b) cancellation: build a large tree (docker-exec, ~50 files), start `deleteTree` in a task, cancel immediately → throws `CancellationError` (or completes normally if the walk was faster — assertion tolerant like the file's existing cancel tests) and server state is consistent (the remainder can be cleaned up with a second `deleteTree`).
- [x] **Step 6: Carry the doubles along** (mock: recursive from the dictionary; remaining stubs as in T1).
- [x] **Step 7: Green** — full `swift test`.
- [x] **Step 8: Commit** — `feat: add recursive deleteTree to the file-system protocol`.

---

### Task 3: Multi-select

**Files:**
- Modify: `Sources/MacSCPApp/RemoteFileTableView.swift` (line 30 `allowsMultipleSelection`, selection callback lines 12, 68, 86–94, 179–180)
- Modify: `Sources/macSCPCore/Presentation/RemoteBrowserViewModel.swift` (lines 19–21, `load()` line 32)
- Modify: `Sources/MacSCPApp/ContentView.swift` (`uploadButton`/`downloadButton`, `pasteboardWriter` call sites stay — NSTableView delivers multi-drag automatically per row)
- Test: `Tests/macSCPCoreTests/RemoteBrowserViewModelTests.swift`

**Interfaces:**
- Produces: `RemoteBrowserViewModel.selectedItems: [RemoteFileItem]` (ordered, source of truth) and `selectedItem: RemoteFileItem?` as a derived convenience (`selectedItems.count == 1 ? selectedItems[0] : nil`) — M7b uses BOTH.

- [x] **Step 1: Failing VM test:**

```swift
    @Test @MainActor func selectedItemDerivesFromSelectedItems() async {
        let vm = RemoteBrowserViewModel(fs: MockRemoteFileSystem())
        let a = RemoteFileItem(name: "a", path: "/a", kind: .file, size: 1)
        let b = RemoteFileItem(name: "b", path: "/b", kind: .file, size: 1)
        vm.selectedItems = [a]
        #expect(vm.selectedItem == a)
        vm.selectedItems = [a, b]
        #expect(vm.selectedItem == nil)
        vm.selectedItems = []
        #expect(vm.selectedItem == nil)
    }
```

- [x] **Step 2: Red, then rework the VM:**

```swift
    /// Currently selected entries, in table order (M7a multi-select).
    /// The single source of truth for selection.
    public var selectedItems: [RemoteFileItem] = []

    /// Single-selection convenience: non-nil exactly when ONE row is
    /// selected. Double-click/editor paths keep using this.
    public var selectedItem: RemoteFileItem? {
        selectedItems.count == 1 ? selectedItems[0] : nil
    }
```

`load()` sets `selectedItems = []` (instead of `selectedItem = nil`).
ATTENTION: `selectedItem` used to be settable (`public var`) — grep all
assignments (`git grep -n "selectedItem =" Sources Tests`) and switch them
over to `selectedItems`.

- [x] **Step 3: Table** — `allowsMultipleSelection = true` (line 30); the callback type becomes `onSelect: ([RemoteFileItem]) -> Void`; in `tableViewSelectionDidChange`:

```swift
            let rows = table.selectedRowIndexes
            onSelect(rows.compactMap { $0 < items.count ? items[$0] : nil })
```

Call sites in `BrowserPane`/`ContentView` bind `viewModel.selectedItems = $0`.

- [x] **Step 4: Toolbar buttons** (`ContentView.uploadButton`/`downloadButton`): instead of the `selected == nil || kind == .symlink` disable, the rule becomes: enabled when `session.local.selectedItems.contains { $0.kind != .symlink }` (and the remote equivalent); the action iterates over `selectedItems`, file → `enqueue`, folder → `enqueueTree`, symlink → skip (silently). `onCompleted` refresh per item as before.
- [x] **Step 5: Green** — full suite; `swift build` warning-free with respect to the changed files.
- [x] **Step 6: Commit** — `feat: multi-select in both file panes`.

---

### Task 4: Hidden files

**Files:**
- Modify: `Sources/macSCPCore/Settings/SettingsStore.swift` (new field after `downloadLimitKBs` line ~121, same didSet/persist pattern)
- Modify: `Sources/macSCPCore/Presentation/RemoteBrowserViewModel.swift` (filter in `load()`)
- Modify: `Sources/MacSCPApp/SettingsView.swift` (new "General" tab BEFORE "Transfers", lines 14–27)
- Modify: `Sources/MacSCPApp/MacSCPApp.swift` (commands block for ⌘⇧.)
- Modify: `Sources/MacSCPApp/ContentView.swift` (wiring store→VMs, onChange + session start, analogous to the limit wiring lines ~248–256/474–476)
- Modify: `Sources/MacSCPApp/Resources/en.lproj/Localizable.strings` + `de.lproj`
- Test: `Tests/macSCPCoreTests/SettingsStoreTests.swift`, `Tests/macSCPCoreTests/RemoteBrowserViewModelTests.swift`

**Interfaces:**
- Consumes: T3 (`selectedItems` reset in `load()`).
- Produces: `SettingsStore.showHiddenFiles: Bool` (default `false`, persisted); `RemoteBrowserViewModel.showHiddenFiles: Bool` (default `false`; changing it requires the caller to call `refresh()`).

- [x] **Step 1: Failing tests:**

```swift
    // SettingsStoreTests: defaults false, persists, survives reload.
    @Test func showHiddenFilesDefaultsFalseAndPersists() throws {
        let dir = try makeTempDir()
        let store = SettingsStore(directory: dir)
        #expect(store.showHiddenFiles == false)
        store.showHiddenFiles = true
        let reloaded = SettingsStore(directory: dir)
        #expect(reloaded.showHiddenFiles == true)
    }

    // RemoteBrowserViewModelTests: dotfiles filtered unless enabled.
    @Test @MainActor func loadFiltersDotfilesUnlessShowHiddenIsOn() async {
        let fs = MockRemoteFileSystem()
        fs.entries["/"] = [
            RemoteFileItem(name: ".env", path: "/.env", kind: .file, size: 1),
            RemoteFileItem(name: "visible.txt", path: "/visible.txt", kind: .file, size: 1),
        ]
        let vm = RemoteBrowserViewModel(fs: fs)
        await vm.load()
        #expect(vm.items.map(\.name) == ["visible.txt"])
        vm.showHiddenFiles = true
        await vm.load()
        #expect(vm.items.map(\.name) == [".env", "visible.txt"])
    }
```

(Adapt the mock's entry access to the actual `MockRemoteFileSystem` API —
assertions unchanged; sort order: directories first, then case-insensitive —
`.env` before `visible.txt`.)

- [x] **Step 2: Red, then implement:**

SettingsStore (copy the pattern from `uploadLimitKBs` — field, didSet→persist,
forward-compatible encode/decode):

```swift
    /// Show dotfiles in both panes (M7a). Default OFF — the Finder-like
    /// default; ⌘⇧. and the General settings tab toggle it.
    public var showHiddenFiles: Bool {
        didSet { persist() }
    }
```

VM in `load()` after the `list`:

```swift
            let visible = showHiddenFiles
                ? listed
                : listed.filter { !$0.name.hasPrefix(".") }
            items = Self.sortedForDisplay(visible)
```

plus property:

```swift
    /// Display filter for dotfiles (M7a). The caller re-`load()`s after
    /// changing it — the filter is presentation-only, never in the FS layer.
    public var showHiddenFiles = false
```

- [x] **Step 3: "General" settings tab** — in `SettingsView.swift`, new first tab:

```swift
            GeneralSettingsTab(store: store)
                .tabItem {
                    Label(
                        L10n.string("settings.tab.general", "General"),
                        systemImage: "gearshape")
                }
```

```swift
/// General app options (M7a): currently the hidden-files toggle.
private struct GeneralSettingsTab: View {
    @Bindable var store: SettingsStore

    var body: some View {
        Form {
            Toggle(
                L10n.string("settings.general.showHidden", "Show hidden files"),
                isOn: $store.showHiddenFiles)
            Text(L10n.string(
                "settings.general.showHiddenHint",
                "Applies to both panes. Shortcut: ⌘⇧."))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(20)
    }
}
```

Keys EN: `"settings.tab.general" = "General"; "settings.general.showHidden" = "Show hidden files"; "settings.general.showHiddenHint" = "Applies to both panes. Shortcut: ⌘⇧.";` — DE: `"Allgemein"`, `"Versteckte Dateien anzeigen"`, `"Gilt für beide Seiten. Kürzel: ⌘⇧."`.

- [x] **Step 4: ⌘⇧. command** — in `MacSCPApp.swift` on the `WindowGroup`:

```swift
        .commands {
            CommandGroup(after: .sidebar) {
                Button(L10n.string("menu.toggleHidden", "Show/Hide Hidden Files")) {
                    settingsStore.showHiddenFiles.toggle()
                }
                .keyboardShortcut(".", modifiers: [.command, .shift])
            }
        }
```

Keys: EN `"menu.toggleHidden" = "Show/Hide Hidden Files";` DE `"Versteckte Dateien ein-/ausblenden";`.

- [x] **Step 5: Wiring** — in `ContentView`: in `startSession` set both VMs (`local.showHiddenFiles = settingsStore.showHiddenFiles`, likewise remote) and add an `.onChange(of: settingsStore.showHiddenFiles)` next to the limit observers, which sets both VMs of the CURRENT session and triggers a `refresh()` of both panes (`Task { await session.local.refresh(); await session.remote.refresh() }`; no-op without a session).
- [x] **Step 6: Green** — full suite.
- [x] **Step 7: Commit** — `feat: hidden-files toggle with settings tab and shortcut`.

---

### Task 5: Close-out verification (coordinator, not a subagent)

- [x] Start the Docker rig (main checkout!), `MACSCP_ITEST=1 MACSCP_KEYCHAIN=1 swift test` ⇒ fully green (including the new gated rename/chmod/deleteTree tests).
- [x] Visual smoke (rebuild the dev wrapper): multi-select via ⌘-click in both panes; transferring a selection of 3 (queue shows 3 items); a symlink in the selection is skipped; hidden files: default OFF (Home shows NO dotfiles anymore — the most noticeable change), ⌘⇧. toggles it on/off (both panes), "General" settings tab DE/EN text; double-click editor (uses `selectedItem`) still works.
- [x] Plan checkboxes, ledger, Opus whole-branch final review (base = commit before T1 on develop), fixes, push develop, `gh run watch` (does ci.yml also run on develop? check — ci.yml only triggers on push to main + PRs: then a local `swift test` record is enough, or extend ci.yml to develop as part of this task), stop the rig, memory update, milestone summary.
