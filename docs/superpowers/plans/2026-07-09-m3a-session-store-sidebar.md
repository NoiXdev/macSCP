# macSCP M3a — Session-Store, Schlüsselbund & Sidebar Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Gespeicherte Verbindungen (Passwort-Auth) mit Sessions-Sidebar: speichern beim Verbinden, Passwort ausschließlich im macOS-Schlüsselbund, Ein-Klick-Reconnect, Löschen per Kontextmenü.

**Architecture:** `StoredSession` (Codable, OHNE Geheimnisse) + `SessionStore` (JSON in `~/Library/Application Support/macSCP/sessions.json`, injizierbares Verzeichnis, atomare Writes). Geheimnisse hinter dem `SecretStore`-Protocol: `KeychainSecretStore` (Security.framework) in Produktion, `InMemorySecretStore` in Tests. `SessionListViewModel` (`@Observable @MainActor`) verbindet beides. `ConnectionViewModel` bekommt `shouldSaveSession`/`saveName` (+ Feld-Validierung), das Formular den Speichern-Toggle. `ContentView` erhält die Sessions-Sidebar (HSplitView links, Phosphor-Punkt für die aktive Session) — Klick füllt das Formular aus dem Store + Schlüsselbund und verbindet.

**Abhängigkeitsgraph (Parallel-Phasen für den Koordinator):**

```
Task 0 ─→ [ Task 1 (SessionStore) ∥ Task 2 (SecretStore/Keychain) ∥ Task 3 (ConnectionViewModel v3 + Form) ]
        ─→ Task 4 (SessionListViewModel) ─→ Task 5 (Sidebar + ContentView) ─→ Task 6 (Abschluss)
```
(Tasks 1/2/3 sind dateidisjunkt — drei parallele Worktrees möglich.)

## Global Constraints

- swift-tools-version 6.0, Language Mode v5; macOS 14; UI-Texte Deutsch; Conventional Commits mit Footer `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`; niemals pushen (macht der Koordinator)
- **Geheimnisse NIEMALS in der JSON-Datei** — nur Session-Metadaten; Passwörter ausschließlich über `SecretStore`
- YAGNI für M3a: NUR Passwort-Auth (`AuthKind.password`; Key/Agent → M3b), KEIN Session-Editor-Dialog (Speichern nur beim Verbinden), KEINE Start-Verzeichnisse, KEIN Umbenennen, KEINE Rückfrage-Dialoge (Session-Wechsel während Transfer wird per `.disabled` blockiert)
- Schlüsselbund-Tests sind gated hinter `MACSCP_KEYCHAIN=1` (CI-Runner-Keychains sind unzuverlässig); Unit-Suite bleibt ohne Gate grün
- Nach jedem Task: `swift test` grün

## Datei-Landkarte (Delta M3a)

```
Sources/macSCPCore/
  Sessions/StoredSession.swift        (neu, Task 1)
  Sessions/SessionStore.swift         (neu, Task 1)
  Sessions/SecretStore.swift          (neu, Task 2 — Protocol + KeychainSecretStore)
  Presentation/ConnectionViewModel.swift (Task 3 — shouldSaveSession/saveName + .saveName-Field)
  Presentation/SessionListViewModel.swift (neu, Task 4)
Sources/MacSCPApp/
  ConnectionFormView.swift            (Task 3 — Speichern-Toggle + Name-Feld)
  DesignTokens.swift                  (Task 5 — statusPhosphor)
  SessionSidebar.swift                (neu, Task 5)
  ContentView.swift                   (Task 0 Nits; Task 5 Sidebar-Layout + Stored-Connect)
  BrowserPane.swift                   (Task 0 — onDrop-Gating)
  MacSCPApp.swift                     (Task 5 — Mindestbreite 930)
Tests/macSCPCoreTests/
  SessionStoreTests.swift             (Task 1 — 6 Tests)
  KeychainSecretStoreTests.swift      (Task 2 — 2 Tests, gated MACSCP_KEYCHAIN=1)
  InMemorySecretStore.swift           (Task 2 — Test-Double)
  ConnectionViewModelTests.swift      (Task 3 — +2 Tests)
  SessionListViewModelTests.swift     (Task 4 — 5 Tests)
```

---

### Task 0: M3-Auftakt-Nits (aus M2d-Abschluss-Review)

**Files:**
- Modify: `Sources/MacSCPApp/ContentView.swift`
- Modify: `Sources/MacSCPApp/BrowserPane.swift`

Keine neuen Tests (reine Hygiene); Verifikation: Build + Suite (67) grün.

- [ ] **Step 1:** In `ContentView.swift`, im Remote-`pasteboardWriter`: `to: LocalFileSystem(),` ersetzen durch `to: session.localFS,` (Instanz-Wiederverwendung statt Neubau).
- [ ] **Step 2:** In `ContentView.swift`: den 9-zeiligen Promise-Closure-Body in eine private Methode extrahieren und an der Aufrufstelle nutzen:

```swift
    /// Promise-Einlösung: Remote-Datei direkt über die Engine an die
    /// vom Finder vorgegebene URL laden (bewusst ohne TransferBar → M5).
    private func remotePromiseProvider(
        for item: RemoteFileItem, session: BrowserSession
    ) -> RemoteFilePromiseProvider {
        RemoteFilePromiseProvider(item: item) { item, url in
            try await TransferEngine.copyFile(
                from: session.remoteFS, sourcePath: item.path,
                to: session.localFS,
                destinationDirectory: url.deletingLastPathComponent()
                    .path(percentEncoded: false),
                fileName: url.lastPathComponent,
                onProgress: { _ in }
            )
        }
    }
```

Aufrufstelle: `pasteboardWriter: { item in item.kind == .file ? remotePromiseProvider(for: item, session: session) : nil }`.

- [ ] **Step 3:** In `BrowserPane.swift`: `.overlay(...)`- und `.onDrop(...)`-Modifier nur anwenden, wenn `onDropURLs != nil` (kein Streu-Highlight auf dem lokalen Pane). Da Modifier nicht bedingt sein können, das Highlight über die Bedingung im Stroke lösen und den Drop im Closure ablehnen (bereits vorhanden) — konkret: die `strokeBorder`-Zeile ändern zu

```swift
                    .strokeBorder(tint, lineWidth: isDropTargeted && onDropURLs != nil ? 2.5 : 0)
```

- [ ] **Step 4:** In `BrowserPane.swift`: `extension NSItemProvider` → `fileprivate extension NSItemProvider` (Methode nur hier genutzt).
- [ ] **Step 5:** `swift build && swift test` — 67 grün. Commit:

```bash
git add Sources/MacSCPApp/
git commit -m "refactor: apply M2 review hygiene nits

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 1: StoredSession + SessionStore

**Files:**
- Create: `Sources/macSCPCore/Sessions/StoredSession.swift`
- Create: `Sources/macSCPCore/Sessions/SessionStore.swift`
- Test: `Tests/macSCPCoreTests/SessionStoreTests.swift`

**Interfaces:**
- Produces (für Task 4/5):

```swift
public struct StoredSession: Codable, Equatable, Identifiable, Sendable {
    public enum AuthKind: String, Codable, Sendable { case password }
    public let id: UUID
    public var name: String
    public var host: String
    public var port: Int
    public var username: String
    public var authKind: AuthKind
    public init(id: UUID = UUID(), name: String, host: String, port: Int = 22,
                username: String, authKind: AuthKind = .password)
}

public struct SessionStore: Sendable {
    public init(directory: URL)                 // wirft nicht; legt nichts an
    public static var defaultDirectory: URL     // ~/Library/Application Support/macSCP
    public func all() throws -> [StoredSession] // [] wenn Datei fehlt
    public func upsert(_ session: StoredSession) throws  // ersetzt per id, sonst append; atomar
    public func delete(id: UUID) throws         // unbekannte id = No-op
}
```

**Parallel-Hinweis:** disjunkt zu Task 2 und Task 3 — Worktree.

- [ ] **Step 1: Fehlschlagende Tests**

`Tests/macSCPCoreTests/SessionStoreTests.swift`:

```swift
import Foundation
import Testing
@testable import macSCPCore

@Suite("SessionStore")
struct SessionStoreTests {
    private func makeTempStore() -> (SessionStore, URL) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-sessions-\(UUID().uuidString)")
        return (SessionStore(directory: dir), dir)
    }

    @Test func emptyWhenNoFileExists() throws {
        let (store, dir) = makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(try store.all() == [])
    }

    @Test func upsertPersistsAndRoundtrips() throws {
        let (store, dir) = makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let session = StoredSession(name: "web", host: "example.com", username: "tim")
        try store.upsert(session)
        #expect(try store.all() == [session])
    }

    @Test func upsertReplacesById() throws {
        let (store, dir) = makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        var session = StoredSession(name: "web", host: "example.com", username: "tim")
        try store.upsert(session)
        session.name = "web-neu"
        try store.upsert(session)
        let all = try store.all()
        #expect(all.count == 1)
        #expect(all.first?.name == "web-neu")
    }

    @Test func deleteRemovesSession() throws {
        let (store, dir) = makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let session = StoredSession(name: "web", host: "example.com", username: "tim")
        try store.upsert(session)
        try store.delete(id: session.id)
        #expect(try store.all() == [])
    }

    @Test func deleteUnknownIdIsNoop() throws {
        let (store, dir) = makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let session = StoredSession(name: "web", host: "example.com", username: "tim")
        try store.upsert(session)
        try store.delete(id: UUID())
        #expect(try store.all() == [session])
    }

    @Test func corruptFileThrows() throws {
        let (store, dir) = makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("kein json".utf8).write(to: dir.appendingPathComponent("sessions.json"))
        #expect(throws: (any Error).self) {
            _ = try store.all()
        }
    }
}
```

- [ ] **Step 2: Rot verifizieren** — `swift test --filter SessionStoreTests` → Compile-Fehler `cannot find 'SessionStore' in scope`

- [ ] **Step 3: Implementieren**

`Sources/macSCPCore/Sessions/StoredSession.swift`:

```swift
import Foundation

/// Gespeicherte Verbindung — enthält KEINE Geheimnisse.
/// Passwörter liegen ausschließlich im SecretStore (Schlüsselbund),
/// adressiert über die Session-id.
public struct StoredSession: Codable, Equatable, Identifiable, Sendable {
    /// M3a: nur Passwort. privateKey/agent kommen in M3b.
    public enum AuthKind: String, Codable, Sendable {
        case password
    }

    public let id: UUID
    public var name: String
    public var host: String
    public var port: Int
    public var username: String
    public var authKind: AuthKind

    public init(
        id: UUID = UUID(),
        name: String,
        host: String,
        port: Int = 22,
        username: String,
        authKind: AuthKind = .password
    ) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.username = username
        self.authKind = authKind
    }
}
```

`Sources/macSCPCore/Sessions/SessionStore.swift`:

```swift
import Foundation

/// JSON-Persistenz für gespeicherte Sessions. Zustandslos: jede Operation
/// liest und schreibt die Datei (kleine Anzahl Sessions, atomare Writes).
public struct SessionStore: Sendable {
    private let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("macSCP", isDirectory: true)
    }

    private var fileURL: URL {
        directory.appendingPathComponent("sessions.json")
    }

    public func all() throws -> [StoredSession] {
        guard FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false)) else {
            return []
        }
        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder().decode([StoredSession].self, from: data)
    }

    public func upsert(_ session: StoredSession) throws {
        var sessions = try all()
        if let index = sessions.firstIndex(where: { $0.id == session.id }) {
            sessions[index] = session
        } else {
            sessions.append(session)
        }
        try persist(sessions)
    }

    public func delete(id: UUID) throws {
        var sessions = try all()
        sessions.removeAll { $0.id == id }
        try persist(sessions)
    }

    private func persist(_ sessions: [StoredSession]) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(sessions).write(to: fileURL, options: .atomic)
    }
}
```

- [ ] **Step 4: Grün** — `swift test --filter SessionStoreTests` (6 PASS), dann `swift test` (73 im Merge-Endstand; auf dem eigenen Branch 67 + 6).

- [ ] **Step 5: Commit**

```bash
git add Sources/macSCPCore/Sessions/ Tests/macSCPCoreTests/SessionStoreTests.swift
git commit -m "feat: add stored session model with json persistence

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: SecretStore-Protocol + KeychainSecretStore

**Files:**
- Create: `Sources/macSCPCore/Sessions/SecretStore.swift`
- Create: `Tests/macSCPCoreTests/InMemorySecretStore.swift`
- Test: `Tests/macSCPCoreTests/KeychainSecretStoreTests.swift` (gated)

**Interfaces:**
- Produces (für Task 4/5):

```swift
public protocol SecretStore: Sendable {
    func savePassword(_ password: String, for sessionID: UUID) throws
    func password(for sessionID: UUID) throws -> String?   // nil = kein Eintrag
    func deletePassword(for sessionID: UUID) throws        // fehlender Eintrag = No-op
}
public struct KeychainError: Error, Equatable, Sendable { public let status: OSStatus }
public struct KeychainSecretStore: SecretStore {
    public init(service: String = "dev.noidee.macSCP")
}
```

- Test-Double (internal, Test-Target): `InMemorySecretStore` (final class, NSLock, `@unchecked Sendable`).

**Parallel-Hinweis:** disjunkt zu Task 1 und Task 3 — Worktree.

- [ ] **Step 1: Gated Tests (Rot via Compile-Fehler)**

`Tests/macSCPCoreTests/KeychainSecretStoreTests.swift`:

```swift
import Foundation
import Testing
@testable import macSCPCore

/// Läuft nur mit MACSCP_KEYCHAIN=1 (lokal) — CI-Runner-Keychains sind unzuverlässig.
@Suite(
    "KeychainSecretStore",
    .enabled(if: ProcessInfo.processInfo.environment["MACSCP_KEYCHAIN"] == "1"),
    .serialized
)
struct KeychainSecretStoreTests {
    private let store = KeychainSecretStore(service: "dev.noidee.macSCP.test")

    @Test func roundtripSaveReadUpdate() throws {
        let id = UUID()
        defer { try? store.deletePassword(for: id) }

        #expect(try store.password(for: id) == nil)
        try store.savePassword("geheim1", for: id)
        #expect(try store.password(for: id) == "geheim1")
        try store.savePassword("geheim2", for: id)   // Update-Pfad
        #expect(try store.password(for: id) == "geheim2")
    }

    @Test func deleteRemovesAndIsIdempotent() throws {
        let id = UUID()
        try store.savePassword("weg", for: id)
        try store.deletePassword(for: id)
        #expect(try store.password(for: id) == nil)
        try store.deletePassword(for: id)   // No-op, wirft nicht
    }
}
```

`Tests/macSCPCoreTests/InMemorySecretStore.swift`:

```swift
import Foundation
@testable import macSCPCore

/// Test-Double: Geheimnisse im Speicher, threadsicher über NSLock.
final class InMemorySecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [UUID: String] = [:]

    func savePassword(_ password: String, for sessionID: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        storage[sessionID] = password
    }

    func password(for sessionID: UUID) throws -> String? {
        lock.lock(); defer { lock.unlock() }
        return storage[sessionID]
    }

    func deletePassword(for sessionID: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        storage[sessionID] = nil
    }
}
```

- [ ] **Step 2: Rot verifizieren** — `swift build --build-tests` bzw. `swift test --filter KeychainSecretStoreTests` → Compile-Fehler `cannot find 'SecretStore'/'KeychainSecretStore' in scope`

- [ ] **Step 3: Implementieren**

`Sources/macSCPCore/Sessions/SecretStore.swift`:

```swift
import Foundation
import Security

/// Abstraktion über die Geheimnis-Ablage. Produktion: macOS-Schlüsselbund.
/// Geheimnisse werden über die Session-id adressiert und tauchen NIE in der
/// Session-JSON auf.
public protocol SecretStore: Sendable {
    func savePassword(_ password: String, for sessionID: UUID) throws
    func password(for sessionID: UUID) throws -> String?
    func deletePassword(for sessionID: UUID) throws
}

public struct KeychainError: Error, Equatable, Sendable {
    public let status: OSStatus
}

public struct KeychainSecretStore: SecretStore {
    private let service: String

    public init(service: String = "dev.noidee.macSCP") {
        self.service = service
    }

    private func baseQuery(for sessionID: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: sessionID.uuidString,
        ]
    }

    public func savePassword(_ password: String, for sessionID: UUID) throws {
        let data = Data(password.utf8)
        let update: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(baseQuery(for: sessionID) as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var query = baseQuery(for: sessionID)
            query[kSecValueData as String] = data
            let addStatus = SecItemAdd(query as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError(status: addStatus) }
        } else {
            guard status == errSecSuccess else { throw KeychainError(status: status) }
        }
    }

    public func password(for sessionID: UUID) throws -> String? {
        var query = baseQuery(for: sessionID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw KeychainError(status: status)
        }
        return String(data: data, encoding: .utf8)
    }

    public func deletePassword(for sessionID: UUID) throws {
        let status = SecItemDelete(baseQuery(for: sessionID) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError(status: status)
        }
    }
}
```

- [ ] **Step 4: Grün** — `MACSCP_KEYCHAIN=1 swift test --filter KeychainSecretStoreTests` (2 PASS — lokal möglich; falls der Schlüsselbund im Sandbox-Kontext blockiert: als NICHT lokal verifiziert kennzeichnen, der Koordinator übernimmt das in Task 6). Ohne Gate: `swift test` unverändert grün (Suite wird übersprungen).

- [ ] **Step 5: Commit**

```bash
git add Sources/macSCPCore/Sessions/SecretStore.swift Tests/macSCPCoreTests/InMemorySecretStore.swift Tests/macSCPCoreTests/KeychainSecretStoreTests.swift
git commit -m "feat: add secret store protocol with keychain implementation

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 3: ConnectionViewModel v3 (Speichern-Toggle) + Formular

**Files:**
- Modify: `Sources/macSCPCore/Presentation/ConnectionViewModel.swift`
- Modify: `Tests/macSCPCoreTests/ConnectionViewModelTests.swift` (+2 Tests)
- Modify: `Sources/MacSCPApp/ConnectionFormView.swift`

**Interfaces:**
- Produces (für Task 5): `ConnectionViewModel.shouldSaveSession: Bool` (default false), `saveName: String` (default ""), neuer `Field`-Case `.saveName`; Validierung: Toggle an + leerer (getrimmter) Name → `failed(message: "Name für die gespeicherte Session angeben.", field: .saveName)` VOR dem Verbindungsaufbau.

**Parallel-Hinweis:** disjunkt zu Task 1 und Task 2 — Worktree.

- [ ] **Step 1: Fehlschlagende Tests** — in `ConnectionViewModelTests` ergänzen:

```swift
    @Test func saveRequestedWithEmptyNameFlagsSaveNameField() async {
        let vm = makeVM(connector: { _ in
            Issue.record("Connector darf bei fehlendem Session-Namen nicht laufen")
            throw RemoteFSError.connectionFailed(reason: "unreachable")
        })
        vm.shouldSaveSession = true
        vm.saveName = "   "
        let fs = await vm.connect()
        #expect(fs == nil)
        #expect(vm.state == .failed(
            message: "Name für die gespeicherte Session angeben.", field: .saveName))
    }

    @Test func saveNameNotValidatedWhenToggleOff() async {
        let vm = makeVM()
        vm.shouldSaveSession = false
        vm.saveName = ""
        let fs = await vm.connect()
        #expect(fs != nil)
    }
```

Run: `swift test --filter ConnectionViewModelTests` → Compile-Fehler (`shouldSaveSession` unbekannt).

- [ ] **Step 2: ViewModel erweitern** — in `ConnectionViewModel`:

1. `Field` um `case saveName` ergänzen.
2. Properties ergänzen:

```swift
    /// Session nach erfolgreichem Verbinden speichern (Store + Schlüsselbund)?
    public var shouldSaveSession: Bool = false
    public var saveName: String = ""
```

3. In `connect()` nach dem Passwort-Guard ergänzen:

```swift
        if shouldSaveSession,
           saveName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            state = .failed(
                message: "Name für die gespeicherte Session angeben.", field: .saveName)
            return nil
        }
```

- [ ] **Step 3: Formular erweitern** — in `ConnectionFormView`, innerhalb der `Form` nach dem `SecureField`:

```swift
                Toggle("Als Session speichern", isOn: $viewModel.shouldSaveSession)
                if viewModel.shouldSaveSession {
                    TextField("Session-Name", text: $viewModel.saveName,
                              prompt: Text("z.B. hetzner-web"))
                        .errorHighlight(failedField == .saveName)
                }
```

- [ ] **Step 4: Grün** — `swift test --filter ConnectionViewModelTests` (10 PASS), `swift build && swift test` (auf dem eigenen Branch 69).

- [ ] **Step 5: Commit**

```bash
git add Sources/macSCPCore/Presentation/ConnectionViewModel.swift Tests/macSCPCoreTests/ConnectionViewModelTests.swift Sources/MacSCPApp/ConnectionFormView.swift
git commit -m "feat: add save-session toggle with validated session name

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 4: SessionListViewModel

**Files:**
- Create: `Sources/macSCPCore/Presentation/SessionListViewModel.swift`
- Test: `Tests/macSCPCoreTests/SessionListViewModelTests.swift`

**Interfaces:**
- Consumes: Task 1 (`SessionStore`, `StoredSession`) + Task 2 (`SecretStore`, im Test `InMemorySecretStore`)
- Produces (für Task 5):

```swift
@Observable @MainActor
public final class SessionListViewModel {
    public private(set) var sessions: [StoredSession]   // name-sortiert (case-insensitiv)
    public private(set) var errorMessage: String?
    public init(store: SessionStore, secrets: any SecretStore)
    public func reload()
    @discardableResult
    public func save(name: String, host: String, port: Int, username: String,
                     password: String) -> StoredSession?
    public func delete(_ session: StoredSession)
    public func password(for session: StoredSession) -> String?
}
```

- [ ] **Step 1: Fehlschlagende Tests**

`Tests/macSCPCoreTests/SessionListViewModelTests.swift`:

```swift
import Foundation
import Testing
@testable import macSCPCore

@Suite("SessionListViewModel")
@MainActor
struct SessionListViewModelTests {
    private func makeVM() -> (SessionListViewModel, InMemorySecretStore, URL) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-slvm-\(UUID().uuidString)")
        let secrets = InMemorySecretStore()
        let vm = SessionListViewModel(store: SessionStore(directory: dir), secrets: secrets)
        return (vm, secrets, dir)
    }

    @Test func saveCreatesSessionAndStoresPassword() throws {
        let (vm, secrets, dir) = makeVM()
        defer { try? FileManager.default.removeItem(at: dir) }
        let stored = vm.save(name: "web", host: "example.com", port: 22,
                             username: "tim", password: "geheim")
        #expect(stored != nil)
        #expect(vm.sessions.map(\.name) == ["web"])
        #expect(try secrets.password(for: stored!.id) == "geheim")
    }

    @Test func reloadSortsByNameCaseInsensitive() {
        let (vm, _, dir) = makeVM()
        defer { try? FileManager.default.removeItem(at: dir) }
        vm.save(name: "zeta", host: "h", port: 22, username: "u", password: "p")
        vm.save(name: "Alpha", host: "h", port: 22, username: "u", password: "p")
        vm.save(name: "beta", host: "h", port: 22, username: "u", password: "p")
        #expect(vm.sessions.map(\.name) == ["Alpha", "beta", "zeta"])
    }

    @Test func deleteRemovesSessionAndSecret() throws {
        let (vm, secrets, dir) = makeVM()
        defer { try? FileManager.default.removeItem(at: dir) }
        let stored = vm.save(name: "weg", host: "h", port: 22, username: "u", password: "p")!
        vm.delete(stored)
        #expect(vm.sessions.isEmpty)
        #expect(try secrets.password(for: stored.id) == nil)
    }

    @Test func passwordReadsSecret() {
        let (vm, _, dir) = makeVM()
        defer { try? FileManager.default.removeItem(at: dir) }
        let stored = vm.save(name: "web", host: "h", port: 22, username: "u", password: "pw")!
        #expect(vm.password(for: stored) == "pw")
    }

    @Test func corruptStoreYieldsGermanErrorMessage() throws {
        let (vm, _, dir) = makeVM()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("kaputt".utf8).write(to: dir.appendingPathComponent("sessions.json"))
        vm.reload()
        #expect(vm.sessions.isEmpty)
        #expect(vm.errorMessage?.hasPrefix("Sessions konnten nicht geladen werden") == true)
    }
}
```

- [ ] **Step 2: Rot verifizieren** — Compile-Fehler `cannot find 'SessionListViewModel' in scope`

- [ ] **Step 3: Implementieren**

`Sources/macSCPCore/Presentation/SessionListViewModel.swift`:

```swift
import Foundation
import Observation

/// Zustand der Sessions-Sidebar: Liste, Speichern, Löschen, Passwort-Zugriff.
/// Geheimnisse laufen ausschließlich über den SecretStore.
@Observable
@MainActor
public final class SessionListViewModel {
    public private(set) var sessions: [StoredSession] = []
    public private(set) var errorMessage: String?

    private let store: SessionStore
    private let secrets: any SecretStore

    public init(store: SessionStore, secrets: any SecretStore) {
        self.store = store
        self.secrets = secrets
        reload()
    }

    public func reload() {
        do {
            sessions = try store.all().sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
            errorMessage = nil
        } catch {
            sessions = []
            errorMessage = "Sessions konnten nicht geladen werden: \(String(describing: error))"
        }
    }

    @discardableResult
    public func save(
        name: String, host: String, port: Int, username: String, password: String
    ) -> StoredSession? {
        let session = StoredSession(name: name, host: host, port: port, username: username)
        do {
            try store.upsert(session)
            try secrets.savePassword(password, for: session.id)
            reload()
            return session
        } catch {
            errorMessage = "Session konnte nicht gespeichert werden: \(String(describing: error))"
            return nil
        }
    }

    public func delete(_ session: StoredSession) {
        do {
            try store.delete(id: session.id)
            try secrets.deletePassword(for: session.id)
            reload()
        } catch {
            errorMessage = "Session konnte nicht gelöscht werden: \(String(describing: error))"
        }
    }

    public func password(for session: StoredSession) -> String? {
        (try? secrets.password(for: session.id)) ?? nil
    }
}
```

- [ ] **Step 4: Grün** — `swift test --filter SessionListViewModelTests` (5 PASS), dann `swift test` komplett: **80 Tests grün** (67 + 6 T1 + 2 T3 + 5 T4; Keychain-Suite übersprungen).

- [ ] **Step 5: Commit**

```bash
git add Sources/macSCPCore/Presentation/SessionListViewModel.swift Tests/macSCPCoreTests/SessionListViewModelTests.swift
git commit -m "feat: add session list view model backed by store and secrets

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 5: Sessions-Sidebar + ContentView-Verdrahtung

**Files:**
- Create: `Sources/MacSCPApp/SessionSidebar.swift`
- Modify: `Sources/MacSCPApp/DesignTokens.swift` (+ statusPhosphor)
- Modify (vollständig ersetzen): `Sources/MacSCPApp/ContentView.swift`
- Modify: `Sources/MacSCPApp/MacSCPApp.swift` (Mindestbreite)

**Interfaces:** Consumes Tasks 1–4. Produces die benutzbare Sidebar (Neue Verbindung, Session-Klick = Reconnect mit Schlüsselbund-Passwort, Kontextmenü Löschen, Phosphor-Punkt für aktiv).

- [ ] **Step 1: Design-Token ergänzen** — in `DesignTokens.swift`:

```swift
    /// Phosphor aus docs/design/ci.md: Verbunden-Status, Terminal-Grün.
    static let statusPhosphor = Color(nsColor: NSColor(
        srgbRed: 123 / 255, green: 216 / 255, blue: 143 / 255, alpha: 1)) // #7BD88F
```

- [ ] **Step 2: SessionSidebar**

`Sources/MacSCPApp/SessionSidebar.swift`:

```swift
import SwiftUI
import macSCPCore

/// Linke Spalte: gespeicherte Sessions. Klick verbindet, Kontextmenü löscht,
/// der Phosphor-Punkt markiert die aktive Verbindung.
struct SessionSidebar: View {
    let viewModel: SessionListViewModel
    let activeSessionID: UUID?
    let interactionsDisabled: Bool
    let onSelect: (StoredSession) -> Void
    let onNew: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("SESSIONS")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)

            List {
                Button(action: onNew) {
                    Label("Neue Verbindung", systemImage: "plus")
                }
                .buttonStyle(.plain)

                ForEach(viewModel.sessions) { session in
                    HStack(spacing: 8) {
                        Circle()
                            .fill(session.id == activeSessionID
                                  ? DesignTokens.statusPhosphor
                                  : Color.secondary.opacity(0.35))
                            .frame(width: 7, height: 7)
                        Text(session.name)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { onSelect(session) }
                    .contextMenu {
                        Button("Löschen", role: .destructive) {
                            viewModel.delete(session)
                        }
                    }
                    .help("\(session.username)@\(session.host):\(String(session.port))")
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)

            if let errorMessage = viewModel.errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .font(.caption)
                    .padding(8)
            }
        }
        .disabled(interactionsDisabled)
    }
}
```

- [ ] **Step 3: ContentView ersetzen**

`Sources/MacSCPApp/ContentView.swift` — Datei komplett ersetzen (übernimmt ALLE bestehenden privaten Methoden `uploadDropped`, `remotePromiseProvider`, `uploadButton`, `downloadButton` unverändert aus dem aktuellen Stand; hier NUR die veränderten Teile gezeigt — der Implementierer fügt die unveränderten Methoden aus dem bestehenden File ein):

```swift
import AppKit
import SwiftUI
import macSCPCore

struct BrowserSession {
    let localFS: LocalFileSystem
    let remoteFS: any RemoteFileSystem
    let local: RemoteBrowserViewModel
    let remote: RemoteBrowserViewModel
}

struct ContentView: View {
    @State private var connectionViewModel = ConnectionViewModel(connector: { config in
        try await CitadelFileSystem.connect(config: config)
    })
    @State private var sessionListViewModel = SessionListViewModel(
        store: SessionStore(directory: SessionStore.defaultDirectory),
        secrets: KeychainSecretStore()
    )
    @State private var session: BrowserSession?
    @State private var activeSessionID: UUID?
    @State private var transferViewModel = TransferViewModel()

    private var sidebarDisabled: Bool {
        transferViewModel.isRunning || connectionViewModel.state == .connecting
    }

    var body: some View {
        HSplitView {
            SessionSidebar(
                viewModel: sessionListViewModel,
                activeSessionID: activeSessionID,
                interactionsDisabled: sidebarDisabled,
                onSelect: { stored in connectStored(stored) },
                onNew: { disconnectToForm() }
            )
            .frame(minWidth: 170, idealWidth: 190, maxWidth: 260)

            detail
                .frame(minWidth: 590, maxWidth: .infinity)
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let session {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    uploadButton(session)
                    downloadButton(session)
                    Spacer()
                    Button("Trennen") {
                        disconnectToForm()
                    }
                    .disabled(transferViewModel.isRunning)
                }
                .padding(8)

                Divider()

                HSplitView {
                    BrowserPane(
                        title: "Lokal",
                        tint: DesignTokens.localAmber,
                        viewModel: session.local,
                        pasteboardWriter: { item in
                            item.kind == .file
                                ? NSURL(fileURLWithPath: item.path)
                                : nil
                        }
                    )
                    .frame(minWidth: 280)

                    BrowserPane(
                        title: "Remote",
                        tint: DesignTokens.remoteBlue,
                        viewModel: session.remote,
                        onDropURLs: { urls in
                            uploadDropped(urls, session: session)
                        },
                        pasteboardWriter: { item in
                            item.kind == .file
                                ? remotePromiseProvider(for: item, session: session)
                                : nil
                        }
                    )
                    .frame(minWidth: 280)
                }

                TransferBar(viewModel: transferViewModel)
            }
        } else {
            ConnectionFormView(viewModel: connectionViewModel) { fs in
                startSession(with: fs)
            }
        }
    }

    /// Nach erfolgreichem Verbinden: Panes aufbauen und ggf. Session speichern.
    private func startSession(with fs: any RemoteFileSystem) {
        session = BrowserSession(
            localFS: LocalFileSystem(),
            remoteFS: fs,
            local: RemoteBrowserViewModel(fs: LocalFileSystem(), startPath: NSHomeDirectory()),
            remote: RemoteBrowserViewModel(fs: fs)
        )
        transferViewModel = TransferViewModel()

        if connectionViewModel.shouldSaveSession {
            let stored = sessionListViewModel.save(
                name: connectionViewModel.saveName
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                host: connectionViewModel.host
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                port: Int(connectionViewModel.port
                    .trimmingCharacters(in: .whitespaces)) ?? 22,
                username: connectionViewModel.username
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                password: connectionViewModel.password
            )
            activeSessionID = stored?.id
            connectionViewModel.shouldSaveSession = false
        }
    }

    /// Sidebar-Klick: bestehende Verbindung trennen, Formular aus Store +
    /// Schlüsselbund füllen und direkt verbinden.
    private func connectStored(_ stored: StoredSession) {
        Task {
            await teardownSession()
            connectionViewModel.host = stored.host
            connectionViewModel.port = String(stored.port)
            connectionViewModel.username = stored.username
            connectionViewModel.saveName = stored.name
            connectionViewModel.shouldSaveSession = false
            connectionViewModel.password = sessionListViewModel.password(for: stored) ?? ""

            if let fs = await connectionViewModel.connect() {
                startSession(with: fs)
                activeSessionID = stored.id
            }
        }
    }

    private func disconnectToForm() {
        Task {
            await teardownSession()
        }
    }

    private func teardownSession() async {
        if let session {
            await session.remote.disconnect()
        }
        connectionViewModel.clearPassword()
        session = nil
        activeSessionID = nil
    }

    // … uploadDropped, remotePromiseProvider, uploadButton, downloadButton
    //   UNVERÄNDERT aus dem bestehenden ContentView übernehmen …
}
```

Hinweis: Ein per Sidebar gestarteter Connect, der FEHLSCHLÄGT (z.B. Passwort im Schlüsselbund fehlt), landet im Formular mit vorbefüllten Feldern und roter Meldung — gewünschtes Verhalten, nichts extra bauen.

- [ ] **Step 4: Mindestbreite** — in `MacSCPApp.swift`: `.frame(minWidth: 930, minHeight: 460)`

- [ ] **Step 5: Grün** — `swift build && swift test` (80 Tests)

- [ ] **Step 6: Commit**

```bash
git add Sources/MacSCPApp/
git commit -m "feat: add sessions sidebar with keychain-backed one-click reconnect

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 6: Abschluss-Verifikation

- [ ] **Step 1:** `swift test` — 80 Tests grün (Keychain-Suite übersprungen)
- [ ] **Step 2:** `MACSCP_KEYCHAIN=1 swift test --filter KeychainSecretStoreTests` — 2/2 (lokal; falls Task 2 das nicht verifizieren konnte, hier nachholen)
- [ ] **Step 3:** Docker-Rig hoch, `MACSCP_ITEST=1 swift test --filter CitadelFileSystem` — 6/6
- [ ] **Step 4: Visueller Smoke-Test** (Koordinator): Verbinden mit Toggle „Als Session speichern" + Name → Sidebar zeigt Session mit Phosphor-Punkt; Trennen → Punkt aus; Sidebar-Klick → verbindet OHNE Passworteingabe (Schlüsselbund); Kontextmenü → Löschen entfernt Eintrag; „Neue Verbindung" → leeres Formular; Toggle an + leerer Name → rotes Feld
- [ ] **Step 5:** Rig runter, Checkboxen abhaken, Commit `docs: mark M3a plan tasks as completed` (mit Footer)

## Ausblick (eigene Pläne)

**M3b** Key-/Agent-Auth (AuthMethod-Erweiterung, Citadel-Wiring, Auth-Picker im Formular, Passphrasen im Schlüsselbund) · **M3c** TOFU-Host-Keys (KnownHosts-Store, eigener hostKeyValidator, Bestätigungs-UI, harter Stopp bei Änderung) · **M3d** ssh-config-Import (purer Parser, Merge in die Sidebar).
