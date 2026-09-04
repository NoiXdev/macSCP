# Delete Contracts on S3 and WebDAV Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `deleteTree(at:)` on a plain file deletes the file, and
`delete(path:)` on a directory refuses, on every backend — the contract
`RemoteFileSystem` already states, which S3 and WebDAV break today.

**Architecture:** Both operations look the entry up first (`stat`, the
one lookup each backend already has) and branch on its kind: WebDAV's
`deleteTree` sends `DELETE` with or without the trailing slash according
to the kind; S3's `deleteTree` deletes the object itself when the path
is an object, the prefix's keys when it is a directory; S3's
`delete(path:)` throws `protocolError` for a directory and `notFound`
for nothing, instead of letting the idempotent `DeleteObject` answer
204 over a key that never existed. The CLI matrix's delete-first
cleanup workaround is retired once the contract holds.

**Tech Stack:** Swift 6 strict, Swift Testing, the stubbed S3/WebDAV
transports the unit suites already use, the Docker rig (`MACSCP_ITEST=1`:
MinIO 19000, Apache WebDAV 18080).

**Spec:** the two `docs/BACKLOG.md` rows measured 2026-09-04 —
"`deleteTree` does not delete a plain file (S3, WebDAV)" and "S3
`delete(path:)` on a directory is a silent no-op" — and the contract in
`Sources/macSCPCore/RemoteFS/RemoteFileSystem.swift`: `delete` "Deletes
a FILE at `path` (not a directory). Throws `RemoteFSError.notFound` if
nothing exists there, and `RemoteFSError.protocolError` if `path` is a
directory"; `deleteTree` "A plain file behaves exactly like `delete`".
Measured: `DELETE /dav/<file>.txt/` answers 400, without the slash 204;
S3 `resolvePrefix` returns `key + "/"` so a file's `deleteTree` batches
zero keys; `RootMode.resolve` strips the trailing slash so a directory's
`delete` never addresses the `<name>/` marker key.

## Global Constraints

- English only; Conventional Commits; footer exactly `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`; commit per task; zero warnings; do not push.
- Red first against the real defect: the gated rig case is red before the change, the unit case (stubbed transport) is red before the change; both are named in the report with the observed failure text.
- The rig only (127.0.0.1), started from the main checkout; every remote entry a test creates is removed by the test and the removal asserted through `stat` → `notFound`; the WebDAV container has no volume — leave it as found.
- No wall-clock ceiling; tests never block the cooperative pool; no `#require` on a non-optional; every wait through `MacSCPTestSupport.pollUntil` under a suite `.timeLimit`.
- A number in a comment or backlog row is counted when written; comments naming callers are checked in the same pass (`RemoteBrowserViewModel.deleteItems`, `RmCommand`, `CLIMatrix.removeRemote`).
- One extra request per call is acceptable (the lookup); no second request path — the lookup is the existing `stat`.

---

### Task 1: WebDAV `deleteTree` on a plain file

**Files:**
- Modify: `Sources/macSCPCore/WebDAV/WebDAVFileSystem.swift:508-510` (`deleteTree`)
- Test: `Tests/macSCPCoreTests/WebDAVFileSystemWriteTests.swift` (stubbed transport: a `PROPFIND` answering a file, then the `DELETE` the test asserts was sent WITHOUT a trailing slash; a second case: a collection, `DELETE` WITH the slash) and `Tests/macSCPCoreTests/WebDAVFileSystemIntegrationTests.swift` (gated: write a file, `deleteTree` it, `stat` → `notFound`; create a collection with a file inside, `deleteTree` it, `stat` → `notFound`)

**Interfaces:**
- Consumes: `stat(path:)` (`WebDAVFileSystem.swift:214`, PROPFIND depth 0 with the slash fallback already built in), `simple(method:path:isDirectory:)`.
- Produces: nothing new; behaviour only.

- [x] **Step 1: Red first.** Gated: `MACSCP_ITEST=1 swift test --filter WebDAVFileSystemIntegrationTests` with the new file case — expected red: `deleteTree` throws (the 400 mapped through `mapStatus`) or the file survives. Unit: the stub records the request; expected red: the URL ends with `/`.
- [x] **Step 2: Implement.**

```swift
    /// One call for a collection (WebDAV deletes it recursively server-side;
    /// S3 needs a listing and batched DeleteObjects). The lookup first is
    /// what makes a plain file behave exactly like `delete`, as the
    /// protocol's contract says: Apache answers 400 to a DELETE whose path
    /// carries a trailing slash but names a file (measured 2026-09-04 on
    /// the rig), and only the entry's kind says which URL shape to send.
    public func deleteTree(at path: String) async throws {
        let entry = try await stat(path: path)
        try await simple(method: "DELETE", path: path, isDirectory: entry.kind == .directory)
    }
```

- [x] **Step 3: Green** — the two suites above, plus `swift test` (zero warnings).
- [x] **Step 4: Commit** `fix(webdav): deleteTree on a plain file deletes the file`.

---

### Task 2: S3 `deleteTree` on a plain file, `delete` on a directory

**Files:**
- Modify: `Sources/macSCPCore/S3/S3FileSystem.swift:378-382` (`delete(path:)`) and `:497-528` (`deleteTree`)
- Test: `Tests/macSCPCoreTests/S3FileSystemTests.swift` (stubbed transport: `deleteTree` on a path whose listing shows an object → exactly one `DELETE` on that key and no `POST ?delete`; `delete` on a path whose listing shows a `CommonPrefixes` entry → `RemoteFSError.protocolError` and NO request beyond the listing; `delete` on a path the listing does not contain → `RemoteFSError.notFound` and no `DELETE`) and `Tests/macSCPCoreTests/S3FileSystemIntegrationTests.swift` (gated against MinIO: `write` an object, `deleteTree` it, `stat` → `notFound`; `createDirectory`, `delete` it → `protocolError`, the marker still listed; then `deleteTree` the directory, `stat` → `notFound`)

**Interfaces:**
- Consumes: `stat(path:)` (`S3FileSystem.swift:265`, the parent listing), `delete(bucket:key:)` (`:391`), `resolvePrefix(path:)`, `allObjectKeys(bucket:underPrefix:)`, `mode.resolve(path:)`.

- [x] **Step 1: Red first.** Unit: the stub records requests; expected reds: `deleteTree` on the object sends `POST ?delete` with zero keys (or nothing), `delete` on the prefix sends a `DELETE` and returns normally, `delete` on nothing sends a `DELETE` and returns normally. Gated: the object survives `deleteTree`; `delete` on the directory returns normally.
- [x] **Step 2: Implement.**

```swift
    /// A signed `DELETE` on the object key — after the lookup that the
    /// contract needs: S3's `DeleteObject` answers 204 whether or not the
    /// key existed, so without it a missing file and a directory (whose
    /// marker key is `<name>/`, which `resolve` never addresses) both came
    /// back as a silent success (measured 2026-09-04, backlog row "S3
    /// `delete(path:)` on a directory is a silent no-op").
    public func delete(path: String) async throws {
        try refuseBucketLevelOperation(.delete, path: path)
        let entry = try await stat(path: path)          // throws notFound itself
        guard entry.kind != .directory else {
            throw RemoteFSError.protocolError(reason: "S3 delete: \(path) is a directory")
        }
        let (bucket, key) = try mode.resolve(path: path)
        try await delete(bucket: bucket, key: key)
    }

    public func deleteTree(at path: String) async throws {
        try refuseBucketLevelOperation(.deleteTree, path: path)
        let entry = try await stat(path: path)          // throws notFound itself
        if entry.kind != .directory {
            // A plain file behaves exactly like `delete` (the protocol's
            // contract): the prefix walk below would batch zero keys over
            // `<key>/` and report success having deleted nothing.
            let (bucket, key) = try mode.resolve(path: path)
            try await delete(bucket: bucket, key: key)
            return
        }
        let (bucket, treePrefix) = try resolvePrefix(path: path)
        // … the existing batched walk, unchanged …
    }
```

- [x] **Step 3: Green** — `swift test --filter S3FileSystem`, `MACSCP_ITEST=1 swift test --filter S3FileSystemIntegrationTests`, full `swift test`, zero warnings.
- [x] **Step 4: Commit** `fix(s3): deleteTree deletes a plain file, delete refuses a directory and reports a missing key`.

---

### Task 3: Retire the workaround, close the rows

**Files:**
- Modify: `Tests/macSCPCoreTests/Support/CLIMatrix.swift` (`removeRemote`: the delete-first-then-deleteTree workaround and its comment go; one `deleteTree` per entry, the `verifyGone` outcome check stays)
- Modify: `docs/BACKLOG.md` (both rows → **Done 2026-09-04** with the commits and the measured before/after; the `deleteTree` row's "consequence read from the call sites" sentence stays as history)

- [x] **Step 1:** `MACSCP_ITEST=1 swift test --filter CLIMatrix` green with the single-call cleanup (55 tests); if any backend goes red here, the contract is not yet honoured for that shape — that is a finding for Task 1/2, not a reason to keep the workaround.
- [x] **Step 2:** the rows; count the gated cases added (Tasks 1–2) and name them.
- [x] **Step 3: Commit** `test(cli): the matrix cleans up through deleteTree alone, and the backlog says the contract holds`.
