# M19 — Login set import/export + unified conflict resolution (Design/Spec)

**Date:** 2026-08-02
**Status:** approved (brainstorm), ready for writing-plans
**Branch:** `develop`
**Predecessors:** M9a (session export/import), M5b (transfer conflict dialog), M10b (login sets), M17 (managed SSH keys), M18 (login sets overlay with search/context menu, SSH keys sheet).

## Goal

Export and import login sets — with optional secrets and optionally embedded
managed keys. At the same time, **all** import paths (login sets **and**
sessions) get the same conflict dialog, so imports behave the same
everywhere.

## Starting point (verified)

- **`SessionExportCodec`** (`Sources/macSCPCore/Sessions/SessionExportCodec.swift`): envelope with `format`/`version`/`encrypted` (`formatName = "macscp-sessions"`, `currentVersion = 1`); unencrypted = plaintext JSON, encrypted = PBKDF2 (600 000 iterations) + AES-GCM; `probe(_:)` detects encryption without decrypting; hardened against tampered files (the iteration count is clamped to `> 0 && <= 10_000_000` before it reaches CommonCrypto). **The envelope carries a concrete `payload: SessionExportPayload?`, and the format name is hardcoded** — not reusable without rework.
- **Secrets in the session export:** `SessionExportPayload.includesSecrets: Bool` as opt-in; `password`/`jumpPassword`/`s3SecretAccessKey` are optional fields; the app warns in two stages (`isConfirmingPlaintext`) for an unencrypted export that includes secrets.
- **`SessionImportPlanner`**: a pure function `plan(existing:existingGroups:incoming:) -> SessionImportPlan` with `groupsToCreate`/`sessionsToImport`/`skipped`; the duplicate key is `(host, port, username)`; duplicates are **silently skipped** and only counted. Keychain writes happen only in `applyImport`, in the app.
- **Transfer conflict pattern (M5b):** `ConflictResolution { overwrite, skip, rename }` + a decider closure `(TransferConflict) async -> (resolution: ConflictResolution, applyToAll: Bool)?`; `applyToAll` sets a rule for the rest of the queue (`queueRule`, reset once the queue drains). This is the established template.
- **`LoginSet`** carries **no** secrets (the `LoginSetStore` docs say so explicitly) — those live in the Keychain under `set.id`. Fields: `id`, `name`, `username`, `authKind`, `keyPath`, `kind` (ssh/s3), `accessKeyID`.
- **Managed keys (M17/M18):** `ManagedKeyStore` with `keyDirectory` (0700), files at 0600 under UUID names, passphrase in the Keychain under `key.id`; `key(forPath:)` resolves a path to a managed key; `SSHKeyImporter.inspect` derives type/fingerprint/public key.
- Session import **never** imports login sets (`loginSetID` is always `nil`).

## Decisions (maintainer, 2026-08-02)

1. **Secrets:** opt-in as with session export (off by default; encrypted preferred; two-stage plaintext warning).
2. **Keys:** managed keys are **embedded**, so a set works immediately on another machine.
3. **Embedding boundary:** **only managed** keys; external paths (e.g. `~/.ssh/id_ed25519`) are **never read**. Its own toggle, "Embed key files", with its own warning.
4. **Import conflicts:** a dialog per conflict (skip / replace / rename) **with "apply to all"** — and this dialog applies **uniformly to session import too**.

## Architecture

### 1. Generic codec + own format

The envelope/crypto part becomes generic over the payload type and takes the
format name as a parameter. `SessionExportCodec` stays as a thin facade with
an **unchanged public API** on top; a `LoginSetExportCodec` sits alongside it.
That way the hardened crypto exists **once** — a future fix lands in both
places. The existing session codec tests are the regression guard for the
rework.

*Rejected:* a separate codec as a copy (crypto maintained twice — a finding
gets fixed in one place and forgotten in the other); extending the session
format (mixes two things that are exported separately).

**Format:** `format: "macscp-logins"`, `version: 1`, its own UTType
(`macscp-logins`), so the open dialog offers only matching files and an
accidentally chosen session file is clearly rejected.

**Payload:**

```swift
public struct LoginSetExportPayload: Codable, Equatable, Sendable {
    public var includesSecrets: Bool
    public var includesKeyFiles: Bool
    public var sets: [ExportedLoginSet]
}

public struct ExportedLoginSet: Codable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    public var kind: ConnectionKind          // ssh | s3
    public var username: String
    public var authKind: StoredSession.AuthKind
    public var keyPath: String?
    public var accessKeyID: String?
    /// Only when `includesSecrets` — the set's Keychain secret at export time.
    public var secret: String?
    /// Only when `includesKeyFiles` AND the keyPath resolves to a managed key.
    public var embeddedKey: EmbeddedKey?
}

public struct EmbeddedKey: Codable, Equatable, Sendable {
    public var fileContents: Data            // the private key file
    public var name: String
    public var comment: String
    public var type: KeyType
    public var fingerprint: String
    public var hasPassphrase: Bool
    /// Only when `includesSecrets` — the managed key's Keychain passphrase.
    public var passphrase: String?
}
```

### 2. Shared conflict resolution (Core + App)

A new building block used by **both** import paths, modeled on the transfer
queue:

```swift
public enum ImportConflictResolution: Equatable, Sendable { case skip, replace, rename }

public struct ImportConflict: Equatable, Sendable {
    public var itemName: String          // e.g. the login set / session name
    public var kindLabel: String         // what collides, for the dialog text
}

public typealias ImportConflictDecider =
    @Sendable (ImportConflict) async -> (resolution: ImportConflictResolution, applyToAll: Bool)?
```

- `applyToAll == true` sets the answer as a rule for all further conflicts in **this** import; `nil` aborts the import (nothing gets applied).
- **Login set import:** the collision key is the **name** (case-insensitive, trimmed).
- **Session import:** the existing key `(host, port, username)` stays; only the handling changes from "silently skip" to "ask". `SessionImportPlan.skipped` is kept for the summary.
- **`replace` semantics (security-relevant):** the existing entry is overwritten, **including its Keychain secret**; the entry keeps its `id`, so sessions referencing a login set keep pointing to it. The dialog states this explicitly.
- **`rename`:** the imported entry gets a unique name (suffix), the existing one is left untouched; the imported one gets a **fresh `id`**.
- **`skip`:** the imported entry is discarded.

**Behavior change (deliberate):** session import will now ask instead of silently skipping. "Skip + apply to all" reproduces the old behavior in one click.

**App:** a shared conflict sheet (name, what collides, three actions + "apply to all remaining"), styled after the transfer conflict sheet, used by both import flows.

### 3. Embedded keys

**Export:** for sets with `authKind == .privateKey`, `ManagedKeyStore.key(forPath:)`
checks whether the path is a managed key. Only then — and only with the
"Embed key files" toggle on — is `embeddedKey` populated (file contents +
metadata; `passphrase` only additionally when the secrets toggle is also on).
**External paths are never read.**

**Import:** an `embeddedKey` is handled like a key import: fresh `UUID`,
write the file into `ManagedKeyStore.keyDirectory`, set **0600**, explicitly
harden the directory to **0700** (the Foundation trap from M17/M18:
`createDirectory` does not re-harden an existing directory), metadata into
the store, passphrase (if present) into the Keychain under the new key ID.
The imported set's `keyPath` then points at the **new local path**. If any
step fails, the file and the Keychain slot are removed again (no orphaned
artifact) — as with a manual import.

**Without an embedded key:** the set is created; if the file does not exist
on the target machine, it is flagged in the list as **"key missing"**.

### 4. App UI

**Export:** "Export…" button in the login sets overlay (all sets; only the
selected ones when a selection is made) and "Export…" in the row context
menu (single set). Export sheet modeled on the session one: toggles
**"Include passwords"** + **"Embed key files"**, encrypted/unencrypted
choice, password + confirmation, two-stage plaintext confirmation as soon as
secrets **or** keys would go out unencrypted.

**Import:** "Import…" button in the overlay + "Import logins…" menu item in
the Sessions menu. Flow: choose file → `probe` → password sheet if needed →
planning → conflict dialog per collision → apply → summary
("X imported, Y replaced, Z skipped"; plus a note on sets with a missing
key).

## Tests

- **Codec (Core):** roundtrip unencrypted + encrypted; wrong password → typed error; a `macscp-sessions` file as a login import → clearly rejected; unknown version → `unsupportedVersion`; tampered iteration count is rejected. The existing session codec tests keep running **unchanged** (regression guard for the generic rework).
- **Conflict resolution (Core):** `skip`/`replace`/`rename` each individually; `applyToAll` applies to all following conflicts; `nil` aborts (nothing applied) — for **both** planners.
- **Secret hygiene:** an export without opt-in contains neither secrets nor key material (checked against the produced file).
- **Key embedding:** roundtrip with a managed key — after import the file exists at 0600, is registered in the store, `keyPath` points at it; an **external** path is not read in.
- **App:** build-verified, catalog parity, idle-CPU smoke.

## Security / invariants

- Secrets and key material only on explicit opt-in in the export; unencrypted export of them only after two-stage confirmation.
- External key files are never read; `~/.ssh` stays read- and write-taboo except by explicit user choice.
- Imported keys: 0600 / directory 0700, passphrase only in the Keychain under the new key ID, cleanup on failure.
- `replace` deliberately overwrites the Keychain secret too — named in the dialog.
- No key material and no secrets in logs or error texts.
- No new external dependency.

## Not in M19

- A batch overview instead of individual dialogs (deliberately rejected — would break uniformity with the transfer dialog).
- Embedding **external** key files.
- Known-hosts/SSH-key export as its own formats (SSH keys have their own path from M18).

## Affected files

- `Sources/macSCPCore/Sessions/SessionExportCodec.swift` — **modify** (generic envelope/crypto core, facade unchanged).
- `Sources/macSCPCore/Sessions/LoginSetExportCodec.swift` — **create** (payload + codec).
- `Sources/macSCPCore/Sessions/ImportConflict.swift` — **create** (resolution/conflict/decider).
- `Sources/macSCPCore/Sessions/LoginSetImportPlanner.swift` — **create**.
- `Sources/macSCPCore/Sessions/SessionImportPlanner.swift` — **modify** (decider instead of silent skip).
- `Sources/MacSCPApp/ImportConflictSheet.swift` — **create** (shared sheet).
- `Sources/MacSCPApp/LoginSetsSheet.swift` — **modify** (export/import buttons + context menu entry, "key missing" flag).
- `Sources/MacSCPApp/SessionExportImportSheets.swift` — **modify/extend** (login set export sheet on the same pattern).
- `Sources/MacSCPApp/ContentView.swift`, `MacSCPApp.swift` — **modify** (fileExporter/Importer, menu item, conflict sheet wiring for both imports).
- `Sources/MacSCPApp/Resources/{en,de,fr,pl}.lproj/Localizable.strings` — **modify**.
- `Tests/macSCPCoreTests/…` — codec, conflict, and embedding tests.
