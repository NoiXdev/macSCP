# M13 — S3 Transfer + CRUD Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the S3 backend fully transfer and CRUD-capable — real `readStream`, `write`, `delete`, `createDirectory`, `rename`, `deleteTree` — over the existing SigV4 signer, validated against MinIO.

**Architecture:** Extend the `S3HTTPTransport` seam with a streaming download; generalize request-building into a signed-request helper; add an `S3Uploader` that hybridizes single-PUT and multipart; map the remaining CRUD verbs to their S3 REST calls; and add a protocol-level `supportsAppendResume` flag so the generic `TransferEngine` never appends a tail to a non-appendable S3 destination.

**Tech Stack:** Swift 6 (`.swiftLanguageMode(.v5)`), Foundation (`URLSession`, `XMLParser`), swift-crypto (`SHA256`/`Insecure.MD5` via the existing signer + hashing), Swift Testing. No new dependency.

## Global Constraints

- Swift 6, all targets `.swiftLanguageMode(.v5)`, minimum macOS 15.
- Code and comments English only. No new user-facing strings expected (transfer/CRUD error + action texts are backend-agnostic already); if one is unavoidable, add it to all four catalogs (en/de/fr/pl), typographic quotes, no ASCII `"` in non-English values.
- No new external dependency — Foundation + swift-crypto (via `SigV4Signer` and `import Crypto` for MD5).
- Secrets (`secretAccessKey`/`sessionToken`) flow only into `SigV4Signer`; never logged/interpolated. No request/response bodies in logs.
- No atomic rename, no true upload-resume — documented S3 limits.
- Every multipart upload aborts on any failure path (no orphaned upload).
- TDD red→green; new logic ships with tests. Gated MinIO runs from the MAIN checkout (never a worktree), seed reproducible.
- **No release.** Cross-backend S3↔SSH transfer + presigned URLs are M14.

## Existing interfaces (verified, do not re-derive)

- `SigV4Signer.authorizationHeader(method: String, host: String, path: String, query: [(name: String, value: String)], headers: [String: String], payloadHash: String, date: Date) -> (authorization: String, extraHeaders: [String: String])` — already supports any method + payload hash. `SigV4Signer.emptyPayloadHash` constant. `static func canonicalQueryString(query:) -> String` (internal, the single source of wire-query encoding — the M12 I-1 fix).
- `S3HTTPTransport.send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)`; `URLSessionS3Transport` wraps `URLSession`.
- `S3FileSystem` (`Sources/macSCPCore/S3/S3FileSystem.swift`): private `init(config:transport:)`, `config: S3ConnectionConfig`, `transport: any S3HTTPTransport`; existing private `buildListRequest(prefix:continuationToken:)`, static `queryPairs(...)`, static `requestURL(config:queryPairs:)`, static `s3Prefix(forPath:)`. All mutating methods currently throw `.protocolError`.
- `S3ConnectionConfig`: `accessKeyID`, `secretAccessKey`, `region`, `endpoint`, `bucket`, `usePathStyle`, `sessionToken`.
- `RemoteFileSystem` (`Sources/macSCPCore/RemoteFS/RemoteFileSystem.swift`): the protocol + an `extension` (line 64) with the convenience `readStream(path:)`/`write(path:contents:)` defaults. `TransferChunk.size = 64 * 1024`. `WriteMode.overwrite/.append`.
- `RemoteFSError`: `.connectionFailed(reason:)`, `.authenticationFailed`, `.notFound(path:)`, `.permissionDenied(path:)`, `.protocolError(reason:)`. Equatable.
- `RemoteFileItem(name:path:kind:size:modifiedAt:permissions:owner:group:)`; `RemoteFileKind.file/.directory/.symlink/.other`; `isDirectory`.
- `RemotePath.join(_:_:)`, `.parent(of:)`, `.normalizedAbsolute(_:)`.
- `TransferEngine.copyFile(from:sourcePath:to:destinationDirectory:fileName:resume:throttle:secondaryThrottle:onProgress:)` (`Sources/macSCPCore/RemoteFS/TransferEngine.swift:93`): stats source for `total`, computes `resumeOffset` from `destination.stat().size` only when `resume == true`, reads `source.readStream(fromOffset:)`, writes `destination.write(mode: resumeOffset > 0 ? .append : .overwrite, contents:)`.
- Test fake (`Tests/macSCPCoreTests/S3FileSystemTests.swift`): `actor FakeS3Transport: S3HTTPTransport` with `responses: [(Data, HTTPURLResponse)]` (FIFO) + `requests: [URLRequest]`; helper `httpResponse(status:)`; `struct ThrowingS3Transport` whose `send` throws.
- Gated integration (`Tests/macSCPCoreTests/S3FileSystemIntegrationTests.swift`): `@Suite(..., .enabled(if: ProcessInfo.processInfo.environment["MACSCP_ITEST"] == "1"), .serialized)`, connects to `http://127.0.0.1:19000`, path-style, region `us-east-1`, creds `macscp`/`macscpsecretkey`, bucket `macscp-seed`.

---

### Task 1: Resume safety — `supportsAppendResume` + engine guard + queue gating

**Files:**
- Modify: `Sources/macSCPCore/RemoteFS/RemoteFileSystem.swift` (protocol requirement + default extension)
- Modify: `Sources/macSCPCore/S3/S3FileSystem.swift` (override → `false`)
- Modify: `Sources/macSCPCore/RemoteFS/TransferEngine.swift:93-122` (guard)
- Modify: `Sources/macSCPCore/Presentation/TransferQueueViewModel.swift` (gate the resume/interrupted offer)
- Test: `Tests/macSCPCoreTests/TransferEngineTests.swift` (new resume-guard case), `Tests/macSCPCoreTests/S3FileSystemTests.swift` (flag is false)

**Interfaces:**
- Produces: `var supportsAppendResume: Bool { get }` on `RemoteFileSystem` (default `true` via extension; `S3FileSystem` returns `false`). `TransferEngine.copyFile` internally computes `let effectiveResume = resume && destination.supportsAppendResume`.

- [ ] **Step 1: Failing test — engine never appends to a non-appendable destination.** In `TransferEngineTests.swift`, add a mock `RemoteFileSystem` that records the `WriteMode` it was handed and reports `supportsAppendResume == false`, with a `stat` returning a size SMALLER than the source total (the corruption trigger). Assert that `copyFile(resume: true)` writes with `.overwrite` from offset 0, not `.append`.

```swift
@Test func resumeIsSuppressedForNonAppendableDestination() async throws {
    // Source: 100 bytes. Destination: reports 40 bytes already there AND
    // supportsAppendResume == false (an S3-like backend). A naive resume
    // would append the tail from offset 40 and corrupt the object.
    let source = InMemoryFS(files: ["/a.bin": Data(repeating: 0xAB, count: 100)])
    let dest = RecordingFS(existingSize: 40, supportsAppendResume: false)
    try await TransferEngine.copyFile(
        from: source, sourcePath: "/a.bin",
        to: dest, destinationDirectory: "/", fileName: "a.bin",
        resume: true, onProgress: { _ in })
    #expect(dest.lastWriteMode == .overwrite)
    #expect(dest.lastReadOffset == 0)   // full re-read, not from 40
}
```
(Use/extend whatever in-memory `RemoteFileSystem` test doubles already exist in `TransferEngineTests.swift`; if none record the write mode, add a minimal `RecordingFS` conforming to the full protocol with `supportsAppendResume` overridable and capturing `write`'s `mode` + the offset passed to the source's `readStream`. The source offset is observable because `copyFile` calls `source.readStream(path:fromOffset:)` — make the source double record the offset too, or assert via `dest.lastWriteMode` alone if the source is the in-memory one.)

- [ ] **Step 2: Run red.** `swift test --filter TransferEngine` → FAIL (the protocol has no `supportsAppendResume` yet; won't compile / wrong mode).

- [ ] **Step 3: Add the protocol member + default.** In `RemoteFileSystem.swift`, add to the protocol:
```swift
    /// Whether an interrupted transfer to THIS file system can resume by
    /// appending to a partial destination (`WriteMode.append`). SSH/local
    /// support it; object stores like S3 do not (no append, and a re-PUT
    /// replaces the whole object) — the engine forces a full overwrite for
    /// destinations that return `false`, so a size-mismatched existing object
    /// is never corrupted by an append tail (M13).
    var supportsAppendResume: Bool { get }
```
And in the `extension RemoteFileSystem` (near line 64) add the default:
```swift
    public var supportsAppendResume: Bool { true }
```

- [ ] **Step 4: Override in S3 + engine guard.** In `S3FileSystem.swift` add `public var supportsAppendResume: Bool { false }`. In `TransferEngine.copyFile`, replace the resume gate (line ~108 `if resume {`) so it reads the effective flag first:
```swift
        // S3-like destinations cannot append (no partial object survives a
        // failed multipart, and a re-PUT replaces the whole object) — force a
        // full overwrite regardless of the caller's `resume` (M13).
        let effectiveResume = resume && destination.supportsAppendResume
        var resumeOffset: UInt64 = 0
        if effectiveResume {
            // … existing body unchanged (stat destination, size heuristic) …
        }
```
(Keep the rest of the method identical; only the `if resume {` → `if effectiveResume {` change and the `let effectiveResume` line.)

- [ ] **Step 5: Gate the queue's resume offer.** In `TransferQueueViewModel.swift`, where an interrupted transfer is classified/retained as resumable (the `.interrupted` status, ~lines 55-76 and `retryInterrupted`), only treat a connection-loss as `.interrupted` (resumable) when the destination reports `supportsAppendResume`; otherwise classify it as `.failed` (a plain retry re-uploads from scratch). The item already holds its destination FS for the transfer; read `destinationFileSystem.supportsAppendResume` at the classification site. Add a one-line English comment referencing M13. (If the destination FS is not directly reachable at the classification site, thread the boolean in when the item is constructed — do not restructure the queue.)

- [ ] **Step 6: Run green + full.** `swift test --filter TransferEngine` → PASS; `swift test` → all green (baseline 957/70; +≥1).

- [ ] **Step 7: Commit.**
```bash
git add Sources/macSCPCore/RemoteFS/RemoteFileSystem.swift Sources/macSCPCore/S3/S3FileSystem.swift Sources/macSCPCore/RemoteFS/TransferEngine.swift Sources/macSCPCore/Presentation/TransferQueueViewModel.swift Tests/macSCPCoreTests/TransferEngineTests.swift Tests/macSCPCoreTests/S3FileSystemTests.swift
git commit -m "feat: never append-resume to a non-appendable destination"
```

---

### Task 2: Streaming download transport (`sendStreaming`) + fake

**Files:**
- Modify: `Sources/macSCPCore/S3/S3HTTPTransport.swift` (protocol + `URLSessionS3Transport`)
- Test: `Tests/macSCPCoreTests/S3FileSystemTests.swift` (extend `FakeS3Transport`; add a small transport test)

**Interfaces:**
- Produces: `func sendStreaming(_ request: URLRequest) async throws -> (body: AsyncThrowingStream<Data, Error>, response: HTTPURLResponse)` on `S3HTTPTransport`; `URLSessionS3Transport` implements it via `URLSession.bytes(for:)`, chunking into `TransferChunk.size` `Data` blocks. `FakeS3Transport` gains a canned-stream path.

- [ ] **Step 1: Extend the protocol + fake first (compile-driven).** Add to `S3HTTPTransport`:
```swift
    /// Streams a (large) response body instead of buffering it — for object
    /// downloads. The response headers/status are available immediately; the
    /// body arrives as `TransferChunk.size` chunks. Non-2xx statuses are the
    /// CALLER's to map (see `S3FileSystem.readStream`) — this only transports.
    func sendStreaming(_ request: URLRequest) async throws
        -> (body: AsyncThrowingStream<Data, Error>, response: HTTPURLResponse)
```
Implement on `URLSessionS3Transport`:
```swift
    public func sendStreaming(_ request: URLRequest) async throws
        -> (body: AsyncThrowingStream<Data, Error>, response: HTTPURLResponse) {
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw RemoteFSError.protocolError(reason: "S3 transport received a non-HTTP response")
        }
        let stream = AsyncThrowingStream<Data, Error> { continuation in
            let task = Task {
                do {
                    var buffer = Data(); buffer.reserveCapacity(TransferChunk.size)
                    for try await byte in bytes {
                        buffer.append(byte)
                        if buffer.count >= TransferChunk.size {
                            continuation.yield(buffer); buffer.removeAll(keepingCapacity: true)
                        }
                    }
                    if !buffer.isEmpty { continuation.yield(buffer) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        return (stream, http)
    }
```

- [ ] **Step 2: Give the fake a streaming path.** Extend `FakeS3Transport` so a queued response can be delivered as a stream. Simplest: add a parallel FIFO `streamingResponses: [(Data, HTTPURLResponse)]` (or reuse `responses`) and implement:
```swift
    func sendStreaming(_ request: URLRequest) async throws
        -> (body: AsyncThrowingStream<Data, Error>, response: HTTPURLResponse) {
        requests.append(request)
        guard !responses.isEmpty else {
            throw RemoteFSError.protocolError(reason: "FakeS3Transport ran out of canned responses")
        }
        let (data, response) = responses.removeFirst()
        let stream = AsyncThrowingStream<Data, Error> { c in
            // Emit the canned body in <= TransferChunk.size slices so tests see chunking.
            var offset = 0
            while offset < data.count {
                let end = min(offset + TransferChunk.size, data.count)
                c.yield(data.subdata(in: offset..<end)); offset = end
            }
            c.finish()
        }
        return (stream, response)
    }
```
Also give `ThrowingS3Transport` a `sendStreaming` that throws, so it still conforms.

- [ ] **Step 3: Run build/tests.** `swift build` clean; `swift test --filter S3FileSystem` still PASS (existing tests unaffected; the protocol grew but all conformers implement it).

- [ ] **Step 4: Commit.**
```bash
git add Sources/macSCPCore/S3/S3HTTPTransport.swift Tests/macSCPCoreTests/S3FileSystemTests.swift
git commit -m "feat: add a streaming download path to the S3 transport"
```

---

### Task 3: Signed-request helper + streaming `readStream`

**Files:**
- Modify: `Sources/macSCPCore/S3/S3FileSystem.swift`
- Test: `Tests/macSCPCoreTests/S3FileSystemTests.swift`

**Interfaces:**
- Produces: private `func buildSignedRequest(method: String, key: String, query: [(name: String, value: String)], extraHeaders: [String: String], body: Data?, payloadHash: String) throws -> URLRequest` (generalizes `buildListRequest`). Real `readStream(path:fromOffset:)`.
- Consumes: `transport.sendStreaming` (Task 2).

- [ ] **Step 1: Failing test — range download streams object bytes; offset≥EOF is empty.**
```swift
@Test func readStreamRequestsRangeAndYieldsChunkedBytes() async throws {
    let body = Data((0..<(TransferChunk.size + 10)).map { UInt8($0 & 0xFF) })
    let (fs, transport) = try await connect(responses: [(body, httpResponse(status: 206))])
    var received = Data()
    for try await chunk in try await fs.readStream(path: "/big.bin", fromOffset: 5) {
        received.append(chunk)
    }
    #expect(received == body)                              // fake echoes the canned body
    let req = await transport.requests.last!
    #expect(req.value(forHTTPHeaderField: "Range") == "bytes=5-")
    #expect(req.httpMethod == "GET")
}

@Test func readStreamBeyondEOFYieldsEmptyStream() async throws {
    // S3 answers a range past EOF with 416; map to an empty stream, no error.
    let (fs, _) = try await connect(responses: [(Data(), httpResponse(status: 416))])
    var count = 0
    for try await _ in try await fs.readStream(path: "/x", fromOffset: 999) { count += 1 }
    #expect(count == 0)
}
```

- [ ] **Step 2: Run red.** `swift test --filter S3FileSystem` → FAIL (readStream throws `.protocolError`).

- [ ] **Step 3: Add `buildSignedRequest` + `keyRequestURL`.** Refactor the existing URL/host/signing logic out of `buildListRequest` into a shared helper. Add a static `keyRequestURL(config:key:query:)` that builds the path- or virtual-host URL for an OBJECT key (path-style: `/{bucket}/{key}`; virtual-host: host `{bucket}.{host}`, path `/{key}`), percent-encoding each key segment via the signer's canonical URI rules but leaving `/` literal, and setting `percentEncodedQuery = SigV4Signer.canonicalQueryString(query:)`. Then:
```swift
    private func buildSignedRequest(
        method: String, key: String, query: [(name: String, value: String)],
        extraHeaders: [String: String] = [:], body: Data? = nil,
        payloadHash: String
    ) throws -> URLRequest {
        let url = try Self.keyRequestURL(config: config, key: key, queryPairs: query)
        guard let host = url.host else {
            throw RemoteFSError.connectionFailed(reason: "S3 endpoint has no host: \(config.endpoint)")
        }
        let hostHeader = url.port.map { "\(host):\($0)" } ?? host
        let canonicalPath = url.path.isEmpty ? "/" : url.path
        var headers = extraHeaders
        headers["host"] = hostHeader
        let signer = SigV4Signer(accessKeyID: config.accessKeyID, secretAccessKey: config.secretAccessKey,
            region: config.region, service: "s3", sessionToken: config.sessionToken)
        let (authorization, signed) = signer.authorizationHeader(
            method: method, host: hostHeader, path: canonicalPath, query: query,
            headers: headers, payloadHash: payloadHash, date: Date())
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(hostHeader, forHTTPHeaderField: "Host")
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        for (k, v) in signed { request.setValue(v, forHTTPHeaderField: k) }
        for (k, v) in extraHeaders { request.setValue(v, forHTTPHeaderField: k) }
        if let body { request.httpBody = body }
        return request
    }
```
IMPORTANT: `extraHeaders` passed to the signer MUST be the ones you want SIGNED (e.g. `x-amz-copy-source`, `Range` is NOT signed by convention — do NOT sign `Range`; pass it only as a request header, not into `headers`). Note: keep `buildListRequest` working by re-expressing it through `keyRequestURL`/the signer, or leave it as-is and only ADD the new helper — either is fine as long as list still passes.

- [ ] **Step 4: Implement `readStream`.**
```swift
    public func readStream(path: String, fromOffset offset: UInt64) async throws -> AsyncThrowingStream<Data, Error> {
        let key = Self.objectKey(forPath: path)   // no leading slash, no trailing slash
        var request = try buildSignedRequest(method: "GET", key: key, query: [], payloadHash: SigV4Signer.emptyPayloadHash)
        request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range")   // unsigned, added after signing
        let (body, response) = try await transport.sendStreaming(request)
        switch response.statusCode {
        case 200..<300: return body
        case 416: return AsyncThrowingStream { $0.finish() }   // range past EOF → empty
        case 403: throw RemoteFSError.authenticationFailed
        case 404: throw RemoteFSError.notFound(path: path)
        default: throw RemoteFSError.protocolError(reason: "S3 download failed with HTTP status \(response.statusCode)")
        }
    }
```
Add `static func objectKey(forPath:)` (like `s3Prefix` but WITHOUT the trailing slash — a file key). Note the `Range` header is set on the request AFTER `buildSignedRequest` returns, so it is not part of the signed headers (matches AWS: `Range` need not be signed).

- [ ] **Step 5: Run green + full.** `swift test --filter S3FileSystem` PASS; `swift build` clean.

- [ ] **Step 6: Commit.**
```bash
git add Sources/macSCPCore/S3/S3FileSystem.swift Tests/macSCPCoreTests/S3FileSystemTests.swift
git commit -m "feat: stream S3 object downloads with a range GET"
```

---

### Task 4: `delete` + `createDirectory` (0-byte marker)

**Files:**
- Modify: `Sources/macSCPCore/S3/S3FileSystem.swift`
- Test: `Tests/macSCPCoreTests/S3FileSystemTests.swift`

**Interfaces:**
- Consumes: `buildSignedRequest` (Task 3), `transport.send`.

- [ ] **Step 1: Failing tests.**
```swift
@Test func deleteSendsDeleteForTheObjectKey() async throws {
    let (fs, transport) = try await connect(responses: [(Data(), httpResponse(status: 204))])
    try await fs.delete(path: "/dir/file.txt")
    let req = await transport.requests.last!
    #expect(req.httpMethod == "DELETE")
    #expect(req.url!.path.hasSuffix("/dir/file.txt"))
}

@Test func createDirectoryPutsAZeroByteMarkerKey() async throws {
    let (fs, transport) = try await connect(responses: [(Data(), httpResponse(status: 200))])
    try await fs.createDirectory(at: "/newfolder")
    let req = await transport.requests.last!
    #expect(req.httpMethod == "PUT")
    #expect(req.url!.path.hasSuffix("/newfolder/"))   // trailing slash = folder marker
    #expect((req.httpBody?.count ?? 0) == 0)
}
```

- [ ] **Step 2: Run red.** FAIL (both throw `.protocolError`).

- [ ] **Step 3: Implement.**
```swift
    public func delete(path: String) async throws {
        let request = try buildSignedRequest(method: "DELETE", key: Self.objectKey(forPath: path),
            query: [], payloadHash: SigV4Signer.emptyPayloadHash)
        try await sendExpectingSuccess(request, path: path)   // maps non-2xx like fetchPage
    }

    public func createDirectory(at path: String) async throws {
        // 0-byte marker object whose key ends in "/" — the universal S3
        // empty-folder convention. Idempotent: re-PUT is harmless.
        let markerKey = Self.objectKey(forPath: path) + "/"
        let request = try buildSignedRequest(method: "PUT", key: markerKey, query: [],
            body: Data(), payloadHash: SigV4Signer.emptyPayloadHash)
        try await sendExpectingSuccess(request, path: path)
    }
```
Add a private `sendExpectingSuccess(_:path:)` that calls `transport.send`, maps transport errors to `.connectionFailed`, and maps status 2xx → ok / 403 → `.authenticationFailed` / 404 → `.notFound(path:)` / other → `.protocolError`. (Extract the mapping already inline in `fetchPage` so both share it — DRY.)

- [ ] **Step 4: Run green.** PASS.

- [ ] **Step 5: Commit.**
```bash
git add Sources/macSCPCore/S3/S3FileSystem.swift Tests/macSCPCoreTests/S3FileSystemTests.swift
git commit -m "feat: implement S3 delete and create-directory (marker object)"
```

---

### Task 5: `S3Uploader` single-PUT + `write` wiring

**Files:**
- Create: `Sources/macSCPCore/S3/S3Uploader.swift`
- Modify: `Sources/macSCPCore/S3/S3FileSystem.swift` (`write` delegates)
- Test: `Tests/macSCPCoreTests/S3UploaderTests.swift`

**Interfaces:**
- Produces: `struct S3Uploader` with `static let singlePutThreshold = 8 * 1024 * 1024` and `func upload(key: String, contents: AsyncThrowingStream<Data, Error>, using fs: S3RequestBuilder) async throws`. To keep `S3Uploader` testable without the whole `S3FileSystem`, define a small internal seam `protocol S3RequestBuilder` that `S3FileSystem` conforms to, exposing exactly what the uploader needs: `func signedRequest(method:key:query:extraHeaders:body:payloadHash:) throws -> URLRequest` and `func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)`. (Thin wrappers over `buildSignedRequest` + `transport.send`.)

- [ ] **Step 1: Failing test — a below-threshold stream becomes ONE signed PUT with a real sha256.**
```swift
@Test func smallUploadIsASinglePut() async throws {
    let body = Data(repeating: 0x42, count: 1024)
    let builder = FakeRequestBuilder(responses: [(Data(), http(200))])
    let uploader = S3Uploader()
    try await uploader.upload(key: "dir/small.bin", contents: stream(of: [body]), using: builder)
    #expect(builder.performed.count == 1)
    let req = builder.performed[0]
    #expect(req.httpMethod == "PUT")
    #expect(req.httpBody == body)
    // payloadHash was the real sha256 of the body (not UNSIGNED-PAYLOAD)
    #expect(builder.lastPayloadHash == sha256Hex(body))
}
```
(`FakeRequestBuilder` records `signedRequest` calls incl. the `payloadHash` and returns canned `perform` responses. `stream(of:)` wraps `[Data]` in an `AsyncThrowingStream`. `sha256Hex` uses `Crypto.SHA256`.)

- [ ] **Step 2: Run red.** `swift test --filter S3Uploader` → FAIL.

- [ ] **Step 3: Implement the single-PUT path.** In `S3Uploader.upload`: pull from the stream into a buffer; if the stream ENDS at or below `singlePutThreshold`, do one PUT:
```swift
    let payloadHash = SigV4Signer.hexSHA256Public(buffer)   // real content hash
    let request = try builder.signedRequest(method: "PUT", key: key, query: [],
        extraHeaders: [:], body: buffer, payloadHash: payloadHash)
    let (_, response) = try await builder.perform(request)
    guard (200..<300).contains(response.statusCode) else {
        throw Self.mapStatus(response.statusCode, key: key)
    }
```
(You'll need a public/internal SHA-256 hex helper. Either widen a `SigV4Signer` helper to `internal static func hexSHA256(_:) -> String` — it already has a private `hexSHA256` — or compute inline with `Crypto.SHA256`. Prefer widening the signer's existing helper to avoid a second implementation.) Wire `S3FileSystem.write` (overwrite; `.append` never reaches here because Task 1 forces overwrite for S3):
```swift
    public func write(path: String, mode: WriteMode, contents: AsyncThrowingStream<Data, Error>) async throws {
        try await S3Uploader().upload(key: Self.objectKey(forPath: path), contents: contents, using: self)
    }
```
Make `S3FileSystem` conform to `S3RequestBuilder` (the two thin methods).

- [ ] **Step 4: Run green.** `swift test --filter S3Uploader` PASS; `swift build` clean.

- [ ] **Step 5: Commit.**
```bash
git add Sources/macSCPCore/S3/S3Uploader.swift Sources/macSCPCore/S3/S3FileSystem.swift Tests/macSCPCoreTests/S3UploaderTests.swift
git commit -m "feat: upload small S3 objects with a single signed PUT"
```

---

### Task 6: `S3Uploader` multipart (initiate / upload-part / complete / always-abort)

**Files:**
- Modify: `Sources/macSCPCore/S3/S3Uploader.swift`
- Create: `Sources/macSCPCore/S3/S3MultipartXML.swift` (parse InitiateMultipartUpload; build CompleteMultipartUpload)
- Test: `Tests/macSCPCoreTests/S3UploaderTests.swift`

**Interfaces:**
- Produces: `enum S3MultipartXML { static func parseUploadID(_ data: Data) throws -> String; static func completeBody(parts: [(number: Int, etag: String)]) -> Data }`.

- [ ] **Step 1: Failing tests — over-threshold stream does Initiate → ≥2 UploadPart → Complete; a part failure Aborts.**
```swift
@Test func largeUploadUsesMultipartWithParts() async throws {
    // 20 MiB in 64 KiB chunks → >8 MiB threshold → multipart, parts >=5 MiB.
    let chunks = Array(repeating: Data(repeating: 0x7, count: 64*1024), count: 320) // 20 MiB
    let builder = FakeRequestBuilder(responses: [
        (Data(initiateXML(uploadID: "UP1").utf8), http(200)),   // Initiate
        (Data(), http(200, etag: "\"etag-1\"")),                // UploadPart 1
        (Data(), http(200, etag: "\"etag-2\"")),                // UploadPart 2
        (Data(), http(200, etag: "\"etag-3\"")),                // UploadPart 3
        (Data(), http(200)),                                    // Complete
    ])
    try await S3Uploader().upload(key: "big.bin", contents: stream(of: chunks), using: builder)
    let methods = builder.performed.map { ($0.httpMethod!, $0.url!.query ?? "") }
    #expect(methods.first!.1.contains("uploads"))               // Initiate POST ?uploads
    #expect(methods.contains { $0.1.contains("partNumber=1") && $0.1.contains("uploadId=UP1") })
    #expect(methods.last!.1.contains("uploadId=UP1"))           // Complete POST ?uploadId
    // Complete body lists the collected ETags in part order:
    #expect(String(data: builder.performed.last!.httpBody!, encoding: .utf8)!.contains("etag-1"))
}

@Test func multipartAbortsOnPartFailure() async throws {
    let chunks = Array(repeating: Data(repeating: 1, count: 64*1024), count: 320)
    let builder = FakeRequestBuilder(responses: [
        (Data(initiateXML(uploadID: "UP2").utf8), http(200)),   // Initiate
        (Data(), http(500)),                                    // UploadPart 1 fails
    ])
    await #expect(throws: (any Error).self) {
        try await S3Uploader().upload(key: "big.bin", contents: stream(of: chunks), using: builder)
    }
    // An Abort (DELETE ?uploadId) must have been issued:
    #expect(builder.performed.contains { $0.httpMethod == "DELETE" && ($0.url!.query ?? "").contains("uploadId=UP2") })
}
```
(`initiateXML(uploadID:)` returns `<?xml…><InitiateMultipartUploadResult><UploadId>UP1</UploadId></…>`. `FakeRequestBuilder.perform` returns the canned responses in order; `http(_:etag:)` sets the `ETag` header.)

- [ ] **Step 2: Run red.** FAIL.

- [ ] **Step 3: Implement multipart + XML.** In `upload`, when the buffer first reaches `singlePutThreshold` before the stream ends, switch to multipart:
  1. POST `?uploads` (empty body, `payloadHash = emptyPayloadHash`), parse `UploadId` via `S3MultipartXML.parseUploadID`.
  2. Accumulate the stream into ≥5 MiB parts (the already-buffered bytes are part 1's start); for each full part (and the final remainder) PUT `?partNumber={n}&uploadId={id}` with `x-amz-content-sha256: UNSIGNED-PAYLOAD` (pass `payloadHash: "UNSIGNED-PAYLOAD"` — the signer treats it as the literal content-sha256 header value and canonical hash); read the `ETag` response header, collect `(n, etag)`.
  3. POST `?uploadId={id}` with `S3MultipartXML.completeBody(parts:)`.
  4. Wrap steps 2-3 in `do { } catch { try? await abort(uploadID:key:builder:); throw error }` where `abort` sends DELETE `?uploadId={id}`. Also `Task.checkCancellation()` before each part (a cancel therefore also aborts).
  Constants: `partSize = 8 * 1024 * 1024` (≥ the 5 MiB S3 minimum). `S3MultipartXML.completeBody` emits:
```xml
<CompleteMultipartUpload><Part><PartNumber>1</PartNumber><ETag>"etag-1"</ETag></Part>…</CompleteMultipartUpload>
```
  (ETags are echoed verbatim including their quotes.)

- [ ] **Step 4: Run green.** `swift test --filter S3Uploader` PASS; `swift build` clean.

- [ ] **Step 5: Commit.**
```bash
git add Sources/macSCPCore/S3/S3Uploader.swift Sources/macSCPCore/S3/S3MultipartXML.swift Tests/macSCPCoreTests/S3UploaderTests.swift
git commit -m "feat: upload large S3 objects via multipart with abort-on-failure"
```

---

### Task 7: `rename` — file (copy+delete, stat precheck) + directory re-key

**Files:**
- Modify: `Sources/macSCPCore/S3/S3FileSystem.swift`
- Test: `Tests/macSCPCoreTests/S3FileSystemTests.swift`

**Interfaces:**
- Produces: real `rename(from:to:)`; private `allObjectKeys(underPrefix:) async throws -> [String]` (recursive, NO delimiter, FULL keys) used here and by Task 8.

- [ ] **Step 1: Failing tests.**
```swift
@Test func renameFileCopiesThenDeletesAndPrechecksDestination() async throws {
    let (fs, transport) = try await connect(responses: [
        (Data(), httpResponse(status: 404)),   // stat(to) via a parent-list → not found (free to proceed)
        (Data(), httpResponse(status: 200)),   // PUT copy
        (Data(), httpResponse(status: 204)),   // DELETE source
    ])
    try await fs.rename(from: "/a.txt", to: "/b.txt")
    let copy = await transport.requests.first { $0.httpMethod == "PUT" }!
    #expect(copy.value(forHTTPHeaderField: "x-amz-copy-source")!.contains("/a.txt"))
    #expect(await transport.requests.contains { $0.httpMethod == "DELETE" })
}
```
(For the stat-precheck the fake needs a listing response that does NOT contain `b.txt`; model it with an empty `<ListBucketResult>`; adjust the canned sequence to match how `stat` lists the parent. Keep the assertion on the copy-source header + a DELETE being issued.)

- [ ] **Step 2: Run red.** FAIL.

- [ ] **Step 3: Implement.**
```swift
    public func rename(from: String, to: String) async throws {
        // No silent overwrite (protocol contract): S3 PUT-copy WOULD overwrite,
        // so check the destination up front.
        if (try? await stat(path: to)) != nil {
            throw RemoteFSError.protocolError(reason: "Destination already exists: \(to)")
        }
        let fromKind = try await stat(path: from).kind
        if fromKind == .directory {
            let fromPrefix = Self.s3Prefix(forPath: from)
            let toPrefix = Self.s3Prefix(forPath: to)
            for key in try await allObjectKeys(underPrefix: fromPrefix) {
                let destKey = toPrefix + key.dropFirst(fromPrefix.count)
                try await copyObject(fromKey: key, toKey: String(destKey))
                try await delete(key: key)
            }
        } else {
            try await copyObject(fromKey: Self.objectKey(forPath: from), toKey: Self.objectKey(forPath: to))
            try await delete(key: Self.objectKey(forPath: from))
        }
    }
```
`copyObject(fromKey:toKey:)` = PUT `{toKey}` with signed header `x-amz-copy-source: /{bucket}/{rfc3986(fromKey)}`, empty body, `payloadHash = emptyPayloadHash` (the copy-source header MUST be signed — pass it in the `extraHeaders` that go to the signer). Add a `delete(key:)` overload that deletes a raw key (the existing public `delete(path:)` can delegate to it). `allObjectKeys(underPrefix:)` pages `ListObjectsV2` WITHOUT `delimiter`, collecting every `<Key>` (a raw-key list — do NOT reuse the leaf-stripping browser `list`; parse `<Contents><Key>` directly, or add a raw variant to `S3ListParser`).

- [ ] **Step 4: Run green.** PASS. `swift build` clean.

- [ ] **Step 5: Commit.**
```bash
git add Sources/macSCPCore/S3/S3FileSystem.swift Tests/macSCPCoreTests/S3FileSystemTests.swift
git commit -m "feat: rename S3 objects and prefixes via copy-and-delete"
```

---

### Task 8: `deleteTree` — recursive list + batched DeleteObjects

**Files:**
- Modify: `Sources/macSCPCore/S3/S3FileSystem.swift`
- Test: `Tests/macSCPCoreTests/S3FileSystemTests.swift`

**Interfaces:**
- Consumes: `allObjectKeys(underPrefix:)` (Task 7), `import Crypto` for `Insecure.MD5`.

- [ ] **Step 1: Failing test.**
```swift
@Test func deleteTreeBatchesDeleteObjectsWithContentMD5() async throws {
    // A listing with 3 keys under the prefix, then one DeleteObjects response.
    let (fs, transport) = try await connect(responses: [
        (Data(listingWithKeys(["d/", "d/a", "d/b"]).utf8), httpResponse(status: 200)),
        (Data("<DeleteResult></DeleteResult>".utf8), httpResponse(status: 200)),
    ])
    try await fs.deleteTree(at: "/d")
    let del = await transport.requests.last!
    #expect(del.httpMethod == "POST")
    #expect((del.url!.query ?? "").contains("delete"))
    #expect(del.value(forHTTPHeaderField: "Content-MD5") != nil)   // required by S3 for this call
    let bodyXML = String(data: del.httpBody!, encoding: .utf8)!
    #expect(bodyXML.contains("<Key>d/a</Key>") && bodyXML.contains("<Key>d/</Key>"))
}
```

- [ ] **Step 2: Run red.** FAIL.

- [ ] **Step 3: Implement.**
```swift
    public func deleteTree(at path: String) async throws {
        let keys = try await allObjectKeys(underPrefix: Self.s3Prefix(forPath: path))
        // A plain file (no trailing-slash prefix) still resolves through its
        // own key; treat an empty result as a single-object delete fallback.
        for batch in keys.chunked(into: 1000) {          // S3 DeleteObjects max 1000
            try Task.checkCancellation()
            let body = Self.deleteObjectsXML(keys: batch)
            let md5 = Data(Insecure.MD5.hash(data: body)).base64EncodedString()
            let request = try buildSignedRequest(method: "POST", key: "",
                query: [(name: "delete", value: "")],
                extraHeaders: ["Content-MD5": md5],       // Content-MD5 is signed here
                body: body, payloadHash: SigV4Signer.hexSHA256Public(body))
            try await sendExpectingSuccess(request, path: path)
        }
    }
```
`deleteObjectsXML(keys:)` → `<Delete>` + `<Object><Key>…</Key></Object>` per key + `</Delete>` (keys XML-escaped). `key: ""` on `buildSignedRequest` targets the bucket root (path-style `/{bucket}?delete`); verify `keyRequestURL` yields the bucket URL for an empty key. Add a small `Array.chunked(into:)` helper (or inline). `Content-MD5` MUST be in the signed headers (it is part of the canonical request for DeleteObjects).

- [ ] **Step 4: Run green.** PASS. `swift build` clean.

- [ ] **Step 5: Commit.**
```bash
git add Sources/macSCPCore/S3/S3FileSystem.swift Tests/macSCPCoreTests/S3FileSystemTests.swift
git commit -m "feat: delete S3 trees with batched DeleteObjects"
```

---

### Task 9: Coordinator — gated MinIO integration + whole-milestone verification

**Files:**
- Modify: `Tests/macSCPCoreTests/S3FileSystemIntegrationTests.swift`

- [ ] **Step 1: Add gated MinIO CRUD/transfer tests.** In the `.enabled(if: MACSCP_ITEST)` suite, add (each cleaning up its own keys under a unique per-test prefix so re-runs stay reproducible):
  - `uploadThenDownloadRoundTripsSmallObject` — write a few KiB via `TransferEngine.copyFile` (local→S3), read it back (S3→local or `readStream`), assert bit-identical.
  - `uploadThenDownloadRoundTripsMultipartObject` — a >8 MiB payload, exercising the real multipart path; assert bit-identical.
  - `createDirectoryThenListShowsFolder` — `createDirectory`, then `list("/")` contains the folder.
  - `renameFileMovesTheObject` and `renameFolderRekeysAllObjects`.
  - `deleteTreeRemovesEveryKeyUnderThePrefix`.

- [ ] **Step 2: Bring rigs up + run gated (coordinator).**
```bash
docker compose -f docker/test-server/compose.yml up -d minio minio-init sshd sshd2
MACSCP_ITEST=1 MACSCP_KEYCHAIN=1 swift test 2>&1 | tail -5
```
Expected: all green, the `S3FileSystem against Docker MinIO` suite RUNS the new cases and passes, zero real skips.

- [ ] **Step 3: Build + ungated + smoke.** `swift build` clean (no new warnings); `swift test` green. Package the dev app (`MACSCP_VERSION=1.3.0-dev scripts/package-app` → codesign → xattr → open → `ps -o %cpu` idle ~0% → kill) — no GUI change expected, but confirm nothing regressed at launch.

- [ ] **Step 4: Whole-milestone review.** `scripts/review-package <M13-base> HEAD` on the most-capable model. Focus: (a) `readStream`/`write` correctness incl. multipart abort-on-failure (no orphaned upload); (b) the resume-guard truly prevents an append tail to S3 (the corruption case); (c) secret never in logs/JSON; (d) SSH/local transfer paths unchanged (regression); (e) rename destination-precheck honors no-silent-overwrite; (f) `Content-MD5`/signing on DeleteObjects; (g) `sendStreaming` cancels the URLSession byte task on stream termination (no leaked task). Fix rounds until "Ready to merge: Yes".

- [ ] **Step 5: Finish.** Tick this plan, update the ledger + roadmap memory, commit docs, push `develop`, `gh run watch`, redeploy the dev build. **No release/tag.**

---

## Self-Review

**Spec coverage:** readStream (T3), write single+multipart (T5/T6), delete + createDirectory (T4), rename file+folder (T7), deleteTree (T8), transport streaming (T2), resume-guard + `supportsAppendResume` (T1), gated MinIO + review (T9), secret hygiene + no-new-dependency + abort-on-failure (Global Constraints, enforced per task). ✅ All spec sections map to a task.

**Type consistency:** `supportsAppendResume` (T1) consumed nowhere else by name mismatch; `buildSignedRequest`/`keyRequestURL`/`objectKey(forPath:)` defined T3, reused T4/T7/T8; `S3RequestBuilder` seam defined T5, extended for multipart T6; `allObjectKeys(underPrefix:)` defined T7, reused T8; `sendExpectingSuccess`/`mapStatus` DRY across T4/T5/T8. `hexSHA256Public` (widened signer helper) introduced T5, reused T8 — implementer widens `SigV4Signer`'s existing private `hexSHA256` to internal in T5. ✅

**Placeholder scan:** no TBD/TODO; every code step carries real code or a precise, bounded instruction (e.g. the exact S3 XML shapes, the exact headers to sign vs. not sign). The few "adjust the canned sequence to match how `stat` lists the parent" notes are test-fixture calibration against real, already-existing code the implementer can read — not logic placeholders. ✅

---

## Abschluss M13 (2026-08-01)

**Alle 8 Tasks umgesetzt, jeweils Task-Review + Fix-Runden sauber.** Kern-Lektion
des Meilensteins: **Fake-Transport-Unit-Tests validieren die SigV4-Signatur
NICHT** — ein Signatur-Bug (Task 4: `URL.path` verschluckt den Trailing-Slash
des Ordner-Markers → SignatureDoesNotMatch) wurde NUR durch einen echten
MinIO-Test gefangen. Konsequenz: jede signier-berührende Task
(createDirectory, Upload, rename, deleteTree) wurde ab da **zur Task-Zeit gated
gegen echtes MinIO** verifiziert, nicht erst im Abschluss.

**Verifikation:**
- Voller gated Lauf `MACSCP_ITEST=1 MACSCP_KEYCHAIN=1 swift test` → 982/71 grün;
  die MinIO-Suite lief mit allen 6 M13-Gated-Tests (createDirectory,
  Upload/Download-Roundtrip klein + Multipart >8 MiB, Rename Datei + Ordner,
  deleteTree) plus SSH-Integration, CitadelShell, KeychainSecretStore — zero
  echte Skips. `swift build` sauber (0 Warnungen).
- **Whole-Milestone Opus-Review: „Ready to merge: Yes"** — (a)–(g) alle
  bestanden (Resume-Sperre byte-gleich für SSH/local; Multipart-Abort auf jedem
  Fehlerpfad; canonicalKeyPath-Signatur korrekt + für non-empty Keys
  unverändert; kein Silent-Overwrite/Datenverlust bei rename/copy/deleteTree;
  Secret nur im Signer; Cancellation pro Teil/Batch; keine neue Dependency;
  keine `if kind ==`-Verunreinigung).

**Implementierte S3-Operationen:** `readStream` (Range-GET, gestreamt),
`write` (Hybrid single-PUT ≤8 MiB / Multipart >8 MiB mit Abort), `delete`,
`createDirectory` (0-Byte-Marker), `rename` (Datei copy+delete mit
Precheck; Ordner re-key), `deleteTree` (DeleteObjects-Batches). `setPermissions`
bleibt bewusst `protocolError` (kein POSIX). Resume-Sperre: `supportsAppendResume`
(S3 false) + Engine-Guard verhindert Append-Korruption gegen S3-Ziele.

**Offen (bewusst, kein Blocker):** Maintainer-Sichtprüfung (echtes S3-Browsen +
Transfer im UI) steht aus (offline). Kleinere Ledger-Minors: Multipart-Unit-Test
prüft nur Teil 1 (live-Multipart-Test kompensiert), kein dedizierter
S3MultipartXML-Unit-Test, `parseObjectKeys` dupliziert S3ListParser (~40 Zeilen),
`<Error`-Partial-Failure ist Substring-Check, kein `<Quiet>` in DeleteObjects,
`sendStreaming` ohne explizites `onCancel` (relevant erst bei echtem
Download-Cancel).

**Grenzen:** Cross-Backend S3↔SSH-Transfer + Presigned-URLs = **M14**.
**KEIN Release.**
