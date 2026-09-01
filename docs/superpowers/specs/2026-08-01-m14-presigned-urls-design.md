# M14 — Presigned Share URLs (S3) Design

**Status:** approved (brainstorming 2026-08-01)
**Milestone:** M14
**Language:** design doc EN; code/comments EN; UI localized EN/DE/FR/PL.

## Goal

Generate a **time-limited, signed share URL** for an S3 object — the
"Temporary Share URL" context menu entry the maintainer requested back in
M12. Two directions, selectable at creation time:
- **GET** — someone **downloads** the object via the URL (the classic
  "send someone this file" case).
- **PUT** — someone **uploads** a file via the URL (to a target key
  editable in the sheet).

The URL carries the signature in the query (no header needed) and expires
after a selectable duration (SigV4 maximum **7 days**). Purely
computational, **no network** at creation time.

This is the **first real use of the M12 contribution seam**: a backend
contributes a protocol-specific context menu entry that the generic layer
reads without knowing the concrete type.

**Not in M14:** cross-backend transfer S3↔SSH (= M15); "Open with"
S3 CLI tool (a later milestone). **No release.**

## Starting point (as-is)

- `SigV4Signer` (M12/M13) can only do **header** signing
  (`authorizationHeader`). Presigned needs **query** signing — a new
  method.
- `ProtocolCapabilities.supportsPresignedURL` exists (s3 = true, ssh =
  false), but is **read nowhere**.
- `BackendContributions.FileActionContribution` (M12 seam) exists, but is
  **empty** in both descriptors and **not wired to the context menu** (the
  doc comment explicitly says "S3 presigned URL lands in M14").
- `BrowserContextMenu.entries(…)` (Core) builds fixed `BrowserMenuEntry`
  cases; the App's `RemoteFileTableView` renders them as an `NSMenu`. No
  descriptor contribution is read.
- `RemoteShellProvider` is the established pattern for an **optional**
  backend capability (`as?` query) — the model for presigned.

## Architecture / components

### 1. SigV4 presigned query signing (`SigV4Signer`)

New method next to `authorizationHeader`:
```swift
public func presignedQuery(
    method: String, host: String, path: String,
    expiresInSeconds: Int, date: Date
) -> [(name: String, value: String)]
```
Produces the SigV4 query parameters for a presigned URL:
`X-Amz-Algorithm=AWS4-HMAC-SHA256`, `X-Amz-Credential={accessKeyID}/{scope}`,
`X-Amz-Date={amzDate}`, `X-Amz-Expires={seconds}`,
`X-Amz-SignedHeaders=host`, (for STS additionally
`X-Amz-Security-Token={sessionToken}`), and last
`X-Amz-Signature={sig}`. The payload hash in the canonical request is
`UNSIGNED-PAYLOAD`, the only signed header is `host`; the canonical query
contains all X-Amz-* parameters **except** `X-Amz-Signature` (sorted,
RFC-3986 as before, via `canonicalQueryString`). The HMAC chain /
`canonicalURI` / `hexSHA256` are reused (single source). Pinned against
the **AWS presigned test vector**.

### 2. Optional capability seam (`PresignedURLProvider`)

New `Sources/macSCPCore/RemoteFS/PresignedURLProvider.swift` (pattern like
`RemoteShellProvider`):
```swift
public enum PresignedMethod: String, Sendable { case get = "GET", put = "PUT" }

public protocol PresignedURLProvider: Sendable {
    /// A time-limited signed URL for `key`. `.get` downloads it, `.put` uploads
    /// to it. `expiresIn` is clamped to [1s, 7 days] (SigV4 max). Pure — no I/O.
    func presignedURL(method: PresignedMethod, key: String, expiresIn: TimeInterval) throws -> URL
}
```
The App queries `fs as? PresignedURLProvider` (no `if kind ==`). Backends
without presigned do not conform.

### 3. `S3FileSystem: PresignedURLProvider`

`presignedURL(method:key:expiresIn:)` builds the object URL (path- vs.
virtual-host as in M13, via `keyRequestURL`/`canonicalKeyPath`), calls
`signer.presignedQuery(...)` with `expiresIn` (clamped via
`max(1, min(604800, …))`), and appends the query. Pure signing, no
`transport` call.

### 4. Contribution seam into the context menu (Core)

- `BrowserMenuEntry` gets `case backendFileAction(FileActionContribution)`.
- `BrowserContextMenu.entries(…)` gets a parameter
  `fileActions: [FileActionContribution] = []` and appends them **only for
  a single-file selection** (`selection.count == 1`, `!isDirectory`) — e.g.
  right before `copyPath`/`delete`. `BrowserKeyCommand` stays untouched (no
  keyboard shortcut).
- `s3Descriptor.fileActions` (in `BackendDescriptor.swift`) gets
  `FileActionContribution(id: "s3.presignedURL", titleKey:
  "browser.action.presignedURL", titleDefault: "Share Link…")`.
  `sshDescriptor.fileActions` stays empty.

### 5. App — context menu + sheet (`RemoteFileTableView` / new sheet)

- `RemoteFileTableView`'s coordinator reads the active remote backend's
  `fileActions` (`BackendDescriptor.descriptor(for: activeKind).fileActions`,
  via the pane's existing backend/descriptor reference) and renders
  `backendFileAction` entries as `NSMenuItem`; a click reports the
  `FileActionContribution.id` + the selection to a handler.
- New **sheet** `PresignedURLSheet` (SwiftUI):
  - Segmented `PresignedMethod`: **GET (Download)** / **PUT (Upload)**.
  - Expiry `Picker`: 15 min / 1 hr / 24 hr / 7 days — preset from
    `settingsStore.presignedDefaultExpiry`.
  - For **PUT**: an **editable target key field**, preset with the
    clicked object's key; a warning "overwrites an existing key".
  - Button "Generate URL" → calls `fs.presignedURL(...)` → shows the URL
    in a read-only, text-selectable field + a **"Copy"** button (to the
    clipboard). Errors (no provider / signature error) as an inline
    message.
- Only visible/generatable when the active remote backend is a
  `PresignedURLProvider` — the menu contribution (driven by the
  `supportsPresignedURL`-driven descriptor) already guarantees that.

### 6. Settings (`SettingsStore` + settings UI)

- `SettingsStore.presignedDefaultExpiry: PresignedExpiry` (enum with the
  four levels; Codable-persisted in the existing JSON pattern, default
  `.oneHour`).
- A control in the **Transfers** settings tab ("Default expiry for share
  links").

## Error handling / security

- **The URL IS the secret**: whoever has it can access within the
  window. It is written **only** to the clipboard — **never logged, never
  persisted, never interpolated into an error message**. The access key
  is (unavoidably) present in the URL query; the secret **never** is (it
  flows only into the HMAC signature, as everywhere).
- **PUT overwrites** the target key without confirmation (S3 semantics) —
  the sheet warns visibly.
- Expiry hard-clamped to **[1 s, 604800 s]** (SigV4 limit 7 days).
- `presignedURL` is purely computational; a missing provider or an
  invalid key throws `RemoteFSError.protocolError`, or is prevented by
  the menu gating.

## Tests

- **SigV4 presigned unit** (`SigV4SignerTests`): `presignedQuery` against
  the documented AWS presigned vector (GET, fixed creds/region/date/
  expires) — `X-Amz-Signature` bit-identical; the order/encoding of the
  X-Amz-* parameters correct.
- **`presignedURL` unit** (`S3FileSystemTests`, no fake needed — purely
  computational): GET and PUT URLs contain the expected query parameters,
  correct key/host (path- + virtual-host), `X-Amz-Expires` clamped
  (>7 days → 604800), signature present. No secret in the URL.
- **`BrowserContextMenu` unit**: a single **file** selection with
  `fileActions: [presigned]` contains the `backendFileAction` entry; a
  **folder**/multi-selection does **not**; SSH (empty fileActions) never
  does.
- **GATED MinIO** (the decisive check, as learned in M13 — fake tests do
  NOT validate the signature): presign **GET** of a seed object → fetch
  via `URLSession` GET → bytes bit-identical (HTTP 200). Presign **PUT**
  to a new key → upload via `URLSession` PUT → the object appears in
  `list`/`stat` with the correct size. Cleanup. Runs from the main
  checkout.
- **Runtime idle-CPU smoke** (standing habit since M11n): start a dev
  build, open the new sheet (S3 file → "Share Link…"), idle ~0% CPU,
  switching GET/PUT without spinning.

## Files

- Change: `Sources/macSCPCore/S3/SigV4Signer.swift` (`presignedQuery`).
- New: `Sources/macSCPCore/RemoteFS/PresignedURLProvider.swift`.
- Change: `Sources/macSCPCore/S3/S3FileSystem.swift`
  (`PresignedURLProvider` conformance + `presignedURL`).
- Change: `Sources/macSCPCore/Presentation/BrowserContextMenu.swift`
  (`backendFileAction` case + `fileActions` parameter).
- Change: `Sources/macSCPCore/Capabilities/BackendDescriptor.swift`
  (`s3Descriptor.fileActions`).
- Change: `Sources/macSCPCore/Settings/SettingsStore.swift`
  (`presignedDefaultExpiry` + `PresignedExpiry`).
- New: `Sources/MacSCPApp/PresignedURLSheet.swift`.
- Change: `Sources/MacSCPApp/RemoteFileTableView.swift` (menu reads
  `fileActions`, handler opens the sheet), `Sources/MacSCPApp/SettingsView.swift`
  (expiry control), `Sources/MacSCPApp/Resources/{en,de,fr,pl}.lproj/
  Localizable.strings`.
- Tests: `SigV4SignerTests.swift`, `S3FileSystemTests.swift`,
  `BrowserContextMenuTests.swift` (if it exists, otherwise new),
  `S3FileSystemIntegrationTests.swift` (gated GET+PUT).

## Global Constraints

- Swift 6, all targets `.swiftLanguageMode(.v5)`, min. macOS 15.
- Code/comments **English**; UI strings via the four `.strings`
  catalogues EN/DE/FR/PL, typographic quotation marks, **no ASCII `"`** in
  non-EN values; FR/PL AI-generated (native review before release).
- **No new dependency** (Foundation `URLSession` only in the gated test;
  swift-crypto via `SigV4Signer`).
- **Secret only in the signer**, never in logs/JSON/URL; the generated
  presigned URL only to the clipboard, never logged/persisted.
- The generic layer reads only capabilities/contributions — **no
  `if kind ==`** in the browser/menu; presigned as `as? PresignedURLProvider`.
- TDD red→green; new logic with tests; **every signing-touching change
  gated against real MinIO** (the M13 lesson). Runtime smoke for the new
  sheet.
- **No release.** Cross-backend = M15; "Open with" S3 CLI = a later
  milestone.
