# macSCP M2a — Remote-Browser-App Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Eine startbare SwiftUI-macOS-App mit Verbindungsdialog und Remote-Datei-Browser (read-only) auf Basis des M1-Cores.

**Architecture:** Neues SPM-Executable-Target `MacSCPApp` (SwiftUI, `@main App`); ViewModels (`@Observable`, `@MainActor`) und Formatierung liegen UI-unabhängig in `macSCPCore/Presentation` und werden gegen den vorhandenen `MockRemoteFileSystem` getestet. Die Dateiliste ist ein AppKit-`NSTableView` via `NSViewRepresentable` (Spec-Vorgabe: SwiftUI-Listen brechen bei großen Verzeichnissen ein). Produktions-Verbindung via `CitadelFileSystem.connect`.

**Tech Stack:** Swift 6-Toolchain (Language Mode v5), SwiftUI + AppKit (macOS 14+), Observation-Framework, Citadel (bereits Dependency), Swift Testing.

## Global Constraints

- swift-tools-version 6.0, alle Targets `swiftSettings: [.swiftLanguageMode(.v5)]` (wie in `Package.swift` etabliert)
- Plattform: macOS 14 (`.macOS(.v14)`)
- Conventional Commits, Footer `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`; niemals pushen (macht der Koordinator)
- UI-Texte auf Deutsch
- YAGNI für M2a: KEINE Keychain, KEIN TOFU/Host-Key-UI, KEINE Transfers, KEIN lokales Pane, KEIN Drag & Drop, KEINE Session-Persistenz — alles spätere Meilensteine (M2b/M3)
- Integrationstest-Gate `MACSCP_ITEST=1` und Docker-Rig (`docker compose -f docker/test-server/compose.yml up -d`, testuser/testpass, Port 2222) bleiben unverändert
- Nach jedem Task: kompletter `swift test` muss grün sein (Unit-Suite läuft ohne Docker)

## Datei-Landkarte (Ende M2a)

```
Sources/
  macSCPCore/
    Presentation/
      FileListFormatter.swift        (neu, Task 2 — pure Anzeige-Formatierung)
      ConnectionViewModel.swift      (neu, Task 3 — Formular-Zustand + Fehlertexte)
      RemoteBrowserViewModel.swift   (neu, Task 4 — Pfad/Liste/Navigation)
    RemoteFS/…, SSH/…                (unverändert aus M1)
  MacSCPApp/
    MacSCPApp.swift                  (neu, Task 1 — @main App)
    RemoteFileTableView.swift        (neu, Task 5 — NSTableView-Wrapper)
    ConnectionFormView.swift         (neu, Task 6)
    BrowserView.swift                (neu, Task 6)
    ContentView.swift                (neu, Task 6)
  MacSCPCLI/…                        (unverändert)
Tests/macSCPCoreTests/
  FileListFormatterTests.swift       (neu, Task 2)
  ConnectionViewModelTests.swift     (neu, Task 3)
  RemoteBrowserViewModelTests.swift  (neu, Task 4)
```

---

### Task 1: App-Target-Gerüst

**Files:**
- Modify: `Package.swift`
- Create: `Sources/MacSCPApp/MacSCPApp.swift`

**Interfaces:**
- Consumes: nichts Neues (Target hängt nur von `macSCPCore` ab)
- Produces: Executable-Product `macSCP`, Modul `MacSCPApp`; `@main struct MacSCPApp: App` — Task 6 ersetzt dessen `body`-Inhalt

- [x] **Step 1: Package.swift erweitern**

In `Package.swift` unter `products:` ergänzen (nach dem bestehenden `macscp-cli`-Eintrag):

```swift
        .executable(name: "macSCP", targets: ["MacSCPApp"]),
```

und unter `targets:` (nach dem `MacSCPCLI`-Target):

```swift
        .executableTarget(
            name: "MacSCPApp",
            dependencies: ["macSCPCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
```

- [x] **Step 2: Minimale App**

`Sources/MacSCPApp/MacSCPApp.swift`:

```swift
import SwiftUI

@main
struct MacSCPApp: App {
    init() {
        // Ohne App-Bundle (Start via `swift run`) läuft der Prozess als
        // Accessory — erst die Regular-Policy bringt Fenster und Dock-Icon.
        // Echtes .app-Bundle kommt in M6.
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    var body: some Scene {
        WindowGroup("macSCP") {
            Text("macSCP — M2 in Arbeit")
                .padding()
                .frame(minWidth: 480, minHeight: 320)
        }
    }
}
```

- [x] **Step 3: Bauen und Tests**

Run: `swift build && swift test`
Expected: `Build complete!`, 25 Tests grün (Integrationssuite ohne Docker übersprungen)

- [x] **Step 4: Manueller Smoke-Test**

Run: `swift run macSCP` (aus `/Users/noidee/macSCP`)
Expected: Fenster „macSCP" mit Text „macSCP — M2 in Arbeit" erscheint; mit Cmd+Q beenden. (In Headless-Umgebung: Prozess startet ohne Crash; nach ~5 s mit Ctrl+C beenden und das als Erfolg werten.)

- [x] **Step 5: Commit**

```bash
git add Package.swift Sources/MacSCPApp/MacSCPApp.swift
git commit -m "feat: add SwiftUI app target with placeholder window

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: FileListFormatter

**Files:**
- Create: `Sources/macSCPCore/Presentation/FileListFormatter.swift`
- Test: `Tests/macSCPCoreTests/FileListFormatterTests.swift`

**Interfaces:**
- Consumes: `RemoteFileItem` (M1: `name`, `path`, `kind`, `size: UInt64?`, `modifiedAt: Date?`, `isDirectory`)
- Produces: `public enum FileListFormatter` mit `sizeString(for: RemoteFileItem) -> String`, `dateString(for: RemoteFileItem) -> String`, `displayName(for: RemoteFileItem) -> String` — genutzt von Task 5 (Tabelle)

- [x] **Step 1: Fehlschlagende Tests**

`Tests/macSCPCoreTests/FileListFormatterTests.swift`:

```swift
import Foundation
import Testing
@testable import macSCPCore

@Suite("FileListFormatter")
struct FileListFormatterTests {
    private let dir = RemoteFileItem(name: "docs", path: "/docs", kind: .directory, size: 96)
    private let file = RemoteFileItem(
        name: "a.txt", path: "/a.txt", kind: .file,
        size: 1536, modifiedAt: Date(timeIntervalSince1970: 0)
    )
    private let bare = RemoteFileItem(name: "b", path: "/b", kind: .file)

    @Test func directoriesShowDashInsteadOfInodeSize() {
        #expect(FileListFormatter.sizeString(for: dir) == "-")
    }

    @Test func missingSizeShowsDash() {
        #expect(FileListFormatter.sizeString(for: bare) == "-")
    }

    @Test func fileSizeIsFormatted() {
        let s = FileListFormatter.sizeString(for: file)
        #expect(s != "-")
        #expect(s.contains(where: \.isNumber))
    }

    @Test func missingDateShowsDash() {
        #expect(FileListFormatter.dateString(for: bare) == "-")
    }

    @Test func presentDateIsFormatted() {
        let s = FileListFormatter.dateString(for: file)
        #expect(s != "-")
        #expect(s.contains("19") || s.contains("70"))  // 1970, locale-tolerant
    }

    @Test func directoryDisplayNameGetsSlash() {
        #expect(FileListFormatter.displayName(for: dir) == "docs/")
        #expect(FileListFormatter.displayName(for: file) == "a.txt")
    }
}
```

- [x] **Step 2: Rot verifizieren**

Run: `swift test --filter FileListFormatterTests`
Expected: Compile-Fehler `cannot find 'FileListFormatter' in scope`

- [x] **Step 3: Implementieren**

`Sources/macSCPCore/Presentation/FileListFormatter.swift`:

```swift
import Foundation

/// Formatiert RemoteFileItem-Felder für die Dateiliste. Pur, damit testbar.
/// Verzeichnisse zeigen "-" statt ihrer Inode-Größe (wie WinSCP).
public enum FileListFormatter {
    private static let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f
    }()

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    public static func sizeString(for item: RemoteFileItem) -> String {
        guard !item.isDirectory, let size = item.size else { return "-" }
        return byteFormatter.string(fromByteCount: Int64(size))
    }

    public static func dateString(for item: RemoteFileItem) -> String {
        guard let date = item.modifiedAt else { return "-" }
        return dateFormatter.string(from: date)
    }

    public static func displayName(for item: RemoteFileItem) -> String {
        item.isDirectory ? item.name + "/" : item.name
    }
}
```

- [x] **Step 4: Grün verifizieren**

Run: `swift test --filter FileListFormatterTests`
Expected: 6 Tests PASS

- [x] **Step 5: Gesamtsuite + Commit**

Run: `swift test` — Expected: 31 Tests grün.

```bash
git add Sources/macSCPCore/Presentation/FileListFormatter.swift Tests/macSCPCoreTests/FileListFormatterTests.swift
git commit -m "feat: add display formatting for remote file listings

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 3: ConnectionViewModel

**Files:**
- Create: `Sources/macSCPCore/Presentation/ConnectionViewModel.swift`
- Test: `Tests/macSCPCoreTests/ConnectionViewModelTests.swift`

**Interfaces:**
- Consumes: `SSHConnectionConfig` (M1, wirft `ConfigError`), `RemoteFSError`, `RemoteFileSystem`-Protocol, im Test `MockRemoteFileSystem`
- Produces: `public final class ConnectionViewModel` (`@Observable`, `@MainActor`) mit Feldern `host/port/username/password: String`, `state: ConnectionViewModel.State` (`.idle/.connecting/.failed(message:)`), `init(connector:)`, `func connect() async -> (any RemoteFileSystem)?` und `typealias Connector = @Sendable (SSHConnectionConfig) async throws -> any RemoteFileSystem` — genutzt von Task 6 (Formular + ContentView)

- [x] **Step 1: Fehlschlagende Tests**

`Tests/macSCPCoreTests/ConnectionViewModelTests.swift`:

```swift
import Foundation
import Testing
@testable import macSCPCore

@Suite("ConnectionViewModel")
@MainActor
struct ConnectionViewModelTests {
    private func makeVM(
        connector: @escaping ConnectionViewModel.Connector = { _ in
            MockRemoteFileSystem(tree: ["/": []])
        }
    ) -> ConnectionViewModel {
        let vm = ConnectionViewModel(connector: connector)
        vm.host = "example.com"
        vm.port = "22"
        vm.username = "tim"
        vm.password = "geheim"
        return vm
    }

    @Test func successReturnsFileSystemAndResetsState() async {
        let vm = makeVM()
        let fs = await vm.connect()
        #expect(fs != nil)
        #expect(vm.state == .idle)
    }

    @Test func nonNumericPortFailsWithGermanMessage() async {
        let vm = makeVM()
        vm.port = "abc"
        let fs = await vm.connect()
        #expect(fs == nil)
        #expect(vm.state == .failed(message: "Port muss eine Zahl sein."))
    }

    @Test func emptyHostFailsWithGermanMessage() async {
        let vm = makeVM()
        vm.host = ""
        _ = await vm.connect()
        #expect(vm.state == .failed(message: "Host darf nicht leer sein."))
    }

    @Test func emptyPasswordFailsBeforeConnecting() async {
        let vm = makeVM(connector: { _ in
            Issue.record("Connector darf bei leerem Passwort nicht aufgerufen werden")
            throw RemoteFSError.connectionFailed(reason: "unreachable")
        })
        vm.password = ""
        _ = await vm.connect()
        #expect(vm.state == .failed(message: "Passwort darf nicht leer sein."))
    }

    @Test func authFailureMapsToGermanMessage() async {
        let vm = makeVM(connector: { _ in throw RemoteFSError.authenticationFailed })
        let fs = await vm.connect()
        #expect(fs == nil)
        #expect(vm.state == .failed(
            message: "Anmeldung fehlgeschlagen — Benutzername oder Passwort prüfen."))
    }

    @Test func connectionFailureMapsToGermanMessage() async {
        let vm = makeVM(connector: { _ in
            throw RemoteFSError.connectionFailed(reason: "timeout")
        })
        _ = await vm.connect()
        #expect(vm.state == .failed(message: "Verbindung fehlgeschlagen: timeout"))
    }
}
```

- [x] **Step 2: Rot verifizieren**

Run: `swift test --filter ConnectionViewModelTests`
Expected: Compile-Fehler `cannot find 'ConnectionViewModel' in scope`

- [x] **Step 3: Implementieren**

`Sources/macSCPCore/Presentation/ConnectionViewModel.swift`:

```swift
import Foundation
import Observation

/// Zustand und Logik des Verbindungsformulars.
/// Der Connector ist injizierbar: Produktion nutzt CitadelFileSystem.connect,
/// Tests einen Mock — das ViewModel bleibt ohne Netz testbar.
@Observable
@MainActor
public final class ConnectionViewModel {
    public enum State: Equatable {
        case idle
        case connecting
        case failed(message: String)
    }

    public typealias Connector = @Sendable (SSHConnectionConfig) async throws -> any RemoteFileSystem

    public var host: String = ""
    public var port: String = "22"
    public var username: String = ""
    public var password: String = ""
    public private(set) var state: State = .idle

    private let connector: Connector

    public init(connector: @escaping Connector) {
        self.connector = connector
    }

    /// Liefert das verbundene Dateisystem oder nil; Fehler landen in `state`.
    public func connect() async -> (any RemoteFileSystem)? {
        guard let portNumber = Int(port.trimmingCharacters(in: .whitespaces)) else {
            state = .failed(message: "Port muss eine Zahl sein.")
            return nil
        }
        guard !password.isEmpty else {
            state = .failed(message: "Passwort darf nicht leer sein.")
            return nil
        }
        do {
            let config = try SSHConnectionConfig(
                host: host, port: portNumber, username: username, auth: .password(password)
            )
            state = .connecting
            let fs = try await connector(config)
            state = .idle
            return fs
        } catch {
            state = .failed(message: Self.message(for: error))
            return nil
        }
    }

    static func message(for error: Error) -> String {
        switch error {
        case SSHConnectionConfig.ConfigError.emptyHost:
            return "Host darf nicht leer sein."
        case SSHConnectionConfig.ConfigError.emptyUsername:
            return "Benutzername darf nicht leer sein."
        case SSHConnectionConfig.ConfigError.invalidPort(let port):
            return "Ungültiger Port: \(port)."
        case RemoteFSError.authenticationFailed:
            return "Anmeldung fehlgeschlagen — Benutzername oder Passwort prüfen."
        case RemoteFSError.connectionFailed(let reason):
            return "Verbindung fehlgeschlagen: \(reason)"
        default:
            return "Unerwarteter Fehler: \(String(describing: error))"
        }
    }
}
```

- [x] **Step 4: Grün verifizieren**

Run: `swift test --filter ConnectionViewModelTests`
Expected: 6 Tests PASS

- [x] **Step 5: Gesamtsuite + Commit**

Run: `swift test` — Expected: 37 Tests grün.

```bash
git add Sources/macSCPCore/Presentation/ConnectionViewModel.swift Tests/macSCPCoreTests/ConnectionViewModelTests.swift
git commit -m "feat: add connection form view model with typed error messages

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 4: RemoteBrowserViewModel

**Files:**
- Create: `Sources/macSCPCore/Presentation/RemoteBrowserViewModel.swift`
- Test: `Tests/macSCPCoreTests/RemoteBrowserViewModelTests.swift`

**Interfaces:**
- Consumes: `RemoteFileSystem`-Protocol (`list/stat/disconnect`), `RemotePath.parent(of:)`, `RemoteFSError`; im Test `MockRemoteFileSystem`
- Produces: `public final class RemoteBrowserViewModel` (`@Observable`, `@MainActor`): `currentPath: String`, `items: [RemoteFileItem]`, `state: RemoteBrowserViewModel.State` (`.loading/.loaded/.failed(message:)`), `canGoUp: Bool`, `init(fs:startPath:)`, `load()`, `open(_:)`, `goUp()`, `refresh()`, `disconnect()` — genutzt von Task 6 (BrowserView) und Task 5 (Items-Quelle)

- [x] **Step 1: Fehlschlagende Tests**

`Tests/macSCPCoreTests/RemoteBrowserViewModelTests.swift`:

```swift
import Testing
@testable import macSCPCore

@Suite("RemoteBrowserViewModel")
@MainActor
struct RemoteBrowserViewModelTests {
    private func makeFS() -> MockRemoteFileSystem {
        MockRemoteFileSystem(tree: [
            "/": [
                RemoteFileItem(name: "zebra.txt", path: "/zebra.txt", kind: .file, size: 1),
                RemoteFileItem(name: "Alpha", path: "/Alpha", kind: .directory),
                RemoteFileItem(name: "beta.txt", path: "/beta.txt", kind: .file, size: 2),
            ],
            "/Alpha": [
                RemoteFileItem(name: "inner.md", path: "/Alpha/inner.md", kind: .file, size: 3),
            ],
        ])
    }

    @Test func loadSortsDirectoriesFirstThenCaseInsensitive() async {
        let vm = RemoteBrowserViewModel(fs: makeFS())
        await vm.load()
        #expect(vm.state == .loaded)
        #expect(vm.items.map(\.name) == ["Alpha", "beta.txt", "zebra.txt"])
    }

    @Test func openDirectoryNavigatesAndLoads() async {
        let vm = RemoteBrowserViewModel(fs: makeFS())
        await vm.load()
        let alpha = vm.items[0]
        await vm.open(alpha)
        #expect(vm.currentPath == "/Alpha")
        #expect(vm.items.map(\.name) == ["inner.md"])
    }

    @Test func openFileIsNoOp() async {
        let vm = RemoteBrowserViewModel(fs: makeFS())
        await vm.load()
        let file = vm.items[1]
        await vm.open(file)
        #expect(vm.currentPath == "/")
    }

    @Test func goUpNavigatesToParent() async {
        let vm = RemoteBrowserViewModel(fs: makeFS(), startPath: "/Alpha")
        await vm.load()
        #expect(vm.canGoUp)
        await vm.goUp()
        #expect(vm.currentPath == "/")
        #expect(vm.items.count == 3)
    }

    @Test func goUpAtRootIsNoOp() async {
        let vm = RemoteBrowserViewModel(fs: makeFS())
        await vm.load()
        #expect(!vm.canGoUp)
        await vm.goUp()
        #expect(vm.currentPath == "/")
    }

    @Test func missingPathYieldsGermanNotFoundMessage() async {
        let vm = RemoteBrowserViewModel(fs: makeFS(), startPath: "/nope")
        await vm.load()
        #expect(vm.state == .failed(message: "Pfad nicht gefunden: /nope"))
        #expect(vm.items.isEmpty)
    }
}
```

- [x] **Step 2: Rot verifizieren**

Run: `swift test --filter RemoteBrowserViewModelTests`
Expected: Compile-Fehler `cannot find 'RemoteBrowserViewModel' in scope`

- [x] **Step 3: Implementieren**

`Sources/macSCPCore/Presentation/RemoteBrowserViewModel.swift`:

```swift
import Foundation
import Observation

/// Zustand des Remote-Browsers: aktueller Pfad, sortierte Einträge,
/// Lade-/Fehlerzustand. Arbeitet ausschließlich gegen das Protocol.
@Observable
@MainActor
public final class RemoteBrowserViewModel {
    public enum State: Equatable {
        case loading
        case loaded
        case failed(message: String)
    }

    public private(set) var currentPath: String
    public private(set) var items: [RemoteFileItem] = []
    public private(set) var state: State = .loading

    private let fs: any RemoteFileSystem

    public init(fs: any RemoteFileSystem, startPath: String = "/") {
        self.fs = fs
        self.currentPath = startPath
    }

    public var canGoUp: Bool { currentPath != "/" }

    public func load() async {
        state = .loading
        do {
            let listed = try await fs.list(path: currentPath)
            items = Self.sortedForDisplay(listed)
            state = .loaded
        } catch {
            items = []
            state = .failed(message: Self.message(for: error, path: currentPath))
        }
    }

    public func open(_ item: RemoteFileItem) async {
        guard item.isDirectory else { return }
        currentPath = item.path
        await load()
    }

    public func goUp() async {
        guard canGoUp else { return }
        currentPath = RemotePath.parent(of: currentPath)
        await load()
    }

    public func refresh() async {
        await load()
    }

    public func disconnect() async {
        await fs.disconnect()
    }

    /// Verzeichnisse zuerst, dann Name case-insensitiv —
    /// einheitlich für alle Backends (Mock sortiert nicht, Citadel schon).
    static func sortedForDisplay(_ items: [RemoteFileItem]) -> [RemoteFileItem] {
        items.sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    static func message(for error: Error, path: String) -> String {
        switch error {
        case RemoteFSError.notFound:
            return "Pfad nicht gefunden: \(path)"
        case RemoteFSError.permissionDenied:
            return "Keine Berechtigung für: \(path)"
        case RemoteFSError.protocolError(let reason):
            return "Protokollfehler: \(reason)"
        case RemoteFSError.connectionFailed(let reason):
            return "Verbindung verloren: \(reason)"
        default:
            return "Unerwarteter Fehler: \(String(describing: error))"
        }
    }
}
```

- [x] **Step 4: Grün verifizieren**

Run: `swift test --filter RemoteBrowserViewModelTests`
Expected: 6 Tests PASS

- [x] **Step 5: Gesamtsuite + Commit**

Run: `swift test` — Expected: 43 Tests grün.

```bash
git add Sources/macSCPCore/Presentation/RemoteBrowserViewModel.swift Tests/macSCPCoreTests/RemoteBrowserViewModelTests.swift
git commit -m "feat: add remote browser view model with navigation and sorting

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 5: RemoteFileTableView (NSTableView-Wrapper)

**Files:**
- Create: `Sources/MacSCPApp/RemoteFileTableView.swift`

**Interfaces:**
- Consumes: `RemoteFileItem`, `FileListFormatter` (Task 2)
- Produces: `struct RemoteFileTableView: NSViewRepresentable` mit `items: [RemoteFileItem]` und `onOpen: (RemoteFileItem) -> Void` (Doppelklick auf Verzeichnis) — genutzt von Task 6 (BrowserView)

Kein Unit-Test (reiner AppKit-View-Code, Spec: UI via manuelle Smoke-Tests); die Logik dahinter (Formatter, Sortierung) ist bereits in Tasks 2/4 getestet. Verifikation: kompiliert + Smoke-Test in Task 6.

- [x] **Step 1: Implementieren**

`Sources/MacSCPApp/RemoteFileTableView.swift`:

```swift
import AppKit
import SwiftUI
import macSCPCore

/// AppKit-NSTableView als SwiftUI-View. Spec-Vorgabe: reine SwiftUI-Listen
/// brechen bei Verzeichnissen mit tausenden Einträgen ein.
struct RemoteFileTableView: NSViewRepresentable {
    let items: [RemoteFileItem]
    let onOpen: (RemoteFileItem) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onOpen: onOpen)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let table = NSTableView()
        table.style = .inset
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = false

        for (identifier, title, width) in [
            ("name", "Name", 260.0),
            ("size", "Größe", 90.0),
            ("modified", "Geändert", 160.0),
        ] {
            let column = NSTableColumn(identifier: .init(identifier))
            column.title = title
            column.width = width
            table.addTableColumn(column)
        }

        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        table.target = context.coordinator
        table.doubleAction = #selector(Coordinator.doubleClicked(_:))

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        context.coordinator.table = table
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.items = items
        context.coordinator.onOpen = onOpen
        (nsView.documentView as? NSTableView)?.reloadData()
    }

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var items: [RemoteFileItem] = []
        var onOpen: (RemoteFileItem) -> Void
        weak var table: NSTableView?

        init(onOpen: @escaping (RemoteFileItem) -> Void) {
            self.onOpen = onOpen
        }

        func numberOfRows(in tableView: NSTableView) -> Int {
            items.count
        }

        func tableView(
            _ tableView: NSTableView,
            viewFor tableColumn: NSTableColumn?,
            row: Int
        ) -> NSView? {
            guard row < items.count, let columnID = tableColumn?.identifier.rawValue else {
                return nil
            }
            let item = items[row]
            let text: String
            switch columnID {
            case "name": text = FileListFormatter.displayName(for: item)
            case "size": text = FileListFormatter.sizeString(for: item)
            case "modified": text = FileListFormatter.dateString(for: item)
            default: return nil
            }

            let reuseID = NSUserInterfaceItemIdentifier("cell-\(columnID)")
            let cell: NSTableCellView
            if let reused = tableView.makeView(withIdentifier: reuseID, owner: nil)
                as? NSTableCellView {
                cell = reused
            } else {
                cell = NSTableCellView()
                cell.identifier = reuseID
                let field = NSTextField(labelWithString: "")
                field.lineBreakMode = .byTruncatingMiddle
                field.translatesAutoresizingMaskIntoConstraints = false
                cell.addSubview(field)
                cell.textField = field
                NSLayoutConstraint.activate([
                    field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                    field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
                    field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                ])
            }
            cell.textField?.stringValue = text
            return cell
        }

        @objc func doubleClicked(_ sender: Any?) {
            guard let row = table?.clickedRow, row >= 0, row < items.count else { return }
            let item = items[row]
            if item.isDirectory {
                onOpen(item)
            }
        }
    }
}
```

- [x] **Step 2: Bauen + Gesamtsuite**

Run: `swift build && swift test`
Expected: `Build complete!`, 43 Tests grün

- [x] **Step 3: Commit**

```bash
git add Sources/MacSCPApp/RemoteFileTableView.swift
git commit -m "feat: add AppKit table view wrapper for remote file listings

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 6: Views verdrahten (Formular → Browser)

**Files:**
- Create: `Sources/MacSCPApp/ConnectionFormView.swift`
- Create: `Sources/MacSCPApp/BrowserView.swift`
- Create: `Sources/MacSCPApp/ContentView.swift`
- Modify: `Sources/MacSCPApp/MacSCPApp.swift` (Platzhalter-Body ersetzen)

**Interfaces:**
- Consumes: `ConnectionViewModel` (Task 3), `RemoteBrowserViewModel` (Task 4), `RemoteFileTableView` (Task 5), `CitadelFileSystem.connect(config:)` (M1)
- Produces: benutzbare App: Formular → verbinden → Browser (navigieren, aktualisieren, trennen)

- [x] **Step 1: ConnectionFormView**

`Sources/MacSCPApp/ConnectionFormView.swift`:

```swift
import SwiftUI
import macSCPCore

struct ConnectionFormView: View {
    @Bindable var viewModel: ConnectionViewModel
    let onConnected: (any RemoteFileSystem) -> Void

    private var isConnecting: Bool { viewModel.state == .connecting }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Neue Verbindung")
                .font(.title2.bold())

            Form {
                TextField("Host", text: $viewModel.host, prompt: Text("server.example.com"))
                TextField("Port", text: $viewModel.port)
                TextField("Benutzername", text: $viewModel.username)
                SecureField("Passwort", text: $viewModel.password)
            }
            .disabled(isConnecting)

            if case .failed(let message) = viewModel.state {
                Text(message)
                    .foregroundStyle(.red)
                    .font(.callout)
            }

            HStack {
                Spacer()
                if isConnecting {
                    ProgressView()
                        .controlSize(.small)
                }
                Button("Verbinden") {
                    Task {
                        if let fs = await viewModel.connect() {
                            onConnected(fs)
                        }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isConnecting)
            }
        }
        .padding(24)
        .frame(minWidth: 420)
    }
}
```

- [x] **Step 2: BrowserView**

`Sources/MacSCPApp/BrowserView.swift`:

```swift
import SwiftUI
import macSCPCore

struct BrowserView: View {
    let viewModel: RemoteBrowserViewModel
    let onDisconnect: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button {
                    Task { await viewModel.goUp() }
                } label: {
                    Image(systemName: "arrow.up")
                }
                .disabled(!viewModel.canGoUp)
                .help("Übergeordnetes Verzeichnis")

                Text(viewModel.currentPath)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.head)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Button {
                    Task { await viewModel.refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Aktualisieren")

                Button("Trennen") {
                    Task {
                        await viewModel.disconnect()
                        onDisconnect()
                    }
                }
            }
            .padding(10)

            Divider()

            ZStack {
                RemoteFileTableView(items: viewModel.items) { item in
                    Task { await viewModel.open(item) }
                }

                if viewModel.state == .loading {
                    ProgressView()
                }

                if case .failed(let message) = viewModel.state {
                    VStack(spacing: 8) {
                        Text(message)
                            .foregroundStyle(.red)
                        Button("Erneut versuchen") {
                            Task { await viewModel.refresh() }
                        }
                    }
                    .padding()
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
        .task { await viewModel.load() }
    }
}
```

- [x] **Step 3: ContentView**

`Sources/MacSCPApp/ContentView.swift`:

```swift
import SwiftUI
import macSCPCore

struct ContentView: View {
    @State private var connectionViewModel = ConnectionViewModel(connector: { config in
        try await CitadelFileSystem.connect(config: config)
    })
    @State private var browserViewModel: RemoteBrowserViewModel?

    var body: some View {
        if let browserViewModel {
            BrowserView(viewModel: browserViewModel) {
                self.browserViewModel = nil
            }
        } else {
            ConnectionFormView(viewModel: connectionViewModel) { fs in
                browserViewModel = RemoteBrowserViewModel(fs: fs)
            }
        }
    }
}
```

- [x] **Step 4: App-Body ersetzen**

In `Sources/MacSCPApp/MacSCPApp.swift` den `WindowGroup`-Inhalt ersetzen:

```swift
    var body: some Scene {
        WindowGroup("macSCP") {
            ContentView()
                .frame(minWidth: 640, minHeight: 420)
        }
    }
```

(Der `init()` mit der Activation-Policy bleibt unverändert.)

- [x] **Step 5: Bauen + Gesamtsuite**

Run: `swift build && swift test`
Expected: `Build complete!`, 43 Tests grün

- [x] **Step 6: Manueller Smoke-Test gegen Docker-Server**

```bash
docker compose -f docker/test-server/compose.yml up -d
sleep 5
swift run macSCP
```

Checkliste (der Reihe nach):
1. Formular erscheint. Host `127.0.0.1`, Port `2222`, User `testuser`, Passwort absichtlich `falsch` → „Anmeldung fehlgeschlagen — Benutzername oder Passwort prüfen." in Rot, Formular bleibt bedienbar.
2. Passwort `testpass` → Browser erscheint, Pfad `/`.
3. Navigieren nach `/data/seed` (Doppelklick `data/`, dann `seed/`): `hello.txt` mit Größe, `sub/` mit `-`; Verzeichnisse stehen oben.
4. Pfeil-hoch-Button → zurück in `/data`; bei `/` ist der Button ausgegraut.
5. „Trennen" → zurück zum Formular.
6. Cmd+Q beendet die App.

Danach: `docker compose -f docker/test-server/compose.yml down`

(In Headless-Umgebung ohne Fenster: Schritte nicht prüfbar — dann App nur via `swift run macSCP` auf crashfreien Start prüfen, mit Ctrl+C beenden, und im Report explizit als NICHT manuell verifiziert kennzeichnen.)

- [x] **Step 7: Commit**

```bash
git add Sources/MacSCPApp/
git commit -m "feat: wire connection form and remote browser into the app window

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 7: Abschluss-Verifikation

**Files:**
- Modify: `docs/superpowers/plans/2026-07-09-m2a-remote-browser-app.md` (Checkboxen)

- [x] **Step 1: Komplette Unit-Suite**

Run: `swift test`
Expected: 43 Tests in 8 Suiten grün, Integrationssuite übersprungen

- [x] **Step 2: Integrationstests**

```bash
docker compose -f docker/test-server/compose.yml up -d
sleep 5
MACSCP_ITEST=1 swift test --filter CitadelFileSystem
docker compose -f docker/test-server/compose.yml down
```
Expected: 4/4 grün

- [x] **Step 3: Checkboxen dieses Plans auf `- [x]` setzen und committen**

```bash
git add docs/superpowers/plans/2026-07-09-m2a-remote-browser-app.md
git commit -m "docs: mark M2a plan tasks as completed

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Ausblick M2b (eigener Plan, nicht Teil dieses Plans)

Lokales Pane (`LocalFileSystem` + zweites Table), `readStream`/`writeStream` im
`RemoteFileSystem`-Protocol, Download/Upload einzelner Dateien,
Drag & Drop (Finder → Remote via `onDrop`, Remote → Finder via
`NSFilePromiseProvider`). Erst nach Abschluss und Review von M2a planen.
