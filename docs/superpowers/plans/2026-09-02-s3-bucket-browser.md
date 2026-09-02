# S3: the Bucket List as the First Folder — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** An S3 session can start at the account's bucket list instead of
inside one bucket: a visible toggle on the form, `ListBuckets` checked
once on connect with three named outcomes, a root mode in
`S3FileSystem` where `/` is the list and `/<bucket>/…` routes into that
bucket, and bucket rows in the browser that offer "open" only — all
measured against a rig with a second bucket and a key that may not list.

**Architecture:** Follows `docs/superpowers/specs/2026-09-02-s3-bucket-browser-design.md`
as decided 2026-09-02: **toggle, not inference; presets only, no provider
type.** `S3ConnectionConfig` gains `startsAtBucketList: Bool` (false =
today's behaviour, byte-for-byte) and `bucket` becomes irrelevant when
it is true — the form hides the bucket field through the schema's own
visibility conditioning (`visibleFields(in:)` is what `firstViolation`
consults, so a hidden bucket is not a required blank). `S3FileSystem`
gains a `RootMode` (`.bucket(String)` / `.bucketList`) decided once at
connect; the request builders (`requestURL`, `canonicalKeyPath`,
`objectKey(forPath:)`) take the bucket from the mode plus the path's
first component in list mode — one decision, no string branching per
call. `ListBuckets` (`GET /` on the endpoint, SigV4-signed like every
other request) runs on connect in list mode and maps to three outcomes.
A bucket row is a `RemoteFileItem` of kind directory with `modifiedAt =
creationDate` and no size/permissions — the table already tolerates
absent values (WebDAV rows carry no permissions). Actions on a bucket
row: open only; the existing "is this action possible here" predicate
gets one more answer.

**Tech Stack:** Swift 6, Swift Testing; `S3FieldSchema`/`BackendDescriptor`
(a toggle field of the same kind as `usePathStyle`), `S3FileSystem`
request builders (~lines 660-740), `S3ListParser`/`S3XMLText` for the
`ListAllMyBucketsResult` XML, MinIO rig (`docker/test-server/compose.yml`
`minio`/`minio-init`, `mc` client), four App catalogs.

## Global Constraints

- English only; Conventional Commits; footer exactly `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- **Toggle off = today, exactly.** Every existing S3 test stays green
  untouched; a saved session without the new field decodes as `false`
  (read-side default, no migration file).
- **No provider type.** No enum on `S3ConnectionConfig`; presets stay
  value lists.
- **The secret key reaches no message, log or expectation.** The three
  `ListBuckets` outcomes name the situation, never the key.
- **No bucket creation or deletion** from macSCP.
- Every request stays SigV4-signed through the existing signer; the
  redirect policy (`S3RedirectSessionDelegate`, same-origin re-sign)
  applies to `ListBuckets` like to every call.
- Rig from the main checkout only; only `macscp-test-*` containers; the
  restricted key's secret is a rig constant like `macscpsecretkey`, not a
  real credential.
- Four catalogs for every new string; German du-form; parity guards.
- Swift 6 language mode; warning budget 1 on a fresh scratch path.
- TDD red first; gated tests `MACSCP_ITEST=1` against MinIO on 19000.

---

### Task 1: The rig — a second bucket and a key that may not list

**Files:**
- Modify: `docker/test-server/compose.yml` (`minio-init`: `mc mb local/macscp-second`, one object in it; `mc admin user add local macscp-scoped macscpscopedsecret`; `mc admin policy create local scoped-seed <policy.json>` with `s3:ListBucket`/`s3:GetObject`/`s3:PutObject`/`s3:DeleteObject` on `arn:aws:s3:::macscp-seed` and `arn:aws:s3:::macscp-seed/*` only — NO `s3:ListAllMyBuckets`; `mc admin policy attach local scoped-seed --user macscp-scoped`)
- Create: `docker/test-server/minio/scoped-seed-policy.json` (mounted read-only into `minio-init`)
- Modify: `docker/test-server/README.md` (the keys table: root `macscp`/`macscpsecretkey` may list; scoped `macscp-scoped`/`macscpscopedsecret` may not; proof commands)

- [ ] **Step 1:** Prove with `mc` from inside `minio-init`'s image (a one-off
  `docker compose run --rm minio-init sh -c '…'` or `docker exec`): root
  `mc ls local` shows two buckets; scoped `mc ls scoped` fails with
  `AccessDenied`; scoped `mc ls scoped/macscp-seed` lists. Paste the three
  outputs into the README with the date.
- [ ] **Step 2:** `docker compose up -d` recreates only `minio-init`
  (container IDs of `minio`, both sshd and webdav unchanged — check).
- [ ] **Step 3: Commit** — `build(rig): a second MinIO bucket and a key that may not list buckets`

### Task 2: Core — `startsAtBucketList`, root mode, `ListBuckets`, three outcomes

**Files:**
- Modify: `Sources/macSCPCore/S3/S3ConnectionConfig.swift` (`public var startsAtBucketList: Bool = false`, last init parameter with default)
- Modify: `Sources/macSCPCore/S3/S3FileSystem.swift` (`enum RootMode { case bucket(String), bucketList }`, decided in `connect`; `requestURL`/`canonicalKeyPath`/`objectKey(forPath:)` take `(bucket, key)` from `mode.resolve(path:)` — one function; `connect` in list mode calls `listBuckets()` instead of the `ListObjectsV2` probe; `list(path: "/")` in list mode returns bucket rows; `list("/<b>/…")`, `stat`, transfers route into `<b>`)
- Modify: `Sources/macSCPCore/S3/S3ListParser.swift` (parse `ListAllMyBucketsResult`: `Buckets/Bucket/{Name,CreationDate}`)
- Modify: `Sources/macSCPCore/RemoteFS/RemoteFSError.swift` (or the S3 error enum — read where `connectionFailed` siblings live): `bucketListForbidden` (403 on `ListBuckets`), `bucketListEmpty` (200, zero buckets); anything else stays `connectionFailed`
- Test: `Tests/macSCPCoreTests/S3FileSystemTests.swift` (mock transport: the three outcomes; root-mode path resolution table: `/` → list, `/b` → `(b, "")`, `/b/x/y` → `(b, "x/y")`, a path without a bucket component in list mode is an error, not a request to `/`), `Tests/macSCPCoreTests/S3IntegrationTests.swift` (gated: root key + toggle → two bucket rows named `macscp-seed`, `macscp-second`, both directories, `modifiedAt` non-nil; open `macscp-seed` → `a.txt`, `sub`; scoped key + toggle → `bucketListForbidden`; scoped key + bucket `macscp-seed`, toggle off → today's connect works — the "usual case" the entry names)

**Interfaces:**
- Produces: `S3ConnectionConfig.startsAtBucketList`, `RemoteFSError.bucketListForbidden`, `.bucketListEmpty` (exact names Task 3 maps), `S3FileSystem.RootMode` (internal).

- [ ] **Step 1: Red** — the mock-transport tests and the path table first.
- [ ] **Step 2:** Implement `RootMode` and thread it through the three
  builders; count the call sites of each builder before and after and
  write the count into the commit body (they must be equal).
- [ ] **Step 3:** `listBuckets()`: `GET {endpoint}/` (path-style) — for
  virtual-hosted endpoints `ListBuckets` is on the bare endpoint host,
  never on a bucket host; parse; map 403 `AccessDenied` →
  `bucketListForbidden`, 200 with zero → `bucketListEmpty`.
- [ ] **Step 4:** Gated tests against the rig; record each of the four
  outcomes before fixing anything.
- [ ] **Step 5: Commit** — `feat(s3): a connection may start at the bucket list`

### Task 3: The form — toggle, hidden bucket field, three messages

**Files:**
- Modify: `Sources/macSCPCore/S3/S3FieldSchema.swift` (`case startsAtBucketList` in `S3Field`; a field of `usePathStyle`'s kind; the `bucket` field's visibility conditioned on it being off; `makeConfig` reads it; `apply`/`values(from:)` round-trip it; `defaults` = off; `editBaseline` unchanged)
- Modify: `Sources/macSCPCore/Presentation/ConnectionViewModel.swift` (map `bucketListForbidden` → `core.connect.s3BucketListForbidden`: "This key may not list buckets. Turn off 'Start at the bucket list' and enter the bucket."; `bucketListEmpty` → `core.connect.s3BucketListEmpty`: "This key can list buckets, but the account has none.")
- Modify: the four Core catalogs (`core.connect.s3StartsAtBucketList` = "Start at the bucket list", the two messages), stringsdict untouched
- Test: `Tests/macSCPCoreTests/S3FieldSchemaTests.swift` (toggle on → bucket not among `visibleFields`, `firstViolation` passes with a blank bucket; toggle off → bucket required as today; `makeConfig` round-trip; a pre-existing bag without the key → off), `ConnectionViewModelTests` (the two mappings), `LocalizationParityTests`/`GermanAddressFormTests` green

- [ ] Red first; commit — `feat(s3): the form's "Start at the bucket list" toggle and its messages`

### Task 4: The browser — bucket rows offer "open" only

**Files:**
- Modify: wherever the file pane decides which actions a selected remote row allows (grep the toolbar/context-menu predicate for `RemoteFileItem` and `isDirectory`; the local pane has the same shape) — a bucket row (S3 session in list mode, depth 0) allows open/refresh only: no upload, download, rename, delete, checksum, presigned URL
- Modify: `Sources/macSCPCore/Capabilities/ProtocolCapabilities.swift` only if the predicate needs a capability rather than a path test — prefer the path test (list mode + depth 0) and say why in the doc comment
- Test: an ungated test of the predicate over a bucket row and an object row; a source-scanning guard is NOT needed if the predicate is one function both menus call — make it one function

- [ ] Red first; commit — `feat(browser): a bucket row opens, nothing else`

### Task 5: Closeout

**Files:**
- Modify: `docs/superpowers/specs/2026-08-31-backlog-s3-without-bucket.md` ("Done" with the four measured outcomes and the rig proof), `docs/BACKLOG.md` (B-3 → Done), the design doc's status line

- [ ] Commit — `docs(backlog): S3 starts at the bucket list; B-3 closed`

## What is explicitly not in this plan

- No provider type; no bucket create/delete; no Servinga measurement (no
  key in the rig — recorded as unmeasured).
- No change to transfers' semantics inside a bucket.
