# M11c — Set permissions recursively (Design)

Date: 2026-07-29 · Status: approved by the maintainer ("go ahead")

## Goal

In the permissions dialog, apply permissions to an entire subtree —
either the same permissions for files and folders, or separate ones
(folders almost always need the x bit, files usually don't).

**Maintainer decisions (2026-07-29):**

1. Separate mode is pre-filled with: files = permissions of the clicked
   folder, folders = the same permissions PLUS the x bit wherever read is
   allowed (644 ⇒ folder 755). Both freely editable.
2. The dialog asks, when "recursive" is switched on, whether to use the
   same or separate permissions.

## 1. The walk (Core, RISK)

- `PermissionsTreeApplier` — a pure function against `any RemoteFileSystem`,
  NO protocol extension: this way it applies without duplication to both
  the local AND the remote backend (`deleteTree` had to be implemented per
  backend because it derives `topLevelKind` itself; here the caller
  supplies the kind of the root entry, see below).
- Signature:
  `static func apply(root: String, kind: RemoteFileKind, filePermissions: UInt32, directoryPermissions: UInt32, on fs: any RemoteFileSystem) async -> PermissionsTreeResult`
  — does NOT throw; the result carries the numbers.
- `PermissionsTreeResult: Equatable, Sendable`:
  `changed: Int`, `skippedSymlinks: Int`, `failed: Int`,
  `firstErrorMessage: String?`, `cancelled: Bool`.
- Flow: top-down via `list(path:)`, because its entries report the type
  UNRESOLVED (the same property the delete walk's symlink safety rests on).
  For each entry:
  - `.symlink` ⇒ SKIP, `skippedSymlinks += 1`, NEVER call `setPermissions`
    on it and NEVER descend into it.
  - `.directory` ⇒ `setPermissions(directoryPermissions)`, then recurse.
  - otherwise ⇒ `setPermissions(filePermissions)`.
  - Per-entry error: `failed += 1`, remember the first message, KEEP GOING
    (the `applyImport` pattern). A failed `list` of a subdirectory also
    counts this way and does not stop the rest.
- **Symlink rationale (binding):** `setPermissions` FOLLOWS the symlink on
  both backends (a known M7a finding). A recursive run that does not skip
  symlinks would change permissions on targets OUTSIDE the tree — exactly
  the escape `deleteTree` prevents. Skipping is therefore a safety
  invariant, not a convenience.
- Root: the kind (`kind`) comes from the caller (the selection comes from
  `list()`, i.e. from the same unresolved source). If it is `.symlink`,
  NOTHING happens (result: only `skippedSymlinks == 1`) — the dialog
  doesn't offer the action for symlinks anyway.
- Cancellation: `Task.checkCancellation()` before every entry; on
  cancellation the walk stops and returns `cancelled: true` with the
  counts accumulated so far (no error, no rollback — permissions already
  set stay set, which is documented).

## 2. Deriving folder permissions (Core, pure)

`PosixPermissions.directoryDefault(from:)`: sets the x bit in each triple
(owner/group/other) wherever r is set there; special bits
(setuid/setgid/sticky) stay unchanged. 644 ⇒ 755, 600 ⇒ 700,
640 ⇒ 750. A pure function, directly testable.

## 3. VM action

`RemoteBrowserViewModel.applyPermissionsRecursively(file:directory:to:)`:
calls the walk, reloads the list afterward, writes ONE audit entry
(`chmod -R <file>/<dir> <path>` plus the numbers; `isError` only if
`failed > 0`), delivers the result to the UI. Progress is reported via an
optional callback (`(changed, failed) -> Void`) so the sheet can keep
count.

## 4. Dialog

- A "Apply to all sub-items" toggle in the existing permissions sheet;
  ONLY visible when the object is a folder (for a file, "recursive" would
  have no effect).
- Switched on: segments `Same permissions | Separate`. "Same permissions"
  uses the existing grid for both; "Separate" shows TWO grids
  (files / folders) pre-filled per §2.
- The apply button is then named "Apply Recursively" and first asks ONE
  confirmation naming the target path and mode (the action cannot be
  undone).
- During the run: a progress line in the sheet (a running count) plus
  "Cancel"; afterward the result line (changed / skipped / failed, with
  the first message on failures). No entry in the transfer queue — this
  isn't a transfer.
- **Correction (final review 2026-07-29):** the walk is protocol-based
  and demonstrably works against `LocalFileSystem` too (symlink detection
  there is correct, including symlink-to-directory and dead symlinks).
  REACHABLE today, though, it is ONLY on the remote side:
  `LocalFileSystem.item(for:)` returns `permissions: nil`, which is why the
  sheet locally replaces the whole permissions block with "Permissions are
  not available for this item" (behavior since M7b, not a regression).
  The original wording "applies on both panes" was wrong. Unlocking local
  permissions (filling in POSIX attributes in `item(for:)`) is backlog —
  the recursive run would then come along with no further work.

## 5. Tests

- Derivation: 644⇒755, 600⇒700, 640⇒750, special bits unchanged.
- Walk (mock FS recording every `setPermissions` call): a mixed tree
  (files, folders, symlinks, an empty folder); separate vs. same
  permissions; **no `setPermissions` on a symlink path** (the recording
  proves it); an entry's error counts and doesn't stop the run; a failed
  `list` of a subfolder counts and doesn't stop the run; cancellation
  mid-tree returns `cancelled: true` with partial counts; root is a symlink
  ⇒ nothing happens.
- VM: audit entry with numbers, `isError` only when `failed > 0`, the list
  is reloaded, the progress callback fires.
- Gated against the rig: a real tree including a symlink; then verified via
  `docker exec stat` that permissions in the tree are correct AND the
  symlink target outside is UNCHANGED.

## 6. Breakdown

T1 Core walk + derivation (RISK) → T2 VM action + audit + progress →
T3 dialog (toggle, two grids, confirmation, progress, EN/DE) →
T4 wrap-up (gated rig test, final review). NO release.

## 7. Deliberately NOT in M11c

No multi-selection (the dialog is single-selection), no "files only" or
"folders only" filter, no undo, no preview of the affected entries, no
recursive setting of owner/group (SFTP `chown` is not implemented and not
planned).
