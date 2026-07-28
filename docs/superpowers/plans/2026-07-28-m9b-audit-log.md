# M9b — Audit-Log Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Pro gespeicherter Verbindung ein rollierendes 1000-Einträge-Protokoll (Verbindungen, Transfers, Datei-Operationen, Fehler), einsehbar über ein Sheet aus dem Sidebar-Kontextmenü, gelöscht mit der Verbindung.

**Architecture:** `AuditEvent` + `AuditLogStore` (SessionStore-Muster, Datei pro Session-ID) und `AuditRecorder` in Core; Aufzeichnung über zwei optionale Sinks (Queue-Terminal-Übergang, Remote-VM-Aktionen) plus direkte Connect/Teardown-Aufrufe im Tab-Fluss; App-Seite ist das Audit-Sheet mit Filter/Suche/Export/Leeren.

**Tech Stack:** Swift 6 / `.swiftLanguageMode(.v5)`, Swift Testing, SwiftUI (Sheet, fileExporter `.txt`).

## Global Constraints

- Spec: `docs/superpowers/specs/2026-07-28-m9b-audit-log-design.md` — bindend. Branch: **develop**.
- NUR gespeicherte Sessions loggen (Recorder nil bei Ad-hoc); Deckel rollierend die NEUESTEN 1000 pro Session (`maxEntriesPerSession = 1000`, internal).
- `append`/`clear`/`deleteLog` werfen NIE und stören nie einen Arbeitsfluss (Fehler still); `events(for:)` liefert bei kaputter/fehlender Datei `[]`.
- `detail` ist fertiger ENGLISCHER Klartext; lokalisiert werden nur Kind-Labels (EN/DE). Keine Navigations-/Listing-Ereignisse.
- Queue-Sink feuert EXAKT einmal pro Item am bestehenden `wasTerminal`-Gate (wo `totalFailureCount` zählt), nie bei Progress-Updates; Queue-Invarianten unangetastet.
- Transfer-Mapping: `.finished`→transferFinished, `.failed`→transferFailed (mit Meldung), `.cancelled`→transferCancelled; `.skipped` und `.interrupted` werden NICHT geloggt (Spec §1: nur die drei Kinds; interrupted endet später ohnehin als failed/finished-Neulauf).
- Alle neuen UI-Texte EN/DE; Code + Kommentare NUR Englisch; keine neuen SPM-Dependencies.
- Conventional Commits (Englisch), Footer: `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- `swift build` + volle `swift test` nach jedem Task grün (Ausgangslage 412 Tests / 34 Suiten); gated Suiten nur in T4; Tests SYNCHRON im Vordergrund.
- TDD für Core (Store, Recorder, Sinks); App-Target untestbar → T3 liefert Build + Verhaltensbeschreibung.

## Schedule

T1 (AuditEvent + AuditLogStore, Core) → T2 (AuditRecorder + Sinks, Core) → T3 (App: Verkabelung + Sheet + Menü + Lösch-Hook) → T4 Abschluss (Koordinator).

---

### Task 1: AuditEvent + AuditLogStore (Core)

**Files:**
- Create: `Sources/macSCPCore/Sessions/AuditEvent.swift`, `Sources/macSCPCore/Sessions/AuditLogStore.swift`
- Test: `Tests/macSCPCoreTests/AuditLogStoreTests.swift` (neu)

**Interfaces:**
- Produces (T2/T3 verlassen sich exakt hierauf):
  - `public struct AuditEvent: Codable, Equatable, Sendable, Identifiable { public let id: UUID; public let timestamp: Date; public let kind: Kind; public let detail: String; public let isError: Bool; public let errorMessage: String?; public init(id: UUID = UUID(), timestamp: Date = Date(), kind: Kind, detail: String, isError: Bool = false, errorMessage: String? = nil) }`
  - `public enum Kind: String, Codable, CaseIterable, Sendable` (in AuditEvent): `connected, disconnected, transferFinished, transferFailed, transferCancelled, rename, delete, permissions, newFolder, editUpload, crossSessionTransfer`
  - `public struct AuditLogStore: Sendable { public init(directory: URL); public static var defaultDirectory: URL; public func append(_ event: AuditEvent, for sessionID: UUID); public func events(for sessionID: UUID) -> [AuditEvent]; public func clear(for sessionID: UUID); public func deleteLog(for sessionID: UUID) }` — `append` kappt auf die neuesten 1000 (chronologische Reihenfolge in der Datei), alle Mutationen atomar, ALLE Methoden werfen nie.
  - `static let maxEntriesPerSession = 1000` (internal, testbar via `@testable`).

- [ ] **Step 1: Failing Tests** — `Tests/macSCPCoreTests/AuditLogStoreTests.swift`:

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

- [ ] **Step 2: Rot beweisen.** `swift test --filter AuditLogStoreTests` → FAIL (Typen fehlen).

- [ ] **Step 3: Implementierung.** `AuditEvent.swift` exakt laut Interfaces-Block (mit Doku-Kommentaren: detail = fertiger englischer Klartext, Anzeige lokalisiert nur Kind-Labels). `AuditLogStore.swift` nach `SessionStore`-Muster:

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

(Hinweis: `UUID.uuidString` als Dateiname ist stabil; Datums-Kodierung bleibt beim JSONEncoder-Default — Roundtrip-Test deckt das.)

- [ ] **Step 4: Grün + volle Suite.** Filter-Suite PASS; `swift test` → 412 + 5 = 417 (echte Zahl festhalten); Build sauber.

- [ ] **Step 5: Commit.** `feat: add the per-session audit log store`

---

### Task 2: AuditRecorder + Sinks (Core)

**Files:**
- Create: `Sources/macSCPCore/Sessions/AuditRecorder.swift`
- Modify: `Sources/macSCPCore/Presentation/TransferQueueViewModel.swift` (auditSink + Item.isEditUpload), `Sources/macSCPCore/Presentation/RemoteBrowserViewModel.swift` (auditSink in den vier Aktionen)
- Test: `Tests/macSCPCoreTests/AuditRecorderTests.swift` (neu), `Tests/macSCPCoreTests/TransferQueueViewModelTests.swift` + `Tests/macSCPCoreTests/RemoteBrowserViewModelTests.swift` (Sink-Tests ergänzen)

**Interfaces:**
- Consumes: `AuditEvent`/`AuditLogStore` (T1), `TransferQueueViewModel.Item` (fileName/direction/status/destinationTabID), die vier VM-Aktionen.
- Produces (T3 verlässt sich exakt hierauf):
  - `public struct AuditRecorder: Sendable { public let sessionID: UUID; public init(sessionID: UUID, store: AuditLogStore); public func recordConnected(host: String, username: String); public func recordDisconnected(); public func recordTransfer(_ item: TransferQueueViewModel.Item, targetTitle: String?); public func recordAction(_ event: AuditEvent) }`
  - `recordTransfer`-Mapping: `.finished` → `transferFinished` (bzw. `editUpload`, wenn `item.isEditUpload`; bzw. `crossSessionTransfer`, wenn `item.destinationTabID != nil` — Detail dann `to “<targetTitle ?? "unknown session">”: <fileName>`); `.failed(message)` → `transferFailed` mit `isError: true, errorMessage: message`; `.cancelled` → `transferCancelled`; `.skipped`/`.interrupted`/nicht-terminal → KEIN Event (Methode kehrt still zurück). Detail-Basisform: `"upload <fileName>"` / `"download <fileName>"`.
  - `TransferQueueViewModel.auditSink: ((Item) -> Void)?` (public var, Default nil) — Aufruf am `wasTerminal`-Gate (direkt neben `totalFailureCount`), NACH dem Status-Schreiben, mit dem aktualisierten Item.
  - `TransferQueueViewModel.Item.isEditUpload: Bool` (public let, Default false; `true` nur auf dem `enqueueEditUpload`-Pfad — analog `destinationTabID` durchgereicht).
  - `RemoteBrowserViewModel.auditSink: ((AuditEvent) -> Void)?` (public var, Default nil) — die vier Aktionen melden nach Abschluss: Erfolg z. B. `AuditEvent(kind: .rename, detail: "rename <altPfad> → <neuerName>")`; Fehler dasselbe Kind mit `isError: true, errorMessage: <der zurückgegebene String>`. Kinds: rename/newFolder/permissions (Detail `chmod <octal> <pfad>`)/delete (Detail `delete <pfad1>, <pfad2>, …`).

- [ ] **Step 1: Failing Recorder-Tests** (`AuditRecorderTests.swift` — Temp-Store wie T1; Items über einen internen Test-Konstruktor oder den vorhandenen Weg bauen, den die Queue-Tests nutzen — Datei vorher lesen):

```swift
    // Assertions (Helper an die realen Konstruktionswege anpassen):
    // finished upload            -> kind .transferFinished, detail hat "upload" + fileName
    // finished + isEditUpload    -> kind .editUpload
    // finished + destinationTabID + targetTitle "db-prod"
    //                            -> kind .crossSessionTransfer, detail enthält "db-prod"
    // finished + destinationTabID + targetTitle nil -> detail enthält "unknown session"
    // failed("boom")             -> kind .transferFailed, isError, errorMessage "boom"
    // cancelled                  -> kind .transferCancelled
    // skipped / interrupted / running -> store bleibt LEER
    // recordConnected/Disconnected -> kinds .connected/.disconnected, Host+User im Detail
```

- [ ] **Step 2: Rot**, dann `AuditRecorder` implementieren, grün.

- [ ] **Step 3: Failing Sink-Tests.** Queue (`TransferQueueViewModelTests.swift`, vorhandene Gate-/Mock-Muster): (a) auditSink erhält pro Item EXAKT einen Aufruf beim Terminal-Übergang (finished-Fall; Zähler-Closure), (b) wiederholtes `setStatus` auf bereits-terminalem Item feuert NICHT erneut (Muster des totalFailureCount-Doppelzähl-Tests), (c) Progress-Updates (running→running) feuern nie, (d) `enqueueEditUpload`-Item trägt `isEditUpload == true`, normale Items `false`, (e) nil-Sink = kein Effekt (Bestands-Regression läuft ohnehin über die volle Suite). VM (`RemoteBrowserViewModelTests.swift`, Mock-FS-Muster der Datei): rename-Erfolg feuert Event mit kind .rename; rename-Fehler (Mock wirft) feuert isError-Event mit der lokalisierten Meldung; deleteItems mit 2 Pfaden nennt beide im Detail; nil-Sink feuert nichts.

- [ ] **Step 4: Rot**, dann Sinks implementieren: Queue — `public var auditSink: ((Item) -> Void)?`; am `wasTerminal`-Gate (`if status.isTerminal && !wasTerminal { … }`) nach den bestehenden Zeilen `auditSink?(items[index])`; `Item.isEditUpload` ergänzen (alle drei Item-Konstruktionsstellen + Job analog `destinationTabID`; `enqueueEditUpload` setzt true; `retryInterrupted`-Retain reicht durch). VM — `public var auditSink: ((AuditEvent) -> Void)?`; in den vier Aktionen nach dem Ergebnis das Event bauen (Erfolg/Fehler) und `auditSink?(event)` (VOR dem return; Detail-Formate aus dem Interfaces-Block). Grün.

- [ ] **Step 5: Volle Suite + Commit.** `swift test` (417 + ~12; echte Zahl festhalten). Commit `feat: record transfers and file actions into the audit log`

---

### Task 3: App — Verkabelung, Sheet, Menü, Lösch-Hook

**Files:**
- Create: `Sources/MacSCPApp/AuditLogSheet.swift`
- Modify: `Sources/MacSCPApp/SessionTab.swift` (auditRecorder), `Sources/MacSCPApp/ContentView.swift` (Verdrahtung, Sheet-State), `Sources/MacSCPApp/SessionSidebar.swift` (Menüeintrag + Callback), `Sources/macSCPCore/Presentation/SessionListViewModel.swift` (auditStore-Injektion + deleteLog im delete), `Sources/MacSCPApp/Resources/en.lproj/Localizable.strings` + `de.lproj`
- Test: `Tests/macSCPCoreTests/SessionListViewModelTests.swift` (delete-räumt-Log-Test); App-Rest visueller Smoke (T4)

**Interfaces:**
- Consumes: alles aus T1/T2, `SessionTab`, `tabsModel`, Sidebar-Callback-Muster, `PolishedButtonStyle`, fileExporter-Muster aus M9a (`SessionExportDocument` als Vorlage für ein Text-Dokument).

**Verhaltens-Anforderungen (Spec §4/§5, bindend):**
1. `SessionTab.auditRecorder: AuditRecorder?` — gesetzt in `connect(in:stored:)` UND in `startSession`, wenn dabei eine gespeicherte Session entsteht (`activeStoredSessionID` gesetzt wird); direkt danach `recordConnected(host:username:)` + Verdrahtung `tab.transferQueue.auditSink` und `tab.session?.remote.auditSink` (Closure captured den Recorder by value; Queue-Sink löst `destinationTabID` über `tabsModel` zum Ziel-`displayTitle` auf — Tab weg ⇒ nil ⇒ „unknown session"). Im `teardown(_:)`: `recordDisconnected()` (nur wenn Recorder existiert), dann Recorder + beide Sinks auf nil. Ad-hoc-Connects setzen NIE einen Recorder.
2. Ein app-weiter `AuditLogStore` (Default-Verzeichnis) — erzeugt in `MacSCPApp` neben SettingsStore/Limiter, per Parameter an ContentView (kein Singleton); `SessionListViewModel` bekommt ihn als Init-Parameter mit Default `AuditLogStore(directory: AuditLogStore.defaultDirectory)` und ruft in `delete(_:)` zusätzlich `auditStore.deleteLog(for: session.id)` — TDD: Core-Test (Temp-Verzeichnisse) beweist, dass delete die Log-Datei entfernt.
3. Sidebar: Session-Kontextmenü „Audit-Log…" (Key `sidebar.auditLog`) über „Löschen", Callback `onShowAuditLog(StoredSession)` nach bestehendem Muster; öffnet das Sheet auch ohne aktive Verbindung.
4. `AuditLogSheet(session:store:)` (~640×480): Titel = Session-Name; Filter-Segmente Alle/Transfers/Datei-Ops/Verbindung/Fehler (Kategorie-Zuordnung Spec §1: Transfers = transferFinished/Failed/Cancelled/editUpload/crossSessionTransfer; Datei-Ops = rename/delete/permissions/newFolder; Verbindung = connected/disconnected; Fehler = isError-Querschnitt); Suchfeld (case-insensitiv über detail + errorMessage); Tabelle NEUESTE OBEN: Zeit `dd.MM. HH:mm:ss` (DateFormatter, lokal), lokalisiertes Kind-Label, Detail monospaced, Fehlerzeilen rot getönt; Fußzeile: Zähler („%lld Einträge" bzw. „%lld von %lld"), „Als Text exportieren…" (fileExporter `.plainText`, Zeilenformat `[<ISO8601>] <KIND-rawValue> <detail>` + ` — error: <message>` bei Fehlern, Default-Name „<SessionName> Audit Log"), „Log leeren…" (destruktiv + confirmationDialog, ruft `clear(for:)` und lädt neu); leerer Zustand Hinweistext. Laden beim Öffnen, kein Live-Refresh.
5. Keys EN/DE (Vorschlag): `sidebar.auditLog`, `audit.filter.all/transfers/fileOps/connection/errors`, `audit.search`, `audit.empty`, `audit.count %lld`, `audit.countFiltered %lld %lld`, `audit.export`, `audit.clear`, `audit.clear.title`, `audit.clear.message`, `audit.clear.confirm`, plus je Kind ein Label `audit.kind.<rawValue>` (11 Stück). Grep-Gegenprobe beide Kataloge.

- [ ] **Step 1:** SessionListViewModel-Injektion + delete-Hook (TDD: Test zuerst rot). **Step 2:** SessionTab/ContentView-Verdrahtung (Recorder-Lebenszyklus, Sink-Mapping). **Step 3:** AuditLogSheet + Sidebar-Eintrag + Sheet-State. **Step 4:** Katalog-Keys + Gegenprobe. **Step 5:** `swift build` (0 Fehler, keine neuen Warnungen) + volle `swift test` (Stand T2 + 1). **Step 6:** Commit `feat: show a per-session audit log from the sidebar`.

---

### Task 4: Abschluss-Verifikation (Koordinator)

- [ ] Gated Suiten (Rig-Start aus dem Haupt-Checkout): `MACSCP_ITEST=1 MACSCP_KEYCHAIN=1 swift test` ⇒ komplett grün, zero skips.
- [ ] Visueller Smoke (Dev-Wrapper; Maintainer testet ggf. selbst — Checkliste übergeben): gespeicherte Session verbinden → Transfer + Umbenennen + Löschen + chmod + Neuer Ordner ausführen → trennen → „Audit-Log…" zeigt alles korrekt (Reihenfolge neueste oben, Zeiten lokal, Fehlertransfer rot); Filter + Suche; Cross-Session-Transfer zeigt Ziel-Titel; Editor-Upload als eigenes Kind; Ad-hoc-Verbindung loggt NICHTS; „Leeren" mit Rückfrage; Text-Export öffnen und Format prüfen; Session löschen ⇒ Log-Datei weg (`ls Application Support/macSCP/audit/`); Regressionen Sidebar-Menü/M9a-Einträge.
- [ ] Plan-Checkboxen, Ledger, Opus-Whole-Branch-Final-Review (Base = Commit vor T1), Fixes, Push develop, CI, Rig `stop`, Memory-Update, Milestone-Zusammenfassung (+ M9c Auto-Refresh als Nächstes; Release-Bündelung weiter offen).
