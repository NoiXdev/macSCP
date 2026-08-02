# M18a — Browser-Fixes & „Neue Datei" Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Der Neuer-Ordner-Dialog hängt nicht mehr am Neuladen der Liste, Owner/Gruppe werden nur bei sichtbaren Spalten geholt, „Neue Datei…" kommt ins Kontextmenü, und eine außerhalb des Bildschirms wiederhergestellte Fenstergeometrie wird untersucht.

**Architecture:** Kernänderung ist eine Trennung in Core: die Datei-Operation (schnell, fehlerbehaftet) und die anschließende Listen-Aktualisierung (langsam, reine Anzeige) werden zwei awaitbare Schritte; der Dialog wartet nur noch auf den ersten. Dazu ein Schalter am `LocalFileSystem`, der die teure Owner/Gruppe-Abfrage nur bei sichtbaren Spalten macht.

**Tech Stack:** Swift (SwiftPM, `.swiftLanguageMode(.v5)`), Swift Testing, SwiftUI + AppKit, macOS 15+.

## Global Constraints

- Swift `.swiftLanguageMode(.v5)`, minimum macOS 15; **keine neue externe Dependency**.
- **Keine Protokolländerung** an `RemoteFileSystem` (kein neuer `list`-Parameter).
- Fehlerverhalten unverändert: Kollisionen/Fehler erscheinen **im** Dialog, der dann offen bleibt.
- Audit-Ereignisse bleiben erhalten (`newFolder`, `rename`) bzw. folgen demselben Muster (`newFile`).
- Bestehende Tests werden **angepasst, nicht gelöscht** — jede bisher geprüfte Erwartung muss weiter geprüft werden (ggf. auf zwei Schritte verteilt).
- UI-Strings EN/DE/FR/PL, typografische Zeichen in nicht-englischen Werten.
- Conventional Commits; Footer: `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.

**Verankerte Fakten (verifiziert):** `RemoteBrowserViewModel.createFolder(named:)` liegt bei `Sources/macSCPCore/Presentation/RemoteBrowserViewModel.swift:464`, `rename(_:to:)` direkt davor (~445); beide: Operation → `await load()` → Auswahl setzen → Audit → `return nil`. `LocalFileSystem.list(path:)` (`:59`) mappt jeden Eintrag durch `Self.item(for:)` (`:266`) → `ownerGroup(for:)` (`:302`, `FileManager.attributesOfItem` pro Eintrag). `LocalFileSystem()` wird erzeugt in `ContentView.swift:1908` und `:1910` sowie `EditSessionManager.swift:39`. `NameEntrySheet.confirm()` (`Sources/MacSCPApp/BrowserSheets.swift:47`) ruft `dismiss()` erst nach `await onConfirm(...)`. Menü-Auslöser `case .newFolder: showNewFolderSheet = true` (`Sources/MacSCPApp/BrowserPane.swift:191`), Sheet bei `:257`. `BrowserMenuEntry` (`Sources/macSCPCore/Presentation/BrowserContextMenu.swift`) hat u. a. `case newFolder` (:34); gerendert in `RemoteFileTableView.swift:852`. Fenster-`setFrame` bei `ContentView.swift:1565`.

---

## Task 1: Core — Operation und Listen-Aktualisierung trennen

**Files:**
- Modify: `Sources/macSCPCore/Presentation/RemoteBrowserViewModel.swift`
- Test: `Tests/macSCPCoreTests/RemoteBrowserViewModelTests.swift`

**Interfaces:**
- Produces: `public func refreshAndSelect(path: String) async`; `createFolder(named:)` und `rename(_:to:)` behalten ihre Signatur (`async -> String?`), laden aber **nicht** mehr selbst nach.

- [ ] **Step 1: Failing-Test schreiben**

In `Tests/macSCPCoreTests/RemoteBrowserViewModelTests.swift` ergänzen. Nutze den in dieser Datei vorhandenen Fake-FS (Name aus der Datei übernehmen — **nicht erfinden**) und zähle dessen `list`-Aufrufe; hat der Fake keinen Zähler, ergänze einen (`private(set) var listCallCount`).

```swift
    // MARK: - Operation does not wait on the listing (M18a)

    @Test func createFolderReturnsWithoutRefreshingTheListing() async {
        let fs = /* Fake-FS dieser Datei, mit list-Zähler */
        let vm = /* wie in den Nachbartests konstruiert */
        await vm.load()
        let listsAfterLoad = await fs.listCallCount

        let error = await vm.createFolder(named: "fresh")
        #expect(error == nil)
        // The create must NOT have triggered another listing — dismissing the
        // sheet may not wait on it.
        #expect(await fs.listCallCount == listsAfterLoad)
    }

    @Test func refreshAndSelectRefreshesAndSelectsTheNewEntry() async {
        let fs = /* Fake-FS */
        let vm = /* … */
        await vm.load()
        _ = await vm.createFolder(named: "fresh")

        await vm.refreshAndSelect(path: RemotePath.join(vm.currentPath, "fresh"))
        #expect(vm.items.contains { $0.name == "fresh" })
        #expect(vm.selectedItems.map(\.name) == ["fresh"])
    }
```

Den bestehenden Test `createFolderRefreshesAndSelects` **anpassen** (nicht löschen): er ruft künftig `createFolder` **und** `refreshAndSelect` und prüft dieselben Erwartungen wie bisher. Gleiches für einen etwaigen Rename-Pendant-Test.

- [ ] **Step 2: Test rot**

Run: `swift test --filter RemoteBrowserViewModelTests`
Expected: FAIL — `createFolderReturnsWithoutRefreshingTheListing` schlägt fehl (die Liste wird noch geladen) bzw. `refreshAndSelect` existiert nicht.

- [ ] **Step 3: Umbau in `RemoteBrowserViewModel`**

`createFolder(named:)` (~464): den Block nach erfolgreichem `createDirectory`

```swift
        await load()
        if let created = items.first(where: { $0.path == path }) {
            selectedItems = [created]
        }
        auditSink?(AuditEvent(kind: .newFolder, detail: detail))
        return nil
```

ersetzen durch

```swift
        // The directory exists once `createDirectory` returns; refreshing the
        // listing is presentation only. Keeping it out of this method means
        // dismissing the sheet never waits on a listing — which can block on
        // a slow server, a huge directory, or a macOS permission prompt
        // (M18a). Callers refresh via `refreshAndSelect(path:)` afterwards.
        auditSink?(AuditEvent(kind: .newFolder, detail: detail))
        return nil
```

`rename(_:to:)` (~445) analog: `await load()` + Auswahl entfernen, Audit + `return nil` bleiben.

Neue Methode ergänzen (neben `load()`):

```swift
    /// Refreshes the listing and selects `path` when present. Called after a
    /// successful create/rename so the sheet can dismiss immediately (M18a).
    public func refreshAndSelect(path: String) async {
        await load()
        if let entry = items.first(where: { $0.path == path }) {
            selectedItems = [entry]
        }
    }
```

- [ ] **Step 4: Test grün + volle Suite**

Run: `swift test --filter RemoteBrowserViewModelTests` → PASS.
Dann `swift build && swift test` → Build 0 Warnungen, alle Tests grün.

- [ ] **Step 5: Commit**

```bash
git add Sources/macSCPCore/Presentation/RemoteBrowserViewModel.swift Tests/macSCPCoreTests/RemoteBrowserViewModelTests.swift
git commit -m "fix: stop create and rename from waiting on a listing refresh

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Task 2: Core — Owner/Gruppe nur auf Anforderung

**Files:**
- Modify: `Sources/macSCPCore/RemoteFS/LocalFileSystem.swift`
- Test: `Tests/macSCPCoreTests/LocalFileSystemTests.swift`

**Interfaces:**
- Produces: `LocalFileSystem.init(fetchesOwnerGroup: Bool = false)`.

- [ ] **Step 1: Failing-Test**

In `Tests/macSCPCoreTests/LocalFileSystemTests.swift` (Datei existiert; Muster der Nachbartests für Temp-Verzeichnisse übernehmen):

```swift
    // MARK: - Owner/group is opt-in (M18a)

    @Test func listOmitsOwnerAndGroupByDefault() async throws {
        let dir = /* Temp-Verzeichnis wie in den Nachbartests */
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("x".utf8).write(to: dir.appendingPathComponent("a.txt"))

        let fs = LocalFileSystem()   // default: no owner/group lookup
        let items = try await fs.list(path: dir.path(percentEncoded: false))
        #expect(items.count == 1)
        #expect(items[0].owner == nil)
        #expect(items[0].group == nil)
    }

    @Test func listIncludesOwnerAndGroupWhenRequested() async throws {
        let dir = /* Temp-Verzeichnis */
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("x".utf8).write(to: dir.appendingPathComponent("a.txt"))

        let fs = LocalFileSystem(fetchesOwnerGroup: true)
        let items = try await fs.list(path: dir.path(percentEncoded: false))
        #expect(items[0].owner != nil)
        #expect(items[0].group != nil)
    }
```

Die Feldnamen (`owner`/`group`) gegen `RemoteFileItem` prüfen und exakt übernehmen.

- [ ] **Step 2: Test rot**

Run: `swift test --filter LocalFileSystemTests`
Expected: FAIL — `listOmitsOwnerAndGroupByDefault` schlägt fehl (Owner/Gruppe sind gefüllt) bzw. der Initializer existiert nicht.

- [ ] **Step 3: Implementieren**

`LocalFileSystem` bekommt ein gespeichertes `let fetchesOwnerGroup: Bool` mit
`init(fetchesOwnerGroup: Bool = false)`. Da `item(for:)` heute `static` ist,
muss der Schalter bis dorthin durchgereicht werden — entweder `item(for:)` um
einen Parameter erweitern (`static func item(for url: URL, fetchesOwnerGroup: Bool)`)
und an allen Aufrufstellen (`list` ~59, `stat` ~71) mitgeben, oder `item` zu
einer Instanzmethode machen. Wähle die Variante mit dem kleineren Diff und
passe **alle** Aufrufstellen an.

In `ownerGroup(for:)` wird der `attributesOfItem`-Aufruf nur noch ausgeführt,
wenn der Schalter an ist; sonst `(nil, nil)` ohne Syscall. Dokumentiere im
Doc-Kommentar **warum**: pro Eintrag ein Syscall, und auf geschützten Ordnern
(Schreibtisch/Dokumente/Downloads) löst er blockierende macOS-Berechtigungs-
dialoge aus (M18a-Befund).

- [ ] **Step 4: Test grün + volle Suite**

Run: `swift test --filter LocalFileSystemTests` → PASS. Dann `swift build && swift test` → 0 Warnungen, grün.

- [ ] **Step 5: Commit**

```bash
git add Sources/macSCPCore/RemoteFS/LocalFileSystem.swift Tests/macSCPCoreTests/LocalFileSystemTests.swift
git commit -m "perf: look up local owner and group only when asked

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Task 3: Core — `createFile`

**Files:**
- Modify: `Sources/macSCPCore/Presentation/RemoteBrowserViewModel.swift`
- Modify: `Sources/macSCPCore/Presentation/BrowserContextMenu.swift` (Menüeintrag `newFile`)
- Test: `Tests/macSCPCoreTests/RemoteBrowserViewModelTests.swift`

**Interfaces:**
- Consumes: `refreshAndSelect(path:)` (Task 1), `RemoteFileSystem.write(path:mode:contents:)`.
- Produces: `public func createFile(named name: String) async -> String?`; `BrowserMenuEntry.newFile`.

- [ ] **Step 1: Failing-Test**

```swift
    // MARK: - createFile (M18a)

    @Test func createFileCreatesAnEmptyFileAndReportsSuccess() async {
        let fs = /* Fake-FS */
        let vm = /* … */
        await vm.load()

        let error = await vm.createFile(named: "notes.txt")
        #expect(error == nil)
        await vm.refreshAndSelect(path: RemotePath.join(vm.currentPath, "notes.txt"))
        #expect(vm.items.contains { $0.name == "notes.txt" })
    }

    @Test func createFileCollisionReturnsError() async {
        let fs = /* Fake-FS mit vorhandenem Eintrag "taken.txt" */
        let vm = /* … */
        await vm.load()
        let error = await vm.createFile(named: "taken.txt")
        #expect(error != nil)
    }
```

Ergänze zusätzlich einen Audit-Test analog zu `createFolderSuccessFiresNewFolderEventWithFullPath` (Muster aus derselben Datei übernehmen).

- [ ] **Step 2: Test rot**

Run: `swift test --filter RemoteBrowserViewModelTests`
Expected: FAIL — „value of type 'RemoteBrowserViewModel' has no member 'createFile'".

- [ ] **Step 3: `createFile` implementieren**

Direkt neben `createFolder`, mit **derselben** Kollisionsprüfung (`stat`-Probe,
weil sie auch versteckte Einträge sieht) und demselben Fehlerkontrakt. Statt
`createDirectory` wird eine leere Datei geschrieben:

```swift
    /// Creates an empty file in the current directory. Same collision probe
    /// and error contract as `createFolder(named:)`; like it, this does NOT
    /// refresh the listing — callers use `refreshAndSelect(path:)` (M18a).
    public func createFile(named name: String) async -> String? {
        let path = RemotePath.join(currentPath, name)
        let detail = "create \(path)"
        if (try? await fs.stat(path: path)) != nil {
            let message = Self.message(
                for: RemoteFSError.protocolError(reason: "destination already exists: \(path)"),
                path: path)
            auditSink?(AuditEvent(kind: .newFile, detail: detail, isError: true, errorMessage: message))
            return message
        }
        do {
            let empty = AsyncThrowingStream<Data, Error> { $0.finish() }
            try await fs.write(path: path, mode: .overwrite, contents: empty)
        } catch {
            let message = Self.message(for: error, path: path)
            auditSink?(AuditEvent(kind: .newFile, detail: detail, isError: true, errorMessage: message))
            return message
        }
        auditSink?(AuditEvent(kind: .newFile, detail: detail))
        return nil
    }
```

Die exakte `write`-Signatur und den leeren Stream gegen `RemoteFileSystem` und
bestehende Aufrufer prüfen (z. B. wie `EditSessionManager` schreibt) und
übernehmen. `AuditEvent.Kind` braucht einen neuen Fall `newFile` — ergänze ihn
und passe **alle** erschöpfenden `switch`-Stellen an (u. a.
`Sources/MacSCPApp/AuditLogSheet.swift:229`, wo `.rename, .delete, .permissions, .newFolder`
zusammen behandelt werden).

- [ ] **Step 4: Menüeintrag im Modell**

In `BrowserContextMenu.swift` `case newFile` neben `case newFolder` (:34)
ergänzen — dieselbe Verfügbarkeitsregel (auch bei Klick auf den leeren
Bereich). Die Stelle, die die Einträge zusammenstellt, entsprechend erweitern,
und die zugehörigen Tests der Menü-Zusammenstellung mitziehen (Datei mit den
`BrowserContextMenu`-Tests suchen und die vorhandenen Erwartungen ergänzen).

- [ ] **Step 5: Test grün + volle Suite**

Run: `swift test` → alle grün, Build 0 Warnungen.

- [ ] **Step 6: Commit**

```bash
git add Sources/macSCPCore Tests/macSCPCoreTests
git commit -m "feat: create an empty file from the browser

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Task 4: App — Dialog nicht warten lassen, „Neue Datei…", Owner/Gruppe-Flag

**Files:**
- Modify: `Sources/MacSCPApp/BrowserPane.swift`
- Modify: `Sources/MacSCPApp/RemoteFileTableView.swift`
- Modify: `Sources/MacSCPApp/ContentView.swift`
- Modify: `Sources/MacSCPApp/Resources/{en,de,fr,pl}.lproj/Localizable.strings`

**Interfaces:**
- Consumes: `refreshAndSelect(path:)`, `createFile(named:)`, `BrowserMenuEntry.newFile` (Tasks 1–3), `LocalFileSystem(fetchesOwnerGroup:)` (Task 2).

Reine App-Verkabelung — build-verifiziert.

- [ ] **Step 1: Neuer-Ordner-Sheet wartet nicht mehr**

In `BrowserPane.swift` den `onConfirm` des Neuer-Ordner-Sheets (~257) so
ändern, dass nach Erfolg **ohne Warten** aktualisiert wird:

```swift
                onConfirm: { name in
                    let error = await viewModel.createFolder(named: name)
                    if error == nil {
                        // Dismiss immediately; the listing refresh must not
                        // hold the sheet open (M18a).
                        let path = RemotePath.join(viewModel.currentPath, name)
                        Task { await viewModel.refreshAndSelect(path: path) }
                    }
                    return error
                })
```

Den Rename-Sheet (~250) analog anpassen (Zielpfad ist dort
`RemotePath.join(viewModel.currentPath, newName)`).

- [ ] **Step 2: „Neue Datei…"-Sheet + Auslöser**

`@State private var showNewFileSheet = false` ergänzen; im Menü-Callback
`case .newFile: showNewFileSheet = true` (neben `.newFolder`, ~191); ein
weiteres `.sheet(isPresented: $showNewFileSheet)` mit `NameEntrySheet`
(Titel `sheet.newFile.title`, Bestätigung `sheet.newFile.confirm`,
Standardname `sheet.newFile.defaultName`) und demselben Nicht-Warten-Muster
aus Step 1, aber `viewModel.createFile(named:)`.

In `RemoteFileTableView.swift` den neuen Fall rendern (bei ~852 neben
`.newFolder`), Titel `menu.newFile`.

- [ ] **Step 3: Owner/Gruppe-Flag setzen**

In `ContentView.swift` an den beiden `LocalFileSystem()`-Stellen (:1908, :1910)
den Schalter aus den sichtbaren Spalten ableiten, z. B.:

```swift
let wantsOwnerGroup = settingsStore.visibleColumns.contains(.owner)
    || settingsStore.visibleColumns.contains(.group)
```

und `LocalFileSystem(fetchesOwnerGroup: wantsOwnerGroup)` übergeben. Die
realen Namen von Spalten-Enum und Settings-Zugriff aus dem Code übernehmen
(`FileColumn`-Fälle prüfen). `EditSessionManager` (Core) bleibt beim Standard
(kein Owner/Gruppe nötig).

- [ ] **Step 4: L10n**

Neue Keys in **allen vier** Katalogen (typografisch, kein ASCII-Quote in
nicht-englischen Werten):

EN:
```
"menu.newFile" = "New File…";
"sheet.newFile.title" = "New File";
"sheet.newFile.confirm" = "Create";
"sheet.newFile.defaultName" = "untitled.txt";
```
DE:
```
"menu.newFile" = "Neue Datei…";
"sheet.newFile.title" = "Neue Datei";
"sheet.newFile.confirm" = "Erstellen";
"sheet.newFile.defaultName" = "unbenannt.txt";
```
FR:
```
"menu.newFile" = "Nouveau fichier…";
"sheet.newFile.title" = "Nouveau fichier";
"sheet.newFile.confirm" = "Créer";
"sheet.newFile.defaultName" = "sans-titre.txt";
```
PL:
```
"menu.newFile" = "Nowy plik…";
"sheet.newFile.title" = "Nowy plik";
"sheet.newFile.confirm" = "Utwórz";
"sheet.newFile.defaultName" = "bez-nazwy.txt";
```

- [ ] **Step 5: Build + Verhalten**

Run: `swift build && swift test --filter Localizable`
Expected: 0 (neue) Warnungen, Parität grün. Verhalten per Codelesen: Ordner/Datei
anlegen schließt den Dialog sofort; Fehler halten ihn weiterhin offen; die Liste
aktualisiert sich kurz danach.

- [ ] **Step 6: Commit**

```bash
git add Sources/MacSCPApp
git commit -m "fix: dismiss the browser name sheet without waiting for the listing

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Task 5: Fenstergeometrie untersuchen (und nur bei eigener Ursache klemmen)

**Files:**
- Investigate/Modify: `Sources/MacSCPApp/ContentView.swift` (~1540–1570)

- [ ] **Step 1: Ursache belegen**

Beobachtet wurde ein wiederhergestellter Fensterrahmen bei `{-101, -1386}`
(außerhalb aller Bildschirme). **Erst klären, wer den Rahmen setzt:**
- Lies den Block um `window.setFrame(newFrame, display: true, animate: true)` (`ContentView.swift:1565`) samt der Herleitung von `newFrame` (M5c: Wachsen auf die gemerkte Browser-Größe). Kann daraus ein Rahmen außerhalb der sichtbaren Fläche entstehen (z. B. weil nur die Größe gemerkt wird, der Ursprung aber vom aktuellen Fenster stammt)?
- Prüfe, ob die App eigene Fenster-Wiederherstellung macht oder ob das macOS' Restaurierung ist (Suche nach `frameAutosaveName`, `NSWindowRestoration`, `restorationClass`, gespeicherten Frame-Werten im SettingsStore).

Halte im Bericht **fest, was du belegt hast**.

- [ ] **Step 2: Nur bei eigener Ursache klemmen**

Ist es unser `setFrame`: den Zielrahmen vor dem Setzen auf die sichtbare Fläche
klemmen — Bildschirm über `window.screen ?? NSScreen.main`, Fläche
`visibleFrame`, Ursprung so verschieben, dass der Rahmen vollständig sichtbar
liegt (und die Größe notfalls auf die Fläche begrenzen). Wenn die Logik in eine
kleine reine Funktion passt (`func clamped(_ frame: NSRect, to visible: NSRect) -> NSRect`),
lege sie so an und teste sie:

```swift
    @Test func frameOutsideVisibleAreaIsMovedBack() {
        let visible = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let offscreen = NSRect(x: -101, y: -1386, width: 1200, height: 800)
        let result = clamped(offscreen, to: visible)
        #expect(visible.contains(result))
    }
```

Ist es **macOS' eigene** Wiederherstellung: **nicht** umgehen — im Bericht
dokumentieren und diesen Task ohne Codeänderung abschließen.

- [ ] **Step 3: Build + Commit (falls geändert)**

Run: `swift build && swift test`
Expected: 0 Warnungen, grün.

```bash
git add Sources/MacSCPApp/ContentView.swift Tests/macSCPCoreTests
git commit -m "fix: keep the restored window frame on screen

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Task 6: Abschluss

- [ ] **Step 1: Volle Suite + 0 Warnungen**

Run: `swift build && swift test && swift test --filter Localizable`
Expected: alles grün, keine neuen Warnungen.

- [ ] **Step 2: Runtime-Verifikation des Bugs**

Dev-Build bauen (`MACSCP_VERSION=1.8.1-dev scripts/package-app`), starten,
im **lokalen** Bereich einen Ordner **und** eine Datei anlegen: Der Dialog muss
**sofort** schließen, der Eintrag danach in der Liste erscheinen. Zusätzlich
Idle-CPU messen (~0 %).

- [ ] **Step 3: Whole-Milestone-Review**

Opus-Review über `git merge-base develop HEAD`..HEAD (Basis = `a496a66`),
Fokus: Fehlerverhalten unverändert (Fehler halten den Dialog offen), Audit
vollständig, keine Protokolländerung, Tests angepasst statt gelöscht.

- [ ] **Step 4: Push + Dev-Build (auf Maintainer-Anordnung)**

---

## Self-Review

**1. Spec coverage:** A (Dialog wartet nicht) → Task 1 + Task 4 Step 1 ✅ · B (Owner/Gruppe opt-in) → Task 2 + Task 4 Step 3 ✅ · C („Neue Datei") → Task 3 + Task 4 Steps 2/4 ✅ · D (Fenster) → Task 5 ✅ · Tests → in jedem Task ✅ · Invarianten → Global Constraints + Task 6 ✅

**2. Placeholder scan:** Bewusst offen mit klarer „realen Namen übernehmen"-Anweisung: Fake-FS-Name und Konstruktion in den VM-Tests, `RemoteFileItem`-Feldnamen, `write`-Signatur/leerer Stream, Spalten-Enum-Fälle, die `AuditEvent.Kind`-switch-Stellen, und die reale Ursache in Task 5. Kein „TBD/TODO".

**3. Type consistency:** `refreshAndSelect(path:)`, `createFile(named:) -> String?`, `LocalFileSystem(fetchesOwnerGroup:)`, `BrowserMenuEntry.newFile`, `AuditEvent.Kind.newFile` — über alle Tasks konsistent verwendet.
