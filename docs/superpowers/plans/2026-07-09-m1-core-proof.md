# macSCP M1 — Kern-Beweis: Implementierungsplan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Swift-Package `macSCPCore` mit `RemoteFileSystem`-Abstraktion, Citadel-SFTP-Implementierung (Passwort-Auth) und CLI-Treiber, der ein Remote-Verzeichnis auflistet — bewiesen gegen einen lokalen Docker-SSH-Server.

**Architecture:** UI-freies SPM-Package mit drei Schichten: `RemoteFS` (Protocol + Modelle), `SSH` (Config + Citadel-Anbindung), CLI-Executable als Treiber. Alle Kernlogik gegen das Protocol testbar (Mock); die Citadel-Schicht wird per Integrationstest gegen Docker verifiziert.

**Tech Stack:** Swift 6 Toolchain (Language Mode v5), SPM, [Citadel 0.12.x](https://github.com/orlandos-nl/Citadel), swift-argument-parser, Swift Testing, Docker (`linuxserver/openssh-server`) für Integrationstests.

**Spec:** `docs/superpowers/specs/2026-07-09-macscp-design.md`

**Bewusst NICHT in M1** (kommt in M2–M5): Key-/Agent-Auth, Host-Key-Verifikation (TOFU), Datei-Transfers, Reconnect, alle UI. Das `RemoteFileSystem`-Protocol startet mit `list`/`stat` und wächst in M2 um die Transfer-Operationen.

**Commit-Konvention:** Conventional Commits, Footer `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`. Push nur am Ende des Plans, nicht pro Task.

---

## Voraussetzungen (einmalig prüfen)

- [ ] `swift --version` → Swift 6.x (Xcode 16+). Falls älter: Xcode aktualisieren, bevor es losgeht.
- [ ] `docker --version` → Docker läuft (für Task 6/7).

## Datei-Struktur (Endzustand von M1)

```
Package.swift
.gitignore
Sources/
  macSCPCore/
    RemoteFS/
      RemoteFileItem.swift      # Modell: Datei/Verzeichnis-Eintrag + RemotePath-Helfer
      RemoteFSError.swift       # Typisierte Fehler der Schicht
      RemoteFileSystem.swift    # Das zentrale Protocol
    SSH/
      SSHConnectionConfig.swift # Validierte Verbindungsparameter
      SFTPAttributeMapper.swift # Pure Mapping-Logik SFTP-Attribute → RemoteFileItem
      CitadelFileSystem.swift   # Citadel-Implementierung des Protocols
  MacSCPCLI/
    MacSCPCLI.swift             # CLI-Treiber (@main, daher NICHT main.swift nennen)
Tests/
  macSCPCoreTests/
    RemotePathTests.swift
    MockRemoteFileSystem.swift  # Test-Double, wird ab M2 wiederverwendet
    MockRemoteFileSystemTests.swift
    SSHConnectionConfigTests.swift
    SFTPAttributeMapperTests.swift
    CitadelFileSystemIntegrationTests.swift  # env-gated, braucht Docker
docker/
  test-server/
    compose.yml
    seed/
      hello.txt
      sub/.gitkeep
.github/workflows/ci.yml
```

---

### Task 1: Package-Gerüst

**Files:**
- Create: `Package.swift`
- Create: `.gitignore`
- Create: `Sources/macSCPCore/RemoteFS/RemoteFileItem.swift` (leerer Platzhalter-Inhalt, Task 2 füllt ihn)
- Create: `Tests/macSCPCoreTests/RemotePathTests.swift` (leerer Platzhalter)

- [ ] **Step 1: Package.swift anlegen**

```swift
// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "macSCP",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "macSCPCore", targets: ["macSCPCore"]),
        .executable(name: "macscp-cli", targets: ["MacSCPCLI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/orlandos-nl/Citadel.git", from: "0.12.1"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
    ],
    targets: [
        .target(
            name: "macSCPCore",
            dependencies: [.product(name: "Citadel", package: "Citadel")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "MacSCPCLI",
            dependencies: [
                "macSCPCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "macSCPCoreTests",
            dependencies: ["macSCPCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
```

Hinweis: Language Mode v5, weil Citadels NIO-Typen unter Swift-6-Strict-Concurrency
sonst unnötige Reibung erzeugen. Umstellung auf v6 ist bewusst nicht Teil von M1.

- [ ] **Step 2: .gitignore anlegen**

```
.build/
.swiftpm/
DerivedData/
xcuserdata/
*.xcodeproj
.DS_Store
```

- [ ] **Step 3: Minimal-Quelldateien anlegen, damit die Targets bauen**

`Sources/macSCPCore/RemoteFS/RemoteFileItem.swift`:
```swift
// Wird in Task 2 implementiert.
```

`Sources/MacSCPCLI/MacSCPCLI.swift`:
```swift
@main
struct MacSCPCLI {
    static func main() {
        print("macscp-cli — M1 in Arbeit")
    }
}
```

`Tests/macSCPCoreTests/RemotePathTests.swift`:
```swift
import Testing
@testable import macSCPCore
```

- [ ] **Step 4: Build + leerer Testlauf**

Run: `swift build && swift test`
Expected: `Build complete!`, Testlauf grün mit 0 Tests. (Erster Lauf lädt Citadel + Abhängigkeiten, dauert ein paar Minuten.)

- [ ] **Step 5: Commit**

```bash
git add Package.swift Package.resolved .gitignore Sources/ Tests/
git commit -m "build: scaffold Swift package with Citadel dependency"
```

---

### Task 2: RemoteFileItem, RemotePath, RemoteFSError

**Files:**
- Modify: `Sources/macSCPCore/RemoteFS/RemoteFileItem.swift`
- Create: `Sources/macSCPCore/RemoteFS/RemoteFSError.swift`
- Modify: `Tests/macSCPCoreTests/RemotePathTests.swift`

- [ ] **Step 1: Failing Tests für RemotePath schreiben**

`Tests/macSCPCoreTests/RemotePathTests.swift`:
```swift
import Testing
@testable import macSCPCore

@Suite("RemotePath")
struct RemotePathTests {
    @Test func joinAppendsComponent() {
        #expect(RemotePath.join("/home/user", "docs") == "/home/user/docs")
    }

    @Test func joinHandlesTrailingSlash() {
        #expect(RemotePath.join("/home/user/", "docs") == "/home/user/docs")
    }

    @Test func joinOnRoot() {
        #expect(RemotePath.join("/", "etc") == "/etc")
    }

    @Test func parentOfNestedPath() {
        #expect(RemotePath.parent(of: "/home/user/docs") == "/home/user")
    }

    @Test func parentOfTopLevelIsRoot() {
        #expect(RemotePath.parent(of: "/etc") == "/")
    }

    @Test func parentOfRootIsRoot() {
        #expect(RemotePath.parent(of: "/") == "/")
    }
}
```

- [ ] **Step 2: Testlauf — muss fehlschlagen**

Run: `swift test --filter RemotePathTests`
Expected: Compile-Fehler `cannot find 'RemotePath' in scope`

- [ ] **Step 3: Modelle implementieren**

`Sources/macSCPCore/RemoteFS/RemoteFileItem.swift` (Platzhalter ersetzen):
```swift
import Foundation

public enum RemoteFileKind: Equatable, Sendable {
    case file
    case directory
    case symlink
    case other
}

public struct RemoteFileItem: Equatable, Sendable {
    public let name: String
    public let path: String
    public let kind: RemoteFileKind
    public let size: UInt64?
    public let modifiedAt: Date?
    /// POSIX-Rechte ohne Dateityp-Bits, z.B. 0o644
    public let permissions: UInt32?

    public init(
        name: String,
        path: String,
        kind: RemoteFileKind,
        size: UInt64? = nil,
        modifiedAt: Date? = nil,
        permissions: UInt32? = nil
    ) {
        self.name = name
        self.path = path
        self.kind = kind
        self.size = size
        self.modifiedAt = modifiedAt
        self.permissions = permissions
    }

    public var isDirectory: Bool { kind == .directory }
}

public enum RemotePath {
    public static func join(_ base: String, _ component: String) -> String {
        base.hasSuffix("/") ? base + component : base + "/" + component
    }

    public static func parent(of path: String) -> String {
        guard path != "/" else { return "/" }
        let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
        guard let idx = trimmed.lastIndex(of: "/") else { return "/" }
        let parent = String(trimmed[..<idx])
        return parent.isEmpty ? "/" : parent
    }
}
```

`Sources/macSCPCore/RemoteFS/RemoteFSError.swift`:
```swift
public enum RemoteFSError: Error, Equatable, Sendable {
    case connectionFailed(reason: String)
    case authenticationFailed
    case notFound(path: String)
    case permissionDenied(path: String)
    case protocolError(reason: String)
}
```

- [ ] **Step 4: Testlauf — muss grün sein**

Run: `swift test --filter RemotePathTests`
Expected: 6 Tests PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/macSCPCore/RemoteFS/ Tests/macSCPCoreTests/RemotePathTests.swift
git commit -m "feat: add remote file model, path helpers and typed errors"
```

---

### Task 3: RemoteFileSystem-Protocol + Mock

**Files:**
- Create: `Sources/macSCPCore/RemoteFS/RemoteFileSystem.swift`
- Create: `Tests/macSCPCoreTests/MockRemoteFileSystem.swift`
- Create: `Tests/macSCPCoreTests/MockRemoteFileSystemTests.swift`

- [ ] **Step 1: Failing Tests schreiben**

`Tests/macSCPCoreTests/MockRemoteFileSystemTests.swift`:
```swift
import Testing
@testable import macSCPCore

@Suite("MockRemoteFileSystem")
struct MockRemoteFileSystemTests {
    private func makeMock() -> MockRemoteFileSystem {
        MockRemoteFileSystem(tree: [
            "/": [
                RemoteFileItem(name: "readme.txt", path: "/readme.txt", kind: .file, size: 12),
                RemoteFileItem(name: "docs", path: "/docs", kind: .directory),
            ],
            "/docs": [
                RemoteFileItem(name: "spec.md", path: "/docs/spec.md", kind: .file, size: 400),
            ],
        ])
    }

    @Test func listsSeededDirectory() async throws {
        let fs = makeMock()
        let items = try await fs.list(path: "/")
        #expect(items.map(\.name) == ["readme.txt", "docs"])
    }

    @Test func listUnknownPathThrowsNotFound() async {
        let fs = makeMock()
        await #expect(throws: RemoteFSError.notFound(path: "/nope")) {
            _ = try await fs.list(path: "/nope")
        }
    }

    @Test func statFindsItemViaParentListing() async throws {
        let fs = makeMock()
        let item = try await fs.stat(path: "/docs/spec.md")
        #expect(item.name == "spec.md")
        #expect(item.kind == .file)
    }

    @Test func statUnknownPathThrowsNotFound() async {
        let fs = makeMock()
        await #expect(throws: RemoteFSError.notFound(path: "/docs/ghost.md")) {
            _ = try await fs.stat(path: "/docs/ghost.md")
        }
    }
}
```

- [ ] **Step 2: Testlauf — muss fehlschlagen**

Run: `swift test --filter MockRemoteFileSystemTests`
Expected: Compile-Fehler `cannot find 'MockRemoteFileSystem' in scope`

- [ ] **Step 3: Protocol + Mock implementieren**

`Sources/macSCPCore/RemoteFS/RemoteFileSystem.swift`:
```swift
/// Abstraktion über ein entferntes Dateisystem.
/// M1: nur Lesen (list/stat). Transfer-Operationen kommen in M2 dazu.
public protocol RemoteFileSystem: Sendable {
    func list(path: String) async throws -> [RemoteFileItem]
    func stat(path: String) async throws -> RemoteFileItem
    func disconnect() async
}
```

`Tests/macSCPCoreTests/MockRemoteFileSystem.swift`:
```swift
@testable import macSCPCore

/// Test-Double mit fest verdrahtetem Verzeichnisbaum.
/// Schlüssel = Verzeichnispfad, Wert = dessen Einträge.
actor MockRemoteFileSystem: RemoteFileSystem {
    private let tree: [String: [RemoteFileItem]]

    init(tree: [String: [RemoteFileItem]]) {
        self.tree = tree
    }

    func list(path: String) async throws -> [RemoteFileItem] {
        guard let items = tree[path] else {
            throw RemoteFSError.notFound(path: path)
        }
        return items
    }

    func stat(path: String) async throws -> RemoteFileItem {
        let parent = RemotePath.parent(of: path)
        guard let siblings = tree[parent],
              let item = siblings.first(where: { $0.path == path }) else {
            throw RemoteFSError.notFound(path: path)
        }
        return item
    }

    func disconnect() async {}
}
```

- [ ] **Step 4: Testlauf — muss grün sein**

Run: `swift test --filter MockRemoteFileSystemTests`
Expected: 4 Tests PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/macSCPCore/RemoteFS/RemoteFileSystem.swift Tests/macSCPCoreTests/
git commit -m "feat: add RemoteFileSystem protocol with mock implementation"
```

---

### Task 4: SSHConnectionConfig

**Files:**
- Create: `Sources/macSCPCore/SSH/SSHConnectionConfig.swift`
- Create: `Tests/macSCPCoreTests/SSHConnectionConfigTests.swift`

- [ ] **Step 1: Failing Tests schreiben**

`Tests/macSCPCoreTests/SSHConnectionConfigTests.swift`:
```swift
import Testing
@testable import macSCPCore

@Suite("SSHConnectionConfig")
struct SSHConnectionConfigTests {
    @Test func defaultsToPort22() throws {
        let config = try SSHConnectionConfig(host: "example.com", username: "tim", auth: .password("x"))
        #expect(config.port == 22)
    }

    @Test func emptyHostThrows() {
        #expect(throws: SSHConnectionConfig.ConfigError.emptyHost) {
            _ = try SSHConnectionConfig(host: "", username: "tim", auth: .password("x"))
        }
    }

    @Test func emptyUsernameThrows() {
        #expect(throws: SSHConnectionConfig.ConfigError.emptyUsername) {
            _ = try SSHConnectionConfig(host: "example.com", username: "", auth: .password("x"))
        }
    }

    @Test func portOutOfRangeThrows() {
        #expect(throws: SSHConnectionConfig.ConfigError.invalidPort(70000)) {
            _ = try SSHConnectionConfig(host: "example.com", port: 70000, username: "tim", auth: .password("x"))
        }
    }
}
```

- [ ] **Step 2: Testlauf — muss fehlschlagen**

Run: `swift test --filter SSHConnectionConfigTests`
Expected: Compile-Fehler `cannot find 'SSHConnectionConfig' in scope`

- [ ] **Step 3: Implementieren**

`Sources/macSCPCore/SSH/SSHConnectionConfig.swift`:
```swift
public struct SSHConnectionConfig: Equatable, Sendable {
    /// M1: nur Passwort. Key- und Agent-Auth kommen in M3 (Session-Manager).
    public enum AuthMethod: Equatable, Sendable {
        case password(String)
    }

    public enum ConfigError: Error, Equatable, Sendable {
        case emptyHost
        case emptyUsername
        case invalidPort(Int)
    }

    public let host: String
    public let port: Int
    public let username: String
    public let auth: AuthMethod

    public init(host: String, port: Int = 22, username: String, auth: AuthMethod) throws {
        guard !host.isEmpty else { throw ConfigError.emptyHost }
        guard (1...65535).contains(port) else { throw ConfigError.invalidPort(port) }
        guard !username.isEmpty else { throw ConfigError.emptyUsername }
        self.host = host
        self.port = port
        self.username = username
        self.auth = auth
    }
}
```

- [ ] **Step 4: Testlauf — muss grün sein**

Run: `swift test --filter SSHConnectionConfigTests`
Expected: 4 Tests PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/macSCPCore/SSH/ Tests/macSCPCoreTests/SSHConnectionConfigTests.swift
git commit -m "feat: add validated SSH connection config"
```

---

### Task 5: SFTPAttributeMapper (pure Mapping-Logik)

**Files:**
- Create: `Sources/macSCPCore/SSH/SFTPAttributeMapper.swift`
- Create: `Tests/macSCPCoreTests/SFTPAttributeMapperTests.swift`

Die Übersetzung von SFTP-Rohdaten in `RemoteFileItem` ist pure Logik — sie wird
hier ohne Citadel-Typen testbar gemacht (Primitive rein, Modell raus). Die dünne
Citadel-Schicht in Task 6 ruft nur noch diesen Mapper.

- [ ] **Step 1: Failing Tests schreiben**

`Tests/macSCPCoreTests/SFTPAttributeMapperTests.swift`:
```swift
import Foundation
import Testing
@testable import macSCPCore

@Suite("SFTPAttributeMapper")
struct SFTPAttributeMapperTests {
    @Test func directoryBitYieldsDirectoryKind() {
        #expect(SFTPAttributeMapper.kind(fromPermissions: 0o040755) == .directory)
    }

    @Test func regularFileBitYieldsFileKind() {
        #expect(SFTPAttributeMapper.kind(fromPermissions: 0o100644) == .file)
    }

    @Test func symlinkBitYieldsSymlinkKind() {
        #expect(SFTPAttributeMapper.kind(fromPermissions: 0o120777) == .symlink)
    }

    @Test func missingPermissionsYieldOtherKind() {
        #expect(SFTPAttributeMapper.kind(fromPermissions: nil) == .other)
    }

    @Test func itemStripsFileTypeBitsFromPermissions() {
        let item = SFTPAttributeMapper.item(
            name: "notes.txt",
            directory: "/home/tim",
            size: 1024,
            permissions: 0o100644,
            modifiedAt: nil
        )
        #expect(item.path == "/home/tim/notes.txt")
        #expect(item.kind == .file)
        #expect(item.permissions == 0o644)
        #expect(item.size == 1024)
    }
}
```

- [ ] **Step 2: Testlauf — muss fehlschlagen**

Run: `swift test --filter SFTPAttributeMapperTests`
Expected: Compile-Fehler `cannot find 'SFTPAttributeMapper' in scope`

- [ ] **Step 3: Implementieren**

`Sources/macSCPCore/SSH/SFTPAttributeMapper.swift`:
```swift
import Foundation

/// Übersetzt SFTP-Attribut-Primitive in RemoteFileItem.
/// Bewusst frei von Citadel-Typen, damit pur testbar.
enum SFTPAttributeMapper {
    private static let typeMask: UInt32 = 0o170000
    private static let directoryBits: UInt32 = 0o040000
    private static let symlinkBits: UInt32 = 0o120000
    private static let regularFileBits: UInt32 = 0o100000

    static func kind(fromPermissions permissions: UInt32?) -> RemoteFileKind {
        guard let permissions else { return .other }
        switch permissions & typeMask {
        case directoryBits: return .directory
        case symlinkBits: return .symlink
        case regularFileBits: return .file
        default: return .other
        }
    }

    static func item(
        name: String,
        directory: String,
        size: UInt64?,
        permissions: UInt32?,
        modifiedAt: Date?
    ) -> RemoteFileItem {
        RemoteFileItem(
            name: name,
            path: RemotePath.join(directory, name),
            kind: kind(fromPermissions: permissions),
            size: size,
            modifiedAt: modifiedAt,
            permissions: permissions.map { $0 & 0o7777 }
        )
    }
}
```

- [ ] **Step 4: Testlauf — muss grün sein**

Run: `swift test --filter SFTPAttributeMapperTests`
Expected: 5 Tests PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/macSCPCore/SSH/SFTPAttributeMapper.swift Tests/macSCPCoreTests/SFTPAttributeMapperTests.swift
git commit -m "feat: map SFTP attributes to remote file items"
```

---

### Task 6: CitadelFileSystem + Docker-Integrationstest

**Files:**
- Create: `Sources/macSCPCore/SSH/CitadelFileSystem.swift`
- Create: `docker/test-server/compose.yml`
- Create: `docker/test-server/seed/hello.txt`
- Create: `docker/test-server/seed/sub/.gitkeep`
- Create: `Tests/macSCPCoreTests/CitadelFileSystemIntegrationTests.swift`

Die Citadel-Schicht ist bewusst dünn (verbinden, delegieren, Fehler mappen) und
wird ausschließlich per Integrationstest gegen einen echten SSH-Server geprüft.
Der Test ist über die Umgebungsvariable `MACSCP_ITEST=1` geschaltet, damit
`swift test` ohne Docker (z.B. in CI) grün bleibt.

- [ ] **Step 1: Docker-Testserver definieren**

`docker/test-server/compose.yml`:
```yaml
services:
  sshd:
    image: lscr.io/linuxserver/openssh-server:latest
    container_name: macscp-test-sshd
    ports:
      - "2222:2222"
    environment:
      - PUID=1000
      - PGID=1000
      - PASSWORD_ACCESS=true
      - USER_NAME=testuser
      - USER_PASSWORD=testpass
    volumes:
      - ./seed:/data/seed:ro
```

`docker/test-server/seed/hello.txt`:
```
hello from macSCP test server
```

`docker/test-server/seed/sub/.gitkeep`: leere Datei.

- [ ] **Step 2: Server starten und manuell verifizieren**

Run:
```bash
docker compose -f docker/test-server/compose.yml up -d
sleep 5
ssh -o StrictHostKeyChecking=no -p 2222 testuser@localhost "ls /data/seed" || true
```
Expected: Passwort-Prompt bzw. mit `sshpass`/manueller Eingabe: `hello.txt` und `sub`. Wichtig ist: Port 2222 antwortet.

- [ ] **Step 3: Failing Integrationstest schreiben**

`Tests/macSCPCoreTests/CitadelFileSystemIntegrationTests.swift`:
```swift
import Foundation
import Testing
@testable import macSCPCore

/// Läuft nur mit MACSCP_ITEST=1 und laufendem Docker-Testserver
/// (docker compose -f docker/test-server/compose.yml up -d).
@Suite(
    "CitadelFileSystem gegen Docker-SSH-Server",
    .enabled(if: ProcessInfo.processInfo.environment["MACSCP_ITEST"] == "1"),
    .serialized
)
struct CitadelFileSystemIntegrationTests {
    private func connect() async throws -> CitadelFileSystem {
        let config = try SSHConnectionConfig(
            host: "127.0.0.1",
            port: 2222,
            username: "testuser",
            auth: .password("testpass")
        )
        return try await CitadelFileSystem.connect(config: config)
    }

    @Test func listsSeededDirectory() async throws {
        let fs = try await connect()
        defer { Task { await fs.disconnect() } }

        let items = try await fs.list(path: "/data/seed")
        let names = items.map(\.name)
        #expect(names.contains("hello.txt"))
        #expect(names.contains("sub"))
        #expect(items.first { $0.name == "sub" }?.kind == .directory)
        #expect(items.first { $0.name == "hello.txt" }?.kind == .file)
    }

    @Test func statReturnsFileDetails() async throws {
        let fs = try await connect()
        defer { Task { await fs.disconnect() } }

        let item = try await fs.stat(path: "/data/seed/hello.txt")
        #expect(item.kind == .file)
        #expect((item.size ?? 0) > 0)
    }

    @Test func wrongPasswordThrowsAuthenticationFailed() async throws {
        let config = try SSHConnectionConfig(
            host: "127.0.0.1",
            port: 2222,
            username: "testuser",
            auth: .password("WRONG")
        )
        await #expect(throws: RemoteFSError.authenticationFailed) {
            _ = try await CitadelFileSystem.connect(config: config)
        }
    }
}
```

- [ ] **Step 4: Testlauf — muss fehlschlagen**

Run: `MACSCP_ITEST=1 swift test --filter CitadelFileSystem`
Expected: Compile-Fehler `cannot find 'CitadelFileSystem' in scope`

- [ ] **Step 5: CitadelFileSystem implementieren**

`Sources/macSCPCore/SSH/CitadelFileSystem.swift`:
```swift
import Citadel
import Foundation

/// SFTP-Implementierung von RemoteFileSystem auf Basis von Citadel.
/// M1: Passwort-Auth, keine Host-Key-Prüfung (TOFU kommt in M3).
public final class CitadelFileSystem: RemoteFileSystem, @unchecked Sendable {
    private let client: SSHClient
    private let sftp: SFTPClient

    private init(client: SSHClient, sftp: SFTPClient) {
        self.client = client
        self.sftp = sftp
    }

    public static func connect(config: SSHConnectionConfig) async throws -> CitadelFileSystem {
        let authMethod: SSHAuthenticationMethod
        switch config.auth {
        case .password(let password):
            authMethod = .passwordBased(username: config.username, password: password)
        }

        do {
            let client = try await SSHClient.connect(
                host: config.host,
                port: config.port,
                authenticationMethod: authMethod,
                hostKeyValidator: .acceptAnything(),
                reconnect: .never
            )
            let sftp = try await client.openSFTP()
            return CitadelFileSystem(client: client, sftp: sftp)
        } catch let error as SSHClientError {
            switch error {
            case .allAuthenticationOptionsFailed:
                throw RemoteFSError.authenticationFailed
            default:
                throw RemoteFSError.connectionFailed(reason: String(describing: error))
            }
        } catch let error as RemoteFSError {
            throw error
        } catch {
            throw RemoteFSError.connectionFailed(reason: String(describing: error))
        }
    }

    public func list(path: String) async throws -> [RemoteFileItem] {
        let names = try await sftp.listDirectory(atPath: path)
        return names
            .flatMap { $0.components }
            .filter { $0.filename != "." && $0.filename != ".." }
            .map { component in
                SFTPAttributeMapper.item(
                    name: component.filename,
                    directory: path,
                    size: component.attributes.size,
                    permissions: component.attributes.permissions,
                    modifiedAt: component.attributes.accessModificationTime?.modificationTime
                )
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public func stat(path: String) async throws -> RemoteFileItem {
        let attributes = try await sftp.getAttributes(at: path)
        let name = path == "/" ? "/" : String(path.split(separator: "/").last ?? "")
        return SFTPAttributeMapper.item(
            name: name,
            directory: RemotePath.parent(of: path),
            size: attributes.size,
            permissions: attributes.permissions,
            modifiedAt: attributes.accessModificationTime?.modificationTime
        )
    }

    public func disconnect() async {
        try? await client.close()
    }
}
```

**Abgleich mit Citadel 0.12.x:** Die Signaturen `SSHClient.connect(host:port:authenticationMethod:hostKeyValidator:reconnect:)`, `listDirectory(atPath:) -> [SFTPMessage.Name]` und `getAttributes(at:)` sind gegen den Stand 04/2026 verifiziert. Falls der Compiler bei `SSHClientError`-Cases, `SFTPMessage.Name.components`, den Property-Namen von `SFTPFileAttributes` (`size`/`permissions`/`accessModificationTime`) oder einer inzwischen Settings-basierten connect-API (`SSHClientSettings` + `SSHClient.connect(to:)`) meckert: exakte Namen in `.build/checkouts/Citadel/Sources/Citadel/` nachschlagen und nur die Aufruf-Stellen anpassen — Protocol und Mapper bleiben unverändert.

- [ ] **Step 6: Unit-Tests bleiben grün (ohne Docker-Abhängigkeit)**

Run: `swift test`
Expected: alle bisherigen Tests PASS; die Integrationstests werden als "skipped" gemeldet (Gate nicht gesetzt).

- [ ] **Step 7: Integrationstest gegen laufenden Server**

Run: `MACSCP_ITEST=1 swift test --filter CitadelFileSystem`
Expected: 3 Tests PASS

- [ ] **Step 8: Commit**

```bash
git add Sources/macSCPCore/SSH/CitadelFileSystem.swift docker/ Tests/macSCPCoreTests/CitadelFileSystemIntegrationTests.swift
git commit -m "feat: add Citadel-backed SFTP file system with integration tests"
```

---

### Task 7: CLI-Treiber

**Files:**
- Modify: `Sources/MacSCPCLI/MacSCPCLI.swift`

- [ ] **Step 1: CLI implementieren**

`Sources/MacSCPCLI/MacSCPCLI.swift` (Platzhalter komplett ersetzen):
```swift
import ArgumentParser
import Foundation
import macSCPCore

@main
struct MacSCPCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "macscp-cli",
        abstract: "Listet ein Remote-Verzeichnis über SFTP (M1-Treiber)."
    )

    @Option(name: .long, help: "SSH-Host") var host: String
    @Option(name: .long, help: "SSH-Port") var port: Int = 22
    @Option(name: .long, help: "Benutzername") var user: String
    @Argument(help: "Remote-Pfad") var path: String = "/"

    func run() async throws {
        guard let password = ProcessInfo.processInfo.environment["MACSCP_PASSWORD"],
              !password.isEmpty else {
            throw ValidationError("Passwort über die Umgebungsvariable MACSCP_PASSWORD setzen.")
        }

        let config = try SSHConnectionConfig(host: host, port: port, username: user, auth: .password(password))
        let fs = try await CitadelFileSystem.connect(config: config)

        do {
            let items = try await fs.list(path: path)
            let formatter = ByteCountFormatter()
            for item in items {
                let size = item.size.map { formatter.string(fromByteCount: Int64($0)) } ?? "-"
                let suffix = item.isDirectory ? "/" : ""
                print("\(item.name)\(suffix)\t\(size)")
            }
        } catch {
            await fs.disconnect()
            throw error
        }
        await fs.disconnect()
    }
}
```

- [ ] **Step 2: Build**

Run: `swift build`
Expected: `Build complete!`

- [ ] **Step 3: Manuell gegen den Docker-Server verifizieren**

Run:
```bash
MACSCP_PASSWORD=testpass swift run macscp-cli --host 127.0.0.1 --port 2222 --user testuser /data/seed
```
Expected:
```
hello.txt	30 Bytes
sub/	-
```
(Byte-Zahl kann leicht abweichen; entscheidend: beide Einträge, `sub` mit `/`.)

- [ ] **Step 4: Fehlerfall verifizieren**

Run: `MACSCP_PASSWORD=falsch swift run macscp-cli --host 127.0.0.1 --port 2222 --user testuser /data/seed; echo "exit=$?"`
Expected: Fehlermeldung (authenticationFailed), `exit=1` — kein Stacktrace-Crash.

- [ ] **Step 5: Commit**

```bash
git add Sources/MacSCPCLI/MacSCPCLI.swift
git commit -m "feat: add CLI driver to list remote directories"
```

---

### Task 8: CI-Workflow + Aufräumen

**Files:**
- Create: `.github/workflows/ci.yml`

- [ ] **Step 1: Workflow anlegen**

`.github/workflows/ci.yml`:
```yaml
name: CI

on:
  push:
    branches: [main]
  pull_request:

jobs:
  test:
    runs-on: macos-15
    steps:
      - uses: actions/checkout@v4
      - name: Build
        run: swift build
      - name: Unit-Tests
        run: swift test
```

Hinweis: GitHub-macOS-Runner haben kein Docker — die Integrationstests bleiben
dort durch das `MACSCP_ITEST`-Gate automatisch übersprungen und laufen nur lokal.

- [ ] **Step 2: Kompletter lokaler Testlauf als Abschluss-Beweis**

Run:
```bash
swift test && MACSCP_ITEST=1 swift test --filter CitadelFileSystem
docker compose -f docker/test-server/compose.yml down
```
Expected: alle Tests PASS, Container gestoppt.

- [ ] **Step 3: Commit + Push**

```bash
git add .github/
git commit -m "ci: build and run unit tests on pull requests"
git push
```

- [ ] **Step 4: CI-Lauf prüfen**

Run: `gh run watch --repo NoiXdev/macSCP --exit-status || gh run list --repo NoiXdev/macSCP --limit 1`
Expected: Workflow grün.

---

## Definition of Done (M1)

- `swift test` grün ohne Docker (Integrationstests sauber übersprungen)
- `MACSCP_ITEST=1 swift test` grün mit laufendem Docker-Testserver
- CLI listet ein echtes Remote-Verzeichnis und behandelt falsche Passwörter mit sauberer Fehlermeldung
- CI auf GitHub grün
- Damit ist die riskanteste Annahme des Projekts (Citadel trägt SFTP) bewiesen; M2 (Zwei-Fenster-Browser) kann geplant werden
