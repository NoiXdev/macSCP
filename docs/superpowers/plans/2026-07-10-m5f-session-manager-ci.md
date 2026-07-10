# M5f — Session-Manager & CI-Angleich Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Flache Session-Gruppen + Kontextmenü (Umbenennen/Bearbeiten/Verschieben/Löschen) in der Sidebar, Bearbeiten-Modus im Verbindungsformular, und Angleich von Sidebar/Formular/Toolbar/Akzentfarben an die CI-Entwürfe.

**Architecture:** Gruppen als eigene `StoredGroup`-Objekte im `SessionStore` (Container-Format mit Altformat-Fallback, keine Migration); alle Operationen im `SessionListViewModel`; die Sidebar ruft das ViewModel direkt, nur Verbinden/Bearbeiten laufen als Callbacks über `ContentView`. Der Edit-Modus ist ein Formular-Modus im `ConnectionViewModel` (Secrets werden nie geladen; leeres Passwortfeld = Keychain-Eintrag bleibt). CI-Angleich als gezielte View-Anpassungen mit bestehenden `DesignTokens`.

**Tech Stack:** Swift 6 Toolchain / `.swiftLanguageMode(.v5)`, SwiftUI (macOS 15+), Swift Testing (`@Test`/`#expect`), bestehende Suiten in `Tests/macSCPCoreTests/`.

## Global Constraints

- Spec: `docs/superpowers/specs/2026-07-10-m5f-session-manager-ci-design.md` — bindend.
- Code + Kommentare NUR Englisch; UI-Strings über `L10n`/`CoreL10n` mit Keys in BEIDEN Katalogen `Sources/MacSCPApp/Resources/{en,de}.lproj/Localizable.strings` (EN Default, DE Übersetzung). Niemals Display-Strings hardcoden.
- Secrets ausschließlich Keychain (`SecretStore`), adressiert über Session-ID; `sessions.json` enthält NIE Geheimnisse; gespeicherte Secrets werden NIE ins Formular geladen.
- TOFU-Invarianten unangetastet (Mismatch = Hard-Stop, Unknown = expliziter Consent) — dieser Milestone berührt die Maschinerie nicht.
- CI-Regeln (`docs/design/ci.md`): Bernstein `LocalAmber` nur lokal/Upload, Ozeanblau `RemoteBlue` nur remote/Download/Primäraktion, Phosphor nur Verbunden-Status, Fehler System-Rot; Duo-Farben nie dekorativ mischen.
- Gruppe löschen = auflösen: Sessions werden entgruppiert, NIE mitgelöscht.
- Vorwärts-/Rückwärtskompatibilität: bestehende `sessions.json` (nacktes Array) lädt ohne Migration; verwaiste `groupID`s werden beim Laden wie `nil` behandelt.
- TDD rot→grün; jede neue Logik mit Tests; `swift test` muss nach jedem Task grün sein (280+ Tests).
- Conventional Commits (Englisch), Footer: `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- Umgebungs-Hinweis für alle Agenten: Bash-Fehler „claude-opus-4-8 is temporarily unavailable … cannot determine the safety" sind KEINE Permission-Denials — kurz warten und identisch erneut ausführen.

## Schedule

T1 → T2 → T3 → T4 → T5 → T6, strikt sequenziell (T3–T5 teilen sich `ContentView.swift`/`ConnectionFormView.swift`; Worktree-Parallelität lohnt hier nicht).

---

### Task 1: StoredGroup + Store-Containerformat (Core)

**Files:**
- Create: `Sources/macSCPCore/Sessions/StoredGroup.swift`
- Modify: `Sources/macSCPCore/Sessions/StoredSession.swift` (Feld + Init-Parameter)
- Modify: `Sources/macSCPCore/Sessions/SessionStore.swift` (Containerformat, Gruppen-API)
- Test: `Tests/macSCPCoreTests/SessionStoreTests.swift` (erweitern)

**Interfaces:**
- Consumes: bestehendes `StoredSession`, `SessionStore` (nacktes `[StoredSession]`-JSON).
- Produces (spätere Tasks verlassen sich exakt hierauf):
  - `public struct StoredGroup: Codable, Equatable, Identifiable, Sendable { public let id: UUID; public var name: String; public init(id: UUID = UUID(), name: String) }`
  - `StoredSession.groupID: UUID?` (var, Init-Parameter `groupID: UUID? = nil` am Ende)
  - `SessionStore.allGroups() throws -> [StoredGroup]`
  - `SessionStore.upsertGroup(_ group: StoredGroup) throws`
  - `SessionStore.dissolveGroup(id: UUID) throws` (entfernt Gruppe UND entgruppiert deren Sessions in EINEM Write)
  - `SessionStore.all()` / `upsert(_:)` / `delete(id:)` unverändert in Signatur; `all()` liefert Sessions mit bereinigten (verwaisten) `groupID`s.

- [ ] **Step 1: Failing Tests schreiben** — in `SessionStoreTests.swift` ergänzen (bestehende Suite-Struktur/Temp-Dir-Muster der Datei übernehmen):

```swift
@Test func groupsRoundtripThroughTheStore() throws {
    let store = SessionStore(directory: tempDir)
    let group = StoredGroup(name: "Customers")
    try store.upsertGroup(group)
    let session = StoredSession(name: "web", host: "h", username: "u", groupID: group.id)
    try store.upsert(session)

    #expect(try store.allGroups() == [group])
    #expect(try store.all().first?.groupID == group.id)
}

@Test func legacyPlainArrayFileLoadsWithoutGroups() throws {
    let legacy = """
    [{"authKind":"password","host":"legacy.example","id":"11111111-1111-1111-1111-111111111111",\
    "name":"old","port":22,"username":"tim"}]
    """
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    try legacy.data(using: .utf8)!.write(to: tempDir.appendingPathComponent("sessions.json"))
    let store = SessionStore(directory: tempDir)

    #expect(try store.allGroups().isEmpty)
    let sessions = try store.all()
    #expect(sessions.count == 1)
    #expect(sessions.first?.name == "old")
    #expect(sessions.first?.groupID == nil)
}

@Test func dissolveGroupUngroupsItsSessionsInOneWrite() throws {
    let store = SessionStore(directory: tempDir)
    let group = StoredGroup(name: "Temp")
    try store.upsertGroup(group)
    try store.upsert(StoredSession(name: "a", host: "h", username: "u", groupID: group.id))
    try store.dissolveGroup(id: group.id)

    #expect(try store.allGroups().isEmpty)
    #expect(try store.all().first?.groupID == nil)
}

@Test func orphanedGroupIDIsTreatedAsNilOnLoad() throws {
    let store = SessionStore(directory: tempDir)
    try store.upsert(StoredSession(name: "a", host: "h", username: "u", groupID: UUID()))
    #expect(try store.all().first?.groupID == nil)
}

@Test func groupRenamePersistsViaUpsertGroup() throws {
    let store = SessionStore(directory: tempDir)
    var group = StoredGroup(name: "Old")
    try store.upsertGroup(group)
    group.name = "New"
    try store.upsertGroup(group)
    #expect(try store.allGroups() == [group])
    #expect(try store.allGroups().count == 1)
}
```

- [ ] **Step 2: Rot laufen lassen** — `swift test --filter SessionStore` → FAIL („cannot find 'StoredGroup'", „extra argument 'groupID'").

- [ ] **Step 3: Implementieren**

`StoredGroup.swift` (neu):

```swift
import Foundation

/// A flat session group shown as a collapsible sidebar section.
/// Deleting a group DISSOLVES it: member sessions become ungrouped,
/// they are never deleted with the group.
public struct StoredGroup: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var name: String

    public init(id: UUID = UUID(), name: String) {
        self.id = id
        self.name = name
    }
}
```

`StoredSession.swift`: `public var groupID: UUID?` nach `keyPath` einfügen; Init bekommt `groupID: UUID? = nil` als letzten Parameter und weist zu. (Optional → Alt-JSON ohne Feld decodiert zu `nil`; kein Custom-Decoder nötig.)

`SessionStore.swift`: privates Containerformat + Fallback; bestehende öffentliche Methoden auf `load()`/`persist(_:)` umstellen:

```swift
/// On-disk container (current format). Legacy files are a bare
/// `[StoredSession]` array — `load()` falls back to that shape, so old
/// installations keep working without a migration step.
private struct StoreFile: Codable {
    var groups: [StoredGroup] = []
    var sessions: [StoredSession] = []
}

private func load() throws -> StoreFile {
    guard FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false)) else {
        return StoreFile()
    }
    let data = try Data(contentsOf: fileURL)
    var file: StoreFile
    if let container = try? JSONDecoder().decode(StoreFile.self, from: data) {
        file = container
    } else {
        file = StoreFile(groups: [], sessions: try JSONDecoder().decode([StoredSession].self, from: data))
    }
    // Defensive: a groupID whose group no longer exists behaves like nil.
    let knownIDs = Set(file.groups.map(\.id))
    for index in file.sessions.indices where file.sessions[index].groupID.map({ !knownIDs.contains($0) }) == true {
        file.sessions[index].groupID = nil
    }
    return file
}

private func persist(_ file: StoreFile) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(file).write(to: fileURL, options: .atomic)
}

public func all() throws -> [StoredSession] { try load().sessions }
public func allGroups() throws -> [StoredGroup] { try load().groups }

public func upsert(_ session: StoredSession) throws {
    var file = try load()
    if let index = file.sessions.firstIndex(where: { $0.id == session.id }) {
        file.sessions[index] = session
    } else {
        file.sessions.append(session)
    }
    try persist(file)
}

public func delete(id: UUID) throws {
    var file = try load()
    file.sessions.removeAll { $0.id == id }
    try persist(file)
}

public func upsertGroup(_ group: StoredGroup) throws {
    var file = try load()
    if let index = file.groups.firstIndex(where: { $0.id == group.id }) {
        file.groups[index] = group
    } else {
        file.groups.append(group)
    }
    try persist(file)
}

public func dissolveGroup(id: UUID) throws {
    var file = try load()
    file.groups.removeAll { $0.id == id }
    for index in file.sessions.indices where file.sessions[index].groupID == id {
        file.sessions[index].groupID = nil
    }
    try persist(file)
}
```

Wichtig: Ein `try?`-Decode auf `StoreFile` akzeptiert auch `[]` NICHT (Array ≠ Objekt) — genau deshalb funktioniert der Fallback. `Achtung:` leeres Array `[]` decodiert als `[StoredSession]` ✓.

- [ ] **Step 4: Grün laufen lassen** — `swift test --filter SessionStore` PASS, danach `swift test` komplett PASS (bestehende `StoredSessionCompatTests` müssen unverändert grün sein).

- [ ] **Step 5: Commit** — `git add -A && git commit -m "feat: add flat session groups to the session store"` (+ Footer).

---

### Task 2: SessionListViewModel — Gruppen-CRUD + Update-Semantik (Core)

**Files:**
- Modify: `Sources/macSCPCore/Presentation/SessionListViewModel.swift`
- Modify: `Sources/macSCPCore/Resources/{en,de}.lproj/Localizable.strings` NUR falls neue `core.*`-Fehlertexte nötig (Muster: bestehende `core.session.*`-Keys; für Gruppen-Fehler `core.session.groupSaveFailed %@` EN „Could not save group: %@" / DE „Gruppe konnte nicht gespeichert werden: %@")
- Test: `Tests/macSCPCoreTests/SessionListViewModelTests.swift` (erweitern, `InMemorySecretStore` existiert dort bereits als Helper)

**Interfaces:**
- Consumes: Task-1-API (`StoredGroup`, `allGroups`, `upsertGroup`, `dissolveGroup`, `groupID`).
- Produces:
  - `public private(set) var groups: [StoredGroup]` (Anlage-Reihenfolge, NICHT sortiert)
  - `public func sessions(inGroup groupID: UUID?) -> [StoredSession]`
  - `public func renameSession(_ session: StoredSession, to newName: String)` (trimmt; leer = no-op)
  - `public func updateSession(_ updated: StoredSession, newSecret: String?)` — `nil` ODER leer = Keychain-Secret bleibt; nicht-leer = `savePassword` überschreibt
  - `@discardableResult public func createGroup(named name: String) -> StoredGroup?` (trimmt; leer → nil, kein Anlegen)
  - `public func renameGroup(_ group: StoredGroup, to newName: String)` (trimmt; leer = no-op)
  - `public func dissolveGroup(_ group: StoredGroup)`
  - `public func moveSession(_ session: StoredSession, toGroup groupID: UUID?)`
  - `save(name:host:port:username:password:authKind:keyPath:groupID:)` — bestehende Methode + `groupID: UUID? = nil`; beim Update über Namens-Match bleibt eine vorhandene Gruppenzuordnung erhalten, wenn `groupID`-Argument `nil` ist? NEIN — Entscheidung: das Argument gewinnt IMMER (explizite Auswahl im Formular; der Picker ist beim Speichern sichtbar und `nil` heißt dort „Keine Gruppe").

- [ ] **Step 1: Failing Tests** (Auszug — alle in `SessionListViewModelTests.swift`; Setup-Muster der Datei übernehmen):

```swift
@Test @MainActor func groupCRUDRoundtrip() throws {
    let vm = makeViewModel() // existing helper pattern: temp store + InMemorySecretStore
    let group = vm.createGroup(named: "  Customers ")
    #expect(group?.name == "Customers")
    #expect(vm.groups.map(\.name) == ["Customers"])

    vm.renameGroup(group!, to: "Clients")
    #expect(vm.groups.map(\.name) == ["Clients"])

    #expect(vm.createGroup(named: "   ") == nil)
    #expect(vm.groups.count == 1)
}

@Test @MainActor func dissolveKeepsSessionsAndUngroupsThem() throws {
    let vm = makeViewModel()
    let group = vm.createGroup(named: "G")!
    let stored = vm.save(name: "s", host: "h", port: 22, username: "u",
                         password: "pw", groupID: group.id)!
    vm.dissolveGroup(group)
    #expect(vm.groups.isEmpty)
    #expect(vm.sessions.count == 1)
    #expect(vm.sessions.first?.groupID == nil)
    #expect(vm.password(for: stored) == "pw") // secret untouched
}

@Test @MainActor func moveAndFilterByGroup() throws {
    let vm = makeViewModel()
    let group = vm.createGroup(named: "G")!
    let stored = vm.save(name: "s", host: "h", port: 22, username: "u", password: "pw")!
    vm.moveSession(stored, toGroup: group.id)
    #expect(vm.sessions(inGroup: group.id).map(\.name) == ["s"])
    #expect(vm.sessions(inGroup: nil).isEmpty)
}

@Test @MainActor func renameSessionTrimsAndRejectsEmpty() throws {
    let vm = makeViewModel()
    let stored = vm.save(name: "old", host: "h", port: 22, username: "u", password: "pw")!
    vm.renameSession(stored, to: "  new ")
    #expect(vm.sessions.first?.name == "new")
    vm.renameSession(vm.sessions.first!, to: "   ")
    #expect(vm.sessions.first?.name == "new")
}

@Test @MainActor func updateSessionKeepsSecretWhenNewSecretIsNilOrEmpty() throws {
    let vm = makeViewModel()
    let stored = vm.save(name: "s", host: "h", port: 22, username: "u", password: "keep")!
    var updated = stored
    updated.host = "h2"
    vm.updateSession(updated, newSecret: nil)
    #expect(vm.password(for: stored) == "keep")
    vm.updateSession(updated, newSecret: "")
    #expect(vm.password(for: stored) == "keep")
    vm.updateSession(updated, newSecret: "next")
    #expect(vm.password(for: stored) == "next")
    #expect(vm.sessions.first?.host == "h2")
}
```

- [ ] **Step 2: Rot** — `swift test --filter SessionListViewModel` → FAIL (unbekannte Methoden).

- [ ] **Step 3: Implementieren** — alle Methoden folgen dem bestehenden do/catch-reload-errorMessage-Muster der Datei; `reload()` lädt zusätzlich `groups = try store.allGroups()` (unsortiert). Kernstücke:

```swift
public func sessions(inGroup groupID: UUID?) -> [StoredSession] {
    sessions.filter { $0.groupID == groupID }
}

public func renameSession(_ session: StoredSession, to newName: String) {
    let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    var updated = session
    updated.name = trimmed
    updateSession(updated, newSecret: nil)
}

public func updateSession(_ updated: StoredSession, newSecret: String?) {
    do {
        try store.upsert(updated)
        if let newSecret, !newSecret.isEmpty {
            try secrets.savePassword(newSecret, for: updated.id)
        }
        reload()
    } catch {
        reload()
        errorMessage = String(
            format: CoreL10n.string("core.session.saveFailed %@"), String(describing: error))
    }
}

@discardableResult
public func createGroup(named name: String) -> StoredGroup? {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    let group = StoredGroup(name: trimmed)
    do { try store.upsertGroup(group); reload(); return group }
    catch {
        reload()
        errorMessage = String(
            format: CoreL10n.string("core.session.groupSaveFailed %@"), String(describing: error))
        return nil
    }
}
```

`renameGroup`/`dissolveGroup`/`moveSession` analog (`moveSession`: Kopie mit gesetzter `groupID` → `updateSession(_, newSecret: nil)`). `save(...)` bekommt `groupID: UUID? = nil` und setzt es in beiden Zweigen (update + create).

- [ ] **Step 4: Grün** — `swift test --filter SessionListViewModel`, dann `swift test` komplett.
- [ ] **Step 5: Commit** — `feat: add group CRUD and secret-preserving updates to the session list`.

---

### Task 3: Sidebar — Gruppen, Kontextmenüs, Inline-Rename, D&D, CI-Optik (App)

**Files:**
- Modify: `Sources/MacSCPApp/SessionSidebar.swift` (weitgehender Neuaufbau des Body)
- Modify: `Sources/MacSCPApp/ContentView.swift:181-198` (neuer Callback `onEdit`)
- Modify: `Sources/MacSCPApp/Resources/{en,de}.lproj/Localizable.strings` (neue Keys, s.u.)
- Test: kein Unit-Test (reine SwiftUI-View; Logik liegt in T2) — Verifikation über T6-Smoke.

**Interfaces:**
- Consumes: T2-API komplett; `DesignTokens.remoteBlue`, `DesignTokens.statusPhosphor`.
- Produces: `SessionSidebar` mit zusätzlichem Parameter `onEdit: (StoredSession) -> Void`; ContentView reicht ihn durch (T4 implementiert den Handler; T3 verdrahtet ihn provisorisch mit `{ _ in }` und einem `// wired in M5f/T4` -Kommentar, damit T3 eigenständig baubar bleibt).

Verhalten (aus der Spec, bindend):
- Reihenfolge: „SESSIONS"-Label → ungruppierte (`viewModel.sessions(inGroup: nil)`) → je Gruppe (Anlage-Reihenfolge) ein einklappbarer Abschnitt → „IMPORTIERT"-Sektion unverändert.
- Einklapp-Zustand: `@State private var collapsedGroups: Set<UUID> = []` (nicht persistiert).
- Kontextmenü Session: Verbinden (`onSelect`) · Bearbeiten… (`onEdit`) · Umbenennen (startet Inline-Edit) · „Verschieben nach" als `Menu` mit: „Keine Gruppe" (nur wenn gruppiert), alle Gruppen (Häkchen/Disabled für aktuelle), Divider, „Neue Gruppe…" (legt via Alert an und verschiebt dann) · Löschen (role: .destructive → `confirmationDialog`).
- Löschen-Rückfrage (`confirmationDialog`): Titel mit Session-Namen, Text nennt Keychain-Löschung, destruktiver Bestätigen-Button.
- Kontextmenü Gruppen-Header: Umbenennen (Inline) · Auflösen (`dissolveGroup`).
- Kontextmenü Hintergrund (`.contextMenu` auf der List/leerer Fläche): Neue Verbindung (`onNew`) · Neue Gruppe….
- „Neue Gruppe…": `.alert` mit `TextField` (Bestätigen ruft `createGroup`; leerer Name legt nichts an — VM-Guard reicht, der Alert darf einfach schließen).
- Inline-Rename (Session UND Gruppe): `@State private var renamingID: UUID?` + `@State private var renameDraft: String = ""` + `@FocusState`; Zeile zeigt `TextField` statt `Text`, `.onSubmit` committet (`renameSession`/`renameGroup`), Escape (`.onExitCommand`) und Fokus-Verlust brechen ab (kein stiller Commit).
- D&D: Session-Zeile `.draggable(session.id.uuidString)`; Gruppen-Header `.dropDestination(for: String.self)` → `moveSession(toGroup: group.id)`; das „SESSIONS"-Label ebenso mit `toGroup: nil`. (String-Payload reicht; UUID aus String parsen, unbekannte IDs ignorieren.)
- Optik: aktive Session `.background(RoundedRectangle(cornerRadius: 6).fill(DesignTokens.remoteBlue.opacity(0.12)))` + `.fontWeight(.semibold)` + `.foregroundStyle(DesignTokens.remoteBlue)`; Phosphor-Punkt wie gehabt; Hover-Zustand über `.onHover`-State mit `Color.secondary.opacity(0.08)`-Hintergrund; Abschnitts-Labels `.font(.caption2.weight(.semibold)).tracking(0.8).foregroundStyle(.secondary)` + `.textCase(.uppercase)`-Verhalten über bereits versalen Katalog-Text.
- `interactionsDisabled` bleibt auf dem Gesamt-Container.

Neue L10n-Keys (EN → DE), in BEIDE Kataloge unter `/* Session manager (M5f) */`:

```
"sidebar.connect" = "Connect"; / "Verbinden";
"sidebar.edit" = "Edit…"; / "Bearbeiten…";
"sidebar.rename" = "Rename"; / "Umbenennen";
"sidebar.moveTo" = "Move to"; / "Verschieben nach";
"sidebar.noGroup" = "No group"; / "Keine Gruppe";
"sidebar.newGroup" = "New group…"; / "Neue Gruppe…";
"sidebar.newGroup.title" = "New group"; / "Neue Gruppe";
"sidebar.newGroup.placeholder" = "Group name"; / "Gruppenname";
"sidebar.newGroup.create" = "Create"; / "Anlegen";
"sidebar.group.dissolve" = "Dissolve group"; / "Gruppe auflösen";
"sidebar.delete.confirmTitle %@" = "Delete “%@”?"; / "„%@“ löschen?";
"sidebar.delete.confirmMessage" = "The saved credentials are removed as well."; / "Die gespeicherten Zugangsdaten werden mit entfernt.";
"common.create" = "Create"; / "Anlegen";
```

(„sidebar.delete" = „Delete"/„Löschen" existiert bereits.)

- [ ] **Step 1: Implementieren** (View-Umbau nach obiger Spezifikation; Struktur-Vorgabe):

```swift
List {
    Button(action: onNew) { Label(L10n.string("sidebar.newConnection", "New connection"), systemImage: "plus") }
        .buttonStyle(.plain)

    sessionRows(viewModel.sessions(inGroup: nil))          // ungrouped

    ForEach(viewModel.groups) { group in
        Section(isExpanded: Binding(
            get: { !collapsedGroups.contains(group.id) },
            set: { expanded in
                if expanded { collapsedGroups.remove(group.id) }
                else { collapsedGroups.insert(group.id) }
            }
        )) {
            sessionRows(viewModel.sessions(inGroup: group.id))
        } header: {
            groupHeader(group)   // label + context menu + dropDestination + inline rename
        }
    }

    importedSection  // unverändert aus dem Bestand extrahiert
}
```

`sessionRows(_:)` und `groupHeader(_:)` als private `@ViewBuilder`-Helper; Zeilen-Inhalt (Punkt, Name/TextField, Hover, aktive Optik, contextMenu, draggable, help) in einem privaten `SessionRow`-Sub-View, damit der Body lesbar bleibt.

- [ ] **Step 2: Build prüfen** — `swift build` fehlerfrei; `swift test` komplett grün (keine Core-Änderungen).
- [ ] **Step 3: Kurzer manueller Sanity-Check** (Koordinator übernimmt den vollen Smoke in T6): App bauen und starten, Gruppe anlegen, Session per Kontextmenü verschieben, Inline-Rename, Löschen-Rückfrage.
- [ ] **Step 4: Commit** — `feat: add groups, context menus and CI styling to the session sidebar`.

---

### Task 4: Edit-Modus im Verbindungsformular (Core + App)

**Files:**
- Modify: `Sources/macSCPCore/Presentation/ConnectionViewModel.swift`
- Modify: `Sources/MacSCPApp/ConnectionFormView.swift`
- Modify: `Sources/MacSCPApp/ContentView.swift` (`onEdit`-Handler, Speichern-Callbacks, Gruppen-Picker-Datenfluss, `save(...)`-Aufruf um `groupID` ergänzen)
- Modify: `Sources/macSCPCore/Resources/{en,de}.lproj/Localizable.strings` + App-Kataloge (Keys s.u.)
- Test: `Tests/macSCPCoreTests/ConnectionViewModelTests.swift` (erweitern)

**Interfaces:**
- Consumes: T2 (`updateSession(_:newSecret:)`, `groups`), T3 (`onEdit`-Callback-Slot).
- Produces (ConnectionViewModel):
  - `public enum FormMode: Equatable, Sendable { case new, edit(sessionID: UUID) }`
  - `public private(set) var mode: FormMode = .new`
  - `public var selectedGroupID: UUID?` (gilt für new-mit-Speichern UND edit)
  - `public func beginEditing(_ stored: StoredSession)` — füllt host/port/username/authChoice/keyPath/saveName/selectedGroupID, setzt `password = ""` (NIE aus Keychain laden), `mode = .edit(sessionID: stored.id)`, `state = .idle`
  - `public func endEditing()` — `mode = .new`, Formularfelder zurück auf Ausgangszustand (wie `teardownSession` sie hinterlässt: leere Felder, `authChoice = .password`)
  - `public func validateForEditSave() -> StoredSession?` — validiert host/port(numerisch)/username/name (Password darf leer sein; bei `.privateKey` muss keyPath gesetzt sein); bei Erfolg liefert sie die zusammengebaute `StoredSession` mit der `sessionID` aus dem Mode und `groupID = selectedGroupID`; bei Fehler setzt sie `state = .failed(...)` mit denselben `core.connect.*`-Meldungen wie `connect()` und liefert `nil`.

Verhalten:
- ContentView `onEdit(stored)`: wie `connectStored` zuerst `await teardownSession()` (Detailfläche wird Formular), dann `connectionViewModel.beginEditing(stored)`. Kein Auto-Connect.
- FormView im Edit-Modus (`case .edit = viewModel.mode`):
  - Titel `connection.editTitle` („Edit session" / „Session bearbeiten").
  - Passwort-/Passphrase-Feld: Placeholder `connection.field.password.unchanged` („unchanged" / „unverändert"); Feld leer beim Einstieg.
  - Speichern-Toggle + Session-Name-Feld: Toggle ausgeblendet, Name-Feld immer sichtbar (Label `connection.field.saveName`).
  - Gruppen-Picker (`connection.field.group` „Group"/„Gruppe"): Optionen „Keine Gruppe" (`sidebar.noGroup`, tag `UUID?.none`) + alle `groups` (Parameter `groups: [StoredGroup]`, von ContentView `sessionListViewModel.groups` gereicht). Derselbe Picker erscheint im New-Modus sobald `shouldSaveSession == true`.
  - Buttons: **Zurück** (`common.back`, ruft `onCancelEdit`) · **Speichern** (`common.save` „Save"/„Speichern", ruft `onSaveEdited(session, newSecret)`) · **Speichern & verbinden** (`connection.saveAndConnect` „Save & connect"/„Speichern & verbinden", `.keyboardShortcut(.defaultAction)`, prominenter Button).
  - `newSecret`-Regel am Callback: `viewModel.password.isEmpty ? nil : viewModel.password`.
- Neue FormView-Parameter: `groups: [StoredGroup]`, `onSaveEdited: (StoredSession, String?) -> Void`, `onCancelEdit: () -> Void` (mit Default-Werten `[]`/no-ops, damit T3-Aufrufer nicht bricht).
- ContentView-Handler:
  - `onSaveEdited`: `sessionListViewModel.updateSession(session, newSecret: secret); connectionViewModel.endEditing()`
  - „Speichern & verbinden": FormView ruft dafür `onSaveEdited` gefolgt von `onConnectEdited(session)`; ContentView implementiert `onConnectEdited` als `connectStored(session)` (lädt Secret aus der Keychain — deckt „leer = unverändert" automatisch). Callback-Signatur: `onConnectEdited: (StoredSession) -> Void = { _ in }`.
  - `startSession`-Save-Block (ContentView:449-467): `groupID: connectionViewModel.selectedGroupID` ergänzen.
- Edit-Modus zeigt KEINEN Verbinden-Button und keinen TOFU-Prompt-Zweig (der existiert nur im Connect-Weg; `hostKeyPrompt` bleibt im Edit-Modus nil, weil nie verbunden wird — keine Sonderbehandlung nötig).

Neue Keys: `connection.editTitle`, `connection.field.password.unchanged`, `connection.field.group`, `connection.saveAndConnect`, `common.save` (EN/DE wie oben) — App-Katalog; keine neuen Core-Keys (Validierung nutzt bestehende `core.connect.*`).

- [ ] **Step 1: Failing Tests** (`ConnectionViewModelTests.swift`):

```swift
@Test @MainActor func beginEditingPrefillsEverythingExceptTheSecret() {
    let vm = makeViewModel() // existing helper/connector stub pattern of the file
    let stored = StoredSession(name: "web", host: "h", port: 2222, username: "u",
                               authKind: .privateKey, keyPath: "/k", groupID: UUID())
    vm.password = "leftover"
    vm.beginEditing(stored)

    #expect(vm.mode == .edit(sessionID: stored.id))
    #expect(vm.host == "h" && vm.port == "2222" && vm.username == "u")
    #expect(vm.saveName == "web" && vm.keyPath == "/k")
    #expect(vm.authChoice == .privateKey)
    #expect(vm.selectedGroupID == stored.groupID)
    #expect(vm.password.isEmpty) // never loaded from the keychain
}

@Test @MainActor func validateForEditSaveAllowsEmptyPasswordAndBuildsTheSession() {
    let vm = makeViewModel()
    let stored = StoredSession(name: "web", host: "h", username: "u")
    vm.beginEditing(stored)
    vm.host = "new.example"

    let result = vm.validateForEditSave()
    #expect(result?.id == stored.id)
    #expect(result?.host == "new.example")
    #expect(vm.state == .idle)
}

@Test @MainActor func validateForEditSaveRejectsInvalidPort() {
    let vm = makeViewModel()
    vm.beginEditing(StoredSession(name: "web", host: "h", username: "u"))
    vm.port = "abc"
    #expect(vm.validateForEditSave() == nil)
    #expect(vm.state == .failed(message: CoreL10n.string("core.connect.portNumeric"), field: .port))
}

@Test @MainActor func endEditingReturnsToNewMode() {
    let vm = makeViewModel()
    vm.beginEditing(StoredSession(name: "web", host: "h", username: "u"))
    vm.endEditing()
    #expect(vm.mode == .new)
    #expect(vm.host.isEmpty && vm.saveName.isEmpty)
}
```

- [ ] **Step 2: Rot** — `swift test --filter ConnectionViewModel` → FAIL.
- [ ] **Step 3: Core implementieren** (Mode/beginEditing/endEditing/validateForEditSave nach Interface oben; Validierungsreihenfolge und Meldungen identisch zu `connect()`: host leer → `.host`, port nicht numerisch → `.port`, username leer → `.username`, name leer → `.saveName`, bei `.privateKey` keyPath leer → `.keyPath`).
- [ ] **Step 4: Grün** — Filter-Suite, dann `swift test` komplett.
- [ ] **Step 5: App-Teil implementieren** (FormView-Zweige + ContentView-Handler + Kataloge nach Spezifikation oben) und `swift build` prüfen.
- [ ] **Step 6: Commit** — `feat: add edit mode for stored sessions to the connection form`.

---

### Task 5: Toolbar, Fenstertitel, globaler Tint, Formular-Proportionen (App)

**Files:**
- Modify: `Sources/MacSCPApp/ContentView.swift:229-250` (Kopfzeilen-HStack → `.toolbar`), `:181-207` (Tint), `startSession`/`teardownSession` (Fenstertitel)
- Modify: `Sources/MacSCPApp/MacSCPApp.swift` (Tint auf Settings-Scene)
- Modify: `Sources/MacSCPApp/ConnectionFormView.swift` (prominenter Primärbutton)
- Test: kein Unit-Test (reine Präsentation) — Verifikation T6.

**Interfaces:**
- Consumes: `DesignTokens.remoteBlue`; bestehender `WindowAccessor` (`window`-State in ContentView); `connectionViewModel.saveName`/`username`/`host`.
- Produces: keine neuen APIs.

Verhalten:
- Kopfzeile (ContentView:233-249) entfällt; stattdessen am `detail`-Container:

```swift
.toolbar {
    if let session {
        ToolbarItemGroup(placement: .primaryAction) {
            uploadButton(session)      // existing builders, unchanged semantics
            downloadButton(session)
            Button { session.terminal.toggle() } label: {
                Label(L10n.string("browser.terminalToggle", "Terminal"), systemImage: "terminal")
            }
            .keyboardShortcut("t", modifiers: .command)
            .help(L10n.string("browser.terminalToggleHelp", "Show/hide terminal (⌘T)"))
            Button(L10n.string("browser.disconnect", "Disconnect")) { disconnectToForm() }
                .disabled(transferQueue.isActive)
        }
    }
}
```

  (Platzierung am äußeren `HSplitView`-Container in `body`, damit die Toolbar dem Fenster gehört; `if let session` hält sie im getrennten Zustand leer.)
- Fenstertitel: in `startSession` nach dem Save-Block `window?.title = "macSCP — " + (activeSessionName ?? "\(connectionViewModel.username)@\(connectionViewModel.host)")`, wobei `activeSessionName` der gespeicherte Name ist (`connectionViewModel.saveName`, falls nicht leer); in `teardownSession` zurück auf `window?.title = "macSCP"`. Der Titel ist reine Fenster-Chrome (Eigenname „macSCP" + Nutzdaten) — kein Katalog-Key nötig.
- Globaler Tint: `.tint(DesignTokens.remoteBlue)` auf dem Root-Container in `ContentView.body` UND auf `SettingsView` in `MacSCPApp.swift`.
- Primärbutton: in `ConnectionFormView` bekommen „Verbinden" (New-Modus) und „Speichern & verbinden" (Edit-Modus) `.buttonStyle(.borderedProminent)` (Farbe kommt über den Tint). Übrige Buttons bleiben Standard.
- Formular-Proportionen: `Form`-Block auf `.frame(maxWidth: 460)` begrenzen und den umgebenden VStack horizontal zentriert lassen wie bisher (Mockup-Proportion ~420–460 pt); Alert-/Highlight-Verhalten aus dem Design-Review-Fix (6e03c7a) unangetastet.
- CI-Wache: Upload-/Download-Button-Beschriftungen behalten ihre semantischen Farben (bestehende Builder unverändert); der blaue Tint darf Bernstein-Elemente nicht überschreiben (TransferQueueBar setzt seine Farben explizit — prüfen, dass kein `.tint`-Erbe sie kippt; falls doch, dort explizit gegensetzen).

- [ ] **Step 1: Implementieren** nach Spezifikation.
- [ ] **Step 2: Build + volle Suite** — `swift build`, `swift test` grün.
- [ ] **Step 3: Commit** — `feat: move session actions into a native toolbar and adopt the CI accent`.

---

### Task 6: Abschluss-Verifikation

- [ ] `swift test` gesamt; Rig hoch (`docker compose -f docker/test-server/compose.yml up -d`, NUR aus dem Haupt-Checkout), `MACSCP_ITEST=1 MACSCP_KEYCHAIN=1 swift test` voll grün.
- [ ] **Alt-Datei-Kompatibilität real:** vorhandene `~/Library/Application Support/macSCP/sessions.json` sichern; App starten → bestehende Sessions erscheinen; eine Gruppe anlegen → Datei ist jetzt Container-Format; App neu starten → alles noch da.
- [ ] **Visueller Smoke (Bildschirm frei):**
  - Sidebar: Gruppe „Kunden" anlegen (Hintergrund-Kontextmenü), Session per „Verschieben nach" einordnen, per Drag & Drop wieder heraus; Gruppe einklappen; Inline-Umbenennen von Session UND Gruppe (Enter committet, Escape bricht ab); Löschen zeigt Rückfrage mit Namen; aktive Session ist blau hinterlegt mit Phosphor-Punkt.
  - Edit-Roundtrip: Session anlegen (verbinden mit „Als Session speichern", Gruppe im Picker wählbar) → trennen → Kontextmenü „Bearbeiten…" → Formular vorbefüllt, Passwortfeld leer mit „unverändert" → Host ändern, Passwort LEER lassen → „Speichern & verbinden" → Verbindung kommt zustande (beweist: Secret blieb erhalten) → erneut bearbeiten, falsches Passwort eintippen → Speichern → Verbinden schlägt mit Auth-Fehler fehl (beweist: Secret überschrieben) → korrigieren.
  - Toolbar/Titel: verbunden zeigt „macSCP — ‹Name›" + Toolbar-Aktionen; getrennt „macSCP" ohne Items; ⌘T funktioniert weiter.
  - Farben: Verbinden/Speichern & verbinden prominent in Ozeanblau; Pane-Badges weiter Bernstein/Blau; Transfer-Leiste unverändert Duo-Farben; DE + EN stichprobenartig (eine Ansicht mit `-AppleLanguages '(en)'`).
- [ ] Checkboxen im Plan abhaken, Commit `docs: mark M5f plan tasks as completed` (+ Footer).

## Ausblick

Danach M6 — Release (Icon, DMG mit lproj-Markern + SPM-Bundles, README, Polish-Backlog aus dem Ledger).
