import Foundation
import Testing
@testable import macSCPCore

/// Runs only with MACSCP_ITEST=1 and a running Docker test server
/// (docker compose -f docker/test-server/compose.yml up -d).
@Suite(
    "CitadelFileSystem against Docker SSH server",
    .enabled(if: ProcessInfo.processInfo.environment["MACSCP_ITEST"] == "1"),
    .serialized
)
struct CitadelFileSystemIntegrationTests {
    /// Cushions reconnect throttling of the test container: on a transient
    /// transport error, wait briefly and connect once more.
    /// Use ONLY for connects that are SUPPOSED to succeed — not for
    /// mismatch/reject tests (there the error is intentional).
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

        // /config is the writable home of testuser in the linuxserver image
        let remotePath = "/config/macscp-upload-test.bin"
        try await fs.write(path: remotePath, contents: stream)

        var readBack = Data()
        for try await chunk in try await fs.readStream(path: remotePath) {
            readBack.append(chunk)
        }
        #expect(readBack == payload)
    }

    /// M5c/T2: A large upload is cancelled after the first progress event.
    /// Expectation: `copyFile` throws `CancellationError`, the remote partial
    /// file is GENUINELY smaller than the source, and the connection remains
    /// usable afterward.
    @Test func cancelledUploadStopsEarlyAndKeepsConnectionUsable() async throws {
        let fs = try await connect()
        defer { Task { await fs.disconnect() } }

        // Generate source at runtime (128 MiB random) — NEVER checked in.
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

        // Cancel after the FIRST progress event.
        let progressSeen = CallCounterBox()
        let source = LocalFileSystem()
        let task = Task {
            try await TransferEngine.copyFile(
                from: source, sourcePath: localFile.path(percentEncoded: false),
                to: fs, destinationDirectory: "/config", fileName: remoteName,
                onProgress: { _ in progressSeen.increment() })
        }

        // Wait for the first progress event (with an upper bound against hangs).
        var polls = 0
        while progressSeen.value == 0 && polls < 500 {
            try await Task.sleep(for: .milliseconds(10))
            polls += 1
        }
        #expect(progressSeen.value > 0)
        task.cancel()

        // Cancellation must become visible as CancellationError.
        do {
            try await task.value
            Issue.record("expected CancellationError, transfer ran to completion")
        } catch is CancellationError {
            // expected
        } catch {
            Issue.record("expected CancellationError, was: \(error)")
        }

        // Remote partial file is GENUINELY smaller than the source (docker exec stat).
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
        #expect(remoteSize < sourceSize)   // GENUINELY smaller — cancellation caught mid-transfer

        // Connection/SFTP remains usable afterward.
        let listing = try await fs.list(path: "/config")
        #expect(listing.contains { $0.name == remoteName })
    }

    /// M5c/T4 GATED VALIDATION (must pass before any parallel-slot code lands):
    /// three ~8 MiB uploads run TRULY CONCURRENTLY over ONE `CitadelFileSystem`
    /// — i.e. a single SFTP channel — via a `TaskGroup` calling
    /// `TransferEngine.copyFile` directly. Expectation: each file arrives
    /// byte-identical (source md5 == remote md5, checked with docker exec). If
    /// this fails structurally, the channel cannot tolerate parallelism and the
    /// whole parallel-slot task is BLOCKED (parallelism stays at 1).
    @Test func threeConcurrentUploadsOverOneChannelArriveIntact() async throws {
        let fs = try await connect()
        defer { Task { await fs.disconnect() } }

        let localDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-parallel-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: localDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: localDir) }

        // Build three distinct ~8 MiB random sources at runtime (never checked in).
        struct Upload { let localPath: String; let remoteName: String; let remotePath: String; let md5: String }
        var uploads: [Upload] = []
        for index in 0..<3 {
            let localFile = localDir.appendingPathComponent("src-\(index).bin")
            let dd = Process()
            dd.executableURL = URL(fileURLWithPath: "/bin/dd")
            dd.arguments = ["if=/dev/urandom", "of=\(localFile.path(percentEncoded: false))",
                            "bs=1m", "count=8"]
            dd.standardError = FileHandle.nullDevice
            try dd.run()
            dd.waitUntilExit()
            #expect(dd.terminationStatus == 0)

            let remoteName = "macscp-parallel-\(UUID().uuidString)-\(index).bin"
            uploads.append(Upload(
                localPath: localFile.path(percentEncoded: false),
                remoteName: remoteName, remotePath: "/config/\(remoteName)",
                md5: localMD5(localFile.path(percentEncoded: false))))
        }
        defer { for upload in uploads { cleanupConfigPath(upload.remotePath) } }

        // Drive all three uploads TRULY concurrently over the single channel.
        let source = LocalFileSystem()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for upload in uploads {
                group.addTask {
                    try await TransferEngine.copyFile(
                        from: source, sourcePath: upload.localPath,
                        to: fs, destinationDirectory: "/config", fileName: upload.remoteName,
                        onProgress: { _ in })
                }
            }
            try await group.waitForAll()
        }

        // Byte-identical arrival: remote md5 (docker exec) must equal source md5.
        for upload in uploads {
            #expect(remoteMD5(upload.remotePath) == upload.md5)
        }
    }

    /// M5c/T4 gated end-to-end: five files uploaded THROUGH the queue with
    /// `maxConcurrent == 3` (a multi-drop equivalent) all arrive byte-identical.
    /// Exercises the real parallel-slot dispatch over one live SFTP channel.
    @MainActor
    @Test func queueUploadsFilesInParallelSlotsIntact() async throws {
        let fs = try await connect()
        defer { Task { await fs.disconnect() } }

        let localDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-queue-parallel-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: localDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: localDir) }

        struct Upload { let localPath: String; let remoteName: String; let remotePath: String; let md5: String }
        var uploads: [Upload] = []
        for index in 0..<5 {
            let localFile = localDir.appendingPathComponent("q-\(index).bin")
            let dd = Process()
            dd.executableURL = URL(fileURLWithPath: "/bin/dd")
            dd.arguments = ["if=/dev/urandom", "of=\(localFile.path(percentEncoded: false))",
                            "bs=1m", "count=4"]
            dd.standardError = FileHandle.nullDevice
            try dd.run()
            dd.waitUntilExit()
            #expect(dd.terminationStatus == 0)

            let remoteName = "macscp-queue-parallel-\(UUID().uuidString)-\(index).bin"
            uploads.append(Upload(
                localPath: localFile.path(percentEncoded: false),
                remoteName: remoteName, remotePath: "/config/\(remoteName)",
                md5: localMD5(localFile.path(percentEncoded: false))))
        }
        defer { for upload in uploads { cleanupConfigPath(upload.remotePath) } }

        let vm = TransferQueueViewModel()
        vm.maxConcurrent = 3
        let source = LocalFileSystem()
        for upload in uploads {
            vm.enqueue(
                fileName: upload.remoteName, direction: .upload,
                source: source, sourcePath: upload.localPath,
                destination: fs, destinationDirectory: "/config",
                onCompleted: nil)
        }

        // Poll until every queue item reaches a terminal state.
        var polls = 0
        while vm.items.contains(where: { !$0.status.isTerminal }) && polls < 2000 {
            try await Task.sleep(for: .milliseconds(20))
            polls += 1
        }
        #expect(vm.items.allSatisfy { $0.status == .finished })

        for upload in uploads {
            #expect(remoteMD5(upload.remotePath) == upload.md5)
        }
    }

    /// Local md5 via `/sbin/md5 -q` (returns just the hash).
    private func localMD5(_ path: String) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/sbin/md5")
        process.arguments = ["-q", path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    /// Remote md5 via `docker exec macscp-test-sshd md5sum <path>` (first field).
    private func remoteMD5(_ path: String) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/local/bin/docker")
        process.arguments = ["exec", "macscp-test-sshd", "md5sum", path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return out.split(whereSeparator: { $0 == " " || $0 == "\n" }).first.map(String.init) ?? ""
    }

    /// Remote file size via `docker exec stat -c %s` (M5d/T2 resume tests).
    private func remoteSize(_ path: String) -> Int {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/local/bin/docker")
        process.arguments = ["exec", "macscp-test-sshd", "stat", "-c", "%s", path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return Int(out) ?? -1
    }

    /// Remote mtime (epoch seconds) via `docker exec stat -c %Y` (M5d/T2
    /// "resume on complete file writes nothing" test).
    private func remoteMtime(_ path: String) -> Int {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/local/bin/docker")
        process.arguments = ["exec", "macscp-test-sshd", "stat", "-c", "%Y", path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return Int(out) ?? -1
    }

    /// Generates a runtime key and installs the public key in the container.
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

            // Note: authorized_keys grows across runs on a long-lived container —
            // acceptable for the test rig.
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
        // Only the FIRST (expected-to-succeed) connect is guarded against
        // reconnect throttling. The decider counter stays at 1: after the
        // upsert the key is known, a retry does not ask the decider again.
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
        #expect(asked.value == 1)   // no second prompt
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

    /// Cleans up a test folder under /config via `docker exec rm -rf`. Used
    /// for directories and as a catch-all after a test's own `fs.delete`
    /// (RemoteFileSystem only deletes FILES, no rmdir/remove for directories).
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
        // Citadel creates ONLY the last level — first base, then subfolder.
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
        // Second call on the same path must NOT throw (idempotent).
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
            Issue.record("expected protocolError")
        } catch let error as RemoteFSError {
            guard case .protocolError = error else {
                Issue.record("expected protocolError, was: \(error)")
                return
            }
        }
    }

    // MARK: - M5d/T1: offset reads, append writes, delete

    @Test func readStreamFromOffsetReturnsExactRemainingBytes() async throws {
        let fs = try await connect()
        defer { Task { await fs.disconnect() } }
        let remotePath = "/config/macscp-offset-test-\(UUID().uuidString).bin"
        defer { cleanupConfigPath(remotePath) }

        // Spans multiple chunks so the offset lands mid-stream, not just in the first chunk.
        let payload = Data((0..<(TransferChunk.size * 2 + 123)).map { UInt8($0 % 251) })
        let (stream, continuation) = AsyncThrowingStream<Data, Error>.makeStream()
        continuation.yield(payload)
        continuation.finish()
        try await fs.write(path: remotePath, mode: .overwrite, contents: stream)

        let offset = UInt64(TransferChunk.size) + 50
        var readBack = Data()
        for try await chunk in try await fs.readStream(path: remotePath, fromOffset: offset) {
            readBack.append(chunk)
        }
        #expect(readBack == payload.suffix(from: Int(offset)))
    }

    @Test func readStreamFromOffsetBeyondEOFYieldsEmptyStream() async throws {
        let fs = try await connect()
        defer { Task { await fs.disconnect() } }
        let remotePath = "/config/macscp-offset-eof-test-\(UUID().uuidString).bin"
        defer { cleanupConfigPath(remotePath) }

        let (stream, continuation) = AsyncThrowingStream<Data, Error>.makeStream()
        continuation.yield(Data("short".utf8))
        continuation.finish()
        try await fs.write(path: remotePath, contents: stream)

        var collected = Data()
        for try await chunk in try await fs.readStream(path: remotePath, fromOffset: 9999) {
            collected.append(chunk)
        }
        #expect(collected.isEmpty)
    }

    /// Overwrite writes the first part, a second `write(mode: .append)` adds
    /// the rest — the resulting remote file must be BYTE-IDENTICAL to a
    /// locally constructed reference (first part + second part), verified
    /// via md5 (docker exec) so the comparison also covers multi-chunk
    /// transfers, not just tiny in-memory buffers.
    @Test func overwriteThenAppendProducesByteIdenticalFullContent() async throws {
        let fs = try await connect()
        defer { Task { await fs.disconnect() } }

        let localDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-append-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: localDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: localDir) }

        let firstPart = Data((0..<(TransferChunk.size + 500)).map { UInt8($0 % 233) })
        let secondPart = Data((0..<(TransferChunk.size / 2 + 77)).map { UInt8(($0 + 17) % 199) })
        let referenceFile = localDir.appendingPathComponent("reference.bin")
        try (firstPart + secondPart).write(to: referenceFile)
        let referenceMD5 = localMD5(referenceFile.path(percentEncoded: false))

        let remotePath = "/config/macscp-append-test-\(UUID().uuidString).bin"
        defer { cleanupConfigPath(remotePath) }

        let (stream1, continuation1) = AsyncThrowingStream<Data, Error>.makeStream()
        continuation1.yield(firstPart)
        continuation1.finish()
        try await fs.write(path: remotePath, mode: .overwrite, contents: stream1)

        let (stream2, continuation2) = AsyncThrowingStream<Data, Error>.makeStream()
        continuation2.yield(secondPart)
        continuation2.finish()
        try await fs.write(path: remotePath, mode: .append, contents: stream2)

        #expect(remoteMD5(remotePath) == referenceMD5)
    }

    @Test func deleteRemovesFileConfirmedByListAndSecondDeleteThrowsNotFound() async throws {
        let fs = try await connect()
        defer { Task { await fs.disconnect() } }
        let remoteName = "macscp-delete-test-\(UUID().uuidString).bin"
        let remotePath = "/config/\(remoteName)"
        defer { cleanupConfigPath(remotePath) }

        let (stream, continuation) = AsyncThrowingStream<Data, Error>.makeStream()
        continuation.yield(Data("delete me".utf8))
        continuation.finish()
        try await fs.write(path: remotePath, contents: stream)

        let beforeListing = try await fs.list(path: "/config")
        #expect(beforeListing.contains { $0.name == remoteName })

        try await fs.delete(path: remotePath)

        let afterListing = try await fs.list(path: "/config")
        #expect(!afterListing.contains { $0.name == remoteName })

        await #expect(throws: RemoteFSError.notFound(path: remotePath)) {
            try await fs.delete(path: remotePath)
        }
    }

    // MARK: - M5d/T2: engine resume

    /// The gated core test for M5d/T2: a 32 MiB upload is cancelled after the
    /// first progress event (the M5c/T2 cancel pattern), leaving a GENUINELY
    /// partial remote file. `copyFile(resume: true)` for the SAME source/
    /// destination must then continue from that partial's size and produce a
    /// remote file BYTE-IDENTICAL to the local source (md5 match) — not just
    /// "same size".
    @Test func resumeAfterCancelProducesByteIdenticalFile() async throws {
        let fs = try await connect()
        defer { Task { await fs.disconnect() } }

        let localDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-resume-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: localDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: localDir) }
        let localFile = localDir.appendingPathComponent("big.bin")

        let dd = Process()
        dd.executableURL = URL(fileURLWithPath: "/bin/dd")
        dd.arguments = ["if=/dev/urandom", "of=\(localFile.path(percentEncoded: false))",
                        "bs=1m", "count=32"]
        dd.standardError = FileHandle.nullDevice
        try dd.run()
        dd.waitUntilExit()
        #expect(dd.terminationStatus == 0)
        let sourceSize = try FileManager.default
            .attributesOfItem(atPath: localFile.path(percentEncoded: false))[.size] as? Int ?? 0
        #expect(sourceSize == 32 * 1024 * 1024)
        let sourceMD5 = localMD5(localFile.path(percentEncoded: false))

        let remoteName = "macscp-resume-upload-\(UUID().uuidString).bin"
        let remotePath = "/config/\(remoteName)"
        defer { cleanupConfigPath(remotePath) }

        // Cancel after the FIRST progress event — same pattern as M5c/T2.
        let progressSeen = CallCounterBox()
        let source = LocalFileSystem()
        let task = Task {
            try await TransferEngine.copyFile(
                from: source, sourcePath: localFile.path(percentEncoded: false),
                to: fs, destinationDirectory: "/config", fileName: remoteName,
                onProgress: { _ in progressSeen.increment() })
        }

        var polls = 0
        while progressSeen.value == 0 && polls < 500 {
            try await Task.sleep(for: .milliseconds(10))
            polls += 1
        }
        #expect(progressSeen.value > 0)
        task.cancel()

        do {
            try await task.value
            Issue.record("expected CancellationError, transfer ran to completion")
        } catch is CancellationError {
            // expected
        } catch {
            Issue.record("expected CancellationError, was: \(error)")
        }

        // Partial file is GENUINELY smaller than the source.
        let partialSize = remoteSize(remotePath)
        #expect(partialSize >= 0)
        #expect(partialSize < sourceSize)

        // Resume: continue from the partial's offset.
        try await TransferEngine.copyFile(
            from: source, sourcePath: localFile.path(percentEncoded: false),
            to: fs, destinationDirectory: "/config", fileName: remoteName,
            resume: true,
            onProgress: { _ in })

        #expect(remoteSize(remotePath) == sourceSize)
        #expect(remoteMD5(remotePath) == sourceMD5)   // byte-identical after resume
    }

    /// Resuming an ALREADY-COMPLETE remote file must not write anything at
    /// all: size and mtime are captured before and after the resume call and
    /// must be unchanged (docker exec stat).
    @Test func resumeOnAlreadyCompleteFileWritesNothing() async throws {
        let fs = try await connect()
        defer { Task { await fs.disconnect() } }

        let localDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-resume-complete-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: localDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: localDir) }
        let localFile = localDir.appendingPathComponent("small.bin")
        let payload = Data((0..<(TransferChunk.size + 321)).map { UInt8($0 % 211) })
        try payload.write(to: localFile)

        let remoteName = "macscp-resume-complete-\(UUID().uuidString).bin"
        let remotePath = "/config/\(remoteName)"
        defer { cleanupConfigPath(remotePath) }

        let source = LocalFileSystem()
        // First, a full plain transfer completes the file.
        try await TransferEngine.copyFile(
            from: source, sourcePath: localFile.path(percentEncoded: false),
            to: fs, destinationDirectory: "/config", fileName: remoteName,
            onProgress: { _ in })

        let beforeSize = remoteSize(remotePath)
        let beforeMtime = remoteMtime(remotePath)
        #expect(beforeSize == payload.count)

        // Let the filesystem's mtime clock tick forward so a spurious write
        // (bug) would be observable as a changed mtime, not hidden by
        // same-second timestamp resolution.
        try await Task.sleep(for: .seconds(1))

        try await TransferEngine.copyFile(
            from: source, sourcePath: localFile.path(percentEncoded: false),
            to: fs, destinationDirectory: "/config", fileName: remoteName,
            resume: true,
            onProgress: { _ in })

        #expect(remoteSize(remotePath) == beforeSize)
        #expect(remoteMtime(remotePath) == beforeMtime)   // no write occurred
    }

    // MARK: - M7a/T1: rename + setPermissions

    /// Uploads a file, renames it, and confirms the listing shows only the
    /// new name (not both). Renaming a second file onto the same (now
    /// occupied) name must throw — no silent overwrite. Then `chmod` via
    /// `setPermissions`, re-stat, and confirm the low 12 bits round-trip.
    @Test func renameAndSetPermissionsRoundtrip() async throws {
        let fs = try await connect()
        defer { Task { await fs.disconnect() } }

        let base = "/config/macscp-rename-test-\(UUID().uuidString)"
        let oldName = "\(base)-old.bin"
        let newName = "\(base)-new.bin"
        let otherName = "\(base)-other.bin"
        defer {
            cleanupConfigPath(oldName)
            cleanupConfigPath(newName)
            cleanupConfigPath(otherName)
        }

        let (stream, continuation) = AsyncThrowingStream<Data, Error>.makeStream()
        continuation.yield(Data("rename me".utf8))
        continuation.finish()
        try await fs.write(path: oldName, contents: stream)

        let beforeListing = try await fs.list(path: "/config")
        #expect(beforeListing.contains { $0.path == oldName })
        #expect(!beforeListing.contains { $0.path == newName })

        try await fs.rename(from: oldName, to: newName)

        let afterListing = try await fs.list(path: "/config")
        #expect(!afterListing.contains { $0.path == oldName })
        #expect(afterListing.contains { $0.path == newName })

        // Renaming another file onto the now-occupied name must throw —
        // no silent overwrite, source stays where it is.
        let (otherStream, otherContinuation) = AsyncThrowingStream<Data, Error>.makeStream()
        otherContinuation.yield(Data("do not overwrite".utf8))
        otherContinuation.finish()
        try await fs.write(path: otherName, contents: otherStream)

        await #expect(throws: RemoteFSError.self) {
            try await fs.rename(from: otherName, to: newName)
        }
        let afterCollisionListing = try await fs.list(path: "/config")
        #expect(afterCollisionListing.contains { $0.path == otherName })

        // setPermissions: chmod 0o640, re-stat, low 12 bits must match exactly.
        try await fs.setPermissions(path: newName, permissions: 0o640)
        let stat = try await fs.stat(path: newName)
        #expect((stat.permissions ?? 0) & 0o7777 == 0o640)
    }

    @Test func tamperedKnownKeyFailsHardWithMismatch() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-tofu-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = KnownHostsStore(directory: dir)
        try store.upsert(KnownHostKey(
            host: "127.0.0.1", port: 2222,
            keyType: "ssh-ed25519", publicKeyBase64: "QUJDREVG"))   // deliberately wrong
        let config = try SSHConnectionConfig(
            host: "127.0.0.1", port: 2222, username: "testuser",
            auth: .password("testpass"))

        do {
            _ = try await CitadelFileSystem.connect(
                config: config, knownHosts: store,
                onUnknownHostKey: { _ in
                    Issue.record("mismatch must NEVER ask the decider")
                    return true
                })
            Issue.record("expected mismatch")
        } catch let error as HostKeyError {
            guard case .mismatch = error else {
                Issue.record("expected mismatch, was: \(error)")
                return
            }
        }
    }
}

/// Small thread-safe counter double for the decider calls.
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
