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

    /// M15: an S3 session bound to an S3 login set resolves its credentials
    /// from the set and those credentials really authenticate against MinIO.
    /// Proves the resolve → S3ConnectionConfig → connect → list chain end to
    /// end, not just in a fake.
    @Test func setBoundS3SessionResolvesAndLists() async throws {
        let set = LoginSet(
            name: "rig", username: "",
            kind: .s3, accessKeyID: "macscp")
        let secrets = InMemorySecretStore()
        try secrets.savePassword("macscpsecretkey", for: set.id)
        let session = StoredSession(
            name: "rig-session", host: "unused", username: "unused",
            loginSetID: set.id, kind: .s3)

        // M22/T9: one resolver for every backend, returning the same
        // `FieldValues` the form produces.
        let resolved = try #require(
            try LoginResolver.resolve(session: session, sets: [set], secrets: secrets))

        let config = S3ConnectionConfig(
            accessKeyID: resolved[S3Field.accessKeyID],
            secretAccessKey: resolved[S3Field.secretAccessKey],
            region: "us-east-1", endpoint: "http://127.0.0.1:19000",
            bucket: "macscp-seed", usePathStyle: true, sessionToken: nil)

        let fs = try await S3FileSystem.connect(config)
        defer { Task { await fs.disconnect() } }
        let items = try await fs.list(path: "/")
        #expect(items.count >= 0)
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

    /// M18a final review (Important-1): `createFile`'s existence probe now
    /// only proceeds on a DEFINITE `RemoteFSError.notFound`. That verdict is
    /// produced by `S3FileSystem.stat`, which is a `ListObjectsV2` under the
    /// hood — a fake transport cannot prove the real server drives it to
    /// that exact case, and getting it wrong would leave New File
    /// permanently broken on S3 (worse than the bug being fixed). This
    /// exercises the whole view-model path against MinIO: the missing key
    /// creates, the existing key collides, and the collision must not
    /// truncate the object.
    @MainActor
    @Test func createFileCreatesThenCollidesAgainstMinIO() async throws {
        let fs = try await connect()
        defer { Task { await fs.disconnect() } }
        let key = "m18a-createfile-\(UUID().uuidString).txt"

        var caught: Error?
        do {
            let vm = RemoteBrowserViewModel(fs: fs, startPath: "/")
            await vm.load()

            #expect(await vm.createFile(named: key) == nil)
            let created = try await fs.stat(path: "/\(key)")
            #expect(created.kind == .file)
            #expect(created.size == 0)

            // Give the object content, then collide: the message comes back
            // and the bytes survive.
            let body = Data("keep me".utf8)
            let uploadStream = AsyncThrowingStream<Data, Error> { continuation in
                continuation.yield(body)
                continuation.finish()
            }
            try await fs.write(path: "/\(key)", mode: .overwrite, contents: uploadStream)

            #expect(await vm.createFile(named: key) != nil)
            var readBack = Data()
            for try await chunk in try await fs.readStream(path: "/\(key)", fromOffset: 0) {
                readBack.append(chunk)
            }
            #expect(readBack == body)
        } catch {
            caught = error
        }
        try? await fs.delete(path: "/\(key)")
        if let caught { throw caught }
    }

    /// M14/T2: the signing proof for `presignedURL(.get)` — a presigned GET
    /// URL is only meaningful if a plain, unauthenticated `URLSession`
    /// request against it (no `Authorization` header at all — the signature
    /// lives entirely in the query string) is independently accepted by a
    /// REAL S3-compatible server. The fake-transport unit test
    /// (`S3FileSystemTests.swift`) only proves the URL's SHAPE; it signs and
    /// "sends" from the same data, so it can never catch a SigV4 signing bug
    /// — only MinIO re-deriving the signature from the wire bytes can
    /// (same rationale as the M13 write/rename/deleteTree gated tests).
    @Test func presignedGetURLDownloadsTheObjectFromMinIO() async throws {
        let fs = try await connect()
        defer { Task { await fs.disconnect() } }
        let key = "m14-presign-get-\(UUID().uuidString).txt"
        let body = Data("hello presigned".utf8)

        var caught: Error?
        do {
            let uploadStream = AsyncThrowingStream<Data, Error> { continuation in
                continuation.yield(body)
                continuation.finish()
            }
            try await fs.write(path: "/\(key)", mode: .overwrite, contents: uploadStream)

            let url = try fs.presignedURL(method: .get, key: key, expiresIn: 600)
            let (data, response) = try await URLSession.shared.data(from: url)
            #expect((response as? HTTPURLResponse)?.statusCode == 200)
            #expect(data == body)
        } catch {
            caught = error
        }
        // Best-effort cleanup so re-runs stay reproducible, mirroring every
        // other gated test's pattern.
        try? await fs.delete(path: "/\(key)")
        if let caught { throw caught }
    }

    /// M14/T2: the signing proof for `presignedURL(.put)` — a presigned PUT
    /// URL uploads to the exact key it was signed for when driven by a
    /// plain `URLSession.upload(for:from:)`, again against a REAL MinIO
    /// server (see the GET test above for the fuller rationale).
    @Test func presignedPutURLUploadsToTheKeyOnMinIO() async throws {
        let fs = try await connect()
        defer { Task { await fs.disconnect() } }
        let key = "m14-presign-put-\(UUID().uuidString).bin"

        var caught: Error?
        do {
            let url = try fs.presignedURL(method: .put, key: key, expiresIn: 600)
            var request = URLRequest(url: url)
            request.httpMethod = "PUT"
            let body = Data(repeating: 0x5A, count: 4096)
            let (_, response) = try await URLSession.shared.upload(for: request, from: body)
            #expect(((response as? HTTPURLResponse)?.statusCode ?? 0) / 100 == 2)

            let stat = try await fs.stat(path: "/\(key)")
            #expect(stat.size == 4096)
        } catch {
            caught = error
        }
        try? await fs.delete(path: "/\(key)")
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
