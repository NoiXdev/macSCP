# M9b — Audit Log Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A rolling 1000-entry log per stored connection (connections, transfers, file operations, errors), viewable through a sheet from the sidebar context menu, deleted along with the connection.

**Architecture:** `AuditEvent` + `AuditLogStore` (SessionStore pattern, one file per session ID) and `AuditRecorder` in Core; recording through two optional sinks (queue terminal transition, remote VM actions) plus direct connect/teardown calls in the tab flow; the App side is the audit sheet with filter/search/export/clear.

**Tech Stack:** Swift 6 / `.swiftLanguageMode(.v5)`, Swift Testing, SwiftUI (sheet, fileExporter `.txt`).

## Global Constraints

- Spec: `docs/superpowers/specs/2026-07-28-m9b-audit-log-design.md` — binding. Branch: **develop**.
- ONLY log stored sessions (recorder nil for ad-hoc); the cap rolls to keep the NEWEST 1000 per session (`maxEntriesPerSession = 1000`, internal).
- `append`/`clear`/`deleteLog` NEVER throw and never disturb a workflow (errors are silent); `events(for:)` returns `[]` for a broken/missing file.
- `detail` is finished ENGLISH plain text; only the kind labels are localized (EN/DE). No navigation/listing events.
- The queue sink fires EXACTLY once per item at the existing `wasTerminal` gate (where `totalFailureCount` counts), never on progress updates; queue invariants untouched.
- Transfer mapping: `.finished`→transferFinished, `.failed`→transferFailed (with message), `.cancelled`→transferCancelled; `.skipped` and `.interrupted` are NOT logged (spec §1: only the three kinds; interrupted eventually ends up as a failed/finished rerun anyway).
- All new UI text EN/DE; code + comments ONLY English; no new SPM dependencies.
- Conventional Commits (English), footer: `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- `swift build` + the full `swift test` green after every task (starting point 412 tests / 34 suites); gated suites only in T4; tests run SYNCHRONOUSLY in the foreground.
- TDD for Core (store, recorder, sinks); the App target is untestable → T3 delivers a build plus a behavior description.

## Schedule

T1 (AuditEvent + AuditLogStore, Core) → T2 (AuditRecorder + Sinks, Core) → T3 (App: wiring + sheet + menu + delete hook) → T4 completion (coordinator).

---

### Task 1: AuditEvent + AuditLogStore (Core)

**Files:**
- Create: `Sources/macSCPCore/Sessions/AuditEvent.swift`, `Sources/macSCPCore/Sessions/AuditLogStore.swift`
- Test: `Tests/macSCPCoreTests/AuditLogStoreTests.swift` (new)

**Interfaces:**
- Produces (T2/T3 rely on this exactly):
  - `public struct AuditEvent: Codable, Equatable, Sendable, Identifiable { public let id: UUID; public let timestamp: Date; public let kind: Kind; public let detail: String; public let isError: Bool; public let errorMessage: String?; public init(id: UUID = UUID(), timestamp: Date = Date(), kind: Kind, detail: String, isError: Bool = false, errorMessage: String? = nil) }`
  - `public enum Kind: String, Codable, CaseIterable, Sendable` (in AuditEvent): `connected, disconnected, transferFinished, transferFailed, transferCancelled, rename, delete, permissions, newFolder, editUpload, crossSessionTransfer`
  - `public struct AuditLogStore: Sendable { public init(directory: URL); public static var defaultDirectory: URL; public func append(_ event: AuditEvent, for sessionID: UUID); public func events(for sessionID: UUID) -> [AuditEvent]; public func clear(for sessionID: UUID); public func deleteLog(for sessionID: UUID) }` — `append` trims to the newest 1000 (chronological order in the file), all mutations atomic, ALL methods never throw.
  - `static let maxEntriesPerSession = 1000` (internal, testable via `@testable`).

- [x] **Step 1: Failing tests** — `Tests/macSCPCoreTests/AuditLogStoreTests.swift`:

```swift
import Foundation
import Testing
@testable import macSCPCore

@Suite("AuditLogStore")
struct AuditLogStoreTests {
    private func makeStore() throws -> (AuditLogStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("audit-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (AuditLogStore(directory: dir), dir)
    }

    private func event(_ detail: String, kind: AuditEvent.Kind = .transferFinished) -> AuditEvent {
        AuditEvent(kind: kind, detail: detail)
    }

    @Test func appendAndReadRoundtrip() throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = UUID()
        store.append(event("first"), for: id)
        store.append(event("second", kind: .rename), for: id)
        let events = store.events(for: id)
        #expect(events.map(\.detail) == ["first", "second"])
        #expect(events[1].kind == .rename)
        // Other sessions are isolated.
        #expect(store.events(for: UUID()).isEmpty)
    }

    @Test func rollingCapKeepsNewest() throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = UUID()
        for index in 0...AuditLogStore.maxEntriesPerSession {  // one over the cap
            store.append(event("e\(index)"), for: id)
        }
        let events = store.events(for: id)
        #expect(events.count == AuditLogStore.maxEntriesPerSession)
        #expect(events.first?.detail == "e1")   // oldest ("e0") evicted
        #expect(events.last?.detail == "e\(AuditLogStore.maxEntriesPerSession)")
    }

    @Test func clearAndDeleteRemoveEverything() throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = UUID()
        store.append(event("x"), for: id)
        store.clear(for: id)
        #expect(store.events(for: id).isEmpty)
        store.append(event("y"), for: id)
        store.deleteLog(for: id)
        #expect(store.events(for: id).isEmpty)
        #expect(!FileManager.default.fileExists(
            atPath: dir.appendingPathComponent("\(id).json").path(percentEncoded: false)))
    }

    @Test func corruptFileReadsAsEmpty() throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = UUID()
        try Data("not json".utf8).write(to: dir.appendingPathComponent("\(id).json"))
        #expect(store.events(for: id).isEmpty)
        // A later append recovers the file (starts fresh rather than throwing).
        store.append(event("fresh"), for: id)
        #expect(store.events(for: id).map(\.detail) == ["fresh"])
    }

    @Test func unwritableDirectoryNeverThrowsOrDisturbs() throws {
        // Directory path that is actually a FILE (M9a pattern): every write
        // fails internally; append must swallow it silently.
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("audit-blocked-\(UUID().uuidString)")
        try Data().write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let store = AuditLogStore(directory: file)
        let id = UUID()
        store.append(event("lost"), for: id)   // must not throw/trap
        store.clear(for: id)
        store.deleteLog(for: id)
        #expect(store.events(for: id).isEmpty)
    }
}
```

- [x] **Step 2: Prove red.** `swift test --filter AuditLogStoreTests` → FAIL (types missing).

- [x] **Step 3: Implementation.** `AuditEvent.swift` exactly per the interfaces block (with doc comments: detail = finished English plain text, display localizes only the kind labels). `AuditLogStore.swift` following the `SessionStore` pattern:

```swift
import Foundation

/// Per-session audit log persistence (M9b). One JSON file per stored
/// session under `audit/`, rolling cap of the newest 1000 entries.
/// EVERY method is throw-free by design: a broken log must never disturb
/// a transfer or file action (spec M9b §2) — write errors are swallowed,
/// a corrupt file reads as empty and is recovered by the next append.
public struct AuditLogStore: Sendable {
    static let maxEntriesPerSession = 1000

    private let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public static var defaultDirectory: URL {
        SessionStore.defaultDirectory.appendingPathComponent("audit", isDirectory: true)
    }

    private func fileURL(for sessionID: UUID) -> URL {
        directory.appendingPathComponent("\(sessionID.uuidString).json")
    }

    public func append(_ event: AuditEvent, for sessionID: UUID) {
        var events = self.events(for: sessionID)
        events.append(event)
        if events.count > Self.maxEntriesPerSession {
            events.removeFirst(events.count - Self.maxEntriesPerSession)
        }
        persist(events, for: sessionID)
    }

    public func events(for sessionID: UUID) -> [AuditEvent] {
        guard let data = try? Data(contentsOf: fileURL(for: sessionID)) else { return [] }
        return (try? JSONDecoder().decode([AuditEvent].self, from: data)) ?? []
    }

    public func clear(for sessionID: UUID) {
        persist([], for: sessionID)
    }

    public func deleteLog(for sessionID: UUID) {
        try? FileManager.default.removeItem(at: fileURL(for: sessionID))
    }

    private func persist(_ events: [AuditEvent], for sessionID: UUID) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(events).write(to: fileURL(for: sessionID), options: .atomic)
        } catch {
            // Deliberately silent (spec M9b §2): logging must never break
            // the flow it observes.
        }
    }
}
```

(Note: `UUID.uuidString` as a file name is stable; date encoding stays on the JSONEncoder default — the round-trip test covers this.)

- [x] **Step 4: Green + full suite.** Filter suite PASS; `swift test` → 412 + 5 = 417 (record the real number); build clean.

- [x] **Step 5: Commit.** `feat: add the per-session audit log store`

---

### Task 2: AuditRecorder + Sinks (Core)

**Files:**
- Create: `Sources/macSCPCore/Sessions/AuditRecorder.swift`
- Modify: `Sources/macSCPCore/Presentation/TransferQueueViewModel.swift` (auditSink + Item.isEditUpload), `Sources/macSCPCore/Presentation/RemoteBrowserViewModel.swift` (auditSink in the four actions)
- Test: `Tests/macSCPCoreTests/AuditRecorderTests.swift` (new), `Tests/macSCPCoreTests/TransferQueueViewModelTests.swift` + `Tests/macSCPCoreTests/RemoteBrowserViewModelTests.swift` (add sink tests)

**Interfaces:**
- Consumes: `AuditEvent`/`AuditLogStore` (T1), `TransferQueueViewModel.Item` (fileName/direction/status/destinationTabID), the four VM actions.
- Produces (T3 relies on this exactly):
  - `public struct AuditRecorder: Sendable { public let sessionID: UUID; public init(sessionID: UUID, store: AuditLogStore); public func recordConnected(host: String, username: String); public func recordDisconnected(); public func recordTransfer(_ item: TransferQueueViewModel.Item, targetTitle: String?); public func recordAction(_ event: AuditEvent) }`
  - `recordTransfer` mapping: `.finished` → `transferFinished` (or `editUpload` if `item.isEditUpload`; or `crossSessionTransfer` if `item.destinationTabID != nil` — detail then `to "<targetTitle ?? "unknown session">": <fileName>`); `.failed(message)` → `transferFailed` with `isError: true, errorMessage: message`; `.cancelled` → `transferCancelled`; `.skipped`/`.interrupted`/non-terminal → NO event (the method returns silently). Base detail form: `"upload <fileName>"` / `"download <fileName>"`.
  - `TransferQueueViewModel.auditSink: ((Item) -> Void)?` (public var, default nil) — called at the `wasTerminal` gate (right next to `totalFailureCount`), AFTER the status write, with the updated item.
  - `TransferQueueViewModel.Item.isEditUpload: Bool` (public let, default false; `true` only on the `enqueueEditUpload` path — passed through analogously to `destinationTabID`).
  - `RemoteBrowserViewModel.auditSink: ((AuditEvent) -> Void)?` (public var, default nil) — the four actions report after completion: success e.g. `AuditEvent(kind: .rename, detail: "rename <oldPath> → <newName>")`; failure the same kind with `isError: true, errorMessage: <the returned string>`. Kinds: rename/newFolder/permissions (detail `chmod <octal> <path>`)/delete (detail `delete <path1>, <path2>, …`).

- [x] **Step 1: Failing recorder tests** (`AuditRecorderTests.swift` — temp store like T1; build items via an internal test constructor or the existing path the queue tests use — read the file first):

```swift
    // Assertions (adapt the helper to the real construction paths):
    // finished upload            -> kind .transferFinished, detail has "upload" + fileName
    // finished + isEditUpload    -> kind .editUpload
    // finished + destinationTabID + targetTitle "db-prod"
    //                            -> kind .crossSessionTransfer, detail contains "db-prod"
    // finished + destinationTabID + targetTitle nil -> detail contains "unknown session"
    // failed("boom")             -> kind .transferFailed, isError, errorMessage "boom"
    // cancelled                  -> kind .transferCancelled
    // skipped / interrupted / running -> store stays EMPTY
    // recordConnected/Disconnected -> kinds .connected/.disconnected, host+user in the detail
```

- [x] **Step 2: Red**, then implement `AuditRecorder`, green.

- [x] **Step 3: Failing sink tests.** Queue (`TransferQueueViewModelTests.swift`, existing gate/mock patterns): (a) auditSink receives EXACTLY one call per item at the terminal transition (finished case; counter closure), (b) a repeated `setStatus` on an already-terminal item does NOT fire again (pattern of the totalFailureCount double-count test), (c) progress updates (running→running) never fire, (d) an `enqueueEditUpload` item carries `isEditUpload == true`, normal items `false`, (e) nil sink = no effect (existing regression runs via the full suite anyway). VM (`RemoteBrowserViewModelTests.swift`, the file's mock-FS pattern): rename success fires an event with kind .rename; rename failure (mock throws) fires an isError event with the localized message; deleteItems with 2 paths names both in the detail; nil sink fires nothing.

- [x] **Step 4: Red**, then implement the sinks: queue — `public var auditSink: ((Item) -> Void)?`; at the `wasTerminal` gate (`if status.isTerminal && !wasTerminal { … }`) after the existing lines `auditSink?(items[index])`; add `Item.isEditUpload` (all three item construction sites + job, analogous to `destinationTabID`; `enqueueEditUpload` sets true; the `retryInterrupted` retain passes it through). VM — `public var auditSink: ((AuditEvent) -> Void)?`; in the four actions, build the event after the result (success/failure) and `auditSink?(event)` (BEFORE the return; detail formats from the interfaces block). Green.

- [x] **Step 5: Full suite + commit.** `swift test` (417 + ~12; record the real number). Commit `feat: record transfers and file actions into the audit log`

---

### Task 3: App — wiring, sheet, menu, delete hook

**Files:**
- Create: `Sources/MacSCPApp/AuditLogSheet.swift`
- Modify: `Sources/MacSCPApp/SessionTab.swift` (auditRecorder), `Sources/MacSCPApp/ContentView.swift` (wiring, sheet state), `Sources/MacSCPApp/SessionSidebar.swift` (menu entry + callback), `Sources/macSCPCore/Presentation/SessionListViewModel.swift` (auditStore injection + deleteLog in delete), `Sources/MacSCPApp/Resources/en.lproj/Localizable.strings` + `de.lproj`
- Test: `Tests/macSCPCoreTests/SessionListViewModelTests.swift` (delete-clears-log test); rest of the App is visual smoke (T4)

**Interfaces:**
- Consumes: everything from T1/T2, `SessionTab`, `tabsModel`, the sidebar callback pattern, `PolishedButtonStyle`, the fileExporter pattern from M9a (`SessionExportDocument` as a template for a text document).

**Behavior requirements (spec §4/§5, binding):**
1. `SessionTab.auditRecorder: AuditRecorder?` — set in `connect(in:stored:)` AND in `startSession`, when that produces a stored session (`activeStoredSessionID` is set); immediately followed by `recordConnected(host:username:)` + wiring of `tab.transferQueue.auditSink` and `tab.session?.remote.auditSink` (the closure captures the recorder by value; the queue sink resolves `destinationTabID` via `tabsModel` to the target's `displayTitle` — tab gone ⇒ nil ⇒ "unknown session"). In `teardown(_:)`: `recordDisconnected()` (only if a recorder exists), then set the recorder and both sinks to nil. Ad-hoc connects NEVER set a recorder.
2. An app-wide `AuditLogStore` (default directory) — created in `MacSCPApp` next to SettingsStore/Limiter, passed to ContentView as a parameter (no singleton); `SessionListViewModel` receives it as an init parameter with default `AuditLogStore(directory: AuditLogStore.defaultDirectory)` and additionally calls `auditStore.deleteLog(for: session.id)` in `delete(_:)` — TDD: a Core test (temp directories) proves that delete removes the log file.
3. Sidebar: session context menu "Audit Log…" (key `sidebar.auditLog`) above "Delete", callback `onShowAuditLog(StoredSession)` following the existing pattern; opens the sheet even without an active connection.
4. `AuditLogSheet(session:store:)` (~640×480): title = session name; filter segments All/Transfers/File Ops/Connection/Errors (category mapping per spec §1: Transfers = transferFinished/Failed/Cancelled/editUpload/crossSessionTransfer; File Ops = rename/delete/permissions/newFolder; Connection = connected/disconnected; Errors = the isError cross-section); search field (case-insensitive over detail + errorMessage); table NEWEST ON TOP: time `dd.MM. HH:mm:ss` (DateFormatter, local), localized kind label, detail monospaced, error rows tinted red; footer: counter ("%lld entries" / "%lld of %lld"), "Export as text…" (fileExporter `.plainText`, line format `[<ISO8601>] <KIND-rawValue> <detail>` + ` — error: <message>` for errors, default name "<SessionName> Audit Log"), "Clear log…" (destructive + confirmationDialog, calls `clear(for:)` and reloads); empty-state hint text. Loaded on open, no live refresh.
5. Keys EN/DE (proposal): `sidebar.auditLog`, `audit.filter.all/transfers/fileOps/connection/errors`, `audit.search`, `audit.empty`, `audit.count %lld`, `audit.countFiltered %lld %lld`, `audit.export`, `audit.clear`, `audit.clear.title`, `audit.clear.message`, `audit.clear.confirm`, plus one label per kind `audit.kind.<rawValue>` (11 of them). Grep counter-check both catalogs.

- [x] **Step 1:** SessionListViewModel injection + delete hook (TDD: test red first). **Step 2:** SessionTab/ContentView wiring (recorder lifecycle, sink mapping). **Step 3:** AuditLogSheet + sidebar entry + sheet state. **Step 4:** catalog keys + counter-check. **Step 5:** `swift build` (0 errors, no new warnings) + full `swift test` (T2's count + 1). **Step 6:** commit `feat: show a per-session audit log from the sidebar`.

---

### Task 4: Final verification (coordinator)

- [x] Gated suites (rig started from the main checkout): `MACSCP_ITEST=1 MACSCP_KEYCHAIN=1 swift test` ⇒ fully green, zero skips (443 before / 445 after the final-review fixes).
- [ ] Visual smoke — **delegated to the maintainer** (wrapper runs; checklist in the milestone summary): connect a stored session → run transfer + rename + delete + chmod + new folder → disconnect → "Audit Log…" shows everything correctly (order newest on top, times local, failed transfer red); filter + search; cross-session transfer shows the target title; editor upload as its own kind; ad-hoc connection logs NOTHING; "Clear" with confirmation; open the text export and check the format; delete a session ⇒ log file gone (`ls Application Support/macSCP/audit/`); regressions in the sidebar menu/M9a entries.
- [x] Plan checkboxes, ledger, Opus whole-branch final review (base = commit before T1; "No" with three Importants → fix commit 1b42157 → re-review "Ready to merge: Yes"), fixes, push develop, CI, rig `stop`, memory update, milestone summary (+ M9c auto-refresh as next; release bundling still open).
