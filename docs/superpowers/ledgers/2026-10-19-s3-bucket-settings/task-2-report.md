# Task 2 report: `S3BucketSettings`, and versioning through it

Status: DONE. One commit: `e5ab8876` `feat(s3): read and write a bucket's versioning state` (not pushed).

## Files

- Created `Sources/macSCPCore/RemoteFS/S3BucketSettings.swift`: `BucketVersioning` (`never`, `enabled`, `suspended`) and `protocol S3BucketSettings: Sendable` with only `versioning(ofBucket:)` and `setVersioning(_:ofBucket:)`. The doc comment says later settings add methods here and their conformance in the extension at the bottom of `S3FileSystem.swift`; it carries no count of future methods.
- Created `Sources/macSCPCore/S3/S3SettingsXML.swift`: `parseVersioning(_:)`, `versioningBody(_:)`, `XMLParser` plus delegate like `S3MultipartXML`.
- Modified `Sources/macSCPCore/S3/S3FileSystem.swift`: `extension S3FileSystem: S3BucketSettings`, placed immediately above the `RemoteChecksumProvider` extension, after `PresignedURLProvider`.
- Tests: `S3SettingsXMLTests.swift`, `S3BucketSettingsGatedTests.swift` (both named in the brief), plus `S3BucketSettingsTests.swift` (not named in the brief; request-shape and error-mapping tests on `FakeS3Transport`).

## Behaviour

- Read: `GET` on `?versioning`. Request built with `Self.signedRequest(.bucketRoot(bucket:), method:, query:, config:)` (which goes through `addressed` and `requestURL`, so no hand-built URL) and sent with `send`. A non-2xx answer throws `Self.mapErrorStatus(status, body:, path: "/" + bucket)`.
- Write: `PUT` on `?versioning`. The body is built first, so `.never` throws before any request exists. Signed with `payloadHash: SigV4Signer.hexSHA256(body)`, then `sendExpectingSuccess`, which also goes through `mapErrorStatus` with the body.
- `parseVersioning`:
  - Absent `<Status>` returns `.never`.
  - `Enabled` returns `.enabled`, `Suspended` returns `.suspended`; the text is trimmed.
  - An unknown status (including an empty `<Status></Status>`), malformed XML, and a root element other than `VersioningConfiguration` throw `.protocolError`. A foreign root aborts the parse and gets its own reason text rather than Foundation's abort message.
  - Only a `Status` that is a direct child of the root counts. `MfaDelete` is ignored.
- `versioningBody(.never)` throws `RemoteFSError.finding(.operationNotSupported)`.
  - The test `neverIsRefusedAsAnUnsupportedOperation` pins the exact finding, not just the error type.
  - `settingNeverSendsNothing` pins that `setVersioning(.never, …)` adds no request to the transport.

## TDD red, quoted

`swift test --filter S3SettingsXMLTests` before any implementation. The test target compiles as a whole, so the compiler stopped on the gated file first (these lines are also in the commit message):

```
Tests/macSCPCoreTests/S3BucketSettingsGatedTests.swift:39:24: error: cannot find type 'BucketVersioning' in scope
Tests/macSCPCoreTests/S3BucketSettingsGatedTests.swift:42:42: error: value of type 'S3FileSystem' has no member 'versioning'
Tests/macSCPCoreTests/S3BucketSettingsGatedTests.swift:43:26: error: value of type 'S3FileSystem' has no member 'setVersioning'
```

The brief expected `cannot find 'S3SettingsXML' in scope`. I did not see that exact line; the output above is what the compiler printed, a build failure rather than test failures.

## Green

- `swift test --filter S3SettingsXMLTests`: exit 0, 9 tests in 1 suite passed.
- `swift test --filter S3BucketSettingsTests`: exit 0, 6 tests in 1 suite passed.
- `MACSCP_ITEST=1 swift test --filter S3BucketSettingsGatedTests`: exit 0, 1 test passed against the rig in 0.122 s.
  - It creates `macscp-versioning-<12 hex>` with a raw signed `PUT`.
  - It reads `.never`, sets `.enabled` and reads it back, sets `.suspended` and reads it back, then deletes the bucket.
  - It asserts the observed sequence `[.never, .enabled, .suspended]`, a 2xx on create and a 2xx on delete.
  - Cleanup runs even if the round trip throws.
  - Every wait is an `await`; there is no elapsed-time assertion.
- Full `swift test`: exit 1. The only failure is `ViewTestabilitySpike` "Varying only isRegex leaves the pixels unchanged" (`ViewTestabilitySpike.swift:202:9`, `off == on`), the known unrelated red. The macSCPCore run reported 4965 tests passed, 0 failures.
- I ran the two filters separately because the sandbox refused a single `--filter "A|B"` invocation. Step 5's `S3FileSystem` filter is covered by the full run.

## Rig safety

I touched only my own throwaway bucket. `macscp-seed`, `macscp-second` and `macscp-probe-lock` are not named anywhere in the new test file except `macscp-seed` as the `bucket:` field of the connection config, which is where every existing gated test puts it. Nothing is read from or written to that bucket.

## Concerns

1. No empty-bucket guard. `versioning(ofBucket: "")` would sign a request against the account root (path-style) or a malformed host (virtual-host style). The plan puts bucket-name validation in Task 5 (`S3BucketName.problem(with:)`), so I added nothing here.
2. `mapErrorStatus` receives `path: "/" + bucket` in every mode. `reportedPath(bucket:key:)` would have returned `"/"` in `.bucket` mode, which names the connected bucket and not the argument, so I did not use it.
3. The gated test needs no `createBucket`, since Task 5 adds that. It makes and removes its bucket with raw `signedRequest` and `perform`; Task 5 can swap that for its own `createBucket` if it wants.
4. The `PUT` carries no `Content-MD5`, and RustFS accepted it. AWS does not require one for `PutBucketVersioning` when the body is SigV4-hashed. This is not measured against AWS.

---

# Fix round 1 (commit `fcde650d`)

## Withdrawn

Concern 4 of the report above read: "The `PUT` carries no `Content-MD5`, and RustFS accepted it. AWS does not require one for `PutBucketVersioning` when the body is SigV4-hashed. This is not measured against AWS." The second sentence is withdrawn. AWS's API reference marks `Content-MD5` as required for `PutBucketVersioning` (https://docs.aws.amazon.com/AmazonS3/latest/API/API_PutBucketVersioning.html). I did not read that page myself; the coordinator did, and I take it from the coordinator's measurement. The reviewer confirmed from the code that no `Content-MD5` was on the wire in `e5ab8876`.

## Changes

1. `setVersioning` now builds `Data(Insecure.MD5.hash(data: body)).base64EncodedString()` and passes it as `extraHeaders: ["Content-MD5": md5]`, as `deleteTree` does. `extraHeaders` are signed. Test `settingAStateSendsASignedContentMD5OfItsBody` asserts that the header is sent and that `Authorization` names `content-md5`.
   - Its expected values are literals: `IjhtHf5gnkMYmEeiwoaHWg==` for Enabled and `zsURZSA06S13UA4zV6WnyQ==` for Suspended. They were computed once, outside the code, with `printf '%s' <body> | openssl md5 -binary | base64`.
   - It does not assert that any store accepted the request.
2. The `deleteTree` doc comment is corrected in place. The old wording is quoted: "(unlike every other request this file builds)".
3. The `docs/BACKLOG.md` row "Every bucket-subresource PUT carries a signed `Content-MD5`, and the Docker rig cannot tell a request that has it from one that lacks it" is added at the end of the "New features" table. It carries the requirement, the AWS URL, the rig's blindness, the test that holds it, and the reach to `PutBucketCors` and `PutObjectLockConfiguration`. It states that neither of those two AWS pages was read, so those tasks confirm against their own page. It carries no counts, so there is no command to attach.
4. Important 2: `aNamedRefusalInTheBodyBecomesItsFinding` now asserts `.finding(.operationNotSupported)` directly, matching its sibling `aNonSuccessAnswerIsMappedThroughTheSharedStatusMapping`.
5. Gated test: `defer { Task { await fs.disconnect() } }` after `connect`. The two explicit `disconnect()` calls and the early-return branch are removed.
6. `S3BucketSettings` doc comment: the bucket argument is not validated here, and name validation belongs to `S3BucketName.problem(with:)` (Task 5).
7. The coordinator's recorded, not-fixed note is unchanged: `.never` is runtime-forbidden while `CaseIterable` offers it, and Task 8 owns that.

## Red

Command: `swift test --filter S3BucketSettingsTests`, run after the test edits and before the production change. Exit 1.

```
✘ Test settingAStateSendsASignedContentMD5OfItsBody(state:expectedMD5:) recorded an issue with 2 arguments state → .enabled, expectedMD5 → "IjhtHf5gnkMYmEeiwoaHWg==" at S3BucketSettingsTests.swift:82:9: Expectation failed: sent.value(forHTTPHeaderField: "Content-MD5") == expectedMD5
✘ Test settingAStateSendsASignedContentMD5OfItsBody(state:expectedMD5:) recorded an issue with 2 arguments state → .suspended, expectedMD5 → "zsURZSA06S13UA4zV6WnyQ==" at S3BucketSettingsTests.swift:82:9: Expectation failed: sent.value(forHTTPHeaderField: "Content-MD5") == expectedMD5
✘ Test settingAStateSendsASignedContentMD5OfItsBody(state:expectedMD5:) recorded an issue with 2 arguments state → .enabled, expectedMD5 → "IjhtHf5gnkMYmEeiwoaHWg==" at S3BucketSettingsTests.swift:84:9: Expectation failed: authorization.lowercased().contains("content-md5")
✘ Test settingAStateSendsASignedContentMD5OfItsBody(state:expectedMD5:) recorded an issue with 2 arguments state → .suspended, expectedMD5 → "zsURZSA06S13UA4zV6WnyQ==" at S3BucketSettingsTests.swift:84:9: Expectation failed: authorization.lowercased().contains("content-md5")
✘ Test run with 7 tests in 1 suite failed after 0.014 seconds with 4 issues.
```

## Green

- `swift test --filter S3BucketSettingsTests`: exit 0, "Test run with 7 tests in 1 suite passed".
- `swift test --filter S3SettingsXMLTests`: exit 0, 9 tests passed.
- `swift test --filter S3FileSystem`: exit 0, 125 tests in 2 suites passed. Run because `S3FileSystem.swift` changed.
- `MACSCP_ITEST=1 swift test --filter S3BucketSettingsGatedTests`: exit 0, 1 test passed. The rig accepts the request with the header too, as expected. As the coordinator noted, this run says nothing about the header either way.
- Full suite not re-run, as instructed.
