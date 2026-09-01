# M9b — Audit log per connection (design)

Date: 2026-07-28 · Status: approved by the maintainer (blocks 1+2 confirmed individually)

## Goal

Per SAVED connection, a persistent log of what happened in its sessions —
connections, transfers, file operations, errors. It is kept until the
connection is deleted, and can be viewed at any time via the sidebar
context menu.

**Maintainer decisions (2026-07-28):**

1. Event scope: everything essential — connected/disconnected, completed
   transfers (direction, name, destination, success/failure/cancel), file
   operations (rename, delete, permissions, new folder), editor uploads,
   cross-session transfers (with destination session), errors with
   message text. NO navigation/listing events.
2. Log only saved sessions (ad-hoc connections: nothing); rolling cap of
   the newest **1000** entries per session.
3. Display: sidebar context menu "Audit Log…" → large sheet with table,
   filter segments, text search, "Clear Log…" (confirmation), and
   "Export as Text…".
4. Architecture: approach A — `AuditLogStore` (SessionStore pattern) +
   optional sink hooks at the three existing chokepoints; no event bus,
   no OSLog.

## 1. Model (Core)

`Sources/macSCPCore/Sessions/AuditEvent.swift`

- `public struct AuditEvent: Codable, Equatable, Sendable, Identifiable`:
  `id: UUID`, `timestamp: Date`, `kind: Kind`, `detail: String`,
  `isError: Bool`, `errorMessage: String?`.
- `public enum Kind: String, Codable, CaseIterable, Sendable`:
  `connected`, `disconnected`, `transferFinished`, `transferFailed`,
  `transferCancelled`, `rename`, `delete`, `permissions`, `newFolder`,
  `editUpload`, `crossSessionTransfer`.
- `detail` is FINISHED English plain text (e.g.
  `upload report.pdf → /var/www`, `rename /etc/app.conf → app.conf.bak`,
  `to “db-prod”: dump.sql.gz → /srv/backups`). The display localizes only
  the kind LABELS (EN/DE); details (paths/names) are payload data and stay
  untranslated. Category mapping for the filter: transfers =
  transferFinished/Failed/Cancelled/editUpload/crossSessionTransfer;
  file ops = rename/delete/permissions/newFolder; connection =
  connected/disconnected; errors = `isError == true` (cross-cutting).

## 2. AuditLogStore (Core)

`Sources/macSCPCore/Sessions/AuditLogStore.swift`

- Pattern `SessionStore`: stateless struct, injectable directory (default
  `Application Support/macSCP/audit/`), one file per session
  `<sessionID>.json`, atomic writes, prettyPrinted/sortedKeys.
- API:
  - `append(_ event: AuditEvent, for sessionID: UUID)` — loads, appends,
    truncates to the NEWEST 1000 (chronological order in the file),
    writes. NEVER throws (errors silently swallowed): a broken log must
    not disrupt any transfer/action.
  - `events(for sessionID: UUID) -> [AuditEvent]` — broken/missing file
    ⇒ `[]` (fail-safe; the sheet display then simply shows "empty").
  - `clear(for sessionID: UUID)` / `deleteLog(for sessionID: UUID)` —
    clear or remove the file; errors silent.
- Cap constant `maxEntriesPerSession = 1000` (internal, testable).

## 3. AuditRecorder + sinks (Core)

`Sources/macSCPCore/Sessions/AuditRecorder.swift`

- `public struct AuditRecorder: Sendable`: `sessionID` + store; convenience:
  `recordConnected(host:username:)`, `recordDisconnected()`,
  `recordTransfer(...)` (maps queue-item terminal state → kind, including
  the editor-upload and cross-session variants; cross-session detail
  contains the DESTINATION TITLE, which the App supplies),
  `recordAction(kind:detail:error:)` for the four browser actions.
- Sinks (both optional, default nil — nil ⇒ no logging, ad-hoc stays
  silent):
  - `TransferQueueViewModel.auditSink: ((Item) -> Void)?` — called at the
    SINGLE terminal transition (the `wasTerminal` gate, where
    `totalFailureCount` counts), exactly once per item; never on
    non-terminal transitions.
  - `RemoteBrowserViewModel.auditSink: ((AuditEvent) -> Void)?` — the four
    actions (rename/createFolder/applyPermissions/deleteItems) report
    success OR failure (with message) on completion. Only the remote pane
    gets a sink.
- Connection events are logged directly by the App layer via the recorder
  (connect success, or teardown in the tab flow).

## 4. App wiring

- `SessionTab.auditRecorder: AuditRecorder?` — set on connecting a SAVED
  session (`connect(in:stored:)` or `startSession`, when an
  `activeStoredSessionID` arises), nulled on teardown (after
  `recordDisconnected`). The queue sink and the remote-VM sink are wired
  when the recorder is set and detached when it is nulled.
- Cross-session detail: the App sink resolves `item.destinationTabID` via
  `tabsModel` to the destination title (destination tab already closed ⇒
  "unknown session").
- Deletion: `SessionListViewModel.delete` additionally calls
  `auditStore.deleteLog(for: session.id)`; errors do not block deleting
  the session. The store is injected into the VM (init parameter with a
  default — tests pass temp directories).

## 5. Audit sheet (App)

- Sidebar session context menu: "Audit Log…" (above "Delete"; for EVERY
  saved session, even without an active connection).
- Sheet ~640×480, house style: title = session name; filter segments
  All / Transfers / File Ops / Connection / Errors; search field
  (full-text over `detail` + `errorMessage`, case-insensitive); table:
  time (`dd.MM. HH:mm:ss`, local), event label (localized EN/DE), detail
  (monospaced); error rows tinted red; NEWEST ON TOP.
- Footer: counter ("%lld entries" / filtered "%lld of %lld"),
  "Export as Text…" (fileExporter, `.txt` — line format
  `[ISO8601] KIND detail` + ` — error: <message>` for errors),
  "Clear Log…" (destructive, confirmation, calls `clear(for:)`).
- Empty state: subtle notice ("No entries yet.").
- Loaded on open; NO live refresh (deliberate — close/reopen is enough;
  auto-refresh is an M9c topic).
- All new UI text EN/DE.

## 6. Tests

- Store: append/roundtrip; rolling cap (entry 1001 evicts the oldest,
  order stable); clear/deleteLog; broken file ⇒ `[]`; append against an
  unwritable directory (file instead of folder, M9a pattern) does not
  throw and does not disrupt.
- Recorder: item→event mapping (finished/failed/cancelled ×
  upload/download, editor-upload kind, cross-session kind with
  destination title in the detail); action mapping of the four VM
  methods (success + error case).
- Queue sink: fires exactly once per terminal transition (a duplicate
  setStatus does not fire again — tested at the wasTerminal gate); never
  on progress updates.
- VM sink: fires only when a sink is set; success AND error case; nil sink
  = no effect (regression: actions unchanged).
- App (sheet, menu, wiring): visual smoke test (T4 checklist in the plan).

## 7. Deliberately NOT in M9b

- No logging for ad-hoc connections (not even transiently).
- No navigation/listing events.
- No live refresh of the open sheet; no separate window.
- No structured export (CSV/JSON) — text only; backlog candidate.
- No retention settings (the 1000 cap is fixed).
