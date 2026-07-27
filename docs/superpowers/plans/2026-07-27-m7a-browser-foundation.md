# M7a — Browser-Fundament Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Drei neue FS-APIs (`rename`, `setPermissions`, rekursives `deleteTree`), Finder-artige Mehrfachauswahl und der „Versteckte Dateien"-Schalter — das Fundament, auf dem M7b das Kontextmenü baut.

**Architecture:** Protokoll-Erweiterung in `RemoteFileSystem` mit Implementierungen in `LocalFileSystem` (FileManager) und `CitadelFileSystem` (SFTP rename/setstat + Bottom-up-Walk); alle Test-Doubles ziehen mit. Multi-Select ersetzt `selectedItem` durch ein geordnetes `selectedItems`-Array (mit `selectedItem` als abgeleiteter Convenience). Der Hidden-Filter lebt als Anzeige-Filter im `RemoteBrowserViewModel`, gespeist aus einem neuen `SettingsStore`-Feld; ⌘⇧. kommt als App-Command (View-Menü).

**Tech Stack:** Swift 6 / `.swiftLanguageMode(.v5)`, Swift Testing, Citadel-SFTP (`rename(at:to:)`, `setAttributes(at:to:)`), AppKit-`NSTableView` im Representable.

## Global Constraints

- Spec: `docs/superpowers/specs/2026-07-27-m7a-browser-foundation-design.md` — bindend. Branch: **develop**.
- `rename(from:to:)`: `to` ist der VOLLE Zielpfad; existierendes Ziel ⇒ Fehler, KEIN stilles Überschreiben.
- `setPermissions`: nur die unteren 12 Bits (`permissions & 0o7777`), Typ-Bits nie schreiben.
- `deleteTree`: Symlinks werden GELÖSCHT, NIE gefolgt; kooperativ cancelbar (`Task.checkCancellation` pro Eintrag); Abbruch hinterlässt einen teilgelöschten Baum (dokumentiert).
- Versteckt-Filter: Anzeige-Schicht (ViewModel), Kriterium `name.hasPrefix(".")`; `SettingsStore.showHiddenFiles` Default `false`.
- Sicherheits-/Architektur-/Queue-Invarianten unangetastet; Code + Kommentare NUR Englisch; neue UI-Texte katalogisiert EN/DE (App: `Sources/MacSCPApp/Resources/*/Localizable.strings`).
- Conventional Commits (Englisch), Footer: `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- `swift build` + volle `swift test` nach jedem Task grün (Ausgangslage 317 Tests / 28 Suiten); gated Suiten (`MACSCP_ITEST=1`, Docker-Rig aus dem Haupt-Checkout) NUR beim Abschluss.
- TDD: neue Logik erst rot beweisen.
- Umgebungs-Hinweis: Bash-Fehler „claude-opus-4-8 is temporarily unavailable … cannot determine the safety" sind KEINE Permission-Denials — warten und identisch wiederholen.

## Schedule

T1 → T2 (Core-FS, T2 RISK) → T3 → T4 (App-Schicht) → T5 Abschluss (Koordinator).

---

### Task 1: FS-APIs `rename` + `setPermissions`

**Files:**
- Modify: `Sources/macSCPCore/RemoteFS/RemoteFileSystem.swift` (Protocol, nach `delete` Zeile 34)
- Modify: `Sources/macSCPCore/RemoteFS/LocalFileSystem.swift` (nach `delete`, Zeilen ~108–123 als Muster)
- Modify: `Sources/macSCPCore/SSH/CitadelFileSystem.swift` (nach `delete` Zeile ~290)
- Modify: `Tests/macSCPCoreTests/MockRemoteFileSystem.swift` (nach `createDirectory` Zeile ~104) und JEDES weitere `RemoteFileSystem`-konforme Test-Double: grep `git grep -ln ": RemoteFileSystem" Tests` — aktuell `TransferQueueViewModelTests.swift` (`QueueTestFS`), `TransferEngineTests.swift`, `EditSessionManagerTests.swift`, `RemoteBrowserViewModelTests.swift` (Konformitäts-Stubs analog `delete`)
- Test: `Tests/macSCPCoreTests/LocalFileSystemTests.swift`, `Tests/macSCPCoreTests/CitadelFileSystemIntegrationTests.swift` (gated)

**Interfaces:**
- Produces (T2/M7b verlassen sich exakt hierauf):
  - `func rename(from: String, to: String) async throws`
  - `func setPermissions(path: String, permissions: UInt32) async throws`

- [ ] **Step 1: Protocol erweitern** — in `RemoteFileSystem.swift` nach `delete`:

```swift
    /// Renames/moves the entry at `from` to the FULL destination path `to`.
    /// An existing destination is an error (`RemoteFSError`) — this call
    /// never silently overwrites. The UI builds same-directory paths for a
    /// rename; the protocol stays generic (M7a).
    func rename(from: String, to: String) async throws

    /// Sets the POSIX permission bits of the entry at `path`. Only the low
    /// 12 bits (rwx for owner/group/other + setuid/setgid/sticky) are
    /// applied — file-type bits are never written (M7a).
    func setPermissions(path: String, permissions: UInt32) async throws
```

- [ ] **Step 2: Failing Unit-Tests (Local)** — in `LocalFileSystemTests.swift` (bestehende tmp-Dir-Muster der Datei wiederverwenden):

```swift
    @Test func renameMovesFileAndRefusesExistingDestination() async throws {
        let dir = try makeTempDir()
        let fs = LocalFileSystem()
        let a = dir.appendingPathComponent("a.txt").path(percentEncoded: false)
        let b = dir.appendingPathComponent("b.txt").path(percentEncoded: false)
        try Data("x".utf8).write(to: URL(fileURLWithPath: a))
        try await fs.rename(from: a, to: b)
        #expect(!FileManager.default.fileExists(atPath: a))
        #expect(FileManager.default.fileExists(atPath: b))
        // Existing destination must be refused, source stays put.
        try Data("y".utf8).write(to: URL(fileURLWithPath: a))
        await #expect(throws: RemoteFSError.self) {
            try await fs.rename(from: a, to: b)
        }
        #expect(FileManager.default.fileExists(atPath: a))
    }

    @Test func renameMissingSourceThrowsNotFound() async throws {
        let dir = try makeTempDir()
        let fs = LocalFileSystem()
        await #expect(throws: RemoteFSError.self) {
            try await fs.rename(
                from: dir.appendingPathComponent("missing").path(percentEncoded: false),
                to: dir.appendingPathComponent("target").path(percentEncoded: false))
        }
    }

    @Test func setPermissionsAppliesLow12BitsOnly() async throws {
        let dir = try makeTempDir()
        let fs = LocalFileSystem()
        let f = dir.appendingPathComponent("p.txt").path(percentEncoded: false)
        try Data("x".utf8).write(to: URL(fileURLWithPath: f))
        // Type bits in the argument must be ignored (0o100000 = regular file).
        try await fs.setPermissions(path: f, permissions: 0o100640)
        let mode = try FileManager.default.attributesOfItem(atPath: f)[.posixPermissions] as? Int
        #expect(mode == 0o640)
    }
```

(Existiert in der Datei kein `makeTempDir`-Helper, den vorhandenen tmp-Setup-Stil der Datei übernehmen — Assertions unverändert.)

- [ ] **Step 3: Rot beweisen** — `swift test --filter LocalFileSystemTests` ⇒ Compile-Fehler (Protokoll-Konforme unvollständig) = rot.
- [ ] **Step 4: Local implementieren** — in `LocalFileSystem.swift` (Fehler über das vorhandene `Self.map(error, path:)`):

```swift
    /// Renames/moves to the FULL destination path. Refuses an existing
    /// destination — `moveItem` would too, but the explicit check yields a
    /// stable, mapped error instead of a Foundation-specific one.
    public func rename(from: String, to: String) async throws {
        guard FileManager.default.fileExists(atPath: from) else {
            throw RemoteFSError.notFound(path: from)
        }
        guard !FileManager.default.fileExists(atPath: to) else {
            throw RemoteFSError.protocolError(reason: "destination already exists: \(to)")
        }
        do {
            try FileManager.default.moveItem(atPath: from, toPath: to)
        } catch {
            throw Self.map(error, path: from)
        }
    }

    /// Applies only the low 12 permission bits; type bits are stripped.
    public func setPermissions(path: String, permissions: UInt32) async throws {
        guard FileManager.default.fileExists(atPath: path) else {
            throw RemoteFSError.notFound(path: path)
        }
        do {
            try FileManager.default.setAttributes(
                [.posixPermissions: Int(permissions & 0o7777)], ofItemAtPath: path)
        } catch {
            throw Self.map(error, path: path)
        }
    }
```

- [ ] **Step 5: Citadel implementieren** — in `CitadelFileSystem.swift` (Fehler über `Self.mapSFTPError(_:path:)`; Kollisionscheck explizit, weil OpenSSH-Rename je nach Server überschreiben kann):

```swift
    /// Renames/moves to the FULL destination path. The explicit existence
    /// probe keeps the no-silent-overwrite contract server-independent
    /// (SFTP rename semantics differ between servers).
    public func rename(from: String, to: String) async throws {
        if (try? await sftp.getAttributes(at: to)) != nil {
            throw RemoteFSError.protocolError(reason: "destination already exists: \(to)")
        }
        do {
            try await sftp.rename(at: from, to: to)
        } catch {
            throw Self.mapSFTPError(error, path: from)
        }
    }

    /// Sets only the low 12 permission bits via SFTP setstat.
    public func setPermissions(path: String, permissions: UInt32) async throws {
        var attributes = SFTPFileAttributes()
        attributes.permissions = permissions & 0o7777
        do {
            try await sftp.setAttributes(at: path, to: attributes)
        } catch {
            throw Self.mapSFTPError(error, path: path)
        }
    }
```

(Prüfen: hat `SFTPFileAttributes` keinen argumentlosen `public init`, dann `SFTPFileAttributes(size: nil, uidgid: nil, permissions: permissions & 0o7777, accessModificationTime: nil)` bzw. die tatsächlich vorhandene Init-Form verwenden — Verhalten identisch, im Report vermerken.)

- [ ] **Step 6: Doubles nachziehen** — `MockRemoteFileSystem` bekommt funktionierende In-Memory-Varianten (Dateien-Dictionary verschieben; permissions in einem `var permissionsByPath: [String: UInt32]` ablegen), die übrigen Test-Doubles minimale Stubs im Stil ihres vorhandenen `delete` (z. B. `throw RemoteFSError.protocolError(reason: "unsupported in this test double")` wo nie aufgerufen).
- [ ] **Step 7: Gated Integration-Tests** — in `CitadelFileSystemIntegrationTests.swift` (Muster der Datei: `MACSCP_ITEST`-Gate, eigener UUID-Pfad unter `/config`, Cleanup per docker-exec):

```swift
    @Test func renameAndSetPermissionsRoundtrip() async throws {
        // rename: upload a file, rename it, list shows only the new name;
        // renaming onto an existing name throws.
        // setPermissions: chmod 0o640, re-stat, permissions & 0o7777 == 0o640.
    }
```

Der Test wird VOLL ausformuliert (kein Kommentar-Gerüst) nach dem Vorbild der bestehenden `delete`-Integrationstests in derselben Datei; Assertions: Liste vorher/nachher, `#expect(throws:)` für die Kollision, `stat`-Permissions-Vergleich.

- [ ] **Step 8: Grün** — volle `swift test` (ungated; die gated Tests kompilieren, laufen aber erst in T5).
- [ ] **Step 9: Commit** — `feat: add rename and setPermissions to the file-system protocol`.

---

### Task 2: `deleteTree` (RISK)

**Files:**
- Modify: `Sources/macSCPCore/RemoteFS/RemoteFileSystem.swift`, `LocalFileSystem.swift`, `CitadelFileSystem.swift`, alle Test-Doubles (wie T1)
- Test: `Tests/macSCPCoreTests/LocalFileSystemTests.swift`, `Tests/macSCPCoreTests/MockRemoteFileSystemTests.swift`, `CitadelFileSystemIntegrationTests.swift` (gated)

**Interfaces:**
- Consumes: T1 gemergt (Protokollstand).
- Produces: `func deleteTree(at path: String) async throws` — M7b ruft genau diesen Namen.

- [ ] **Step 1: Protocol** — nach `setPermissions`:

```swift
    /// Recursively deletes the entry at `path` (file, symlink, or directory
    /// with its entire contents). Symlinks are deleted, NEVER followed — the
    /// walk cannot escape the subtree. Cooperatively cancellable per entry;
    /// a cancellation leaves a partially deleted tree in place (documented,
    /// M7a). A plain file behaves exactly like `delete`.
    func deleteTree(at path: String) async throws
```

- [ ] **Step 2: Failing Tests** — Local (`LocalFileSystemTests.swift`):

```swift
    @Test func deleteTreeRemovesNestedDirectoryButNeverFollowsSymlinks() async throws {
        let dir = try makeTempDir()
        let fs = LocalFileSystem()
        // outside/victim.txt must SURVIVE: tree/link points at outside.
        let outside = dir.appendingPathComponent("outside", isDirectory: true)
        let victim = outside.appendingPathComponent("victim.txt")
        let tree = dir.appendingPathComponent("tree", isDirectory: true)
        let sub = tree.appendingPathComponent("sub", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: victim)
        try Data("x".utf8).write(to: sub.appendingPathComponent("f.txt"))
        try FileManager.default.createSymbolicLink(
            at: tree.appendingPathComponent("link"), withDestinationURL: outside)

        try await fs.deleteTree(at: tree.path(percentEncoded: false))

        #expect(!FileManager.default.fileExists(atPath: tree.path(percentEncoded: false)))
        #expect(FileManager.default.fileExists(atPath: victim.path(percentEncoded: false)))
    }
```

Mock (`MockRemoteFileSystemTests.swift`): Baum im In-Memory-Mock anlegen, `deleteTree`, `list` des Parents zeigt den Eintrag nicht mehr; plus ein Cancellation-Test gegen den CITADEL-Walk gehört in die gated Suite (Step 5).

- [ ] **Step 3: Rot beweisen**, dann **Local implementieren** (Symlink-Check VOR removeItem entfällt — `removeItem` folgt Symlinks nicht, löscht den Link; genau das dokumentieren):

```swift
    /// Recursive delete. `FileManager.removeItem` is natively recursive and
    /// removes symlinks WITHOUT following them, which matches the protocol
    /// contract exactly. Cancellation granularity is the whole call here
    /// (Foundation offers no per-entry hook) — acceptable for local trees.
    public func deleteTree(at path: String) async throws {
        try Task.checkCancellation()
        guard FileManager.default.fileExists(atPath: path)
            || (try? FileManager.default.attributesOfItem(atPath: path)) != nil else {
            throw RemoteFSError.notFound(path: path)
        }
        do {
            try FileManager.default.removeItem(atPath: path)
        } catch {
            throw Self.map(error, path: path)
        }
    }
```

(Hinweis für den Implementer: `fileExists` folgt Symlinks — der `attributesOfItem`-Zweitcheck fängt dangling Symlinks, die trotzdem löschbar sein müssen.)

- [ ] **Step 4: Citadel implementieren** — Bottom-up-Walk:

```swift
    /// Recursive delete via bottom-up walk: SFTP has no recursive remove.
    /// Files and symlinks go through `remove` (a symlink is removed as the
    /// link itself — never followed, the walk descends only into REAL
    /// directories per the listed entry kind); directories are emptied
    /// first, then removed with rmdir. Cooperatively cancellable per entry;
    /// cancellation leaves a partially deleted tree (documented).
    public func deleteTree(at path: String) async throws {
        try Task.checkCancellation()
        let entry: RemoteFileItem
        do {
            entry = try await stat(path: path)
        } catch {
            throw Self.mapSFTPError(error, path: path)
        }
        guard entry.kind == .directory else {
            try await delete(path: path)
            return
        }
        let children: [RemoteFileItem]
        do {
            children = try await sftp.listDirectory(atPath: path)
                .flatMap { $0.components }
                .filter { $0.filename != "." && $0.filename != ".." }
                .map { Self.item(fromComponent: $0, parent: path) }
        } catch {
            throw Self.mapSFTPError(error, path: path)
        }
        for child in children {
            try Task.checkCancellation()
            if child.kind == .directory {
                try await deleteTree(at: child.path)
            } else {
                try await delete(path: child.path)
            }
        }
        do {
            try await sftp.rmdir(at: path)
        } catch {
            throw Self.mapSFTPError(error, path: path)
        }
    }
```

WICHTIG: Die Datei hat bereits eine `list`-Implementierung, die Komponenten zu `RemoteFileItem` mappt — deren vorhandenen Mapping-Helper wiederverwenden statt `Self.item(fromComponent:parent:)` neu zu erfinden (exakten Namen aus der Datei übernehmen; existiert kein separater Helper, `list(path:)` selbst aufrufen). `rmdir`-Signatur aus Citadel prüfen (`rmdir(at:)` — tatsächliche Parameter-Labels übernehmen). Abweichungen im Report dokumentieren.

- [ ] **Step 5: Gated Tests** (`CitadelFileSystemIntegrationTests.swift`): (a) verschachtelter Baum (2 Ebenen, Dateien + leeres Unterverzeichnis + Symlink AUF eine Datei außerhalb, per docker-exec `ln -s` angelegt) → `deleteTree` → Baum weg, Symlink-ZIEL existiert weiter (docker-exec `test -f`); (b) Cancellation: großen Baum anlegen (docker-exec, ~50 Dateien), `deleteTree` in Task starten, sofort canceln → wirft `CancellationError` (oder endet regulär, wenn der Walk schneller war — Assertion tolerant wie die bestehenden Cancel-Tests der Datei) und der Server-Zustand ist konsistent (Rest lässt sich mit zweitem `deleteTree` aufräumen).
- [ ] **Step 6: Doubles nachziehen** (Mock: rekursiv aus dem Dictionary; übrige Stubs wie T1).
- [ ] **Step 7: Grün** — volle `swift test`.
- [ ] **Step 8: Commit** — `feat: add recursive deleteTree to the file-system protocol`.

---

### Task 3: Multi-Select

**Files:**
- Modify: `Sources/MacSCPApp/RemoteFileTableView.swift` (Zeile 30 `allowsMultipleSelection`, Selektions-Callback Zeilen 12, 68, 86–94, 179–180)
- Modify: `Sources/macSCPCore/Presentation/RemoteBrowserViewModel.swift` (Zeilen 19–21, `load()` Zeile 32)
- Modify: `Sources/MacSCPApp/ContentView.swift` (`uploadButton`/`downloadButton`, `pasteboardWriter`-Callsites bleiben — NSTableView liefert Multi-Drag automatisch pro Zeile)
- Test: `Tests/macSCPCoreTests/RemoteBrowserViewModelTests.swift`

**Interfaces:**
- Produces: `RemoteBrowserViewModel.selectedItems: [RemoteFileItem]` (geordnet, Quelle der Wahrheit) und `selectedItem: RemoteFileItem?` als abgeleitete Convenience (`selectedItems.count == 1 ? selectedItems[0] : nil`) — M7b nutzt BEIDE.

- [ ] **Step 1: Failing VM-Test:**

```swift
    @Test @MainActor func selectedItemDerivesFromSelectedItems() async {
        let vm = RemoteBrowserViewModel(fs: MockRemoteFileSystem())
        let a = RemoteFileItem(name: "a", path: "/a", kind: .file, size: 1)
        let b = RemoteFileItem(name: "b", path: "/b", kind: .file, size: 1)
        vm.selectedItems = [a]
        #expect(vm.selectedItem == a)
        vm.selectedItems = [a, b]
        #expect(vm.selectedItem == nil)
        vm.selectedItems = []
        #expect(vm.selectedItem == nil)
    }
```

- [ ] **Step 2: Rot, dann VM umbauen:**

```swift
    /// Currently selected entries, in table order (M7a multi-select).
    /// The single source of truth for selection.
    public var selectedItems: [RemoteFileItem] = []

    /// Single-selection convenience: non-nil exactly when ONE row is
    /// selected. Double-click/editor paths keep using this.
    public var selectedItem: RemoteFileItem? {
        selectedItems.count == 1 ? selectedItems[0] : nil
    }
```

`load()` setzt `selectedItems = []` (statt `selectedItem = nil`). ACHTUNG: `selectedItem` war bisher gesetzt-bar (`public var`) — grep alle Zuweisungen (`git grep -n "selectedItem =" Sources Tests`) und stelle sie auf `selectedItems` um.

- [ ] **Step 3: Tabelle** — `allowsMultipleSelection = true` (Zeile 30); Callback-Typ wird `onSelect: ([RemoteFileItem]) -> Void`; in `tableViewSelectionDidChange`:

```swift
            let rows = table.selectedRowIndexes
            onSelect(rows.compactMap { $0 < items.count ? items[$0] : nil })
```

Callsites in `BrowserPane`/`ContentView` binden `viewModel.selectedItems = $0`.

- [ ] **Step 4: Toolbar-Buttons** (`ContentView.uploadButton`/`downloadButton`): statt `selected == nil || kind == .symlink`-Disable gilt: enabled, wenn `session.local.selectedItems.contains { $0.kind != .symlink }` (bzw. remote); die Action iteriert über `selectedItems`, Datei → `enqueue`, Ordner → `enqueueTree`, Symlink → überspringen (still). `onCompleted`-Refresh wie bisher pro Item.
- [ ] **Step 5: Grün** — volle Suite; `swift build` warnungsfrei bzgl. der geänderten Dateien.
- [ ] **Step 6: Commit** — `feat: multi-select in both file panes`.

---

### Task 4: Versteckte Dateien

**Files:**
- Modify: `Sources/macSCPCore/Settings/SettingsStore.swift` (neues Feld nach `downloadLimitKBs` Zeile ~121, gleiches didSet/persist-Muster)
- Modify: `Sources/macSCPCore/Presentation/RemoteBrowserViewModel.swift` (Filter in `load()`)
- Modify: `Sources/MacSCPApp/SettingsView.swift` (neuer Tab „Allgemein" VOR „Transfers", Zeilen 14–27)
- Modify: `Sources/MacSCPApp/MacSCPApp.swift` (Commands-Block für ⌘⇧.)
- Modify: `Sources/MacSCPApp/ContentView.swift` (Wiring Store→VMs, onChange + Session-Start, analog der Limit-Verdrahtung Zeilen ~248–256/474–476)
- Modify: `Sources/MacSCPApp/Resources/en.lproj/Localizable.strings` + `de.lproj`
- Test: `Tests/macSCPCoreTests/SettingsStoreTests.swift`, `Tests/macSCPCoreTests/RemoteBrowserViewModelTests.swift`

**Interfaces:**
- Consumes: T3 (`selectedItems`-Reset in `load()`).
- Produces: `SettingsStore.showHiddenFiles: Bool` (Default `false`, persistiert); `RemoteBrowserViewModel.showHiddenFiles: Bool` (Default `false`; Änderung erfordert `refresh()` durch den Aufrufer).

- [ ] **Step 1: Failing Tests:**

```swift
    // SettingsStoreTests: defaults false, persists, survives reload.
    @Test func showHiddenFilesDefaultsFalseAndPersists() throws {
        let dir = try makeTempDir()
        let store = SettingsStore(directory: dir)
        #expect(store.showHiddenFiles == false)
        store.showHiddenFiles = true
        let reloaded = SettingsStore(directory: dir)
        #expect(reloaded.showHiddenFiles == true)
    }

    // RemoteBrowserViewModelTests: dotfiles filtered unless enabled.
    @Test @MainActor func loadFiltersDotfilesUnlessShowHiddenIsOn() async {
        let fs = MockRemoteFileSystem()
        fs.entries["/"] = [
            RemoteFileItem(name: ".env", path: "/.env", kind: .file, size: 1),
            RemoteFileItem(name: "visible.txt", path: "/visible.txt", kind: .file, size: 1),
        ]
        let vm = RemoteBrowserViewModel(fs: fs)
        await vm.load()
        #expect(vm.items.map(\.name) == ["visible.txt"])
        vm.showHiddenFiles = true
        await vm.load()
        #expect(vm.items.map(\.name) == [".env", "visible.txt"])
    }
```

(Mock-Zugriff auf die Einträge dem tatsächlichen `MockRemoteFileSystem`-API anpassen — Assertions unverändert; Sortierung: Verzeichnisse zuerst, dann case-insensitiv — `.env` vor `visible.txt`.)

- [ ] **Step 2: Rot, dann implementieren:**

SettingsStore (Muster von `uploadLimitKBs` kopieren — Feld, didSet→persist, Encode/Decode vorwärtskompatibel):

```swift
    /// Show dotfiles in both panes (M7a). Default OFF — the Finder-like
    /// default; ⌘⇧. and the General settings tab toggle it.
    public var showHiddenFiles: Bool {
        didSet { persist() }
    }
```

VM in `load()` nach dem `list`:

```swift
            let visible = showHiddenFiles
                ? listed
                : listed.filter { !$0.name.hasPrefix(".") }
            items = Self.sortedForDisplay(visible)
```

plus Property:

```swift
    /// Display filter for dotfiles (M7a). The caller re-`load()`s after
    /// changing it — the filter is presentation-only, never in the FS layer.
    public var showHiddenFiles = false
```

- [ ] **Step 3: Settings-Tab „Allgemein"** — in `SettingsView.swift` neuer erster Tab:

```swift
            GeneralSettingsTab(store: store)
                .tabItem {
                    Label(
                        L10n.string("settings.tab.general", "General"),
                        systemImage: "gearshape")
                }
```

```swift
/// General app options (M7a): currently the hidden-files toggle.
private struct GeneralSettingsTab: View {
    @Bindable var store: SettingsStore

    var body: some View {
        Form {
            Toggle(
                L10n.string("settings.general.showHidden", "Show hidden files"),
                isOn: $store.showHiddenFiles)
            Text(L10n.string(
                "settings.general.showHiddenHint",
                "Applies to both panes. Shortcut: ⌘⇧."))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(20)
    }
}
```

Keys EN: `"settings.tab.general" = "General"; "settings.general.showHidden" = "Show hidden files"; "settings.general.showHiddenHint" = "Applies to both panes. Shortcut: ⌘⇧.";` — DE: `"Allgemein"`, `"Versteckte Dateien anzeigen"`, `"Gilt für beide Seiten. Kürzel: ⌘⇧."`.

- [ ] **Step 4: ⌘⇧.-Command** — in `MacSCPApp.swift` am `WindowGroup`:

```swift
        .commands {
            CommandGroup(after: .sidebar) {
                Button(L10n.string("menu.toggleHidden", "Show/Hide Hidden Files")) {
                    settingsStore.showHiddenFiles.toggle()
                }
                .keyboardShortcut(".", modifiers: [.command, .shift])
            }
        }
```

Keys: EN `"menu.toggleHidden" = "Show/Hide Hidden Files";` DE `"Versteckte Dateien ein-/ausblenden";`.

- [ ] **Step 5: Wiring** — in `ContentView`: bei `startSession` beide VMs setzen (`local.showHiddenFiles = settingsStore.showHiddenFiles`, remote ebenso) und ein `.onChange(of: settingsStore.showHiddenFiles)` neben den Limit-Observern, das beide VMs der AKTUELLEN Session setzt und `refresh()` beider Panes anstößt (`Task { await session.local.refresh(); await session.remote.refresh() }`; ohne Session no-op).
- [ ] **Step 6: Grün** — volle Suite.
- [ ] **Step 7: Commit** — `feat: hidden-files toggle with settings tab and shortcut`.

---

### Task 5: Abschluss-Verifikation (Koordinator, kein Subagent)

- [ ] Docker-Rig starten (Haupt-Checkout!), `MACSCP_ITEST=1 MACSCP_KEYCHAIN=1 swift test` ⇒ komplett grün (inkl. der neuen gated rename/chmod/deleteTree-Tests).
- [ ] Visueller Smoke (Dev-Wrapper neu bauen): Multi-Select per ⌘-Klick beide Panes; Übertragen einer 3er-Auswahl (Queue zeigt 3 Items); Symlink in Auswahl wird übersprungen; versteckte Dateien: Standard AUS (Home zeigt KEINE Dotfiles mehr — die augenfälligste Änderung), ⌘⇧. blendet ein/aus (beide Panes), Settings-Tab „Allgemein" DE/EN-Texte; Doppelklick-Editor (nutzt `selectedItem`) funktioniert weiter.
- [ ] Plan-Checkboxen, Ledger, Opus-Whole-Branch-Final-Review (Base = Commit vor T1 auf develop), Fixes, Push develop, `gh run watch` (ci.yml läuft auch auf develop? prüfen — ci.yml triggert nur push auf main + PRs: dann `swift test`-Beleg lokal genügt bzw. ci.yml um develop erweitern als Teil dieses Tasks), Rig `stop`, Memory-Update, Milestone-Zusammenfassung.
