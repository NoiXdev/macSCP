# Task 5 report: create bucket

Status: DONE_WITH_CONCERNS. Commit: `1ba02d92` (`feat(s3): create a bucket, with versioning and object lock`), on `s3-bucket-settings`, nothing pushed. Tree clean after the probes.

## What the diff contains

New:
- `Sources/macSCPCore/S3/S3BucketName.swift`: `BucketNameProblem` and `S3BucketName.problem(with:)`.
- `Tests/macSCPCoreTests/S3BucketNameTests.swift`, `S3CreateBucketTests.swift`, `S3CreateBucketGatedTests.swift`.

Modified:
- `S3BucketSettings.swift`: `createBucket(_:versioning:objectLock:)` on the protocol, with the contract in its doc comment. The type-level comment that said `S3BucketName` was "introduced by the create-bucket task" is rewritten.
- `S3FileSystem.swift`: the conformance, in the existing extension.
- `S3SettingsXML.swift`: `createBucketBody(region:)`.
- Comments and one positive-list entry, written after searching for comments that name `createBucket`:
  - `S3SettingsFakeTransport.swift` and `S3BucketSettingsGatedTests.swift` said "there is no `createBucket` yet"; both are rewritten. Those suites keep a raw create on purpose, so their set-up does not depend on the call they are not testing.
  - `S3ObjectLockTests.theProtocolOffersNoWayToEnableLockOnAnExistingBucket` gained `createBucket(_:versioning:objectLock:)` in its positive list. It contains no "enable", so the negative check is unaffected.

## The three things asked for

**A. Neither switch is "creation-only".** The `createBucket` doc comment says the switches are offered at creation because that is when a person decides what a bucket is for, not because the store forbids them later. It states that `CreateBucket` has no versioning flag, that AWS permits Object Lock later on a versioned bucket, and that macSCP offers no such call, for scope and irreversibility. The commit message says the same. No comment claims they can only be set at creation.

**B. `objectLock: true` with `versioning: false` is refused.** The call throws `RemoteFSError.protocolError(reason: "object lock requires versioning, and versioning was declined")` before any request.
- Why refuse rather than force: forcing versioning on would silently answer a question the caller did not ask, and a UI that shows versioning off while lock is on has a bug that should surface, not be absorbed.
- A caller derives `versioning` from the lock toggle, not the other way round.
- With `objectLock: true` the call sends the versioning request itself through the existing `setVersioning(.enabled, ...)` and does not rely on the store.

**C. Name check, with both halves.**
- Rules: 3 to 63 characters, lowercase ASCII letters, digits, hyphens and dots only, a letter or digit at both ends, not four dot-separated digit groups.
- Order, pinned by a test: length, uppercase, other character, edges, address form. Uppercase comes before the character check because lowercasing is the one-step fix.
- The brief's refusal test and acceptance test are both kept verbatim. Beside them are a boundary refusal list (16 cases), an ordering list (5 cases), and a second acceptance list of names that sit next to a refusal (16 cases). Examples: `192.168.0`, `192.168.0.1.2`, `192.168.0.a`, 62 and 63 `a`s, `a-.-b`.

## Red, taken tests-first

I wrote the three test files before any source existed. `swift test --filter S3BucketNameTests` gave:
```
error: cannot find type 'BucketNameProblem' in scope
error: cannot find 'S3BucketName' in scope
```
The `createBucket` tests were in the same module, so their own red was the build failure; I did not take it separately.

One correction to my own tests after green: three of them asserted `url.query == nil`. The URL builder leaves a bare `?` on a bucket root with no query, so the query is `""`. My assertion was wrong, not the code. They now assert it is empty.

## Results

- `swift test --filter "S3BucketNameTests|S3CreateBucketTests"`: 13 tests in 2 suites passed.
- `MACSCP_ITEST=1 swift test --filter S3CreateBucketGated`: 4 passed.
  - It touched only `macscp-create-<purpose>-<12 hex>` buckets, each deleted afterwards (the delete status is asserted 2xx).
  - It never named `macscp-seed`, `macscp-second` or `macscp-probe-lock`.
- Full `swift test` (no `--build-system`): 5068 tests passed in the first run, then Swift Testing reported 2556 tests with one failure, the known `ViewTestabilitySpike` "Varying only isRegex leaves the pixels unchanged" (`off == on`). That is not mine.
- Waits in the tests are all `await`; there is no wall-clock ceiling.

## Rig measurement (2026-10-19)

On the rig, a second `createBucket` of a bucket the key already owns, with both switches on a bucket made with neither:
- returns success;
- does NOT turn Object Lock on (`hasObjectLock` stays `false`);
- the versioning request that follows DOES take effect (`.enabled`).

So `createBucket` on an existing name is not an error there and is not a lock-retrofit path, but it is a way to switch versioning on. My first draft of that gated test assumed it would throw, and the rig disproved it. The test now pins the measured behaviour, labelled as the rig's, and the protocol doc comment says "a caller that means 'a new bucket' checks the name is free". AWS answers a re-create differently by region (unmeasured here).

## Mutation probes

Run after the commit, because `scripts/mutation-probe` refuses a dirty tree. Every probe was RED (caught). None reported `PLANT CHANGED NOTHING` or `BUILD FAILED`. The tree was clean afterwards.

| Label | `--filter` | `--apply` | Caught by |
|---|---|---|---|
| drop-ip-rule | `S3BucketNameTests` | `perl -0pi -e 's/        if looksLikeAnIPv4Address\(name\) \{ return \.looksLikeAnIPAddress \}\n//' Sources/macSCPCore/S3/S3BucketName.swift` | `aNameSThreeWouldRejectIsRefusedHere`, `theBoundariesOfEachRuleAreRefused` |
| widen-ip-rule | `S3BucketNameTests` | `perl -0pi -e 's/groups\.count == 4 else/groups.count >= 4 else/' Sources/macSCPCore/S3/S3BucketName.swift` | `aNameBesideARefusalStillPasses` (the acceptance list) |
| min-length-2 | `S3BucketNameTests` | `perl -0pi -e 's/if length < 3 \{ return \.tooShort \}/if length < 2 { return .tooShort }/' Sources/macSCPCore/S3/S3BucketName.swift` | `aNameSThreeWouldRejectIsRefusedHere` |
| drop-lock-needs-versioning | `S3CreateBucketTests` | `perl -0pi -e 's/        if objectLock && !versioning \{\n            throw RemoteFSError\.protocolError\(\n                reason: \"object lock requires versioning, and versioning was declined\"\)\n        \}\n//' Sources/macSCPCore/S3/S3FileSystem.swift` | `objectLockWithoutVersioningIsRefusedBeforeAnyRequest` |
| drop-lock-header | `S3CreateBucketTests` | `perl -0pi -e 's/        if objectLock \{ headers\[\"x-amz-bucket-object-lock-enabled\"\] = \"true\" \}\n//' Sources/macSCPCore/S3/S3FileSystem.swift` | `objectLockRidesOnTheCreateAsASignedHeaderAndVersioningFollows` |
| drop-name-check | `S3CreateBucketTests` | `perl -0pi -e 's/        if let problem = S3BucketName\.problem\(with: bucket\) \{\n.*\n        \}\n//' Sources/macSCPCore/S3/S3FileSystem.swift` | `aNameThatFailsTheCheckSendsNothing` |
| versioning-only-with-lock | `S3CreateBucketTests` | `perl -0pi -e 's/if versioning \|\| objectLock \{/if objectLock {/' Sources/macSCPCore/S3/S3FileSystem.swift` | `versioningIsASecondRequestAfterTheCreate`, `aFailedVersioningRequestAfterTheCreateIsReportedAsItself` |

Not probed: dropping `|| objectLock` from `if versioning || objectLock`. It is an equivalent mutant, because the guard above it makes `objectLock` imply `versioning`, so I did not plant it.

## Concerns

1. **`LocationConstraint` is a deviation from the brief and is unmeasured.** The brief does not mention it. I added `S3SettingsXML.createBucketBody(region:)` because I recall AWS refusing a `CreateBucket` outside `us-east-1` without it. The code sends no body for `us-east-1` and a `LocationConstraint` naming the region otherwise. That split is from memory, and the doc comments say so. A unit test pins that the body is built and signed, but nothing was measured against AWS or any non-`us-east-1` store.
   - Risk: a store with an unusual region string (`auto`, for example) may dislike it.
   - It is one line to drop in `createBucket`, if you want the brief's literal behaviour.
2. **A failure of the versioning request leaves the bucket created and unversioned.** The error thrown is that request's own, and it is documented on the protocol. I chose no rollback, because deleting a bucket the call just made is itself a destructive act that can fail. A UI should be ready for "created, but versioning failed".
3. **A bucket-name rule is not checked here.** The brief's rules are implemented exactly. Left to the store: adjacent dots, dot beside hyphen, `xn--` and `sthree-` prefixes, `-s3alias` and `--ol-s3` suffixes, and uniqueness. The `S3BucketName` doc comment lists them. They would each need a `BucketNameProblem` case nobody asked for.
4. **Re-creating an owned bucket is not refused**, as measured above. A caller that wants "new bucket only" must check the name is free first. I did not add a pre-check request, which would be an extra round trip with its own race.
5. **The name-problem error is a `.protocolError` with an English reason**, e.g. `bucket name is not valid: tooShort`. It follows `setObjectLockDefault`'s days-below-one precedent and avoids a new finding, which the project counts at a case, a `Name` case, a `name` arm and four catalogue sentences. A UI that wants to say why calls `problem(with:)` itself, as `setCORS`'s finding already assumes. If you want a typed finding for this, that is a follow-up.

---

# Fix round 1 (commit `5cda8c5b`)

Coordinator ruling: four Important (I-1..I-4), three Minor (M-2, M-4, M-5), one question (M-3). Everything below is from the diff of `5cda8c5b` (`git show --stat 5cda8c5b` is the file list), the commands are the ones I ran, and their outputs are quoted.

## I-4: `createBucket(_ name: String, protection: BucketProtection)`

The brief fixed a two-`Bool` signature. The coordinator overrode it, so this changes a signature the brief fixed.

- `BucketProtection` is `.none`, `.versioned`, `.lockedAndVersioned` (`Sendable`, `Equatable`, `CaseIterable`), declared in `S3BucketSettings.swift`.
- Two internal accessors, `enablesVersioning` and `enablesObjectLock`, are what `createBucket` reads.
- The runtime refusal (`protocolError` "object lock requires versioning, and versioning was declined") is deleted, and so is its test, `objectLockWithoutVersioningIsRefusedBeforeAnyRequest`. The combination cannot be written any more.
- Decision B is not reversed. Refusing beat forcing, for the reason I gave: forcing silently resolves a contradiction in the caller's own request. The reviewer found the same words in two places in the tree, including `S3XMLText.escaped`, whose comment says dropping the character "would produce a well-formed document and is the worse answer". The enum is that same decision expressed where it cannot be got wrong. The protocol doc comment says so.
- The earlier "equivalent mutant" I declined to plant (`|| objectLock`) no longer exists, because `versioning || objectLock` is gone.
- Task 11's UI keeps its two toggles; only the Core call site changes.

## I-2: named refusals for a taken name

- New findings: `.bucketNameTaken` (from `BucketAlreadyExists`) and `.bucketAlreadyOwnedByYou` (from `BucketAlreadyOwnedByYou`). Both are payload-free.
- `RemoteFSFinding.swift` gained, for each: the case, the `Name` case, the `name` arm, `messageKey`, `message`, `logSentence` and `readsAsConnectionFailure` (`false`).
- Catalogues: four sentences each, 8 lines in all (`en`, `de`, `fr`, `pl`), after `core.finding.corsRuleInvalid`. The German ones address the user as du ("Du besitzt bereits einen Bucket mit diesem Namen").
- `S3ErrorCode.finding(forCode:status:path:)` has two new arms.
- `aRefusedCreateIsMappedAndNoVersioningRequestFollows` is now `aRefusedCreateIsMappedToItsOwnFindingAndNoVersioningRequestFollows`, parameterised over the two codes, and asserts the named finding.
- A control was added, `aConflictWithAnotherCodeKeepsTheGenericMapping`: a 409 with `OperationAborted` stays `.unexpectedStatus(code: 409)`, so the named findings are chosen by code, not status.
- The doc comment above the extension is corrected to say a refusal `S3ErrorCode` names keeps its finding and any other code falls through.
- `S3ErrorCode`'s "Five names" heading was stale before this round: it said five while the switch held three. It is now restated with its command.
  - `grep -c '^        case "' Sources/macSCPCore/S3/S3ErrorCode.swift` prints 5, and 3 on `git show HEAD:...` before the change (run against the pre-change tree).
  - BSD grep and ugrep agree; I ran both.

## I-1: signing region, not changed (as ruled)

- `createBucketBody`'s doc comment now carries the third unmeasured half: signing with `config.region` against the global endpoint of macSCP's AWS preset.
- The first two halves (the `us-east-1` split) are described as confirmed against AWS's reference by reading, with no request from this repository. This is the coordinator's confirmation. I did not measure it and the comment does not say I did.
- `docs/BACKLOG.md` has a new row after the `Content-MD5` row, titled "The AWS preset together with a region other than `us-east-1` is the one `CreateBucket` combination nobody has tried against a real endpoint". It carries the reference link, says nothing was measured, and lists what closing it takes.
- Its two commands are written without pipes and were run in the form committed:
  - `grep -n -e 's3.amazonaws.com' Sources/macSCPCore/S3/S3FieldSchema.swift` printed line 97, the preset's endpoint.
  - `grep -n -e 'region: config.region' Sources/macSCPCore/S3/S3RequestSigning.swift` printed line 71.

## I-3: routed to Task 11, not fixed here

My measurement stands: a second create of an owned bucket succeeds, the lock header does not retrofit, and `setVersioning(.enabled, ...)` takes effect. Since `.never` is unrepresentable at the store, that is a one-way door on a bucket the user did not mean to touch. The coordinator is writing the "check the name is free first" contract into Task 11's brief, where the sheet is offered only in bucket-list mode and already holds the list. So it stops being an unenforced sentence in a doc comment. I made no code change for it, and I have not seen Task 11's brief.

## M-2, M-4, M-5

- **M-2:** a probe on `createBucketBody`'s `guard region != "us-east-1" else { return nil }`. See the table below.
- **M-4:** `aNameBesideARefusalStillPasses` now says `a-.-b` and `1.2.3.-4` are deliberately-unchecked-at-this-layer names that AWS itself refuses, not names it accepts.
- **M-5:** the gated suite's buckets are named `macscp-<purpose>-<12 hex>` with `purpose` one of `create-both`, `create-versioned`, `create-plain` and `create-twice`. That gives `macscp-create-both-<12 hex>` and so on. Before the fix round I wrote `macscp-create-<purpose>-<12 hex>`, which was wrong: the names come out as `macscp-create-…` only because every purpose here begins with `create-`.

## M-3: answered plainly

The quoted red lines are an excerpt, not the whole output, and I did not label them as one.

- The command was `swift test --filter S3BucketNameTests > red.log 2>&1; grep -E "error:" red.log | sort -u | head -20`. The commit and report quoted the two distinct messages from it.
- `grep -c createBucket /tmp/claude-501/red.log` prints 0. That log contains no error about `createBucket`. So the red of `S3CreateBucketTests` was never observed: the compiler reported only the `BucketNameProblem` and `S3BucketName` errors. I do not know whether it stopped before type-checking the call or ran in another batch.
- Correction to the report's wording "I wrote the three test files before any source existed". Two did: `S3BucketNameTests` and `S3CreateBucketTests`. `S3CreateBucketGatedTests` was written after the implementation and its first run was green. The original commit message's red claim is accurate only for `S3BucketNameTests`.
- The same pattern recurred in this round's red. The complete distinct error list (not a head-truncated one) was:
  ```
  error: cannot find type 'BucketProtection' in scope
  error: type 'RemoteFSFinding' has no member 'bucketNameTaken'
  error: type 'RemoteFSFinding' has no member 'bucketAlreadyOwnedByYou'
  error: type 'RemoteFSFinding.Name' has no member 'bucketNameTaken'
  error: type 'RemoteFSFinding.Name' has no member 'bucketAlreadyOwnedByYou'
  ```
  No "has no member 'createBucket'" line appears there either. The new `createBucket(_:protection:)` tests were red only through `BucketProtection` not existing. The probes below are what shows those tests can fail.

## Commands and outputs

| Command | Output |
|---|---|
| `swift test` (no `--build-system`) | `✔ Test run with 5068 tests in 406 suites passed after 37.140 seconds.` and, for Swift Testing, `✘ Test run with 2556 tests in 230 suites failed after 49.186 seconds with 1 issue.` The one issue is `ViewTestabilitySpike` "Varying only isRegex leaves the pixels unchanged" (`off == on`), the known failure that is not mine. |
| `swift test --filter "S3BucketNameTests|S3CreateBucketTests|S3ErrorCodeTests|RemoteFSFindingTests|LocalizationParity|GermanAddressForm"` | `✔ Test run with 46 tests in 6 suites passed after 0.117 seconds.` |
| `MACSCP_ITEST=1 swift test --filter S3CreateBucketGated` | 4 passed, `✔ Test run with 4 tests in 1 suite passed after 0.269 seconds.` Throwaway buckets only, each deleted. |

The Swift Testing count is 2556 both before and after: one test removed (`objectLockWithoutVersioningIsRefusedBeforeAnyRequest`) and one added (`aConflictWithAnotherCodeKeepsTheGenericMapping`).

## Mutation probes after the signature change

All run on the committed tree with `scripts/mutation-probe`. Each reported RED (caught), none reported `PLANT CHANGED NOTHING` or `BUILD FAILED`, and `git status --short` was empty afterwards.

| Label | `--filter` | `--apply` | Caught by |
|---|---|---|---|
| drop-us-east-1-guard (M-2) | `S3CreateBucketTests` | `perl -0pi -e 's/        guard region != "us-east-1" else \{ return nil \}\n//' Sources/macSCPCore/S3/S3SettingsXML.swift` | `aPlainBucketIsOneBodylessPutOnTheBucketRoot` |
| lock-header-on-versioned | `S3CreateBucketTests` | `perl -0pi -e 's/var enablesObjectLock: Bool \{ self == \.lockedAndVersioned \}/var enablesObjectLock: Bool { self != .none }/' Sources/macSCPCore/RemoteFS/S3BucketSettings.swift` | `versioningIsASecondRequestAfterTheCreate` |
| drop-lock-header | `S3CreateBucketTests` | `perl -0pi -e 's/        if protection\.enablesObjectLock \{ headers\["x-amz-bucket-object-lock-enabled"\] = "true" \}\n//' Sources/macSCPCore/S3/S3FileSystem.swift` | `objectLockRidesOnTheCreateAsASignedHeaderAndVersioningFollows` |
| drop-name-check | `S3CreateBucketTests` | `perl -0pi -e 's/        if let problem = S3BucketName\.problem\(with: bucket\) \{\n.*\n        \}\n//' Sources/macSCPCore/S3/S3FileSystem.swift` | `aNameThatFailsTheCheckSendsNothing` |
| versioning-only-when-locked | `S3CreateBucketTests` | `perl -0pi -e 's/var enablesVersioning: Bool \{ self != \.none \}/var enablesVersioning: Bool { self == .lockedAndVersioned }/' Sources/macSCPCore/RemoteFS/S3BucketSettings.swift` | `aFailedVersioningRequestAfterTheCreateIsReportedAsItself`, `versioningIsASecondRequestAfterTheCreate` |
| drop-bucket-already-exists | `S3CreateBucketTests|S3ErrorCodeTests` | `perl -0pi -e 's/        case "BucketAlreadyExists":\n            return \.finding\(\.bucketNameTaken\)\n//' Sources/macSCPCore/S3/S3ErrorCode.swift` | `aRefusedCreateIsMappedToItsOwnFindingAndNoVersioningRequestFollows`, `aNamedCodeBecomesItsFinding` |

The probes from the first report that touched the deleted `objectLock && !versioning` guard (drop-lock-needs-versioning) no longer apply. The name-rule probes (`drop-ip-rule`, `widen-ip-rule`, `min-length-2`) are untouched by this round and were not re-run.
