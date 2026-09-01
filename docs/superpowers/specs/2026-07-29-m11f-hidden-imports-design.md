# M11f — Hidden Imports (Design)

Date: 2026-07-29 · Status: approved by the maintainer ("go ahead")

## Goal

Connections imported from `~/.ssh/config` should be able to disappear from
the sidebar without macSCP touching the config file. The way back
goes through a dedicated management sheet (maintainer decision 2026-07-29,
the "dedicated management sheet" option — consistent with Known Hosts and
Login Sets).

## Starting point

- `SSHConfigImporter.load(path:)` re-reads `~/.ssh/config` every time a
  window opens (`ContentView.task`), deduplicates by alias
  (first-wins, ssh semantics) and sorts alphabetically.
- `SSHConfigHost` carries `alias`, `hostName`, `user`, `port`,
  `identityFile` — no secrets, no ID other than the alias.
- The sidebar's IMPORTED section shows them read-only; a click fills
  the form, without connecting. There is no context menu today.
- `~/.ssh/config` is strictly read-only — a deliberate commitment since
  M3d.

## 1. Persistence (Core)

`HiddenImportStore`, following the pattern of `LoginSetStore`: its own
JSON file `hidden-imports.json` in the same directory as `sessions.json`,
stateless, atomic writes, a forward-compatible container format (unknown
fields don't survive a write — but an older file without those fields
loads without complaint).

Only the **alias** is stored — it is the identity under which the entry
sits both in the config and in the sidebar. No host, no user, no
path: the list must not become a second, staling copy of the config.

API: `allHidden() -> [String]`, `hide(_ alias: String)`,
`unhide(_ alias: String)`, `isHidden(_ alias: String) -> Bool`.
`hide`/`unhide` are idempotent. The comparison is exact (not
case-insensitive): ssh treats `Host` aliases as exact strings, and
a more lenient rule would hide entries the user never meant.

## 2. Filter + orphans (Core, pure)

A pure function splits the loaded hosts into what the sidebar
shows and what the sheet shows:

- **visible**: all hosts whose alias is not in the hidden list.
- **hidden**: aliases from the list that still exist in the config.
- **orphaned**: aliases from the list for which the config has NO
  matching host anymore (renamed or deleted).

The split is pure and testable without file access; loading stays in
`SSHConfigImporter`.

## 3. Operation (App)

- **Hide**: context menu on an imported row → „Ausblenden".
  The entry disappears immediately; no confirmation dialog (the action
  is lossless and reversible with one click).
- **Bring back**: menu **Sitzungen ▸ Ausgeblendete Importe… (⌘⇧I)**.
  ⌘⇧I is free (taken are ⌘N, ⌘W, ⌘1–9, ⌘⇧., ⌘⇧K, ⌘⇧L, ⌘T, ⌘,).
  The menu title carries the count as long as something is hidden — without
  this hint the way back would be undiscoverable once the IMPORTED
  section is completely empty.
- **Sheet**: one row per hidden alias with „Wieder einblenden".
  Orphaned entries are marked as such („nicht mehr in
  ~/.ssh/config") and can be removed from the list entirely, so nothing
  rots there that nobody can attribute anymore. Empty state with a
  sentence explaining how entries get here.
- After every change, the sidebar updates immediately (the
  read config data stays in the window state, re-filtered without
  re-reading the file).

## 4. What deliberately does NOT happen

- No writing to `~/.ssh/config` — in any variant.
- The hidden list does **not** travel with the sessions export (M9a): it
  belongs to a local file on this exact machine, not to the
  connections. On a different machine, the same list would look
  arbitrary.
- No hiding by pattern/wildcard, no groups, no editing
  imported entries (the latter would remain a contradiction to the
  read-only commitment).
- No audit entry: hiding is a pure display setting with no
  security relevance.

## 5. Tests

- Store: roundtrip hide/unhide, idempotency in both directions, empty file,
  missing file, unknown fields in the file (forward compatibility),
  exact (not case-insensitive) comparison.
- Filter: visible/hidden/orphaned across a table of cases,
  including "alias renamed ⇒ old entry orphaned, new one visible".
- Order of visible hosts stays the importer's sort order.
- EN/DE catalogs: identical key sets (the parsing guard from M11d covers
  the format).

## 6. Breakdown

T1 Core (store + pure split function) → T2 App (context menu, sheet,
menu item with counter, wiring, EN/DE) → T3 wrap-up.
NO release.
