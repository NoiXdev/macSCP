# macSCP M2a — Remote Browser App Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A launchable SwiftUI macOS app with a connection dialog and a remote file browser (read-only) built on top of the M1 core.

**Architecture:** New SPM executable target `MacSCPApp` (SwiftUI, `@main App`); ViewModels (`@Observable`, `@MainActor`) and formatting live UI-independently in `macSCPCore/Presentation` and are tested against the existing `MockRemoteFileSystem`. The file list is an AppKit `NSTableView` via `NSViewRepresentable` (spec requirement: SwiftUI lists break down on large directories). Production connection via `CitadelFileSystem.connect`.

**Tech Stack:** Swift 6 toolchain (Language Mode v5), SwiftUI + AppKit (macOS 14+), Observation framework, Citadel (already a dependency), Swift Testing.

## Global Constraints

- swift-tools-version 6.0, all targets `swiftSettings: [.swiftLanguageMode(.v5)]` (as established in `Package.swift`)
- Platform: macOS 14 (`.macOS(.v14)`)
- Conventional Commits, footer `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`; never push (the coordinator does that)
- UI text in German
- YAGNI for M2a: NO Keychain, NO TOFU/host-key UI, NO transfers, NO local pane, NO drag & drop, NO session persistence — all later milestones (M2b/M3)
- Integration test gate `MACSCP_ITEST=1` and the Docker rig (`docker compose -f docker/test-server/compose.yml up -d`, testuser/testpass, port 2222) stay unchanged
- After every task: a full `swift test` must be green (the unit suite runs without Docker)

## File Map (End of M2a)

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

### Task 1: App Target Scaffold

**Files:**
- Modify: `Package.swift`
- Create: `Sources/MacSCPApp/MacSCPApp.swift`

**Interfaces:**
- Consumes: nothing new (the target only depends on `macSCPCore`)
- Produces: executable product `macSCP`, module `MacSCPApp`; `@main struct MacSCPApp: App` — Task 6 replaces its `body` content

- [x] **Step 1: Extend Package.swift**

Add to `Package.swift` under `products:` (after the existing `macscp-cli` entry):

```swift
        .executable(name: "macSCP", targets: ["MacSCPApp"]),
```

and under `targets:` (after the `MacSCPCLI` target):

```swift
        .executableTarget(
            name: "MacSCPApp",
            dependencies: ["macSCPCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
```

- [x] **Step 2: Minimal app**

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

- [x] **Step 3: Build and tests**

Run: `swift build && swift test`
Expected: `Build complete!`, 25 tests green (integration suite skipped without Docker)

- [x] **Step 4: Manual smoke test**

Run: `swift run macSCP` (from `/Users/noidee/macSCP`)
Expected: the window "macSCP" with the text "macSCP — M2 in Arbeit" appears; quit with Cmd+Q. (In headless environments: process starts without crashing; quit with Ctrl+C after ~5 s and count that as success.)

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
- Produces: `public enum FileListFormatter` with `sizeString(for: RemoteFileItem) -> String`, `dateString(for: RemoteFileItem) -> String`, `displayName(for: RemoteFileItem) -> String` — used by Task 5 (table)

- [x] **Step 1: Failing tests**

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

- [x] **Step 2: Verify red**

Run: `swift test --filter FileListFormatterTests`
Expected: compile error `cannot find 'FileListFormatter' in scope`

- [x] **Step 3: Implement**

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

- [x] **Step 4: Verify green**

Run: `swift test --filter FileListFormatterTests`
Expected: 6 tests PASS

- [x] **Step 5: Full suite + commit**

Run: `swift test` — Expected: 31 tests green.

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
- Consumes: `SSHConnectionConfig` (M1, throws `ConfigError`), `RemoteFSError`, the `RemoteFileSystem` protocol, `MockRemoteFileSystem` in the test
- Produces: `public final class ConnectionViewModel` (`@Observable`, `@MainActor`) with fields `host/port/username/password: String`, `state: ConnectionViewModel.State` (`.idle/.connecting/.failed(message:)`), `init(connector:)`, `func connect() async -> (any RemoteFileSystem)?`, and `typealias Connector = @Sendable (SSHConnectionConfig) async throws -> any RemoteFileSystem` — used by Task 6 (form + ContentView)

- [x] **Step 1: Failing tests**

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

- [x] **Step 2: Verify red**

Run: `swift test --filter ConnectionViewModelTests`
Expected: compile error `cannot find 'ConnectionViewModel' in scope`

- [x] **Step 3: Implement**

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

- [x] **Step 4: Verify green**

Run: `swift test --filter ConnectionViewModelTests`
Expected: 6 tests PASS

- [x] **Step 5: Full suite + commit**

Run: `swift test` — Expected: 37 tests green.

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
- Consumes: the `RemoteFileSystem` protocol (`list/stat/disconnect`), `RemotePath.parent(of:)`, `RemoteFSError`; `MockRemoteFileSystem` in the test
- Produces: `public final class RemoteBrowserViewModel` (`@Observable`, `@MainActor`): `currentPath: String`, `items: [RemoteFileItem]`, `state: RemoteBrowserViewModel.State` (`.loading/.loaded/.failed(message:)`), `canGoUp: Bool`, `init(fs:startPath:)`, `load()`, `open(_:)`, `goUp()`, `refresh()`, `disconnect()` — used by Task 6 (BrowserView) and Task 5 (items source)

- [x] **Step 1: Failing tests**

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

- [x] **Step 2: Verify red**

Run: `swift test --filter RemoteBrowserViewModelTests`
Expected: compile error `cannot find 'RemoteBrowserViewModel' in scope`

- [x] **Step 3: Implement**

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

- [x] **Step 4: Verify green**

Run: `swift test --filter RemoteBrowserViewModelTests`
Expected: 6 tests PASS

- [x] **Step 5: Full suite + commit**

Run: `swift test` — Expected: 43 tests green.

```bash
git add Sources/macSCPCore/Presentation/RemoteBrowserViewModel.swift Tests/macSCPCoreTests/RemoteBrowserViewModelTests.swift
git commit -m "feat: add remote browser view model with navigation and sorting

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 5: RemoteFileTableView (NSTableView wrapper)

**Files:**
- Create: `Sources/MacSCPApp/RemoteFileTableView.swift`

**Interfaces:**
- Consumes: `RemoteFileItem`, `FileListFormatter` (Task 2)
- Produces: `struct RemoteFileTableView: NSViewRepresentable` with `items: [RemoteFileItem]` and `onOpen: (RemoteFileItem) -> Void` (double-click on a directory) — used by Task 6 (BrowserView)

No unit test (pure AppKit view code, spec: UI via manual smoke tests); the logic behind it (formatter, sorting) is already tested in Tasks 2/4. Verification: compiles + smoke test in Task 6.

- [x] **Step 1: Implement**

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

- [x] **Step 2: Build + full suite**

Run: `swift build && swift test`
Expected: `Build complete!`, 43 tests green

- [x] **Step 3: Commit**

```bash
git add Sources/MacSCPApp/RemoteFileTableView.swift
git commit -m "feat: add AppKit table view wrapper for remote file listings

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 6: Wire up views (form → browser)

**Files:**
- Create: `Sources/MacSCPApp/ConnectionFormView.swift`
- Create: `Sources/MacSCPApp/BrowserView.swift`
- Create: `Sources/MacSCPApp/ContentView.swift`
- Modify: `Sources/MacSCPApp/MacSCPApp.swift` (replace placeholder body)

**Interfaces:**
- Consumes: `ConnectionViewModel` (Task 3), `RemoteBrowserViewModel` (Task 4), `RemoteFileTableView` (Task 5), `CitadelFileSystem.connect(config:)` (M1)
- Produces: a usable app: form → connect → browser (navigate, refresh, disconnect)

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

- [x] **Step 4: Replace the app body**

In `Sources/MacSCPApp/MacSCPApp.swift`, replace the `WindowGroup` content:

```swift
    var body: some Scene {
        WindowGroup("macSCP") {
            ContentView()
                .frame(minWidth: 640, minHeight: 420)
        }
    }
```

(The `init()` with the activation policy stays unchanged.)

- [x] **Step 5: Build + full suite**

Run: `swift build && swift test`
Expected: `Build complete!`, 43 tests green

- [x] **Step 6: Manual smoke test against the Docker server**

```bash
docker compose -f docker/test-server/compose.yml up -d
sleep 5
swift run macSCP
```

Checklist (in order):
1. The form appears. Host `127.0.0.1`, port `2222`, user `testuser`, password deliberately `falsch` → „Anmeldung fehlgeschlagen — Benutzername oder Passwort prüfen." in red, the form stays usable.
2. Password `testpass` → the browser appears, path `/`.
3. Navigate to `/data/seed` (double-click `data/`, then `seed/`): `hello.txt` with a size, `sub/` with `-`; directories are listed first.
4. Up-arrow button → back to `/data`; at `/` the button is greyed out.
5. „Trennen" → back to the form.
6. Cmd+Q quits the app.

Afterwards: `docker compose -f docker/test-server/compose.yml down`

(In a headless environment without a window: steps cannot be checked — then only verify the app starts without crashing via `swift run macSCP`, quit with Ctrl+C, and mark it explicitly in the report as NOT manually verified.)

- [x] **Step 7: Commit**

```bash
git add Sources/MacSCPApp/
git commit -m "feat: wire connection form and remote browser into the app window

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 7: Final Verification

**Files:**
- Modify: `docs/superpowers/plans/2026-07-09-m2a-remote-browser-app.md` (checkboxes)

- [x] **Step 1: Full unit suite**

Run: `swift test`
Expected: 43 tests in 8 suites green, integration suite skipped

- [x] **Step 2: Integration tests**

```bash
docker compose -f docker/test-server/compose.yml up -d
sleep 5
MACSCP_ITEST=1 swift test --filter CitadelFileSystem
docker compose -f docker/test-server/compose.yml down
```
Expected: 4/4 green

- [x] **Step 3: Set this plan's checkboxes to `- [x]` and commit**

```bash
git add docs/superpowers/plans/2026-07-09-m2a-remote-browser-app.md
git commit -m "docs: mark M2a plan tasks as completed

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Outlook M2b (separate plan, not part of this plan)

Local pane (`LocalFileSystem` + a second table), `readStream`/`writeStream` in
the `RemoteFileSystem` protocol, download/upload of individual files,
drag & drop (Finder → remote via `onDrop`, remote → Finder via
`NSFilePromiseProvider`). Plan only after M2a is complete and reviewed.
