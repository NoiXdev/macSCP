# M11g — Interactive path bar (design)

Date: 2026-07-30 · Status: approved by the maintainer ("yes, go ahead")

## Goal

The path bar in the pane header becomes interactive: click copies the
path, double-click opens manual entry, tab completes shell-style
(maintainer decision 2026-07-30).

## Starting point

- The path bar today is a plain `Text(viewModel.currentPath)` in the
  header of `BrowserPane` (11.5 pt monospaced, `inkTertiary`,
  `.middle` truncation).
- `RemoteBrowserViewModel` knows `open(_ item:)`, `goUp()`, `refresh()` —
  **no** direct jump to a path.
- Both panes sit behind the same `RemoteFileSystem` protocol
  (`LocalFileSystem` and `CitadelFileSystem`), so directory listing is the
  same operation for completion on both sides.

## 1. Completion (Core, pure)

`PathCompletion.complete(input:entries:caseSensitive:) -> Result` is a
pure function over the typed text and a directory listing:

- `Result.completedInput: String` — the text after completion up to the
  unambiguous common prefix (unchanged if nothing can be completed).
- `Result.candidates: [String]` — the matching folder names, alphabetical.
- Only **directories** are candidates (jumping to a file gets you
  nowhere) and get `/` appended, so typing can continue immediately.
- A trailing `/` in the input means "list this directory"; otherwise the
  last path component filters by prefix.
- `caseSensitive` is a parameter, not a default: the far side usually is
  case-sensitive, a local macOS filesystem in the default configuration
  usually is not. A fixed value would complete incorrectly in exactly one
  of the two panes.

Determining candidates needs the listing of the typed path's **parent
directory** — the App fetches it via the pane's FS and passes it in; the
function itself does no I/O.

## 2. Jumping (Core, ViewModel)

`navigate(to path: String) async -> String?` (nil = success, otherwise a
localized message), following the pattern of the M7b actions:

- normalizes repeated and trailing slashes (the same trap as in M7a's
  `deleteTree`: stripping once is not enough),
- checks via `stat` that the target exists and is a **directory** — a
  file gets its own message, not the same one as "does not exist",
- **symlinks (correction 2026-07-30, T1 review):** `LocalFileSystem.stat`
  deliberately reports `kind == .symlink` for a symlink, even one pointing
  at a directory, while Citadel's `stat` resolves links. A plain
  `isDirectory` test would therefore have rejected `/tmp`, `/var`, and
  `/etc` in the local pane — symlinks on every Mac — with the factually
  wrong message "not a directory". For `kind == .symlink`, a `list()` is
  therefore attempted: if it succeeds, the target is navigable. Core thus
  stays symlink-agnostic (no `lstat`, no resolution logic), and the far
  side is untouched, because its `stat` already resolves.
- missing permissions get the filesystem's own message,
- on success, it loads the same way as `open`, including a selection
  reset.

## 3. Interaction (App)

- **Single click**: copies the full path to the clipboard. The cursor
  turns into a hand (otherwise the capability would be undiscoverable),
  and a brief confirmation fades in and back out — without feedback,
  nobody would know whether it worked.
- **Double-click**: the row becomes a text field, prefilled with the
  current path, cursor at the end. **Enter** jumps, **Esc** cancels,
  **losing focus** also cancels — identical to the inline rename in the
  sidebar (M5f), so there is only one rule to remember.
- **Tab**: completes up to the unambiguous common prefix. A second,
  immediately following tab expands the candidates below the field; the
  list is clickable. Any further keystroke closes it again.
- While a completion is in progress, the field stays interactive; a slow
  listing must not block input.

## 4. Errors, honestly

A path that does not exist, is a file, or lacks permissions leaves the
field **open** with the message below it — the typed text is not lost. No
silent discarding, no falling back to the old path without a notice.

## 5. Deliberately NOT in M11g

- No clickable path segments (breadcrumb): the click is assigned to
  copying by maintainer decision.
- No history list, no globbing, no bookmarks.
- No `~` resolution on the far side: that would need an extra query to
  the server, and a half-working `~` is worse than none.
- No audit entry (navigation is not a change).
- **Completion does not offer symlinks, even if their target is a
  directory** (addendum, M11g closing review): typed navigation has
  followed a symlink directory since T1
  (`RemoteBrowserViewModel.navigate(to:)` checks `list()` on the target
  when `stat` returns `.symlink`). `PathCompletion.complete`, by
  contrast, still filters symlinks out entirely (see its own doc
  comment) — deliberately, not by oversight: whether a symlink points at
  a directory cannot be determined without a `stat` per entry, and that
  would break `PathCompletion`'s I/O-free contract (the function only
  gets the finished list, never permission to query on its own). The
  consequence is a visible asymmetry: on every Mac, `/tmp`, `/var`, and
  `/etc` are symlinks; tab at `/t` offers nothing there, while `/tmp` as
  a fully typed path works without complaint. A double-click on a symlink
  entry in the file list is likewise inert, for the same reason (no
  navigation handler for it). Both stay unchanged in M11g; the
  inconsistency is recognized and accepted, not an open bug.

## 6. Tests

- `PathCompletion`: absolute prefix, unambiguous match, several
  candidates (common prefix gets completed, the rest stays), no match,
  trailing slash lists everything, files are never candidates, case
  sensitivity in both modes, empty listing, root directory, components
  with spaces.
- `navigate(to:)`: success loads and sets `currentPath`; file instead of
  folder, non-existent, and permission errors each produce a different
  message; slash normalization including double slash and repeated
  trailing slash; selection gets cleared.
- Gated rig test: jump into a deep directory and back, plus completion
  against a real listing.
- EN/DE catalogs: key sets identical (the M11d parsing guard covers this
  format).

## 7. Breakdown

T1 Core (`PathCompletion` + `navigate(to:)` + rig test) → T2 App (path
bar: copy, entry, tab, candidate list, error line, EN/DE) → T3 closeout.
NO release.
