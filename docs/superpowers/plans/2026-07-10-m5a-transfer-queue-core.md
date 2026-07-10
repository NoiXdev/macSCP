# macSCP M5a — Transfer-Queue-Kern Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** ALLE drei Transferwege (Buttons, Drop, Finder-Promise) laufen durch EINE Warteschlange mit sichtbarer Queue-Leiste — Drops und Klicks während laufender Transfers werden eingereiht statt verworfen.

**Architektur:** Neues `TransferQueueViewModel` (@Observable @MainActor) mit Item-Liste und seriellem Worker-Loop (Parallelität 1 in M5a — die Abstraktion trägt N Worker, aber gleichzeitige Transfers über EINEN SFTP-Channel werden erst in M5c empirisch validiert und hochgedreht; Spec-Default 3 kommt dann). `enqueue` reiht ein und weckt den Worker; `enqueueAndWait` (für den Promise-Pfad) wartet per Continuation auf den Abschluss GENAU dieses Items. `TransferBar` wird durch `TransferQueueBar` (Item-Liste) ersetzt; das alte Ein-Transfer-`TransferViewModel` wird am Ende gelöscht.

**Tech Stack:** Bestehende `TransferEngine.copyFile` (unverändert), `TransferProgress`/`TransferDirection`, MockRemoteFileSystem für Tests.

## Global Constraints

- swift-tools 6.0; ALLE Targets `.swiftLanguageMode(.v5)`; macOS 15; Swift Testing, TDD rot→grün.
- Duo-Farben semantisch: ↑ Bernstein (`DesignTokens.localAmber`) = Upload, ↓ Ozeanblau (`DesignTokens.remoteBlue`) = Download; Fehler System-Rot. Deutsche UI-Texte.
- Gated Tests: `MACSCP_ITEST=1` (Rig NUR aus dem Haupt-Checkout), `MACSCP_KEYCHAIN=1`.
- Die UI besitzt Lebenszyklen explizit: `teardownSession` räumt die Queue VOR dem Disconnect (Muster: Terminal-Shutdown M4).
- Kein Verhalten des Terminals/TOFU anfassen (außer Task 0a, der gezielt den Terminal-Screen-Erhalt fixt).
- Conventional Commits, Footer `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`. Implementierer pushen nicht.

**Abhängigkeitsgraph:** `[ Task 0 (M5-Openings) ∥ Task 1 (Queue-VM, Core) ] → Task 2 (Queue-Leiste, UI) → Task 3 (ContentView-Umbau) → Task 4 (Abschluss)` — T0/T1 dateidisjunkt (Worktree-parallel).

---

### Task 0: M5-Openings — Terminal-Screen-Erhalt + Cancellation-Fast-Path-Test

**Files:**
- Modify: `Sources/macSCPCore/Presentation/TerminalPanelViewModel.swift`
- Modify: `Sources/MacSCPApp/SSHTerminalView.swift`
- Test: `Tests/macSCPCoreTests/TerminalPanelViewModelTests.swift` (ergänzen)
- Test: `Tests/macSCPCoreTests/ConnectionViewModelTests.swift` (ergänzen)

**Interfaces:**
- Produces: `TerminalPanelViewModel.replayBuffer: [[UInt8]]` (public read) — von der View beim Mount abgespielt.

**Hintergrund (Final-Review M4, Minor 1):** ⌘T-Ausblenden bei laufender Shell unmountet die `TerminalView`; `onOutput`s weak-Ref wird nil, der Lese-Loop verwirft alle Chunks; beim Wiedereinblenden startet eine leere Konsole. Fix: Der VM puffert die letzten Output-Chunks und die View spielt sie in `makeNSView` ab.

- [ ] **Step 1: Fehlschlagender Test — Replay-Puffer**

```swift
@Test func outputIsBufferedForReplayWhileHidden() async throws {
    let shell = MockShell()
    let vm = TerminalPanelViewModel(openShell: { _, _, _ in shell })
    vm.toggle()
    try await waitUntil { vm.state == .running }
    // Kein onOutput gesetzt (Panel ausgeblendet) — Chunks dürfen nicht verloren gehen
    shell.continuation.yield(Array("verborgen".utf8))
    try await waitUntil { !vm.replayBuffer.isEmpty }
    #expect(vm.replayBuffer.flatMap { $0 } == Array("verborgen".utf8))
    // Neuer Konsument (Re-Mount) sieht Puffer + Live-Daten
    var received: [[UInt8]] = []
    vm.onOutput = { received.append($0) }
    shell.continuation.yield(Array("live".utf8))
    try await waitUntil { !received.isEmpty }
}
```

Zweiter Test: Puffer ist gedeckelt (ältestes fliegt raus) — Konstante `maxReplayBytes = 256 * 1024`:

```swift
@Test func replayBufferIsBounded() async throws {
    let shell = MockShell()
    let vm = TerminalPanelViewModel(openShell: { _, _, _ in shell })
    vm.toggle()
    try await waitUntil { vm.state == .running }
    shell.continuation.yield([UInt8](repeating: 1, count: 200_000))
    shell.continuation.yield([UInt8](repeating: 2, count: 200_000))
    try await waitUntil { vm.replayBuffer.count == 1 || vm.replayBuffer.reduce(0) { $0 + $1.count } <= 256 * 1024 }
    #expect(vm.replayBuffer.reduce(0) { $0 + $1.count } <= 256 * 1024)
    #expect(vm.replayBuffer.last?.last == 2)  // Neuestes bleibt
}
```

- [ ] **Step 2: Rot** — `replayBuffer` unbekannt.

- [ ] **Step 3: Implementieren**

Im VM: privater Puffer, im Lese-Loop VOR dem `onOutput`-Aufruf füllen; bei `shutdown()` und beim Neu-Öffnen (`openIfNeeded` nach `.ended`) leeren:

```swift
/// Zuletzt empfangene Output-Chunks (max. 256 KiB) — Replay beim Wieder-
/// einblenden des Panels, damit ⌘T den sichtbaren Screen nicht verwirft.
public private(set) var replayBuffer: [[UInt8]] = []
private static let maxReplayBytes = 256 * 1024
private var replayBytes = 0

private func bufferForReplay(_ chunk: [UInt8]) {
    replayBuffer.append(chunk)
    replayBytes += chunk.count
    while replayBytes > Self.maxReplayBytes, !replayBuffer.isEmpty {
        replayBytes -= replayBuffer.removeFirst().count
    }
}
```

Im Lese-Loop (`readTask`): `self?.bufferForReplay(chunk)` vor `self?.onOutput?(chunk)`. In `openIfNeeded` (vor dem Öffnen) und `shutdown()`: `replayBuffer = []; replayBytes = 0`.

In `SSHTerminalView.makeNSView`, direkt nach dem Setzen von `viewModel.onOutput`:

```swift
for chunk in viewModel.replayBuffer {
    terminal.feed(byteArray: chunk[...])
}
```

- [ ] **Step 4: Cancellation-Fast-Path-Test** (Final-Review Minor 2) — in `ConnectionViewModelTests.swift`: Connector, dessen `onUnknownHostKey`-Aufruf erst NACH dem Cancel kommt (Connector wartet auf ein Signal; Test cancelt die connect-Task, gibt dann das Signal frei) → `presentHostKeyPrompt` läuft mit bereits gesetzter Cancellation in `withCheckedContinuation` und muss über den `Task.isCancelled`-Fast-Path sofort `false` liefern; Assertion: connect kehrt zurück (Timeout-Race-Muster der Datei wiederverwenden), kein Hänger. Falls der Fast-Path nach ehrlichem Versuch nicht deterministisch erreichbar ist (onCancel-Handler feuert immer zuerst), den Test als deterministischen Nachweis des GESAMTVERHALTENS (cancel-vor-Prompt → kein Hänger) formulieren und im Report dokumentieren, welcher Pfad greift.

- [ ] **Step 5: Grün** — Filter-Suiten + Gesamtsuite (145 + 3 neue = 148 erwartet).
- [ ] **Step 6: Commit** — `fix: preserve terminal screen across panel toggle` (mit Footer).

---

### Task 1: TransferQueueViewModel (Core)

**Files:**
- Create: `Sources/macSCPCore/Presentation/TransferQueueViewModel.swift`
- Test: `Tests/macSCPCoreTests/TransferQueueViewModelTests.swift`

**Interfaces:**
- Consumes: `TransferEngine.copyFile(from:sourcePath:to:destinationDirectory:fileName:onProgress:)` (unverändert), `TransferProgress`, `TransferDirection`.
- Produces (für T2/T3 bindend):

```swift
@Observable @MainActor
public final class TransferQueueViewModel {
    public struct Item: Identifiable, Equatable {
        public enum Status: Equatable {
            case queued
            case running(TransferProgress)
            case finished
            case failed(String)      // deutsche Meldung
            case cancelled
        }
        public let id: UUID
        public let fileName: String
        public let direction: TransferDirection
        public internal(set) var status: Status
    }

    public private(set) var items: [Item]
    /// true solange irgendein Item queued/running ist (Sidebar-Gate).
    public var isActive: Bool { get }
    /// Anzahl offener (queued+running) Items — fürs "n ausstehend"-Label.
    public var pendingCount: Int { get }

    public init()

    /// Reiht ein und startet den Worker, falls er schläft. Läuft IMMER an —
    /// kein isRunning-Verwerfen mehr.
    @discardableResult
    public func enqueue(
        fileName: String, direction: TransferDirection,
        source: any RemoteFileSystem, sourcePath: String,
        destination: any RemoteFileSystem, destinationDirectory: String,
        onCompleted: (@MainActor () async -> Void)?
    ) -> UUID

    /// Wie enqueue, kehrt aber erst zurück, wenn GENAU dieses Item fertig ist.
    /// Wirft bei failed/cancelled (Promise-Pfad: Finder braucht die Datei).
    public func enqueueAndWait(
        fileName: String, direction: TransferDirection,
        source: any RemoteFileSystem, sourcePath: String,
        destination: any RemoteFileSystem, destinationDirectory: String
    ) async throws

    /// Bricht alles ab: laufenden Transfer canceln, queued → .cancelled,
    /// wartende Continuations werfen. Kehrt erst nach Worker-Stopp zurück.
    public func cancelAll() async

    /// Entfernt finished/failed/cancelled aus der Liste.
    public func clearCompleted()
}
```

**Kernpunkte der Implementierung:**

```swift
// Privater Zustand:
private struct Job {
    let id: UUID
    let source: any RemoteFileSystem
    let sourcePath: String
    let destination: any RemoteFileSystem
    let destinationDirectory: String
    let fileName: String
    let onCompleted: (@MainActor () async -> Void)?
}
private var jobs: [UUID: Job] = [:]
private var order: [UUID] = []                 // FIFO der queued-Items
private var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]
private var workerTask: Task<Void, Never>?
private var runningTransferTask: Task<Void, Error>?   // fürs Cancel des aktiven copyFile

// Worker-Loop (seriell, MainActor-Klasse, copyFile awaited off-main):
private func kickWorker() {
    guard workerTask == nil else { return }
    workerTask = Task { [weak self] in
        while let self, let jobID = self.nextQueuedID() {
            await self.process(jobID)
        }
        self?.workerTask = nil
    }
}
```

`process(_:)` setzt Status `.running(TransferProgress(bytesTransferred: 0, totalBytes: nil))`, nutzt das GEORDNETE AsyncStream-Consumer-Muster aus dem alten `TransferViewModel` (ein Konsument aktualisiert `items[...] .status = .running(progress)`), führt `TransferEngine.copyFile` in einer eigenen `runningTransferTask` aus (damit `cancelAll` sie canceln kann), setzt am Ende `.finished`/`.failed(message)`, ruft `onCompleted` (nur bei Erfolg), und resumed den Waiter (`waiters.removeValue(forKey:)`: Erfolg → `resume()`, Fehler → `resume(throwing:)`).

Fehlertexte: `Self.message(for:)` — die switch-Fälle 1:1 aus `TransferViewModel.message(for:)` übernehmen (die Datei existiert bis T3 noch als Referenz).

`cancelAll()`: alle queued-IDs aus `order` → Status `.cancelled`, deren Waiter mit `CancellationError()` resumen; `runningTransferTask?.cancel()`; `await workerTask?.value` (Worker beendet sich, weil `nextQueuedID()` nichts mehr liefert und das laufende copyFile mit CancellationError endet → Status des aktiven Items `.cancelled`, nicht `.failed`); erst dann zurückkehren. `CancellationError` in `process` gesondert behandeln (`catch is CancellationError` → `.cancelled`).

**Achtung Reentrancy:** `enqueue` während der Worker läuft hängt nur an `order`/`jobs`/`items` an — der laufende `while`-Loop nimmt es im nächsten Durchlauf mit. KEIN zweiter Worker (Guard `workerTask == nil`).

- [ ] **Step 1: Fehlschlagende Tests** — `TransferQueueViewModelTests.swift`, Mock-Muster aus `TransferViewModelTests.swift` übernehmen (MockRemoteFileSystem mit read/write-Streams existiert dort; ggf. gemeinsame Helfer kopieren statt teilen). Bindende Verhaltens-Zusicherungen:

  1. `enqueueRunsTransferAndFinishes` — ein Item, Status-Verlauf queued→running→finished, `onCompleted` genau 1×, Datei beim Ziel-Mock angekommen.
  2. `secondEnqueueDuringRunningIsQueuedNotDropped` — zwei enqueues direkt nacheinander (Mock-Read mit Verzögerung/Signal), Item 2 hat Status `.queued` WÄHREND Item 1 läuft, danach laufen BEIDE fertig (das pinnt den alten isRunning-Drop als tot).
  3. `itemsRunInFIFOOrder` — drei Items, Abschluss-Reihenfolge == Einreihungs-Reihenfolge (Mock protokolliert Schreib-Reihenfolge).
  4. `failedItemDoesNotBlockQueue` — Item 1 wirft (Mock-Fehler `RemoteFSError.notFound`), Status `.failed` mit deutscher Meldung, Item 2 läuft trotzdem und finisht.
  5. `enqueueAndWaitReturnsAfterCompletion` — kehrt erst nach `.finished` zurück (Task + Signal-Mock beweisen die Ordnung).
  6. `enqueueAndWaitThrowsOnFailure` — Mock wirft → `enqueueAndWait` wirft.
  7. `cancelAllCancelsQueuedAndRunning` — Item 1 läuft (Mock blockiert auf Signal), Item 2 queued; `cancelAll()`; Item 2 `.cancelled` sofort, Item 1 `.cancelled` (nicht `.failed`), ein wartender `enqueueAndWait` auf Item 2 wirft; danach `isActive == false`; neues `enqueue` läuft wieder an (Worker-Neustart nach cancelAll).
  8. `clearCompletedRemovesOnlyDone` — finished+failed+cancelled fliegen, queued/running bleiben.
  9. `isActiveReflectsPendingWork` — false initial, true nach enqueue, false nach Abschluss.

- [ ] **Step 2: Rot** — Compile-Fehler.
- [ ] **Step 3: Implementieren** (wie oben skizziert; Code-Layout an `TransferViewModel` orientieren).
- [ ] **Step 4: Grün** — Filter-Suite (9), Gesamtsuite (Basis + 9).
- [ ] **Step 5: Commit** — `feat: add transfer queue view model with fifo worker` (mit Footer).

---

### Task 2: TransferQueueBar (UI)

**Files:**
- Create: `Sources/MacSCPApp/TransferQueueBar.swift`

**Interfaces:**
- Consumes: `TransferQueueViewModel` (API aus Task 1 — liegt nach dem Merge auf dem Basis-Commit vor).
- Produces: `struct TransferQueueBar: View { let viewModel: TransferQueueViewModel }` — T3 bettet sie statt `TransferBar` ein.

Kein Unit-Test (SwiftUI-Darstellung); Verifikation Build + visuell in T4.

- [ ] **Step 1: Implementieren**

```swift
import SwiftUI
import macSCPCore

/// Warteschlangen-Leiste unter den Panes: kompakte Item-Liste,
/// ↑ Bernstein (Upload), ↓ Ozeanblau (Download), Fehler in System-Rot.
struct TransferQueueBar: View {
    let viewModel: TransferQueueViewModel

    private func tint(for direction: TransferDirection) -> Color {
        direction == .upload ? DesignTokens.localAmber : DesignTokens.remoteBlue
    }

    var body: some View {
        if viewModel.items.isEmpty {
            EmptyView()
        } else {
            VStack(spacing: 0) {
                Divider()
                HStack {
                    Text(viewModel.isActive
                         ? "Übertragungen — \(viewModel.pendingCount) ausstehend"
                         : "Übertragungen")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Aufräumen") { viewModel.clearCompleted() }
                        .controlSize(.small)
                        .disabled(viewModel.items.allSatisfy {
                            $0.status == .queued || $0.status.isRunning
                        })
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)

                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(viewModel.items) { item in
                            row(item)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 6)
                }
                .frame(maxHeight: 110)
            }
        }
    }

    @ViewBuilder
    private func row(_ item: TransferQueueViewModel.Item) -> some View {
        HStack(spacing: 8) {
            Image(systemName: item.direction == .upload ? "arrow.up" : "arrow.down")
                .foregroundStyle(tint(for: item.direction))
                .fontWeight(.bold)
                .frame(width: 14)
            Text(item.fileName)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            switch item.status {
            case .queued:
                Text("wartet").font(.caption).foregroundStyle(.secondary)
            case .running(let progress):
                if let fraction = progress.fraction {
                    ProgressView(value: fraction)
                        .tint(tint(for: item.direction))
                        .frame(width: 120)
                } else {
                    ProgressView().controlSize(.small)
                }
            case .finished:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(tint(for: item.direction))
            case .failed(let message):
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(1)
                    .help(message)
            case .cancelled:
                Text("abgebrochen").font(.caption).foregroundStyle(.secondary)
            }
        }
        .font(.callout)
    }
}
```

Dazu im VM-Konsum nötig (Task 1 liefert): `Item.Status` braucht ein Helper-Property `isRunning: Bool` (in Core, `public var isRunning: Bool { if case .running = self { return true }; return false }`) — falls Task 1 es nicht ohnehin anlegt, hier als Extension in der Datei ergänzen.

- [ ] **Step 2: Grün** — `swift build && swift test` (Basis unverändert).
- [ ] **Step 3: Commit** — `feat: add transfer queue bar listing queued items` (mit Footer).

---

### Task 3: ContentView-Umbau — alles durch die Queue

**Files:**
- Modify: `Sources/MacSCPApp/ContentView.swift`
- Modify: `Sources/MacSCPApp/RemoteFilePromise.swift` (nur falls Signatur-Anpassung nötig)
- Delete: `Sources/MacSCPApp/TransferBar.swift`
- Delete: `Sources/macSCPCore/Presentation/TransferViewModel.swift`
- Delete: `Tests/macSCPCoreTests/TransferViewModelTests.swift`

**Interfaces:**
- Consumes: `TransferQueueViewModel` (T1), `TransferQueueBar` (T2).

- [ ] **Step 1: State umstellen** — `@State private var transferViewModel = TransferViewModel()` → `@State private var transferQueue = TransferQueueViewModel()`; in `startSession` neu instanziieren (`transferQueue = TransferQueueViewModel()`) wie bisher.

- [ ] **Step 2: Gates neu ziehen**
  - `sidebarDisabled`: `transferViewModel.isRunning` → `transferQueue.isActive` (Session-Wechsel während laufender Queue bleibt gesperrt — bewusste M5a-Entscheidung, Abbruch-Dialog kommt mit M5c/Reconnect).
  - Upload-/Download-Button: `.disabled(... || transferViewModel.isRunning)` → das isRunning-Kriterium ENTFERNEN (nur noch `selected == nil || kind != .file`) — Klicks reihen ein.
  - „Trennen"-Button: `.disabled(transferViewModel.isRunning)` → `.disabled(transferQueue.isActive)`.
  - `uploadDropped`: den `guard !transferViewModel.isRunning`-Drop-Guard ENTFERNEN (Kommentar dazu ebenfalls); die awaited-for-Schleife wird zu direkten `enqueue`-Aufrufen (kein Task nötig):

```swift
private func uploadDropped(_ urls: [URL], session: BrowserSession) {
    let files = urls.filter { /* wie bisher */ }
    for url in files {
        transferQueue.enqueue(
            fileName: url.lastPathComponent, direction: .upload,
            source: session.localFS, sourcePath: url.path(percentEncoded: false),
            destination: session.remoteFS,
            destinationDirectory: session.remote.currentPath,
            onCompleted: { await session.remote.refresh() }
        )
    }
}
```

  - Buttons analog: `Task { await transferViewModel.run(...) }` → `transferQueue.enqueue(...)` (synchron, kein Task).

- [ ] **Step 3: Promise-Pfad durch die Queue** — in `remotePromiseProvider`:

```swift
RemoteFilePromiseProvider(item: item) { item, url in
    try await transferQueue.enqueueAndWait(
        fileName: url.lastPathComponent, direction: .download,
        source: session.remoteFS, sourcePath: item.path,
        destination: session.localFS,
        destinationDirectory: url.deletingLastPathComponent()
            .path(percentEncoded: false)
    )
}
```

(Der Provider-Callback ist bereits `async throws` — Signatur in `RemoteFilePromise.swift` prüfen; falls der Callback bisher `@Sendable` ohne MainActor ist, den `enqueueAndWait`-Aufruf in `await MainActor.run { ... }` heben bzw. die Closure-Signatur minimal anpassen. Promise-Downloads erscheinen damit in der Leiste und serialisieren sich mit allen anderen Transfers — der alte Gate-Bypass ist tot.)

- [ ] **Step 4: Teardown** — in `teardownSession()` VOR `session.terminal.shutdown()`: `await transferQueue.cancelAll()`.

- [ ] **Step 5: TransferBar ersetzen** — `TransferBar(viewModel: transferViewModel)` → `TransferQueueBar(viewModel: transferQueue)`; Datei `TransferBar.swift` löschen; `TransferViewModel.swift` + dessen Testdatei löschen. `grep -rn "TransferViewModel\|TransferBar" Sources/ Tests/` muss leer sein (bis auf TransferQueue*).

- [ ] **Step 6: Grün + Headless-Launch** — `swift build && swift test` (Gesamtsuite = Basis − alte TransferVM-Tests); Headless-Launch-Check (Bundle-Wrapper-Muster).
- [ ] **Step 7: Commit** — `feat: route all transfers through the queue` (mit Footer).

---

### Task 4: Abschluss-Verifikation

- [ ] **Step 1:** `swift test` — Gesamtsuite grün (erwartet ≈ 148 + 9 − 4 alte TransferVM-Tests; exakte Zahl im Report).
- [ ] **Step 2:** Rig hoch (HAUPT-Checkout), `MACSCP_ITEST=1` 15/15, `MACSCP_KEYCHAIN=1` 2/2, Rig runter (bzw. für Step 3 anlassen).
- [ ] **Step 3: Visueller Smoke-Test** (Koordinator, Rig läuft): Verbinden; 3+ Dateien per Multi-Drop ins Remote-Pane → ALLE erscheinen in der Queue-Leiste (wartet/laufend), arbeiten FIFO ab, ↑ bernstein; WÄHREND ein Transfer läuft einen Download-Klick einreihen → wird queued, nicht verworfen; Remote-Datei in den Finder ziehen (Promise) WÄHREND die Queue arbeitet → erscheint als Item und landet byte-identisch (diff); Fehlerfall (nicht lesbare Datei o.ä.) blockiert die Queue nicht; „Aufräumen" leert Erledigte; ⌘T-Terminal kurz ein/aus während Queue läuft (Screen bleibt erhalten — Task-0-Fix); Trennen erst nach Queue-Ende möglich (Button disabled solange aktiv).
- [ ] **Step 4:** Checkboxen, Commit `docs: mark M5a plan tasks as completed` (mit Footer).

## Ausblick

M5b: Konfliktregeln (überschreiben/überspringen/umbenennen) + rekursive Verzeichnis-Transfers. M5c: Resume (SFTP-Offset), Rate/ETA, Reconnect-Überleben (Queue pausiert), Parallelität → Spec-Default 3 nach empirischer Ein-Channel-Validierung. M5d: Editor-Integration (Temp-Download, DispatchSource-Watcher, Auto-Upload, Session-Cleanup). Danach M6 Release.
