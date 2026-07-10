# macSCP M5c — Einstellungen + Transfer-Steuerung Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Zentrales Einstellungsfenster (⌘,) mit wirkenden Schaltern — maximale gleichzeitige Übertragungen (1–8, Default 3) und Bandbreiten-Limits Up/Down — plus kooperative Transfer-Cancellation („Alle abbrechen" wird real), Rate/ETA in der Leiste, und das kompakte Verbindungsfenster.

**Architektur:** `SettingsStore` (Core, JSON im Application-Support-Verzeichnis nach `SessionStore`-Muster, vorwärtskompatibel: unbekannte Schlüssel überleben Laden/Speichern). SwiftUI-`Settings`-Scene mit Tab „Übertragungen". Kooperative Cancellation via `Task.checkCancellation()` im Chunk-Loop der `TransferEngine` (deckt beide FS-Richtungen — der Loop ist der gemeinsame Engpass). Queue bekommt N parallele Worker-Slots (Setting-gesteuert; vorab gated empirisch validiert, dass mehrere Transfers über EINEN SFTP-Channel sauber laufen). Drossel als Token-Zeit-Rechnung im selben Chunk-Loop. `TransferProgress` wächst um Rate/ETA (gleitendes Fenster im Queue-Consumer, nicht in der Engine).

**Tech Stack:** Bestehende Engine/Queue; SwiftUI `Settings`-Scene; keine neuen Dependencies.

## Global Constraints

- swift-tools 6.0; ALLE Targets `.swiftLanguageMode(.v5)`; macOS 15; Swift Testing, TDD rot→grün.
- Gated Tests: `MACSCP_ITEST=1` (Rig NUR aus Haupt-Checkout), `MACSCP_KEYCHAIN=1`.
- Queue-Invarianten (M5a/M5b) bleiben: exactly-once-Waiter, cancelAll-Semantik inkl. resolvingJobID-Fenster, Gruppen-Buchhaltung exactly-once, Konfliktregel-Reset bei Drain. FIFO-*Start*-Reihenfolge bleibt bei N Workern erhalten (Slots ziehen der Reihe nach aus `order`); Abschluss-Reihenfolge darf abweichen.
- Settings-Defaults: `maxConcurrentTransfers = 3` (1–8), `uploadLimitKBs = 0`, `downloadLimitKBs = 0` (0 = unbegrenzt). Ohne Settings-Datei gelten die Defaults; die App verhält sich mit Defaults (bis auf Parallelität 3 statt 1) wie M5b.
- KEINE Geheimnisse im SettingsStore. Deutsche UI-Texte; Duo-Farben-Semantik; Conventional Commits mit Footer `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`. Implementierer pushen nicht.

**Abhängigkeitsgraph:** `[ T0 (Fenster+Tests) ∥ T1 (SettingsStore) ∥ T2 (Cancellation, RISK) ] → [ T3 (Settings-UI) ∥ T4 (N-Worker, RISK) ] → T5 (Drossel + Rate/ETA) → T6 (Abschluss)` — T0/T1/T2 dateidisjunkt (Worktrees); T3 (App-Settings-Dateien) ∥ T4 (Core-Queue) ebenfalls disjunkt.

---

### Task 0: Opening — kompaktes Verbindungsfenster + fehlende Baum-Tests

**Files:**
- Modify: `Sources/MacSCPApp/MacSCPApp.swift`, `Sources/MacSCPApp/ContentView.swift`
- Test: `Tests/macSCPCoreTests/TransferQueueViewModelTests.swift` (ergänzen)

**Teil A — Fenster (User-Feedback 2026-07-10):** Das Formular-Fenster ist zu groß, der Inhalt sitzt zu tief. Bindend:
1. Formular-Zustand (`session == nil`): kompaktes Fenster — Inhalt-Mindestgröße ca. 700×440, Formular OBEN ausgerichtet (VStack mit Spacer unten bzw. `.frame(maxHeight: .infinity, alignment: .top)` im Detail-Zweig), nicht vertikal zentriert.
2. Browser-Zustand: Mindestgröße 930×460 wie bisher.
3. Beim Zustandswechsel passt sich das Fenster AKTIV an (animiert): Verbinden → auf mindestens 930×620 wachsen (bzw. letzte Browser-Größe, wenn gemerkt — einfache `@State`-Merkgröße reicht); Trennen → auf ~700×460 schrumpfen.
4. Umsetzung: globales `.frame(minWidth: 930, ...)` in `MacSCPApp.swift` ENTFERNEN; konditionales `.frame(minWidth: session == nil ? 700 : 930, minHeight: 460)` in ContentView; NSWindow-Zugriff über einen kleinen `WindowAccessor` (`NSViewRepresentable`, reicht `weak var window` per Callback hoch) + `window.setFrame(_:display:animate:)`-Aufrufe in `startSession`/`teardownSession` (Fensterbreite/-höhe setzen, Position beibehalten: Top-Left fixieren).
5. Verifikation Teil A: Headless-Launch + visueller Check in T6 (kein Unit-Test für AppKit-Fenster).

**Teil B — Baum-Tests (Final-Review M5b, Backlog e):** zwei Tests im bestehenden Stil (Signal-Mocks):
- `twoConcurrentTreesKeepIndependentGroups` — zwei `enqueueTree` nacheinander (unterschiedliche Ordner), beide onCompleted feuern je genau 1×, Item-Zuordnung sauber.
- `emptyTreeFiresOnCompleted` — Ordner ohne Dateien (nur leere Unterordner): onCompleted feuert genau 1×, `createdDirectories` enthält beide Ebenen.

- [ ] Step 1: Teil-B-Tests rot (falls sie wider Erwarten grün sind: dokumentieren — sie pinnen dann nur; kein Implementierungsbedarf laut Review-Trace).
- [ ] Step 2: Teil A implementieren; `swift build && swift test` grün (185 + 2 = 187), Headless-Launch ok.
- [ ] Step 3: Commit `fix: compact connection window and pin tree accounting tests` (mit Footer).

---

### Task 1: SettingsStore (Core)

**Files:**
- Create: `Sources/macSCPCore/Settings/SettingsStore.swift`
- Test: `Tests/macSCPCoreTests/SettingsStoreTests.swift`

**Interfaces (bindend für T3/T4/T5):**

```swift
/// Zentrale App-Einstellungen. JSON in <directory>/settings.json —
/// VORWÄRTSKOMPATIBEL: unbekannte Schlüssel bleiben beim Speichern erhalten
/// (Roundtrip über ein rohes [String: JSONValue]-Backing, typisierte Accessoren
/// obendrauf). Kein Geheimnis-Speicher.
@Observable @MainActor
public final class SettingsStore {
    public static let defaultDirectory: URL   // == SessionStore.defaultDirectory
    public init(directory: URL)               // lädt sofort; fehlende Datei => Defaults

    /// Maximale gleichzeitige Übertragungen (geklemmt auf 1...8, Default 3).
    public var maxConcurrentTransfers: Int { get set }   // Setter speichert
    /// Bandbreiten-Limits in KB/s; 0 = unbegrenzt (Default 0). Geklemmt >= 0.
    public var uploadLimitKBs: Int { get set }
    public var downloadLimitKBs: Int { get set }
}
```

**Bindende Tests:** Defaults ohne Datei; Persistenz-Roundtrip; Klemmen (0→1, 99→8, negatives Limit→0); UNBEKANNTE Schlüssel im JSON überleben Laden+Ändern+Speichern (Fixture mit Fremdschlüssel auf Platte schreiben, danach prüfen); korruptes JSON → Defaults + kein Crash (Datei wird beim nächsten Speichern ersetzt); Verzeichnis wird bei Bedarf angelegt.

- [ ] Rot → implementieren → grün (Filter + Gesamt) → Commit `feat: add forward-compatible settings store` (mit Footer).

---

### Task 2: Kooperative Cancellation (Engine/FS) — RISK

**Files:**
- Modify: `Sources/macSCPCore/RemoteFS/TransferEngine.swift`
- Modify: `Sources/macSCPCore/SSH/CitadelFileSystem.swift` (nur falls Stream-Unfolds eigene Checks brauchen)
- Test: `Tests/macSCPCoreTests/TransferEngineTests.swift`, gated `Tests/macSCPCoreTests/CitadelFileSystemIntegrationTests.swift` (ergänzen)

**Hintergrund (M5c-VORBEDINGUNG aus M5a-Final-Review):** `cancelAll` cancelt die laufende Transfer-Task, aber `copyFile` prüft Cancellation nie → der Transfer läuft bis zum natürlichen Ende (`.finished` statt `.cancelled`). Grep-verifiziert: kein `Task.isCancelled`/`checkCancellation` im Engine-Pfad.

**Bindend:**
1. `TransferEngine.copyFile`: `try Task.checkCancellation()` VOR jedem Chunk-Write (im Konsum-Loop des Quell-Streams). Wirkung: Abbruch greift chunk-genau (64 KiB), wirft `CancellationError`, Queue mappt wie gehabt auf `.cancelled`.
2. Aufräum-Semantik dokumentieren (bestehende Review-Notiz M2c): Partial-Writes werden NICHT zurückgerollt — Doc-Kommentar an `copyFile` ergänzen („Abbruch hinterlässt ggf. Teil-Datei am Ziel; Aufräumen ist Sache des Aufrufers/M5d-Resume").
3. Unit-Test (Mock): Transfer mit Signal-gebremstem Quell-Stream; Task canceln; assert `CancellationError` fliegt, Ziel-Mock hat < alle Chunks, KEIN weiterer Chunk nach dem Cancel-Punkt.
4. Unit-Test (Queue-Ebene, `TransferQueueViewModelTests`): laufender Transfer mit gebremstem Stream; `cancelAll()`; Item endet `.cancelled` (nicht `.finished`), cancelAll kehrt ZÜGIG zurück (Timeout-Race < 2 s statt Natural-End).
5. Gated Test: großer Upload (≥ 64 MiB Random) gegen das Rig; Task nach erstem Progress-Event canceln; assert Fehler ist CancellationError und die Remote-Teildatei ist ECHT kleiner als die Quelle (docker exec stat); Verbindung/SFTP danach weiter nutzbar (list ok).
6. M5a/M5b-Invarianten unangetastet; `.serialized` wo nötig gegen Rig-Flakiness.

- [ ] Rot (Tests 3+4 gegen aktuellen Stand: 3 hängt/liefert alle Chunks, 4 endet .finished) → implementieren → grün → Commit `feat: make transfers cooperatively cancellable` (mit Footer).

---

### Task 3: Einstellungs-Fenster (App)

**Files:**
- Create: `Sources/MacSCPApp/SettingsView.swift`
- Modify: `Sources/MacSCPApp/MacSCPApp.swift` (Settings-Scene), `Sources/MacSCPApp/ContentView.swift` (SettingsStore-Instanz durchreichen)

**Interfaces:** Consumes `SettingsStore` (T1).

**Bindend:**
1. `MacSCPApp`: EIN `SettingsStore` als `@State` im App-Struct; `Settings { SettingsView(store: settingsStore) }`-Scene (macOS öffnet sie via ⌘, / Menü „Einstellungen…"); dieselbe Instanz an `ContentView` (Parameter, kein Singleton — v2-Fenster-Regel).
2. `SettingsView`: `TabView` mit EINEM Tab „Übertragungen" (Symbol `arrow.up.arrow.down`), `Form`-Layout, Fenster ~460×260 fix:
   - „Maximale gleichzeitige Übertragungen": `Stepper`(1–8) mit Wertanzeige + Fußnote „Gilt für neue Übertragungen; laufende sind nicht betroffen."
   - „Bandbreiten-Limit Upload/Download": je ein Zahlenfeld (KB/s) mit „0 = unbegrenzt"-Placeholder/Fußnote; Eingaben < 0 werden geklemmt (Store macht das).
3. Die Tab-Struktur ist bewusst erweiterbar (Kommentar: künftige Tabs Terminal/Allgemein).
4. Verifikation: Build + Suite unverändert grün; Headless-Launch; visuell in T6.

- [ ] Implementieren → grün → Commit `feat: add settings window with transfer tab` (mit Footer).

---

### Task 4: Queue-Parallelität N (Core) — RISK

**Files:**
- Modify: `Sources/macSCPCore/Presentation/TransferQueueViewModel.swift`
- Test: `Tests/macSCPCoreTests/TransferQueueViewModelTests.swift`, gated `Tests/macSCPCoreTests/CitadelShellIntegrationTests.swift` ODER neue gated Datei (Validierung)

**Bindend:**
1. **Validierung ZUERST (gated, eigener Commit-Schritt):** Test der über EINEN `CitadelFileSystem` DREI Uploads (~8 MiB) ECHT GLEICHZEITIG fährt (`async let`/TaskGroup direkt auf `TransferEngine.copyFile`) und byte-identische Ankunft prüft (docker exec md5sum). Schlägt das strukturell fehl (Citadel-SFTP-Channel verkraftet keine Parallelität) → STOPP, BLOCKED melden — dann bleibt Parallelität 1 und T3/T5 laufen ohne diesen Schalter (Koordinator entscheidet).
2. `TransferQueueViewModel`: `public var maxConcurrent: Int = 3` (geklemmt 1–8; ContentView setzt ihn aus dem SettingsStore bei `startSession` UND bei Änderung via `.onChange` — Änderung wirkt auf KÜNFTIGE Slot-Vergaben, laufende bleiben). Worker-Loop → Slot-Modell: bis zu `maxConcurrent` gleichzeitige `process`-Tasks; Start-Reihenfolge strikt FIFO aus `order`; `runningTransferTask` wird zu `runningTransferTasks: [UUID: Task]`; `resolvingJobID` zu `resolvingJobIDs: Set<UUID>` — cancelAll-Semantik (queued-Sweep, In-Flight-Resolver-Sweep, laufende canceln [jetzt kooperativ dank T2], Expansion zuerst) bleibt exactly-once. Konflikt-Prompts serialisieren sich weiterhin von selbst (MainActor + EIN Bridge-Prompt: zweiter Konflikt wartet, bis der erste resolved ist — die Bridge muss dafür eine faire Warteschlange bekommen ODER der Slot awaited die Bridge exklusiv; einfachste bindende Lösung: ein `AsyncSemaphore`/gate im VM um den Decider-Aufruf, FIFO).
3. Unit-Tests: `startsAtMostMaxConcurrent` (3 gebremste Transfers + maxConcurrent 2 → nie >2 gleichzeitig im Mock aktiv, Zähler im Mock); `fifoStartOrderPreserved` (Start-Reihenfolge == Einreihung trotz Parallelität); `cancelAllWithParallelRunners` (2 laufende + 1 queued: alle enden .cancelled, exactly-once, zügige Rückkehr); `conflictPromptsSerializeAcrossSlots` (2 parallele Konflikte → Decider-Aufrufe nacheinander, nie verschachtelt); bestehende 27 Suite-Tests bleiben grün (Parallelität-Default in Tests explizit auf 1 setzen wo Determinismus nötig — NICHT die Assertions aufweichen).
4. Gated: 5 Dateien Multi-Drop-äquivalent via enqueue, maxConcurrent 3, alle md5-identisch.

- [ ] Validierung → rot → implementieren → grün (alle Ebenen) → Commit `feat: run transfers on configurable parallel slots` (mit Footer).

---

### Task 5: Bandbreiten-Drossel + Rate/ETA

**Files:**
- Modify: `Sources/macSCPCore/RemoteFS/TransferEngine.swift` (Drossel), `Sources/macSCPCore/RemoteFS/RemoteFileSystem.swift` (TransferProgress-Erweiterung — Datei prüfen, wo TransferProgress lebt), `Sources/macSCPCore/Presentation/TransferQueueViewModel.swift` (Rate-Fenster), `Sources/MacSCPApp/TransferQueueBar.swift` (Anzeige), `Sources/MacSCPApp/ContentView.swift` (Limits aus Settings an enqueue-Pfade)
- Tests: Engine- + Queue- + ggf. Formatter-Tests

**Bindend:**
1. `TransferEngine.copyFile` bekommt `bytesPerSecondLimit: Int = 0` (0 = aus): Token-Zeit-Drossel im Chunk-Loop (nach jedem Chunk: Soll-Zeit = übertragene Bytes / Limit; liegt Ist < Soll → `Task.sleep` um die Differenz; einfacher gleitender Ansatz, kein Burst-Bucket nötig). Cancellation-Check (T2) bleibt VOR dem Sleep wirksam (sleep wirft bei Cancel — dokumentieren).
2. Queue reicht das Limit richtungsabhängig durch: `.upload` → uploadLimitKBs, `.download` → downloadLimitKBs (Werte kommen als neue enqueue-Parameter mit Default 0 ODER als VM-Properties, die ContentView aus dem SettingsStore setzt — Entscheidung: VM-Properties `uploadLimitBytesPerSec`/`downloadLimitBytesPerSec`, von ContentView via onChange gesetzt; gilt ab dem NÄCHSTEN startenden Item).
3. Rate/ETA: `TransferProgress` erhält `bytesPerSecond: Double?` und `etaSeconds: Double?` (nil solange unbekannt). Berechnung NICHT in der Engine, sondern im Progress-Consumer der Queue: gleitendes 3-Sekunden-Fenster über (Zeitstempel, Bytes)-Paaren; ETA nur bei bekanntem totalBytes. Leiste zeigt hinter dem Balken kompakt `"1,2 MB/s · 0:42"` (Formatter-Helfer, tabellarische Ziffern, deutsche Formate via `MeasurementFormatter`/eigenem Helfer — Tests für den Formatter).
4. Engine-Test: Limit 256 KB/s, 1 MiB Mock-Transfer → Dauer ≥ ~3,5 s (Toleranzfenster, kein Flaky-Exakt-Timing; alternativ virtuelle Zeit via injizierbarem sleep — bevorzugt: `sleep`-Closure injizierbar, Test zählt Soll-Schlafzeit statt echt zu schlafen). Queue-Test: Rate-Feld gefüllt und monoton sinnvoll bei konstantem Mock-Takt; ETA nil ohne totalBytes.

- [ ] Rot → implementieren → grün → Commit `feat: add bandwidth limits and transfer rate display` (mit Footer).

---

### Task 6: Abschluss-Verifikation

- [ ] `swift test` gesamt grün (Zählung im Report); Rig hoch, `MACSCP_ITEST=1` (19 + neue gated), `MACSCP_KEYCHAIN=1` 2/2.
- [ ] Visueller Smoke-Test (nur bei freiem Bildschirm): kompaktes Formular-Fenster beim Start + Wachsen/Schrumpfen bei Verbinden/Trennen; ⌘, öffnet Einstellungen, Stepper/Felder wirken; Parallelität 3: Multi-Drop → bis zu 3 Balken GLEICHZEITIG, Start-Reihenfolge FIFO; Limit 200 KB/s Upload setzen → sichtbar gedrosselte Rate in der Leiste (`~0,2 MB/s`), zurück auf 0 → volle Rate; „Alle abbrechen"-Verhalten via Trennen-Disabled-Gate bleibt (kein neuer Button in M5c — bewusst); Promise-Drag-durch-Queue NACHHOLEN (Fenster vorher klein ziehen, Drop auf freien Desktop-Bereich); byte-identisch.
- [ ] Checkboxen, Commit `docs: mark M5c plan tasks as completed` (mit Footer).

## Ausblick

M5d: Resume (SFTP-Offset) + Reconnect-Überleben (Queue pausiert) + Teil-Datei-Aufräumen. M5e: Editor-Integration. M6: Release (Icon, Polish inkl. Sheet-Default-Action-Review, notarisierte DMG). Backlog-Reste: .other-Suffix, Baum-Abbrechen-Semantik (M6-Design-Note).
