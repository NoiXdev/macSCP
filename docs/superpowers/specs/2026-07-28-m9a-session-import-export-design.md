# M9a — Import/export of connections (design)

Date: 2026-07-28 · Status: approved by the maintainer (blocks 1+2 confirmed individually)

## Goal

Export connections (individually, per group, or all) via the sidebar
context menu into a versioned `.macscpsessions` file and import them back
additively — optionally encrypted, with optional passwords and duplicate
detection.

**Maintainer decisions (2026-07-28):**

1. Passwords: optional ALSO in the unencrypted export (checkbox, default
   OFF, red warning + extra confirmation for the plaintext case).
   Key FILES are never exported, only the path reference.
2. Duplicates: triple host+port+username (display name irrelevant, internal
   IDs irrelevant); duplicates are skipped, the result dialog reports the
   numbers.
3. UI: context menu entries (session "Export…", group "Export Group…",
   background "Export All…" + "Import…"); group assignment as a toggle in
   the export sheet.
4. Technique: approach A — a custom JSON envelope format, CryptoKit AES-GCM
   + PBKDF2 (CommonCrypto), NO new dependencies.

## 1. File format `.macscpsessions`

JSON envelope, versioned (pattern: sessions.json):

```json
{
  "format": "macscp-sessions",
  "version": 1,
  "encrypted": false,
  "payload": { … }                     // Klartext-Fall
}
```

Encrypted case, instead of `payload`:

```json
{
  "format": "macscp-sessions",
  "version": 1,
  "encrypted": true,
  "salt": "<Base64, 16 zufällige Bytes>",
  "iterations": 600000,
  "ciphertext": "<Base64, AES-GCM SealedBox combined über das serialisierte Payload-JSON>"
}
```

- Key derivation: PBKDF2-HMAC-SHA256 (CommonCrypto), 600,000 iterations
  (the value is stored in the file — a later increase does not break old
  files), 256-bit key.
- AES-GCM (CryptoKit) authenticates: a wrong password and a tampered file
  are indistinguishable to the codec and end in the same defined error
  (deliberate, no oracle distinction).
- `version` > 1 on import ⇒ a clear abort ("File comes from a newer macSCP
  version").

Payload:

```json
{
  "includesSecrets": true,
  "groups":   [ { "id": "<UUID>", "name": "Prod" } ],
  "sessions": [ {
      "id": "<UUID>",                  // nur zur Gruppen-Referenz innerhalb der Datei
      "name": "web-01", "host": "…", "port": 22, "username": "…",
      "authKind": "password" | "privateKey",
      "keyPath": "<Pfad oder null>",
      "groupID": "<UUID oder null>",
      "password": "<String oder fehlend>"   // nur wenn includesSecrets
  } ]
}
```

- `groups` contains only groups that exported sessions reference, and only
  if the group toggle was on (otherwise empty + `groupID: null` everywhere).
- Passwords missing from the keychain are left out; the export report
  counts them ("exported without password: n").

## 2. Core units (pure, unit-testable)

### 2.1 SessionExportCodec

`Sources/macSCPCore/Sessions/SessionExportCodec.swift`

- `encode(_ payload: SessionExportPayload, password: String?) throws -> Data`
  — `password == nil` ⇒ plaintext envelope, otherwise encrypted.
- `decode(_ data: Data, password: String?) throws -> SessionExportPayload`
  — typed errors: `notAnExportFile`, `unsupportedVersion(Int)`,
  `passwordRequired`, `wrongPasswordOrCorrupted`.
- `probe(_ data: Data) throws -> Bool` (is it encrypted?) — so the UI
  knows whether a password sheet is needed, without decrypting.

### 2.2 SessionImportPlanner

`Sources/macSCPCore/Sessions/SessionImportPlanner.swift`

- `plan(existing: [StoredSession], existingGroups: [StoredGroup], incoming: SessionExportPayload) -> SessionImportPlan`
- Rules:
  - Duplicate ⇔ same triple (host, port, username) against the EXISTING
    set — case-sensitive on the username, host normalized like the
    KnownHostsStore (lowercase); duplicates land in `skipped`.
  - Triple duplicates are also deduplicated WITHIN the file (keep-first,
    like the ssh-config import).
  - Groups: matched against existing ones by NAME (exact); missing groups
    are tracked as ones to create; sessions reference the result.
  - Every session to be imported gets a FRESH UUID; the password (if
    present in the payload) hangs off the plan entry and is stored under
    the new ID.
- `SessionImportPlan`: `groupsToCreate`, `sessionsToImport`
  (including an optional password per entry), `skipped` (for reporting).

### 2.3 VM integration

`SessionListViewModel` gains:

- `exportPayload(for scope: ExportScope, includeGroups: Bool, includePasswords: Bool) -> (payload: SessionExportPayload, missingPasswordCount: Int)`
  — `ExportScope`: `.single(StoredSession)`, `.group(StoredGroup)`, `.all`.
  Passwords via the existing `password(for:)` (keychain).
- `applyImport(_ plan: SessionImportPlan) -> SessionImportResult` — creates
  groups + sessions (store), saves passwords (SecretStore); keychain
  errors do NOT abort: the session is created anyway,
  `passwordFailures` counts. `SessionImportResult`: imported / skipped /
  passwords carried over / password failures.
- Import is ADDITIVE: existing sessions/groups are never changed or
  overwritten.

## 3. UI (app layer)

### 3.1 Export

- Context menu entries (keys EN/DE): session "Export…", group "Export
  Group…", background "Export All…" (dimmed at 0 sessions) —
  all open THE SAME export sheet with a pre-set scope.
- Export sheet: summary ("n connections"), toggle "Include group
  assignment" (default ON, hidden/irrelevant for a scope without groups),
  toggle "Include passwords" (default OFF), choice
  "Encrypted/Unencrypted":
  - Encrypted: two SecureFields (password + repeat); the export button is
    active only once they match and have ≥ 1 character; a hint to choose a
    long password.
  - Unencrypted AND passwords on: a red warning block ("Passwords will then
    sit in the file in plaintext") + the button requires an additional
    confirmation (two-step: "Export anyway…").
- Then the native save dialog (`fileExporter`), a custom UTType
  `dev.noix.macscp.sessions` (extension `.macscpsessions`, declared in
  Info.plist). After success, a short result hint including
  `missingPasswordCount`, if > 0.

### 3.2 Import

- Background menu "Import…" → `fileImporter` → `probe`:
  - encrypted ⇒ password sheet; a wrong password shows the message in the
    sheet, unlimited attempts, cancel possible.
- Planner → `applyImport` → result dialog: "X imported, Y skipped as
  duplicates, Z passwords carried over" + a password failure line if
  applicable + a note "The file contained unencrypted passwords." if
  applicable.
- Sidebar refreshes; NO auto-connect.

### 3.3 Error cases

- `notAnExportFile`/`unsupportedVersion`: alert with a clear message.
- `wrongPasswordOrCorrupted`: inline in the password sheet.
- Empty scope: menu item dimmed.
- Write error on export (disk): alert with a localized error message.

## 4. Tests

- Codec: roundtrip plain + encrypted (including umlauts/emoji in the
  password and in the payload), wrong password ⇒
  `wrongPasswordOrCorrupted`, ONE flipped ciphertext byte ⇒ the same
  error, `probe` both cases, version gate,
  `passwordRequired` (encrypted decoded without a password),
  `includesSecrets` flag consistent.
- Planner: triple duplicate despite a different name; host case
  normalization; in-file duplicates keep-first; group match by name vs.
  new creation; fresh UUIDs (≠ file IDs, ≠ existing); password pass-through.
- VM: `applyImport` with a mock SecretStore (including an injected
  keychain error ⇒ session created anyway, counter correct);
  `exportPayload` scopes + counters.
- UI: visual smoke (T4 checklist in the plan).

## 5. Deliberately NOT in M9a

- No merge/overwrite of existing sessions on import (additive only).
- No export of key files; no passphrase extraction from the ssh-agent.
- No third-party format import (PuTTY/WinSCP/Termius) — backlog candidate.
- No iCloud/sync mechanism.
