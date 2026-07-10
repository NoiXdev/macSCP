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
    /// Reconnect-Throttling des Testcontainers abfedern: bei transientem
    /// Transport-Fehler kurz warten und einmal erneut verbinden.
    /// NUR für Connects verwenden, die erfolgreich sein SOLLEN — nicht für
    /// Mismatch/Reject-Tests (dort ist der Fehler beabsichtigt).
    private func connectWithRetry(
        _ make: () async throws -> CitadelFileSystem
    ) async throws -> CitadelFileSystem {
        do {
            return try await make()
        } catch {
            try? await Task.sleep(for: .milliseconds(500))
            return try await make()
        }
    }

    private func connect() async throws -> CitadelFileSystem {
        let config = try SSHConnectionConfig(
            host: "127.0.0.1",
            port: 2222,
            username: "testuser",
            auth: .password("testpass")
        )
        let store = KnownHostsStore(directory: URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-kh-\(UUID().uuidString)"))
        return try await connectWithRetry {
            try await CitadelFileSystem.connect(
                config: config, knownHosts: store, onUnknownHostKey: { _ in true })
        }
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

    @Test func listNonexistentPathThrowsNotFound() async throws {
        let fs = try await connect()
        defer { Task { await fs.disconnect() } }

        await #expect(throws: RemoteFSError.notFound(path: "/data/seed/does-not-exist")) {
            _ = try await fs.list(path: "/data/seed/does-not-exist")
        }
    }

    @Test func wrongPasswordThrowsAuthenticationFailed() async throws {
        let config = try SSHConnectionConfig(
            host: "127.0.0.1",
            port: 2222,
            username: "testuser",
            auth: .password("WRONG")
        )
        let store = KnownHostsStore(directory: URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-kh-\(UUID().uuidString)"))
        await #expect(throws: RemoteFSError.authenticationFailed) {
            _ = try await CitadelFileSystem.connect(
                config: config, knownHosts: store, onUnknownHostKey: { _ in true })
        }
    }

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

    /// M5c/T2: Ein großer Upload wird nach dem ersten Progress-Event abgebrochen.
    /// Erwartung: `copyFile` wirft `CancellationError`, die Remote-Teildatei ist
    /// ECHT kleiner als die Quelle, und die Verbindung bleibt danach nutzbar.
    @Test func cancelledUploadStopsEarlyAndKeepsConnectionUsable() async throws {
        let fs = try await connect()
        defer { Task { await fs.disconnect() } }

        // Quelle zur Laufzeit erzeugen (128 MiB Random) — NIE eingecheckt.
        let localDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-cancel-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: localDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: localDir) }
        let localFile = localDir.appendingPathComponent("big.bin")

        let dd = Process()
        dd.executableURL = URL(fileURLWithPath: "/bin/dd")
        dd.arguments = ["if=/dev/urandom", "of=\(localFile.path(percentEncoded: false))",
                        "bs=1m", "count=128"]
        dd.standardError = FileHandle.nullDevice
        try dd.run()
        dd.waitUntilExit()
        #expect(dd.terminationStatus == 0)
        let sourceSize = try FileManager.default
            .attributesOfItem(atPath: localFile.path(percentEncoded: false))[.size] as? Int ?? 0
        #expect(sourceSize == 128 * 1024 * 1024)

        let remoteName = "macscp-cancel-upload-\(UUID().uuidString).bin"
        let remotePath = "/config/\(remoteName)"
        defer { cleanupConfigPath(remotePath) }

        // Nach dem ERSTEN Progress-Event abbrechen.
        let progressSeen = CallCounterBox()
        let source = LocalFileSystem()
        let task = Task {
            try await TransferEngine.copyFile(
                from: source, sourcePath: localFile.path(percentEncoded: false),
                to: fs, destinationDirectory: "/config", fileName: remoteName,
                onProgress: { _ in progressSeen.increment() })
        }

        // Auf das erste Progress-Event warten (mit Obergrenze gegen Hänger).
        var polls = 0
        while progressSeen.value == 0 && polls < 500 {
            try await Task.sleep(for: .milliseconds(10))
            polls += 1
        }
        #expect(progressSeen.value > 0)
        task.cancel()

        // Abbruch muss als CancellationError sichtbar werden.
        do {
            try await task.value
            Issue.record("CancellationError erwartet, Transfer lief durch")
        } catch is CancellationError {
            // erwartet
        } catch {
            Issue.record("CancellationError erwartet, war: \(error)")
        }

        // Remote-Teildatei ist ECHT kleiner als die Quelle (docker exec stat).
        let stat = Process()
        stat.executableURL = URL(fileURLWithPath: "/usr/local/bin/docker")
        stat.arguments = ["exec", "macscp-test-sshd", "stat", "-c", "%s", remotePath]
        let pipe = Pipe()
        stat.standardOutput = pipe
        stat.standardError = FileHandle.nullDevice
        try stat.run()
        stat.waitUntilExit()
        #expect(stat.terminationStatus == 0)
        let out = String(
            data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let remoteSize = Int(out) ?? -1
        #expect(remoteSize >= 0)
        #expect(remoteSize < sourceSize)   // ECHT kleiner — Abbruch griff mitten drin

        // Verbindung/SFTP danach weiter nutzbar.
        let listing = try await fs.list(path: "/config")
        #expect(listing.contains { $0.name == remoteName })
    }

    /// Erzeugt einen Laufzeit-Key und installiert den Public Key im Container.
    private func makeInstalledKey() throws -> (dir: URL, keyPath: String) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-itest-key-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let keyURL = dir.appendingPathComponent("id_ed25519")

        do {
            let keygen = Process()
            keygen.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
            keygen.arguments = ["-t", "ed25519", "-f", keyURL.path(percentEncoded: false),
                                "-N", "", "-q", "-C", "macscp-itest"]
            try keygen.run()
            keygen.waitUntilExit()
            #expect(keygen.terminationStatus == 0)

            let pubKey = try String(contentsOfFile: keyURL.path(percentEncoded: false) + ".pub",
                                    encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)

            // Hinweis: authorized_keys wächst über Läufe auf einem langlebigen Container —
            // für das Test-Rig akzeptabel.
            let install = Process()
            install.executableURL = URL(fileURLWithPath: "/usr/local/bin/docker")
            install.arguments = [
                "exec", "macscp-test-sshd", "sh", "-c",
                "mkdir -p /config/.ssh && echo '\(pubKey)' >> /config/.ssh/authorized_keys"
                    + " && chmod 700 /config/.ssh && chmod 600 /config/.ssh/authorized_keys"
                    + " && chown -R 1000:1000 /config/.ssh",
            ]
            try install.run()
            install.waitUntilExit()
            #expect(install.terminationStatus == 0)

            return (dir, keyURL.path(percentEncoded: false))
        } catch {
            try? FileManager.default.removeItem(at: dir)
            throw error
        }
    }

    @Test func privateKeyAuthConnectsAndLists() async throws {
        let (dir, keyPath) = try makeInstalledKey()
        defer { try? FileManager.default.removeItem(at: dir) }

        let config = try SSHConnectionConfig(
            host: "127.0.0.1", port: 2222, username: "testuser",
            auth: .privateKey(keyPath: keyPath, passphrase: nil))
        let store = KnownHostsStore(directory: URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-kh-\(UUID().uuidString)"))
        let fs = try await connectWithRetry {
            try await CitadelFileSystem.connect(
                config: config, knownHosts: store, onUnknownHostKey: { _ in true })
        }
        defer { Task { await fs.disconnect() } }

        let items = try await fs.list(path: "/data/seed")
        #expect(items.contains { $0.name == "hello.txt" })
    }

    @Test func tofuStoresKeyOnFirstAcceptAndConnectsSilentlyAfterwards() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-tofu-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = KnownHostsStore(directory: dir)
        let config = try SSHConnectionConfig(
            host: "127.0.0.1", port: 2222, username: "testuser",
            auth: .password("testpass"))

        let asked = CallCounterBox()
        // Nur der ERSTE (Erfolg erwartete) Connect wird gegen Reconnect-Throttling
        // abgesichert. Der Decider-Zähler bleibt bei 1: nach dem upsert ist der Key
        // bekannt, ein Retry fragt den Decider nicht erneut.
        let fs1 = try await connectWithRetry {
            try await CitadelFileSystem.connect(
                config: config, knownHosts: store,
                onUnknownHostKey: { _ in asked.increment(); return true })
        }
        await fs1.disconnect()
        #expect(asked.value == 1)
        #expect(try store.find(host: "127.0.0.1", port: 2222) != nil)

        let fs2 = try await CitadelFileSystem.connect(
            config: config, knownHosts: store,
            onUnknownHostKey: { _ in asked.increment(); return true })
        await fs2.disconnect()
        #expect(asked.value == 1)   // kein zweiter Prompt
    }

    @Test func rejectedHostKeyFailsWithoutStoring() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-tofu-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = KnownHostsStore(directory: dir)
        let config = try SSHConnectionConfig(
            host: "127.0.0.1", port: 2222, username: "testuser",
            auth: .password("testpass"))

        await #expect(throws: HostKeyError.rejectedByUser) {
            _ = try await CitadelFileSystem.connect(
                config: config, knownHosts: store, onUnknownHostKey: { _ in false })
        }
        #expect(try store.find(host: "127.0.0.1", port: 2222) == nil)
    }

    /// Räumt einen Test-Ordner unter /config via `docker exec rm -rf` auf.
    /// Kein SFTP-delete verfügbar (RemoteFileSystem kennt kein rmdir/remove) —
    /// daher Cleanup über den Container, wie schon bei `makeInstalledKey`.
    private func cleanupConfigPath(_ path: String) {
        let rm = Process()
        rm.executableURL = URL(fileURLWithPath: "/usr/local/bin/docker")
        rm.arguments = ["exec", "macscp-test-sshd", "rm", "-rf", path]
        try? rm.run()
        rm.waitUntilExit()
    }

    @Test func createDirectoryCreatesNewDirectory() async throws {
        let fs = try await connect()
        defer { Task { await fs.disconnect() } }
        let base = "/config/macscp-mkdir-test-\(UUID().uuidString)"
        defer { cleanupConfigPath(base) }

        try await fs.createDirectory(at: base)

        let item = try await fs.stat(path: base)
        #expect(item.kind == .directory)
    }

    @Test func createDirectoryCreatesLastLevelAfterParentExists() async throws {
        // Citadel legt NUR die letzte Ebene an — erst Basis, dann Unterordner.
        let fs = try await connect()
        defer { Task { await fs.disconnect() } }
        let base = "/config/macscp-mkdir-test-\(UUID().uuidString)"
        defer { cleanupConfigPath(base) }
        let sub = base + "/sub"

        try await fs.createDirectory(at: base)
        try await fs.createDirectory(at: sub)

        let item = try await fs.stat(path: sub)
        #expect(item.kind == .directory)
    }

    @Test func createDirectoryIsIdempotentOnSecondCall() async throws {
        let fs = try await connect()
        defer { Task { await fs.disconnect() } }
        let base = "/config/macscp-mkdir-test-\(UUID().uuidString)"
        defer { cleanupConfigPath(base) }

        try await fs.createDirectory(at: base)
        // Zweiter Aufruf am selben Pfad darf NICHT werfen (idempotent).
        try await fs.createDirectory(at: base)

        let item = try await fs.stat(path: base)
        #expect(item.kind == .directory)
    }

    @Test func createDirectoryThrowsProtocolErrorOnFileCollision() async throws {
        let fs = try await connect()
        defer { Task { await fs.disconnect() } }
        let path = "/config/macscp-mkdir-test-\(UUID().uuidString).txt"
        defer { cleanupConfigPath(path) }

        let (stream, continuation) = AsyncThrowingStream<Data, Error>.makeStream()
        continuation.yield(Data("mkdir-collision".utf8))
        continuation.finish()
        try await fs.write(path: path, contents: stream)

        do {
            try await fs.createDirectory(at: path)
            Issue.record("protocolError erwartet")
        } catch let error as RemoteFSError {
            guard case .protocolError = error else {
                Issue.record("protocolError erwartet, war: \(error)")
                return
            }
        }
    }

    @Test func tamperedKnownKeyFailsHardWithMismatch() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-tofu-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = KnownHostsStore(directory: dir)
        try store.upsert(KnownHostKey(
            host: "127.0.0.1", port: 2222,
            keyType: "ssh-ed25519", publicKeyBase64: "QUJDREVG"))   // absichtlich falsch
        let config = try SSHConnectionConfig(
            host: "127.0.0.1", port: 2222, username: "testuser",
            auth: .password("testpass"))

        do {
            _ = try await CitadelFileSystem.connect(
                config: config, knownHosts: store,
                onUnknownHostKey: { _ in
                    Issue.record("Mismatch darf NIE den Decider fragen")
                    return true
                })
            Issue.record("mismatch erwartet")
        } catch let error as HostKeyError {
            guard case .mismatch = error else {
                Issue.record("mismatch erwartet, war: \(error)")
                return
            }
        }
    }
}

/// Kleines threadsicheres Zähler-Double für die Decider-Aufrufe.
final class CallCounterBox: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() {
        lock.lock(); defer { lock.unlock() }
        count += 1
    }

    var value: Int {
        lock.lock(); defer { lock.unlock() }
        return count
    }
}
