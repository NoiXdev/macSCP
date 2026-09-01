# M13 — S3 Transfer/CRUD Design

**Status:** approved (brainstorming 2026-08-01)
**Milestone:** M13
**Language:** design doc EN; code/comments EN; no new UI strings expected
(the error/action texts already exist backend-agnostic from M5/M7).

## Goal

Actually implement the mutating `S3FileSystem` operations stubbed in M12, so
that an S3 backend can transfer and do CRUD fully in the browser:
**download (`readStream`), upload (`write`), `delete`,
`createDirectory`, `rename`, `deleteTree`**. `setPermissions` deliberately
stays `protocolError` (S3 has no POSIX permission model — the capability
`permissionModel == .none` hides the editor anyway).

Validated against the real MinIO rig (`http://127.0.0.1:19000`, bucket
`macscp-seed`) and through the existing `SigV4Signer`. **No new
dependency** (Foundation `URLSession`/`XMLParser` + swift-crypto via the
signer).

**Not in M13:** cross-backend transfer S3↔SSH (the engine is
backend-agnostic — after M13 it in principle runs "for free", the
*explicit* gated verification + double-throttle hardening is **M14**);
presigned URLs (M14); real upload resume (S3 structurally cannot do it,
see §6).

## Starting point (as-is)

`S3FileSystem` (M12/T5) has real, signed `connect`/`list`/`stat`
(ListObjectsV2); all mutating methods throw
`RemoteFSError.protocolError`. `SigV4Signer.authorizationHeader(method:host:
path:query:headers:payloadHash:date:)` already carries arbitrary methods +
payload hash (the static `canonicalQueryString` is `internal`, single
source). `S3HTTPTransport.send(_:) -> (Data, HTTPURLResponse)` only
delivers **buffered**. `TransferEngine.copyFile(from:…:resume:…)` drives
`source.stat().size` → `source.readStream(fromOffset:)` → `destination.write(
mode:contents:)`; `resume` is an **opt-in flag** of the caller.

## S3 API mapping

| `RemoteFileSystem` | S3 operation |
|---|---|
| `readStream(path:fromOffset:)` | `GET {key}` with `Range: bytes={offset}-`, streamed; offset ≥ EOF → empty stream (no error) |
| `write(overwrite)` | hybrid: ≤ threshold → single `PUT {key}`; otherwise multipart |
| `write(append)` | structurally impossible for an S3 target → never triggered by the engine lock (§6) |
| `delete(path:)` | `DELETE {key}` (single object; file contract) |
| `createDirectory(at:)` | `PUT {key}/` with 0-byte body (marker object), idempotent |
| `rename(from:to:)` (file) | `PUT {toKey}` with `x-amz-copy-source: /{bucket}/{fromKey}` (URL-encoded) + `DELETE {fromKey}` |
| `rename(from:to:)` (folder) | copy+delete for **every** object under the prefix (including the marker); not atomic, O(N) |
| `deleteTree(at:)` | list recursively (no delimiter) → `POST {bucket}?delete` (DeleteObjects) in batches of ≤1000; marker included |
| `setPermissions` | still `protocolError` (no POSIX) |
| `homeDirectoryPath` | `"/"` (unchanged) |

Key derivation uses the existing `S3FileSystem.s3Prefix(forPath:)` logic
(no leading slash; object key without, "directory" key with `/` suffix).

## Architecture / components

### 1. Transport seam (`S3HTTPTransport`)

Grows by **exactly one** method for streamed downloads:

```swift
public protocol S3HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
    func sendStreaming(_ request: URLRequest) async throws
        -> (body: AsyncThrowingStream<Data, Error>, response: HTTPURLResponse)
}
```

- `URLSessionS3Transport.sendStreaming` uses `URLSession.bytes(for:)`,
  reads the `AsyncBytes`, and emits `TransferChunk.size`-sized `Data`
  chunks as an `AsyncThrowingStream`. Non-2xx is mapped to a
  `RemoteFSError` BEFORE streaming begins (403/404/otherwise), so errors
  do not first surface in the stream consumer.
- **Uploads need no new seam**: the `URLRequest` carries `httpBody`
  (the buffered small file, or the buffered multipart part), the
  existing `send` suffices (responses are small: ETag/XML).
- `FakeS3Transport` (tests) implements both paths — `sendStreaming` returns
  a canonical byte stream from canned `Data`.

### 2. Upload (`S3Uploader`, new file `Sources/macSCPCore/S3/S3Uploader.swift`)

A focused uploader that `S3FileSystem.write` calls. Encapsulates the
hybrid decision and the multipart lifecycle.

- **Threshold: 8 MiB** (`partSize`/`singlePutThreshold`, a constant). Buffers
  from the chunk stream up to the threshold:
  - Stream ends before the threshold → **single `PUT {key}`** with
    `x-amz-content-sha256 = hex(sha256(body))` (the body is fully
    present, so a real signature; `Content-Length` set).
  - Threshold reached → **multipart**:
    1. `POST {key}?uploads` → `UploadId` from the XML (`InitiateMultipartUpload`).
    2. per part `PUT {key}?partNumber={n}&uploadId={id}` with the buffered
       part (≥5 MiB except the last), `x-amz-content-sha256: UNSIGNED-PAYLOAD`;
       collect `ETag` from the response header (part number → ETag).
    3. `POST {key}?uploadId={id}` with `CompleteMultipartUpload` XML (sorted
       `<Part><PartNumber><ETag>`).
- **Abort/error**: every error after `Initiate` (including
  `CancellationError`) **always** triggers `DELETE {key}?uploadId={id}`
  (`AbortMultipartUpload`) before the error is propagated — no orphaned
  multipart upload, which would otherwise cost storage/money.
- `Task.checkCancellation()` before each part.
- 5 MiB is the S3 minimum per part (except the last); the 8 MiB threshold
  sits deliberately above that, so a multipart can always form ≥2 valid
  parts.

### 3. Download (`S3FileSystem.readStream`)

Builds the signed range GET (`Range: bytes={offset}-`), calls
`transport.sendStreaming`, passes its body stream through (already cut
into `TransferChunk.size` pieces). Offset ≥ object size → S3 responds 416
(or empty); mapped to an **empty** stream (no error — the protocol
contract requires "offset at or beyond EOF yields an empty stream").
Signature with `payloadHash = emptyPayloadHash` (GET has no body).

### 4. CRUD operations (`S3FileSystem`)

- `delete`: signed `DELETE {key}`; 204/200 → ok, 404 → `.notFound`.
- `createDirectory`: signed `PUT {key}/` with empty body
  (`payloadHash = emptyPayloadHash`), idempotent (creating it again is ok).
- `rename` (file): `PUT {toKey}` with `x-amz-copy-source` header (value
  `/{bucket}/{fromKey}`, RFC 3986 encoded), empty body; then
  `DELETE {fromKey}`. **S3 PUT-copy silently overwrites** — so `rename`
  actively checks the target's existence **beforehand** (`stat {toKey}`;
  found → `RemoteFSError` instead of silently overwriting, protocol
  contract). Since `stat` also knows the kind, `S3FileSystem` decides the
  file vs. folder path.
- `rename` (folder): recursively list all keys under `fromPrefix`, for each
  `copy {from} → {to}` (prefix substitution) + `delete {from}`; including the
  `…/` marker. Not atomic (documented); a partial failure leaves already
  copied objects standing at the target (no rollback — v1, documented).
- `deleteTree`: recursively (without delimiter) list all keys under the
  prefix, delete in batches of ≤1000 via `POST {bucket}?delete`
  (DeleteObjects XML with `Content-MD5`, which the S3 API requires here);
  marker included. Cooperatively cancellable per batch; a cancellation
  leaves a partially deleted tree standing (like Citadel/Local, documented).

### 5. Signing with a body

`buildSignedRequest(method:key:query:headers:body:payloadHash:)` helper in
`S3FileSystem` (a generalization of the existing `buildListRequest`): builds
the URL (path- vs. virtual-host style), signs with the given `payloadHash`,
sets `httpBody` when present. `Content-Length` follows from `httpBody`.
Wire query still goes through `SigV4Signer.canonicalQueryString` (the I-1
fix from M12 remains the single source of query encoding).

### 6. Resume lock (Core hardening — security-critical for correctness)

S3 cannot do `.append`. The engine must **never** append a tail against an
S3 target (otherwise an existing object of a different size at the same
key would be corrupted).

- New on the protocol: `var supportsAppendResume: Bool { get }` with a
  default extension of `true`. `LocalFileSystem`/`CitadelFileSystem` inherit
  `true`; `S3FileSystem` returns `false`.
- `TransferEngine.copyFile` internally treats `let resume = resume &&
  destination.supportsAppendResume`. This means that for an S3 target
  `resumeOffset` is always 0 and the write mode is always `.overwrite` —
  no matter what the caller passes (belt-and-suspenders; no caller can
  corrupt an S3 upload).
- `TransferQueueViewModel` reads the target's `supportsAppendResume` so as
  to not offer a "Resume" option at all for an S3 target in the first
  place (UI consistency; the engine lock is the actual protection).

## Error handling

- HTTP mapping consistent with M12: 403 → `.authenticationFailed`,
  404 → `.notFound(path:)`, network/transport → `.connectionFailed(reason:)`,
  other non-2xx → `.protocolError(reason: "… HTTP {code}")`.
- Multipart abort cleans up on every error (§2).
- `Task.checkCancellation()` per chunk (upload part, download already via
  the engine stream) and per DeleteObjects batch.
- **Secret hygiene**: `secretAccessKey`/`sessionToken` only flow into the
  signer; never logged/interpolated. No body contents in logs.

## Tests

- **Core unit against `FakeS3Transport`** (no network), per operation:
  - Upload single-`PUT` path (small stream → one PUT, correct
    `payloadHash`, key/body match).
  - Upload multipart path (stream > threshold → Initiate/≥2× UploadPart/Complete;
    part numbers + collected ETags correct; part order in the Complete XML).
  - Multipart **abort** on a part error (error injected → abort request goes
    out, error is propagated).
  - Download range GET (offset header correct; bytes delivered chunked;
    offset ≥ EOF → empty stream).
  - `createDirectory` (marker key ends in `/`, 0 bytes).
  - `delete` (DELETE key; 404 → notFound).
  - `rename` file (copy-source header + delete), folder (re-key all keys).
  - `deleteTree` (recursive listing without delimiter → DeleteObjects batch,
    marker included; >1000 → multiple batches).
  - **Resume lock**: `TransferEngine.copyFile(resume: true)` with an
    S3-target fake whose `supportsAppendResume == false` always writes
    `.overwrite` from offset 0 (never `.append`) — even if a smaller
    object already "sits" at the target.
- **Gated MinIO integration** (`MACSCP_ITEST=1`, real rig from the
  main checkout): upload→download roundtrip (bit-identical content), file > 8 MiB
  (real multipart path), create a folder + see it again, rename a file,
  rename a folder, delete a tree. Seed bucket stays reproducible; the test
  cleans up its own keys.

## Files

- New: `Sources/macSCPCore/S3/S3Uploader.swift` (hybrid PUT/multipart logic).
- Modify: `Sources/macSCPCore/S3/S3FileSystem.swift` (readStream/write/delete/
  createDirectory/rename/deleteTree real; `buildSignedRequest` helper;
  `supportsAppendResume = false`).
- Modify: `Sources/macSCPCore/S3/S3HTTPTransport.swift` (`sendStreaming` +
  impl).
- Modify: `Sources/macSCPCore/RemoteFS/RemoteFileSystem.swift`
  (`supportsAppendResume` requirement + default extension).
- Modify: `Sources/macSCPCore/RemoteFS/TransferEngine.swift` (resume guard).
- Modify: `Sources/macSCPCore/Presentation/TransferQueueViewModel.swift`
  (resume offer gated on `supportsAppendResume`).
- Possibly new: `Sources/macSCPCore/S3/S3MultipartXML.swift` (parser for
  `InitiateMultipartUpload`/builder for `CompleteMultipartUpload`/
  `Delete` XML) — or inline in `S3Uploader`/`S3FileSystem`, depending on size
  (the plan decides the split).
- Tests: `Tests/macSCPCoreTests/S3UploaderTests.swift`,
  extensions in `S3FileSystemTests.swift`, new cases in
  `TransferEngineTests.swift` (resume lock),
  `S3FileSystemIntegrationTests.swift` (gated MinIO CRUD/transfer).

## Global Constraints

- Swift 6, all targets `.swiftLanguageMode(.v5)`, min. macOS 15.
- Code/comments **English**; no new UI strings expected (the error/
  action texts already exist backend-agnostic). If a new
  user-visible string does become necessary, it goes into all four
  catalogs EN/DE/FR/PL (typographic quotation marks, no ASCII `"` in
  non-EN).
- **No new dependency** (Foundation + swift-crypto via `SigV4Signer`).
- **Secret only in the signer**, never in logs/JSON; no plaintext bodies in
  logs.
- **No atomic rename, no real resume** — documented S3 limitations.
- Multipart is aborted on every error path (no orphaned upload).
- TDD red→green; new logic with tests; gated MinIO from the main checkout,
  seed reproducible.
- **No release.** Cross-backend/presigned = M14.
