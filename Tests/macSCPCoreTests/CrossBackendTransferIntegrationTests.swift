import Foundation
import NIOCore
import Testing
@testable import macSCPCore

/// Cross-backend transfers between MinIO (S3) and the SSH rig (SFTP), M16.
/// Runs only with MACSCP_ITEST=1 and the Docker rig up
/// (`docker compose -f docker/test-server/compose.yml up -d`). Proves that
/// `TransferEngine.copyFile` really moves bytes between two DIFFERENT
/// backend kinds against real servers — the unit tests only ever exercise
/// same-kind or fake-transport pairs, so a cross-backend signing/path bug
/// (the kind M12/M13 already found within a single backend) could otherwise
/// hide here.
@Suite(
    "Cross-backend S3↔SSH transfer",
    .enabled(if: ProcessInfo.processInfo.environment["MACSCP_ITEST"] == "1"),
    .serialized
)
struct CrossBackendTransferIntegrationTests {
    private func connectS3() async throws -> S3FileSystem {
        let config = S3ConnectionConfig(
            accessKeyID: "macscp", secretAccessKey: "macscpsecretkey",
            region: "us-east-1", endpoint: "http://127.0.0.1:19000",
            bucket: "macscp-seed", usePathStyle: true, sessionToken: nil)
        return try await S3FileSystem.connect(config)
    }

    // Connects that must succeed go through the shared `connectWithRetry`
    // in `Support/IntegrationConnect.swift`; the private copy that used to
    // sit here shadowed it with an identical body.

    private func connectSSH(port: Int = 2222) async throws -> CitadelFileSystem {
        let config = try SSHConnectionConfig(
            host: "127.0.0.1",
            port: port,
            username: "testuser",
            auth: .password("testpass")
        )
        // The store is only consulted during the handshake (never retained by
        // the returned `CitadelFileSystem`), so its temp directory can be
        // removed right after `connect` returns.
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-kh-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = KnownHostsStore(directory: dir)
        return try await connectWithRetry {
            try await CitadelFileSystem.connect(
                config: config, connectTimeout: .seconds(30), knownHosts: store, onUnknownHostKey: .asking { _ in true })
        }
    }

    /// Best-effort recursive removal of an SSH-side path via the test
    /// container's shell — mirrors `CitadelFileSystemIntegrationTests
    /// .cleanupConfigPath` verbatim (writable base is `/config` on the rig).
    private func cleanupSSHPath(_ path: String, container: String = "macscp-test-sshd") {
        let rm = Process()
        rm.executableURL = URL(fileURLWithPath: "/usr/local/bin/docker")
        rm.arguments = ["exec", container, "rm", "-rf", path]
        try? rm.run()
        rm.waitUntilExit()
    }

    /// Writes a single in-memory `Data` blob to `path` on `fs` in one shot.
    private func writeOnce(_ fs: any RemoteFileSystem, path: String, content: Data) async throws {
        let (stream, continuation) = AsyncThrowingStream<Data, Error>.makeStream()
        continuation.yield(content)
        continuation.finish()
        try await fs.write(path: path, contents: stream)
    }

    /// Reads an `AsyncThrowingStream<Data>` to completion, appending every
    /// chunk into a single `Data` — shared by every byte-identical assertion
    /// below.
    private func drain(_ stream: AsyncThrowingStream<Data, Error>) async throws -> Data {
        var result = Data()
        for try await chunk in stream {
            result.append(chunk)
        }
        return result
    }

    /// Recursive list + createDirectory + copyFile walk, the same shape a
    /// real tree-transfer (M5b) drives — good enough to prove the
    /// cross-backend directory-tree path without depending on the queue's
    /// internal tree-transfer plumbing.
    private func copyTree(
        from source: any RemoteFileSystem, sourcePath: String,
        to destination: any RemoteFileSystem, destinationPath: String
    ) async throws {
        try await destination.createDirectory(at: destinationPath)
        for item in try await source.list(path: sourcePath) {
            switch item.kind {
            case .directory:
                try await copyTree(
                    from: source, sourcePath: "\(sourcePath)/\(item.name)",
                    to: destination, destinationPath: "\(destinationPath)/\(item.name)")
            case .file:
                try await TransferEngine.copyFile(
                    from: source, sourcePath: "\(sourcePath)/\(item.name)",
                    to: destination, destinationDirectory: destinationPath, fileName: item.name,
                    onProgress: { _ in })
            case .symlink, .other:
                break
            }
        }
    }

    // MARK: - SSH -> S3 byte-identical

    @Test func sshToS3CopyIsByteIdentical() async throws {
        let sshFS = try await connectSSH()
        defer { Task { await sshFS.disconnect() } }
        let s3FS = try await connectS3()
        defer { Task { await s3FS.disconnect() } }

        let sourceName = "m16-x2s-source-\(UUID().uuidString).bin"
        let sourcePath = "/config/\(sourceName)"
        let destinationKey = "m16-x2s-dest-\(UUID().uuidString).bin"

        var caught: Error?
        do {
            // ~200 KiB of random payload, written to the SSH side only.
            let payload = Data((0..<(200 * 1024)).map { _ in UInt8.random(in: 0...255) })
            try await writeOnce(sshFS, path: sourcePath, content: payload)

            try await TransferEngine.copyFile(
                from: sshFS, sourcePath: sourcePath,
                to: s3FS, destinationDirectory: "/", fileName: destinationKey,
                onProgress: { _ in })

            let readBack = try await drain(try await s3FS.readStream(path: "/\(destinationKey)"))
            #expect(readBack == payload)
        } catch {
            caught = error
        }
        // Best-effort cleanup on both sides so re-runs stay reproducible.
        cleanupSSHPath(sourcePath)
        try? await s3FS.delete(path: "/\(destinationKey)")
        if let caught { throw caught }
    }

    // MARK: - S3 -> SSH byte-identical

    @Test func s3ToSSHCopyIsByteIdentical() async throws {
        let s3FS = try await connectS3()
        defer { Task { await s3FS.disconnect() } }
        let sshFS = try await connectSSH()
        defer { Task { await sshFS.disconnect() } }

        let sourceKey = "m16-s2x-source-\(UUID().uuidString).bin"
        let destinationName = "m16-s2x-dest-\(UUID().uuidString).bin"
        let destinationPath = "/config/\(destinationName)"

        var caught: Error?
        do {
            // ~200 KiB of random payload, written to MinIO only.
            let payload = Data((0..<(200 * 1024)).map { _ in UInt8.random(in: 0...255) })
            try await writeOnce(s3FS, path: "/\(sourceKey)", content: payload)

            try await TransferEngine.copyFile(
                from: s3FS, sourcePath: "/\(sourceKey)",
                to: sshFS, destinationDirectory: "/config", fileName: destinationName,
                onProgress: { _ in })

            let readBack = try await drain(try await sshFS.readStream(path: destinationPath))
            #expect(readBack == payload)
        } catch {
            caught = error
        }
        try? await s3FS.delete(path: "/\(sourceKey)")
        cleanupSSHPath(destinationPath)
        if let caught { throw caught }
    }

    // MARK: - Directory tree cross-backend (SSH -> S3)

    /// A directory with one file plus a subfolder-with-a-file, copied
    /// SSH -> S3 via `list` + `createDirectory` + `copyFile` (the same shape
    /// a tree-transfer drives). On the S3 side `createDirectory` lays down
    /// the 0-byte folder marker, and the final `list` calls prove both files
    /// landed in the correct nested structure.
    @Test func directoryTreeCopiesSSHToS3WithCorrectStructure() async throws {
        let sshFS = try await connectSSH()
        defer { Task { await sshFS.disconnect() } }
        let s3FS = try await connectS3()
        defer { Task { await s3FS.disconnect() } }

        let suffix = UUID().uuidString
        let sourceBase = "/config/m16-tree-src-\(suffix)"
        let destBase = "/m16-tree-dest-\(suffix)"
        let topFile = "top.txt"
        let subFile = "sub.txt"

        var caught: Error?
        do {
            // Build the tree on the SSH side: base/top.txt + base/sub/sub.txt.
            try await sshFS.createDirectory(at: sourceBase)
            try await writeOnce(sshFS, path: "\(sourceBase)/\(topFile)", content: Data("top".utf8))
            try await sshFS.createDirectory(at: "\(sourceBase)/sub")
            try await writeOnce(sshFS, path: "\(sourceBase)/sub/\(subFile)", content: Data("sub".utf8))

            try await copyTree(
                from: sshFS, sourcePath: sourceBase, to: s3FS, destinationPath: destBase)

            let destItems = try await s3FS.list(path: destBase)
            #expect(destItems.contains { $0.name == topFile && $0.kind == .file })
            #expect(destItems.contains { $0.name == "sub" && $0.kind == .directory })

            let destSubItems = try await s3FS.list(path: "\(destBase)/sub")
            #expect(destSubItems.contains { $0.name == subFile && $0.kind == .file })
        } catch {
            caught = error
        }
        // Best-effort cleanup on both sides so re-runs stay reproducible.
        // `deleteTree` removes every object under the prefix INCLUDING the
        // 0-byte folder markers `createDirectory` left behind (M13/T8).
        cleanupSSHPath(sourceBase)
        try? await s3FS.deleteTree(at: destBase)
        if let caught { throw caught }
    }

    // MARK: - Resume guard across the backend boundary

    /// `resume: true` against an S3 destination: `supportsAppendResume` is
    /// `false` for S3, so the M13 guard forces `.overwrite` regardless of the
    /// caller's flag. The proof is a fully successful, byte-identical
    /// transfer despite `resume: true` — no 416, no corrupted/truncated
    /// object (direct access to the internal write-mode isn't available or
    /// needed).
    @Test func resumeTrueAcrossBoundaryStillCopiesByteIdentical() async throws {
        let sshFS = try await connectSSH()
        defer { Task { await sshFS.disconnect() } }
        let s3FS = try await connectS3()
        defer { Task { await s3FS.disconnect() } }

        let sourceName = "m16-resume-source-\(UUID().uuidString).bin"
        let sourcePath = "/config/\(sourceName)"
        let destinationKey = "m16-resume-dest-\(UUID().uuidString).bin"

        var caught: Error?
        do {
            let payload = Data((0..<(200 * 1024)).map { _ in UInt8.random(in: 0...255) })
            try await writeOnce(sshFS, path: sourcePath, content: payload)

            try await TransferEngine.copyFile(
                from: sshFS, sourcePath: sourcePath,
                to: s3FS, destinationDirectory: "/", fileName: destinationKey,
                resume: true,
                onProgress: { _ in })

            let readBack = try await drain(try await s3FS.readStream(path: "/\(destinationKey)"))
            #expect(readBack == payload)
        } catch {
            caught = error
        }
        cleanupSSHPath(sourcePath)
        try? await s3FS.delete(path: "/\(destinationKey)")
        if let caught { throw caught }
    }
}
