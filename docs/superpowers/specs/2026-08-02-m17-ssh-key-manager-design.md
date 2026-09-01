# M17 — SSH Key Manager (Design/Spec)

**Date:** 2026-08-02
**Status:** approved (brainstorm), ready for writing-plans
**Branch:** `develop`
**Predecessors:** M3b (`SSHPrivateKeyLoader`, ed25519 loading), M10a/M3c (known-hosts store pattern), S3 program M12–M16 complete.

## Goal

A dedicated Settings tab „SSH-Schlüssel" (SSH Keys): generate ed25519/rsa/ecdsa
keys (with name, comment, optional passphrase), list, delete, copy/export the
public key. Generated **ed25519** keys are directly selectable as auth in the
connection form and in login sets; their passphrase is held centrally in the
Keychain and resolved automatically on connect.

## Starting point (verified)

- **Loading today:** `SSHPrivateKeyLoader` (`Sources/macSCPCore/SSH/SSHPrivateKeyLoader.swift:15`) loads **only ed25519** (OpenSSH format, optionally passphrase-encrypted) via Citadel's `Curve25519.Signing.PrivateKey(sshEd25519:decryptionKey:)`. RSA/ECDSA loading does not exist.
- **Reference:** a `keyPath: String?` (file path) everywhere — `StoredSession.keyPath`, `JumpSpec.keyPath`, `LoginSet.keyPath`, `ConnectionViewModel.keyPath`, `ResolvedLogin.keyPath`. No key registry. Form + login set editor: `TextField` + `fileImporter` "…" button, writes the raw path back.
- **swift-crypto** (`Package.swift:12`, `from: "3.0.0"`) is present; `Curve25519.Signing` is already used. **Key generation + OpenSSH serialization do not exist.**
- **`ssh-keygen` precedent:** the tests generate keys via `/usr/bin/ssh-keygen` `Process()` (`Tests/macSCPCoreTests/SSHPrivateKeyLoaderTests.swift:14`, flags `-t ed25519 -f <path> -N <pass> -q -C <comment>`).
- **`SecretStore`:** UUID-addressed (`savePassword`/`password`/`deletePassword` for a `UUID`), `kSecAttrService="dev.noix.macSCP"`. Login set secrets live under `set.id` — the same pattern can be used for a key.
- **Settings:** `SettingsView` (`Sources/MacSCPApp/SettingsView.swift:12`) is a `TabView` with 5 tabs; a sixth `.tabItem` slots right in. Window fixed at 460×460.
- **`~/.ssh`:** is written **nowhere** (strictly read-only; known hosts live in an app folder). A write path to `~/.ssh` would be the first in the project.

## Decisions (maintainer, 2026-08-02)

1. **Storage location:** an app-owned folder, private files 0600 (directory 0700); **no** writing to `~/.ssh`.
2. **Generation:** shell out to `/usr/bin/ssh-keygen` (argument array, no shell injection).
3. **Reference:** path-based — `keyPath` points to the app's key file, **no** model/export rework. The picker fills `keyPath`.
4. **Passphrase:** held centrally in the Keychain under `key.id`; resolved automatically on connect (path lookup), otherwise falls back to the existing form/session flow.
5. **Type scope:** the generate dialog offers ed25519/rsa/ecdsa (+ RSA bit length). **Only ed25519 is connectable as a macSCP login** (loader boundary); RSA/ECDSA are generatable + pub-exportable, **not** offered in the login picker, and marked "not connectable" in the list.

## Architecture

### Core

**`ManagedKey`** (model, Core):
```swift
public struct ManagedKey: Identifiable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    public var comment: String
    public var type: KeyType          // .ed25519 / .rsa(bits:Int) / .ecdsa
    public var fingerprint: String    // "SHA256:…"
    public var publicKeyOpenSSH: String  // "ssh-ed25519 AAAA… comment"
    public var createdAt: Date
    public var hasPassphrase: Bool
    public var fileName: String        // relative to the key directory
}
```
`KeyType`: `enum` with `.ed25519`, `.rsa(bits: Int)`, `.ecdsa`; `.isConnectable` → true only for `.ed25519`.

**`SSHKeyGenerator`** (Core, testable):
```swift
func generate(type: KeyType, comment: String, passphrase: String?, into dir: URL)
    throws -> GeneratedKey   // { privateKeyURL: URL, publicKeyOpenSSH: String, fingerprint: String }
```
- Calls `ssh-keygen` with an argument array: `-t <ed25519|rsa|ecdsa>`, `-b <bits>` (RSA only), `-f <appfile>`, `-N <passphrase | "">`, `-C <comment>`, `-q`. Non-zero exit → a typed error.
- Reads the generated `.pub` (OpenSSH line), ensures `chmod 0600` on the private file, derives the fingerprint (existing `HostKeyFingerprint` path or `ssh-keygen -lf`).
- **Documentation note:** the passphrase briefly appears in `argv` (visible only same-user via `ps`) — an accepted minor issue; `ssh-keygen` offers no stdin passphrase path for generation.

**`ManagedKeyStore`** (Core): atomic JSON writing like `KnownHostsStore` (its own App Support folder; the key file folder is a subfolder of it, 0700). **Secret-free** (no passphrase, no private-key bytes in the JSON). API:
- `all() -> [ManagedKey]`
- `add(_ key: ManagedKey)`
- `remove(id: UUID)` — deletes the metadata **and** the private/pub file **and** (via the SecretStore) the Keychain slot under `id`
- `key(forPath: String) -> ManagedKey?` — path lookup (app key file → managed key) for passphrase resolution

**Passphrase resolution on connect:** an addition to the existing resolution path (where `keyPath` + passphrase are determined for `SSHPrivateKeyLoader`): before taking the passphrase from the form/session, check `ManagedKeyStore.key(forPath: resolvedKeyPath)`; if a managed key with `hasPassphrase` exists, use the passphrase from `SecretStore.password(for: key.id)`. Otherwise, the existing path unchanged. **`SSHPrivateKeyLoader` stays untouched.**

### App

**Settings tab „SSH-Schlüssel"** (sixth `.tabItem`, `systemImage: "key"`):
- **List:** per key: name, type badge (`ED25519`/`RSA`/`ECDSA`), short fingerprint, comment, creation date, a lock icon when there's a passphrase. RSA/ECDSA carry a subtle „nicht als macSCP-Login verbindbar" (not connectable as a macSCP login) note.
- **„Erzeugen…"** (Generate…) (sheet): name, comment, type picker (ed25519/rsa/ecdsa), for RSA a bit-length picker (2048/3072/4096, default 3072), optional passphrase (SecureField + confirmation). "Generate" → `SSHKeyGenerator` → creates the file, stores the passphrase (if set) in the Keychain under a new key ID, writes metadata to the store.
- **„Public-Key kopieren"** (Copy Public Key) (NSPasteboard), **„Public-Key exportieren…"** (Export Public Key…) (`fileExporter` → `.pub`).
- **„Löschen"** (Delete) (confirmation) → store `remove(id:)` (file + `.pub` + Keychain). A warning with a best-effort count when sessions/login sets reference this `keyPath` (like the `usageCount` display on login sets).
- Actions as buttons **and** a per-row context menu.
- Window height may need adjusting (currently fixed 460×460); failing that, a scrollable list at fixed height.

**Form + login set editor:** the existing `keyPath` block additively gets a „Verwalteter Schlüssel" (Managed Key) menu listing the store's **ed25519** keys (name + short fingerprint) that fills `keyPath` with the app file path on selection. Free text + "…" browse stay alongside it. A „Schlüssel verwalten…" (Manage Keys…) button opens the Settings tab (analogous to "Manage Logins…").

## Tests

**Core (Swift Testing):**
- `ManagedKeyStore`: CRUD, atomic secret-free JSON, `key(forPath:)`, `remove` deletes the file + Keychain slot (`MACSCP_KEYCHAIN=1`).
- `SSHKeyGenerator` (real `/usr/bin/ssh-keygen`): ed25519 → file exists + 0600, `.pub` in OpenSSH format, fingerprint parseable; **roundtrip:** a generated ed25519 key loads via `SSHPrivateKeyLoader`; a passphrase-protected key requires the passphrase; RSA/ECDSA generatable.
- Passphrase resolution: a managed key path with a Keychain passphrase returns it; a foreign path falls back to the form flow.

**App:** build-verified + runtime idle-CPU smoke test (new tab/list).

## Security / invariants

- Key bytes never logged; passphrase exclusively in the Keychain under `key.id`; the JSON store is secret-free.
- Private files 0600, directory 0700, in the App Support folder — **no** writing to `~/.ssh`.
- `ssh-keygen` via argument array (no shell injection).
- `remove` cleans up the private/pub file + Keychain slot.
- No new external dependency (swift-crypto is already present; generation via the system `ssh-keygen`).

## L10n

All new user-facing strings (tab label, list/action labels, generate dialog,
type/bit-length options, "not connectable" note, delete/usage warning, form
menu) in EN/DE/FR/PL, typographic characters, FR/PL AI-generated (native
review before release).

## Not in M17 (→ v2)

- Key **import** of existing keys.
- Rolling out `authorized_keys` to the server.
- RSA/ECDSA as a **connectable** macSCP login (loader boundary — would need RSA/ECDSA loading in `SSHPrivateKeyLoader`).
- `managedKeyID` model reference (the path lookup is enough for v1).
- A switchable secret backend (1Password vault) — its own future milestone with a feasibility round.

## Files affected

- `Sources/macSCPCore/SSH/ManagedKey.swift` (+ `KeyType`) — **create**.
- `Sources/macSCPCore/SSH/SSHKeyGenerator.swift` — **create**.
- `Sources/macSCPCore/SSH/ManagedKeyStore.swift` — **create**.
- Connect resolution path (Core, where `keyPath`+passphrase are determined for `SSHPrivateKeyLoader` — `ConnectionViewModel`/`LoginResolver` area) — **modify** (passphrase lookup).
- `Sources/MacSCPApp/SettingsView.swift` + new `SSHKeysSettingsTab` — **modify/create**.
- `Sources/MacSCPApp/ConnectionFormView.swift`, `Sources/MacSCPApp/LoginSetsSheet.swift` — **modify** (key picker menu).
- `Sources/MacSCPApp/Resources/{en,de,fr,pl}.lproj/Localizable.strings` — **modify**.
- `Tests/macSCPCoreTests/…` — `ManagedKeyStoreTests`, `SSHKeyGeneratorTests`, passphrase resolution test — **create**.
