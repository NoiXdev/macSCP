# M11j — Keyboard control in the file browser (Design)

Date: 2026-07-30 · Status: approved by the maintainer (Finder style,
transfer direction-by-pane)

## Goal

Operate the file list by keyboard: navigate, open, rename,
delete, info, transfer — without needing to reach for the mouse.

## Starting point

- The list is a plain `NSTableView` (not subclassed) in the
  `RemoteFileTableView` coordinator; **no** keyboard handler. Only the
  native arrow-key selection works; typing does nothing.
- All actions already go through ONE model today: `onOpen`,
  `onOpenFile`, and `onMenuAction(BrowserMenuEntry, [RemoteFileItem])` for
  Rename/Info/NewFolder/Delete/Transfer, plus `viewModel.goUp()`. Validity
  (which action is allowed for which selection) lives in the
  pure Core function `BrowserContextMenu.entries(for:side:)`.

## Key bindings (Finder style, maintainer's decision)

| Key | Action |
|---|---|
| **Return** | Rename (only with exactly one selection) |
| **⌘↓** / **⌘O** | Open: folder → go in (`onOpen`), file → editor (`onOpenFile`, remote only) |
| **⌘↑** | Up one level (`goUp`) |
| **⌘⌫** | Delete with confirmation (`delete`) |
| **⌘I** | Info & permissions (single item only, NEVER a symlink) |
| **Space** | Transfer — the local pane uploads, remote downloads |
| **⌘A** | Select all (native) |
| **Esc** | Clear selection |

- **Plain ⌫ stays unbound** — no accidental deletion; Finder doesn't
  delete with it either.
- Arrow keys (moving the selection) stay the native table function.
- Both panes identical; the transfer direction follows from `side`.

## Validity = context menu, no second path

A key triggers an action only if the same action would also appear in the
context menu for the current selection. Concretely: the
keyboard consults `BrowserContextMenu.entries(for:side:)` (or a thin
derivative of it) and forwards only permitted actions to exactly the
closures the context menu already uses. That way the menu and the
keyboard can never drift apart:

- Rename/Info only with a single selection; Info never on a symlink.
- Delete only with a non-empty selection.
- Editor only remote and only for files.
- Transfer only with a transferable selection.

If a key is not permitted for the current selection, **nothing** happens
(no error, no suppressed beep — the keypress falls through to `super`,
so native functions like type-select are preserved).

## AppKit wiring

- `RemoteFileTableView` gets an **`NSTableView` subclass** with:
  - `override func keyDown(_:)` for the **modifier-free** keys: **Return**
    (rename), **Space** (transfer), **Esc** (clear selection).
  - `override func performKeyEquivalent(_:) -> Bool` for the
    **⌘-combined** keys (⌘↓/⌘O/⌘↑/⌘⌫/⌘I): command events in
    AppKit flow through `performKeyEquivalent`, NOT through `keyDown` — the
    classic trap. Return `true` only when we actually handle the key;
    otherwise `false`, so App menu shortcuts and focus changes
    stay untouched.
  - Both check first that a matching selection exists and that the action
    is permitted per the menu model; otherwise `super`/`false`.
- The coordinator (already `NSTableViewDelegate`/`NSMenuDelegate`) gets the
  dispatch methods; the subclass holds a weak reference to it
  and calls them. The selection is read BY VALUE at the moment of the
  keypress (the same pattern as `MenuActionBox` in menu building, against
  stale indices).
- **Collision check:** before implementation, make sure ⌘↓/⌘↑/⌘O/
  ⌘I/⌘⌫ don't collide with any existing App menu shortcut (taken are
  ⌘N/W/1–9, ⌘⇧., ⌘⇧K/L/I, ⌘T, ⌘,). If one collides, report it,
  don't silently rebind it.

## Deliberately NOT in M11j

- No change to type-to-select (stays native).
- No Quick Look / space-bar preview (space bar is transfer).
- No arrow-key navigation of the candidate list in the path bar (that is
  M11i/PathBar, untouched).
- No new audit entry (the triggered actions already audit themselves
  where relevant — delete etc.).

## Tests

- **Pure validity derivation** (Core, testable): a function that, from
  `(key, selection, pane side)`, returns the `BrowserMenuEntry` to trigger
  or the open/up/transfer intent, OR "nothing" — decoupled from the
  `NSEvent`. Cases: Return with single vs. multiple selection; ⌘I on a
  symlink (nothing) vs. a file; ⌘⌫ with an empty vs. non-empty selection;
  space direction by `side`; ⌘O folder vs. file vs. file-in-the-local-pane
  (no editor). This function is the automated core; it ensures
  the keyboard and the menu share the same validity.
- The AppKit binding (`keyDown`/`performKeyEquivalent`) has no
  test target → smoke checklist.

## Breakdown

T1 Core (pure `BrowserKeyCommand` derivation + test) → T2 App
(`NSTableView` subclass, dispatch, collision check, both panes) →
T3 wrap-up. NO release.
