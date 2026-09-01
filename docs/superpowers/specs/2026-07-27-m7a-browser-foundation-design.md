# macSCP M7a — Browser foundation (design spec)

**Date:** 2026-07-27
**Status:** approved by the maintainer (block 1)
**Context:** First part of the file-browser expansion (split M7a foundation
→ M7b context menu & dialogs). First work on the new **develop workflow**:
branch `develop`, releases only via targeted merge onto `main` + tag from
now on. Tabs for multiple sessions are M8 — the menu design in M7b keeps
the "Übertragen" substructure open for that.

## Decisions (maintainer, 2026-07-27)

- **Multi-select**: yes, Finder-style (⌘/⇧-click), actions act on the
  selection.
- **Delete**: folders too, recursively (with confirmation — UI in M7b).
- **Permissions editor**: both panes (local + remote) — UI in M7b, API
  here.
- **Hidden files**: default OFF (behavior change — today everything is
  shown), settings toggle + ⌘⇧.

## New FS APIs (`RemoteFileSystem` protocol, Local + Citadel + tests)

1. `func rename(from: String, to: String) async throws`
   - `to` is the FULL target path (same folder ⇒ rename; the UI builds
     the path, the protocol stays generic).
   - Existing target: error (`RemoteFSError` mapping), NO silent
     overwrite. Local: `FileManager.moveItem` (throws on collision);
     remote: SFTP rename (server refuses the collision, or the error is
     mapped to a clear text).
2. `func setPermissions(path: String, permissions: UInt32) async throws`
   - Acts only on the lower 12 bits (rwx for owner/group/other +
     setuid/setgid/sticky); file-type bits are never written.
   - Local: `FileManager.setAttributes([.posixPermissions:])`;
     remote: SFTP setstat.
3. `func deleteTree(at path: String) async throws` (RISK)
   - Recursive delete. Local: `FileManager.removeItem` (natively
     recursive). Remote: bottom-up walk — `list`, files/symlinks via
     `delete`, then the (empty) directories; symlinks are DELETED, NEVER
     followed (no escape from the tree).
   - Cooperatively cancelable (`Task.checkCancellation` per entry); a
     cancellation leaves behind a partially deleted tree (documented).
   - Single-file call behaves like `delete`.

## Multi-select

- `RemoteFileTableView`: `allowsMultipleSelection = true`; the coordinator
  reports the selection as an ordered array (table order).
- `RemoteBrowserViewModel`: new `selectedItems: [RemoteFileItem]`
  (source of truth); `selectedItem` stays as a derived convenience
  (`selectedItems.count == 1 ? first : nil`) — the double-click/editor
  path continues to use it.
- Upload/download toolbar buttons: active as soon as the selection
  contains at least one transferable item; they enqueue ALL selected
  items (file → `enqueue`, folder → `enqueueTree`, symlinks are silently
  skipped — no longer locking the buttons the way single symlink
  selection used to).
- Drag from the table: all selected rows supply writers (local NSURL,
  remote FilePromise) — mechanics per row as today.

## Hidden files

- `SettingsStore.showHiddenFiles: Bool`, default `false`
  (forward-compatible JSON as before).
- Filter in `RemoteBrowserViewModel` (display layer, NOT in the FS
  protocol): anything starting with `.` is hidden; sorting stays
  unchanged. `..` navigation is not affected (no list entry).
- Settings UI: new tab **"Allgemein"** in the existing settings window
  with the toggle "Versteckte Dateien anzeigen" (EN "Show hidden files"),
  keys EN/DE.
- Shortcut **⌘⇧.** in the browser toggles the setting live (writes to
  `SettingsStore`; both panes react via the existing onChange pattern).

## Invariants

- Security/architecture invariants untouched (TOFU, keychain, UI-owned
  lifecycles, queue invariants).
- Code + comments in English; new UI text cataloged EN/DE.
- Existing suite (317) stays green; new logic TDD (rename/
  setPermissions/deleteTree gated Docker tests like the other FS APIs;
  multi-select and filter logic unit-tested).

## Deliberately NOT in M7a

- Context menu, dialogs, delete confirmation → M7b.
- Tabs/multi-session → M8.
- macOS hidden flag locally (UF_HIDDEN) as an additional criterion — the
  dot prefix suffices for v1.1 (backlog note).
