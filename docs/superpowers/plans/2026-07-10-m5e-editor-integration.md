# macSCP M5e — Editor-Integration + „Öffnen mit"-Einstellungen Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Doppelklick auf eine Remote-Datei lädt sie in ein Temp-Verzeichnis, öffnet sie in der richtigen App (Endungs-Regel → Standard-Editor → System-Zuordnung — konfigurierbar im neuen Settings-Tab „Öffnen mit"), und jedes Speichern lädt automatisch zurück auf den Server; beim Trennen wird aufgeräumt.

**Architektur:** `SettingsStore` wächst um `defaultEditorPath` + `fileAssociations` (Endung→App-Pfad, normalisiert). Neuer Settings-Tab „Öffnen mit" (App-Auswahl über Datei-Dialog auf `/Applications`, Regel-Tabelle mit Hinzufügen/Entfernen). Core: `EditSessionManager` (@Observable @MainActor) — Temp-Download über die QUEUE (`enqueueAndWait`), `DispatchSource`-Datei-Watcher mit Debounce, Auto-Upload über die Queue mit Konflikt-Bypass (Zurückschreiben IST gewollt), Lifecycle explizit (`stopAll` im Teardown, Temp-Ordner pro Session). App: `EditorResolver` (Regel → Default → `NSWorkspace`-System-Default) + `NSWorkspace.open(_:withApplicationAt:)`, Doppelklick-Wiring.

## Global Constraints

- swift-tools 6.0; ALLE Targets `.swiftLanguageMode(.v5)`; macOS 15; Swift Testing, TDD rot→grün.
- SPRACH-POLICY: Kommentare/Identifier Englisch; neue UI-Strings via `L10n` mit EN-Quelle + DE in BEIDEN `.strings`; `reason:` englisch.
- Alle Queue-Invarianten bleiben (sechste Generation!): exactly-once, cancelAll-Fenster, Gruppen, FIFO-Start, Slots, interrupted-Semantik.
- Edit-Uploads laufen als NORMALE Queue-Items (sichtbar in der Leiste, Drossel/Parallelität gelten), aber mit Konflikt-Bypass (bindend: eigenes internes `bypassConflictCheck`-Flag am Job; das bestehende resume-Bypass-Verhalten bleibt unverändert daran gekoppelt — `resume==true ⇒ bypass`, neu zusätzlich explizites Flag für Edit-Writebacks mit `resume:false`).
- Temp-Dateien: `FileManager.temporaryDirectory/macscp-edit/<sessionUUID>/<hash(remotePfad)>/<fileName>`; Cleanup löscht den Session-Ordner rekursiv (lokal, FileManager — NICHT das Remote-`delete`).
- KEINE Geheimnisse; Settings bleiben vorwärtskompatibel. Gated: `MACSCP_ITEST=1` (Rig aus Haupt-Checkout).
- Conventional Commits, Footer `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`. Implementierer pushen nicht.

**Abhängigkeitsgraph:** `[ T1 (Settings-Store) ∥ T3 (EditSessionManager, RISK) ] → [ T2 (Settings-Tab) ∥ T4 (Resolver+Wiring) ] → T5 (Abschluss)` — T1 (Settings/) ∥ T3 (Presentation/EditSessionManager + Queue-Flag) dateidisjunkt; T2 (SettingsView) ∥ T4 (ContentView/EditorResolver) ebenso.

---

### Task 1: SettingsStore — Default-Editor + Endungs-Regeln

**Files:**
- Modify: `Sources/macSCPCore/Settings/SettingsStore.swift`
- Test: `Tests/macSCPCoreTests/SettingsStoreTests.swift` (ergänzen)

**Interfaces (bindend für T2/T4):**

```swift
/// Absolute path to the .app bundle used as the default editor for remote
/// files; nil/empty = use the macOS system association. Persisted.
public var defaultEditorPath: String? { get set }

/// Per-extension overrides: normalized extension (lowercase, no leading dot,
/// trimmed) -> absolute .app path. Setting an empty app path removes the rule.
public var fileAssociations: [String: String] { get set }
/// Convenience: association lookup with the SAME normalization applied.
public func associatedApp(forExtension ext: String) -> String?
```

**Bindend:** Normalisierung beim Setzen UND Lesen (".PHP"/"php"/" .php " → "php"); leere/Whitespace-Endungen werden ignoriert; Persistenz-Roundtrip; Forward-Compat bleibt (unbekannte Schlüssel + die neuen als JSONValue-Objekt/String); Defaults nil/[:]. Tests: Roundtrip beider Felder, Normalisierung, Regel-Entfernen via leerem Pfad, Fixture-Kompatibilität (alte settings.json ohne neue Keys lädt sauber; neue Datei von alter Version lesbar-Simulation via Unknown-Key-Test besteht weiter).

- [ ] Rot → implementieren → grün → Commit `feat: add default editor and file association settings` (mit Footer).

---

### Task 2: Settings-Tab „Öffnen mit"

**Files:**
- Modify: `Sources/MacSCPApp/SettingsView.swift`, beide `Sources/MacSCPApp/Resources/{en,de}.lproj/Localizable.strings`

**Bindend:**
1. Zweiter Tab „Open with"/„Öffnen mit" (Symbol `doc.badge.gearshape` o. ä.), Fensterhöhe darf wachsen (~460×360).
2. Abschnitt Standard-Editor: Anzeige des gewählten App-Namens (aus Pfad, `FileManager.displayName`) oder „System default"/„System-Standard"; Buttons „Choose…"/„Auswählen…" (`.fileImporter`, `allowedContentTypes: [.application]`, Start `/Applications`) und „Reset"/„Zurücksetzen" (→ nil).
3. Abschnitt Regeln: Tabelle/Liste der `fileAssociations` (sortiert nach Endung): Endung | App-Name | Entfernen-Button (−). Darunter Hinzufügen-Zeile: TextField Endung (Placeholder „php") + „Choose app…"-Button → fileImporter → Regel wird mit normalisierter Endung gesetzt. Doppelte Endung überschreibt (Store-Semantik).
4. Neue L10n-Keys (EN-Quelle + DE) für Tab, Labels, Buttons, Placeholder, Fußnote („Rules take precedence over the default editor; the system association is the fallback." / „Regeln gehen vor Standard-Editor; System-Zuordnung ist der Fallback.").
5. Verifikation: Build + Suite unverändert; Headless-Launch; visuell in T5.

- [ ] Implementieren → grün → Commit `feat: add open-with settings tab` (mit Footer).

---

### Task 3: EditSessionManager (Core) — RISK

**Files:**
- Create: `Sources/macSCPCore/Presentation/EditSessionManager.swift`
- Modify: `Sources/macSCPCore/Presentation/TransferQueueViewModel.swift` (NUR: internes `bypassConflictCheck`-Flag am Job + öffentliche `enqueueEditUpload(...)`-Methode — Signatur unten)
- Test: `Tests/macSCPCoreTests/EditSessionManagerTests.swift`, Queue-Tests ergänzen

**Interfaces (bindend für T4):**

```swift
@Observable @MainActor
public final class EditSessionManager {
    public struct ActiveEdit: Identifiable, Equatable {
        public let id: UUID
        public let remotePath: String
        public let localURL: URL
        public let fileName: String
    }
    public private(set) var activeEdits: [ActiveEdit] { get }

    public init(sessionID: UUID, queue: TransferQueueViewModel)

    /// Downloads the remote file into the session temp dir via the queue
    /// (enqueueAndWait), registers a debounced file watcher, and returns the
    /// local URL for the caller to open. Re-invoking for an already-active
    /// remotePath returns the existing local URL (no second download/watcher).
    public func beginEditing(
        remotePath: String, fileName: String,
        source: any RemoteFileSystem, destinationForUploads: any RemoteFileSystem
    ) async throws -> URL

    /// Stops all watchers and deletes the session temp directory. Idempotent.
    public func stopAll() async
}

// TransferQueueViewModel gains:
/// Enqueues an editor write-back: uploads localURL back to remoteDirectory/
/// fileName, BYPASSING the conflict check by design (writing back is the
/// user's explicit intent). Behaves like a normal item otherwise (bar, limits,
/// slots, interrupted classification).
public func enqueueEditUpload(
    fileName: String, localURL: URL,
    source: any RemoteFileSystem, destination: any RemoteFileSystem,
    remoteDirectory: String
) -> UUID
```

**Bindend:**
1. Temp-Layout wie in den Global Constraints; Ordner wird bei `beginEditing` angelegt.
2. Download über `queue.enqueueAndWait` (erscheint in der Leiste als Download).
3. Watcher: `DispatchSource.makeFileSystemObjectSource(fileDescriptor:eventMask:[.write,.rename,.delete])` auf der Datei; Editoren machen atomare Saves (rename-swap!) — bindend: nach `.rename`/`.delete` den FD NEU öffnen (Datei am selben Pfad) und weiterbeobachten; Debounce 500 ms (mehrere Events in Folge → EIN Upload); jede erkannte Änderung → `enqueueEditUpload`.
4. Watcher-Callbacks hüpfen auf den MainActor; keine Retain-Zyklen (Quelle gehalten vom Manager, cancel im stopAll/deinit-frei — UI-owned wie immer, KEIN deinit-Cleanup: stopAll ist Pflicht des Aufrufers).
5. `stopAll`: alle Sources canceln, FDs schließen, Session-Temp-Ordner rekursiv löschen; idempotent; laufende Edit-Uploads in der Queue bleiben unberührt (sie lesen die Datei ggf. noch — Reihenfolge: erst Watcher stoppen, dann löschen; ein gerade laufender Upload einer gelöschten Datei endet als normaler .failed — akzeptiert, dokumentieren).
6. Queue-Flag: `bypassConflictCheck` im Job (internal); `resolveConflictIfNeeded` prüft `job.resume || job.bypassConflictCheck`; alle bestehenden Pfade unverändert (Flag default false überall sonst).
7. Tests (Mock-FS, TestSignals, injizierbare Zeit fürs Debounce falls nötig — Debounce via injizierbarem Scheduler/Task.sleep-Hook testbar machen): beginEditing lädt via Queue und liefert URL (Datei existiert lokal, Inhalt == Mock-Remote); Doppel-beginEditing derselben Datei → gleiche URL, kein zweiter Download (Queue-Item-Count!); simulierte Datei-Änderung (lokal schreiben + Watcher-Event bzw. direkter Handler-Aufruf, wenn DispatchSource im Test zu flaky ist → dann den Event-Handler-Pfad als testbare interne Methode schneiden und die DispatchSource-Schicht dünn halten) → genau EIN enqueueEditUpload nach Debounce (zwei schnelle Änderungen → EIN Upload); enqueueEditUpload umgeht Konfliktprüfung (Ziel existiert, KEIN Decider-Call, Item finished); stopAll löscht Temp-Ordner + weitere Änderung löst NICHTS mehr aus; atomarer Save simuliert (rename weg + neue Datei am Pfad) → Watcher überlebt und feuert.

- [ ] Rot → implementieren → grün (Filter + Gesamt) → Commit `feat: add edit session manager with auto-upload` (mit Footer).

---

### Task 4: EditorResolver + Doppelklick-Wiring (App)

**Files:**
- Create: `Sources/MacSCPApp/EditorResolver.swift`
- Modify: `Sources/MacSCPApp/ContentView.swift`, `Sources/MacSCPApp/RemoteFileTableView.swift` (nur falls Doppelklick-auf-Datei-Callback fehlt — prüfen: Verzeichnis-Doppelklick existiert), beide `.strings` (Fehlertext, s. u.)

**Bindend:**
1. `EditorResolver.applicationURL(forFileName:settings:) -> URL?`: (1) `settings.associatedApp(forExtension:)` der Datei-Endung → URL wenn Pfad existiert; (2) `defaultEditorPath` → URL wenn existiert; (3) `NSWorkspace.shared.urlForApplication(toOpen: localURL)`-Fallback… Reihenfolge-Detail: Systemzuordnung braucht die LOKALE URL — Auflösung daher zweistufig: Regel/Default vorab per Dateiname; System-Fallback erst nach dem Download mit der lokalen URL; liefert alles nichts → `NSWorkspace.shared.open(localURL)` (öffnet mit irgendwas) als letzte Stufe. Nicht-existenter konfigurierter App-Pfad → nächste Stufe + einmaliger Log.
2. `BrowserSession` erhält `editManager: EditSessionManager` (Init in `startSession` mit Session-UUID + `transferQueue`); `teardownSession` ruft `await editManager.stopAll()` NACH `cancelAll` und VOR `terminal.shutdown` (Reihenfolge dokumentieren).
3. Doppelklick auf Remote-DATEI (kind == .file): `Task { let url = try await editManager.beginEditing(...); dann App-Auflösung + NSWorkspace.open([url], withApplicationAt: appURL, configuration:) bzw. Fallback-open }`; Fehler → dezente rote Meldung wie bestehende Muster (neuer L10n-Key `edit.openFailed` EN "Could not open file for editing: %@" / DE „Datei konnte nicht zum Bearbeiten geöffnet werden: %@").
4. Symlinks/Verzeichnisse: unverändertes Verhalten (dir = cd; symlink = nichts).
5. Build + Suite grün; Headless-Launch.

- [ ] Implementieren → grün → Commit `feat: open remote files in the configured editor` (mit Footer).

---

### Task 5: Abschluss-Verifikation

- [ ] `swift test` gesamt; Rig hoch, `MACSCP_ITEST=1` voll, `MACSCP_KEYCHAIN=1` 2/2.
- [ ] **Visueller Edit-Roundtrip (Bildschirm frei):** In Settings „Öffnen mit": Regel `txt` → TextEdit anlegen; remote eine `.txt` erzeugen (docker exec), doppelklicken → Download-Item in Leiste → TextEdit öffnet die Datei; Text ändern + ⌘S → Upload-Item erscheint automatisch in der Leiste → `docker exec cat` zeigt die Änderung; ZWEITES Speichern → wieder genau ein Upload. Standard-Editor-Fall (Regel entfernen, Default z. B. TextEdit setzen, `.conf`-Datei doppelklicken → öffnet in TextEdit). System-Fallback-Fall (Default zurücksetzen, `.txt` → öffnet im System-Editor). Trennen → Temp-Ordner ist weg (`ls /tmp/...macscp-edit/`), TextEdit-Dokument bleibt offen (dokumentiert ok), erneutes Speichern löst nichts mehr aus.
- [ ] Checkboxen, Commit `docs: mark M5e plan tasks as completed` (mit Footer).

## Ausblick

Danach M6 — Release: App-Icon (Variante A), lproj-Marker + SPM-Bundles im .app, notarisierte DMG, README/Docs (EN, ohne Stack-Begriffe), Polish-Backlog (globaler Drossel-Bucket, applyToAll-Recheck, Sheet-Default-Action, core.transfer.interrupted verdrahten/löschen, delete-Konsument Teil-Datei-Cleanup, Auto-Reconnect-Backoff-Evaluierung).
