import Foundation
import Testing
@testable import macSCPCore

/// Runs only with MACSCP_ITEST=1 and a running Docker test rig
/// (docker compose -f docker/test-server/compose.yml up -d), which brings up
/// a MinIO container seeded with a bucket containing `a.txt` and
/// `sub/b.txt` (M12/T5). Same gating pattern as
/// `CitadelFileSystemIntegrationTests`.
@Suite(
    "S3FileSystem against Docker MinIO",
    .enabled(if: ProcessInfo.processInfo.environment["MACSCP_ITEST"] == "1"),
    .serialized
)
struct S3FileSystemIntegrationTests {
    private func connect() async throws -> S3FileSystem {
        let config = S3ConnectionConfig(
            accessKeyID: "macscp", secretAccessKey: "macscpsecretkey",
            region: "us-east-1", endpoint: "http://127.0.0.1:9000",
            bucket: "macscp-seed", usePathStyle: true, sessionToken: nil)
        return try await S3FileSystem.connect(config)
    }

    @Test func listsSeededBucketRoot() async throws {
        let fs = try await connect()
        defer { Task { await fs.disconnect() } }

        let items = try await fs.list(path: "/")
        let names = items.map(\.name)
        #expect(names.contains("a.txt"))
        #expect(names.contains("sub"))
        #expect(items.first { $0.name == "a.txt" }?.kind == .file)
        #expect(items.first { $0.name == "sub" }?.kind == .directory)
    }

    @Test func listsSeededSubdirectory() async throws {
        let fs = try await connect()
        defer { Task { await fs.disconnect() } }

        let items = try await fs.list(path: "/sub")
        #expect(items.map(\.name).contains("b.txt"))
    }

    @Test func statReturnsTheSeededFilesSize() async throws {
        let fs = try await connect()
        defer { Task { await fs.disconnect() } }

        let item = try await fs.stat(path: "/a.txt")
        #expect(item.kind == .file)
        #expect(item.size != nil)
    }

    @Test func connectFailsWithWrongCredentials() async throws {
        let config = S3ConnectionConfig(
            accessKeyID: "wrong", secretAccessKey: "alsowrongsecret",
            region: "us-east-1", endpoint: "http://127.0.0.1:9000",
            bucket: "macscp-seed", usePathStyle: true, sessionToken: nil)
        await #expect(throws: RemoteFSError.authenticationFailed) {
            _ = try await S3FileSystem.connect(config)
        }
    }
}
