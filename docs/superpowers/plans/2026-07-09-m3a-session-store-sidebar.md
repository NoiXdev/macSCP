# macSCP M3a — Session Store, Keychain & Sidebar Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stored connections (password auth) with a sessions sidebar: save on connect, password exclusively in the macOS Keychain, one-click reconnect, delete via context menu.

**Architecture:** `StoredSession` (Codable, WITHOUT secrets) + `SessionStore` (JSON in `~/Library/Application Support/macSCP/sessions.json`, injectable directory, atomic writes). Secrets sit behind the `SecretStore` protocol: `KeychainSecretStore` (Security.framework) in production, `InMemorySecretStore` in tests. `SessionListViewModel` (`@Observable @MainActor`) connects both. `ConnectionViewModel` gets `shouldSaveSession`/`saveName` (+ field validation), the form gets the save toggle. `ContentView` gets the sessions sidebar (HSplitView on the left, phosphor dot for the active session) — clicking fills the form from the store + Keychain and connects.

**Dependency graph (parallel phases for the coordinator):**

```
Task 0 ─→ [ Task 1 (SessionStore) ∥ Task 2 (SecretStore/Keychain) ∥ Task 3 (ConnectionViewModel v3 + Form) ]
        ─→ Task 4 (SessionListViewModel) ─→ Task 5 (Sidebar + ContentView) ─→ Task 6 (Abschluss)
```
(Tasks 1/2/3 are file-disjoint — three parallel worktrees possible.)

## Global Constraints

- swift-tools-version 6.0, Language Mode v5; macOS 14; UI text German; Conventional Commits with footer `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`; never push (the coordinator does that)
- **Secrets NEVER in the JSON file** — only session metadata; passwords exclusively via `SecretStore`
- YAGNI for M3a: password auth ONLY (`AuthKind.password`; key/agent → M3b), NO session editor dialog (save only on connect), NO start directories, NO renaming, NO confirmation dialogs (session switching during a transfer is blocked via `.disabled`)
- Keychain tests are gated behind `MACSCP_KEYCHAIN=1` (CI runner keychains are unreliable); the unit suite stays green without the gate
- After every task: `swift test` green

## File map (delta M3a)

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

### Task 0: M3 kickoff nits (from the M2d closeout review)

**Files:**
- Modify: `Sources/MacSCPApp/ContentView.swift`
- Modify: `Sources/MacSCPApp/BrowserPane.swift`

No new tests (pure hygiene); verification: build + suite (67) green.

- [x] **Step 1:** In `ContentView.swift`, in the remote `pasteboardWriter`: replace `to: LocalFileSystem(),` with `to: session.localFS,` (reuse the instance instead of building a new one).
- [x] **Step 2:** In `ContentView.swift`: extract the 9-line promise closure body into a private method and use it at the call site:

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

Call site: `pasteboardWriter: { item in item.kind == .file ? remotePromiseProvider(for: item, session: session) : nil }`.

- [x] **Step 3:** In `BrowserPane.swift`: only apply the `.overlay(...)` and `.onDrop(...)` modifiers when `onDropURLs != nil` (no stray highlight on the local pane). Since modifiers cannot be conditional, resolve the highlight via the condition in the stroke and reject the drop in the closure (already in place) — concretely: change the `strokeBorder` line to

```swift
                    .strokeBorder(tint, lineWidth: isDropTargeted && onDropURLs != nil ? 2.5 : 0)
```

- [x] **Step 4:** In `BrowserPane.swift`: `extension NSItemProvider` → `fileprivate extension NSItemProvider` (method used only here).
- [x] **Step 5:** `swift build && swift test` — 67 green. Commit:

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
- Produces (for Task 4/5):

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

**Parallel note:** disjoint from Task 2 and Task 3 — worktree.

- [x] **Step 1: Failing tests**

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

- [x] **Step 2: Verify red** — `swift test --filter SessionStoreTests` → compile error `cannot find 'SessionStore' in scope`

- [x] **Step 3: Implement**

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

- [x] **Step 4: Green** — `swift test --filter SessionStoreTests` (6 PASS), then `swift test` (73 in the merged end state; 67 + 6 on its own branch).

- [x] **Step 5: Commit**

```bash
git add Sources/macSCPCore/Sessions/ Tests/macSCPCoreTests/SessionStoreTests.swift
git commit -m "feat: add stored session model with json persistence

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: SecretStore protocol + KeychainSecretStore

**Files:**
- Create: `Sources/macSCPCore/Sessions/SecretStore.swift`
- Create: `Tests/macSCPCoreTests/InMemorySecretStore.swift`
- Test: `Tests/macSCPCoreTests/KeychainSecretStoreTests.swift` (gated)

**Interfaces:**
- Produces (for Task 4/5):

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

- Test double (internal, test target): `InMemorySecretStore` (final class, NSLock, `@unchecked Sendable`).

**Parallel note:** disjoint from Task 1 and Task 3 — worktree.

- [x] **Step 1: Gated tests (red via compile error)**

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

- [x] **Step 2: Verify red** — `swift build --build-tests` or `swift test --filter KeychainSecretStoreTests` → compile error `cannot find 'SecretStore'/'KeychainSecretStore' in scope`

- [x] **Step 3: Implement**

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

- [x] **Step 4: Green** — `MACSCP_KEYCHAIN=1 swift test --filter KeychainSecretStoreTests` (2 PASS — locally possible; if the Keychain blocks in the sandbox context: mark as NOT verified locally, the coordinator picks it up in Task 6). Without the gate: `swift test` stays green unchanged (the suite is skipped).

- [x] **Step 5: Commit**

```bash
git add Sources/macSCPCore/Sessions/SecretStore.swift Tests/macSCPCoreTests/InMemorySecretStore.swift Tests/macSCPCoreTests/KeychainSecretStoreTests.swift
git commit -m "feat: add secret store protocol with keychain implementation

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 3: ConnectionViewModel v3 (save toggle) + form

**Files:**
- Modify: `Sources/macSCPCore/Presentation/ConnectionViewModel.swift`
- Modify: `Tests/macSCPCoreTests/ConnectionViewModelTests.swift` (+2 tests)
- Modify: `Sources/MacSCPApp/ConnectionFormView.swift`

**Interfaces:**
- Produces (for Task 5): `ConnectionViewModel.shouldSaveSession: Bool` (default false), `saveName: String` (default ""), new `Field` case `.saveName`; validation: toggle on + empty (trimmed) name → `failed(message: "Name für die gespeicherte Session angeben.", field: .saveName)` BEFORE the connection is established.

**Parallel note:** disjoint from Task 1 and Task 2 — worktree.

- [x] **Step 1: Failing tests** — add to `ConnectionViewModelTests`:

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

Run: `swift test --filter ConnectionViewModelTests` → compile error (`shouldSaveSession` unknown).

- [x] **Step 2: Extend the view model** — in `ConnectionViewModel`:

1. Add `case saveName` to `Field`.
2. Add properties:

```swift
    /// Session nach erfolgreichem Verbinden speichern (Store + Schlüsselbund)?
    public var shouldSaveSession: Bool = false
    public var saveName: String = ""
```

3. In `connect()`, add after the password guard:

```swift
        if shouldSaveSession,
           saveName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            state = .failed(
                message: "Name für die gespeicherte Session angeben.", field: .saveName)
            return nil
        }
```

- [x] **Step 3: Extend the form** — in `ConnectionFormView`, inside the `Form` after the `SecureField`:

```swift
                Toggle("Als Session speichern", isOn: $viewModel.shouldSaveSession)
                if viewModel.shouldSaveSession {
                    TextField("Session-Name", text: $viewModel.saveName,
                              prompt: Text("z.B. hetzner-web"))
                        .errorHighlight(failedField == .saveName)
                }
```

- [x] **Step 4: Green** — `swift test --filter ConnectionViewModelTests` (10 PASS), `swift build && swift test` (69 on its own branch).

- [x] **Step 5: Commit**

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
- Consumes: Task 1 (`SessionStore`, `StoredSession`) + Task 2 (`SecretStore`, in tests `InMemorySecretStore`)
- Produces (for Task 5):

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

- [x] **Step 1: Failing tests**

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

- [x] **Step 2: Verify red** — compile error `cannot find 'SessionListViewModel' in scope`

- [x] **Step 3: Implement**

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

- [x] **Step 4: Green** — `swift test --filter SessionListViewModelTests` (5 PASS), then full `swift test`: **80 tests green** (67 + 6 T1 + 2 T3 + 5 T4; Keychain suite skipped).

- [x] **Step 5: Commit**

```bash
git add Sources/macSCPCore/Presentation/SessionListViewModel.swift Tests/macSCPCoreTests/SessionListViewModelTests.swift
git commit -m "feat: add session list view model backed by store and secrets

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 5: Sessions sidebar + ContentView wiring

**Files:**
- Create: `Sources/MacSCPApp/SessionSidebar.swift`
- Modify: `Sources/MacSCPApp/DesignTokens.swift` (+ statusPhosphor)
- Modify (replace entirely): `Sources/MacSCPApp/ContentView.swift`
- Modify: `Sources/MacSCPApp/MacSCPApp.swift` (minimum width)

**Interfaces:** Consumes Tasks 1–4. Produces the usable sidebar (new connection, session click = reconnect with Keychain password, context menu delete, phosphor dot for active).

- [x] **Step 1: Add design token** — in `DesignTokens.swift`:

```swift
    /// Phosphor aus docs/design/ci.md: Verbunden-Status, Terminal-Grün.
    static let statusPhosphor = Color(nsColor: NSColor(
        srgbRed: 123 / 255, green: 216 / 255, blue: 143 / 255, alpha: 1)) // #7BD88F
```

- [x] **Step 2: SessionSidebar**

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

- [x] **Step 3: Replace ContentView**

`Sources/MacSCPApp/ContentView.swift` — replace the file entirely (carries over ALL existing private methods `uploadDropped`, `remotePromiseProvider`, `uploadButton`, `downloadButton` unchanged from the current state; only the changed parts are shown here — the implementer inserts the unchanged methods from the existing file):

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

Note: A connect started via the sidebar that FAILS (e.g. the password is missing from the Keychain) lands on the form with pre-filled fields and a red message — this is the desired behavior, nothing extra to build.

- [x] **Step 4: Minimum width** — in `MacSCPApp.swift`: `.frame(minWidth: 930, minHeight: 460)`

- [x] **Step 5: Green** — `swift build && swift test` (80 tests)

- [x] **Step 6: Commit**

```bash
git add Sources/MacSCPApp/
git commit -m "feat: add sessions sidebar with keychain-backed one-click reconnect

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 6: Final verification

- [x] **Step 1:** `swift test` — 80 tests green (Keychain suite skipped)
- [x] **Step 2:** `MACSCP_KEYCHAIN=1 swift test --filter KeychainSecretStoreTests` — 2/2 (locally; if Task 2 could not verify this, catch up here)
- [x] **Step 3:** Bring up the Docker rig, `MACSCP_ITEST=1 swift test --filter CitadelFileSystem` — 6/6
- [x] **Step 4: Visual smoke test** (coordinator): connect with the "Als Session speichern" toggle + name → sidebar shows the session with a phosphor dot; disconnect → dot off; sidebar click → connects WITHOUT entering a password (Keychain); context menu → delete removes the entry; "Neue Verbindung" → empty form; toggle on + empty name → red field
- [x] **Step 5:** Bring the rig down, check off the checkboxes, commit `docs: mark M3a plan tasks as completed` (with footer)

## Outlook (separate plans)

**M3b** key/agent auth (AuthMethod extension, Citadel wiring, auth picker in the form, passphrases in the Keychain) · **M3c** TOFU host keys (KnownHosts store, dedicated hostKeyValidator, confirmation UI, hard stop on change) · **M3d** ssh-config import (pure parser, merge into the sidebar).
