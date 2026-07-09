# macSCP M2c — Transfers Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Einzelne Dateien zwischen den Panes übertragen — Download (Remote→Lokal) und Upload (Lokal→Remote) per Button, mit Fortschrittsanzeige in den Duo-Farben.

**Architecture:** Das `RemoteFileSystem`-Protocol bekommt Chunk-Streams (`readStream`/`write`), implementiert von Mock, `LocalFileSystem` und `CitadelFileSystem`. Eine richtungs-agnostische `TransferEngine` pumpt Quelle→Ziel und meldet Fortschritt; ein `TransferViewModel` (`@Observable`) hält den UI-Zustand. Die Tabelle bekommt Einfach-Auswahl; `ContentView` verdrahtet zwei Transfer-Buttons (→ Upload, ← Download) und eine Fortschrittsleiste.

**Abhängigkeitsgraph (Parallel-Phasen für den Koordinator):**

```
Task 0 ─→ Task 1 ─→ Task 2 (Citadel-Streams)   ─→ Task 5 ─→ Task 6
      └─→ Task 4 ┐└→ Task 3 (TransferEngine)   ─┘
   (Task 1 ∥ Task 4)   (Task 2 ∥ Task 3 — disjunkte Dateien)
```

**Tech Stack:** wie M2b. Citadel-Datei-API (`openFile`/`read`/`write`) wird in Task 2 gegen `.build/checkouts/Citadel/` verifiziert.

## Global Constraints

- swift-tools-version 6.0, alle Targets Language Mode v5; macOS 14; UI-Texte Deutsch
- Conventional Commits, Footer `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`; niemals pushen (macht der Koordinator)
- YAGNI für M2c: EINE Transfer gleichzeitig, KEIN Abbrechen/Resume/Queue (→ M5), KEINE Verzeichnis-Transfers, KEIN Drag & Drop (→ M2d), KEINE Konfliktdialoge (Ziel wird überschrieben — bewusst, wird in M5 durch Konfliktregeln ersetzt)
- Chunk-Größe einheitlich 64 KiB (`TransferChunk.size`)
- Duo-Farben nur semantisch: Upload Bernstein, Download Ozeanblau
- Nach jedem Task: `swift test` grün (ohne Docker); Citadel-Streams zusätzlich via `MACSCP_ITEST=1` gegen das Docker-Rig

## Datei-Landkarte (Delta M2c)

```
Sources/macSCPCore/
  RemoteFS/RemoteFileSystem.swift       (Task 1 — Protocol + TransferChunk)
  RemoteFS/LocalFileSystem.swift        (Task 0 Pfad-Fix; Task 1 Streams)
  RemoteFS/TransferEngine.swift         (Task 3 — copyFile + TransferProgress)
  Presentation/RemoteBrowserViewModel.swift (Task 0 Kommentar; Task 4 selectedItem)
  Presentation/TransferViewModel.swift  (Task 3 — UI-Zustand)
  SSH/CitadelFileSystem.swift           (Task 2 — Streams)
Sources/MacSCPApp/
  RemoteFileTableView.swift             (Task 4 — Auswahl-Callback)
  BrowserPane.swift                     (Task 4 — Auswahl durchreichen)
  ContentView.swift                     (Task 5 — Buttons + TransferBar)
  TransferBar.swift                     (Task 5 — neu)
Tests/macSCPCoreTests/
  LocalFileSystemTests.swift            (Task 0 +1 Test; Task 1 +2)
  MockRemoteFileSystem.swift            (Task 1 — Streams + Datei-Inhalte)
  StreamRoundtripTests.swift            (Task 1 — neu, 5 Tests)
  TransferEngineTests.swift             (Task 3 — neu, 5 Tests)
  RemoteBrowserViewModelTests.swift     (Task 4 +1 Test)
  CitadelFileSystemIntegrationTests.swift (Task 2 +2 gated Tests)
```

---

### Task 0: Auftakt-Fixes aus dem M2b-Abschluss-Review

**Files:**
- Modify: `Sources/macSCPCore/RemoteFS/LocalFileSystem.swift` (Pfad-Normalisierung in `item(for:)`)
- Modify: `Sources/macSCPCore/Presentation/RemoteBrowserViewModel.swift` (nur Kommentar Zeile ~61)
- Test: `Tests/macSCPCoreTests/LocalFileSystemTests.swift` (+1 Test)

**Interfaces:** keine API-Änderung. Invariante danach: `RemoteFileItem.path` trägt NIE einen Trailing-Slash (außer `/`) — Voraussetzung für Pfad-Vergleiche in Task 3/5.

Bewusst NICHT in diesem Task (dritter Punkt der M2c-Opening-List): das `try?`-Schlucken in `item(for:)`/`stat` bei unlesbaren Pfaden bleibt vorerst — es betrifft nur Metadaten-Anzeige, ein verlässlicher CI-Test dafür ist ohne root-Rechte fragil, und die Transfer-Pfade (readStream/write) mappen Berechtigungsfehler ohnehin typisiert. Wird wieder relevant, wenn M5-Konfliktregeln stat-Metadaten für Entscheidungen nutzen.

- [ ] **Step 1: Fehlschlagender Test** — in `LocalFileSystemTests` ergänzen:

```swift
    @Test func directoryPathsHaveNoTrailingSlash() async throws {
        let root = try makeTempTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let fs = LocalFileSystem()

        let items = try await fs.list(path: root.path(percentEncoded: false))
        let dir = items.first { $0.name == "unterordner" }
        #expect(dir?.path.hasSuffix("/") == false)
        #expect(dir?.path.hasSuffix("unterordner") == true)
    }
```

Run: `swift test --filter LocalFileSystemTests` — der neue Test muss FAILEN (Verzeichnis-URLs liefern Trailing-Slash).

- [ ] **Step 2: Fix** — in `LocalFileSystem.item(for:)` die `path:`-Zeile ersetzen durch normalisierte Variante (vor dem `RemoteFileItem`-Init):

```swift
        var normalizedPath = url.path(percentEncoded: false)
        if normalizedPath.count > 1, normalizedPath.hasSuffix("/") {
            normalizedPath.removeLast()
        }
```

und im Init `path: normalizedPath` verwenden.

- [ ] **Step 3: Kommentar-Fix** — in `RemoteBrowserViewModel.swift` den Kommentar über `sortedForDisplay` ändern zu:

```swift
    /// Verzeichnisse zuerst, dann Name case-insensitiv —
    /// kein Backend sortiert; dies ist die einzige Sortier-Autorität.
```

- [ ] **Step 4: Grün** — `swift test`: 53 Tests grün (52 + 1).

- [ ] **Step 5: Commit**

```bash
git add Sources/macSCPCore/RemoteFS/LocalFileSystem.swift Sources/macSCPCore/Presentation/RemoteBrowserViewModel.swift Tests/macSCPCoreTests/LocalFileSystemTests.swift
git commit -m "fix: normalize directory paths and stale sort comment

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 1: Streams im Protocol (Mock + LocalFileSystem)

**Files:**
- Modify: `Sources/macSCPCore/RemoteFS/RemoteFileSystem.swift`
- Modify: `Sources/macSCPCore/RemoteFS/LocalFileSystem.swift`
- Modify: `Tests/macSCPCoreTests/MockRemoteFileSystem.swift`
- Create: `Tests/macSCPCoreTests/StreamRoundtripTests.swift`

**Interfaces:**
- Produces (für Task 2/3): Protocol-Erweiterung

```swift
public enum TransferChunk {
    /// Einheitliche Chunk-Größe für alle Backends: 64 KiB.
    public static let size = 64 * 1024
}

// im Protocol RemoteFileSystem ergänzt:
    /// Dateiinhalt als Chunk-Strom (Chunks ≤ TransferChunk.size).
    func readStream(path: String) async throws -> AsyncThrowingStream<Data, Error>
    /// Schreibt den Chunk-Strom als Datei; vorhandene Dateien werden überschrieben.
    func write(path: String, contents: AsyncThrowingStream<Data, Error>) async throws
```

- MockRemoteFileSystem zusätzlich: `init(tree:files:)` mit `files: [String: Data] = [:]` (Pfad→Inhalt) und `func writtenData(at path: String) -> Data?` zum Assertieren.

- [ ] **Step 1: Fehlschlagende Tests**

`Tests/macSCPCoreTests/StreamRoundtripTests.swift`:

```swift
import Foundation
import Testing
@testable import macSCPCore

@Suite("Stream-Roundtrips")
struct StreamRoundtripTests {
    @Test func mockReadStreamDeliversSeededData() async throws {
        let fs = MockRemoteFileSystem(
            tree: ["/": [RemoteFileItem(name: "a.bin", path: "/a.bin", kind: .file, size: 5)]],
            files: ["/a.bin": Data("hallo".utf8)]
        )
        var collected = Data()
        for try await chunk in try await fs.readStream(path: "/a.bin") {
            collected.append(chunk)
        }
        #expect(collected == Data("hallo".utf8))
    }

    @Test func mockReadStreamMissingFileThrowsNotFound() async {
        let fs = MockRemoteFileSystem(tree: ["/": []])
        await #expect(throws: RemoteFSError.notFound(path: "/nix")) {
            _ = try await fs.readStream(path: "/nix")
        }
    }

    @Test func mockWriteCollectsChunks() async throws {
        let fs = MockRemoteFileSystem(tree: ["/": []])
        let (stream, continuation) = AsyncThrowingStream<Data, Error>.makeStream()
        continuation.yield(Data("ha".utf8))
        continuation.yield(Data("llo".utf8))
        continuation.finish()
        try await fs.write(path: "/neu.txt", contents: stream)
        #expect(await fs.writtenData(at: "/neu.txt") == Data("hallo".utf8))
    }

    @Test func localRoundtripPreservesContentAcrossChunks() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-stream-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // > 64 KiB, damit mehrere Chunks entstehen
        let original = Data((0..<(TransferChunk.size * 2 + 123)).map { UInt8($0 % 251) })
        let sourceURL = dir.appendingPathComponent("gross.bin")
        try original.write(to: sourceURL)

        let fs = LocalFileSystem()
        let destPath = dir.appendingPathComponent("kopie.bin").path(percentEncoded: false)
        try await fs.write(
            path: destPath,
            contents: try await fs.readStream(path: sourceURL.path(percentEncoded: false))
        )
        let copied = try Data(contentsOf: URL(fileURLWithPath: destPath))
        #expect(copied == original)
    }

    @Test func localReadStreamMissingFileThrowsNotFound() async {
        let fs = LocalFileSystem()
        let missing = "/tmp/macscp-stream-fehlt-\(UUID().uuidString)"
        await #expect(throws: RemoteFSError.notFound(path: missing)) {
            _ = try await fs.readStream(path: missing)
        }
    }
}
```

Run: `swift test --filter StreamRoundtripTests` — Compile-Fehler (Protocol kennt `readStream` nicht, Mock kennt `files:` nicht).

- [ ] **Step 2: Protocol + TransferChunk**

In `Sources/macSCPCore/RemoteFS/RemoteFileSystem.swift` — Datei komplett ersetzen:

```swift
/// Einheitliche Transfer-Chunk-Größe für alle Backends.
public enum TransferChunk {
    public static let size = 64 * 1024
}

/// Abstraktion über ein (entferntes oder lokales) Dateisystem.
/// M1: list/stat. M2c: Chunk-Streams für Einzeldatei-Transfers.
public protocol RemoteFileSystem: Sendable {
    func list(path: String) async throws -> [RemoteFileItem]
    func stat(path: String) async throws -> RemoteFileItem
    /// Dateiinhalt als Chunk-Strom (Chunks ≤ TransferChunk.size).
    func readStream(path: String) async throws -> AsyncThrowingStream<Data, Error>
    /// Schreibt den Chunk-Strom als Datei; vorhandene Dateien werden überschrieben.
    func write(path: String, contents: AsyncThrowingStream<Data, Error>) async throws
    func disconnect() async
}
```

(`import Foundation` ergänzen — `Data`.)

- [ ] **Step 3: Mock erweitern**

`Tests/macSCPCoreTests/MockRemoteFileSystem.swift` — Datei komplett ersetzen:

```swift
import Foundation
@testable import macSCPCore

/// Test-Double mit fest verdrahtetem Verzeichnisbaum und Datei-Inhalten.
/// Invariante: item.path == RemotePath.join(verzeichnisSchlüssel, item.name),
/// sonst findet stat den Eintrag nicht.
actor MockRemoteFileSystem: RemoteFileSystem {
    private let tree: [String: [RemoteFileItem]]
    private var files: [String: Data]
    private var written: [String: Data] = [:]

    init(tree: [String: [RemoteFileItem]], files: [String: Data] = [:]) {
        self.tree = tree
        self.files = files
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

    func readStream(path: String) async throws -> AsyncThrowingStream<Data, Error> {
        guard let data = files[path] else {
            throw RemoteFSError.notFound(path: path)
        }
        return AsyncThrowingStream { continuation in
            var offset = 0
            while offset < data.count {
                let end = min(offset + TransferChunk.size, data.count)
                continuation.yield(data.subdata(in: offset..<end))
                offset = end
            }
            continuation.finish()
        }
    }

    func write(path: String, contents: AsyncThrowingStream<Data, Error>) async throws {
        var collected = Data()
        for try await chunk in contents {
            collected.append(chunk)
        }
        written[path] = collected
        files[path] = collected
    }

    func writtenData(at path: String) -> Data? {
        written[path]
    }

    func disconnect() async {}
}
```

- [ ] **Step 4: LocalFileSystem-Streams**

In `Sources/macSCPCore/RemoteFS/LocalFileSystem.swift` vor `disconnect()` ergänzen:

```swift
    public func readStream(path: String) async throws -> AsyncThrowingStream<Data, Error> {
        let url = URL(fileURLWithPath: path)
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw Self.map(error, path: path)
        }
        // Pull-basiert (unfolding): der Konsument bestimmt das Tempo,
        // es wird nie mehr als ein Chunk gepuffert.
        return AsyncThrowingStream(unfolding: {
            do {
                if let chunk = try handle.read(upToCount: TransferChunk.size),
                   !chunk.isEmpty {
                    return chunk
                }
                try? handle.close()
                return nil
            } catch {
                try? handle.close()
                throw RemoteFSError.protocolError(reason: String(describing: error))
            }
        })
    }

    public func write(path: String, contents: AsyncThrowingStream<Data, Error>) async throws {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.createFile(atPath: url.path(percentEncoded: false), contents: nil) else {
            throw RemoteFSError.permissionDenied(path: path)
        }
        let handle: FileHandle
        do {
            handle = try FileHandle(forWritingTo: url)
        } catch {
            throw Self.map(error, path: path)
        }
        defer { try? handle.close() }
        for try await chunk in contents {
            try handle.write(contentsOf: chunk)
        }
    }
```

Hinweis Fehlermapping: `FileHandle(forReadingFrom:)` wirft bei fehlender Datei einen NSCocoaError, den `Self.map` bereits auf `notFound` übersetzt.

- [ ] **Step 5: Grün** — `swift test --filter StreamRoundtripTests` (5 Tests PASS), dann `swift test` komplett: **58 Tests grün** (53 + 5). ACHTUNG: `CitadelFileSystem` kompiliert jetzt NICHT mehr (Protocol-Lücke) — die Datei bekommt in diesem Task ÜBERGANGSWEISE zwei Stubs, damit das Paket baut:

```swift
    public func readStream(path: String) async throws -> AsyncThrowingStream<Data, Error> {
        throw RemoteFSError.protocolError(reason: "readStream: kommt in M2c Task 2")
    }

    public func write(path: String, contents: AsyncThrowingStream<Data, Error>) async throws {
        throw RemoteFSError.protocolError(reason: "write: kommt in M2c Task 2")
    }
```

(Task 2 ersetzt beide durch echte Implementierungen.)

- [ ] **Step 6: Commit**

```bash
git add Sources/macSCPCore/RemoteFS/ Sources/macSCPCore/SSH/CitadelFileSystem.swift Tests/macSCPCoreTests/
git commit -m "feat: add chunked read and write streams to the file system protocol

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: CitadelFileSystem-Streams + Integrationstests

**Files:**
- Modify: `Sources/macSCPCore/SSH/CitadelFileSystem.swift` (Stubs aus Task 1 ersetzen)
- Modify: `Tests/macSCPCoreTests/CitadelFileSystemIntegrationTests.swift` (+2 Tests)

**Interfaces:** Consumes Task 1 (`TransferChunk`, Protocol-Signaturen). Keine neuen Producer.

**Parallel-Hinweis für den Koordinator:** disjunkt zu Task 3 — parallel ausführbar (Worktree).

- [ ] **Step 1: Fehlschlagende (gated) Tests** — in `CitadelFileSystemIntegrationTests` ergänzen:

```swift
    @Test func readStreamDeliversSeededFileContent() async throws {
        let fs = try await connect()
        defer { Task { await fs.disconnect() } }

        var collected = Data()
        for try await chunk in try await fs.readStream(path: "/data/seed/hello.txt") {
            collected.append(chunk)
        }
        #expect(String(data: collected, encoding: .utf8) == "hello from macSCP test server\n")
    }

    @Test func writeUploadsAndReadsBackRoundtrip() async throws {
        let fs = try await connect()
        defer { Task { await fs.disconnect() } }

        let payload = Data((0..<(TransferChunk.size + 17)).map { UInt8($0 % 199) })
        let (stream, continuation) = AsyncThrowingStream<Data, Error>.makeStream()
        continuation.yield(payload)
        continuation.finish()

        // /config ist das beschreibbare Home von testuser im linuxserver-Image
        let remotePath = "/config/macscp-upload-test.bin"
        try await fs.write(path: remotePath, contents: stream)

        var readBack = Data()
        for try await chunk in try await fs.readStream(path: remotePath) {
            readBack.append(chunk)
        }
        #expect(readBack == payload)
    }
```

Run (Docker-Rig muss laufen): `MACSCP_ITEST=1 swift test --filter CitadelFileSystem`
Expected: die zwei neuen Tests FAILEN mit `protocolError("… kommt in M2c Task 2")`, die vier alten bleiben grün.

- [ ] **Step 2: Implementieren** — die beiden Stubs in `CitadelFileSystem.swift` ersetzen:

```swift
    public func readStream(path: String) async throws -> AsyncThrowingStream<Data, Error> {
        let file: SFTPFile
        do {
            file = try await sftp.openFile(filePath: path, flags: .read)
        } catch {
            throw mapSFTPError(error, path: path)
        }
        // Pull-basiert (unfolding): der Konsument bestimmt das Tempo.
        var offset: UInt64 = 0
        return AsyncThrowingStream(unfolding: {
            do {
                let buffer = try await file.read(
                    from: offset, length: UInt32(TransferChunk.size))
                guard buffer.readableBytes > 0 else {
                    try await file.close()
                    return nil
                }
                offset += UInt64(buffer.readableBytes)
                return Data(buffer.readableBytesView)
            } catch {
                try? await file.close()
                throw self.mapSFTPError(error, path: path)
            }
        })
    }

    public func write(path: String, contents: AsyncThrowingStream<Data, Error>) async throws {
        let file: SFTPFile
        do {
            file = try await sftp.openFile(
                filePath: path,
                flags: [.create, .write, .truncate]
            )
        } catch {
            throw mapSFTPError(error, path: path)
        }
        do {
            var offset: UInt64 = 0
            for try await chunk in contents {
                try await file.write(ByteBuffer(bytes: chunk), at: offset)
                offset += UInt64(chunk.count)
            }
            try await file.close()
        } catch {
            try? await file.close()
            throw mapSFTPError(error, path: path)
        }
    }
```

(`import NIOCore` oben ergänzen, falls `ByteBuffer` nicht sichtbar.)

**API-Drift-Behandlung wie in M1 bewährt:** Falls der Compiler `openFile(filePath:flags:)`, `SFTPOpenFileFlags`-Case-Namen (`.read/.create/.write/.truncate`), `file.read(from:length:) -> ByteBuffer`, `file.write(_:at:)` oder `file.close()` ablehnt: exakte Namen in `.build/checkouts/Citadel/Sources/Citadel/SFTP/` nachschlagen und NUR die Aufrufstellen anpassen — Protocol, Tests und Fehler-Mapping bleiben. Die zwei Integrationstests definieren den Vertrag.

- [ ] **Step 3: Verifizieren** — `swift test` (58 grün, ungated) UND `MACSCP_ITEST=1 swift test --filter CitadelFileSystem` (6/6).

- [ ] **Step 4: Commit**

```bash
git add Sources/macSCPCore/SSH/CitadelFileSystem.swift Tests/macSCPCoreTests/CitadelFileSystemIntegrationTests.swift
git commit -m "feat: stream file contents over SFTP for transfers

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 3: TransferEngine + TransferViewModel

**Files:**
- Create: `Sources/macSCPCore/RemoteFS/TransferEngine.swift`
- Create: `Sources/macSCPCore/Presentation/TransferViewModel.swift`
- Create: `Tests/macSCPCoreTests/TransferEngineTests.swift`

**Interfaces:**
- Consumes: Task 1 (Streams, `TransferChunk`), `RemotePath.join`
- Produces (für Task 5):

```swift
public struct TransferProgress: Equatable, Sendable {
    public let bytesTransferred: UInt64
    public let totalBytes: UInt64?
    public var fraction: Double? // nil, wenn totalBytes unbekannt/0
}

public enum TransferDirection: Equatable, Sendable { case upload, download }

public enum TransferEngine {
    /// Kopiert EINE Datei von source nach destinationDirectory/fileName.
    /// Richtungs-agnostisch (lokal→remote, remote→lokal, remote→remote).
    public static func copyFile(
        from source: any RemoteFileSystem, sourcePath: String,
        to destination: any RemoteFileSystem, destinationDirectory: String, fileName: String,
        onProgress: @escaping @Sendable (TransferProgress) -> Void
    ) async throws
}

@Observable @MainActor public final class TransferViewModel {
    public enum State: Equatable {
        case idle
        case running(fileName: String, direction: TransferDirection, progress: TransferProgress)
        case failed(message: String)
        case finished(fileName: String, direction: TransferDirection)
    }
    public private(set) var state: State
    public var isRunning: Bool
    public init()
    /// Führt den Transfer aus; ruft onCompleted bei Erfolg (fürs Ziel-Pane-Refresh).
    public func run(
        fileName: String, direction: TransferDirection,
        source: any RemoteFileSystem, sourcePath: String,
        destination: any RemoteFileSystem, destinationDirectory: String,
        onCompleted: @escaping () async -> Void
    ) async
}
```

**Parallel-Hinweis für den Koordinator:** disjunkt zu Task 2 — parallel ausführbar (Worktree).

- [ ] **Step 1: Fehlschlagende Tests**

`Tests/macSCPCoreTests/TransferEngineTests.swift`:

```swift
import Foundation
import Testing
@testable import macSCPCore

@Suite("TransferEngine")
struct TransferEngineTests {
    private func makeSource(content: Data) -> MockRemoteFileSystem {
        MockRemoteFileSystem(
            tree: ["/": [RemoteFileItem(
                name: "quelle.bin", path: "/quelle.bin", kind: .file,
                size: UInt64(content.count))]],
            files: ["/quelle.bin": content]
        )
    }

    @Test func copiesContentToDestinationDirectory() async throws {
        let content = Data((0..<(TransferChunk.size + 512)).map { UInt8($0 % 241) })
        let source = makeSource(content: content)
        let destination = MockRemoteFileSystem(tree: ["/ziel": []])

        try await TransferEngine.copyFile(
            from: source, sourcePath: "/quelle.bin",
            to: destination, destinationDirectory: "/ziel", fileName: "quelle.bin",
            onProgress: { _ in }
        )
        #expect(await destination.writtenData(at: "/ziel/quelle.bin") == content)
    }

    @Test func reportsMonotonicProgressUpToTotal() async throws {
        let content = Data(repeating: 7, count: TransferChunk.size * 3)
        let source = makeSource(content: content)
        let destination = MockRemoteFileSystem(tree: ["/ziel": []])

        let recorder = ProgressRecorder()
        try await TransferEngine.copyFile(
            from: source, sourcePath: "/quelle.bin",
            to: destination, destinationDirectory: "/ziel", fileName: "quelle.bin",
            onProgress: { progress in Task { await recorder.record(progress) } }
        )
        let snapshots = await recorder.snapshots
        #expect(!snapshots.isEmpty)
        #expect(snapshots.map(\.bytesTransferred) == snapshots.map(\.bytesTransferred).sorted())
        #expect(snapshots.last?.bytesTransferred == UInt64(content.count))
        #expect(snapshots.last?.totalBytes == UInt64(content.count))
    }

    @Test func missingSourceThrowsNotFound() async {
        let source = MockRemoteFileSystem(tree: ["/": []])
        let destination = MockRemoteFileSystem(tree: ["/ziel": []])
        await #expect(throws: RemoteFSError.notFound(path: "/fehlt.bin")) {
            try await TransferEngine.copyFile(
                from: source, sourcePath: "/fehlt.bin",
                to: destination, destinationDirectory: "/ziel", fileName: "fehlt.bin",
                onProgress: { _ in }
            )
        }
    }

    @Test func fractionIsNilWithoutTotalAndOneAtCompletion() {
        #expect(TransferProgress(bytesTransferred: 10, totalBytes: nil).fraction == nil)
        #expect(TransferProgress(bytesTransferred: 0, totalBytes: 0).fraction == nil)
        #expect(TransferProgress(bytesTransferred: 50, totalBytes: 100).fraction == 0.5)
    }

    @Test func viewModelRunsTransferAndCallsCompletion() async {
        let content = Data("inhalt".utf8)
        let source = makeSource(content: content)
        let destination = MockRemoteFileSystem(tree: ["/ziel": []])
        let completed = ProgressRecorder()

        let vm = await TransferViewModel()
        await vm.run(
            fileName: "quelle.bin", direction: .download,
            source: source, sourcePath: "/quelle.bin",
            destination: destination, destinationDirectory: "/ziel",
            onCompleted: { await completed.record(
                TransferProgress(bytesTransferred: 1, totalBytes: 1)) }
        )
        #expect(await vm.state == .finished(fileName: "quelle.bin", direction: .download))
        #expect(await completed.snapshots.count == 1)
        #expect(await destination.writtenData(at: "/ziel/quelle.bin") == content)
    }
}

private actor ProgressRecorder {
    private(set) var snapshots: [TransferProgress] = []
    func record(_ p: TransferProgress) { snapshots.append(p) }
}
```

Run: `swift test --filter TransferEngineTests` — Compile-Fehler (`TransferEngine` unbekannt).

- [ ] **Step 2: TransferEngine implementieren**

`Sources/macSCPCore/RemoteFS/TransferEngine.swift`:

```swift
import Foundation

public struct TransferProgress: Equatable, Sendable {
    public let bytesTransferred: UInt64
    public let totalBytes: UInt64?

    public init(bytesTransferred: UInt64, totalBytes: UInt64?) {
        self.bytesTransferred = bytesTransferred
        self.totalBytes = totalBytes
    }

    /// Anteil 0…1; nil, wenn die Gesamtgröße unbekannt oder 0 ist.
    public var fraction: Double? {
        guard let totalBytes, totalBytes > 0 else { return nil }
        return Double(bytesTransferred) / Double(totalBytes)
    }
}

public enum TransferDirection: Equatable, Sendable {
    case upload
    case download
}

/// Kopiert einzelne Dateien zwischen zwei Dateisystemen (M2c: eine zur Zeit,
/// Ziel wird überschrieben; Konfliktregeln und Queue kommen in M5).
public enum TransferEngine {
    public static func copyFile(
        from source: any RemoteFileSystem, sourcePath: String,
        to destination: any RemoteFileSystem, destinationDirectory: String, fileName: String,
        onProgress: @escaping @Sendable (TransferProgress) -> Void
    ) async throws {
        let total = try await source.stat(path: sourcePath).size
        let input = try await source.readStream(path: sourcePath)
        let destinationPath = RemotePath.join(destinationDirectory, fileName)

        // Zähl-Zwischenstück, pull-basiert: das Ziel zieht Chunk für Chunk,
        // nichts wird über einen Chunk hinaus gepuffert.
        var iterator = input.makeAsyncIterator()
        var transferred: UInt64 = 0
        let counted = AsyncThrowingStream<Data, Error>(unfolding: {
            guard let chunk = try await iterator.next() else { return nil }
            transferred += UInt64(chunk.count)
            onProgress(TransferProgress(bytesTransferred: transferred, totalBytes: total))
            return chunk
        })

        try await destination.write(path: destinationPath, contents: counted)
    }
}
```

- [ ] **Step 3: TransferViewModel implementieren**

`Sources/macSCPCore/Presentation/TransferViewModel.swift`:

```swift
import Foundation
import Observation

/// UI-Zustand des (einen) laufenden Transfers.
@Observable
@MainActor
public final class TransferViewModel {
    public enum State: Equatable {
        case idle
        case running(fileName: String, direction: TransferDirection, progress: TransferProgress)
        case failed(message: String)
        case finished(fileName: String, direction: TransferDirection)
    }

    public private(set) var state: State = .idle

    public var isRunning: Bool {
        if case .running = state { return true }
        return false
    }

    public init() {}

    public func run(
        fileName: String, direction: TransferDirection,
        source: any RemoteFileSystem, sourcePath: String,
        destination: any RemoteFileSystem, destinationDirectory: String,
        onCompleted: @escaping () async -> Void
    ) async {
        guard !isRunning else { return }
        state = .running(
            fileName: fileName, direction: direction,
            progress: TransferProgress(bytesTransferred: 0, totalBytes: nil))
        do {
            try await TransferEngine.copyFile(
                from: source, sourcePath: sourcePath,
                to: destination, destinationDirectory: destinationDirectory, fileName: fileName,
                onProgress: { progress in
                    Task { @MainActor [weak self] in
                        self?.state = .running(
                            fileName: fileName, direction: direction, progress: progress)
                    }
                }
            )
            state = .finished(fileName: fileName, direction: direction)
            await onCompleted()
        } catch {
            state = .failed(message: Self.message(for: error))
        }
    }

    static func message(for error: Error) -> String {
        switch error {
        case RemoteFSError.notFound(let path):
            return "Datei nicht gefunden: \(path)"
        case RemoteFSError.permissionDenied(let path):
            return "Keine Berechtigung für: \(path)"
        case RemoteFSError.connectionFailed(let reason):
            return "Verbindung verloren: \(reason)"
        case RemoteFSError.protocolError(let reason):
            return "Übertragung fehlgeschlagen: \(reason)"
        default:
            return "Übertragung fehlgeschlagen: \(String(describing: error))"
        }
    }
}
```

- [ ] **Step 4: Grün** — `swift test --filter TransferEngineTests` (5 PASS), dann komplett: **63 Tests grün** (58 + 5).

- [ ] **Step 5: Commit**

```bash
git add Sources/macSCPCore/RemoteFS/TransferEngine.swift Sources/macSCPCore/Presentation/TransferViewModel.swift Tests/macSCPCoreTests/TransferEngineTests.swift
git commit -m "feat: add direction-agnostic single file transfer engine

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 4: Einfach-Auswahl in Tabelle und ViewModel

**Files:**
- Modify: `Sources/macSCPCore/Presentation/RemoteBrowserViewModel.swift` (`selectedItem` + Reset bei Navigation)
- Modify: `Sources/MacSCPApp/RemoteFileTableView.swift` (Auswahl-Callback)
- Modify: `Sources/MacSCPApp/BrowserPane.swift` (Auswahl durchreichen)
- Test: `Tests/macSCPCoreTests/RemoteBrowserViewModelTests.swift` (+1 Test)

**Interfaces:**
- Produces (für Task 5): `RemoteBrowserViewModel.selectedItem: RemoteFileItem?` (public var; wird bei `load()` auf nil zurückgesetzt), `RemoteFileTableView(items:onOpen:onSelect:)`

**Parallel-Hinweis für den Koordinator:** unabhängig von Task 1–3 — parallel zu Task 1 ausführbar (Worktree; disjunkte Dateien: RemoteBrowserViewModel wird von Task 0 berührt, daher NACH Task 0 starten).

- [ ] **Step 1: Fehlschlagender Test** — in `RemoteBrowserViewModelTests` ergänzen:

```swift
    @Test func navigationResetsSelection() async {
        let vm = RemoteBrowserViewModel(fs: makeFS())
        await vm.load()
        vm.selectedItem = vm.items[1]
        await vm.open(vm.items[0])
        #expect(vm.selectedItem == nil)
    }
```

Run: `swift test --filter RemoteBrowserViewModelTests` — Compile-Fehler (`selectedItem` unbekannt).

- [ ] **Step 2: ViewModel** — in `RemoteBrowserViewModel` ergänzen:

```swift
    /// Aktuell in der Tabelle ausgewählter Eintrag (Einfach-Auswahl).
    public var selectedItem: RemoteFileItem?
```

und in `load()` als erste Zeile nach `state = .loading`:

```swift
        selectedItem = nil
```

- [ ] **Step 3: Tabelle** — `RemoteFileTableView` erweitern (nur die gezeigten Stellen ändern):

Signatur/Properties:

```swift
    let items: [RemoteFileItem]
    let onOpen: (RemoteFileItem) -> Void
    let onSelect: (RemoteFileItem?) -> Void
```

`makeCoordinator`:

```swift
    func makeCoordinator() -> Coordinator {
        Coordinator(onOpen: onOpen, onSelect: onSelect)
    }
```

`updateNSView` zusätzlich:

```swift
        context.coordinator.onSelect = onSelect
```

Coordinator: Property `var onSelect: (RemoteFileItem?) -> Void`, Init um `onSelect:` erweitern, und Delegate-Methode ergänzen:

```swift
        func tableViewSelectionDidChange(_ notification: Notification) {
            guard let table else { return }
            let row = table.selectedRow
            onSelect(row >= 0 && row < items.count ? items[row] : nil)
        }
```

- [ ] **Step 4: BrowserPane** — Aufrufstelle anpassen:

```swift
                RemoteFileTableView(
                    items: viewModel.items,
                    onOpen: { item in Task { await viewModel.open(item) } },
                    onSelect: { item in viewModel.selectedItem = item }
                )
```

- [ ] **Step 5: Grün** — `swift build && swift test`: **Testzahl je nach Merge-Reihenfolge** (allein auf Task-0-Basis: 54; nach Merge mit Task 1/3: entsprechend mehr — der Koordinator verifiziert die Gesamtzahl nach dem Zusammenführen).

- [ ] **Step 6: Commit**

```bash
git add Sources/macSCPCore/Presentation/RemoteBrowserViewModel.swift Sources/MacSCPApp/RemoteFileTableView.swift Sources/MacSCPApp/BrowserPane.swift Tests/macSCPCoreTests/RemoteBrowserViewModelTests.swift
git commit -m "feat: add single row selection to file panes

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 5: Transfer-UI (Buttons + TransferBar)

**Files:**
- Create: `Sources/MacSCPApp/TransferBar.swift`
- Modify: `Sources/MacSCPApp/ContentView.swift` (komplett ersetzen)

**Interfaces:** Consumes Task 3 (`TransferViewModel`, `TransferDirection`, `TransferProgress`) und Task 4 (`selectedItem`). `BrowserSession` wird um die Dateisysteme erweitert (die Engine braucht Quelle/Ziel direkt).

- [ ] **Step 0: Auswahl über reloadData hinweg erhalten** (Review-Fund aus Task 4, empirisch belegt: `reloadData()` löscht die visuelle Auswahl, OHNE den Delegate zu feuern — sobald ContentView `selectedItem` liest, würde jeder Klick sofort optisch „entwählt".)

`Sources/MacSCPApp/RemoteFileTableView.swift`:

1. Neues Property nach `items`:

```swift
    let selectedPath: String?
```

2. `updateNSView` komplett ersetzen:

```swift
    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.items = items
        context.coordinator.onOpen = onOpen
        context.coordinator.onSelect = onSelect
        guard let table = nsView.documentView as? NSTableView else { return }
        // reloadData() löscht die Auswahl ohne Delegate-Aufruf —
        // deshalb programmatisch wiederherstellen, Callback dabei unterdrücken.
        context.coordinator.suppressSelectionCallback = true
        table.reloadData()
        if let selectedPath,
           let row = items.firstIndex(where: { $0.path == selectedPath }) {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        context.coordinator.suppressSelectionCallback = false
    }
```

3. Im `Coordinator`: Property `var suppressSelectionCallback = false` ergänzen und `tableViewSelectionDidChange` als erste Zeile absichern:

```swift
            guard !suppressSelectionCallback else { return }
```

4. In `Sources/MacSCPApp/BrowserPane.swift` die Aufrufstelle erweitern:

```swift
                RemoteFileTableView(
                    items: viewModel.items,
                    selectedPath: viewModel.selectedItem?.path,
                    onOpen: { item in Task { await viewModel.open(item) } },
                    onSelect: { item in viewModel.selectedItem = item }
                )
```

- [ ] **Step 0b: Fortschritts-Reihenfolge in TransferViewModel deterministisch machen** (Review-Fund aus Task 3: die pro Chunk gespawnten `Task { @MainActor … }` sind untereinander und gegenüber dem synchronen `.finished` unsortiert — ein später eintreffendes Progress-Update könnte `.finished` überschreiben.)

In `Sources/macSCPCore/Presentation/TransferViewModel.swift` den Body von `run(...)` ersetzen:

```swift
        guard !isRunning else { return }
        state = .running(
            fileName: fileName, direction: direction,
            progress: TransferProgress(bytesTransferred: 0, totalBytes: nil))

        // Geordnete Zustellung: AsyncStream puffert in Reihenfolge, EIN Konsument
        // aktualisiert den State — kein Task-pro-Chunk, kein Race mit .finished.
        let (progressStream, progressContinuation) = AsyncStream<TransferProgress>.makeStream()
        let consumer = Task { @MainActor [weak self] in
            for await progress in progressStream {
                self?.state = .running(fileName: fileName, direction: direction, progress: progress)
            }
        }

        do {
            try await TransferEngine.copyFile(
                from: source, sourcePath: sourcePath,
                to: destination, destinationDirectory: destinationDirectory, fileName: fileName,
                onProgress: { progressContinuation.yield($0) }
            )
            progressContinuation.finish()
            await consumer.value
            state = .finished(fileName: fileName, direction: direction)
            await onCompleted()
        } catch {
            progressContinuation.finish()
            await consumer.value
            state = .failed(message: Self.message(for: error))
        }
```

Und in `Tests/macSCPCoreTests/TransferEngineTests.swift` den Test `viewModelRunsTransferAndCallsCompletion` verschärfen: `let content = Data("inhalt".utf8)` ersetzen durch

```swift
        let content = Data(repeating: 42, count: TransferChunk.size * 3)
```

(damit mehrere Progress-Events feuern — vor dem Fix wäre `.finished` dann gelegentlich überschrieben worden) und die letzte Assertion `writtenData`-Vergleich entsprechend gegen `content` lassen (unverändert korrekt). Test-Reihenfolge: erst Test verschärfen und mehrfach laufen lassen (`swift test --filter TransferEngineTests` 5×) — wenn er dabei nie rot wird, trotzdem fixen (das Race ist real, nur schwer zu treffen) und danach erneut 5× grün bestätigen.

- [ ] **Step 1: TransferBar**

`Sources/MacSCPApp/TransferBar.swift`:

```swift
import SwiftUI
import macSCPCore

/// Fortschrittsleiste unter den Panes: ↑ Bernstein (Upload), ↓ Ozeanblau (Download).
struct TransferBar: View {
    let viewModel: TransferViewModel

    private func tint(for direction: TransferDirection) -> Color {
        direction == .upload ? DesignTokens.localAmber : DesignTokens.remoteBlue
    }

    private func arrow(for direction: TransferDirection) -> String {
        direction == .upload ? "arrow.up" : "arrow.down"
    }

    var body: some View {
        switch viewModel.state {
        case .idle:
            EmptyView()
        case .running(let fileName, let direction, let progress):
            HStack(spacing: 10) {
                Image(systemName: arrow(for: direction))
                    .foregroundStyle(tint(for: direction))
                    .fontWeight(.bold)
                Text(fileName)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let fraction = progress.fraction {
                    ProgressView(value: fraction)
                        .tint(tint(for: direction))
                } else {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        case .failed(let message):
            Text(message)
                .foregroundStyle(.red)
                .font(.callout)
                .padding(6)
        case .finished(let fileName, let direction):
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(tint(for: direction))
                Text("\(fileName) übertragen")
                    .font(.callout)
            }
            .padding(6)
        }
    }
}
```

- [ ] **Step 2: ContentView ersetzen**

`Sources/MacSCPApp/ContentView.swift` — Datei komplett ersetzen:

```swift
import SwiftUI
import macSCPCore

/// Beide Seiten einer aktiven Verbindung inklusive der Dateisysteme —
/// die TransferEngine braucht Quelle und Ziel direkt.
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
    @State private var session: BrowserSession?
    @State private var transferViewModel = TransferViewModel()

    var body: some View {
        if let session {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    uploadButton(session)
                    downloadButton(session)
                    Spacer()
                    Button("Trennen") {
                        Task {
                            await session.remote.disconnect()
                            connectionViewModel.clearPassword()
                            self.session = nil
                        }
                    }
                    .disabled(transferViewModel.isRunning)
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

                TransferBar(viewModel: transferViewModel)
            }
        } else {
            ConnectionFormView(viewModel: connectionViewModel) { fs in
                session = BrowserSession(
                    localFS: LocalFileSystem(),
                    remoteFS: fs,
                    local: RemoteBrowserViewModel(fs: LocalFileSystem(), startPath: NSHomeDirectory()),
                    remote: RemoteBrowserViewModel(fs: fs)
                )
                transferViewModel = TransferViewModel()
            }
        }
    }

    /// Lokal ausgewählte DATEI → aktuelles Remote-Verzeichnis.
    @ViewBuilder
    private func uploadButton(_ session: BrowserSession) -> some View {
        let selected = session.local.selectedItem
        Button {
            guard let selected else { return }
            Task {
                await transferViewModel.run(
                    fileName: selected.name, direction: .upload,
                    source: session.localFS, sourcePath: selected.path,
                    destination: session.remoteFS,
                    destinationDirectory: session.remote.currentPath,
                    onCompleted: { await session.remote.refresh() }
                )
            }
        } label: {
            Label("Hochladen", systemImage: "arrow.up")
        }
        .tint(DesignTokens.localAmber)
        .disabled(selected == nil || selected?.kind != .file || transferViewModel.isRunning)
        .help("Ausgewählte lokale Datei ins Remote-Verzeichnis hochladen")
    }

    /// Remote ausgewählte DATEI → aktuelles lokales Verzeichnis.
    @ViewBuilder
    private func downloadButton(_ session: BrowserSession) -> some View {
        let selected = session.remote.selectedItem
        Button {
            guard let selected else { return }
            Task {
                await transferViewModel.run(
                    fileName: selected.name, direction: .download,
                    source: session.remoteFS, sourcePath: selected.path,
                    destination: session.localFS,
                    destinationDirectory: session.local.currentPath,
                    onCompleted: { await session.local.refresh() }
                )
            }
        } label: {
            Label("Herunterladen", systemImage: "arrow.down")
        }
        .tint(DesignTokens.remoteBlue)
        .disabled(selected == nil || selected?.kind != .file || transferViewModel.isRunning)
        .help("Ausgewählte Remote-Datei ins lokale Verzeichnis herunterladen")
    }
}
```

- [ ] **Step 3: Grün** — `swift build && swift test` (64 Tests grün: 63 + 1 aus Task 4; Zahl nach Merge-Lage verifizieren).

- [ ] **Step 4: Commit**

```bash
git add Sources/MacSCPApp/
git commit -m "feat: wire upload and download buttons with progress bar

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 6: Abschluss-Verifikation

- [ ] **Step 1:** `swift test` — 64 Tests grün (Gesamtzahl gegen Datei-Landkarte prüfen: 52 + 1 T0 + 5 T1 + 5 T3 + 1 T4 = 64)
- [ ] **Step 2:** Docker-Rig hoch, `MACSCP_ITEST=1 swift test --filter CitadelFileSystem` — 6/6, Rig runter
- [ ] **Step 3: Visueller Smoke-Test** (Koordinator): Datei lokal auswählen → „Hochladen" (Bernstein) → Fortschritt in Bernstein → Remote-Pane zeigt die Datei nach Refresh; Remote-Datei auswählen → „Herunterladen" (Ozeanblau) → lokale Datei erscheint; Verzeichnis ausgewählt → Buttons deaktiviert; während des Transfers → beide Buttons + Trennen deaktiviert
- [ ] **Step 4:** Checkboxen dieses Plans abhaken, Commit `docs: mark M2c plan tasks as completed` (mit Footer)

## Ausblick

**M2d — Drag & Drop** (eigener Plan): Finder → Remote-Pane (`onDrop` + Upload über die jetzt vorhandene Engine), Remote → Finder (`NSFilePromiseProvider` + Download), Pane ↔ Pane.
