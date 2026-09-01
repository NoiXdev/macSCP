# M12 — Multi-Protocol Foundation + Capability Framework + Thin S3 Design

**Status:** approved (brainstorming 2026-08-01)
**Milestone:** M12
**Language:** design doc EN; code/comments EN; UI localized EN/DE/FR/PL

## Goal

Rebuild the app from a single-purpose SSH client into a **protocol plugin
system**: a connection-type discriminator (`kind`), a **capability
framework** through which each backend declares capabilities and supplies
its own contributions (form schema, info fields, context menu entries),
plus, as the **first second consumer, a thin S3 backend** (connect +
browse/list only). SSH stays green throughout; S3 transfer/CRUD/presigned
follow in M13/M14.

Maintainer decisions from the brainstorming session:
- **Scope:** foundation + framework + thin S3 **together** (validates the
  abstraction against two maximally different backends — POSIX-FS+shell vs.
  flat object storage — instead of speculatively).
- **A real plugin system** for the future (WebDAV/FTP/SMB as mere
  descriptors): the capability axes cover the spectrum.
- **Login sets** also get `kind` + per-kind auth.
- **Seams for later:** file-level and connection-level contributions are
  laid down as types; presigned URLs (M14) and diagnostic tools (ping/
  traceroute/speedtest, its own later milestone) dock in there.
- No release; stays on `develop`.

## Context / current state (verified)

- **`RemoteFileSystem`** (Core protocol, `Sources/macSCPCore/RemoteFS/`) is
  already backend-agnostic: `list/stat/readStream/write/delete/createDirectory/
  rename/setPermissions/deleteTree/homeDirectoryPath/disconnect`.
  `LocalFileSystem` and `CitadelFileSystem` implement it; the entire
  browser/transfer layer programs against `any RemoteFileSystem`.
  `CitadelFileSystem` is referenced by name in only **two** places
  (`ContentView.swift:1168`, `MacSCPCLI.swift:25`).
- **`RemoteShellProvider`** (`RemoteShell.swift:19`) is already an optional
  runtime capability (`as?`) — only SSH supplies a shell. **This is the
  model** for the runtime capability protocols.
- **`Connector` typealias** (`ConnectionViewModel.swift:73`):
  `@Sendable (SSHConnectionConfig, @escaping @Sendable (HostKeyCandidate) async -> Bool) async throws -> any RemoteFileSystem`.
  The second parameter is the TOFU host-key decider — **SSH-specific**.
- **`StoredSession`** (`Sessions/StoredSession.swift`): `Codable`
  (synthesized), all fields SSH (host/port/username/authKind/keyPath/groupID/
  loginSetID/jump); forward compatibility via **optional** fields (nil =
  legacy). **No `kind`.** ⚠️ synthesized Codable applies NO defaults to
  missing keys → a new `kind` must be `decodeIfPresent(...) ?? .ssh` (custom
  `init(from:)`), otherwise old JSON breaks (the M3d lesson: synthesized
  Codable already bypassed a normalizing init once).
- **Login sets:** `Sessions/LoginSetStore.swift` (+ `LoginSetsSheet.swift`);
  M10b. Currently SSH-shaped.
- **Form:** `ConnectionFormView.swift` (~750 lines, SSH field sections), fed
  by `ConnectionViewModel` (~888 lines, SSH auth/jump/TOFU).
- **Context menu:** `BrowserContextMenu.entries(for:side:)` is a PURE Core
  function (file level). **Info dialog:** `InfoPermissionsSheet`
  (owner/group/rwx). **Sidebar/tab:** `SessionSidebar`, `TabStripView`
  (this is where the type badge lands).
- **Package.swift:** `defaultLocalization: "en"`; Core lists lproj
  explicitly, App via `.process("Resources")`. **swift-crypto** is already a
  Core dependency (supplies HMAC-SHA256/SHA256 for SigV4 — **no new
  dependency**). URLSession (Foundation) for HTTP.
- **Test rig:** `docker/test-server/compose.yml` (two sshd containers
  2222/2223); `MACSCP_ITEST=1`. A **MinIO container** slots in identically.

## Architecture

### 1. Discriminator & config (Core)

- **`ConnectionKind`** (`enum: String, Codable, CaseIterable, Sendable`):
  `case ssh, s3` (open for `webdav`, `ftp`, `smb`).
- **`ConnectionConfig`** (`enum`): `case ssh(SSHConnectionConfig)`,
  `case s3(S3ConnectionConfig)`. Exhaustively switchable; type-safe.
- **`S3ConnectionConfig`** (new, Core): `accessKeyID`, `region`, `endpoint`
  (S3-compatible), `bucket`, `usePathStyle: Bool`, optional `sessionToken`.
  **Secret access key NOT in the config** — only in the keychain
  (`SecretStore`), like the SSH password.
- **`Connector`** is generalized:
  `@Sendable (ConnectionConfig, HostKeyDecider) async throws -> any RemoteFileSystem`
  (the decider stays in the type, and is simply never invoked by S3). A
  central **`BackendConnector`** dispatcher picks the concrete connect call
  by `kind` (`CitadelFileSystem.connect` / `S3FileSystem.connect`).
- **`StoredSession.kind: ConnectionKind`** (`decodeIfPresent ?? .ssh`,
  custom `init(from:)`) + optional `s3: S3ConnectionConfig?` payload. Old
  JSON loads unchanged as `.ssh`. Analogous for `LoginSet` (kind + per-kind
  auth payload; shared fields like display name/username stay shared).

### 2. Capability framework (Core)

**A) Static `BackendDescriptor` per `kind`** (registry, no live connection):
- **`ProtocolCapabilities`** (struct, declarative): `supportsShell: Bool`,
  `permissionModel: PermissionModel` (`.posixMode`/`.acl`/`.none`),
  `supportsSymlinks: Bool`, `atomicRename: Bool`, `directoriesAreReal: Bool`,
  `resumeMode: ResumeMode` (`.append`/`.rangeGet`/`.restOffset`/`.none`),
  `supportsPresignedURL: Bool`, `transport: TransportSecurity`
  (`.alwaysEncrypted`/`.optionalTLS`/`.plaintext`).
- **Form schema + provider presets:** a `ConnectionFieldSchema` (ordered
  fields with label key, `isSecret`, type) + auth model + a presets list
  (AWS, Hetzner, "Custom"). The generic form renders from the schema; the
  type switch only swaps the schema.
- **Badge:** short name + symbol/tint per `kind`.

The generic UI reads **only** `ProtocolCapabilities` for gating: terminal
button (`supportsShell`), permissions editor (`permissionModel != .none`),
symlink marker (`supportsSymlinks`), resume banner (`resumeMode != .none`),
plaintext warning (`transport == .plaintext`). **No `if kind == …` in the
generic layer.**

**B) Runtime capability protocols** on the `RemoteFileSystem` instance (via
`as?`, like `RemoteShellProvider`): Shell (SSH). Defined as a seam for
later: `PresignedURLProvider` (S3, M14). M12 lays down the seam, does not
fill it for S3.

**Contributions (both levels as a seam in M12, minimally filled):**
- **File level:** `BrowserContextMenu.entries` accepts file actions
  contributed by the backend (M12: only the generic set + SSH's existing
  ones; no new S3 entries). The **info dialog** renders generic + contributed
  detail fields (SSH keeps owner/group/permissions/symlink; S3 thin:
  size/date/ETag).
- **Connection level:** new seam for session/tab actions (diagnostic tools
  dock in later). M12: only the seam, no entries.

**Gating behavior:** a non-SSH tab does **not** show the terminal button;
the terminal shortcut/menu is disabled; if an SSH-only shortcut is
triggered on an S3 tab anyway, there is a **clean, localized error message**
(no silent no-op, no crash).

### 3. Thin S3 backend (Core, the second consumer)

- **`SigV4Signer`** (new): AWS Signature V4 (canonical request → string-to-
  sign → HMAC-SHA256 chain) via swift-crypto; `UNSIGNED-PAYLOAD` for GET
  (HTTPS). Unit-tested against the **official AWS SigV4 test vectors**
  (deterministic, no network).
- **`S3FileSystem: RemoteFileSystem`** (thin): `connect` (endpoint/region/
  bucket + access key from keychain, one `ListObjectsV2` probe call to
  validate auth), `list(path:)` (`ListObjectsV2` with `prefix` +
  `delimiter="/"` → CommonPrefixes = synthetic folders + objects,
  **paginated** via ContinuationToken), `stat`, `homeDirectoryPath` →
  `"/"`, `disconnect`. **Not in M12:** `write`/`readStream`/`delete`/
  `rename`/`createDirectory`/`deleteTree` throw a clear "not supported
  yet" error (come in M13). `setPermissions` throws `protocolError` (S3
  has no POSIX permissions — permanently).
- **Provider presets:** AWS (region→endpoint derivation, virtual-hosted
  style), Hetzner Object Storage (endpoint, path-style), "Custom" (free
  endpoint).
- **Error mapping:** HTTP 403→`authenticationFailed`, 404→`notFound`,
  network→`connectionFailed`, rest→`protocolError`.

### 4. UI (App)

- **Connection form:** type switch (picker ssh/s3) at the top; below it the
  field section generated from the `ConnectionFieldSchema`; provider preset
  picker for S3. The SSH section (auth/jump/TOFU) stays, just gated behind
  `kind`.
- **Badge:** type badge (short name/symbol) in the sidebar row and in the
  tab strip.
- **Gating:** terminal toolbar button/menu + SSH-only actions shown/hidden
  by capability; shortcut error message.
- **L10n:** new keys (type names, S3 field labels, provider names, gating
  errors) in EN/DE/FR/PL (FR/PL AI-generated, native-review flagged).

## Edge cases / deliberate non-goals (M12)

- **S3 connect + browse only** — upload/download/delete/rename/presigned/
  cross-backend are M13/M14. In M12, a clean "not yet supported".
- **No live-language-switch-style rework** of the lookups.
- **Old sessions/login sets** load unchanged as `.ssh` (decodeIfPresent).
- **Secrets** (S3 secret access key) only in the keychain, never in
  JSON/export in plain text (the export path must serialize `kind`+S3
  together, secret kept separate like SSH).
- **SMB/FTP/WebDAV** are NOT part of M12 — only the framework's axes need
  to conceptually support them.

## Tests

- **Core (new, TDD):** `ConnectionKind`/`ConnectionConfig` round-trip;
  `StoredSession`/`LoginSet` `kind` decode (old JSON → `.ssh`, new S3 →
  round-trip); `ProtocolCapabilities`/descriptor registry (SSH and S3
  capabilities correct); `SigV4Signer` against **AWS test vectors**
  (deterministic); `S3FileSystem.list` parsing (ListObjectsV2 XML →
  RemoteFileItems, CommonPrefixes→folders, pagination) with a fake HTTP
  transport (no network).
- **Gated integration:** **MinIO container** in the rig (seed bucket); an
  `S3FileSystemIntegrationTests` (connect + list against real MinIO,
  `MACSCP_ITEST=1`). SSH rig unchanged, stays green.
- **App (no test target):** schema-driven form, badge, gating via
  build/trace; **runtime idle-CPU smoke test** (M11n habit) — app starts,
  SSH connection unchanged, S3 tab opens without spinning.
- **Regression:** the full existing suite stays green (SSH path untouched
  behind the generalized connector).

## Rough task breakdown (for the plan)

1. **Core discriminator:** `ConnectionKind` + `ConnectionConfig` enum +
   `S3ConnectionConfig` + `StoredSession.kind`/`s3` (decodeIfPresent) +
   tests.
2. **Capability framework:** `ProtocolCapabilities` + `BackendDescriptor`
   registry + `ConnectionFieldSchema` + contribution seam types (file/
   connection level) + tests.
3. **Connector dispatcher:** generalized `Connector` + `BackendConnector`
   by `kind`; SSH path passed through verbatim, regression green.
4. **SigV4Signer** (+ AWS test vectors).
5. **Thin S3FileSystem** (connect + list + stat, XML parsing, error
   mapping) + fake-transport tests + MinIO rig + gated integration test.
6. **Login sets kind** + resolver per kind + export/import `kind`+S3.
7. **App:** schema-driven form + type switch + provider presets + badge
   (sidebar/tab) + capability gating (+shortcut error) + L10n EN/DE/FR/PL.
8. **Closing verification** (gated including MinIO, whole-milestone Opus
   review, runtime smoke test, push, dev build).

## Global Constraints

- Swift 6, `.swiftLanguageMode(.v5)`, min. macOS 15; Swift Testing, TDD
  wherever logic is created.
- **No new dependency** — SigV4 via the existing swift-crypto, HTTP via
  URLSession.
- Discriminator/capabilities/config in **Core** (testable); localized
  labels in the App (split like `FileColumn`).
- **Forward compatibility:** old `sessions.json`/login sets load as `.ssh`
  (`decodeIfPresent ?? .ssh`).
- Secrets (SSH **and** S3) exclusively in the keychain (`SecretStore`),
  never in JSON.
- TOFU host-key security unchanged for SSH; S3 has no decider.
- Code/comments EN; UI strings EN/DE/FR/PL, no ASCII `"` in non-EN;
  FR/PL AI-generated (native review before release).
- **M11n lesson:** runtime idle-CPU smoke test before shipping.
- No release/tag without explicit maintainer direction.
