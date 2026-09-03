# Cyberduck Import — Design

**Status:** approved in conversation 2026-09-03 (the maintainer's answers
are recorded in §0); spec written the same day. Plan follows.

## 0. What the maintainer decided

1. Secrets are optional: a checkbox in the preview, "take passwords and
   S3 secrets from the keychain"; default off.
2. The preview lists every bookmark with a checkbox; a session is
   *known* by Cyberduck UUID or by host + port + user (+ protocol) —
   never by name; known-and-changed rows are marked and offer
   overwrite.
3. An update overwrites everything Cyberduck knows; two switches take
   tags (Cyberduck labels) and secrets out of it.
4. The session record gains two columns for provenance —
   `importSource` and `importID` — so other programs can follow.
5. A GUI mockup was shown and accepted (the preview sheet in §4).

## 1. Measured starting point (2026-09-03)

- Cyberduck keeps one XML plist per bookmark under
  `~/Library/Group Containers/G69SCX94XU.duck/Library/Application Support/duck/Bookmarks/<UUID>.duck`.
  Keys seen on the maintainer's machine (8 bookmarks: 3 sftp, 3 ftp,
  2 s3): `Protocol`, `Hostname`, `Port`, `UUID`, `Provider` (always),
  `Username`, `Nickname`, `Private Key File`, `Path`, `Labels`,
  `Download Folder`, `Access Timestamp` (sometimes). Passwords and S3
  secret keys are not in the file; Cyberduck stores them as Internet
  passwords in the macOS keychain (server = hostname, account =
  username, protocol and port set).
- macSCP's import path: `SessionExportCodec` decodes a
  `SessionExportPayload` (groups + `ExportedSession` field bags);
  `SessionImportPlanner` plans against the store, resolves duplicates
  through `ImportConflictArbiter` (skip / replace / rename, the
  `ImportConflictSheet`), refuses unusable bags through the backend
  schema (2026-09-02), and `applyImport` writes sessions and secrets.
  `FieldVocabulary` already builds the "same connection?" key the
  planner uses for duplicates — host/port/user, case-folded host.
- `SSHConfigImporter` is the one existing external source (read-only
  overlay of `~/.ssh/config`, with `HiddenImportStore` for aliases the
  user hides). It does not create sessions, so it is not the pattern
  here; the export/import path is.
- `StoredSession` is additive-Codable (`LegacyStoredSession` shows the
  convention: new fields decode as optional/default).

## 2. Architecture

```
BookmarkSource (protocol)          CyberduckBookmarkSource (first conformer)
  static id: String  ("cyberduck")   locate() → default folder, else nil
  locate() -> URL?                   read(from:) → [ExternalBookmark]
  read(from: URL) throws -> [ExternalBookmark]

ExternalBookmark                  ImportPreviewPlanner
  source, externalID, nickname,     matches bookmarks against the store:
  protocol (.sftp/.s3/.ftp/.other),   .new / .knownUnchanged / .knownChanged([FieldChange])
  host, port, username,               / .unsupported(reason)
  keyPath, path, labels             builds a SessionExportPayload from the
                                    selected rows (+ per-row "update" flag)
                                    → SessionImportPlanner → applyImport
```

- **`BookmarkSource`** (Core, `Sessions/ExternalImport/`): two methods.
  `locate()` returns the source's default folder when it exists;
  `read(from:)` parses every bookmark file in a folder (the user can
  point it at any folder through a picker when `locate()` is nil).
  FileZilla and Transmit later add a conformer each; nothing else
  changes.
- **`ExternalBookmark`**: the source-independent value the preview and
  the planner work with. Unsupported protocols are carried through with
  their name so the preview can grey them out and count them.
- **Provenance on `StoredSession`**: `importSource: String?`
  (the source id, e.g. `"cyberduck"`), `importID: String?` (the
  source's own id, the Cyberduck UUID), `importedAt: Date?`. Additive,
  optional, absent for hand-made sessions; exported and re-imported
  with the session (they are plain fields of the bag). A duplicated
  session (`SessionDuplication`) drops all three — the copy did not come
  from Cyberduck.
- **`ImportPreviewPlanner`** (Core): pure function of
  `[ExternalBookmark]` × store contents × switches → `[PreviewRow]`.
  Matching, in order: (1) a stored session with the same
  `importSource`+`importID`; (2) `FieldVocabulary`'s connection key
  (host case-folded, port, user, protocol) against every stored session
  of that kind — the key the planner already uses, so "known" here and
  "duplicate" there can never disagree. Names are never compared.
  A `.knownChanged` row lists `FieldChange { field, old, new }` for every
  Cyberduck-known field that differs (host, port, username, key path,
  bucket/endpoint, labels when the tags switch is on, nickname).
- **Applying**: selected `.new` rows become fresh `ExportedSession`s;
  selected `.knownChanged` rows become `ExportedSession`s carrying the
  stored session's `id` with `replacesExisting: true` (the planner's
  existing seam) and only the Cyberduck-known fields replaced — name,
  group, tags (unless the switch is on), notes, colour, secrets (unless
  the switch is on) are copied from the stored record first. Everything
  then flows through `SessionImportPlanner` and the existing conflict
  sheet, which still handles a name collision with an unrelated session.

## 3. Translation

| Cyberduck | macSCP |
|---|---|
| `Protocol` `sftp` | SSH session; `Hostname`, `Port` (default 22), `Username`; `Private Key File` → `SSHField.keyPath`, `authKind = .privateKey`; else `.password` (agent is never inferred) |
| `Protocol` `s3` | S3 session; `Hostname` → endpoint (`s3.amazonaws.com` → AWS default endpoint, anything else → custom endpoint with `Port`); `Username` → access key; `Path` → bucket, empty → bucket-list mode (`startsAtBucketList`); region stays the schema default |
| `Protocol` `ftp`, `ftps`, `dav*`, `azure`, `googlestorage`, `dropbox`, … | `.unsupported(protocolName)` — greyed, counted, never imported (WebDAV bookmarks are *also* unsupported in this first cut: Cyberduck's `dav`/`davs` carry a path-shaped URL we have not measured; a follow-up measures and adds it) |
| `Nickname` | session name (falls back to `Hostname`) |
| `Labels` | tags (created if absent), only with the tags switch |
| `UUID` | `importID`; `importSource = "cyberduck"` |
| `Download Folder`, `Provider`, `Access Timestamp` | ignored |

Key files are referenced by path, never copied; a path that does not
exist at import time is kept (the user may restore it) and the preview
says "key file missing" in the row's detail.

## 4. What the user sees

Menu: File → Import → "From Cyberduck…" beside the existing "Import
sessions…". If the default folder exists the sheet opens at once;
otherwise a folder picker first.

The sheet (mockup accepted): title, a one-line count, a table with
checkbox · name · protocol badge · target (`user@host:port` or
`endpoint · bucket`) · status: "New" (checked), "Known, unchanged"
(unchecked), "Changed: port 22 → 2222" (checked, tinted), "Not supported
yet" (disabled). Below: switch "Take passwords and S3 secrets from the
keychain (macOS asks per entry)", switch "Put into group Cyberduck,
labels as tags" (the group is a picker defaulting to a group named
after the source, created on demand), a summary line "n import, m of
them update · k skipped · u not supported", Cancel / Import. After
Import the existing conflict sheet appears only if a name collides with
an unrelated session; then the existing result alert, extended by one
line "u updated".

Keychain: with the switch on, the applier asks the keychain for
Cyberduck's Internet-password item per selected row
(`SecItemCopyMatching`, `kSecClassInternetPassword`, server/account/port/
protocol from the bookmark); macOS shows its own consent prompt per item
(the user may "Always Allow"); a refusal or a missing item leaves the
secret empty and the result alert counts "s secrets not read". macSCP
never writes to Cyberduck's items and never caches what it read outside
its own `SecretStore` slot for the session.

## 5. Errors

- Folder unreadable / no `.duck` files: one sentence in the sheet, no
  table.
- A malformed plist: the row appears as "unreadable" with the file
  name, unchecked, disabled; the rest import.
- The planner's existing refusals (unusable bag, drops-on-load) are
  reported as today under "rejected", by name.

## 6. Testing

- `CyberduckBookmarkSourceTests`: fixture `.duck` plists in the test
  bundle — sftp with key file, sftp with password, s3 with bucket, s3
  without bucket, ftp, a `davs` one, a malformed one, one with labels;
  never the maintainer's real folder (the default-folder locator is
  tested against a temp directory injected as the home).
- `ImportPreviewPlannerTests`: matching by `importID`, by connection
  key with a different name, no match; `.knownChanged` lists exactly the
  differing fields; the tags switch moves `labels` in and out of the
  change list; a changed nickname alone is `.knownChanged` (name is a
  Cyberduck-known field) but never a *match* criterion.
- Applying: a `.knownChanged` row keeps the stored record's group,
  notes, colour and secret when the switches are off; replaces tags and
  secret when on; `importedAt` refreshed; the planner's invariants
  (exactly-once secrets, conflict sheet for unrelated collisions) —
  through the existing `SessionImportPlanner` tests' fixtures.
- Keychain reading behind `MACSCP_KEYCHAIN=1`: an item written by the
  test under Cyberduck's shape (server/account/protocol), read back
  through the reader, deleted in a `defer`; the consent prompt cannot be
  tested — the test runs in the test process's own ACL.
- App: `ImportFromCyberduckGuardTests` — the menu entry, the sheet's
  four states, the two switches and the summary line are wired
  (`SwiftSource` views, positive anchors); four catalogs for every new
  key; German du.

## 7. Not in this design

- FTP/FTPS, WebDAV, cloud-provider bookmarks (grey rows until their
  backends exist; WebDAV needs one measurement).
- Cyberduck's History and Transfers folders.
- A background watcher that re-imports automatically — re-import is
  the same menu entry, run again.
- FileZilla / Transmit sources (the protocol is shaped for them; each
  is its own spec).
