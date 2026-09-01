# macSCP M2c — Transfers Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Transfer individual files between the panes — download (remote→local) and upload (local→remote) via button, with progress display in the duo colors.

**Architecture:** The `RemoteFileSystem` protocol gets chunk streams (`readStream`/`write`), implemented by Mock, `LocalFileSystem`, and `CitadelFileSystem`. A direction-agnostic `TransferEngine` pumps source→destination and reports progress; a `TransferViewModel` (`@Observable`) holds the UI state. The table gets single selection; `ContentView` wires up two transfer buttons (→ upload, ← download) and a progress bar.

**Dependency graph (parallel phases for the coordinator):**

```
Task 0 ─→ Task 1 ─→ Task 2 (Citadel-Streams)   ─→ Task 5 ─→ Task 6
      └─→ Task 4 ┐└→ Task 3 (TransferEngine)   ─┘
   (Task 1 ∥ Task 4)   (Task 2 ∥ Task 3 — disjunkte Dateien)
```

**Tech stack:** same as M2b. The Citadel file API (`openFile`/`read`/`write`) is verified in Task 2 against `.build/checkouts/Citadel/`.

## Global Constraints

- swift-tools-version 6.0, all targets Language Mode v5; macOS 14; UI text German
- Conventional Commits, footer `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`; never push (the coordinator does that)
- YAGNI for M2c: ONE transfer at a time, NO cancel/resume/queue (→ M5), NO directory transfers, NO drag & drop (→ M2d), NO conflict dialogs (destination gets overwritten — deliberate, will be replaced by conflict rules in M5)
- Chunk size uniformly 64 KiB (`TransferChunk.size`)
- Duo colors only semantic: upload amber, download ocean blue
- After every task: `swift test` green (without Docker); Citadel streams additionally via `MACSCP_ITEST=1` against the Docker rig

## File map (delta M2c)

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

### Task 0: Kickoff fixes from the M2b closing review

**Files:**
- Modify: `Sources/macSCPCore/RemoteFS/LocalFileSystem.swift` (Pfad-Normalisierung in `item(for:)`)
- Modify: `Sources/macSCPCore/Presentation/RemoteBrowserViewModel.swift` (comment only, line ~61)
- Test: `Tests/macSCPCoreTests/LocalFileSystemTests.swift` (+1 Test)

**Interfaces:** no API change. Invariant afterward: `RemoteFileItem.path` NEVER carries a trailing slash (except `/`) — a precondition for path comparisons in Task 3/5.

Deliberately NOT in this task (third point of the M2c opening list): the `try?` swallowing in `item(for:)`/`stat` for unreadable paths stays for now — it only affects metadata display, a reliable CI test for it is fragile without root privileges, and the transfer paths (readStream/write) map permission errors as typed errors anyway. Becomes relevant again once M5 conflict rules use stat metadata for decisions.

- [x] **Step 1: Failing test** — add to `LocalFileSystemTests`:

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

Run: `swift test --filter LocalFileSystemTests` — the new test must FAIL (directory URLs return a trailing slash).

- [x] **Step 2: Fix** — in `LocalFileSystem.item(for:)` replace the `path:` line with a normalized variant (before the `RemoteFileItem` init):

```swift
        var normalizedPath = url.path(percentEncoded: false)
        if normalizedPath.count > 1, normalizedPath.hasSuffix("/") {
            normalizedPath.removeLast()
        }
```

and use `path: normalizedPath` in the init.

- [x] **Step 3: Comment fix** — in `RemoteBrowserViewModel.swift` change the comment above `sortedForDisplay` to:

```swift
    /// Verzeichnisse zuerst, dann Name case-insensitiv —
    /// kein Backend sortiert; dies ist die einzige Sortier-Autorität.
```

- [x] **Step 4: Green** — `swift test`: 53 tests green (52 + 1).

- [x] **Step 5: Commit**

```bash
git add Sources/macSCPCore/RemoteFS/LocalFileSystem.swift Sources/macSCPCore/Presentation/RemoteBrowserViewModel.swift Tests/macSCPCoreTests/LocalFileSystemTests.swift
git commit -m "fix: normalize directory paths and stale sort comment

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 1: Streams in the protocol (Mock + LocalFileSystem)

**Files:**
- Modify: `Sources/macSCPCore/RemoteFS/RemoteFileSystem.swift`
- Modify: `Sources/macSCPCore/RemoteFS/LocalFileSystem.swift`
- Modify: `Tests/macSCPCoreTests/MockRemoteFileSystem.swift`
- Create: `Tests/macSCPCoreTests/StreamRoundtripTests.swift`

**Interfaces:**
- Produces (for Task 2/3): protocol extension

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

- MockRemoteFileSystem additionally: `init(tree:files:)` with `files: [String: Data] = [:]` (path→content) and `func writtenData(at path: String) -> Data?` for asserting.

- [x] **Step 1: Failing tests**

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

Run: `swift test --filter StreamRoundtripTests` — compile error (protocol doesn't know `readStream`, Mock doesn't know `files:`).

- [x] **Step 2: Protocol + TransferChunk**

In `Sources/macSCPCore/RemoteFS/RemoteFileSystem.swift` — replace the file entirely:

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

(add `import Foundation` — for `Data`.)

- [x] **Step 3: Extend the mock**

`Tests/macSCPCoreTests/MockRemoteFileSystem.swift` — replace the file entirely:

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

- [x] **Step 4: LocalFileSystem streams**

In `Sources/macSCPCore/RemoteFS/LocalFileSystem.swift`, add before `disconnect()`:

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

Error-mapping note: `FileHandle(forReadingFrom:)` throws an NSCocoaError for a missing file, which `Self.map` already translates to `notFound`.

- [x] **Step 5: Green** — `swift test --filter StreamRoundtripTests` (5 tests PASS), then `swift test` in full: **58 tests green** (53 + 5). WARNING: `CitadelFileSystem` now fails to compile (protocol gap) — the file gets two TRANSITIONAL stubs in this task, so the package builds:

```swift
    public func readStream(path: String) async throws -> AsyncThrowingStream<Data, Error> {
        throw RemoteFSError.protocolError(reason: "readStream: kommt in M2c Task 2")
    }

    public func write(path: String, contents: AsyncThrowingStream<Data, Error>) async throws {
        throw RemoteFSError.protocolError(reason: "write: kommt in M2c Task 2")
    }
```

(Task 2 replaces both with real implementations.)

- [x] **Step 6: Commit**

```bash
git add Sources/macSCPCore/RemoteFS/ Sources/macSCPCore/SSH/CitadelFileSystem.swift Tests/macSCPCoreTests/
git commit -m "feat: add chunked read and write streams to the file system protocol

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: CitadelFileSystem streams + integration tests

**Files:**
- Modify: `Sources/macSCPCore/SSH/CitadelFileSystem.swift` (replace the stubs from Task 1)
- Modify: `Tests/macSCPCoreTests/CitadelFileSystemIntegrationTests.swift` (+2 tests)

**Interfaces:** Consumes Task 1 (`TransferChunk`, protocol signatures). No new producers.

**Parallel note for the coordinator:** disjoint from Task 3 — can run in parallel (worktree).

- [x] **Step 1: Failing (gated) tests** — add to `CitadelFileSystemIntegrationTests`:

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

Run (Docker rig must be up): `MACSCP_ITEST=1 swift test --filter CitadelFileSystem`
Expected: the two new tests FAIL with `protocolError("… kommt in M2c Task 2")`, the four old ones stay green.

- [x] **Step 2: Implement** — replace both stubs in `CitadelFileSystem.swift`:

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

(add `import NIOCore` at the top if `ByteBuffer` isn't visible.)

**API drift handling, proven in M1:** if the compiler rejects `openFile(filePath:flags:)`, the `SFTPOpenFileFlags` case names (`.read/.create/.write/.truncate`), `file.read(from:length:) -> ByteBuffer`, `file.write(_:at:)`, or `file.close()`: look up the exact names in `.build/checkouts/Citadel/Sources/Citadel/SFTP/` and adjust ONLY the call sites — protocol, tests, and error mapping stay. The two integration tests define the contract.

- [x] **Step 3: Verify** — `swift test` (58 green, ungated) AND `MACSCP_ITEST=1 swift test --filter CitadelFileSystem` (6/6).

- [x] **Step 4: Commit**

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
- Consumes: Task 1 (streams, `TransferChunk`), `RemotePath.join`
- Produces (for Task 5):

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

**Parallel note for the coordinator:** disjoint from Task 2 — can run in parallel (worktree).

- [x] **Step 1: Failing tests**

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

Run: `swift test --filter TransferEngineTests` — compile error (`TransferEngine` unknown).

- [x] **Step 2: Implement TransferEngine**

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

- [x] **Step 3: Implement TransferViewModel**

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

- [x] **Step 4: Green** — `swift test --filter TransferEngineTests` (5 PASS), then in full: **63 tests green** (58 + 5).

- [x] **Step 5: Commit**

```bash
git add Sources/macSCPCore/RemoteFS/TransferEngine.swift Sources/macSCPCore/Presentation/TransferViewModel.swift Tests/macSCPCoreTests/TransferEngineTests.swift
git commit -m "feat: add direction-agnostic single file transfer engine

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 4: Single selection in table and view model

**Files:**
- Modify: `Sources/macSCPCore/Presentation/RemoteBrowserViewModel.swift` (`selectedItem` + reset on navigation)
- Modify: `Sources/MacSCPApp/RemoteFileTableView.swift` (selection callback)
- Modify: `Sources/MacSCPApp/BrowserPane.swift` (pass selection through)
- Test: `Tests/macSCPCoreTests/RemoteBrowserViewModelTests.swift` (+1 test)

**Interfaces:**
- Produces (for Task 5): `RemoteBrowserViewModel.selectedItem: RemoteFileItem?` (public var; reset to nil in `load()`), `RemoteFileTableView(items:onOpen:onSelect:)`

**Parallel note for the coordinator:** independent of Task 1–3 — can run in parallel with Task 1 (worktree; disjoint files: RemoteBrowserViewModel is touched by Task 0, so start AFTER Task 0).

- [x] **Step 1: Failing test** — add to `RemoteBrowserViewModelTests`:

```swift
    @Test func navigationResetsSelection() async {
        let vm = RemoteBrowserViewModel(fs: makeFS())
        await vm.load()
        vm.selectedItem = vm.items[1]
        await vm.open(vm.items[0])
        #expect(vm.selectedItem == nil)
    }
```

Run: `swift test --filter RemoteBrowserViewModelTests` — compile error (`selectedItem` unknown).

- [x] **Step 2: View model** — add to `RemoteBrowserViewModel`:

```swift
    /// Aktuell in der Tabelle ausgewählter Eintrag (Einfach-Auswahl).
    public var selectedItem: RemoteFileItem?
```

and in `load()` as the first line after `state = .loading`:

```swift
        selectedItem = nil
```

- [x] **Step 3: Table** — extend `RemoteFileTableView` (change only the spots shown):

Signature/properties:

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

`updateNSView` additionally:

```swift
        context.coordinator.onSelect = onSelect
```

Coordinator: add the property `var onSelect: (RemoteFileItem?) -> Void`, extend the init with `onSelect:`, and add the delegate method:

```swift
        func tableViewSelectionDidChange(_ notification: Notification) {
            guard let table else { return }
            let row = table.selectedRow
            onSelect(row >= 0 && row < items.count ? items[row] : nil)
        }
```

- [x] **Step 4: BrowserPane** — adjust the call site:

```swift
                RemoteFileTableView(
                    items: viewModel.items,
                    onOpen: { item in Task { await viewModel.open(item) } },
                    onSelect: { item in viewModel.selectedItem = item }
                )
```

- [x] **Step 5: Green** — `swift build && swift test`: **test count depends on merge order** (on Task-0 basis alone: 54; after merging with Task 1/3: correspondingly more — the coordinator verifies the total count after merging).

- [x] **Step 6: Commit**

```bash
git add Sources/macSCPCore/Presentation/RemoteBrowserViewModel.swift Sources/MacSCPApp/RemoteFileTableView.swift Sources/MacSCPApp/BrowserPane.swift Tests/macSCPCoreTests/RemoteBrowserViewModelTests.swift
git commit -m "feat: add single row selection to file panes

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 5: Transfer UI (buttons + TransferBar)

**Files:**
- Create: `Sources/MacSCPApp/TransferBar.swift`
- Modify: `Sources/MacSCPApp/ContentView.swift` (replace entirely)

**Interfaces:** Consumes Task 3 (`TransferViewModel`, `TransferDirection`, `TransferProgress`) and Task 4 (`selectedItem`). `BrowserSession` gets extended with the file systems (the engine needs source/destination directly).

- [x] **Step 0: Preserve selection across reloadData** (review finding from Task 4, proven empirically: `reloadData()` clears the visual selection WITHOUT firing the delegate — as soon as ContentView reads `selectedItem`, every click would immediately appear visually "deselected".)

`Sources/MacSCPApp/RemoteFileTableView.swift`:

1. New property after `items`:

```swift
    let selectedPath: String?
```

2. Replace `updateNSView` entirely:

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

3. In `Coordinator`: add the property `var suppressSelectionCallback = false` and guard `tableViewSelectionDidChange` with this as the first line:

```swift
            guard !suppressSelectionCallback else { return }
```

4. In `Sources/MacSCPApp/BrowserPane.swift`, extend the call site:

```swift
                RemoteFileTableView(
                    items: viewModel.items,
                    selectedPath: viewModel.selectedItem?.path,
                    onOpen: { item in Task { await viewModel.open(item) } },
                    onSelect: { item in viewModel.selectedItem = item }
                )
```

- [x] **Step 0b: Make progress ordering in TransferViewModel deterministic** (review finding from Task 3: the per-chunk spawned `Task { @MainActor … }` are unordered among themselves and relative to the synchronous `.finished` — a progress update arriving late could overwrite `.finished`.)

In `Sources/macSCPCore/Presentation/TransferViewModel.swift`, replace the body of `run(...)`:

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

And in `Tests/macSCPCoreTests/TransferEngineTests.swift`, tighten the test `viewModelRunsTransferAndCallsCompletion`: replace `let content = Data("inhalt".utf8)` with

```swift
        let content = Data(repeating: 42, count: TransferChunk.size * 3)
```

(so that multiple progress events fire — before the fix, `.finished` would occasionally have been overwritten) and leave the last assertion's `writtenData` comparison against `content` as is (correct unchanged). Test order: first tighten the test and run it repeatedly (`swift test --filter TransferEngineTests` 5×) — if it never goes red doing so, fix it anyway (the race is real, just hard to hit) and then confirm green 5× again.

- [x] **Step 1: TransferBar**

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

- [x] **Step 2: Replace ContentView**

`Sources/MacSCPApp/ContentView.swift` — replace the file entirely:

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

- [x] **Step 3: Green** — `swift build && swift test` (64 tests green: 63 + 1 from Task 4; verify the number based on merge state).

- [x] **Step 4: Commit**

```bash
git add Sources/MacSCPApp/
git commit -m "feat: wire upload and download buttons with progress bar

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 6: Final verification

- [x] **Step 1:** `swift test` — 64 tests green (check total against the file map: 52 + 1 T0 + 5 T1 + 5 T3 + 1 T4 = 64)
- [x] **Step 2:** bring the Docker rig up, `MACSCP_ITEST=1 swift test --filter CitadelFileSystem` — 6/6, bring the rig down
- [x] **Step 3: Visual smoke test** (coordinator): select a file locally → „Hochladen" (amber) → progress in amber → remote pane shows the file after refresh; select a remote file → „Herunterladen" (ocean blue) → local file appears; directory selected → buttons disabled; during the transfer → both buttons + „Trennen" disabled
- [x] **Step 4:** check off this plan's checkboxes, commit `docs: mark M2c plan tasks as completed` (with footer)

## Outlook

**M2d — Drag & Drop** (own plan): Finder → remote pane (`onDrop` + upload via the now-existing engine), remote → Finder (`NSFilePromiseProvider` + download), pane ↔ pane.
