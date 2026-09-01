# M10b — Login sets (design)

Date: 2026-07-28 · Status: approved by the maintainer (mockup frozen:
`docs/design/assets/m10-mockups.html` sections 3+4; design block "fits",
go straight ahead)

## Goal

Reusable logins (Termius-style): named sets of username + auth,
referenceable from connections ("change once, applies everywhere"), with
a three-way selector in the form and an automatic merge suggestion for
existing identical logins.

**Maintainer decisions (2026-07-28):**

1. ssh-agent auth is NOT part of M10b — its own milestone M10d (Citadel
   has no agent auth; would need its own protocol implementation via the
   custom-delegate hook). The set model is forward-compatible for this
   (`authKind` string raw value).
2. The three-way selector applies in M10b to the TARGET host; the jump
   host (M10c) uses the same building blocks.

## 1. Core model

- `public struct LoginSet: Equatable, Identifiable, Sendable`:
  `id: UUID`, `name: String`, `username: String`,
  `authKind: StoredSession.AuthKind` (REUSED — no duplicate enum),
  `keyPath: String?` (privateKey only).
- Forward compatibility: the store internally persists records with
  `authKind` as a string raw value. An UNKNOWN raw value (e.g. a future
  "agent" from M10d) is NOT delivered by `all()` as a set (never
  misinterpreted as a password set), but the record stays in the file —
  even across upsert/delete of other entries.
- Secrets: password or key passphrase live in the keychain UNDER THE
  SET ID (existing `SecretStore`; no new secret format, never in
  `logins.json`).
- `LoginSetStore` (its own `logins.json`, SessionStore pattern: stateless,
  atomic, forward-compatible): `all()`, `upsert`, `delete(id:)`.
- `StoredSession.loginSetID: UUID?` — optional, decode-compatible (legacy
  nil = manual). nil/non-nil IS the form mode.

## 2. Connect resolution

- If a session references a set, resolution at connect time delivers
  username + auth from the SET (password/passphrase from the keychain
  under the set ID). A testable Core function (e.g.
  `LoginResolver.resolve(session:sets:secrets:)`) builds the
  `SSHConnectionConfig` building blocks; the App wires it into the
  existing connect flow (connectStored/form).
- If the referenced set is missing (deleted/broken file), connect fails
  with an HONEST localized message ("The saved login could not be
  found") — no silent guessing, no silent manual fallback (the session no
  longer has its own data at all).

## 3. Deleting a set = reset

- The confirmation names the affected connections (count + names).
- On confirming: for each affected session, username/authKind/keyPath get
  COPIED BACK into the session, the secret gets COPIED from the set's
  keychain entry to the session's keychain entry, `loginSetID` gets
  nulled; the set + set secret get deleted afterward. Keychain error on
  one session: reset of the rest continues, the result reports the
  failure count (applyImport pattern). Never broken connections.

## 4. Equality detection (LoginMergePlanner)

- A pure Core function over sessions WITHOUT a set:
  - privateKey groups: same (username, keyPath).
  - password groups: same username AND identical keychain password
    (comparison via SecretStore reads; values are never displayed;
    sessions without a stored password do not participate).
- Groups ≥ 2 ⇒ merge suggestion (banner). "Merge…" shows the preview
  (session names), creates ONE set (name suggestion from the username, on
  collision a "(2)" suffix like file conflicts), sets `loginSetID` on all
  sessions in the group, moves the secret under the set ID; the session
  secrets get DELETED after a successful switch (resolution from then on
  runs exclusively through the set).
- "Ignore" persists the group signature as a SET of session IDs in
  `logins.json` (`ignoredMergeGroups: [[UUID]]`) — deliberately NO
  password hash or derivation of one on disk. A new member (session ID
  not in the ignored set) reactivates the suggestion for the expanded
  group.

## 5. UI

- Logins sheet (⌘⇧L in the Sessions menu; sidebar background menu above
  "Known Hosts…"; link "Manage Logins…" in the form next to the picker):
  a list per mockup section 3 (KEY/PASS badge, name,
  `user · auth short form`, usage counter "n connections"), footer
  New…/Edit…/Delete…/Close; merge banner at the top (mockup look,
  "Ignore" + "Merge…" with a preview dialog).
- Set editor sheet (new/edit): name, username, auth segments
  Password|SSH Key (password SecureField with an "unchanged" prompt when
  editing, like the session form; key path + fileImporter + passphrase).
  Save validates that name+username are non-empty.
- Form three-way selector (target host) exactly mockup section 3 bottom
  sheet: toggle `Login Set | Manual` (segments); set mode: picker of all
  sets + a "Manage Logins…" link; manual mode: today's fields + a
  "Save as new login set" toggle + a name field (creates the set on
  connect/save, references it immediately, the session secret moves under
  the set ID). Edit mode shows the remembered state (loginSetID set ⇒
  set mode with the set preselected).
- Export/import (M9a): sessions with a `loginSetID` export the RESOLVED
  values (username/auth/password if applicable) — the export format
  stays unchanged at v1; sets themselves are NOT exported (backlog).

## 6. Tests

- Store: CRUD, forward compatibility (an unknown authKind raw value gets
  skipped, file untouched), loginSetID decode compatibility with an old
  sessions.json.
- Resolver: set→credentials including keychain; missing set ⇒ typed
  error with a localized message.
- Deletion reset: values + secret copied, loginSetID nulled, keychain
  error counts instead of aborting (mock SecretStore).
- Merge planner: key and password grouping (including "no stored
  password does not participate"), ignore signatures (reactivation on a
  new member), merge application (set created, sessions switched over,
  session secrets deleted, name collision "(2)").
- Export resolution: a session with a set exports resolved values.
- UI (sheets, banner, three-way selector, menu): visual smoke test (T4).

## 7. Deliberately NOT in M10b

- No ssh-agent (M10d), no jump host (M10c — which then uses the
  three-way selector).
- No export/import of the sets themselves (backlog; sessions export
  resolved).
- No use of sets in the edit-session "Save & connect" special case beyond
  the normal case (the three-way selector applies everywhere in the
  form).
