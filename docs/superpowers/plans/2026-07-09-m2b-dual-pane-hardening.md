# macSCP M2b — Dual-Pane & Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Zwei-Fenster-Layout (Lokal ↔ Remote, beide read-only) plus die Hardening-Punkte aus den M2a-Reviews — inklusive roter Feld-Umrandung bei Validierungsfehlern (Maintainer-Anforderung 2026-07-09).

**Architecture:** `ConnectionViewModel` wird feld-bewusst (`State.failed(message:field:)`) und re-entrancy-sicher; ein neues `LocalFileSystem` implementiert das vorhandene `RemoteFileSystem`-Protocol über `FileManager`, sodass beide Panes dasselbe ViewModel (`RemoteBrowserViewModel`) und dieselbe Tabelle (`RemoteFileTableView`) nutzen. Die Markenfarben aus `docs/design/ci.md` kommen als dynamische Design-Tokens in die App (Pane-Badges). `BrowserView` wird durch ein wiederverwendbares `BrowserPane` ersetzt, `ContentView` hält nach dem Verbinden eine `BrowserSession` mit beiden ViewModels in einem `HSplitView`.

**Tech Stack:** wie M2a (Swift 6-Toolchain, Language Mode v5, SwiftUI + AppKit, macOS 14, Swift Testing, Citadel).

## Global Constraints

- swift-tools-version 6.0, alle Targets `swiftSettings: [.swiftLanguageMode(.v5)]`; Plattform macOS 14
- Conventional Commits, Footer `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`; niemals pushen (macht der Koordinator)
- UI-Texte auf Deutsch
- YAGNI für M2b: KEINE Transfers/Streams, KEIN Drag & Drop (→ M2c/M2d), KEINE Keychain/Sessions (→ M3), KEINE Auswahl-/Mehrfachselektions-Features in der Tabelle
- Markenfarben nur semantisch einsetzen (Lokal/Remote-Duo aus `docs/design/ci.md`); App bleibt sonst macOS-nativ
- Integrationstest-Gate `MACSCP_ITEST=1` und Docker-Rig bleiben unverändert
- Nach jedem Task: kompletter `swift test` grün (Unit-Suite läuft ohne Docker)

## Datei-Landkarte (Delta M2b)

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

### Task 1: ConnectionViewModel v2 (Feld-Fehler, Guard, Trim) + Sort-Bereinigung

**Files:**
- Modify (vollständig ersetzen): `Sources/macSCPCore/Presentation/ConnectionViewModel.swift`
- Modify (vollständig ersetzen): `Tests/macSCPCoreTests/ConnectionViewModelTests.swift`
- Modify: `Sources/macSCPCore/SSH/CitadelFileSystem.swift` (nur die Sortier-Zeile)

**Interfaces:**
- Consumes: `SSHConnectionConfig`, `RemoteFSError`, `RemoteFileSystem`, im Test `MockRemoteFileSystem`
- Produces (für Task 3/4): `ConnectionViewModel.Field` (`.host/.port/.username/.password`, Equatable+Sendable), `State.failed(message: String, field: Field?)` statt bisher `failed(message:)`, unverändert `connect() async -> (any RemoteFileSystem)?`, NEU `clearPassword()`

**Semantik-Änderungen gegenüber M2a (bewusst):**
1. Jeder Validierungsfehler benennt sein Feld; Auth-/Verbindungsfehler haben `field: nil`.
2. `connect()` ist re-entrancy-sicher: während `.connecting` kehrt ein zweiter Aufruf sofort mit `nil` zurück (Review-Finding: Doppelklick leakte sonst eine SSH-Verbindung).
3. Host und Benutzername werden vor dem Config-Bau getrimmt (Review-Finding: `" example.com "` wählte sich sonst wörtlich ein).
4. `clearPassword()` für den Disconnect-Pfad (Review-Finding: Klartext-Passwort blieb im State).

- [x] **Step 1: Tests ersetzen (Rot)**

`Tests/macSCPCoreTests/ConnectionViewModelTests.swift` — Datei komplett ersetzen:

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

- [x] **Step 2: Rot verifizieren**

Run: `swift test --filter ConnectionViewModelTests`
Expected: Compile-Fehler (u.a. `type 'ConnectionViewModel.State' has no member 'failed(message:field:)'` bzw. fehlendes `Field`)

- [x] **Step 3: ViewModel ersetzen**

`Sources/macSCPCore/Presentation/ConnectionViewModel.swift` — Datei komplett ersetzen:

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

- [x] **Step 4: Build-Bruchstelle in ConnectionFormView minimal flicken**

Der App-Target kompiliert jetzt nicht mehr (`case .failed(let message)` passt nicht mehr). In `Sources/MacSCPApp/ConnectionFormView.swift` NUR diese eine Zeile ändern (die vollständige Neugestaltung mit roter Umrandung kommt in Task 3):

```swift
            if case .failed(let message, _) = viewModel.state {
```

- [x] **Step 5: Redundante Sortierung in CitadelFileSystem entfernen**

In `Sources/macSCPCore/SSH/CitadelFileSystem.swift`, Methode `list(path:)`: die Zeile

```swift
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
```

ersatzlos streichen (Review-Finding: `RemoteBrowserViewModel.sortedForDisplay` ist die einzige Sortier-Autorität; das Backend-Sortieren war totes Werk).

- [x] **Step 6: Grün verifizieren**

Run: `swift test --filter ConnectionViewModelTests`
Expected: 8 Tests PASS

Run: `swift test`
Expected: 45 Tests grün (43 bisher − 6 alte + 8 neue ConnectionViewModel-Tests)

- [x] **Step 7: Committen (zwei Commits)**

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
- Consumes: `RemoteFileSystem`-Protocol, `RemoteFileItem`, `RemoteFileKind`, `RemoteFSError`
- Produces (für Task 4): `public struct LocalFileSystem: RemoteFileSystem` mit `init()`, `list/stat` via FileManager, `disconnect()` No-op

- [x] **Step 1: Fehlschlagende Tests**

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

- [x] **Step 2: Rot verifizieren**

Run: `swift test --filter LocalFileSystemTests`
Expected: Compile-Fehler `cannot find 'LocalFileSystem' in scope`

- [x] **Step 3: Implementieren**

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

Hinweis: `RemoteFileItem.path` trägt hier absichtlich Pfade ohne Trailing-Slash (`path(percentEncoded: false)` liefert für Verzeichnisse ggf. einen Trailing-Slash — falls die Tests deshalb an `RemotePath.parent`-Erwartungen scheitern, in `item(for:)` normalisieren: `var p = url.path(percentEncoded: false); if p.count > 1 && p.hasSuffix("/") { p.removeLast() }` und das im Report offenlegen).

- [x] **Step 4: Grün verifizieren**

Run: `swift test --filter LocalFileSystemTests`
Expected: 6 Tests PASS

- [x] **Step 5: Gesamtsuite + Commit**

Run: `swift test` — Expected: 51 Tests grün.

```bash
git add Sources/macSCPCore/RemoteFS/LocalFileSystem.swift Tests/macSCPCoreTests/LocalFileSystemTests.swift
git commit -m "feat: add local file system behind the remote abstraction

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 3: Design-Tokens + rote Feld-Umrandung

**Files:**
- Create: `Sources/MacSCPApp/DesignTokens.swift`
- Modify (vollständig ersetzen): `Sources/MacSCPApp/ConnectionFormView.swift`

**Interfaces:**
- Consumes: `ConnectionViewModel` v2 (Task 1: `Field`, `State.failed(message:field:)`)
- Produces (für Task 4): `enum DesignTokens` mit `localAmber: Color` und `remoteBlue: Color` (dynamisch Hell/Dunkel, Werte aus `docs/design/ci.md`)

Kein Unit-Test (reine View-/Konstanten-Schicht); Verifikation: Build + Gesamtsuite + visueller Smoke-Test in Task 5.

- [x] **Step 1: Design-Tokens**

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

- [x] **Step 2: ConnectionFormView mit Feld-Highlight ersetzen**

`Sources/MacSCPApp/ConnectionFormView.swift` — Datei komplett ersetzen:

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

- [x] **Step 3: Bauen + Gesamtsuite**

Run: `swift build && swift test`
Expected: `Build complete!`, 51 Tests grün

- [x] **Step 4: Commit**

```bash
git add Sources/MacSCPApp/DesignTokens.swift Sources/MacSCPApp/ConnectionFormView.swift
git commit -m "feat: highlight failing form field and add brand color tokens

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 4: Zwei-Fenster-Layout (BrowserPane + BrowserSession)

**Files:**
- Create: `Sources/MacSCPApp/BrowserPane.swift`
- Delete: `Sources/MacSCPApp/BrowserView.swift`
- Modify (vollständig ersetzen): `Sources/MacSCPApp/ContentView.swift`
- Modify: `Sources/MacSCPApp/MacSCPApp.swift` (nur die frame-Zeile)

**Interfaces:**
- Consumes: `RemoteBrowserViewModel` (unverändert aus M2a), `RemoteFileTableView` (unverändert), `LocalFileSystem` (Task 2), `DesignTokens` (Task 3), `ConnectionViewModel.clearPassword()` (Task 1)
- Produces: benutzbare Zwei-Fenster-App (Lokal links ab Home-Verzeichnis, Remote rechts, beide read-only)

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

- [x] **Step 2: BrowserView löschen**

```bash
git rm Sources/MacSCPApp/BrowserView.swift
```

- [x] **Step 3: ContentView ersetzen**

`Sources/MacSCPApp/ContentView.swift` — Datei komplett ersetzen:

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

- [x] **Step 4: Mindestfenster vergrößern**

In `Sources/MacSCPApp/MacSCPApp.swift` die frame-Zeile im `WindowGroup` ändern zu:

```swift
                .frame(minWidth: 760, minHeight: 440)
```

- [x] **Step 5: Bauen + Gesamtsuite**

Run: `swift build && swift test`
Expected: `Build complete!`, 51 Tests grün

- [x] **Step 6: Commit**

```bash
git add Sources/MacSCPApp/
git commit -m "feat: split browser into local and remote panes

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 5: Abschluss-Verifikation

**Files:**
- Modify: `docs/superpowers/plans/2026-07-09-m2b-dual-pane-hardening.md` (Checkboxen)

- [x] **Step 1: Komplette Unit-Suite**

Run: `swift test`
Expected: 51 Tests in 9 Suiten grün, Integrationssuite übersprungen

- [x] **Step 2: Integrationstests**

```bash
docker compose -f docker/test-server/compose.yml up -d
sleep 6
MACSCP_ITEST=1 swift test --filter CitadelFileSystem
docker compose -f docker/test-server/compose.yml down
```
Expected: 4/4 grün

- [x] **Step 3: Visueller Smoke-Test** (macht der Koordinator am Bildschirm)

1. Formular: Port auf `abc` → rote Meldung UND Port-Feld rot umrandet; Host leeren → Host-Feld rot umrandet.
2. Verbinden gegen Docker (127.0.0.1:2222, testuser/testpass) → Zwei Panes: links LOKAL (Bernstein-Badge, Home-Verzeichnis), rechts REMOTE (Ozeanblau-Badge, `/`).
3. Beide Panes unabhängig navigieren (Doppelklick/Hoch/Aktualisieren).
4. Trennen → Formular, Passwortfeld ist geleert.

- [x] **Step 4: Checkboxen dieses Plans auf `- [x]` setzen und committen**

```bash
git add docs/superpowers/plans/2026-07-09-m2b-dual-pane-hardening.md
git commit -m "docs: mark M2b plan tasks as completed

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Ausblick (eigene Pläne, nicht Teil dieses Plans)

- **M2c — Transfers:** `readStream`/`writeStream` im Protocol (Citadel-openFile-Chunks bzw. FileHandle), TransferEngine mit Fortschritt (Bytes/Rate), Download-/Upload-Buttons zwischen den Panes, Fortschrittsleiste in den Duo-Farben (↑ Bernstein, ↓ Ozeanblau).
- **M2d — Drag & Drop:** Finder → Remote (`onDrop`), Remote → Finder (`NSFilePromiseProvider`), Pane ↔ Pane.
