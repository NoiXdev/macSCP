# M18 — UI polish (search, SSH Keys sheet, context menu, settings sidebar) — Design/Spec

**Date:** 2026-08-02
**Status:** approved (brainstorm), ready for writing-plans
**Branch:** `develop`
**Predecessors:** M11k (FileSearch), M9a (session export pattern), M10a/M10b (Known Hosts/Login Sets sheets), M11f (Hidden Imports sheet), M17 (SSH key manager).

## Goal

Four related UI improvements: (1) a shared search bar across all list sheets, (2) moving SSH key management out of settings into its own sheet (with import/export), (3) a row context menu in the Login Sets sheet, (4) the settings window as sidebar navigation with protocol-specific sections.

## Starting point (verified)

- **Sheets:** `LoginSetsSheet` (List, footer buttons New/Edit/Delete, **no** search, **no** context menu), `KnownHostsSheet` (Table, **its own** ad-hoc contains search), `HiddenImportsSheet` (List, no search), `AuditLogSheet` (List, no search). All in the 720×460 rhythm, presented via the `TabCommands` bridge (`showKnownHosts`/`showLogins`/`showHiddenImports`) + the "Sessions" menu items + `@State` + `.sheet(isPresented:)` in `ContentView`.
- **Search:** `FileSearch.compile(query:isRegex:) -> Result<FileSearchPredicate, FileSearchError>` + `FileSearchPredicate.matches(_ name: String) -> Bool` (Core, M11k, tested). `FileSearchBar` is the existing App UI, but specific to file lists.
- **SSH keys:** today a settings tab (`SSHKeysSettingsTab`, M17) with a list + `GenerateKeySheet` + copy/export/delete; reaches the core APIs `ManagedKeyStore`/`SSHKeyGenerator`/`KeychainSecretStore`. The „Schlüssel verwalten…"-button (form/login-set editor) currently uses `SettingsLink`.
- **Settings:** `SettingsView` = `TabView` with 6 tabs (General/Transfers/Open-with/Terminal/Shortcuts/SSH-Keys), fixed `.frame(width: 460, height: 460)`. Tab `struct`s cleanly injected. `GeneralSettingsTab` overloaded (language/hidden/menu bar/columns/auto-refresh/updates). No `.searchable` pattern in the project; no ready-made SwiftUI building block for a settings sidebar.
- **Login-set context-menu template:** `SessionSidebar` already has a row `.contextMenu` (Connect/Edit/Export/Rename/Delete).
- **Security:** SSH key private files sit at 0600 in the App folder; passphrase in the keychain under `key.id`; no writing to `~/.ssh` (M17 invariants stay).

## Decisions (maintainer, 2026-08-02)

1. **Scope:** M18 = search + SSH-Keys sheet + login-set context menu + settings sidebar. **Login-set import/export stays its own milestone M19** (encrypted codec subsystem).
2. **Search:** the full `FileSearch.compile` mechanism (contains + optional regex + error display), shared component, applied to **Login Sets, Known Hosts, Hidden Imports, Audit Log, SSH Keys**.
3. **SSH keys:** out of settings, its own sheet like Logins/Known Hosts; **with import** (pulled forward from M17-v2) and **private-key export with a warning**; row context menu incl. **rename**.
4. **Settings:** **sidebar navigation** (macOS 15 style); „General" is split into **Allgemein** + **Ansicht**; **protocol sections SSH/S3** with protocol-specific settings (presigned expiry → S3, external-terminal target → SSH).

## Architecture

### 1. Shared search component (App)

New App view **`SheetSearchField`** (more compact than `FileSearchBar`, without filter/jump picker — sheets always filter):
- Binds `@Binding var text: String` + `@Binding var isRegex: Bool`; shows a search field + regex toggle + error text.
- Delivers the compiled `FileSearchPredicate` to the host view (e.g. via an `onChange`-derived `@State`, or the host view calls `FileSearch.compile` itself with `text`/`isRegex`). Empty/whitespace query → matches everything; invalid regex → `FileSearchError` → error text, **no** silent 0-match list.
- Each sheet filters its own list: `items.filter { predicate.matches(searchString(for: $0)) }` with a sheet-specific `searchString`:
  - Login Sets: `"\(name) \(username) \(accessKeyID ?? "")"`
  - Known Hosts: `"\(host) \(fingerprint)"` (replaces the existing contains search)
  - Hidden Imports: `alias`/host
  - Audit Log: event summary (action + host/target)
  - SSH Keys: `"\(name) \(comment) \(fingerprint)"`

**No new Core code** — just the App view + five integrations. Pure SwiftUI, build-verified.

### 2. SSH key management as its own sheet (App)

New **`SSHKeysSheet`** (structure like `LoginSetsSheet`): title, `SheetSearchField`, list (name, type badge, short fingerprint, comment, date, lock; RSA/ECDSA „nicht verbindbar" notice), footer buttons, fixed 720×460. The M17 `SSHKeysSettingsTab` content + `GenerateKeySheet` move over; `ManagedKeyStore`/`SSHKeyGenerator`/keychain core unchanged.

**Actions (footer + row `.contextMenu`):**
- **Generate…** (M17, unchanged)
- **Import…** — `fileImporter` selects an OpenSSH private-key file; copy into the App key folder (0600); derive type + fingerprint via `ssh-keygen -l -f`, public key via `ssh-keygen -y -f` (with a passphrase prompt for a passphrase-protected key); ask for name/comment; optional passphrase into the keychain under a new `key.id`; `ManagedKey` with `add`. On failure, clean up the copied file + keychain slot (no orphaned artifact).
- **Copy public key** / **Export public key…** (M17, unchanged)
- **Export private key…** — copies the private key file to an `NSSavePanel` location, **behind a confirmation with a warning** („Der private Schlüssel verlässt den geschützten Speicher"); the file's passphrase encryption is preserved.
- **Rename…** — change a key's name/comment (`ManagedKey` upsert under the same `id`; file/keychain untouched).
- **Delete…** (M17, `store.remove(id:secrets:)`).

**Reachability (same bridge as Logins/Known Hosts):** new `TabCommands.showSSHKeys` + a „Sessions" menu item **„SSH-Schlüssel…"** + `@State showSSHKeysSheet` + `.sheet(isPresented:)` in `ContentView`. The M17 „Schlüssel verwalten…" button (form/login-set editor) now calls this sheet **directly** (replacing `SettingsLink`). The settings tab „SSH Keys" is removed from `SettingsView`.

**Security:** M17 invariants stay — private files 0600, passphrase only in the keychain under `key.id`, no writing to `~/.ssh`, `ssh-keygen` via an argument array; the private-key export is the only deliberate way out of the protected space, behind a confirmation.

### 3. Login-set row context menu (App)

On `LoginSetsSheet.row`, a `.contextMenu { Bearbeiten…; Löschen… }` that calls the same closures as the footer buttons (`editorTarget` and the delete `confirmationDialog` respectively). A right click selects the row first. Footer buttons stay (additive). No new L10n keys (Edit/Delete already exist).

### 4. Settings window → sidebar navigation (App)

Switch `SettingsView` from `TabView` to **`NavigationSplitView`**: on the left a `List` of sections (with SF Symbols), on the right the detail = the content of the selected section. Existing section `struct`s reused as the detail; `GeneralSettingsTab` split into two.

**Sections:**
- **Allgemein** — language/relaunch, menu bar icon, updates
- **Ansicht** — hidden files, file columns, auto-refresh
- **Übertragung** — parallelism, bandwidth *(protocol-neutral)*
- **Öffnen mit** — editor/extension rules
- **Terminal** — font/size/cursor of the built-in terminal
- **Kurzbefehle** — keyboard-shortcut overview
- **Protokolle** (group):
  - **SSH** — external-terminal target (moved here from „Terminal"); a „SSH-Schlüssel verwalten…" button opens the sheet (section 2)
  - **S3** — presigned-URL default expiry (moved here from „Übertragung"); home for future S3 settings

The SSH-Keys section is dropped (now a sheet). Window size adjusted to the split layout (wider). **Idle-CPU smoke test** before shipping (M11n lesson: SwiftUI layout containers on macOS 26 can run into an infinite loop).

**L10n:** new section titles („Allgemein"/„Ansicht"/„Protokolle"/„SSH"/„S3"), search placeholder/regex/error, import/private-export/rename/warning strings, „SSH-Schlüssel…" menu item — EN/DE/FR/PL, typographic characters, FR/PL AI-generated.

## Tests

- **Core:** no new Core code except possibly a small `searchString` helper per model (if in Core); the search mechanism (`FileSearch`) is already tested. If SSH key **import** gets a Core function (copy file + `ssh-keygen` derivation), a unit/integration test against real `ssh-keygen` (like M17): a key generated via `ssh-keygen` is imported → fingerprint/type/public key match, loads via `SSHPrivateKeyLoader`.
- **App:** build-verified + **runtime idle-CPU smoke test** (especially the new settings sidebar + the five search sheets).
- **L10n:** catalog parity (existing test guard).

## Security / invariants

- SSH key invariants from M17 unchanged (0600/0700, passphrase only in the keychain under `key.id`, no writing to `~/.ssh`, `ssh-keygen` argument array).
- Private-key export only behind a confirmation + warning; import cleans up on failure (no orphaned artifact).
- No new external dependency.

## Not in M18 (→ later)

- **Login-set import/export** (encrypted codec subsystem) — its own milestone **M19**.
- Rolling out `authorized_keys` (M17-v2).
- WebDAV/further protocol settings sections (come with the respective protocol milestone).

## Affected files

- `Sources/MacSCPApp/SheetSearchField.swift` — **create** (shared search bar).
- `Sources/MacSCPApp/LoginSetsSheet.swift` — **modify** (search + row context menu).
- `Sources/MacSCPApp/KnownHostsSheet.swift` — **modify** (unify search onto `SheetSearchField`).
- `Sources/MacSCPApp/HiddenImportsSheet.swift`, `Sources/MacSCPApp/AuditLogSheet.swift` — **modify** (search).
- `Sources/MacSCPApp/SSHKeysSheet.swift` — **create** (extracted from `SSHKeysSettingsTab` + import/private-export/rename + search).
- `Sources/MacSCPApp/SettingsView.swift` — **modify** (sidebar navigation, General split, protocol sections, SSH-Keys tab removed).
- `Sources/MacSCPApp/ContentView.swift`, `Sources/MacSCPApp/MacSCPApp.swift` — **modify** (`showSSHKeys` bridge + „SSH-Schlüssel…" menu item + `.sheet`).
- `Sources/MacSCPApp/ConnectionFormView.swift`, `Sources/MacSCPApp/LoginSetsSheet.swift` — **modify** („Schlüssel verwalten…" → sheet instead of `SettingsLink`).
- `Sources/macSCPCore/SSH/…` — **modify/create** possibly an SSH key import helper + test.
- `Sources/MacSCPApp/Resources/{en,de,fr,pl}.lproj/Localizable.strings` — **modify**.
