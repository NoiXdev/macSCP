# macSCP M2b — Dual-Pane & Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Two-window layout (Local ↔ Remote, both read-only) plus the hardening points from the M2a reviews — including a red field outline on validation errors (maintainer requirement 2026-07-09).

**Architecture:** `ConnectionViewModel` becomes field-aware (`State.failed(message:field:)`) and re-entrancy-safe; a new `LocalFileSystem` implements the existing `RemoteFileSystem` protocol over `FileManager`, so both panes use the same view model (`RemoteBrowserViewModel`) and the same table (`RemoteFileTableView`). The brand colors from `docs/design/ci.md` come into the app as dynamic design tokens (pane badges). `BrowserView` is replaced by a reusable `BrowserPane`; after connecting, `ContentView` holds a `BrowserSession` with both view models in an `HSplitView`.

**Tech Stack:** same as M2a (Swift 6 toolchain, Language Mode v5, SwiftUI + AppKit, macOS 14, Swift Testing, Citadel).

## Global Constraints

- swift-tools-version 6.0, all targets `swiftSettings: [.swiftLanguageMode(.v5)]`; platform macOS 14
- Conventional Commits, footer `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`; never push (the coordinator does that)
- UI text in German
- YAGNI for M2b: NO transfers/streams, NO drag & drop (→ M2c/M2d), NO Keychain/sessions (→ M3), NO selection/multi-selection features in the table
- Use brand colors only semantically (Local/Remote duo from `docs/design/ci.md`); otherwise the app stays macOS-native
- Integration test gate `MACSCP_ITEST=1` and the Docker rig stay unchanged
- After every task: full `swift test` green (the unit suite runs without Docker)

## File Map (M2b Delta)

```
Sources/
  macSCPCore/
    Presentation/ConnectionViewModel.swift   (ersetzt, Task 1 — Field/State v2, Guard, Trim, clearPassword)
    RemoteFS/LocalFileSystem.swift           (neu, Task 2 — FileManager hinter dem Protocol)
    SSH/CitadelFileSystem.swift              (Task 1 — redundante Sortierung entfernt)
  MacSCPApp/
    DesignTokens.swift                       (neu, Task 3 — Bernstein/Ozeanblau dynamisch)
    ConnectionFormView.swift                 (ersetzt, Task 3 — rote Feld-Umrandung)
    BrowserPane.swift                        (neu, Task 4 — ersetzt BrowserView)
    BrowserView.swift                        (gelöscht, Task 4)
    ContentView.swift                        (ersetzt, Task 4 — HSplitView + BrowserSession)
    MacSCPApp.swift                          (Task 4 — größeres Mindestfenster)
Tests/macSCPCoreTests/
  ConnectionViewModelTests.swift             (ersetzt, Task 1 — 8 Tests)
  LocalFileSystemTests.swift                 (neu, Task 2 — 6 Tests)
```

---

### Task 1: ConnectionViewModel v2 (Field Errors, Guard, Trim) + Sort Cleanup

**Files:**
- Modify (fully replace): `Sources/macSCPCore/Presentation/ConnectionViewModel.swift`
- Modify (fully replace): `Tests/macSCPCoreTests/ConnectionViewModelTests.swift`
- Modify: `Sources/macSCPCore/SSH/CitadelFileSystem.swift` (just the sort line)

**Interfaces:**
- Consumes: `SSHConnectionConfig`, `RemoteFSError`, `RemoteFileSystem`, in the test `MockRemoteFileSystem`
- Produces (for Task 3/4): `ConnectionViewModel.Field` (`.host/.port/.username/.password`, Equatable+Sendable), `State.failed(message: String, field: Field?)` instead of the previous `failed(message:)`, unchanged `connect() async -> (any RemoteFileSystem)?`, NEW `clearPassword()`

**Semantic changes vs. M2a (deliberate):**
1. Every validation error names its field; auth/connection errors have `field: nil`.
2. `connect()` is re-entrancy-safe: during `.connecting`, a second call returns `nil` immediately (review finding: a double click would otherwise leak an SSH connection).
3. Host and username are trimmed before building the config (review finding: `" example.com "` would otherwise dial in literally).
4. `clearPassword()` for the disconnect path (review finding: the plaintext password stayed in state).

- [x] **Step 1: Replace tests (Red)**

`Tests/macSCPCoreTests/ConnectionViewModelTests.swift` — replace the file completely:

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

    @Test func nonNumericPortFlagsPortField() async {
        let vm = makeVM()
        vm.port = "abc"
        let fs = await vm.connect()
        #expect(fs == nil)
        #expect(vm.state == .failed(message: "Port muss eine Zahl sein.", field: .port))
    }

    @Test func emptyHostFlagsHostField() async {
        let vm = makeVM()
        vm.host = ""
        _ = await vm.connect()
        #expect(vm.state == .failed(message: "Host darf nicht leer sein.", field: .host))
    }

    @Test func emptyPasswordFlagsPasswordFieldBeforeConnecting() async {
        let vm = makeVM(connector: { _ in
            Issue.record("Connector darf bei leerem Passwort nicht aufgerufen werden")
            throw RemoteFSError.connectionFailed(reason: "unreachable")
        })
        vm.password = ""
        _ = await vm.connect()
        #expect(vm.state == .failed(message: "Passwort darf nicht leer sein.", field: .password))
    }

    @Test func authFailureHasNoField() async {
        let vm = makeVM(connector: { _ in throw RemoteFSError.authenticationFailed })
        let fs = await vm.connect()
        #expect(fs == nil)
        #expect(vm.state == .failed(
            message: "Anmeldung fehlgeschlagen — Benutzername oder Passwort prüfen.",
            field: nil))
    }

    @Test func connectionFailureHasNoField() async {
        let vm = makeVM(connector: { _ in
            throw RemoteFSError.connectionFailed(reason: "timeout")
        })
        _ = await vm.connect()
        #expect(vm.state == .failed(message: "Verbindung fehlgeschlagen: timeout", field: nil))
    }

    @Test func trimsPaddedHostAndUsernameForConnection() async {
        let vm = makeVM(connector: { config in
            #expect(config.host == "example.com")
            #expect(config.username == "tim")
            return MockRemoteFileSystem(tree: ["/": []])
        })
        vm.host = "  example.com "
        vm.username = " tim\t"
        let fs = await vm.connect()
        #expect(fs != nil)
    }

    @Test func secondConnectWhileConnectingIsRejected() async {
        let counter = CallCounter()
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        let vm = makeVM(connector: { _ in
            await counter.increment()
            for await _ in stream {}   // hängt, bis der Test den Stream beendet
            return MockRemoteFileSystem(tree: ["/": []])
        })

        async let first = vm.connect()
        try? await Task.sleep(for: .milliseconds(80))

        let second = await vm.connect()
        #expect(second == nil)

        continuation.finish()
        let firstResult = await first
        #expect(firstResult != nil)
        #expect(await counter.value == 1)
    }
}

private actor CallCounter {
    private(set) var value = 0
    func increment() { value += 1 }
}
```

- [x] **Step 2: Verify red**

Run: `swift test --filter ConnectionViewModelTests`
Expected: compile error (among others `type 'ConnectionViewModel.State' has no member 'failed(message:field:)'` or a missing `Field`)

- [x] **Step 3: Replace the view model**

`Sources/macSCPCore/Presentation/ConnectionViewModel.swift` — replace the file completely:

```swift
import Foundation
import Observation

/// Zustand und Logik des Verbindungsformulars.
/// Der Connector ist injizierbar: Produktion nutzt CitadelFileSystem.connect,
/// Tests einen Mock — das ViewModel bleibt ohne Netz testbar.
@Observable
@MainActor
public final class ConnectionViewModel {
    /// Formularfeld, dessen Validierung fehlschlug — die UI hebt es rot hervor.
    public enum Field: Equatable, Sendable {
        case host
        case port
        case username
        case password
    }

    public enum State: Equatable {
        case idle
        case connecting
        case failed(message: String, field: Field?)
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
    /// Re-entrancy-sicher: Aufrufe während `.connecting` werden verworfen,
    /// damit ein Doppelklick keine zweite (verwaiste) Verbindung aufbaut.
    public func connect() async -> (any RemoteFileSystem)? {
        guard state != .connecting else { return nil }
        guard let portNumber = Int(port.trimmingCharacters(in: .whitespaces)) else {
            state = .failed(message: "Port muss eine Zahl sein.", field: .port)
            return nil
        }
        guard !password.isEmpty else {
            state = .failed(message: "Passwort darf nicht leer sein.", field: .password)
            return nil
        }
        do {
            let config = try SSHConnectionConfig(
                host: host.trimmingCharacters(in: .whitespacesAndNewlines),
                port: portNumber,
                username: username.trimmingCharacters(in: .whitespacesAndNewlines),
                auth: .password(password)
            )
            state = .connecting
            let fs = try await connector(config)
            state = .idle
            return fs
        } catch {
            state = Self.failedState(for: error)
            return nil
        }
    }

    /// Entfernt das Klartext-Passwort aus dem State (z.B. nach dem Trennen).
    public func clearPassword() {
        password = ""
    }

    static func failedState(for error: Error) -> State {
        switch error {
        case SSHConnectionConfig.ConfigError.emptyHost:
            return .failed(message: "Host darf nicht leer sein.", field: .host)
        case SSHConnectionConfig.ConfigError.emptyUsername:
            return .failed(message: "Benutzername darf nicht leer sein.", field: .username)
        case SSHConnectionConfig.ConfigError.invalidPort(let port):
            return .failed(message: "Ungültiger Port: \(port).", field: .port)
        case RemoteFSError.authenticationFailed:
            return .failed(
                message: "Anmeldung fehlgeschlagen — Benutzername oder Passwort prüfen.",
                field: nil)
        case RemoteFSError.connectionFailed(let reason):
            return .failed(message: "Verbindung fehlgeschlagen: \(reason)", field: nil)
        default:
            return .failed(message: "Unerwarteter Fehler: \(String(describing: error))", field: nil)
        }
    }
}
```

- [x] **Step 4: Patch the build break in ConnectionFormView minimally**

The app target no longer compiles (`case .failed(let message)` no longer matches). In `Sources/MacSCPApp/ConnectionFormView.swift` change ONLY this one line (the full redesign with the red outline comes in Task 3):

```swift
            if case .failed(let message, _) = viewModel.state {
```

- [x] **Step 5: Remove redundant sorting in CitadelFileSystem**

In `Sources/macSCPCore/SSH/CitadelFileSystem.swift`, method `list(path:)`: the line

```swift
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
```

delete outright, with no replacement (review finding: `RemoteBrowserViewModel.sortedForDisplay` is the sole sorting authority; the backend sort was dead work).

- [x] **Step 6: Verify green**

Run: `swift test --filter ConnectionViewModelTests`
Expected: 8 tests PASS

Run: `swift test`
Expected: 45 tests green (43 previously − 6 old + 8 new ConnectionViewModel tests)

- [x] **Step 7: Commit (two commits)**

```bash
git add Sources/macSCPCore/Presentation/ConnectionViewModel.swift Tests/macSCPCoreTests/ConnectionViewModelTests.swift Sources/MacSCPApp/ConnectionFormView.swift
git commit -m "feat: add field-aware validation errors with reconnect guard and input trimming

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
git add Sources/macSCPCore/SSH/CitadelFileSystem.swift
git commit -m "refactor: drop redundant backend sort, view model owns ordering

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: LocalFileSystem

**Files:**
- Create: `Sources/macSCPCore/RemoteFS/LocalFileSystem.swift`
- Test: `Tests/macSCPCoreTests/LocalFileSystemTests.swift`

**Interfaces:**
- Consumes: the `RemoteFileSystem` protocol, `RemoteFileItem`, `RemoteFileKind`, `RemoteFSError`
- Produces (for Task 4): `public struct LocalFileSystem: RemoteFileSystem` with `init()`, `list/stat` via FileManager, `disconnect()` a no-op

- [x] **Step 1: Failing tests**

`Tests/macSCPCoreTests/LocalFileSystemTests.swift`:

```swift
import Foundation
import Testing
@testable import macSCPCore

@Suite("LocalFileSystem")
struct LocalFileSystemTests {
    /// Legt einen Wegwerf-Baum an: <root>/unterordner/ und <root>/datei.txt (5 Bytes).
    private func makeTempTree() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-lfs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("unterordner"),
            withIntermediateDirectories: true)
        try Data("hallo".utf8).write(to: root.appendingPathComponent("datei.txt"))
        return root
    }

    @Test func listsFilesAndDirectoriesWithKinds() async throws {
        let root = try makeTempTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let fs = LocalFileSystem()

        let items = try await fs.list(path: root.path(percentEncoded: false))
        let byName = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0) })
        #expect(byName["unterordner"]?.kind == .directory)
        #expect(byName["datei.txt"]?.kind == .file)
    }

    @Test func fileSizeAndDateAreReported() async throws {
        let root = try makeTempTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let fs = LocalFileSystem()

        let items = try await fs.list(path: root.path(percentEncoded: false))
        let file = items.first { $0.name == "datei.txt" }
        #expect(file?.size == 5)
        #expect(file?.modifiedAt != nil)
    }

    @Test func statReturnsDirectory() async throws {
        let root = try makeTempTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let fs = LocalFileSystem()

        let item = try await fs.stat(path: root.path(percentEncoded: false))
        #expect(item.kind == .directory)
    }

    @Test func statReturnsFileWithSize() async throws {
        let root = try makeTempTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let fs = LocalFileSystem()

        let path = root.appendingPathComponent("datei.txt").path(percentEncoded: false)
        let item = try await fs.stat(path: path)
        #expect(item.kind == .file)
        #expect(item.size == 5)
    }

    @Test func listMissingPathThrowsNotFound() async {
        let fs = LocalFileSystem()
        let missing = "/tmp/macscp-gibt-es-nicht-\(UUID().uuidString)"
        await #expect(throws: RemoteFSError.notFound(path: missing)) {
            _ = try await fs.list(path: missing)
        }
    }

    @Test func statMissingPathThrowsNotFound() async {
        let fs = LocalFileSystem()
        let missing = "/tmp/macscp-gibt-es-nicht-\(UUID().uuidString)"
        await #expect(throws: RemoteFSError.notFound(path: missing)) {
            _ = try await fs.stat(path: missing)
        }
    }
}
```

- [x] **Step 2: Verify red**

Run: `swift test --filter LocalFileSystemTests`
Expected: compile error `cannot find 'LocalFileSystem' in scope`

- [x] **Step 3: Implement**

`Sources/macSCPCore/RemoteFS/LocalFileSystem.swift`:

```swift
import Foundation

/// Lokales Dateisystem hinter derselben Abstraktion wie SFTP — dadurch teilen
/// sich beide Panes ViewModel und Tabelle. `disconnect` ist ein No-op.
/// Fehler werden auf dieselben typisierten Fälle gemappt wie beim SFTP-Backend.
public struct LocalFileSystem: RemoteFileSystem {
    private static let resourceKeys: [URLResourceKey] = [
        .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey,
    ]

    public init() {}

    public func list(path: String) async throws -> [RemoteFileItem] {
        let url = URL(fileURLWithPath: path)
        let contents: [URL]
        do {
            contents = try FileManager.default.contentsOfDirectory(
                at: url, includingPropertiesForKeys: Self.resourceKeys)
        } catch {
            throw Self.map(error, path: path)
        }
        return contents.map(Self.item(for:))
    }

    public func stat(path: String) async throws -> RemoteFileItem {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
            throw RemoteFSError.notFound(path: path)
        }
        return Self.item(for: url)
    }

    public func disconnect() async {}

    private static func item(for url: URL) -> RemoteFileItem {
        let values = try? url.resourceValues(forKeys: Set(resourceKeys))
        let kind: RemoteFileKind
        if values?.isSymbolicLink == true {
            kind = .symlink
        } else if values?.isDirectory == true {
            kind = .directory
        } else {
            kind = .file
        }
        return RemoteFileItem(
            name: url.lastPathComponent,
            path: url.path(percentEncoded: false),
            kind: kind,
            size: (values?.fileSize).map(UInt64.init),
            modifiedAt: values?.contentModificationDate,
            permissions: nil
        )
    }

    private static func map(_ error: Error, path: String) -> Error {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain, ns.code == NSFileReadNoSuchFileError {
            return RemoteFSError.notFound(path: path)
        }
        if ns.domain == NSCocoaErrorDomain, ns.code == NSFileReadNoPermissionError {
            return RemoteFSError.permissionDenied(path: path)
        }
        return RemoteFSError.protocolError(reason: String(describing: error))
    }
}
```

Note: `RemoteFileItem.path` deliberately carries paths without a trailing slash here (`path(percentEncoded: false)` may return a trailing slash for directories — if the tests therefore fail against `RemotePath.parent` expectations, normalize in `item(for:)`: `var p = url.path(percentEncoded: false); if p.count > 1 && p.hasSuffix("/") { p.removeLast() }` and disclose that in the report).

- [x] **Step 4: Verify green**

Run: `swift test --filter LocalFileSystemTests`
Expected: 6 tests PASS

- [x] **Step 5: Full suite + commit**

Run: `swift test` — Expected: 51 tests green.

```bash
git add Sources/macSCPCore/RemoteFS/LocalFileSystem.swift Tests/macSCPCoreTests/LocalFileSystemTests.swift
git commit -m "feat: add local file system behind the remote abstraction

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 3: Design Tokens + Red Field Outline

**Files:**
- Create: `Sources/MacSCPApp/DesignTokens.swift`
- Modify (fully replace): `Sources/MacSCPApp/ConnectionFormView.swift`

**Interfaces:**
- Consumes: `ConnectionViewModel` v2 (Task 1: `Field`, `State.failed(message:field:)`)
- Produces (for Task 4): `enum DesignTokens` with `localAmber: Color` and `remoteBlue: Color` (dynamic light/dark, values from `docs/design/ci.md`)

No unit test (a pure view/constants layer); verification: build + full suite + visual smoke test in Task 5.

- [x] **Step 1: Design tokens**

`Sources/MacSCPApp/DesignTokens.swift`:

```swift
import AppKit
import SwiftUI

/// Marken-Duo aus docs/design/ci.md: Bernstein = Lokal, Ozeanblau = Remote.
/// Dynamisch für Hell/Dunkel. Nur semantisch einsetzen (Pane-Badges,
/// später Transferrichtung) — der Rest der App bleibt bei Systemfarben.
enum DesignTokens {
    static let localAmber = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 232 / 255, green: 166 / 255, blue: 60 / 255, alpha: 1) // #E8A63C
            : NSColor(srgbRed: 222 / 255, green: 148 / 255, blue: 38 / 255, alpha: 1) // #DE9426
    })

    static let remoteBlue = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 78 / 255, green: 146 / 255, blue: 214 / 255, alpha: 1) // #4E92D6
            : NSColor(srgbRed: 45 / 255, green: 113 / 255, blue: 184 / 255, alpha: 1) // #2D71B8
    })
}
```

- [x] **Step 2: Replace ConnectionFormView with field highlighting**

`Sources/MacSCPApp/ConnectionFormView.swift` — replace the file completely:

```swift
import SwiftUI
import macSCPCore

struct ConnectionFormView: View {
    @Bindable var viewModel: ConnectionViewModel
    let onConnected: (any RemoteFileSystem) -> Void

    private var isConnecting: Bool { viewModel.state == .connecting }

    /// Das Feld, dessen Validierung zuletzt fehlschlug — bekommt die rote Umrandung.
    private var failedField: ConnectionViewModel.Field? {
        if case .failed(_, let field) = viewModel.state { return field }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Neue Verbindung")
                .font(.title2.bold())

            Form {
                TextField("Host", text: $viewModel.host, prompt: Text("server.example.com"))
                    .errorHighlight(failedField == .host)
                TextField("Port", text: $viewModel.port)
                    .errorHighlight(failedField == .port)
                TextField("Benutzername", text: $viewModel.username)
                    .errorHighlight(failedField == .username)
                SecureField("Passwort", text: $viewModel.password)
                    .errorHighlight(failedField == .password)
            }
            .disabled(isConnecting)

            if case .failed(let message, _) = viewModel.state {
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

private extension View {
    /// Rote Umrandung für das Formularfeld, dessen Validierung fehlschlug.
    func errorHighlight(_ active: Bool) -> some View {
        overlay(
            RoundedRectangle(cornerRadius: 5)
                .strokeBorder(Color.red, lineWidth: active ? 1.5 : 0)
        )
        .animation(.easeOut(duration: 0.15), value: active)
    }
}
```

- [x] **Step 3: Build + full suite**

Run: `swift build && swift test`
Expected: `Build complete!`, 51 tests green

- [x] **Step 4: Commit**

```bash
git add Sources/MacSCPApp/DesignTokens.swift Sources/MacSCPApp/ConnectionFormView.swift
git commit -m "feat: highlight failing form field and add brand color tokens

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 4: Two-Window Layout (BrowserPane + BrowserSession)

**Files:**
- Create: `Sources/MacSCPApp/BrowserPane.swift`
- Delete: `Sources/MacSCPApp/BrowserView.swift`
- Modify (fully replace): `Sources/MacSCPApp/ContentView.swift`
- Modify: `Sources/MacSCPApp/MacSCPApp.swift` (just the frame line)

**Interfaces:**
- Consumes: `RemoteBrowserViewModel` (unchanged from M2a), `RemoteFileTableView` (unchanged), `LocalFileSystem` (Task 2), `DesignTokens` (Task 3), `ConnectionViewModel.clearPassword()` (Task 1)
- Produces: a usable two-window app (Local on the left starting at the home directory, Remote on the right, both read-only)

- [x] **Step 1: BrowserPane**

`Sources/MacSCPApp/BrowserPane.swift`:

```swift
import SwiftUI
import macSCPCore

/// Ein Datei-Pane (lokal oder remote): Kopfzeile mit Seiten-Badge in der
/// Markenfarbe, Pfad, Hoch/Aktualisieren — darunter die AppKit-Tabelle.
struct BrowserPane: View {
    let title: String
    let tint: Color
    let viewModel: RemoteBrowserViewModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(title.uppercased())
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(tint.opacity(0.18), in: RoundedRectangle(cornerRadius: 5))
                    .foregroundStyle(tint)

                Text(viewModel.currentPath)
                    .font(.system(.callout, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.head)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Button {
                    Task { await viewModel.goUp() }
                } label: {
                    Image(systemName: "arrow.up")
                }
                .disabled(!viewModel.canGoUp || viewModel.state == .loading)
                .help("Übergeordnetes Verzeichnis")

                Button {
                    Task { await viewModel.refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(viewModel.state == .loading)
                .help("Aktualisieren")
            }
            .padding(8)

            Divider()

            ZStack {
                RemoteFileTableView(items: viewModel.items) { item in
                    Task { await viewModel.open(item) }
                }
                // Während des Ladens keine Klicks in die (alte) Liste lassen
                .allowsHitTesting(viewModel.state == .loaded)

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

- [x] **Step 2: Delete BrowserView**

```bash
git rm Sources/MacSCPApp/BrowserView.swift
```

- [x] **Step 3: Replace ContentView**

`Sources/MacSCPApp/ContentView.swift` — replace the file completely:

```swift
import SwiftUI
import macSCPCore

/// Beide Seiten einer aktiven Verbindung: lokales Pane (Home-Verzeichnis)
/// und Remote-Pane (SFTP). Lebt genau so lange wie die Verbindung.
struct BrowserSession {
    let local: RemoteBrowserViewModel
    let remote: RemoteBrowserViewModel
}

struct ContentView: View {
    @State private var connectionViewModel = ConnectionViewModel(connector: { config in
        try await CitadelFileSystem.connect(config: config)
    })
    @State private var session: BrowserSession?

    var body: some View {
        if let session {
            VStack(spacing: 0) {
                HStack {
                    Spacer()
                    Button("Trennen") {
                        Task {
                            await session.remote.disconnect()
                            connectionViewModel.clearPassword()
                            self.session = nil
                        }
                    }
                }
                .padding(8)

                Divider()

                HSplitView {
                    BrowserPane(
                        title: "Lokal",
                        tint: DesignTokens.localAmber,
                        viewModel: session.local
                    )
                    .frame(minWidth: 280)

                    BrowserPane(
                        title: "Remote",
                        tint: DesignTokens.remoteBlue,
                        viewModel: session.remote
                    )
                    .frame(minWidth: 280)
                }
            }
        } else {
            ConnectionFormView(viewModel: connectionViewModel) { fs in
                session = BrowserSession(
                    local: RemoteBrowserViewModel(fs: LocalFileSystem(), startPath: NSHomeDirectory()),
                    remote: RemoteBrowserViewModel(fs: fs)
                )
            }
        }
    }
}
```

- [x] **Step 4: Increase the minimum window size**

In `Sources/MacSCPApp/MacSCPApp.swift`, change the frame line in the `WindowGroup` to:

```swift
                .frame(minWidth: 760, minHeight: 440)
```

- [x] **Step 5: Build + full suite**

Run: `swift build && swift test`
Expected: `Build complete!`, 51 tests green

- [x] **Step 6: Commit**

```bash
git add Sources/MacSCPApp/
git commit -m "feat: split browser into local and remote panes

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 5: Final Verification

**Files:**
- Modify: `docs/superpowers/plans/2026-07-09-m2b-dual-pane-hardening.md` (checkboxes)

- [x] **Step 1: Complete unit suite**

Run: `swift test`
Expected: 51 tests in 9 suites green, integration suite skipped

- [x] **Step 2: Integration tests**

```bash
docker compose -f docker/test-server/compose.yml up -d
sleep 6
MACSCP_ITEST=1 swift test --filter CitadelFileSystem
docker compose -f docker/test-server/compose.yml down
```
Expected: 4/4 green

- [x] **Step 3: Visual smoke test** (the coordinator does this on screen)

1. Form: set Port to `abc` → red message AND the Port field outlined in red; clear Host → Host field outlined in red.
2. Connect against Docker (127.0.0.1:2222, testuser/testpass) → two panes: LOCAL on the left (amber badge, home directory), REMOTE on the right (ocean-blue badge, `/`).
3. Navigate both panes independently (double-click/up/refresh).
4. Disconnect → form, the password field is cleared.

- [x] **Step 4: Set this plan's checkboxes to `- [x]` and commit**

```bash
git add docs/superpowers/plans/2026-07-09-m2b-dual-pane-hardening.md
git commit -m "docs: mark M2b plan tasks as completed

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Outlook (separate plans, not part of this plan)

- **M2c — Transfers:** `readStream`/`writeStream` in the protocol (Citadel openFile chunks or FileHandle), TransferEngine with progress (bytes/rate), download/upload buttons between the panes, progress bar in the duo colors (↑ amber, ↓ ocean blue).
- **M2d — Drag & Drop:** Finder → Remote (`onDrop`), Remote → Finder (`NSFilePromiseProvider`), Pane ↔ Pane.
