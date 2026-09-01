# M11m — Additional file list columns (Design)

Date: 2026-07-31 · Status: approved by the maintainer ("go ahead then")

## Goal

Extend the file list with togglable columns: **Permissions**, **Owner**,
**Group**, **Type** — toggleable in Settings, each sortable (builds on the
M11l sorting foundation).

## Starting point

- `RemoteFileItem` today carries `name`, `path`, `kind`, `size: UInt64?`,
  `modifiedAt: Date?`, `permissions: UInt32?`. **No owner/group fields.**
- Citadel's SFTP listing supplies, per entry, `attributes: SFTPFileAttributes`
  (with `uidgid: UserGroupId?` = NUMERIC `userId`/`groupId`, NO names) AND
  `longname: String` (the server-formatted `ls -l` line, in which the
  owner/group NAMES appear as text fields).
- `SFTPAttributeMapper.item(...)` today only pulls size/permissions/modTime;
  `longname` and `uidgid` are discarded.
- The table (`RemoteFileTableView`) builds three fixed columns `name`/`size`/
  `modified`. `FileSortKey` (M11l) has `.name/.size/.modified`.
- Permissions are already formatted as rwx in the info sheet via
  `PosixPermissions` (M7b).

## 1. Model + data origin (Core)

`RemoteFileItem` gets two new optional fields:

- `owner: String?`, `group: String?`.

Origin:

- **Remote listing (readdir):** primarily parse the NAMES from `longname`
  (the `ls -l` format: after the permissions come the link count,
  **owner**, **group**). If parsing fails or `longname` is missing, fall
  back to the numeric `uidgid` as a string (`"1000"`). If neither is
  present, `nil`.
- **Remote single `stat`:** has NO `longname` (only `getAttributes`), so
  only the numeric `uidgid` or `nil`. That is fine — the columns are shown
  by the LISTING, not the single-item fetch.
- **Local:** names via `stat`/`getpwuid`/`getgrgid`, numeric fallback.

**Naming the fragility honestly:** `longname` is server-generated and
format-dependent; the parser is defensive (fixed field positions of the
`ls -l` output, but tolerant of repeated whitespace), and every doubtful
case falls back to the numeric uid/gid or `nil` — never a guessed, wrong
display. The parser is a pure, testable function.

## 2. Column model + setting

- `enum FileColumn: String, Sendable, CaseIterable` with
  `name`, `size`, `modified`, `permissions`, `owner`, `group`, `type`.
  `name` is always visible (not togglable). `size`/`modified` stay visible
  by default (today's behavior); `permissions`/`owner`/`group`/`type`
  default to OFF.
- `SettingsStore` gets a persisted, forward-compatible set of visible
  columns (old JSON ⇒ today's three). App-global (like the other display
  settings), not per pane.
- Formatting per column (pure Core functions, testable, localizable at the
  App layer):
  - Permissions: an rwx string via `PosixPermissions` OR octal — rwx like
    in the info sheet, consistent.
  - Type: "Folder" / "File" / "Symlink" / "—" per `kind` (localized).
  - Owner/Group: the string, or "—".

## 3. Sorting (Core, builds on M11l)

`FileSortKey` gets `.permissions`, `.owner`, `.group`, `.type`:
- `.permissions`: numeric by the bits, name tiebreaker.
- `.owner`/`.group`: `localizedCaseInsensitiveCompare` on the string, `nil`
  goes to the end, name tiebreaker.
- `.type`: by `kind` (stable order folder/file/link/other), name
  tiebreaker. (The folders-first grouping from M11l stays regardless.)
- The name tiebreaker stays ascending even in descending order (M11l rule).

## 4. Interaction (App)

- The table builds its columns DYNAMICALLY from the setting (fixed order:
  Name, Size, Modified, Permissions, Owner, Group, Type — only the visible
  ones). Each column has its `PolishedHeaderCell` and its
  `sortDescriptorPrototype` (M11l), including the self-drawn ▲/▼ indicator.
- Settings ▸ General (or its own small section): a checkbox per togglable
  column. Name stays fixed.
- Row layout: the new columns draw like the existing cells (12.5 pt;
  permissions/type monospaced/regular as appropriate), recycling hygiene
  like the symlink icon (M11h) — cell content MUST be set on every reuse.
- M5g look: the three existing columns keep their dimensions/typography;
  the new ones fit into the same rhythm.

## 5. Deliberately NOT in M11m

- No resolving numeric uid/gid to names via an extra server request (no
  `id`/`getent` call) — only `longname` names or the number.
- No freely reorderable/width-persisted columns (fixed order; widths are
  AppKit's default, not persisted).
- No CHANGING owner/group (display only; chown is out of scope here).
- No audit entry.

## 6. Tests

- `longname` parser (pure): a standard `ls -l` line ⇒ owner/group correct;
  repeated whitespace; names with special characters; a too-short/broken
  line ⇒ `nil` (no guessing); a line with no group column ⇒ defensive.
- Mapper: `longname` wins over `uidgid`; without `longname`, numeric
  fallback; without either, `nil`.
- Column formatters (permissions rwx, type per `kind`, owner/group/"—").
- `FileSortKey` new cases including name tiebreaker and `nil` position.
- `SettingsStore`: forward compatibility (old JSON ⇒ default columns),
  roundtrip.
- Gated rig test: a listing against the Docker server returns owner/group
  (the rig has known values).
- EN/DE catalogs: identical key sets.

## 7. Breakdown

T1 Core (model fields + `longname` parser + mapper + LocalFileSystem +
`FileColumn`/`FileSortKey` cases + formatters + `SettingsStore`, with
tests including gated rig) → T2 App (dynamic columns from the setting,
cells, settings checkboxes, EN/DE) → T3 wrap-up. NO release.
