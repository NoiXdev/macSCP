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
            region: "us-east-1", endpoint: "http://127.0.0.1:19000",
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
            region: "us-east-1", endpoint: "http://127.0.0.1:19000",
            bucket: "macscp-seed", usePathStyle: true, sessionToken: nil)
        await #expect(throws: RemoteFSError.authenticationFailed) {
            _ = try await S3FileSystem.connect(config)
        }
    }

    /// Regression for M13/T4: `buildSignedRequest` used to sign
    /// `URL.path`, which silently drops a trailing slash, so the PUT of a
    /// folder-marker key ("name/") was signed as "name" and MinIO rejected
    /// it with a 403 SignatureDoesNotMatch. This only reproduces against a
    /// real S3-compatible server — the fake-transport unit tests build the
    /// signature and the wire request from the same (buggy) path, so they
    /// can never see the two diverge.
    @Test func createDirectoryThenListShowsTheFolderAgainstMinIO() async throws {
        let fs = try await connect()
        defer { Task { await fs.disconnect() } }
        let name = "m13-createdir-probe"

        var caught: Error?
        do {
            try await fs.createDirectory(at: "/\(name)")
            let items = try await fs.list(path: "/")
            #expect(items.contains { $0.name == name && $0.kind == .directory })
        } catch {
            caught = error
        }
        // Best-effort cleanup so re-runs stay reproducible. `S3FileSystem
        // .delete` normalizes away a trailing slash (it targets FILE keys),
        // so it cannot address a folder-marker key ("name/") — issue a raw
        // signed DELETE instead. `deleteTree` isn't implemented yet
        // (M13/T8), and cleanup failing must never fail this test.
        await Self.deleteMarkerObjectIgnoringErrors(key: "\(name)/")
        if let caught { throw caught }
    }

    /// M13/T5: a small object round-trip against a REAL MinIO server. Unit
    /// tests (`S3UploaderTests.swift`) exercise `S3Uploader`'s buffering and
    /// error-mapping logic with a fake builder that signs and sends the
    /// request from the SAME data, so they can never catch a SigV4 signing
    /// bug — only a live server that independently re-derives the signature
    /// from the wire bytes can. This is that check: `write` a few KiB to a
    /// unique key, `readStream` it back, and assert the bytes are identical.
    @Test func writeThenReadStreamRoundTripsBitIdenticalContent() async throws {
        let fs = try await connect()
        defer { Task { await fs.disconnect() } }
        let key = "m13-uploader-roundtrip-\(UUID().uuidString).bin"
        let body = Data((0..<4096).map { UInt8($0 & 0xFF) })

        var caught: Error?
        do {
            let uploadStream = AsyncThrowingStream<Data, Error> { continuation in
                continuation.yield(body)
                continuation.finish()
            }
            try await fs.write(path: "/\(key)", mode: .overwrite, contents: uploadStream)

            var received = Data()
            for try await chunk in try await fs.readStream(path: "/\(key)", fromOffset: 0) {
                received.append(chunk)
            }
            #expect(received == body)
        } catch {
            caught = error
        }
        // Best-effort cleanup so re-runs stay reproducible, mirroring the
        // pattern above for the folder-marker probe.
        try? await fs.delete(path: "/\(key)")
        if let caught { throw caught }
    }

    /// M13/T6: a >8 MiB object write→read round-trip against a REAL MinIO
    /// server — the one check that actually exercises the multipart
    /// handshake end to end. Unit tests (`S3UploaderTests.swift`) exercise
    /// `S3Uploader`'s part-cutting and abort-on-failure logic with a fake
    /// builder that signs and sends from the SAME data, so they can never
    /// catch a SigV4 signing bug in the Initiate/UploadPart/Complete
    /// requests — only a live server that independently re-derives the
    /// signature from the wire bytes can (mirrors the reasoning for the
    /// small-object round-trip above, M13/T5).
    @Test func writeThenReadStreamRoundTripsBitIdenticalContentAboveMultipartThreshold() async throws {
        let fs = try await connect()
        defer { Task { await fs.disconnect() } }
        let key = "m13-multipart-roundtrip-\(UUID().uuidString).bin"
        // 12 MiB of deterministic pseudo-random bytes (a simple LCG) — large
        // enough to force >=2 multipart parts (partSize is 8 MiB) while
        // staying fast to generate/verify.
        let size = 12 * 1024 * 1024
        var state: UInt64 = 0x1234_5678_9abc_def0
        var body = Data(capacity: size)
        for _ in 0..<size {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            body.append(UInt8((state >> 33) & 0xFF))
        }

        var caught: Error?
        do {
            let uploadStream = AsyncThrowingStream<Data, Error> { continuation in
                // Yield in chunks rather than one huge Data blob, so this
                // exercises the same incremental-buffering path a real
                // transfer would use.
                let chunkSize = 256 * 1024
                var offset = 0
                while offset < body.count {
                    let end = min(offset + chunkSize, body.count)
                    continuation.yield(body.subdata(in: offset..<end))
                    offset = end
                }
                continuation.finish()
            }
            try await fs.write(path: "/\(key)", mode: .overwrite, contents: uploadStream)

            var received = Data()
            for try await chunk in try await fs.readStream(path: "/\(key)", fromOffset: 0) {
                received.append(chunk)
            }
            #expect(received == body)
        } catch {
            caught = error
        }
        // Best-effort cleanup so re-runs stay reproducible, mirroring the
        // pattern above for the small-object round-trip.
        try? await fs.delete(path: "/\(key)")
        if let caught { throw caught }
    }

    /// M13/T7: rename on a FILE — a signed `x-amz-copy-source` PUT followed
    /// by a DELETE of the source, against a REAL MinIO server. Unit tests
    /// (`S3FileSystemTests.swift`) exercise the copy-source header shape and
    /// the destination pre-check with a fake transport that signs and sends
    /// from the SAME data, so they can never catch a SigV4 signing bug in
    /// the copy-source header — only a live server that independently
    /// re-derives the signature from the wire bytes can (mirrors the
    /// reasoning for the write/multipart round trips above).
    @Test func renameFileMovesTheObjectToTheNewKey() async throws {
        let fs = try await connect()
        defer { Task { await fs.disconnect() } }
        let sourceKey = "m13-rename-file-src-\(UUID().uuidString).txt"
        let destKey = "m13-rename-file-dest-\(UUID().uuidString).txt"
        let body = Data("rename me".utf8)

        var caught: Error?
        do {
            let uploadStream = AsyncThrowingStream<Data, Error> { continuation in
                continuation.yield(body)
                continuation.finish()
            }
            try await fs.write(path: "/\(sourceKey)", mode: .overwrite, contents: uploadStream)

            try await fs.rename(from: "/\(sourceKey)", to: "/\(destKey)")

            var received = Data()
            for try await chunk in try await fs.readStream(path: "/\(destKey)", fromOffset: 0) {
                received.append(chunk)
            }
            #expect(received == body)

            do {
                _ = try await fs.stat(path: "/\(sourceKey)")
                Issue.record("expected the source key to be gone after rename")
            } catch let error as RemoteFSError {
                guard case .notFound = error else {
                    Issue.record("expected .notFound for the renamed-away source, got \(error)")
                    return
                }
            }
        } catch {
            caught = error
        }
        // Best-effort cleanup so re-runs stay reproducible — the source
        // should already be gone if the rename succeeded, but a partial
        // failure could leave it behind.
        try? await fs.delete(path: "/\(sourceKey)")
        try? await fs.delete(path: "/\(destKey)")
        if let caught { throw caught }
    }

    /// M13/T7: rename on a DIRECTORY — every object under the source prefix
    /// (here two, one nested under a sub-prefix) must be re-keyed to the
    /// destination prefix, and NONE may remain at the source, against a
    /// REAL MinIO server. Same signing-bug rationale as the file-rename
    /// test above, applied to the `allObjectKeys` pagination + per-key
    /// copy+delete loop.
    @Test func renameDirectoryMovesEveryObjectToTheNewPrefix() async throws {
        let fs = try await connect()
        defer { Task { await fs.disconnect() } }
        let suffix = UUID().uuidString
        let sourceFolder = "m13-rename-dir-src-\(suffix)"
        let destFolder = "m13-rename-dir-dest-\(suffix)"
        let childKeys = ["child-a.txt", "sub/child-b.txt"]

        var caught: Error?
        do {
            for child in childKeys {
                let uploadStream = AsyncThrowingStream<Data, Error> { continuation in
                    continuation.yield(Data(child.utf8))
                    continuation.finish()
                }
                try await fs.write(path: "/\(sourceFolder)/\(child)", mode: .overwrite, contents: uploadStream)
            }

            try await fs.rename(from: "/\(sourceFolder)", to: "/\(destFolder)")

            for child in childKeys {
                var received = Data()
                for try await chunk in try await fs.readStream(path: "/\(destFolder)/\(child)", fromOffset: 0) {
                    received.append(chunk)
                }
                #expect(received == Data(child.utf8))
            }

            // Nothing must remain at the OLD prefix; the NEW one must show
            // up as a directory in a root listing.
            let rootItems = try await fs.list(path: "/")
            #expect(!rootItems.contains { $0.name == sourceFolder })
            #expect(rootItems.contains { $0.name == destFolder && $0.kind == .directory })
        } catch {
            caught = error
        }
        // Best-effort cleanup at BOTH prefixes so re-runs stay reproducible
        // even if an assertion above fails partway through the rename.
        for child in childKeys {
            try? await fs.delete(path: "/\(sourceFolder)/\(child)")
            try? await fs.delete(path: "/\(destFolder)/\(child)")
        }
        if let caught { throw caught }
    }

    /// M13/T8: `deleteTree` against a REAL MinIO server — creates a folder
    /// with several objects (one nested under a sub-prefix, plus the
    /// folder's own trailing-slash marker), deletes the whole tree, and
    /// asserts BOTH that a root listing no longer shows the folder AND that
    /// no keys remain under its prefix. Same signing-bug rationale as the
    /// rename tests above: the `DeleteObjects` `Content-MD5` header and the
    /// bucket-root (`key: ""`) request path are exactly the kind of thing
    /// only a live server that independently re-derives the SigV4 signature
    /// from the wire bytes can validate.
    @Test func deleteTreeRemovesEveryObjectUnderThePrefix() async throws {
        let fs = try await connect()
        defer { Task { await fs.disconnect() } }
        let folder = "m13-deletetree-\(UUID().uuidString)"
        let childKeys = ["a.txt", "sub/b.txt"]

        var caught: Error?
        do {
            try await fs.createDirectory(at: "/\(folder)")
            for child in childKeys {
                let uploadStream = AsyncThrowingStream<Data, Error> { continuation in
                    continuation.yield(Data(child.utf8))
                    continuation.finish()
                }
                try await fs.write(path: "/\(folder)/\(child)", mode: .overwrite, contents: uploadStream)
            }

            try await fs.deleteTree(at: "/\(folder)")

            let rootItems = try await fs.list(path: "/")
            #expect(!rootItems.contains { $0.name == folder })
            // `allObjectKeys` itself is private, so the "no keys remain
            // under the prefix" half of the assertion goes through `list`
            // on the (now nonexistent) folder path instead: ListObjectsV2
            // returns an empty page for a prefix with zero matching keys
            // rather than a 404, so an empty result here is exactly "no
            // keys remain under this prefix".
            let folderItems = try await fs.list(path: "/\(folder)")
            #expect(folderItems.isEmpty)
        } catch {
            caught = error
        }
        // Best-effort cleanup so re-runs stay reproducible even if an
        // assertion above fails partway through.
        for child in childKeys {
            try? await fs.delete(path: "/\(folder)/\(child)")
        }
        await Self.deleteMarkerObjectIgnoringErrors(key: "\(folder)/")
        if let caught { throw caught }
    }

    private static func deleteMarkerObjectIgnoringErrors(key: String) async {
        let bucket = "macscp-seed"
        let rawPath = "/\(bucket)/\(key)"
        guard var components = URLComponents(string: "http://127.0.0.1:19000") else { return }
        components.percentEncodedPath = rawPath
        guard let url = components.url, let host = url.host else { return }
        let hostHeader = url.port.map { "\(host):\($0)" } ?? host

        let signer = SigV4Signer(
            accessKeyID: "macscp", secretAccessKey: "macscpsecretkey",
            region: "us-east-1", service: "s3", sessionToken: nil)
        let (authorization, extraHeaders) = signer.authorizationHeader(
            method: "DELETE", host: hostHeader, path: rawPath, query: [],
            headers: ["host": hostHeader], payloadHash: SigV4Signer.emptyPayloadHash, date: Date())

        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue(hostHeader, forHTTPHeaderField: "Host")
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        for (k, v) in extraHeaders { request.setValue(v, forHTTPHeaderField: k) }

        _ = try? await URLSession.shared.data(for: request)
    }
}
