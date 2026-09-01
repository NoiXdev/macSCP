# macSCP M1 — core proof: implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Swift package `macSCPCore` with a `RemoteFileSystem` abstraction,
a Citadel SFTP implementation (password auth), and a CLI driver that lists
a remote directory — proved against a local Docker SSH server.

**Architecture:** A UI-free SPM package with three layers: `RemoteFS`
(protocol + models), `SSH` (config + Citadel binding), a CLI executable as
the driver. All core logic is testable against the protocol (mock); the
Citadel layer is verified by an integration test against Docker.

**Tech Stack:** Swift 6 toolchain (Language Mode v5), SPM,
[Citadel 0.12.x](https://github.com/orlandos-nl/Citadel),
swift-argument-parser, Swift Testing, Docker (`linuxserver/openssh-server`)
for integration tests.

**Spec:** `docs/superpowers/specs/2026-07-09-macscp-design.md`

**Deliberately NOT in M1** (comes in M2–M5): key/agent auth, host-key
verification (TOFU), file transfers, reconnect, all UI. The
`RemoteFileSystem` protocol starts with `list`/`stat` and grows the
transfer operations in M2.

**Commit convention:** Conventional Commits, footer
`Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`. Push only at the
end of the plan, not per task.

---

## Prerequisites (check once)

- [x] `swift --version` → Swift 6.x (Xcode 16+). If older: update Xcode before starting.
- [x] `docker --version` → Docker is running (for Task 6/7).

## File structure (end state of M1)

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

### Task 1: Package scaffold

**Files:**
- Create: `Package.swift`
- Create: `.gitignore`
- Create: `Sources/macSCPCore/RemoteFS/RemoteFileItem.swift` (empty placeholder content, Task 2 fills it in)
- Create: `Tests/macSCPCoreTests/RemotePathTests.swift` (empty placeholder)

- [x] **Step 1: Create Package.swift**

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

Note: Language Mode v5, because Citadel's NIO types would otherwise create
unnecessary friction under Swift 6 strict concurrency. Switching to v6 is
deliberately not part of M1.

- [x] **Step 2: Create .gitignore**

```
.build/
.swiftpm/
DerivedData/
xcuserdata/
*.xcodeproj
.DS_Store
```

- [x] **Step 3: Create minimal source files so the targets build**

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

- [x] **Step 4: Build + empty test run**

Run: `swift build && swift test`
Expected: `Build complete!`, test run green with 0 tests. (First run
downloads Citadel + dependencies, takes a few minutes.)

- [x] **Step 5: Commit**

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

- [x] **Step 1: Write failing tests for RemotePath**

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

- [x] **Step 2: Test run — must fail**

Run: `swift test --filter RemotePathTests`
Expected: compile error `cannot find 'RemotePath' in scope`

- [x] **Step 3: Implement the models**

`Sources/macSCPCore/RemoteFS/RemoteFileItem.swift` (replace the placeholder):
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

- [x] **Step 4: Test run — must be green**

Run: `swift test --filter RemotePathTests`
Expected: 6 tests PASS

- [x] **Step 5: Commit**

```bash
git add Sources/macSCPCore/RemoteFS/ Tests/macSCPCoreTests/RemotePathTests.swift
git commit -m "feat: add remote file model, path helpers and typed errors"
```

---

### Task 3: RemoteFileSystem protocol + mock

**Files:**
- Create: `Sources/macSCPCore/RemoteFS/RemoteFileSystem.swift`
- Create: `Tests/macSCPCoreTests/MockRemoteFileSystem.swift`
- Create: `Tests/macSCPCoreTests/MockRemoteFileSystemTests.swift`

- [x] **Step 1: Write failing tests**

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

- [x] **Step 2: Test run — must fail**

Run: `swift test --filter MockRemoteFileSystemTests`
Expected: compile error `cannot find 'MockRemoteFileSystem' in scope`

- [x] **Step 3: Implement protocol + mock**

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

- [x] **Step 4: Test run — must be green**

Run: `swift test --filter MockRemoteFileSystemTests`
Expected: 4 tests PASS

- [x] **Step 5: Commit**

```bash
git add Sources/macSCPCore/RemoteFS/RemoteFileSystem.swift Tests/macSCPCoreTests/
git commit -m "feat: add RemoteFileSystem protocol with mock implementation"
```

---

### Task 4: SSHConnectionConfig

**Files:**
- Create: `Sources/macSCPCore/SSH/SSHConnectionConfig.swift`
- Create: `Tests/macSCPCoreTests/SSHConnectionConfigTests.swift`

- [x] **Step 1: Write failing tests**

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

- [x] **Step 2: Test run — must fail**

Run: `swift test --filter SSHConnectionConfigTests`
Expected: compile error `cannot find 'SSHConnectionConfig' in scope`

- [x] **Step 3: Implement**

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

- [x] **Step 4: Test run — must be green**

Run: `swift test --filter SSHConnectionConfigTests`
Expected: 4 tests PASS

- [x] **Step 5: Commit**

```bash
git add Sources/macSCPCore/SSH/ Tests/macSCPCoreTests/SSHConnectionConfigTests.swift
git commit -m "feat: add validated SSH connection config"
```

---

### Task 5: SFTPAttributeMapper (pure mapping logic)

**Files:**
- Create: `Sources/macSCPCore/SSH/SFTPAttributeMapper.swift`
- Create: `Tests/macSCPCoreTests/SFTPAttributeMapperTests.swift`

Translating raw SFTP data into `RemoteFileItem` is pure logic — it is made
testable here without Citadel types (primitives in, model out). The thin
Citadel layer in Task 6 then only calls this mapper.

- [x] **Step 1: Write failing tests**

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

- [x] **Step 2: Test run — must fail**

Run: `swift test --filter SFTPAttributeMapperTests`
Expected: compile error `cannot find 'SFTPAttributeMapper' in scope`

- [x] **Step 3: Implement**

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

- [x] **Step 4: Test run — must be green**

Run: `swift test --filter SFTPAttributeMapperTests`
Expected: 5 tests PASS

- [x] **Step 5: Commit**

```bash
git add Sources/macSCPCore/SSH/SFTPAttributeMapper.swift Tests/macSCPCoreTests/SFTPAttributeMapperTests.swift
git commit -m "feat: map SFTP attributes to remote file items"
```

---

### Task 6: CitadelFileSystem + Docker integration test

**Files:**
- Create: `Sources/macSCPCore/SSH/CitadelFileSystem.swift`
- Create: `docker/test-server/compose.yml`
- Create: `docker/test-server/seed/hello.txt`
- Create: `docker/test-server/seed/sub/.gitkeep`
- Create: `Tests/macSCPCoreTests/CitadelFileSystemIntegrationTests.swift`

The Citadel layer is deliberately thin (connect, delegate, map errors) and
is checked exclusively by an integration test against a real SSH server.
The test is gated by the `MACSCP_ITEST=1` environment variable, so that
`swift test` stays green without Docker (e.g. in CI).

- [x] **Step 1: Define the Docker test server**

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

`docker/test-server/seed/sub/.gitkeep`: empty file.

- [x] **Step 2: Start the server and verify manually**

Run:
```bash
docker compose -f docker/test-server/compose.yml up -d
sleep 5
ssh -o StrictHostKeyChecking=no -p 2222 testuser@localhost "ls /data/seed" || true
```
Expected: password prompt, or with `sshpass`/manual entry: `hello.txt` and
`sub`. What matters: port 2222 responds.

- [x] **Step 3: Write the failing integration test**

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

- [x] **Step 4: Test run — must fail**

Run: `MACSCP_ITEST=1 swift test --filter CitadelFileSystem`
Expected: compile error `cannot find 'CitadelFileSystem' in scope`

- [x] **Step 5: Implement CitadelFileSystem**

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

**Reconciliation with Citadel 0.12.x:** The signatures
`SSHClient.connect(host:port:authenticationMethod:hostKeyValidator:reconnect:)`,
`listDirectory(atPath:) -> [SFTPMessage.Name]` and `getAttributes(at:)` are
verified against the state as of 04/2026. If the compiler complains about
`SSHClientError` cases, `SFTPMessage.Name.components`, the property names
of `SFTPFileAttributes` (`size`/`permissions`/`accessModificationTime`), or
a by-then settings-based connect API (`SSHClientSettings` +
`SSHClient.connect(to:)`): look up the exact names in
`.build/checkouts/Citadel/Sources/Citadel/` and adjust only the call sites
— the protocol and the mapper stay unchanged.

- [x] **Step 6: Unit tests stay green (without a Docker dependency)**

Run: `swift test`
Expected: all previous tests PASS; the integration tests are reported as
"skipped" (gate not set).

- [x] **Step 7: Integration test against a running server**

Run: `MACSCP_ITEST=1 swift test --filter CitadelFileSystem`
Expected: 3 tests PASS

- [x] **Step 8: Commit**

```bash
git add Sources/macSCPCore/SSH/CitadelFileSystem.swift docker/ Tests/macSCPCoreTests/CitadelFileSystemIntegrationTests.swift
git commit -m "feat: add Citadel-backed SFTP file system with integration tests"
```

---

### Task 7: CLI driver

**Files:**
- Modify: `Sources/MacSCPCLI/MacSCPCLI.swift`

- [x] **Step 1: Implement the CLI**

`Sources/MacSCPCLI/MacSCPCLI.swift` (replace the placeholder entirely):
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

- [x] **Step 2: Build**

Run: `swift build`
Expected: `Build complete!`

- [x] **Step 3: Verify manually against the Docker server**

Run:
```bash
MACSCP_PASSWORD=testpass swift run macscp-cli --host 127.0.0.1 --port 2222 --user testuser /data/seed
```
Expected:
```
hello.txt	30 Bytes
sub/	-
```
(The byte count may differ slightly; what matters: both entries, `sub`
with `/`.)

- [x] **Step 4: Verify the error case**

Run: `MACSCP_PASSWORD=falsch swift run macscp-cli --host 127.0.0.1 --port 2222 --user testuser /data/seed; echo "exit=$?"`
Expected: error message (authenticationFailed), `exit=1` — no stack-trace
crash.

- [x] **Step 5: Commit**

```bash
git add Sources/MacSCPCLI/MacSCPCLI.swift
git commit -m "feat: add CLI driver to list remote directories"
```

---

### Task 8: CI workflow + cleanup

**Files:**
- Create: `.github/workflows/ci.yml`

- [x] **Step 1: Create the workflow**

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

Note: GitHub macOS runners have no Docker — the integration tests are
automatically skipped there by the `MACSCP_ITEST` gate and only run
locally.

- [x] **Step 2: Complete local test run as closing proof**

Run:
```bash
swift test && MACSCP_ITEST=1 swift test --filter CitadelFileSystem
docker compose -f docker/test-server/compose.yml down
```
Expected: all tests PASS, container stopped.

- [x] **Step 3: Commit + push**

```bash
git add .github/
git commit -m "ci: build and run unit tests on pull requests"
git push
```

- [x] **Step 4: Check the CI run**

Run: `gh run watch --repo NoiXdev/macSCP --exit-status || gh run list --repo NoiXdev/macSCP --limit 1`
Expected: workflow green.

---

## Definition of Done (M1)

- `swift test` green without Docker (integration tests cleanly skipped)
- `MACSCP_ITEST=1 swift test` green with a running Docker test server
- CLI lists a real remote directory and handles wrong passwords with a clean error message
- CI on GitHub green
- This proves the project's riskiest assumption (Citadel carries SFTP); M2 (two-window browser) can be planned
