# Task 1 report: the store's refusal, said honestly

Status: DONE_WITH_CONCERNS. Commit: `1ef0128e` on `s3-bucket-settings` (not pushed).

## What changed

- `Sources/macSCPCore/S3/S3ErrorCode.swift` (new): `parse(_:)` reads the first `<Code>` via `XMLParser` (aborts once found; non-XML or no `<Code>` gives nil). `finding(forCode:status:path:)` names three codes and returns nil for everything else.
  - `ObjectLockConfigurationNotFoundError` -> `.objectLockNotConfigured`
  - `BucketNotEmpty` -> `.bucketNotEmpty`
  - `NotImplemented` -> `.operationNotSupported`
  - `status` and `path` are accepted for the interface but the code alone decides (stores disagree on status for the same code). Documented in the doc comment.
- `RemoteFSFinding.swift`: five cases (`objectUnderLegalHold(path:)`, `objectUnderRetention(path:)`, `objectLockNotConfigured`, `bucketNotEmpty`, `operationNotSupported`), `Name` cases, `name` arms, `messageKey(for:)` arms (the two path cases carry ` %@` in the derived key), `message`, `logSentence`, `readsAsConnectionFailure` (all false). No `default:` added anywhere.
- `S3FileSystem.mapErrorStatus(_:body:path:)`: reads the body first; a named code is returned, otherwise the unchanged 403/404/default mapping. All 8 call sites now pass the body (the `HEAD` site passes `Data()`, since a HEAD answer has none; `sendExpectingSuccess` now keeps the data it used to discard).
- Catalogues: five sentences x en/de/fr/pl (German in du-form; `GermanAddressFormTests` green).
- Tests: `Tests/macSCPCoreTests/S3ErrorCodeTests.swift` (the brief's tests, the brief's `anamedCodeBecomesItsFinding` spelled `aNamedCodeBecomesItsFinding` (the brief asks for no rename; the coordinator's dispatch did, so the attribution in the first version of this report was wrong); plus an `AccessDenied`-falls-through test and three tests through `mapErrorStatus` itself, proving the body is read and the old mapping is kept for unnamed codes). `RemoteFSFindingTests` needed its two exhaustive switches (`argument(of:)`, `everySample`) extended, and its "eighteen" / "three of eighteen" / "the three" comments updated.

## Things to know

1. `objectUnderLegalHold` and `objectUnderRetention` are DEFINED but NOTHING THROWS THEM YET. `AccessDenied` maps to nil by design (legal hold and retention both answer with it); Task 4's delete path, which reads `?legal-hold`, must construct one of them. I did not parse the server's message to split them. A test pins `AccessDenied` -> nil.
2. `mapErrorStatus` lost `private` (now internal) so it can be tested without a network. Only visibility changed.
3. `S3Uploader.mapStatus` is a status-only local copy whose doc comment said it was "deliberately the same mapping" as `mapErrorStatus`. It is no longer the same, so I rewrote that comment to say it is the status-only half and does not read `<Code>`. Behaviour unchanged. Consequence: refusals on the uploader's own requests (multipart initiate/part/complete/abort) are not named. None of the five codes is plausible there today, but Task 4+ should know.
4. Retention/legal-hold sentences say "cannot be deleted" only. My first draft said "or replaced"; I dropped it, because on a versioned bucket an overwrite succeeds by creating a new version, so "replaced" would be a false claim.
5. The fr/pl sentences are my own translations and have had no native-speaker review.

## Counts written into comments (verified at write time)

- 23 `RemoteFSFinding` cases: `grep -c "^    case [a-zA-Z]" Sources/macSCPCore/RemoteFS/RemoteFSFinding.swift` printed 23 (the file has no other 4-space-indented `case` lines at that level outside the enum body).
- 5 with a payload: `grep -n "(path: String)\|(code: Int)\|(part: Int)" ... | grep "^[0-9]*:    case" | wc -l` printed 5.

## Red, then green

Red (`swift test --filter S3ErrorCodeTests`, before implementation; compile errors, quoted in the commit message):
`type 'RemoteFSFinding.Name' has no member 'objectLockNotConfigured'` (also `bucketNotEmpty`, `operationNotSupported`), `cannot find 'S3ErrorCode' in scope`, `type 'RemoteFSFinding' has no member 'objectUnderLegalHold'`.

Green: `swift test --filter "S3ErrorCode|RemoteFSFinding|LocalizationParity|GermanAddressForm|CLIErrorMapping"` -> `Test run with 58 tests in 5 suites passed`. This includes `everyRemoteFSFindingHasItsOwnSentence`, `everyLogSentenceMatchesItsEnglishCatalogueEntry` (log sentences are the en sentences up to first-letter case), and `noFindingCarriesForeignText`.

## Step 8: blast radius (full suite)

Ran `swift test` with no flags, whole package, log at `scratchpad/full.log`.

- macSCPCoreTests: `Test run with 4944 tests in 396 suites passed`.
- macSCPAppKitTests: `Test run with 2556 tests in 230 suites failed ... with 1 issue`. The one failure is `ViewTestabilitySpike` -> "Varying only isRegex leaves the pixels unchanged" (`ViewTestabilitySpike.swift:202`, `off == on`), a SwiftUI pixel-render comparison unrelated to S3. **It fails identically on an untouched checkout of HEAD `1dac7bd3`** (I built a throwaway detached worktree of HEAD, ran `swift test --filter ViewTestabilitySpike`, same failure, then removed the worktree). It also failed identically when re-run alone on my tree. So it is pre-existing, not caused by this task, and not fixed here.
- No test whose expectation changed. No existing test file was edited except `RemoteFSFindingTests.swift`, and there only the exhaustive switches / count comments that a new case forces; no assertion was altered. No test in the `TransferQueueViewModel`, `RemoteBrowserViewModel` or `ConnectionViewModel` suites changed or went red. Not covered: the gated suites (`MACSCP_ITEST` etc.) were not run, so no live-store behaviour was exercised; the new mapping is only tested at the unit level with synthetic bodies.

## Concerns

- The pre-existing red `ViewTestabilitySpike` test means the full suite is not green on this branch (nor on its base). Someone should know before a CI gate is read.
- Findings 1 and 3 above (unthrown cases; uploader copy unchanged) are real follow-ups for later tasks.


---

# Fix round 1

Commit `cf6e3e5a` (on top of `1ef0128e`), not pushed.

## Important 1: `S3Uploader.mapStatus` comment. Agreed, fixed.

The reviewer is right that visibility is no longer the obstacle. The comment now says the obstacle is the unplumbed body. One correction to the finding's detail: it says two of the five call sites already hold the data. I read them: all five `perform` calls RETURN the data, but only the initiate step binds it (`initiateData`, line 160); the other four discard it with `_`. The comment says "only the initiate step binds it", with its count command `grep -c "throw Self\.mapStatus" Sources/macSCPCore/S3/S3Uploader.swift` (prints 5; the `\.` keeps the comment from matching itself). Behaviour unchanged; I did not plumb the body (not asked).

## Important 2: `deleteTree` batch path. Agreed, closed at the root.

- `S3ErrorCode.perKeyRefusals(in:)` (new, public): one `(key, code)` per `<Error>` in a `<DeleteResult>`, document order; `<Message>` is never read.
- `deleteTree`: after the existing `<Error` substring detection, each refusal goes through `S3ErrorCode.finding(forCode:status:path:)` with `path = reportedPath(bucket:key:)` built from the echoed `<Key>`; the first named one is thrown. Anything unnamed keeps the generic `.protocolError`. `AccessDenied` therefore still falls through, as ruled; the asymmetry is stated in `deleteTree`'s doc comment (and the old sentence "a substring check ... is enough ... without a full XML parse" was reworded since a parse now happens after detection).
- Tests: `deleteTreeNamesAPerKeyRefusalInsideAnHTTP200DeleteResult` (a named code in a 200 body becomes `.finding(.operationNotSupported)`), `deleteTreeKeepsTheGenericErrorForAnUnnamedPerKeyCode` (`AccessDenied` stays `.protocolError`, pinning the deliberate asymmetry), `aDeleteResultYieldsEachRefusedKeyWithItsCode` (two refusals, XML-escaped key unescaped, a `<Deleted>` sibling ignored), `aDeleteResultWithNoErrorsYieldsNone`. The pre-existing `deleteTreeThrowsWhenDeleteResultContainsAPerKeyError` (`InternalError` -> `.protocolError`) still passes unchanged.
- Limit: `NotImplemented` is used as the named code in the routing test because its finding carries no payload. The two path-carrying findings (`objectUnderLegalHold`/`objectUnderRetention`) still cannot be reached from any code, so the `path` built from `<Key>` is exercised by construction only, not asserted by a test.

## Minors

- `finding(forCode:status:path:)` doc comment now says `path` is unused as well as `status`, that the signature is kept, and why (a future path-carrying named finding).
- `noNewFindingCarriesTheServersSentence`: a doc comment now names `RemoteFSFindingTests.everyFindingResolvesToASentenceAndNotToItsKey` and `RemoteFSFindingTests.everyLogSentenceMatchesItsEnglishCatalogueEntry` as its positives.
- `CodeDelegate`: made the code match the comment, the other way round from "abort on first `</Code>`": it now skips an empty `<Code>` and aborts on the first NON-empty one; the doc comment says "first non-empty". New test `anEmptyCodeElementIsSkipped` (`<Code></Code><Code>BucketNotEmpty</Code>` -> `BucketNotEmpty`).
- Attribution corrected above (Things to know / first report).

## Commands and output

Red, before implementing (`swift test --filter "S3ErrorCodeTests|deleteTree"`):
```
S3ErrorCodeTests.swift:79:36: error: type 'S3ErrorCode' has no member 'perKeyRefusals'
S3ErrorCodeTests.swift:86:29: error: type 'S3ErrorCode' has no member 'perKeyRefusals'
```
Green, after:
```
$ swift test --filter "S3ErrorCodeTests|S3FileSystemTests|S3UploaderTests|RemoteFSFinding|LocalizationParity"
✔ Suite RemoteFSFindingTests passed
✔ Suite S3ErrorCodeTests passed
✔ Suite "S3Uploader" passed
✔ Suite "S3FileSystem" passed
✔ Suite "Localization catalog parity" passed
✔ Test run with 139 tests in 5 suites passed after 0.150 seconds.
```
Also `swift test --filter "S3ErrorCodeTests|deleteTree"` -> `Test run with 38 tests in 8 suites passed`, with the four new deleteTree/parser tests and `anEmptyCodeElementIsSkipped` listed passed individually.

The full suite was NOT re-run this round (as instructed). Round 1's full-suite result, including the pre-existing `ViewTestabilitySpike` red, stands for the first commit only; this round touches S3 files and tests only.
