# Checksum Column: Empty Until Asked — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A toggleable table column "Checksum" in the remote file list
that stays EMPTY until the user asks for a file's checksum through the
existing action, then shows the value that action computed — for that
file, for as long as the row is the same file — under the algorithm the
existing setting names. Item 3 of the checksums entry, on the maintainer's
decision of 2026-09-02: empty, computing is an action, never automatic
per listing.

**Architecture:** Nothing new computes. The existing request path
(`ChecksumBatch` in `Sources/MacSCPAppKit/ChecksumPresentation.swift`,
driven by the context-menu action and the info sheet, producing
`ChecksumRequestResult` per `RemoteFileItem`) gains one more consumer: a
per-tab `ChecksumLedger` (Core, `Presentation/ChecksumLedger.swift`)
keyed by the item's path AND identity (`size`, `modifiedAt`), holding the
last `FileChecksum` per algorithm. The browser's row provider asks the
ledger for the visible column's algorithm (`SettingsStore.checksumAlgorithm`)
and renders the hex, or nothing. A row whose identity changed (a new
listing with another size/date) reads as empty again — the ledger never
shows a value for bytes it did not see. A multipart ETag stays out of the
column exactly as it stays out of the sheet: the ledger stores only
results the sheet already calls a checksum (`FileChecksum` whose
provenance is a digest), never the "not the file's checksum" kind. The
column is `FileColumn.checksum`, `isToggleable`, `defaultVisible = false`,
persisted through `SettingsStore.visibleColumns` like the others; its
header carries the algorithm ("Checksum (SHA-256)") so the user sees
which digest a value is.

**Tech Stack:** Swift 6, Swift Testing; `FileColumn`, `SettingsStore.visibleColumns`
and `.checksumAlgorithm`, `RemoteFileTableView` (`buildColumns`, the
`switch columnID` cell mapping at ~536 and ~597), `ChecksumBatch`,
`ChecksumRequestResult`/`FileChecksum` (`Sources/macSCPCore/RemoteFS/FileChecksum.swift`,
`Presentation/ChecksumRequest.swift`), four App catalogs.

**Source:** `docs/superpowers/specs/2026-08-27-backlog-file-hashes.md`
("Decided 2026-09-02 — question 3"), `2026-08-31-file-checksums-design.md`
(the request path this plan reuses).

## Global Constraints

- English only; Conventional Commits; footer exactly `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- **Nothing computes without the user's action.** No listing, refresh,
  scroll or column toggle triggers a checksum request. A guard pins that
  the ledger is only WRITTEN from the request path (`ChecksumBatch`) —
  a negative scan with a positive anchor.
- **A value never outlives its bytes — as far as a listing can tell.** The
  ledger key includes `size` and `modifiedAt`; a row with a different
  identity reads empty. Pinned. The review of Task 1 named the gap the
  key cannot close: a same-size rewrite within one modification-time
  tick (SFTP and WebDAV carry whole seconds) keeps the old value on
  screen. The closeout states that limit; the info sheet has the same
  blindness, so the column is no worse than what exists.
- **Provenance intact.** Only `FileChecksum` values with digest provenance
  enter the ledger; a multipart ETag result does not (the sheet's own
  sentence for it stays the only place it shows). Pinned.
- Column hidden by default; `visibleColumns` round-trips it; older
  settings files without the key decode as before (read-side).
- Four App catalogs (`columns.checksum`, `columns.checksum.withAlgorithm %@`),
  du-form German, parity guards; Swift 6; warning budget 1.
- TDD red first; commit per task; do not push.

---

### Task 1: The ledger

**Files:**
- Create: `Sources/macSCPCore/Presentation/ChecksumLedger.swift`
  (`public struct ChecksumLedger: Sendable { mutating func record(_ result: ChecksumRequestResult, for item: RemoteFileItem); func value(for item: RemoteFileItem, algorithm: ChecksumAlgorithm) -> FileChecksum?; mutating func forget(path:) }` —
  key = `(path, size, modifiedAt)`; `record` ignores results that are not
  digest-provenance checksums)
- Test: `Tests/macSCPCoreTests/ChecksumLedgerTests.swift` — record then
  read; a different size or date reads nil; a different algorithm reads
  nil; a multipart-ETag result is not recorded (build the `ChecksumRequestResult`
  case the sheet renders as "not the file's checksum" — read `ChecksumRequest.swift`
  for its exact case); `forget(path:)`.

- [ ] Red → green → commit `feat(checksums): a per-tab ledger of what the user asked for`

### Task 2: The column

**Files:**
- Modify: `Sources/macSCPCore/Presentation/FileColumn.swift` (`case checksum`; `defaultVisible` false; `isToggleable` true), `Sources/macSCPCore/Settings/SettingsStore.swift` only if `visibleColumns` decoding needs the new raw value tolerated (read it — it filters unknown values already?), `Sources/MacSCPAppKit/RemoteFileTableView.swift` (the column, the two `switch columnID` sites: text = ledger value's hex or empty; header text via the catalog with the current algorithm), the row provider's input (the ledger comes in with the items — read how `visibleColumns` and the settings reach the table and pass the ledger the same way), `Sources/MacSCPAppKit/ChecksumPresentation.swift` (`ChecksumBatch` writes each result into the ledger of the tab that started it — find where the batch's results are consumed and add the ledger write there, one place), the columns menu (wherever `FileColumn.allCases` renders toggles — it picks up the case automatically? verify), four App catalogs.
- Test: `FileColumnTests` (if present, else new): the new case's flags;
  `SettingsStoreTests`: `visibleColumns` round-trips `.checksum`, a stored
  array without it → hidden; a table-provider test (the same style the
  other columns have — grep `Tests/macSCPAppKitTests` for `"size"`/`sizeString`)
  that a row with a ledger value shows the hex and one without shows
  nothing; a guard: the only writer of the ledger is the batch's result
  path (`grep -rn "ledger.record(" Sources` count == 1, positive anchor the
  call exists).

- [ ] Red → green → commit `feat(browser): a checksum column that shows only what was asked for`

### Task 3: Closeout

- [ ] `docs/superpowers/specs/2026-08-27-backlog-file-hashes.md` ("Done — item 3"), `docs/BACKLOG.md` row; commit `docs(backlog): the checksum column, empty until asked`.

## What is explicitly not in this plan

- No per-row button, no automatic computation, no progress inside a file.
- No change to algorithms or their warning at the setting.
- No "this algorithm does not exist here" case (still open in the entry).
