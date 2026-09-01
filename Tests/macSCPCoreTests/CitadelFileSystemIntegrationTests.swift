import Foundation
import NIOCore
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

    private func connect(port: Int = 2222) async throws -> CitadelFileSystem {
        let config = try SSHConnectionConfig(
            host: "127.0.0.1",
            port: port,
            username: "testuser",
            auth: .password("testpass")
        )
        // The store is only consulted during the handshake (never retained by
        // the returned `CitadelFileSystem`), so its temp directory can be
        // removed right after `connect` returns — every caller of this
        // shared helper gets known-hosts cleanup for free.
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-kh-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = KnownHostsStore(directory: dir)
        return try await connectWithRetry {
            try await CitadelFileSystem.connect(
                config: config, connectTimeout: .seconds(30), knownHosts: store, onUnknownHostKey: .asking { _ in true })
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

    /// M11m/T1: the readdir path parses owner/group NAMES from each
    /// entry's `longname` (falling back to the numeric uidgid, never
    /// nothing) — verified live against the Docker rig rather than
    /// asserting a specific username, since the seed directory's on-disk
    /// ownership (and therefore what the container's `ls -l` reports) is
    /// host-dependent, not a fixed rig value (see the M11m design doc's
    /// "honest about longname fragility" section).
    @Test func listsSeededDirectoryReportsOwnerAndGroup() async throws {
        let fs = try await connect()
        defer { Task { await fs.disconnect() } }

        let items = try await fs.list(path: "/data/seed")
        let file = try #require(items.first { $0.name == "hello.txt" })
        #expect(file.owner != nil)
        #expect(file.group != nil)
    }

    @Test func statReturnsFileDetails() async throws {
        let fs = try await connect()
        defer { Task { await fs.disconnect() } }

        let item = try await fs.stat(path: "/data/seed/hello.txt")
        #expect(item.kind == .file)
        #expect((item.size ?? 0) > 0)
    }

    /// Regression: `stat("/")` used to compose its path by joining the
    /// root's basename ("/") onto its parent (also "/"), yielding "//".
    /// `RemoteFileItem.id` IS the path, so the doubled slash travelled on
    /// into navigation, breadcrumbs and error texts. Pinned live because
    /// the unit-level fix (`SFTPAttributeMapper.item`) only holds if
    /// `stat` keeps handing the root down as both name and directory.
    @Test func statOfRootYieldsSingleSlashPath() async throws {
        let fs = try await connect()
        defer { Task { await fs.disconnect() } }

        let item = try await fs.stat(path: "/")
        #expect(item.path == "/")
        #expect(item.id == "/")
        #expect(item.name == "/")
        #expect(item.kind == .directory)
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
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-kh-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = KnownHostsStore(directory: dir)
        await #expect(throws: RemoteFSError.authenticationFailed) {
            _ = try await CitadelFileSystem.connect(
                config: config, connectTimeout: .seconds(30), knownHosts: store, onUnknownHostKey: .asking { _ in true })
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

    /// Remote POSIX mode as an octal string (e.g. `"644"`) via
    /// `docker exec stat -c %a` (M11c/T4 recursive-permissions test).
    private func remotePermissions(_ path: String) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/local/bin/docker")
        process.arguments = ["exec", "macscp-test-sshd", "stat", "-c", "%a", path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
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
    /// `type`/`bits` default to the original M3b ed25519 shape; M10d/T2
    /// reuses this for RSA (`-t rsa -b 2048`) so the gated agent tests share
    /// the exact same docker-exec authorized_keys installation pattern.
    /// `passphrase`, when non-nil, is passed to `ssh-keygen -N` so the
    /// generated private key is encrypted (T4: the passphrase-protected
    /// agent route).
    private func makeInstalledKey(type: String = "ed25519", bits: Int? = nil, passphrase: String? = nil) throws -> (dir: URL, keyPath: String) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-itest-key-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let keyURL = dir.appendingPathComponent("id_\(type)")

        do {
            let keygen = Process()
            keygen.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
            var arguments = ["-t", type, "-f", keyURL.path(percentEncoded: false),
                             "-N", passphrase ?? "", "-q", "-C", "macscp-itest"]
            if let bits {
                arguments += ["-b", String(bits)]
            }
            keygen.arguments = arguments
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
        let khDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-kh-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: khDir) }
        let store = KnownHostsStore(directory: khDir)
        let fs = try await connectWithRetry {
            try await CitadelFileSystem.connect(
                config: config, connectTimeout: .seconds(30), knownHosts: store, onUnknownHostKey: .asking { _ in true })
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
                config: config, connectTimeout: .seconds(30), knownHosts: store,
                onUnknownHostKey: .asking { _ in asked.increment(); return true })
        }
        await fs1.disconnect()
        #expect(asked.value == 1)
        #expect(try store.find(host: "127.0.0.1", port: 2222) != nil)

        let fs2 = try await CitadelFileSystem.connect(
            config: config, connectTimeout: .seconds(30), knownHosts: store,
            onUnknownHostKey: .asking { _ in asked.increment(); return true })
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
                config: config, connectTimeout: .seconds(30), knownHosts: store,
                onUnknownHostKey: .asking { _ in false })
        }
        #expect(try store.find(host: "127.0.0.1", port: 2222) == nil)
    }

    /// Accepting an unknown key writes it and then RECONNECTS, so the write
    /// is load-bearing here — unlike the certificate path, where the
    /// handshake continues in place and a failed write is only recorded. If
    /// the store cannot be written, the reconnect meets the very same
    /// unknown key: the connect must fail with a typed error instead of
    /// asking the user again for a key that can never be remembered.
    @Test func acceptedHostKeyThatCannotBeStoredFailsTheConnect() async throws {
        // A store directory that is actually a FILE, so `upsert`'s
        // `createDirectory` throws — a real store on a real unwritable path.
        let file = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-tofu-blocked-\(UUID().uuidString)")
        try Data().write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let store = KnownHostsStore(directory: file)
        let config = try SSHConnectionConfig(
            host: "127.0.0.1", port: 2222, username: "testuser",
            auth: .password("testpass"))

        let asked = CallCounterBox()
        do {
            _ = try await CitadelFileSystem.connect(
                config: config, connectTimeout: .seconds(30), knownHosts: store,
                onUnknownHostKey: .asking { _ in asked.increment(); return true })
            Issue.record("expected the connect to fail")
        } catch let error as RemoteFSError {
            guard case .connectionFailed(let reason) = error else {
                Issue.record("expected .connectionFailed, got \(error)")
                return
            }
            // Named, not a stringified Foundation error: the read side's
            // verdict reads the same way, and neither is a question the
            // user can answer by retrying.
            #expect(reason.hasPrefix("known_hosts store not writable"))
        }
        // Asked once. The point of failing rather than continuing is that
        // the user is not put in front of the same prompt on every retry.
        #expect(asked.value == 1)
    }

    /// Cleans up a test folder under /config via `docker exec rm -rf`. Used
    /// for directories and as a catch-all after a test's own `fs.delete`
    /// (RemoteFileSystem only deletes FILES, no rmdir/remove for directories).
    private func cleanupConfigPath(_ path: String, container: String = "macscp-test-sshd") {
        let rm = Process()
        rm.executableURL = URL(fileURLWithPath: "/usr/local/bin/docker")
        rm.arguments = ["exec", container, "rm", "-rf", path]
        try? rm.run()
        rm.waitUntilExit()
    }

    /// M18a final review (Important-1): the S3 counterpart of
    /// `createFileCreatesThenCollidesAgainstMinIO` — proof that a real SFTP
    /// server's "no such file" really arrives as `RemoteFSError.notFound`
    /// (via `mapSFTPError`'s `SSH_FX_NO_SUCH_FILE` branch), so the strict
    /// existence probe still lets New File work, and that a collision leaves
    /// the existing file's bytes alone instead of truncating it.
    @MainActor
    @Test func createFileCreatesThenCollidesOnTheRealServer() async throws {
        let fs = try await connect()
        defer { Task { await fs.disconnect() } }
        let base = "/config/macscp-createfile-\(UUID().uuidString)"
        try await fs.createDirectory(at: base)
        defer { cleanupConfigPath(base) }

        let vm = RemoteBrowserViewModel(fs: fs, startPath: base)
        await vm.load()

        #expect(await vm.createFile(named: "notes.txt") == nil)
        let created = try await fs.stat(path: "\(base)/notes.txt")
        #expect(created.kind == .file)
        #expect(created.size == 0)

        let body = Data("keep me".utf8)
        let uploadStream = AsyncThrowingStream<Data, Error> { continuation in
            continuation.yield(body)
            continuation.finish()
        }
        try await fs.write(path: "\(base)/notes.txt", mode: .overwrite, contents: uploadStream)

        #expect(await vm.createFile(named: "notes.txt") != nil)
        var readBack = Data()
        for try await chunk in try await fs.readStream(path: "\(base)/notes.txt", fromOffset: 0) {
            readBack.append(chunk)
        }
        #expect(readBack == body)
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

    /// Regression: the collision probe used to be
    /// `if (try? await sftp.getAttributes(at: to)) != nil`, which collapses
    /// EVERY stat failure — `permissionDenied`, a protocol error, a torn
    /// connection — into the same "nothing is there" verdict as a genuine
    /// "no such file". Only SSH_FX_NO_SUCH_FILE (i.e. `mapSFTPError`'s
    /// `.notFound`) means the destination is definitely free; anything else
    /// leaves existence UNKNOWN and must surface as that error, naming the
    /// destination it could not probe — not fall through to `sftp.rename`
    /// and report whatever the server then says about the SOURCE.
    ///
    /// The destination here sits in a chmod-000 directory, so SFTP stat on
    /// it is denied (EACCES → SSH_FX_PERMISSION_DENIED) while the source is
    /// perfectly readable. Matches `S3FileSystem.rename`'s strict
    /// `catch RemoteFSError.notFound` probe.
    @Test func renameSurfacesAnUnverifiableDestinationProbe() async throws {
        let fs = try await connect()
        defer { Task { await fs.disconnect() } }

        let base = "/config/macscp-rename-probe-\(UUID().uuidString)"
        defer { cleanupConfigPath(base) }
        let source = "\(base)/source.bin"
        let destination = "\(base)/blocked/destination.bin"

        let seed = Process()
        seed.executableURL = URL(fileURLWithPath: "/usr/local/bin/docker")
        seed.arguments = [
            "exec", "macscp-test-sshd", "sh", "-c",
            // `docker exec` runs as root, so `base` is chowned to testuser
            // (uid 1000, the SFTP user) to make the source writable over
            // SFTP. `blocked` keeps mode 000 — testuser owns it but, not
            // being root, is still denied traversal, so stat of anything
            // inside it fails with EACCES rather than ENOENT.
            "mkdir -p '\(base)/blocked' && chown -R 1000:1000 '\(base)'"
                + " && chmod 000 '\(base)/blocked'",
        ]
        try seed.run()
        seed.waitUntilExit()
        #expect(seed.terminationStatus == 0)

        let body = Data("do not move me".utf8)
        let (stream, continuation) = AsyncThrowingStream<Data, Error>.makeStream()
        continuation.yield(body)
        continuation.finish()
        try await fs.write(path: source, contents: stream)

        do {
            try await fs.rename(from: source, to: destination)
            Issue.record("expected the unverifiable probe to throw")
        } catch let error as RemoteFSError {
            #expect(error == .permissionDenied(path: destination))
        }

        // The source stays exactly where it was, with its bytes intact.
        let after = try await fs.stat(path: source)
        #expect(after.kind == .file)
        #expect(after.size == UInt64(body.count))
    }

    // MARK: - M7a/T2: deleteTree (RISK)

    /// A 2-level nested tree (files + an empty subdirectory + a symlink
    /// pointing at a FILE outside the tree, created via docker-exec `ln -s`)
    /// is removed with a single `deleteTree` call. The tree itself is gone
    /// afterward; the symlink's TARGET (outside the tree) survives, proving
    /// the walk deletes the link entry without ever following it.
    ///
    /// Review IMPORTANT-2: also covers a symlink-to-DIRECTORY nested INSIDE
    /// the tree (`sub/dirlink` -> an outside directory) — `list`/READDIR
    /// reports it unresolved just like the file symlink, so the walk deletes
    /// the link entry itself and never descends into (or removes) the
    /// outside directory's contents.
    @Test func deleteTreeRemovesNestedTreeButSymlinkTargetOutsideSurvives() async throws {
        let fs = try await connect()
        defer { Task { await fs.disconnect() } }

        let base = "/config/macscp-deletetree-\(UUID().uuidString)"
        let sub = "\(base)/sub"
        let victimPath = "/config/macscp-deletetree-victim-\(UUID().uuidString).txt"
        let outsideDir = "/config/macscp-deletetree-outsidedir-\(UUID().uuidString)"
        defer {
            cleanupConfigPath(base)
            cleanupConfigPath(victimPath)
            cleanupConfigPath(outsideDir)
        }

        let seed = Process()
        seed.executableURL = URL(fileURLWithPath: "/usr/local/bin/docker")
        seed.arguments = [
            "exec", "macscp-test-sshd", "sh", "-c",
            "mkdir -p '\(sub)' && mkdir -p '\(outsideDir)' && echo keep > '\(outsideDir)/keep.txt'"
                + " && echo victim > '\(victimPath)'"
                + " && echo hi > '\(base)/a.txt' && ln -s '\(victimPath)' '\(base)/link'"
                + " && ln -s '\(outsideDir)' '\(sub)/dirlink'"
                // `docker exec` runs as root, so everything under `base` is
                // root-owned (0755) by default — testuser (the SFTP user,
                // uid 1000) could list it but not unlink entries inside.
                // chown to testuser (matching the file's existing .ssh-seed
                // convention) so the SFTP-side deleteTree walk can actually
                // remove the seeded entries.
                + " && chown -R 1000:1000 '\(base)'",
        ]
        try seed.run()
        seed.waitUntilExit()
        #expect(seed.terminationStatus == 0)

        try await fs.deleteTree(at: base)

        await #expect(throws: RemoteFSError.notFound(path: base)) {
            _ = try await fs.stat(path: base)
        }

        // Symlink TARGET (outside the deleted tree) survives (docker exec test -f).
        let testFile = Process()
        testFile.executableURL = URL(fileURLWithPath: "/usr/local/bin/docker")
        testFile.arguments = ["exec", "macscp-test-sshd", "test", "-f", victimPath]
        try testFile.run()
        testFile.waitUntilExit()
        #expect(testFile.terminationStatus == 0)

        // The in-tree symlink-to-DIRECTORY's target survives with its
        // contents intact (docker exec test -f on the nested keep.txt).
        let testOutsideKeep = Process()
        testOutsideKeep.executableURL = URL(fileURLWithPath: "/usr/local/bin/docker")
        testOutsideKeep.arguments = [
            "exec", "macscp-test-sshd", "test", "-f", "\(outsideDir)/keep.txt",
        ]
        try testOutsideKeep.run()
        testOutsideKeep.waitUntilExit()
        #expect(testOutsideKeep.terminationStatus == 0)
    }

    /// Review CRITICAL-1: `deleteTree` called DIRECTLY on a top-level
    /// symlink-to-DIRECTORY (created via docker-exec `ln -s`) must remove
    /// ONLY the link — never follow it and recurse into (and destroy) the
    /// target directory's contents. SFTP stat follows symlinks and Citadel
    /// exposes no lstat, so this exercises the parent-listing-derived kind
    /// fix rather than a naive `stat`-based dispatch.
    @Test func deleteTreeOnSymlinkToDirectoryRemovesOnlyTheLink() async throws {
        let fs = try await connect()
        defer { Task { await fs.disconnect() } }

        let outsideDir = "/config/macscp-deletetree-dirlink-outside-\(UUID().uuidString)"
        let link = "/config/macscp-deletetree-dirlink-\(UUID().uuidString)"
        defer {
            cleanupConfigPath(outsideDir)
            cleanupConfigPath(link)
        }

        let seed = Process()
        seed.executableURL = URL(fileURLWithPath: "/usr/local/bin/docker")
        seed.arguments = [
            "exec", "macscp-test-sshd", "sh", "-c",
            "mkdir -p '\(outsideDir)' && echo keep > '\(outsideDir)/keep.txt'"
                + " && ln -s '\(outsideDir)' '\(link)'",
        ]
        try seed.run()
        seed.waitUntilExit()
        #expect(seed.terminationStatus == 0)

        try await fs.deleteTree(at: link)

        // The link itself is gone: it no longer appears in its parent's listing.
        let siblings = try await fs.list(path: "/config")
        #expect(!siblings.contains { $0.path == link })

        // The target directory AND its contents survive (docker exec test -f).
        let testKeep = Process()
        testKeep.executableURL = URL(fileURLWithPath: "/usr/local/bin/docker")
        testKeep.arguments = ["exec", "macscp-test-sshd", "test", "-f", "\(outsideDir)/keep.txt"]
        try testKeep.run()
        testKeep.waitUntilExit()
        #expect(testKeep.terminationStatus == 0)
    }

    /// A trailing slash on a symlink argument defeats `topLevelKind`'s exact
    /// parent-listing match (`entry.path == path` never matches `"link/"`),
    /// falling through to the SFTP stat fallback — which FOLLOWS the link and
    /// destroys the TARGET's contents (proven live in the M7a final review).
    /// Normalization must strip the trailing slash before the kind lookup.
    @Test func deleteTreeWithTrailingSlashOnSymlinkRemovesOnlyTheLink() async throws {
        let fs = try await connect()
        defer { Task { await fs.disconnect() } }

        let outsideDir = "/config/macscp-deletetree-tslash-outside-\(UUID().uuidString)"
        let link = "/config/macscp-deletetree-tslash-\(UUID().uuidString)"
        defer {
            cleanupConfigPath(outsideDir)
            cleanupConfigPath(link)
        }

        let seed = Process()
        seed.executableURL = URL(fileURLWithPath: "/usr/local/bin/docker")
        seed.arguments = [
            "exec", "macscp-test-sshd", "sh", "-c",
            "mkdir -p '\(outsideDir)' && echo keep > '\(outsideDir)/keep.txt'"
                + " && ln -s '\(outsideDir)' '\(link)'",
        ]
        try seed.run()
        seed.waitUntilExit()
        #expect(seed.terminationStatus == 0)

        try await fs.deleteTree(at: link + "/")

        // The link itself is gone: it no longer appears in its parent's listing.
        let siblings = try await fs.list(path: "/config")
        #expect(!siblings.contains { $0.path == link })

        // The target directory AND its contents survive (docker exec test -f).
        let testKeep = Process()
        testKeep.executableURL = URL(fileURLWithPath: "/usr/local/bin/docker")
        testKeep.arguments = ["exec", "macscp-test-sshd", "test", "-f", "\(outsideDir)/keep.txt"]
        try testKeep.run()
        testKeep.waitUntilExit()
        #expect(testKeep.terminationStatus == 0)
    }

    /// A ~50-file tree is seeded (docker-exec), `deleteTree` is started in a
    /// `Task` and cancelled immediately. Tolerant like the file's existing
    /// cancel tests: either `CancellationError` surfaces, or the walk simply
    /// finished before the cancellation was observed (both acceptable — the
    /// contract only promises a partially-deleted tree, never a corrupt
    /// one). A second `deleteTree` call cleans up whatever remains.
    @Test func deleteTreeCancellationLeavesConsistentServerState() async throws {
        let fs = try await connect()
        defer { Task { await fs.disconnect() } }

        let base = "/config/macscp-deletetree-cancel-\(UUID().uuidString)"
        defer { cleanupConfigPath(base) }

        let seed = Process()
        seed.executableURL = URL(fileURLWithPath: "/usr/local/bin/docker")
        seed.arguments = [
            "exec", "macscp-test-sshd", "sh", "-c",
            "mkdir -p '\(base)' && for i in $(seq 1 50); do echo x > '\(base)/f$i.txt'; done",
        ]
        try seed.run()
        seed.waitUntilExit()
        #expect(seed.terminationStatus == 0)

        let task = Task { try await fs.deleteTree(at: base) }
        task.cancel()

        do {
            try await task.value
            // The walk finished before the cancellation was observed — acceptable.
        } catch is CancellationError {
            // expected
        } catch {
            Issue.record("expected CancellationError or successful completion, was: \(error)")
        }

        // Consistent server state either way: a second call cleans up
        // whatever remains (a `notFound` here just means the first call
        // already finished the job).
        try? await fs.deleteTree(at: base)
    }

    // MARK: - M11c/T4: PermissionsTreeApplier (RISK)

    /// `PermissionsTreeApplier.apply` against the real Citadel/SFTP backend:
    /// a 2-level tree (root directory + a file + a subdirectory with its own
    /// file — four real entries) plus a symlink INSIDE the tree pointing at
    /// a file OUTSIDE the tree, created via docker-exec `ln -s` exactly like
    /// the `deleteTree` symlink test above. The walk must chmod every real
    /// entry to the new permissions while counting the symlink as skipped —
    /// and, the security property this test exists to prove, NEVER follow
    /// the symlink to chmod its outside target. The outside target is
    /// chowned to `testuser` (same as the tree) precisely so that a
    /// regression which DID follow the link would succeed in changing its
    /// mode rather than silently failing on a permission error — making the
    /// final assertion a real proof, not a coincidence of ownership.
    @Test func recursivePermissionsSkipSymlinksAndLeaveTargetsUntouched() async throws {
        let fs = try await connect()
        defer { Task { await fs.disconnect() } }

        let base = "/config/macscp-permstree-\(UUID().uuidString)"
        let sub = "\(base)/sub"
        let rootFile = "\(base)/a.txt"
        let subFile = "\(sub)/b.txt"
        let linkPath = "\(base)/link"
        let outsideFile = "/config/macscp-permstree-outside-\(UUID().uuidString).txt"
        defer {
            cleanupConfigPath(base)
            cleanupConfigPath(outsideFile)
        }

        let seed = Process()
        seed.executableURL = URL(fileURLWithPath: "/usr/local/bin/docker")
        seed.arguments = [
            "exec", "macscp-test-sshd", "sh", "-c",
            "mkdir -p '\(sub)' && echo root > '\(rootFile)' && echo sub > '\(subFile)'"
                + " && echo outside > '\(outsideFile)' && chmod 600 '\(outsideFile)'"
                + " && chown 1000:1000 '\(outsideFile)'"
                + " && ln -s '\(outsideFile)' '\(linkPath)'"
                // docker exec runs as root, so everything under `base` is
                // root-owned by default (matching the deleteTree symlink
                // test's convention) — chown to testuser (uid 1000) so the
                // SFTP-side setPermissions calls below can actually chmod
                // the seeded entries.
                + " && chown -R 1000:1000 '\(base)'",
        ]
        try seed.run()
        seed.waitUntilExit()
        #expect(seed.terminationStatus == 0)

        let originalOutsideMode = remotePermissions(outsideFile)
        #expect(originalOutsideMode == "600")

        let result = await PermissionsTreeApplier.apply(
            root: base, kind: .directory, filePermissions: 0o644, directoryPermissions: 0o755, on: fs)

        // Four real entries: base (dir), a.txt (file), sub (dir), sub/b.txt
        // (file). The symlink is counted separately and never touched.
        #expect(result.changed == 4)
        #expect(result.skippedSymlinks == 1)
        #expect(result.failed == 0)
        #expect(result.cancelled == false)

        // Every real entry now carries the new mode (docker exec stat -c %a).
        #expect(remotePermissions(base) == "755")
        #expect(remotePermissions(rootFile) == "644")
        #expect(remotePermissions(sub) == "755")
        #expect(remotePermissions(subFile) == "644")

        // SECURITY: the symlink's target OUTSIDE the tree keeps its
        // original, distinctive mode — proves `setPermissions` was never
        // called through the link (it would have changed to 0o644, since
        // the target is a regular file the walk's file-permissions branch
        // would apply were it ever handed the link's resolved target).
        #expect(remotePermissions(outsideFile) == originalOutsideMode)
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
                config: config, connectTimeout: .seconds(30), knownHosts: store,
                onUnknownHostKey: .asking { _ in
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

    // MARK: - M8b/T3: remote-to-remote streaming across two independent servers

    /// Proves `TransferEngine.copyFile` streams remote-to-remote across TWO
    /// separate SSH servers (127.0.0.1:2222 and :2223, second rig container
    /// `macscp-test-sshd-2`) with no local temp file involved by
    /// construction: the engine only ever holds a source `readStream` and
    /// feeds it directly into the destination `write`, so nothing local is
    /// created for this transfer. A ~256 KiB random payload is written to
    /// server 1, copied server-to-server, and read back from server 2 —
    /// bytes must match exactly.
    @Test func remoteToRemoteStreamCopiesByteIdentical() async throws {
        let fs1 = try await connect(port: 2222)
        defer { Task { await fs1.disconnect() } }
        let fs2 = try await connect(port: 2223)
        defer { Task { await fs2.disconnect() } }

        let sourceName = "macscp-r2r-source-\(UUID().uuidString).bin"
        let sourcePath = "/config/\(sourceName)"
        let destinationName = "macscp-r2r-dest-\(UUID().uuidString).bin"
        let destinationPath = "/config/\(destinationName)"
        defer {
            cleanupConfigPath(sourcePath, container: "macscp-test-sshd")
            cleanupConfigPath(destinationPath, container: "macscp-test-sshd-2")
        }

        // ~256 KiB random payload, written to server 1 only.
        let payload = Data((0..<(256 * 1024)).map { _ in UInt8.random(in: 0...255) })
        let (stream, continuation) = AsyncThrowingStream<Data, Error>.makeStream()
        continuation.yield(payload)
        continuation.finish()
        try await fs1.write(path: sourcePath, contents: stream)

        // Remote-to-remote: fs1 is the source, fs2 is the destination.
        try await TransferEngine.copyFile(
            from: fs1, sourcePath: sourcePath,
            to: fs2, destinationDirectory: "/config", fileName: destinationName,
            onProgress: { _ in })

        var readBack = Data()
        for try await chunk in try await fs2.readStream(path: destinationPath) {
            readBack.append(chunk)
        }
        #expect(readBack == payload)
    }

    // MARK: - M9d/T1: remote home directory resolution

    /// The rig's SFTP user lands in some absolute home directory (the exact
    /// value is a rig implementation detail — only the shape is pinned):
    /// it must be an absolute path and it must be listable, since the UI
    /// uses it as the remote pane's landing point at session start.
    @Test func homeDirectoryPathResolvesAbsoluteAndListable() async throws {
        let fs = try await connect()
        defer { Task { await fs.disconnect() } }

        let home = try await fs.homeDirectoryPath()
        #expect(home.hasPrefix("/"))
        _ = try await fs.list(path: home)   // landing point must be listable
    }

    // MARK: - M10c/T1: jump host (ProxyJump) two-stage connect

    /// The target ("sshd2", port 2222 — the container's INTERNAL port, as
    /// seen from inside the jump container, not the host-mapped :2223) is
    /// only reachable THROUGH the jump host (127.0.0.1:2222,
    /// macscp-test-sshd). A fresh KnownHostsStore means BOTH hops are
    /// unknown on the first connect: the decider must be asked exactly
    /// twice (jump key, then target key), `list("/")` must succeed, and
    /// `disconnect()` must close the jump client cleanly. A second connect
    /// with the SAME store must not ask the decider again — both keys are
    /// now remembered.
    @Test func jumpConnectListsOverHop() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-kh-jump-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = KnownHostsStore(directory: dir)
        let config = try SSHConnectionConfig(
            host: "sshd2", port: 2222, username: "testuser", auth: .password("testpass"),
            jump: .init(host: "127.0.0.1", port: 2222, username: "testuser", auth: .password("testpass")))

        let asked = CallCounterBox()
        let fs1 = try await connectWithRetry {
            try await CitadelFileSystem.connect(
                config: config, connectTimeout: .seconds(30), knownHosts: store,
                onUnknownHostKey: .asking { _ in asked.increment(); return true })
        }
        let items = try await fs1.list(path: "/")
        #expect(!items.isEmpty)
        #expect(asked.value == 2)   // both hops unknown on the first connect
        // Both hops actually learned — not just "asked twice" (an attempt
        // could be swallowed without ever reaching `upsert`).
        #expect(try store.find(host: "127.0.0.1", port: 2222) != nil)
        #expect(try store.find(host: "sshd2", port: 2222) != nil)
        await fs1.disconnect()

        let fs2 = try await CitadelFileSystem.connect(
            config: config, connectTimeout: .seconds(30), knownHosts: store,
            onUnknownHostKey: .asking { _ in asked.increment(); return true })
        await fs2.disconnect()
        #expect(asked.value == 2)   // both keys remembered — no second prompt
    }

    /// A wrong jump password must surface as `RemoteFSError.jumpAuthenticationFailed`
    /// — NOT `.authenticationFailed` (that case is reserved for the target hop) —
    /// so the connect form can highlight the jump credentials specifically.
    @Test func jumpWrongPasswordSurfacesJumpAuthFailed() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-kh-jump-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = KnownHostsStore(directory: dir)
        let config = try SSHConnectionConfig(
            host: "sshd2", port: 2222, username: "testuser", auth: .password("testpass"),
            jump: .init(host: "127.0.0.1", port: 2222, username: "testuser", auth: .password("WRONG")))

        await #expect(throws: RemoteFSError.jumpAuthenticationFailed) {
            _ = try await CitadelFileSystem.connect(
                config: config, connectTimeout: .seconds(30), knownHosts: store, onUnknownHostKey: .asking { _ in true })
        }
    }

    /// The invariant "mismatch = hard stop, decider never consulted" must
    /// hold on EVERY hop, not just the (already-tested) single-hop case.
    /// Here the JUMP hop's remembered key is tampered with; the target hop
    /// must never even be reached, so nothing about it is learned.
    @Test func jumpHopMismatchIsHardStop() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-kh-jump-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = KnownHostsStore(directory: dir)
        try store.upsert(KnownHostKey(
            host: "127.0.0.1", port: 2222,
            keyType: "ssh-ed25519", publicKeyBase64: "QUJDREVG"))   // deliberately wrong
        let config = try SSHConnectionConfig(
            host: "sshd2", port: 2222, username: "testuser", auth: .password("testpass"),
            jump: .init(host: "127.0.0.1", port: 2222, username: "testuser", auth: .password("testpass")))

        do {
            _ = try await CitadelFileSystem.connect(
                config: config, connectTimeout: .seconds(30), knownHosts: store,
                onUnknownHostKey: .asking { _ in
                    Issue.record("decider must never be consulted on mismatch")
                    return true
                })
            Issue.record("expected mismatch")
        } catch let error as HostKeyError {
            guard case .mismatch = error else {
                Issue.record("expected mismatch, was: \(error)")
                return
            }
        }
        #expect(try store.find(host: "sshd2", port: 2222) == nil)   // target never reached
    }

    /// Same invariant, TARGET hop this time: both keys are learned via a
    /// clean connect first, then the target's remembered key is tampered
    /// with. The mismatch must still hard-stop even though the jump hop
    /// itself verified cleanly.
    @Test func targetHopMismatchIsHardStop() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-kh-jump-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = KnownHostsStore(directory: dir)
        let config = try SSHConnectionConfig(
            host: "sshd2", port: 2222, username: "testuser", auth: .password("testpass"),
            jump: .init(host: "127.0.0.1", port: 2222, username: "testuser", auth: .password("testpass")))

        let fs = try await connectWithRetry {
            try await CitadelFileSystem.connect(
                config: config, connectTimeout: .seconds(30), knownHosts: store, onUnknownHostKey: .asking { _ in true })
        }
        await fs.disconnect()
        #expect(try store.find(host: "sshd2", port: 2222) != nil)

        // Tamper with the TARGET entry only — the jump entry stays valid.
        try store.upsert(KnownHostKey(
            host: "sshd2", port: 2222,
            keyType: "ssh-ed25519", publicKeyBase64: "QUJDREVG"))   // deliberately wrong

        do {
            _ = try await CitadelFileSystem.connect(
                config: config, connectTimeout: .seconds(30), knownHosts: store,
                onUnknownHostKey: .asking { _ in
                    Issue.record("decider must never be consulted on mismatch")
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

    // MARK: - M11a/T4: jump host referencing a saved session

    /// The M11a happy path proven at the rig level: a bastion session is
    /// SAVED (`SessionStore` + `SecretStore`, mirroring how the app persists
    /// it — see `SessionListViewModelTests.makeVM`), then referenced by
    /// `sessionID` from a `JumpSpec`. Feeding `LoginResolver.resolveJump`'s
    /// result into `SSHConnectionConfig.Jump` and actually connecting proves
    /// the resolution drives a real two-hop connect end to end — not just
    /// that it returns the right data in isolation (already covered by
    /// `LoginResolverTests.resolveJumpFromSessionUsesItsHostAndLogin`).
    @Test func jumpFromSavedSessionConnects() async throws {
        let sessionsDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-sessions-jump-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: sessionsDir) }
        let sessions = SessionStore(directory: sessionsDir)
        let secrets = InMemorySecretStore()

        let bastion = sshSession(
            name: "Bastion", host: "127.0.0.1", port: 2222, username: "testuser", authKind: .password)
        try secrets.savePassword("testpass", for: bastion.id)
        try sessions.upsert(bastion)

        let jumpSpec = StoredSession.JumpSpec(host: "unused", username: "unused", sessionID: bastion.id)
        let resolvedJump = try LoginResolver.resolveJump(
            spec: jumpSpec, sets: [], secrets: secrets,
            sessions: try sessions.all(), referencingSessionID: nil)

        let config = try SSHConnectionConfig(
            host: "sshd2", port: 2222, username: "testuser", auth: .password("testpass"),
            jump: .init(
                host: resolvedJump.host, port: resolvedJump.port,
                username: resolvedJump.login.username,
                auth: .password(resolvedJump.login.secret ?? "")))

        let khDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-kh-session-jump-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: khDir) }
        let store = KnownHostsStore(directory: khDir)

        let fs = try await connectWithRetry {
            try await CitadelFileSystem.connect(
                config: config, connectTimeout: .seconds(30), knownHosts: store, onUnknownHostKey: .asking { _ in true })
        }
        let items = try await fs.list(path: "/")
        #expect(!items.isEmpty)
        await fs.disconnect()
    }

    // MARK: - M10d/T2: ssh-agent authentication (RISK)

    private struct SpawnedAgent {
        let socketPath: String
        let pid: Int32
    }

    private struct AgentSpawnError: Error {
        let detail: String
    }

    private struct AskPassHelperError: Error {
        let detail: String
    }

    /// Starts a BRAND-NEW `ssh-agent -s` process this test owns exclusively
    /// (parsed from its own stdout) — never the maintainer's real agent.
    /// Killed in the caller's `defer`.
    private func spawnAgent() throws -> SpawnedAgent {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-agent")
        process.arguments = ["-s"]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw AgentSpawnError(detail: "ssh-agent -s exited \(process.terminationStatus)")
        }
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        func value(named name: String) -> String? {
            for line in output.split(separator: "\n") where line.hasPrefix("\(name)=") {
                return String(line.dropFirst(name.count + 1).prefix { $0 != ";" })
            }
            return nil
        }
        guard let socketPath = value(named: "SSH_AUTH_SOCK"),
              let pidString = value(named: "SSH_AGENT_PID"), let pid = Int32(pidString)
        else {
            throw AgentSpawnError(detail: "could not parse ssh-agent -s output: \(output)")
        }
        return SpawnedAgent(socketPath: socketPath, pid: pid)
    }

    /// Terminates the spawned agent process (teardown — never touches the
    /// user's own agent, only the PID this test itself started).
    private func killAgent(_ agent: SpawnedAgent) {
        let kill = Process()
        kill.executableURL = URL(fileURLWithPath: "/bin/kill")
        kill.arguments = ["-TERM", String(agent.pid)]
        try? kill.run()
        kill.waitUntilExit()
        // ssh-agent removes its own socket on a TERM it receives while still
        // alive, so this is a no-op on the common path. It matters when TERM
        // never reached a live agent (the test process died first, or the
        // agent was killed hard) and the socket file is left behind in the
        // shared ~/.ssh/agent/ — remove the FILE only, never the directory,
        // which belongs to every agent on the machine.
        try? FileManager.default.removeItem(atPath: agent.socketPath)
    }

    /// Adds a key to the spawned agent. For an encrypted key, `passphrase` is
    /// handed to ssh-add through an SSH_ASKPASS helper the test writes into
    /// `dir` and removes — never through argv, never through stdin of the test
    /// process. The passphrase is never interpolated into shell syntax: it is
    /// written raw to a 0600 secret file, and the 0700 helper script just
    /// `cat`s that file, so a passphrase containing a quote or any other
    /// shell metacharacter cannot break or inject into the script. Each file
    /// is created with its final permissions in one `createFile` call — never
    /// written world/group-readable and then chmod'd — so there is no window
    /// where the plaintext passphrase sits at default permissions. `defer`
    /// removal is armed (`secretFile`/`helperScript` assigned) BEFORE each
    /// `createFile` call, so even a `createFile` that reports failure still
    /// gets any partially-written file cleaned up; `removeItem` on a path
    /// that was never created is a harmless `try?`.
    private func addKey(atPath keyPath: String, to agent: SpawnedAgent,
                        passphrase: String? = nil, helperDirectory: URL? = nil) throws {
        let add = Process()
        add.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-add")
        add.arguments = [keyPath]
        var environment = [
            "SSH_AUTH_SOCK": agent.socketPath,
            "PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin",
        ]
        var helperScript: URL?
        var secretFile: URL?
        defer {
            if let helperScript { try? FileManager.default.removeItem(at: helperScript) }
            if let secretFile { try? FileManager.default.removeItem(at: secretFile) }
        }
        if let passphrase, let helperDirectory {
            let secret = helperDirectory.appendingPathComponent("askpass-secret")
            secretFile = secret
            let secretCreated = FileManager.default.createFile(
                atPath: secret.path(percentEncoded: false), contents: Data(passphrase.utf8),
                attributes: [.posixPermissions: 0o600])
            #expect(secretCreated)
            guard secretCreated else {
                throw AskPassHelperError(detail: "could not create askpass secret file at \(secret.path(percentEncoded: false))")
            }

            let script = helperDirectory.appendingPathComponent("askpass.sh")
            helperScript = script
            let scriptContents = "#!/bin/sh\ncat \"\(secret.path(percentEncoded: false))\"\n"
            let scriptCreated = FileManager.default.createFile(
                atPath: script.path(percentEncoded: false), contents: Data(scriptContents.utf8),
                attributes: [.posixPermissions: 0o700])
            #expect(scriptCreated)
            guard scriptCreated else {
                throw AskPassHelperError(detail: "could not create askpass script at \(script.path(percentEncoded: false))")
            }

            environment["SSH_ASKPASS"] = script.path(percentEncoded: false)
            environment["SSH_ASKPASS_REQUIRE"] = "force"
            environment["DISPLAY"] = ":0"
        }
        add.environment = environment
        try add.run()
        add.waitUntilExit()
        #expect(add.terminationStatus == 0)
    }

    /// Points THIS test process's `SSH_AUTH_SOCK` at `agent` for the
    /// duration of `body`, restoring whatever was there before. `.agent`
    /// auth reads `SSH_AUTH_SOCK` from the process environment exactly
    /// once per `connect()` (see `CitadelFileSystem.AgentAuthContext`), so
    /// this is how the gated tests make macSCP talk to their own spawned
    /// agent instead of the maintainer's.
    ///
    /// `AgentEnvLock` (M11e/T2, see its doc comment) serializes this against
    /// `AgentAuthTests`, which mutates the same process-global
    /// `SSH_AUTH_SOCK` from a DIFFERENT suite — this suite's own
    /// `.serialized` only protects against interleaving within itself.
    @discardableResult
    private func withAgentEnv<T>(
        _ agent: SpawnedAgent, _ body: () async throws -> T
    ) async rethrows -> T {
        try await AgentEnvLock.shared.run {
            let original = ProcessInfo.processInfo.environment["SSH_AUTH_SOCK"]
            setenv("SSH_AUTH_SOCK", agent.socketPath, 1)
            defer {
                if let original {
                    setenv("SSH_AUTH_SOCK", original, 1)
                } else {
                    unsetenv("SSH_AUTH_SOCK")
                }
            }
            return try await body()
        }
    }

    /// `.agent` connects with an ed25519 identity: the agent holds the ONE
    /// key installed in `authorized_keys`, `connect()` lists it once and
    /// offers it, and `list("/data/seed")` proves the SSH+SFTP session is
    /// actually usable afterward.
    @Test func agentAuthConnectsEd25519() async throws {
        let (dir, keyPath) = try makeInstalledKey(type: "ed25519")
        defer { try? FileManager.default.removeItem(at: dir) }
        let agent = try spawnAgent()
        defer { killAgent(agent) }
        try addKey(atPath: keyPath, to: agent)

        let config = try SSHConnectionConfig(
            host: "127.0.0.1", port: 2222, username: "testuser", auth: .agent)
        let khDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-kh-agent-ed25519-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: khDir) }
        let store = KnownHostsStore(directory: khDir)
        let fs = try await withAgentEnv(agent) {
            try await connectWithRetry {
                try await CitadelFileSystem.connect(
                    config: config, connectTimeout: .seconds(30), knownHosts: store, onUnknownHostKey: .asking { _ in true })
            }
        }
        defer { Task { await fs.disconnect() } }

        let items = try await fs.list(path: "/data/seed")
        #expect(items.contains { $0.name == "hello.txt" })
    }

    /// THE RSA RISK test: an `ssh-rsa`-blob identity must authenticate via
    /// `rsa-sha2-512` against a REAL OpenSSH `sshd` — the only way to prove
    /// the algorithm-name/blob-tag shape `AgentAlgorithm.RSASha512` settles
    /// for (see that type's doc comment) is actually accepted end to end.
    @Test func agentAuthConnectsRSA() async throws {
        let (dir, keyPath) = try makeInstalledKey(type: "rsa", bits: 2048)
        defer { try? FileManager.default.removeItem(at: dir) }
        let agent = try spawnAgent()
        defer { killAgent(agent) }
        try addKey(atPath: keyPath, to: agent)

        let config = try SSHConnectionConfig(
            host: "127.0.0.1", port: 2222, username: "testuser", auth: .agent)
        let khDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-kh-agent-rsa-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: khDir) }
        let store = KnownHostsStore(directory: khDir)
        let fs = try await withAgentEnv(agent) {
            try await connectWithRetry {
                try await CitadelFileSystem.connect(
                    config: config, connectTimeout: .seconds(30), knownHosts: store, onUnknownHostKey: .asking { _ in true })
            }
        }
        defer { Task { await fs.disconnect() } }

        let items = try await fs.list(path: "/data/seed")
        #expect(items.contains { $0.name == "hello.txt" })
    }

    /// An agent holding a key that is NOT in `authorized_keys` must fail
    /// bounded with `RemoteFSError.authenticationFailed` — no hang, and the
    /// SAME typed error target-side password auth already produces.
    @Test func agentAuthWrongKeyFailsAuth() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-itest-agentkey-wrong-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let keyURL = dir.appendingPathComponent("id_ed25519")
        let keygen = Process()
        keygen.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        keygen.arguments = ["-t", "ed25519", "-f", keyURL.path(percentEncoded: false),
                            "-N", "", "-q", "-C", "macscp-itest-wrong"]
        try keygen.run()
        keygen.waitUntilExit()
        #expect(keygen.terminationStatus == 0)

        let agent = try spawnAgent()
        defer { killAgent(agent) }
        try addKey(atPath: keyURL.path(percentEncoded: false), to: agent)

        let config = try SSHConnectionConfig(
            host: "127.0.0.1", port: 2222, username: "testuser", auth: .agent)
        let khDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-kh-agent-wrong-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: khDir) }
        let store = KnownHostsStore(directory: khDir)
        await withAgentEnv(agent) {
            await #expect(throws: RemoteFSError.authenticationFailed) {
                _ = try await CitadelFileSystem.connect(
                    config: config, connectTimeout: .seconds(30), knownHosts: store, onUnknownHostKey: .asking { _ in true })
            }
        }
    }

    /// I-3(a): the agent holds TWO ed25519 identities and only the SECOND
    /// one is installed in `authorized_keys`. Proves the per-identity
    /// reconnect loop (`CitadelFileSystem.connectHop`) actually ADVANCES
    /// past a rejected identity to try the next one, rather than stopping
    /// (or looping) on the first — a cursor off-by-one in
    /// `AgentAuthDelegate.remaining` or in the M-3 attempt cap would show up
    /// here as a hang, a wrong-error failure, or an early
    /// `allAuthenticationOptionsFailed` despite a usable identity still
    /// being available.
    @Test func agentAuthSecondIdentitySucceeds() async throws {
        // First identity: generated but deliberately never installed.
        let firstDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-itest-agentkey-not-installed-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: firstDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: firstDir) }
        let firstKeyURL = firstDir.appendingPathComponent("id_ed25519")
        let keygen = Process()
        keygen.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        keygen.arguments = ["-t", "ed25519", "-f", firstKeyURL.path(percentEncoded: false),
                            "-N", "", "-q", "-C", "macscp-itest-not-installed"]
        try keygen.run()
        keygen.waitUntilExit()
        #expect(keygen.terminationStatus == 0)

        // Second identity: installed in authorized_keys via the shared helper.
        let (secondDir, secondKeyPath) = try makeInstalledKey(type: "ed25519")
        defer { try? FileManager.default.removeItem(at: secondDir) }

        let agent = try spawnAgent()
        defer { killAgent(agent) }
        try addKey(atPath: firstKeyURL.path(percentEncoded: false), to: agent)
        try addKey(atPath: secondKeyPath, to: agent)

        let config = try SSHConnectionConfig(
            host: "127.0.0.1", port: 2222, username: "testuser", auth: .agent)
        let khDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-kh-agent-second-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: khDir) }
        let store = KnownHostsStore(directory: khDir)
        let fs = try await withAgentEnv(agent) {
            try await connectWithRetry {
                try await CitadelFileSystem.connect(
                    config: config, connectTimeout: .seconds(30), knownHosts: store, onUnknownHostKey: .asking { _ in true })
            }
        }
        defer { Task { await fs.disconnect() } }

        let items = try await fs.list(path: "/data/seed")
        #expect(items.contains { $0.name == "hello.txt" })
    }

    /// I-3(b): `.agent` on the JUMP hop, not just the target. The jump
    /// (container 1, 127.0.0.1:2222) authenticates via a freshly spawned
    /// agent holding a key installed in container 1's `authorized_keys`; the
    /// target (sshd2:2222, reachable only THROUGH the jump) authenticates
    /// with plain password auth. Proves `connectHop`'s per-identity
    /// reconnect loop works correctly when it is the JUMP hop's attempts
    /// being retried (not just the already-covered target hop).
    @Test func agentAuthOnJumpHop() async throws {
        let (dir, keyPath) = try makeInstalledKey(type: "ed25519")
        defer { try? FileManager.default.removeItem(at: dir) }
        let agent = try spawnAgent()
        defer { killAgent(agent) }
        try addKey(atPath: keyPath, to: agent)

        let config = try SSHConnectionConfig(
            host: "sshd2", port: 2222, username: "testuser", auth: .password("testpass"),
            jump: .init(host: "127.0.0.1", port: 2222, username: "testuser", auth: .agent))
        let khDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-kh-agent-jump-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: khDir) }
        let store = KnownHostsStore(directory: khDir)
        let fs = try await withAgentEnv(agent) {
            try await connectWithRetry {
                try await CitadelFileSystem.connect(
                    config: config, connectTimeout: .seconds(30), knownHosts: store, onUnknownHostKey: .asking { _ in true })
            }
        }
        defer { Task { await fs.disconnect() } }

        let items = try await fs.list(path: "/")
        #expect(!items.isEmpty)
    }

    /// R-8: the jump-hop counterpart to `agentAuthWrongKeyFailsAuth` — an
    /// agent whose ONLY identity is NOT in container 1's `authorized_keys`,
    /// used for the JUMP hop's `.agent` auth (target still plain password).
    /// Must surface as `RemoteFSError.jumpAuthenticationFailed`, not
    /// `.authenticationFailed` (that's reserved for the target hop) and not
    /// `.connectionFailed` (a stringified fallback would mean the jump-stage
    /// error mapping silently failed to recognize the rejection) — the
    /// combination of `.agent` + full rejection + jump hop had no coverage
    /// before this test.
    @Test func agentAuthOnJumpHopWrongKeyFailsJumpAuth() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-itest-agentkey-jump-wrong-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let keyURL = dir.appendingPathComponent("id_ed25519")
        let keygen = Process()
        keygen.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        keygen.arguments = ["-t", "ed25519", "-f", keyURL.path(percentEncoded: false),
                            "-N", "", "-q", "-C", "macscp-itest-jump-wrong"]
        try keygen.run()
        keygen.waitUntilExit()
        #expect(keygen.terminationStatus == 0)

        let agent = try spawnAgent()
        defer { killAgent(agent) }
        try addKey(atPath: keyURL.path(percentEncoded: false), to: agent)

        let config = try SSHConnectionConfig(
            host: "sshd2", port: 2222, username: "testuser", auth: .password("testpass"),
            jump: .init(host: "127.0.0.1", port: 2222, username: "testuser", auth: .agent))
        let khDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-kh-agent-jump-wrong-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: khDir) }
        let store = KnownHostsStore(directory: khDir)
        await withAgentEnv(agent) {
            await #expect(throws: RemoteFSError.jumpAuthenticationFailed) {
                _ = try await CitadelFileSystem.connect(
                    config: config, connectTimeout: .seconds(30), knownHosts: store, onUnknownHostKey: .asking { _ in true })
            }
        }
    }

    /// I-3(c): an ECDSA (P-256) identity through the agent, mirroring
    /// `agentAuthConnectsEd25519`/`agentAuthConnectsRSA` — the third
    /// `AgentSigningAlgorithm` family macSCP offers (`AgentAlgorithm.ECDSAP256`)
    /// had no live-server coverage before this test.
    @Test func agentAuthConnectsECDSA() async throws {
        let (dir, keyPath) = try makeInstalledKey(type: "ecdsa", bits: 256)
        defer { try? FileManager.default.removeItem(at: dir) }
        let agent = try spawnAgent()
        defer { killAgent(agent) }
        try addKey(atPath: keyPath, to: agent)

        let config = try SSHConnectionConfig(
            host: "127.0.0.1", port: 2222, username: "testuser", auth: .agent)
        let khDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-kh-agent-ecdsa-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: khDir) }
        let store = KnownHostsStore(directory: khDir)
        let fs = try await withAgentEnv(agent) {
            try await connectWithRetry {
                try await CitadelFileSystem.connect(
                    config: config, connectTimeout: .seconds(30), knownHosts: store, onUnknownHostKey: .asking { _ in true })
            }
        }
        defer { Task { await fs.disconnect() } }

        let items = try await fs.list(path: "/data/seed")
        #expect(items.contains { $0.name == "hello.txt" })
    }

    /// T4/Step 1: an ECDSA P-384 identity through the agent, mirroring
    /// `agentAuthConnectsECDSA` (P-256) — the backlog entry's table claimed
    /// all three NIST curves connect through the agent, measured only by a
    /// throwaway script, not by a test in the tree.
    @Test func agentAuthConnectsECDSAP384() async throws {
        let (dir, keyPath) = try makeInstalledKey(type: "ecdsa", bits: 384)
        defer { try? FileManager.default.removeItem(at: dir) }
        let agent = try spawnAgent()
        defer { killAgent(agent) }
        try addKey(atPath: keyPath, to: agent)

        let config = try SSHConnectionConfig(
            host: "127.0.0.1", port: 2222, username: "testuser", auth: .agent)
        let khDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-kh-agent-ecdsa-p384-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: khDir) }
        let store = KnownHostsStore(directory: khDir)
        let fs = try await withAgentEnv(agent) {
            try await connectWithRetry {
                try await CitadelFileSystem.connect(
                    config: config, connectTimeout: .seconds(30), knownHosts: store, onUnknownHostKey: .asking { _ in true })
            }
        }
        defer { Task { await fs.disconnect() } }

        let items = try await fs.list(path: "/data/seed")
        #expect(items.contains { $0.name == "hello.txt" })
    }

    /// T4/Step 1: an ECDSA P-521 identity through the agent, mirroring
    /// `agentAuthConnectsECDSA` (P-256) — see `agentAuthConnectsECDSAP384`.
    @Test func agentAuthConnectsECDSAP521() async throws {
        let (dir, keyPath) = try makeInstalledKey(type: "ecdsa", bits: 521)
        defer { try? FileManager.default.removeItem(at: dir) }
        let agent = try spawnAgent()
        defer { killAgent(agent) }
        try addKey(atPath: keyPath, to: agent)

        let config = try SSHConnectionConfig(
            host: "127.0.0.1", port: 2222, username: "testuser", auth: .agent)
        let khDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-kh-agent-ecdsa-p521-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: khDir) }
        let store = KnownHostsStore(directory: khDir)
        let fs = try await withAgentEnv(agent) {
            try await connectWithRetry {
                try await CitadelFileSystem.connect(
                    config: config, connectTimeout: .seconds(30), knownHosts: store, onUnknownHostKey: .asking { _ in true })
            }
        }
        defer { Task { await fs.disconnect() } }

        let items = try await fs.list(path: "/data/seed")
        #expect(items.contains { $0.name == "hello.txt" })
    }

    /// T4/Steps 2-3: a passphrase-protected ed25519 identity, added to the
    /// agent through an `SSH_ASKPASS` helper. This is the route ~90% of
    /// this project's users are actually in — the backlog entry marked it
    /// as a conclusion from how ssh-agent works, not a measurement, and
    /// this test is that measurement. `testPassphrase` has no security
    /// value (a runtime-generated throwaway key, deleted after the test)
    /// but is still kept out of any `#expect` literal, since `#expect`
    /// prints the source text of the expression it checks on failure.
    @Test func agentAuthConnectsWithPassphraseProtectedKey() async throws {
        let testPassphrase = "macscp-itest-passphrase"
        let (dir, keyPath) = try makeInstalledKey(type: "ed25519", passphrase: testPassphrase)
        defer { try? FileManager.default.removeItem(at: dir) }
        let agent = try spawnAgent()
        defer { killAgent(agent) }
        try addKey(atPath: keyPath, to: agent, passphrase: testPassphrase, helperDirectory: dir)

        let config = try SSHConnectionConfig(
            host: "127.0.0.1", port: 2222, username: "testuser", auth: .agent)
        let khDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-kh-agent-passphrase-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: khDir) }
        let store = KnownHostsStore(directory: khDir)
        let fs = try await withAgentEnv(agent) {
            try await connectWithRetry {
                try await CitadelFileSystem.connect(
                    config: config, connectTimeout: .seconds(30), knownHosts: store, onUnknownHostKey: .asking { _ in true })
            }
        }
        defer { Task { await fs.disconnect() } }

        let items = try await fs.list(path: "/data/seed")
        #expect(items.contains { $0.name == "hello.txt" })
    }

    // MARK: - M11g/T1: navigate(to:) + PathCompletion (real rig)

    /// `RemoteBrowserViewModel.navigate(to:)` against the real rig: jump
    /// into a nested seeded directory and back to `/` — proves the
    /// stat-based directory/file/not-found branching and the
    /// currentPath/load() wiring actually work against a REAL SFTP server,
    /// not just `MockRemoteFileSystem`.
    @MainActor
    @Test func navigateJumpsIntoNestedDirectoryAndBackToRoot() async throws {
        let fs = try await connect()
        defer { Task { await fs.disconnect() } }
        let vm = RemoteBrowserViewModel(fs: fs)
        await vm.load()

        let downError = await vm.navigate(to: "/data/seed/sub")
        #expect(downError == nil)
        #expect(vm.currentPath == "/data/seed/sub")

        let upError = await vm.navigate(to: "/")
        #expect(upError == nil)
        #expect(vm.currentPath == "/")
    }

    /// `PathCompletion.directoryToList` + a REAL `list()` + `PathCompletion.
    /// complete` must chain correctly end to end — the pure unit tests fake
    /// a listing, but only this proves the three pieces actually agree on
    /// directory shape against a real SFTP `list()` response.
    @Test func completionAgainstRealListingFindsSeededSubdirectory() async throws {
        let fs = try await connect()
        defer { Task { await fs.disconnect() } }

        let input = "/data/seed/su"
        let directory = PathCompletion.directoryToList(for: input)
        #expect(directory == "/data/seed")

        let entries = try await fs.list(path: directory)
        let result = PathCompletion.complete(input: input, entries: entries, caseSensitive: true)

        #expect(result.completedInput == "/data/seed/sub/")
        #expect(result.candidates == ["sub"])
    }

    // MARK: - B-2: a read stream must not outlive its server-side handle

    /// Seeds a file of `bytes` random bytes at `path` inside the container and
    /// hands it to the SFTP user. `docker exec` runs as root, so the chown is
    /// what makes the file readable over SFTP as testuser.
    private func seedRemoteFile(atPath path: String, bytes: Int) {
        let seed = Process()
        seed.executableURL = URL(fileURLWithPath: "/usr/local/bin/docker")
        seed.arguments = [
            "exec", "macscp-test-sshd", "sh", "-c",
            "head -c \(bytes) /dev/urandom > '\(path)' && chown 1000:1000 '\(path)'",
        ]
        seed.standardError = FileHandle.nullDevice
        try? seed.run()
        seed.waitUntilExit()
        #expect(seed.terminationStatus == 0)
    }

    /// How many descriptors the SERVER still holds on a file of that name,
    /// read out of `/proc` inside the container. This observes the sftp-server
    /// process, not any macSCP state, so it cannot be satisfied by a fix that
    /// merely looks like one: the count only drops when an SFTP CLOSE for that
    /// handle has actually reached the server.
    ///
    /// The same descriptor shows up under several `/proc` entries, so the
    /// number itself carries no meaning — only "some" versus "none" does.
    /// Callers compare against 0, never against an expected count.
    private func serverDescriptorCount(forFileNamed name: String) -> Int {
        let list = Process()
        list.executableURL = URL(fileURLWithPath: "/usr/local/bin/docker")
        list.arguments = [
            // `--privileged`: resolving another process's `/proc/<pid>/fd`
            // symlinks needs CAP_SYS_PTRACE, which a plain `docker exec` does
            // not carry — without it every link reads back "Permission
            // denied" and the count is silently always zero. The sftp-server
            // runs as testuser under the sshd session, so this is exactly the
            // case that needs it.
            "exec", "--privileged", "macscp-test-sshd", "sh", "-c",
            // `grep -c` exits non-zero when it counts nothing, so the exit
            // status carries no information here — stdout is the answer.
            "ls -l /proc/[0-9]*/fd 2>/dev/null | grep -c '\(name)'",
        ]
        let pipe = Pipe()
        list.standardOutput = pipe
        list.standardError = FileHandle.nullDevice
        guard (try? list.run()) != nil else { return -1 }
        let out = String(
            data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        list.waitUntilExit()
        return Int(out) ?? -1
    }

    /// Polls `serverDescriptorCount` until it reaches zero, bounded at roughly
    /// two seconds. The close travels to the server asynchronously once the
    /// stream is gone, so the assertion has to be "closes promptly", not
    /// "is closed by the time this line runs".
    private func waitForServerToCloseDescriptors(forFileNamed name: String) async -> Int {
        var remaining = serverDescriptorCount(forFileNamed: name)
        var polls = 0
        while remaining != 0 && polls < 40 {
            try? await Task.sleep(for: .milliseconds(50))
            remaining = serverDescriptorCount(forFileNamed: name)
            polls += 1
        }
        return remaining
    }

    /// The bare mechanism: a consumer that pulls one chunk and then simply
    /// stops. No cancellation, no EOF, no error — the closure of
    /// `AsyncThrowingStream(unfolding:)` is just released, and with it the
    /// only reference to the open `SFTPFile`.
    @Test func abandonedReadStreamClosesTheServerSideHandle() async throws {
        let fs = try await connect()
        defer { Task { await fs.disconnect() } }

        let name = "macscp-abandoned-read-\(UUID().uuidString).bin"
        let path = "/config/\(name)"
        seedRemoteFile(atPath: path, bytes: 4 * TransferChunk.size)
        defer { cleanupConfigPath(path) }

        // A nested frame so the stream and its iterator are released on
        // return rather than at the end of the test.
        func pullOneChunkThenAbandon() async throws {
            let stream = try await fs.readStream(path: path, fromOffset: 0)
            var iterator = stream.makeAsyncIterator()
            let first = try await iterator.next()
            #expect(first?.count == TransferChunk.size)
            // Measured while the stream is still alive: proves the probe
            // above really sees this handle, so a later zero means "closed"
            // and not "never looked in the right place".
            #expect(serverDescriptorCount(forFileNamed: name) > 0)
        }
        try await pullOneChunkThenAbandon()

        #expect(await waitForServerToCloseDescriptors(forFileNamed: name) == 0)
    }

    /// The path a user reaches by failing on the destination side:
    /// `TransferEngine.copyFile` opens the source stream, the destination
    /// write throws, and the source stream is dropped without anyone
    /// cancelling it.
    @Test func aFailingDestinationWriteClosesTheSourceHandle() async throws {
        let fs = try await connect()
        defer { Task { await fs.disconnect() } }

        let name = "macscp-failed-destination-\(UUID().uuidString).bin"
        let path = "/config/\(name)"
        seedRemoteFile(atPath: path, bytes: 4 * TransferChunk.size)
        defer { cleanupConfigPath(path) }

        // A directory that was never created: `LocalFileSystem.write` cannot
        // create the file there and throws before draining a single chunk.
        let missingDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-missing-\(UUID().uuidString)")
            .path(percentEncoded: false)

        await #expect(throws: (any Error).self) {
            try await TransferEngine.copyFile(
                from: fs, sourcePath: path,
                to: LocalFileSystem(), destinationDirectory: missingDirectory,
                fileName: name, onProgress: { _ in })
        }

        #expect(await waitForServerToCloseDescriptors(forFileNamed: name) == 0)
    }

    /// The path the bug report names: a download cancelled mid-flight. The
    /// counting stream in `copyFile` and the read stream underneath it both
    /// stop being pulled, so neither closure runs again.
    @Test func aCancelledDownloadClosesTheSourceHandle() async throws {
        let fs = try await connect()
        defer { Task { await fs.disconnect() } }

        let name = "macscp-cancelled-download-\(UUID().uuidString).bin"
        let path = "/config/\(name)"
        seedRemoteFile(atPath: path, bytes: 32 * 1024 * 1024)
        defer { cleanupConfigPath(path) }

        let destinationDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-cancelled-download-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: destinationDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: destinationDirectory) }

        let progressSeen = CallCounterBox()
        let task = Task {
            try await TransferEngine.copyFile(
                from: fs, sourcePath: path,
                to: LocalFileSystem(),
                destinationDirectory: destinationDirectory.path(percentEncoded: false),
                fileName: name, onProgress: { _ in progressSeen.increment() })
        }

        var polls = 0
        while progressSeen.value == 0 && polls < 500 {
            try await Task.sleep(for: .milliseconds(10))
            polls += 1
        }
        #expect(progressSeen.value > 0)
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }

        #expect(await waitForServerToCloseDescriptors(forFileNamed: name) == 0)
    }
}

/// M11a/T4 continued: the chain guard on a session-referenced jump must
/// fire from data alone (`resolveJump` never dials anything before it
/// throws — see `LoginResolver.resolveJump`). This deliberately lives
/// OUTSIDE `CitadelFileSystemIntegrationTests` rather than as a `@Test`
/// inside it: a suite-level `.enabled(if:)` trait disables every contained
/// test regardless of that test's own traits, so nesting it in the gated
/// suite above would silently skip it whenever MACSCP_ITEST != 1 — which
/// would misrepresent a guard that in fact needs no rig, no network, and no
/// Docker container at all.
@Suite("Jump-from-session chain guard (no rig required)")
struct JumpFromSavedSessionChainGuardTests {
    /// A bastion session that itself has a jump, referenced as a
    /// session-jump: `resolveJump` must refuse the chain (one hop only)
    /// before any connection is attempted — proven here by never calling
    /// `CitadelFileSystem.connect` at all.
    @Test func jumpFromSavedSessionRefusesChain() throws {
        let sessionsDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-sessions-jump-chain-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: sessionsDir) }
        let sessions = SessionStore(directory: sessionsDir)
        let secrets = InMemorySecretStore()

        let innerJump = StoredSession.JumpSpec(host: "inner", username: "inner")
        let bastion = sshSession(
            name: "Bastion", host: "127.0.0.1", port: 2222, username: "testuser",
            authKind: .password, jump: innerJump)
        try secrets.savePassword("testpass", for: bastion.id)
        try sessions.upsert(bastion)

        let jumpSpec = StoredSession.JumpSpec(host: "unused", username: "unused", sessionID: bastion.id)

        #expect(throws: LoginResolveError.jumpChainNotSupported) {
            _ = try LoginResolver.resolveJump(
                spec: jumpSpec, sets: [], secrets: secrets,
                sessions: try sessions.all(), referencingSessionID: nil)
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
