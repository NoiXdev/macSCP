# M16 — Cross-backend transfer S3↔SSH (Design/Spec)

**Date:** 2026-08-01
**Status:** approved (brainstorm), ready for writing-plans
**Branch:** `develop`
**Predecessors:** M8b (cross-session transfer), M12–M15 (S3 backend + login sets).

## Goal

Gated-verify S3↔SSH transfers in both directions and extend the UI so
cross-backend transfers become visible (destination session + backend
label, passive warning for S3 destinations without resume). The transfer
engine stays unchanged — it is already backend-agnostic.

## Starting point (verified)

Exploring the cross-session path (M8b) found: `TransferEngine.copyFile`
(`Sources/macSCPCore/RemoteFS/TransferEngine.swift:93-189`) reads/writes
**purely through the `RemoteFileSystem` protocol** — no `if S3`, no
`as? CitadelFileSystem`/`as? S3FileSystem`. The entire M8b wiring
(`ContentView.transferToSession` ~2596, `TransferQueueViewModel` crossRemote
branch ~825, `BandwidthLimiter`, `TabsViewModel`) is pure protocol
delegation. Folder recursion (`expandTree` ~1044, S3 0-byte marker hidden in
`S3ListParser`), the resume guard (`effectiveResume` ~108, S3 destination →
overwrite), stat/conflict (~944), and size/progress (~101) all run
generically. **S3↔SSH already copies through, technically.**

Two real gaps:
1. **Test:** No gated S3↔SSH integration test (only SSH↔SSH from M8b,
   `CitadelFileSystemIntegrationTests.swift:1195`). The rig can do it —
   `docker/test-server/compose.yml` starts sshd:2222, sshd2:2223,
   minio:19000/19001 together, common gate `MACSCP_ITEST=1`.
2. **UI transparency:** `TransferQueueBar.row(_:)` shows only arrow +
   filename + status — no destination/backend label, no resume warning. The
   queue `Item` (`TransferQueueViewModel.swift:49`) carries only
   `destinationTabID` (opaque), no destination name/backend.

## Decisions (maintainer, 2026-08-01)

- **Scope:** primarily verification + hardening + UI transparency; no new
  engine mechanics. UI improvements: all three (destination/backend on the
  entry, resume warning, better destination submenu), but built **lean**.
- **Resume warning:** **passive hint** on the transfer entry (⚠ symbol +
  tooltip), no confirmation dialog.

## Architecture

### 1. Gated S3↔SSH test + hardening (Tests)

New gated test (`Tests/macSCPCoreTests/`, suite with
`.enabled(if: ProcessInfo…["MACSCP_ITEST"] == "1")`, uses the existing
compose file, connects S3 on 19000 and Citadel on 2222 simultaneously):

- **SSH→S3:** file on sshd → `TransferEngine.copyFile(source: Citadel,
  destination: S3)` → object in MinIO byte-identical (read back via range
  GET).
- **S3→SSH:** object in MinIO → `copyFile(source: S3, destination:
  Citadel)` → file on sshd byte-identical.
- **Cross-backend folder tree** (at least one direction): recursive
  transfer of a directory (subfolder + file); verifies that S3 "folders"
  (0-byte marker/CommonPrefix) are recognized as `.directory` and created
  on the other side via `createDirectory`.
- **Resume guard:** SSH→S3 with `resume` set gets `.overwrite` (never
  `.append`) — proves the M13 guard live across the backend boundary.

Hardening: covers the tricky cases (S3 marker folders, resume guard,
stat/conflict on an S3 destination). If the live test uncovers a bug (like
the M13 trailing-slash finding, which only real MinIO caught), it is fixed
in M16.

### 2. Cross-backend metadata in the queue `Item` (Core)

Additive to `Item` (and `Job`, threaded the same way as `destinationTabID`/
`crossRemote`/`isEditUpload`):

```swift
/// Whether the destination backend supports append-based resume (M16). Set
/// at enqueue from `destination.supportsAppendResume`; false for an S3
/// destination. Drives the passive resume warning in the transfer row.
public let destinationSupportsResume: Bool   // default true

/// Cross-backend target label (M16): the destination session's display name
/// + protocol kind, set only for cross-remote transfers (nil for
/// same-session). The queue holds only the opaque destinationTabID, so the
/// App supplies this at enqueue.
public let crossBackendTarget: CrossBackendTarget?   // default nil
```

New Core value:

```swift
public struct CrossBackendTarget: Equatable, Sendable {
    public var name: String
    public var kind: ConnectionKind
}
```

- `destinationSupportsResume`: **no** new caller parameter — the queue
  itself reads `destination.supportsAppendResume` when building the
  `Item`/`Job`.
- `crossBackendTarget`: new optional `enqueue`/`enqueueTree` parameter
  (`crossBackendTarget: CrossBackendTarget? = nil`), set in
  `ContentView.transferToSession` (destination session name and `kind` are
  available there).
- Both threaded through **every** `Item` reconstruction site (retry,
  interrupt-retain) — exactly like `isEditUpload`/`destinationDirectory`
  today.

**Test (Core unit):**
- cross-remote enqueue to an S3 destination → `destinationSupportsResume ==
  false`, `crossBackendTarget == CrossBackendTarget(name:…, kind: .s3)`.
- cross-remote enqueue to an SSH destination → `destinationSupportsResume ==
  true`, `crossBackendTarget?.kind == .ssh`.
- same-session local→S3 upload → `destinationSupportsResume == false`,
  `crossBackendTarget == nil`.
- retry/interrupt-retain of such an item keeps both fields (no reset to
  default).

### 3. Transfer row — destination/backend badge + passive resume warning (App)

`TransferQueueBar.row(_:)` (today: arrow + filename + status) gets two
additive, conditional elements in the same `HStack`:

- **Destination badge (cross-backend):** when `item.crossBackendTarget !=
  nil`, a small backend badge (`SSH`/`S3`, small-label typography like the
  sidebar/tab badges from M12) + destination session name (e.g.
  `→ prod-bucket`). Same-session transfers unchanged.
- **Passive resume warning:** when `item.destinationSupportsResume ==
  false` **and** status is active (queued/running), a subdued ⚠ with a
  tooltip "Upload restarts from scratch on interruption." No dialog, no
  click. Disappears on completion. Applies to every S3 destination.

Purely additive, no layout rework/new row heights. Plain SwiftUI view
(build-verified + idle-CPU smoke test); the data logic is tested in
section 2.

**L10n:** tooltip string + possibly a "→" destination-prefix format in
EN/DE/FR/PL (typographic characters, FR/PL AI-generated). Backend badge
labels "SSH"/"S3" already exist from M12.

### 4. Improve the destination session submenu (App)

The M8b "Transfer to session" submenu (`crossSessionTargets(for:)`
~ContentView:2579 + rendering) gains:

- **Backend badge per destination:** `CrossSessionTarget` gets a `kind`
  field (from the destination session); every menu entry shows `SSH`/`S3`
  next to the name.
- **Clearer destination path display:** the existing
  `CrossSessionTarget.remotePath` is also shown in the entry. If the menu
  widget cannot cleanly carry a two-line entry, the path is folded compactly
  into the title (`prod-bucket — /uploads`).

Purely additive, no behavior change to the transfer.

**L10n:** possibly a format string for assembling title/path (EN/DE/FR/PL);
badge labels from M12.

## Security / invariants

- No change to signer/transport/engine copy logic — only additive metadata
  + view.
- No `if kind == .s3` special path in the copy logic; the backend label in
  the `Item` is pure display metadata.
- No new external dependency.
- The resume guard (M13) is left untouched — the test only verifies it
  across the backend boundary.

## Tests

- **Core unit:** queue item metadata (section 2, four cases including
  retry).
- **Gated MinIO+sshd (`MACSCP_ITEST=1`, from the main checkout):** SSH→S3,
  S3→SSH, cross-backend folder tree, resume guard across the boundary
  (section 1).
- **Runtime smoke (maintainer + coordinator idle-CPU):** transfer bar with
  cross-backend badge + resume ⚠, destination submenu with backend badge.

## Not in M16

- New engine/copy mechanics (not needed).
- Active resume confirmation dialog (deliberately dropped — passive was
  chosen).
- "Open with" S3 CLI, connection diagnostics, SSH key manager, SSH terminal
  snippets, MCP server, macSCP CLI (own later milestones).

## Files affected

- `Tests/macSCPCoreTests/…` — new gated S3↔SSH test (possibly its own file
  `CrossBackendTransferIntegrationTests.swift`); Core unit test for the item
  metadata.
- `Sources/macSCPCore/Presentation/TransferQueueViewModel.swift` — `Item`/
  `Job` gain `destinationSupportsResume` + `crossBackendTarget`; `enqueue`/
  `enqueueTree` gain the optional parameter; all reconstruction sites.
- `Sources/macSCPCore/…` — new `CrossBackendTarget` type (own small file or
  alongside `TransferQueueViewModel`).
- `Sources/MacSCPApp/TransferQueueBar.swift` — destination badge + resume ⚠
  in `row(_:)`.
- `Sources/MacSCPApp/ContentView.swift` — `transferToSession` passes along
  `crossBackendTarget`; `crossSessionTargets(for:)` + submenu rendering gain
  `kind`/path.
- `Sources/MacSCPApp/Resources/{en,de,fr,pl}.lproj/Localizable.strings` —
  tooltip + menu format strings.
