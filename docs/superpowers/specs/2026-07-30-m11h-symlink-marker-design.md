# M11h — Mark symlinks (Design)

Date: 2026-07-30 · Status: approved by the maintainer

## Goal

Symlinks in the file list are recognizable, and double-clicking a
symlink that points to a directory opens it.

**Maintainer decisions (2026-07-30):**

1. **Only symlinks** get a symbol — folders and files stay
   unchanged. That way the frozen list layout from M5g is touched
   minimally, and the symbol sits exactly where there was previously no
   information.
2. **The double-click follows suit**: it tries to go into it, the way
   `navigate(to:)` has done since M11g.

## Starting point

- The file list has **no icons at all**. A folder is recognizable only by
  the appended `/` from `FileListFormatter.displayName(for:)`
  (`item.isDirectory ? item.name + "/" : item.name`).
- A symlink therefore looks **exactly like a regular file**.
- The cells are produced in `RemoteFileTableView`'s
  `tableView(_:viewFor:row:)`: one `NSTableCellView` per column with exactly
  one `NSTextField`, attached to the cell via Auto Layout with a 12pt left
  and 12pt right inset.
- `doubleClicked(_:)` calls `onOpen` for directories, `onOpenFile` for
  files — symlinks and `.other` are deliberately a no-op.
- `RemoteBrowserViewModel.navigate(to:)` (M11g) checks exactly the case at
  issue here: if `stat` reports a symlink, a `list()` is attempted;
  if it succeeds, the target is browsable.

## 1. The symbol (App)

In the name column, a row with `kind == .symlink` gets a
leading `NSImageView` with the SF Symbol **`arrow.up.forward`**
(the same arrow macOS itself uses for alias references), in
`inkTertiary`, at the row's text size.

- The symbol sits **within the inset** the row already has: the text field
  stays at 12pt, the symbol sits to its left within the existing
  inner spacing. **The row height and text position do not change** —
  M5g matched both against the mockup, and a shift would be
  a silent design regression in a list that is otherwise untouched.
- All other rows (`.file`, `.directory`, `.other`) look as they do today:
  no symbol, no placeholder, no indentation.
- Cells are reused (`makeView(withIdentifier:)`): the symbol
  must be **explicitly** shown or hidden on every reuse,
  otherwise it drifts onto the wrong row — the classic
  recycling bug.
- A tooltip on the row names the fact ("Symlink"), so the
  symbol is interpretable even without prior knowledge, and it doubles
  as the accessibility description.

**No appended `/` for symlinks**, even when they point to a directory:
without a `stat` per entry that cannot be determined (the same
restraint as with completion in M11g §5). The symbol says
"this is a reference", not "this is a folder" — and thereby
claims nothing macSCP doesn't know.

## 2. The double-click (App)

`doubleClicked(_:)` gets a third case: with `kind == .symlink`
the entry's path is handed to the same path the path input
uses (`navigate(to:)`). Concretely, that means:

- If the symlink points to a browsable directory, the pane switches
  into it — with the **symlink path** as the new location, not the
  resolved target. `navigate(to:)` already behaves this way, and a
  resolved path would lead `goUp()` to a place the user never
  came from.
- If it points to a file or is broken, the message from
  `navigate(to:)` appears — the same one the path input shows. No more
  silent no-op.
- `.other` stays a no-op as before.

That removes the inconsistency the M11g review named:
typing followed a symlink, clicking did not.

## 3. What deliberately does NOT happen

- No `stat` per list entry to resolve symlink targets ahead of time: that
  would be an extra request per row over the connection, for a
  cosmetic gain.
- No display of the target ("current → /var/www/releases/2026-07"): that
  would need a `readlink`, which the FS protocol does not have today.
- No icons for folders and files (maintainer's decision).
- Completion continues to offer no symlinks (M11g §5 stays
  valid unchanged) — it gets no `stat` budget.
- No audit entry (navigation is not a change).

## 4. Tests

- `FileListFormatter`: a symlink gets **no** appended `/`, even
  when it's named "current"; folders and files unchanged (regression).
- Menu/behavior model: the existing `BrowserContextMenu` behavior for
  symlinks stays untouched (no transfer, no editor, no permissions)
  — pinned by a test, so this round doesn't accidentally soften it.
- The double-click path is in the App layer and has no test target; the
  core logic behind it (`navigate(to:)` including the symlink branch) is
  already covered from M11g, including the gated rig test.
- Gated: a symlink to a directory and one to a file in the rig,
  via `navigate(to:)` — the first succeeds, the second returns the
  message.

## 5. Breakdown

T1 App (symbol in the name column incl. recycling hygiene, double-click,
tooltip, EN/DE) + a small Core piece (no `/` for symlinks, with a test) →
T2 wrap-up. NO release.
