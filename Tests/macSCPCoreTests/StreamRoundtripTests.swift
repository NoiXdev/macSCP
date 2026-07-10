import Foundation
import Testing
@testable import macSCPCore

@Suite("Stream roundtrips")
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

        // > 64 KiB, so multiple chunks are produced
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
