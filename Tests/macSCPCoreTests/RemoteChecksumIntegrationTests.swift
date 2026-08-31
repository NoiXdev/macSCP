import CryptoKit
import Foundation
import Testing

@testable import macSCPCore

/// Runs only with MACSCP_ITEST=1 and a running Docker test server
/// (`docker compose -f docker/test-server/compose.yml up -d`, from the MAIN
/// checkout — the seed mount is relative to the compose file).
///
/// What only a real far side can show: that the line this package builds is
/// one a real shell runs, that the tool it names is there and answers in the
/// shape `ChecksumOutputReader` expects, and that the digest is the file's.
/// The rig is GNU coreutils, so it exercises `ChecksumCommandForm.gnu`; the
/// BSD form's tools were measured directly on the macOS host that ran this
/// (see `ChecksumCommandForm.command(for:path:)`).
@Suite(
    "A checksum from the Docker SSH server",
    .enabled(if: ProcessInfo.processInfo.environment["MACSCP_ITEST"] == "1"),
    .serialized
)
struct RemoteChecksumIntegrationTests {
    private func connect() async throws -> CitadelFileSystem {
        let config = try SSHConnectionConfig(
            host: "127.0.0.1", port: 2222, username: "testuser",
            auth: .password("testpass"))
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-kh-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = KnownHostsStore(directory: directory)
        let make = {
            try await CitadelFileSystem.connect(
                config: config, connectTimeout: .seconds(30), knownHosts: store,
                onUnknownHostKey: .asking { _ in true })
        }
        // Cushions the container's reconnect throttling, like every other
        // gated suite here.
        do {
            return try await make()
        } catch {
            try? await Task.sleep(for: .milliseconds(500))
            return try await make()
        }
    }

    private func upload(_ bytes: Data, to path: String, over fs: CitadelFileSystem) async throws {
        let (stream, continuation) = AsyncThrowingStream<Data, Error>.makeStream()
        continuation.yield(bytes)
        continuation.finish()
        try await fs.write(path: path, contents: stream)
    }

    /// A path that carries both of the characters a shell would otherwise
    /// read as syntax — a space, which would split the word, and an
    /// apostrophe, which would close the quoting around it.
    private func awkwardPath() -> String {
        "/config/macscp-checksum it's \(UUID().uuidString).bin"
    }

    private func randomBytes(_ count: Int) -> Data {
        Data((0..<count).map { _ in UInt8.random(in: .min ... .max) })
    }

    @Test("the far side's SHA-256 of a file is the one computed here")
    func sha256MatchesALocallyComputedDigest() async throws {
        let fs = try await connect()
        let path = awkwardPath()
        defer {
            Task {
                try? await fs.delete(path: path)
                await fs.disconnect()
            }
        }

        let bytes = randomBytes(256 * 1024)
        try await upload(bytes, to: path, over: fs)

        let provider = try #require(fs as (any RemoteChecksumProvider)?)
        let outcome = try await provider.remoteChecksum(forFileAt: path, algorithm: .sha256)

        let locally = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        #expect(outcome == .checksum(FileChecksum.computedOnRemote(.sha256, hex: locally)!))
        guard case .checksum(let checksum) = outcome else { return }
        #expect(checksum.provenance == .computedOnRemote)
        #expect(checksum.describesFileContent)
    }

    /// The second algorithm on the same connection: the form was already
    /// found, and it has to name the right tool for MD5 as well as for
    /// SHA-256.
    @Test("the same connection answers for a second algorithm too")
    func md5MatchesALocallyComputedDigest() async throws {
        let fs = try await connect()
        let path = awkwardPath()
        defer {
            Task {
                try? await fs.delete(path: path)
                await fs.disconnect()
            }
        }

        let bytes = randomBytes(64 * 1024)
        try await upload(bytes, to: path, over: fs)

        let provider = try #require(fs as (any RemoteChecksumProvider)?)
        _ = try await provider.remoteChecksum(forFileAt: path, algorithm: .sha256)
        let outcome = try await provider.remoteChecksum(forFileAt: path, algorithm: .md5)

        let locally = Insecure.MD5.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        #expect(outcome == .checksum(FileChecksum.computedOnRemote(.md5, hex: locally)!))
    }
}
