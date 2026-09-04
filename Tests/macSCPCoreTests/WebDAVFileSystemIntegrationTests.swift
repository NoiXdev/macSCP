import Foundation
import MacSCPTestSupport
import NIOCore
import Testing
@testable import macSCPCore

/// Runs only with MACSCP_ITEST=1 and a running Docker test rig
/// (docker compose -f docker/test-server/compose.yml up -d), which brings up
/// an Apache/mod_dav container (M21/Task 11) with three vhosts:
///   - Basic auth,  plain HTTP  -- http://127.0.0.1:18080/dav
///   - Digest auth, plain HTTP  -- http://127.0.0.1:18081/dav
///   - Basic auth,  TLS         -- https://127.0.0.1:18443/dav, a certificate
///     generated at container start (never committed, exactly like the SSH
///     test keys)
/// Same gating pattern as `S3FileSystemIntegrationTests`/
/// `CitadelFileSystemIntegrationTests`. Nothing in the unit suite talks to a
/// real WebDAV server -- every WebDAVFileSystem/WebDAVSessionDelegate test
/// elsewhere in the package drives a fake `HTTPTransport`. This file is what
/// actually proves the wire format, the Digest challenge round trip, TLS
/// TOFU against a real certificate, and cross-backend transfer against
/// another real server (SSH).
@Suite(
    "WebDAVFileSystem against Docker Apache",
    .enabled(if: ProcessInfo.processInfo.environment["MACSCP_ITEST"] == "1"),
    .serialized,
    .timeLimit(.minutes(1))
)
struct WebDAVFileSystemIntegrationTests {

    // MARK: - Connection helpers

    private func trustDirectory() -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-webdav-trust-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Connects against one of the rig's vhosts. `port` selects Basic
    /// (18080), Digest (18081, still plain `http://`) or TLS (18443, pass
    /// `scheme: "https"`) -- `URLSession` negotiates Basic vs. Digest itself
    /// from the server's challenge, so the same connect path exercises both.
    private func connect(
        port: Int, scheme: String = "http",
        trustStore: TrustedCertificateStore? = nil
    ) async throws -> WebDAVFileSystem {
        let config = WebDAVConnectionConfig(
            baseURL: "\(scheme)://127.0.0.1:\(port)/dav", username: "testuser",
            useNextcloudPath: false, password: "testpass")
        let store = trustStore ?? TrustedCertificateStore(directory: trustDirectory())
        return try await WebDAVFileSystem.connect(config, trustStore: store, decider: .asking { _ in true })
    }

    /// Cushions reconnect throttling of the test container, mirroring the
    /// shared `connectWithRetry` in `Support/IntegrationConnect.swift`
    /// verbatim (kept private under its own name because this suite also
    /// has a WebDAV connect helper beside it).
    private func connectSSHWithRetry(
        _ make: () async throws -> CitadelFileSystem
    ) async throws -> CitadelFileSystem {
        do {
            return try await make()
        } catch {
            try? await Task.sleep(for: .milliseconds(500))
            return try await make()
        }
    }

    private func connectSSH() async throws -> CitadelFileSystem {
        let config = try SSHConnectionConfig(
            host: "127.0.0.1", port: 2222, username: "testuser", auth: .password("testpass"))
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-webdav-kh-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = KnownHostsStore(directory: dir)
        return try await connectSSHWithRetry {
            try await CitadelFileSystem.connect(
                config: config, connectTimeout: .seconds(30), knownHosts: store, onUnknownHostKey: .asking { _ in true })
        }
    }

    /// Best-effort recursive removal of an SSH-side path via the test
    /// container's shell, mirroring `CrossBackendTransferIntegrationTests
    /// .cleanupSSHPath` verbatim.
    private func cleanupSSHPath(_ path: String, container: String = "macscp-test-sshd") async {
        _ = try? await SubprocessRunner.run(
            URL(fileURLWithPath: "/usr/local/bin/docker"),
            arguments: ["exec", container, "rm", "-rf", path])
    }

    // MARK: - Stream helpers

    private func writeOnce(_ fs: any RemoteFileSystem, path: String, content: Data) async throws {
        let (stream, continuation) = AsyncThrowingStream<Data, Error>.makeStream()
        continuation.yield(content)
        continuation.finish()
        try await fs.write(path: path, contents: stream)
    }

    private func drain(_ stream: AsyncThrowingStream<Data, Error>) async throws -> Data {
        var result = Data()
        for try await chunk in stream { result.append(chunk) }
        return result
    }

    /// Deterministic pseudo-random bytes (a simple LCG), mirroring
    /// `S3FileSystemIntegrationTests`'s multipart-threshold fixture -- large
    /// enough to force several `TransferChunk.size` (64 KiB) round trips
    /// through `BoundStreamWriter` while staying reproducible.
    private func pseudoRandomBytes(count: Int) -> Data {
        var state: UInt64 = 0x1234_5678_9abc_def0
        var body = Data(capacity: count)
        for _ in 0..<count {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            body.append(UInt8((state >> 33) & 0xFF))
        }
        return body
    }

    // MARK: - Full CRUD round trip over Basic

    @Test func fullCRUDRoundTripOverBasic() async throws {
        let fs = try await connect(port: 18080)
        defer { Task { await fs.disconnect() } }
        let dir = "/m21-crud-basic-\(UUID().uuidString)"
        let originalName = "note.txt"
        let renamedName = "renamed.txt"
        // Space, `&`, and `#` in one name: `&` survives `WebDAVURL.encode`
        // unescaped (it is a sub-delim, not a segment separator), while the
        // space and `#` must be percent-encoded or the request breaks (a
        // literal space in a URL) or silently truncates (`#` starts a
        // fragment). `WebDAVURL` exists specifically because this is where
        // silent bugs live; nothing before this test pinned it against a
        // real server.
        let percentEncodedName = "a b & c#1.txt"
        let subDirName = "sub"
        let renamedSubDirName = "sub-renamed"
        let body = Data("round trip over basic auth".utf8)

        var caught: Error?
        do {
            try await fs.createDirectory(at: dir)
            try await writeOnce(fs, path: "\(dir)/\(originalName)", content: body)

            let listed = try await fs.list(path: dir)
            #expect(listed.contains { $0.name == originalName && $0.kind == .file })

            let stat = try await fs.stat(path: "\(dir)/\(originalName)")
            #expect(stat.kind == .file)
            #expect(stat.size == UInt64(body.count))

            let readBack = try await drain(try await fs.readStream(path: "\(dir)/\(originalName)"))
            #expect(readBack == body)

            try await writeOnce(fs, path: "\(dir)/\(percentEncodedName)", content: body)
            let percentEncodedReadBack = try await drain(
                try await fs.readStream(path: "\(dir)/\(percentEncodedName)"))
            #expect(percentEncodedReadBack == body)

            try await fs.rename(from: "\(dir)/\(originalName)", to: "\(dir)/\(renamedName)")
            let afterRename = try await fs.list(path: dir)
            #expect(!afterRename.contains { $0.name == originalName })
            #expect(afterRename.contains { $0.name == renamedName })

            // Directory rename: `RemoteBrowserViewModel` passes a folder's
            // `item.path` through `rename` the same as a file's, and
            // `WebDAVFileSystem.rename` addresses BOTH endpoints with
            // `isDirectory: false` -- this is where that shape actually
            // meets a real server rather than a stubbed transport.
            try await fs.createDirectory(at: "\(dir)/\(subDirName)")
            try await fs.rename(
                from: "\(dir)/\(subDirName)", to: "\(dir)/\(renamedSubDirName)")
            let afterSubRename = try await fs.list(path: dir)
            #expect(!afterSubRename.contains { $0.name == subDirName })
            #expect(afterSubRename.contains {
                $0.name == renamedSubDirName && $0.kind == .directory
            })

            // `stat` on an existing directory: the path-bar navigation and
            // `macscp rm` (without `--recursive`) both do this before
            // acting on the result.
            let subStat = try await fs.stat(path: "\(dir)/\(renamedSubDirName)")
            #expect(subStat.kind == .directory)

            // `delete` (not `deleteTree`) on an empty collection: what
            // `macscp rm` sends without `--recursive`.
            try await fs.delete(path: "\(dir)/\(renamedSubDirName)")
            let afterSubDelete = try await fs.list(path: dir)
            #expect(!afterSubDelete.contains { $0.name == renamedSubDirName })

            try await fs.delete(path: "\(dir)/\(renamedName)")
            try await fs.delete(path: "\(dir)/\(percentEncodedName)")
            let afterDelete = try await fs.list(path: dir)
            #expect(afterDelete.isEmpty)
        } catch {
            caught = error
        }
        try? await fs.deleteTree(at: dir)
        if let caught { throw caught }
    }

    // MARK: - Full CRUD round trip over Digest

    /// Same shape as the Basic test above, against the Digest vhost --
    /// proves `URLSession` actually answered the server's Digest challenge
    /// (nonce, qop, nonce count) rather than just carrying a `WWW-Authenticate:
    /// Basic` credential that happened to also satisfy Apache.
    @Test func fullCRUDRoundTripOverDigest() async throws {
        let fs = try await connect(port: 18081)
        defer { Task { await fs.disconnect() } }
        let dir = "/m21-crud-digest-\(UUID().uuidString)"
        let originalName = "note.txt"
        let renamedName = "renamed.txt"
        let body = Data("round trip over digest auth".utf8)

        var caught: Error?
        do {
            try await fs.createDirectory(at: dir)
            try await writeOnce(fs, path: "\(dir)/\(originalName)", content: body)

            let listed = try await fs.list(path: dir)
            #expect(listed.contains { $0.name == originalName && $0.kind == .file })

            let readBack = try await drain(try await fs.readStream(path: "\(dir)/\(originalName)"))
            #expect(readBack == body)

            try await fs.rename(from: "\(dir)/\(originalName)", to: "\(dir)/\(renamedName)")
            let afterRename = try await fs.list(path: dir)
            #expect(afterRename.contains { $0.name == renamedName })

            try await fs.delete(path: "\(dir)/\(renamedName)")
        } catch {
            caught = error
        }
        try? await fs.deleteTree(at: dir)
        if let caught { throw caught }
    }

    // MARK: - Rename onto an occupied destination

    /// `rename` sends `Overwrite: F`; a server honoring that answers 412,
    /// which `WebDAVFileSystem.mapStatus` turns into `.protocolError`. The
    /// unit tests (`WebDAVFileSystemTests`) prove the header is SENT; only a
    /// real server proves it is actually HONORED and the destination's
    /// content survives untouched.
    @Test func renameOntoOccupiedDestinationThrowsRatherThanReplacing() async throws {
        let fs = try await connect(port: 18080)
        defer { Task { await fs.disconnect() } }
        let dir = "/m21-rename-collision-\(UUID().uuidString)"
        let sourceName = "source.txt"
        let destinationName = "destination.txt"
        let sourceBody = Data("source content".utf8)
        let destinationBody = Data("destination content -- must survive".utf8)

        var caught: Error?
        do {
            try await fs.createDirectory(at: dir)
            try await writeOnce(fs, path: "\(dir)/\(sourceName)", content: sourceBody)
            try await writeOnce(fs, path: "\(dir)/\(destinationName)", content: destinationBody)

            await #expect(throws: RemoteFSError.self) {
                try await fs.rename(from: "\(dir)/\(sourceName)", to: "\(dir)/\(destinationName)")
            }

            // Both files must still be exactly as they were -- no replace,
            // no partial move.
            let sourceReadBack = try await drain(try await fs.readStream(path: "\(dir)/\(sourceName)"))
            #expect(sourceReadBack == sourceBody)
            let destinationReadBack = try await drain(
                try await fs.readStream(path: "\(dir)/\(destinationName)"))
            #expect(destinationReadBack == destinationBody)
        } catch {
            caught = error
        }
        try? await fs.deleteTree(at: dir)
        if let caught { throw caught }
    }

    // MARK: - deleteTree on a plain file

    /// `RemoteFileSystem.deleteTree`'s contract says a plain file behaves
    /// exactly like `delete`. Apache answers 400 to a DELETE whose path
    /// carries a trailing slash but names a file, so only a real server
    /// proves the shape: a stubbed transport accepts either URL.
    @Test func deleteTreeRemovesAPlainFile() async throws {
        let fs = try await connect(port: 18080)
        defer { Task { await fs.disconnect() } }
        let path = "/m21-deletetree-file-\(UUID().uuidString).txt"

        var caught: Error?
        do {
            try await writeOnce(fs, path: path, content: Data("delete me".utf8))
            #expect(try await fs.stat(path: path).kind == .file)

            try await fs.deleteTree(at: path)

            do {
                _ = try await fs.stat(path: path)
                Issue.record("expected the file to be gone after deleteTree")
            } catch let error as RemoteFSError {
                guard case .notFound = error else {
                    Issue.record("expected .notFound, got \(error)")
                    return
                }
            }
        } catch {
            caught = error
        }
        try? await fs.delete(path: path)
        if let caught { throw caught }
    }

    // MARK: - deleteTree on a populated collection

    /// One DELETE for the whole subtree (after the lookup that picks the URL
    /// shape) — the headline difference from the S3 backend, which needs a
    /// recursive listing and batched DeleteObjects.
    @Test func deleteTreeRemovesAPopulatedCollection() async throws {
        let fs = try await connect(port: 18080)
        defer { Task { await fs.disconnect() } }
        let dir = "/m21-deletetree-\(UUID().uuidString)"

        var caught: Error?
        do {
            try await fs.createDirectory(at: dir)
            try await writeOnce(fs, path: "\(dir)/top.txt", content: Data("top".utf8))
            try await fs.createDirectory(at: "\(dir)/sub")
            try await writeOnce(fs, path: "\(dir)/sub/nested.txt", content: Data("nested".utf8))

            try await fs.deleteTree(at: dir)

            do {
                _ = try await fs.stat(path: dir)
                Issue.record("expected the whole tree to be gone after deleteTree")
            } catch let error as RemoteFSError {
                guard case .notFound = error else {
                    Issue.record("expected .notFound, got \(error)")
                    return
                }
            }
        } catch {
            caught = error
        }
        try? await fs.deleteTree(at: dir)
        if let caught { throw caught }
    }

    // MARK: - Resume: read from an offset

    @Test func readStreamFromOffsetReturnsExactlyTheTail() async throws {
        let fs = try await connect(port: 18080)
        defer { Task { await fs.disconnect() } }
        let path = "/m21-resume-\(UUID().uuidString).bin"
        let body = pseudoRandomBytes(count: 200 * 1024)
        let offset = 123_457

        var caught: Error?
        do {
            try await writeOnce(fs, path: path, content: body)

            let tail = try await drain(try await fs.readStream(path: path, fromOffset: UInt64(offset)))
            #expect(tail == body.suffix(from: offset))
        } catch {
            caught = error
        }
        try? await fs.delete(path: path)
        if let caught { throw caught }
    }

    // MARK: - Large upload under load

    /// A 16 MB upload from a generated stream round-trips byte-identically
    /// -- the guard that the bound-stream PUT (`BoundStreamWriter` pumping a
    /// `Stream.getBoundStreams` pair) really works under sustained load, not
    /// just for the few-KB bodies every other test here uses.
    @Test func largeUploadRoundTripsByteIdentically() async throws {
        let fs = try await connect(port: 18080)
        defer { Task { await fs.disconnect() } }
        let path = "/m21-large-\(UUID().uuidString).bin"
        let size = 16 * 1024 * 1024
        let body = pseudoRandomBytes(count: size)

        var caught: Error?
        do {
            let uploadStream = AsyncThrowingStream<Data, Error> { continuation in
                let chunkSize = 256 * 1024
                var offset = 0
                while offset < body.count {
                    let end = min(offset + chunkSize, body.count)
                    continuation.yield(body.subdata(in: offset..<end))
                    offset = end
                }
                continuation.finish()
            }
            try await fs.write(path: path, mode: .overwrite, contents: uploadStream)

            let readBack = try await drain(try await fs.readStream(path: path))
            #expect(readBack == body)
        } catch {
            caught = error
        }
        try? await fs.delete(path: path)
        if let caught { throw caught }
    }

    // MARK: - TOFU against the TLS vhost

    /// Tracks whether the decider was consulted, without a lock: the decider
    /// closure is `@Sendable async`, so an actor is the natural fit.
    private actor AskedFlag {
        private var asked = false
        func markAsked() { asked = true }
        var wasAsked: Bool { asked }
    }

    /// First connect against the TLS vhost: the certificate is unknown, so
    /// the decider is asked and (on consent) the fingerprint is remembered.
    /// Then the stored fingerprint is tampered with in place -- simulating a
    /// server whose certificate changed since it was trusted -- and a second
    /// connect must fail with `.mismatch` WITHOUT the decider being consulted
    /// again. Mirrors `WebDAVSessionDelegateTests.mismatchRefusesWithoutAsk
    /// ingTheDecider`, but against a REAL TLS handshake and a REAL generated
    /// certificate rather than a synthetic `ServerCertificateCandidate`.
    @Test func tofuAgainstTLSAsksOnceThenMismatchNeverConsultsDecider() async throws {
        let directory = trustDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = TrustedCertificateStore(directory: directory)
        let config = WebDAVConnectionConfig(
            baseURL: "https://127.0.0.1:18443/dav", username: "testuser",
            useNextcloudPath: false, password: "testpass")

        let firstAsked = AskedFlag()
        let fs = try await WebDAVFileSystem.connect(
            config, trustStore: store,
            decider: .asking { _ in await firstAsked.markAsked(); return true })
        await fs.disconnect()
        #expect(await firstAsked.wasAsked)

        let remembered = try #require(try store.find(host: "127.0.0.1", port: 18443))
        // Tamper the stored fingerprint in place -- same host/port, different
        // (fake) certificate bytes -- so `ServerCertificateValidation.evaluate`
        // is forced down the `.mismatch` branch on the next connect.
        try store.upsert(TrustedCertificate(
            host: remembered.host, port: remembered.port,
            derBase64: Data("not-the-real-certificate".utf8).base64EncodedString(),
            subject: remembered.subject, issuer: remembered.issuer,
            notAfter: remembered.notAfter))

        let secondAsked = AskedFlag()
        do {
            _ = try await WebDAVFileSystem.connect(
                config, trustStore: store,
                decider: .asking { _ in await secondAsked.markAsked(); return true })
            Issue.record("expected a certificate mismatch, connect unexpectedly succeeded")
        } catch let error as ServerCertificateError {
            guard case .mismatch = error else {
                Issue.record("expected .mismatch, got \(error)")
                return
            }
        } catch {
            Issue.record("expected ServerCertificateError.mismatch, got \(error)")
        }
        #expect(await secondAsked.wasAsked == false)
    }

    // MARK: - Cross-backend transfer: WebDAV <-> SSH through the real queue

    /// Polls `vm.items` for `id` to reach a terminal state.
    ///
    /// No bound of its own: a transfer that never settles ends this wait
    /// through the suite's `.timeLimit`, which names the test. The bound
    /// that used to sit here was a wall clock over work a loaded machine
    /// schedules, which is the ceiling CLAUDE.md's "A wall-clock ceiling in
    /// a test measures the runner" forbids.
    @MainActor
    private func waitForTerminalStatus(
        _ vm: TransferQueueViewModel, id: UUID
    ) async throws -> TransferQueueViewModel.Item.Status {
        try await pollUntil("the cross-backend transfer to reach a terminal state") {
            vm.items.first(where: { $0.id == id })?.status.isTerminal == true
        }
        guard let status = vm.items.first(where: { $0.id == id })?.status else {
            throw RemoteFSError.protocolError(
                reason: "the transfer item vanished after reaching a terminal state")
        }
        return status
    }

    /// A WebDAV -> SSH transfer driven through `TransferQueueViewModel
    /// .enqueue`, WITH a `crossBackendTarget` set (M16's badge metadata) --
    /// the same production code path an S3<->SSH cross-backend transfer
    /// uses. The queue's transfer machinery does not branch on backend kind
    /// (M12's whole point), so this is the proof that WebDAV needed no
    /// adaptation to slot into it.
    @MainActor
    @Test func webDAVToSSHTransferThroughTheQueueWithCrossBackendTarget() async throws {
        let webdavFS = try await connect(port: 18080)
        defer { Task { await webdavFS.disconnect() } }
        let sshFS = try await connectSSH()
        defer { Task { await sshFS.disconnect() } }

        let sourceName = "m21-w2s-source-\(UUID().uuidString).bin"
        let sourcePath = "/\(sourceName)"
        let destinationName = "m21-w2s-dest-\(UUID().uuidString).bin"
        let destinationPath = "/config/\(destinationName)"
        let payload = pseudoRandomBytes(count: 200 * 1024)

        var caught: Error?
        do {
            try await writeOnce(webdavFS, path: sourcePath, content: payload)

            let vm = TransferQueueViewModel()
            let id = vm.enqueue(
                fileName: destinationName, direction: .download,
                source: webdavFS, sourcePath: sourcePath,
                destination: sshFS, destinationDirectory: "/config",
                onCompleted: nil,
                crossBackendTarget: CrossBackendTarget(name: "webdav-rig", kind: .webdav))

            let status = try await waitForTerminalStatus(vm, id: id)
            #expect(status == .finished)

            let readBack = try await drain(try await sshFS.readStream(path: destinationPath))
            #expect(readBack == payload)
        } catch {
            caught = error
        }
        try? await webdavFS.delete(path: sourcePath)
        await cleanupSSHPath(destinationPath)
        if let caught { throw caught }
    }

    /// The reverse direction, SSH -> WebDAV, so both `RemoteFileSystem`
    /// roles (source and destination) are exercised against the real WebDAV
    /// server, not just one.
    @MainActor
    @Test func sshToWebDAVTransferThroughTheQueueWithCrossBackendTarget() async throws {
        let sshFS = try await connectSSH()
        defer { Task { await sshFS.disconnect() } }
        let webdavFS = try await connect(port: 18080)
        defer { Task { await webdavFS.disconnect() } }

        let sourceName = "m21-s2w-source-\(UUID().uuidString).bin"
        let sourcePath = "/config/\(sourceName)"
        let destinationName = "m21-s2w-dest-\(UUID().uuidString).bin"
        let destinationPath = "/\(destinationName)"
        let payload = pseudoRandomBytes(count: 200 * 1024)

        var caught: Error?
        do {
            try await writeOnce(sshFS, path: sourcePath, content: payload)

            let vm = TransferQueueViewModel()
            let id = vm.enqueue(
                fileName: destinationName, direction: .upload,
                source: sshFS, sourcePath: sourcePath,
                destination: webdavFS, destinationDirectory: "/",
                onCompleted: nil,
                crossBackendTarget: CrossBackendTarget(name: "webdav-rig", kind: .webdav))

            let status = try await waitForTerminalStatus(vm, id: id)
            #expect(status == .finished)

            let readBack = try await drain(try await webdavFS.readStream(path: destinationPath))
            #expect(readBack == payload)
        } catch {
            caught = error
        }
        await cleanupSSHPath(sourcePath)
        try? await webdavFS.delete(path: destinationPath)
        if let caught { throw caught }
    }
}
