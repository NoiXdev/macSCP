# macSCP M5f — Session Manager & CI Alignment (Design Spec)

**Date:** 2026-07-10
**Status:** approved by the maintainer (brainstorming session, design review of the running app)
**References:** `docs/design/ci.md` ("Two worlds, one window"), interactive design
"macSCP — Design & CI" (artifact, session 2026-07-09), `docs/superpowers/specs/2026-07-09-macscp-design.md`

## Goal

Two work items from the maintainer's design review:

1. **Expand the session manager:** context menu with rename / edit /
   delete for saved sessions, plus flat groups (create, rename,
   dissolve, assign sessions).
2. **Align the UI with the CI designs:** sidebar look, connection view,
   title bar/toolbar and consistent accent colors do not yet match
   the approved design.

## Decisions (maintainer, 2026-07-10)

| Question | Decision |
|---|---|
| Design scope | All four items: sidebar look, connection view, title bar/toolbar, consistent accent colors |
| Edit flow | Reuse the existing connection form (edit mode) |
| Group structure | Flat groups (one level), no nested folders |
| Group data model | Dedicated group objects (`groups` array + `groupID` on the session) |
| Design implementation | Targeted view adjustments with the existing `DesignTokens`, no theming system |

## Part A — Session Manager

### Data model & store

- New: `public struct StoredGroup: Codable, Equatable, Identifiable, Sendable`
  with `id: UUID` and `name: String`.
- `StoredSession` gets `public var groupID: UUID?` (nil = ungrouped).
- `SessionStore` persists groups alongside sessions in
  `sessions.json`. **Forward/backward compatibility:** existing files
  without `groups`/`groupID` load unchanged (no migration); the store's
  existing load/save pattern is preserved.
- Ordering: groups in creation order (array order in the store);
  sessions within a group in save order, as before.
- **Deleting a group means dissolving it:** the sessions assigned to it
  get `groupID = nil`, i.e. become ungrouped — never deleted along with it.
- Orphaned `groupID`s (group missing from `groups`) are treated as
  `nil` on load (defensive, not an error).
- Secrets: unchanged, exclusively in the keychain (`SecretStore`),
  addressed by session ID; `sessions.json` still contains no secrets.

### SessionListViewModel — new operations

- `renameSession(id:to:)` — trims the name, empty not allowed.
- `updateSession(_:)` — full edit (name, host, port, user,
  authKind, keyPath, groupID); secret update, see edit flow.
- `createGroup(name:) -> StoredGroup` — empty groups are allowed.
- `renameGroup(id:to:)`
- `dissolveGroup(id:)` — sessions → ungrouped.
- `moveSession(id:toGroup:)` — `nil` = "No group".
- Delete stays as before (session + keychain secret), but gets a
  confirmation prompt in the UI.

### Sidebar behavior

- Layout: "SESSIONS" label → ungrouped sessions → one collapsible
  section per group (DisclosureGroup behavior; collapse state is
  pure per-window UI state, not persisted) → "IMPORTED" section
  (unchanged, not grouped).
- Context menu on a **session row**: Connect · Edit… · Rename ·
  Move to → (submenu: all groups, "No group",
  "New group…") · Delete (destructive, with a confirmation dialog — the
  keychain secret is deleted along with it).
- Rename is **inline**: the row turns into a text field, Enter confirms,
  Escape cancels (losing focus = cancel, no silent commit).
- Context menu on a **group header**: Rename · Dissolve.
- Context menu on the **sidebar background**: New connection · New group…
- **Drag and drop:** dragging a session row onto a group header moves
  the session into that group; dragging onto the "SESSIONS" area ungroups it.
  (The "Move to" context menu is the primary functional path; D&D is
  a convenience.)
- "New group…" opens a name prompt as an alert with a text field
  (confirming creates it, an empty name creates nothing).
- Sidebar interactions stay disabled during transfers/connection setup,
  as before (`interactionsDisabled`).

### Edit flow (form in edit mode)

- Entry point via the context menu "Edit…"; the detail area shows the
  existing connection form pre-filled (name, host, port, user,
  auth kind, key path) plus a **group picker** (picker: No group /
  existing groups). The same picker also appears when creating a new
  session, once "Save as session" is enabled.
- Title "Edit session"; buttons: **Save**,
  **Save & connect**, Back (discards changes and shows the
  previous state).
- **Password/passphrase in edit mode:** field is empty, placeholder
  "unchanged". Leaving it empty = existing secret stays; entering a value =
  overwrites the keychain entry. Stored secrets are **never**
  loaded from the keychain into the form (existing security invariant).
- Switching the auth kind while editing follows the same semantics as
  when creating (password ↔ key, including the passphrase field).
- "Save" does **not** connect; "Save & connect" saves and then
  starts the normal connection path (including TOFU, unchanged).

## Part B — CI Alignment

Principle: targeted adjustments using the existing `DesignTokens`
(`localAmber`, `remoteBlue`, `statusPhosphor`, terminal colors). The
CI rules from `docs/design/ci.md` are binding: amber/ocean blue only
semantically (local/remote), phosphor only for status, errors in system red,
system colors otherwise take precedence.

### Sidebar look (per the design mockup)

- Active session: soft background in ocean blue (derived from
  `remoteBlue`, ~12% opacity), semibold text in `remoteBlue`,
  phosphor dot.
- Inactive rows: subtle hover background; dot in secondary color.
- Section labels ("SESSIONS", group names, "IMPORTED"): small,
  uppercase, tracked — as in the mockup (`.caption2`, semibold, tracking).

### Connection view

- Compact form block (~420 pt), spacing/proportions modeled on
  the dialog mockup.
- Primary button ("Connect" / "Save & connect") in ocean blue
  (`borderedProminent` + tint) instead of the system accent.

### Title bar / toolbar

- Connected: window title **"macSCP — ‹session name›"** (unsaved
  connections: `user@host`); actions **Upload · Download ·
  Terminal · Disconnect** as a real macOS toolbar (SF Symbols) instead of the
  previous built-in header bar.
- Disconnected: title "macSCP", no toolbar items.
- Existing lifecycle/resize logic (compact window, active
  growing/shrinking, M5c/T0) stays unchanged.

### Consistent accent colors

- Global tint in ocean blue on the window content: default buttons,
  toggles, picker selection, progress indicators inherit the CI primary color.
- Semantics untouched: upload/local elements stay amber
  (TransferQueueBar, pane badges), download/remote blue, connected status
  phosphor, errors system red.

## Error handling

- Empty name when renaming/creating (session or group): the input is
  not accepted (inline: cancel; form: field validation as when
  creating).
- Group names may be duplicated (no uniqueness requirement — the ID
  identifies them); the plan may optionally show a hint when creating,
  but MUST NOT require it.
- Store errors (I/O) go through the sidebar's existing `errorMessage`
  path.
- The delete confirmation names the session and states that stored
  credentials are removed along with it.

## Tests

- **Store:** round trip with groups + `groupID`; loading a legacy file
  without group fields; orphaned `groupID` → treated as nil.
- **ViewModel:** rename/update/move/createGroup/renameGroup/dissolveGroup
  (dissolve keeps the sessions and ungroups them); delete removes the
  secret (mock SecretStore); update semantics: empty secret field = secret
  stays, set field = overwritten.
- **ConnectionViewModel (edit mode):** pre-fill, save without
  connecting, save & connect uses the normal connect path.
- **Look:** visual smoke test per completed task (sidebar states,
  toolbar connected/disconnected, edit round trip including
  password-unchanged).

## Deliberately NOT in scope

- Nested folders / hierarchy.
- Manual ordering (D&D order) within groups.
- Grouping the imported ssh-config hosts (stays its own section).
- Theming system / configurable colors.
