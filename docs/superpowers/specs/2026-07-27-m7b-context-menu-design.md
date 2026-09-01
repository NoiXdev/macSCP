# macSCP M7b — Context menu & dialogs (design spec)

**Date:** 2026-07-27
**Status:** approved by the maintainer (block 2)
**Context:** Second part of the file-browser expansion, builds on M7a
(rename/setPermissions/deleteTree, multi-select, hidden filter). Tabs are
M8 — the "Übertragen" submenu is the prepared mounting point ("Transfer to
session xy" is added there).

## Context menu

- Right-click on rows in EITHER pane; implemented as `NSMenu` in the
  table coordinator (the table is AppKit), actions run via callbacks into
  the SwiftUI/view model layer.
- Right-clicking a row that is NOT selected selects it first (Finder
  behavior); right-clicking within an existing multi-selection keeps the
  selection.
- Entries (single selection):
  1. **Übertragen** — submenu, today exactly one entry "Zum anderen Pane"
     (upload or download depending on the pane; file → `enqueue`, folder
     → `enqueueTree`).
  2. **Öffnen** — remote FILES only (the M5e editor path); hidden in the
     local pane and for folders/symlinks.
  3. **Umbenennen…**
  4. **Informationen & Rechte…**
  5. **Neuer Ordner…** (acts on the pane's current directory; also
     available in the background context without a row)
  6. **Pfad kopieren** (full path onto the pasteboard; for multi-selection
     one line per path)
  7. Separator, then **Löschen…** (red, `.destructive`)
- Multi-selection: Umbenennen, Informationen & Rechte and Öffnen are
  dropped; Übertragen/Pfad kopieren/Löschen act on all of them.
- Symlinks: Übertragen is dropped (the queue does not transfer symlinks),
  Umbenennen/Löschen/Pfad kopieren work.

## Dialogs (all as sheets, buttons in PolishedButtonStyle)

- **Umbenennen…**: name sheet, pre-filled with the current name.
  Validation: not empty, no `/`; collision and other errors appear as
  localized error text in the sheet (sheet stays open). Confirming calls
  `rename(from:to:)` with the path in the same directory, followed by a
  pane refresh (selection follows the new name where possible).
- **Neuer Ordner…**: same name-sheet type (shared component), default
  "untitled folder"/"unbenannter Ordner"; calls `createDirectory`,
  followed by refresh + selection of the new folder.
- **Informationen & Rechte…**: shows name, full path, kind, size
  (formatted like the list), modification date, and the permissions: an
  rwx grid (3×3 checkboxes owner/group/other) + octal field (3–4 digits),
  both kept in sync bidirectionally; based on `RemoteFileItem.permissions`
  (if the value is missing, the permissions part is greyed out with a
  note). "Übernehmen" calls `setPermissions` (lower 12 bits only),
  followed by refresh; errors as text in the sheet.
- **Löschen…**: confirmation alert, destructive red confirm button. Text
  names the item for single selection, the count for multi-selection;
  for folders it includes the note "einschließlich des gesamten Inhalts";
  always "Diese Aktion kann nicht widerrufen werden." Execution runs
  sequentially via `deleteTree`/`delete` in a task with cancellation
  propagation; followed by refresh. Error → error alert (localized
  mapping), items already deleted stay deleted.

## Error handling & localization

- All actions report failures via an alert using the existing localized
  error mapping (`TransferQueueViewModel.message(for:)` or Core keys); no
  `String(describing:)`.
- All new menu, sheet, and alert texts are cataloged EN/DE.

## Invariants

- No behavior of existing paths changes (double-click editor, toolbar
  buttons, drag & drop, queue invariants).
- Actions run sequentially and without blocking the UI; during an
  in-progress delete/rename action, the pane refresh target it triggers
  is clearly defined (refresh only after completion).
- Code + comments in English.

## Tests

- Menu state logic (which entries for which selection) as a unit-testable
  helper function (items + pane side → menu model).
- Name validation unit-tested; octal↔grid conversion unit-tested.
- Visual smoke: menu in both panes, rename collision, chmod on the rig
  (`ls -l` proof via docker exec), recursive delete with confirmation,
  new folder, copy path, multi-selection variants.

## Deliberately NOT in M7b

- "Übertragen zu Session xy" (M8 tabs; submenu structure is ready).
- Trash/undo for deleting (SFTP has no trash; local deletion is
  deliberately symmetric — hard delete with confirmation).
- Duplicate, compress, "Öffnen mit" submenu (backlog v1.2).
