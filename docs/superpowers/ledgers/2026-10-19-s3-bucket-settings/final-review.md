
Orientation done: spec read (intent + §10), plan/ledger located, 37 shipped-source files and 43 test files mapped.

**Unit suite, run by me:** `swift test` (no `--build-system` flag), from the worktree root.
Result: `✘ Test run with 2848 tests in 240 suites failed after 30.761 seconds with 1 issue.`
The single issue is `ViewTestabilitySpike.swift:202` ("Varying only isRegex leaves the pixels
unchanged", `off == on`) — the known pre-existing local failure, explicitly out of scope. No other
red. Log: `swift-test.log` in this session's scratchpad.

VERDICT: clean apart from the known pre-existing failure.

## Section 1 — Localization parity

VERDICT: resolved — see this section's closing VERDICT line and Section 8.

Commands run, from the worktree root:

- Key counts per catalogue: `grep -c '^"' Sources/MacSCPAppKit/Resources/<l>.lproj/Localizable.strings`
  → `en 1550, de 1550, fr 1550, pl 1550` (this counts LINES beginning with a quote, which is one
  key per line in these files).
- Key SETS: extracted with `sed -n 's/^"\([^"]*\)" *=.*/\1/p' … | sort` per language and `diff`ed
  pairwise against `en`, for both `Sources/MacSCPAppKit/Resources` and
  `Sources/macSCPCore/Resources`. All six diffs empty: the four catalogues declare exactly the
  same keys in both targets.
- Every key the new App sources name: 121 unique keys harvested from `key: "…"`,
  `L10n.string("…"`, `labelKey`/`helpKey` in the eight new/changed App files plus `titleKey: "…"`
  in `BackendDescriptor.swift`, then `comm -23` against the `en` key set. Empty: no key is
  referenced without a catalogue entry.

VERDICT: no finding. Parity holds on key sets and on every key the new code names.

## Section 2 — Cross-task integration of the five write paths

VERDICT: resolved — see this section's closing VERDICT line and Section 8.

I read all five models whole at HEAD rather than through the diff:
`CreateBucketModel.create`, `BucketVersioningModel.apply`, `BucketCORSModel.save`,
`ObjectLockModel.run`, `BucketObjectLockModel.save`.

**Error mapping and refusal wording — they agree.** Each of the four sentence mappers
(`CreateBucketModel.refusalSentence(for:)`, `BucketVersioningModel.message(for:applying:)`,
`BucketCORSModel.message(for:applying:)`, `ObjectLockLines.message(for:during:)`) has exactly
the same three-arm shape: `RemoteFSError.finding` → `finding.message` (Core-localized, carries
no store text); `permissionDenied`/`authenticationFailed` → that sheet's own "your access key is
not allowed…" line; everything else → a fixed read/apply sentence. No mapper reaches an error's
`reason`. The one deliberate divergence — `ObjectLockLines` routes a permission refusal during
`.applyingRetention` to `retentionRefused` instead of `denied`, because two causes share the
answer — is documented at the line and is the right call.

**What reaches the audit trail — consistent, and recorded at the right moment.** All five
record on both arms, with the sheet's own FIXED sentence as `failure:`, never the error's text.
Four of the five record immediately after the store accepts and BEFORE the read-back
(`apply`, `save`, `run`, `BucketObjectLockModel.save`), so a failed read-back cannot lose the
trace of an irreversible write; `create` records after the outcome is set, out of a bare
`catch` whose `Refusal` type cannot be anything but a refusal. `recorder` has no default value
at any of the five sheets or their five `…SheetItem` structs — checked with the row's own
command, `/usr/bin/grep -n -F -e 'let recorder: AuditRecorder?' Sources/MacSCPAppKit/ContentView.swift`,
which prints 5 lines, as the row claims.

**The new audit kinds are classified everywhere a kind must be.**
`ConnectionHistory.rows` lists all four explicitly; `AuditLogSheet.Filter.segment(of:)` was
rewritten from four catch-all inner switches into one exhaustive switch with no `default`,
which is what makes a fifth kind fail to compile rather than fall through — the four S3 kinds
had been falling through the old shape, so a COMPLIANCE retention was absent from the File Ops
segment. That is a defect this branch found in its own work and fixed.

**Lifecycle.** One `BrowserSession(` construction site exists in the whole App
(`ContentView.swift`), and `objectLockStates` is assigned on the next statement, so the
"cache is nil on an S3 session" shape — which would make the "Object Lock…" row and both
file actions enabled-and-inert — is not reachable. Nothing reassigns `remoteFS`. The cache is
session-scoped, dies with the session, no `deinit` cleanup. Sheets capture the capability at
presentation time. The write `Task`s are launched from the button action rather than from the
sheet's `.task`, so dismissing the sheet does not cancel a write in flight — correct for an
irreversible write, and the audit line still lands.

**Architecture invariants.** `S3BucketSettings` is queried with `as?` at every site I found
(`ConnectionActionContext`, `handleBrowserMenuEntry`, `BrowserSession.objectLockStates(for:)`);
nothing switches on `ConnectionKind` in the dispatch path — `ConnectionActionRoute` is keyed by
contribution `id` with no `default`, and `ConnectionActionRoute.isAvailable(_:in:)` answers
`false` for an unknown id so an unrouted row renders disabled. Nothing in Core knows about
windows. The rebuilt seam has no default value, so all 11 descriptor construction sites spell
it: `/usr/bin/grep -rn -o -e 'connectionActions:' Sources Tests --include='*.swift' | wc -l`
prints 12 OCCURRENCES — the one declaration in `BackendDescriptor.swift` plus 11 construction
sites (3 real descriptors, 8 test synthetics).

**The file actions are gated where they must be.** `BrowserContextMenu.entries` offers
`backendFileAction` only inside `if only.kind == .file`, so "Retention…" and "Legal Hold…"
never appear on a bucket row at the bucket list or on a prefix row inside one — which is
exactly where `ObjectLockTarget.resolve` would answer `nil` and the click would open nothing.

VERDICT: the seams agree on everything they must agree on EXCEPT one — four of the five write
paths read back what they wrote and `create` does not, which is finding F1 in Section 6. The
other finding in this area is F2 (the `deleteTree` probe storm), plus notes N2 and N3.

## Section 3 — Security invariants

VERDICT: resolved — see this section's closing VERDICT line and Section 8.

**COMPLIANCE.** The one irreversible write is gated twice and I could find no path round it.
`ObjectLockModel.run` consults only `canRun`, which is `RunBlocker.allCases.filter(isActive)`
being empty, over a `switch` with no `default`; `complianceNotAcknowledged` is active whenever
`focus == .retention && mode == .compliance && !acknowledged`. `acknowledged` is cleared by any
write to `mode` or `retainUntil`, by `load`, and by a completed write, so a tick cannot stand
for a date or a mode nobody read. `BucketObjectLockModel.save` adds `acknowledgementStale`,
which compares the stamped day against the day the sentence names now. The acknowledgement
sentence is built from the same `retainUntil` the write sends. `weakensAComplianceRetentionInForce`
stops a GOVERNANCE write over a live COMPLIANCE retention before the attempt, so the sheet no
longer offers a button for a change the store must refuse.

**No way to enable Object Lock on an existing bucket.** The protocol has no such method, and
`S3ObjectLockTests.theProtocolOffersNoWayToEnableLockOnAnExistingBucket` is a correctly built
guard: ten positive `#expect(surface.contains(…))` anchors read from the declaration beside
the negative filter, and a companion test (`theSurfaceScanFindsAPlantedEnableMethodAndReadsLabels`)
drives the scanner with a planted `enableObjectLock` and shows it is found, so the scan has been
seen to find something. `setObjectLockDefault` reads the bucket first and refuses one with no
lock, which is what stops it being an enable call on the rig's permissive store.

**TOFU.** Nothing on this branch touches host-key handling; the shipped-source diff names no
host-key, decider or trust symbol.

**Secrets.** No secret, key, token or endpoint reaches a store, state, log, `reason:` string,
notification, audit `detail` or test failure message, as far as I can establish:

- Every sheet maps errors to fixed sentences (Section 2) and the audit `failure:` is that
  sentence. `AuditRecorder`'s four new methods compose `detail` from the bucket name, the key,
  the mode, a day count and an ISO date — nothing from the store, and `recordCORSChanged`
  deliberately writes only the rule COUNT, not origins or headers.
- `S3ErrorCode` never reads `<Message>`; `finding(forCode:status:path:)` carries only the
  caller's own `path`; `perKeyRefusals` echoes a key that `deleteTree` looks up in the batch it
  sent and replaces with its own spelling.
- The second exit is handled: `BucketSettingsAuditTests` keeps its canary in a named constant
  (`private static let storeWords`), computes the `Bool` first and asserts
  `#expect(leaked == false)`, so neither the value nor its spelling can reach a failure
  message. That is the project's own rule, applied correctly.
- The only credential-shaped literals in the branch's test files are the DOCKER RIG's own
  published credentials in `Tests/macSCPCoreTests/Support/S3SettingsFakeTransport.swift`
  (`S3SettingsRig.config`). They are in CLAUDE.md and in the compose file, and
  `grep -rno 'macscpsecretkey' Tests | wc -l` prints 12 occurrences across 12 lines in 11
  files, 10 of which predate this branch. Not a leak; consistent with precedent.

VERDICT: no finding. The security invariants hold, including the one that matters most.

## Section 4 — Concurrency and the cooperative pool

VERDICT: resolved — see this section's closing VERDICT line and Section 8.

- Blocking waits in test targets: `grep -rno` over `Tests/` prints 2 occurrences of
  `syncShutdownGracefully()`, 3 of `futureResult.wait()` and 2 of `DispatchSemaphore`, and
  `grep -rln` over the same three patterns lists exactly four files — `AgentAuthTests.swift`,
  `LoopbackTLSStub.swift`, `SSHPrivateKeyLoaderTests.swift` and
  `TestsNeverBlockThePoolGuardTests.swift`. **None of the branch's 43 test files is among
  them.** Every wait in the new suites is an `await`.
- Wall-clock ceilings: I grepped the branch's new test files for `elapsed`, `ContinuousClock`,
  `Date().timeIntervalSince` and `timeLimit`. The only matches are `.timeLimit(.minutes(1))`
  hang bounds on three in-flight-write tests and one `Date()` used to BUILD a retention date in
  a gated test. No `elapsed < …` anywhere. Correct per the project's rule.
- Swift 6 strict: `swift test` built every target clean. The log's only `warning:` line is
  SwiftPM's own `missing creator for mutated node` about SwiftTerm's bundle — not a
  diagnostic from this branch's code.
- `ObjectLockStateCache` is `@MainActor`; its in-flight read is an unstructured `Task`, which
  is deliberate and correct (a dismissed sheet must not cancel a read another caller awaits),
  and two concurrent asks share one read. An answer is cached, a failure is not.

VERDICT: no finding.

## Section 5 — The measurement record (spot check, not an audit)

VERDICT: resolved — see this section's closing VERDICT line and Section 8.

Six committed commands, extracted from the committed text and run UNREPAIRED in the form they
are committed (all are `/usr/bin/grep` with `-e` patterns and no pipe, or a `perl … | wc -l`
outside a table cell):

1. `/usr/bin/grep -c -F -e 'try Self.sheetSource()' Tests/macSCPAppKitTests/AuditLogSortWiringGuardTests.swift`
   → **8**, and the same with `-e 'try Self.sheetCode()'` → **1**. Row claims 8 and 1 (lines).
   Reproduces.
2. `/usr/bin/grep -n -F -e 'let recorder: AuditRecorder?' Sources/MacSCPAppKit/ContentView.swift`
   → **5 lines**. Row claims five. Reproduces.
3. `/usr/bin/grep -rl -F -e 'macscp-probe-lock' Tests` → the exact five files the row names
   (`S3BucketSettingsGatedTests`, `S3CORSGatedTests`, `S3CreateBucketGatedTests`,
   `S3ObjectLockGatedTests`, `Support/S3SettingsFakeTransport`). Reproduces.
4. `/usr/bin/grep -o -e 'WITHDRAWN 2026-10-12' docs/BACKLOG.md` → **9** printed lines. The row
   says "It prints NINE, not seven — the two extra matches are the copies of the pattern inside
   this sentence's own two commands", i.e. the row had already re-run its command after writing
   the sentence and accounted for the self-reference. Reproduces.
5. `/usr/bin/grep -n -F -e 'maintainer ruling A' Sources/macSCPCore/S3/S3FileSystem.swift` → 2
   lines; the same with `-e 'maintainer ruling A, measured'` → **nothing**. That is the shape
   the round-3 correction claims: the withdrawn phrase survives only inside its own withdrawal.
6. `GermanAddressFormTests`'s two committed `perl` commands. The historical one, which reads the
   German catalogue at `eb0c387f` out of the object store and pipes it through the pattern,
   prints **22** — exactly the figure the withdrawn sentence rested on, which is what makes the
   replacement checkable. The live one prints **62** today; the comment dates its own figure
   ("it was 51 on 2026-10-20, at the commit that carries this paragraph") and says it moves with
   every added du-string, and Tasks 9–12 added more after Task 8 wrote it. Not a contradiction.

Six for six, no repair needed on any. I also read the ledger's closing section: it records the
gated suites as NOT run, the GUI as never seen, Step 1 (user docs) as another dispatch, and
separates three kinds of approval evidence while stating plainly that the maintainer's own words
approve the PLAN and not the design document. "Ruling 26's cost, now measured — the figure I gave
was too small" is a cost correction the record made against itself.

VERDICT: the measurement record is honest on every figure I checked. No finding. I did not find
a ruling whose stated cost is smaller than what I can measure.

## Section 6 — Findings, ranked by what would bite a person using this

VERDICT: resolved — see this section's closing VERDICT line and Section 8.

### F1 — `CreateBucketModel.create` is the only one of the five write paths that never reads back, and the thing it fails to check is Object Lock

**Severity: the highest on this branch.** Verified by reading the shipped source at HEAD, and
the behaviour it depends on is the branch's OWN measurement, not my conjecture.

File and symbols: `Sources/MacSCPAppKit/CreateBucketSheet.swift`, `CreateBucketModel.create(via:recorder:)`
and `CreateBucketModel.createdSentence` / `createdLine`.
Measurement it rests on: the doc comment of `S3BucketSettings.createBucket(_:protection:)` in
`Sources/macSCPCore/RemoteFS/S3BucketSettings.swift`, and
`S3CreateBucketGatedTests.recreatingABucketTheKeyOwnsDoesNotEnableObjectLockButDoesEnableVersioning`.

**What is wrong.** The spec's own anti-goal (§3) is: "A setting that silently did nothing. Every
write is read back from the store, never assumed from a 200." Four of the five write paths honour
it — `BucketVersioningModel.apply` re-reads `versioning(ofBucket:)`, `BucketCORSModel.save`
re-reads `cors(ofBucket:)` through `adopt`, `ObjectLockModel.run` re-reads the retention or the
hold, `BucketObjectLockModel.save` re-reads `objectLockDefault`. `create`'s success arm is:

```
try await settings.createBucket(bucket, protection: choice)
takenNames.insert(bucket)
outcome = .created
recorder?.recordBucketCreated(bucket: bucket, protection: choice, failure: nil)
```

No read. It asserts success from the absence of a throw, which for this one call is exactly what
the measurement says is not safe. The branch's own words, in the protocol doc comment: "The Docker
rig answers a second create of a bucket the key owns with success, **does not let the Object Lock
header retrofit a lock onto it**, and takes the versioning request that follows (measured
2026-10-19)."

**Failure scenario, with inputs and the wrong outcome.** A user is connected in bucket-list mode
to an S3-compatible store that answers a re-create with 200 (measured: the project's own RustFS
rig; AWS answers `BucketAlreadyOwnedByYou` in most regions and IS now caught, so this bites the
non-AWS stores macSCP exists to support). The pane's bucket listing is from when they arrived at
it — minutes or hours ago, and nothing refreshes it when the sheet opens. They open
"Create Bucket…", type `reports-archive` (a bucket they already own but that is not in the stale
listing), tick **Object Lock**, and press Create. Then:

- `CreateBucket` with `x-amz-bucket-object-lock-enabled: true` → 200. The lock is NOT applied.
- `setVersioning(.enabled)` → 200. Versioning is now ON for a bucket they did not mean to touch,
  and that is a one-way door: it can only ever be suspended, never returned to never-versioned.
  Every future version is kept and billed.
- The sheet shows **"The bucket "reports-archive" was created."** and the audit line reads
  `created bucket reports-archive with versioning and Object Lock`.

The person now believes a bucket is protected by Object Lock when it is not. That is the belief
the whole Object Lock half of this branch exists to make trustworthy, and it is the one that
cannot be checked afterwards without opening another sheet the success sentence does not point
them at. Note the asymmetry the branch already built: the FAILURE sentence
(`existsIncompletelyTemplate`) is carefully worded — "It may not have those settings. Open
Versioning and Object Lock for it to see what it has" — while the SUCCESS sentence asserts
flatly that the bucket was created.

**Why no task-scoped reviewer saw it.** Task 11 was reviewed against its own brief, which asked
for the taken-name check (Rulings at ledger lines 618 and 656) and got it. The anti-goal is a
property of the five paths TOGETHER, and the string "read back" / "read-back" does not occur once
in the 4637-line ledger — the comparison was never made.

**The cheapest fix, for the maintainer to weigh:** on the success arm, when
`choice != .none`, read the bucket once (`hasObjectLock` for `.lockedAndVersioned`,
`versioning` for `.versioned`) and show `existsIncompletelyLine` — the sentence that already
exists and already says the right thing — when the read does not confirm what was asked for.
Re-reading the pane's listing when the sheet opens would narrow the window but not close it.

### F2 — `S3FileSystem.deleteTree` probes the lock state of EVERY refused key in a batch, so a folder delete refused on permissions costs up to 2000 extra signed requests

**Severity: medium.** Verified by reading the loop at HEAD and by reading the tests that cover it.

File and symbols: `Sources/macSCPCore/S3/S3FileSystem.swift`, the per-key refusal loop inside
`deleteTree(at:lookup:)`, and `lockFinding(forRefusedDeleteOf:inBucket:)`.

**What is wrong.** `DeleteObjects` reports a key it could not delete inside an HTTP 200
`<DeleteResult>`, one `<Error>` per key. The loop walks every one of them, and for each whose
code is `AccessDenied` — which is what a key lacking `s3:DeleteObject` gets for EVERY key —
calls `lockFinding`, which issues `GET ?legal-hold` and then `GET ?retention`. Neither
establishes a lock on a bucket without Object Lock (the rig answers `400 InvalidRequest` to
both; `noLockInForceMeansTheOrdinaryRefusal`'s third argument measures exactly that at 2
requests), so the loop continues to the next refusal. Batches are up to 1000 keys, and
`Task.checkCancellation()` runs once per BATCH, before the delete, never inside this loop.
There is no cap, and no memory of "this bucket has no Object Lock" — `ObjectLockStateCache`
is an App-layer type and Core does not reach it.

**Failure scenario.** A user's access key has `s3:ListBucket` but not `s3:DeleteObject` (a
read-mostly key, or a bucket policy denying deletes on a prefix — ordinary configurations).
They select a folder holding 1000 objects and press Delete. macSCP sends one `DeleteObjects`,
gets a 200 listing 1000 `AccessDenied` entries, and then sends **2000 further signed GETs**
before throwing "one or more objects could not be deleted". At a 100 ms round trip that is
about 200 seconds in which the delete appears to be working and the per-batch cancellation
check has already gone by. The user sees a long unexplained stall ending in a generic refusal.

All four existing tests of this path (`aKeyRefusedUnderALockIsNamedAtTheCallersOwnKey`,
`aKeyTheBatchNeverHeldIsNeverShownAsAPath`, `theCallersSpellingIsUsedWhenTheStoreEchoesAnEquivalentOne`,
and the single-file `aDeleteOfASingleFileSaysItIsUnderALegalHold`) use a batch with exactly ONE
refused key, so the volume was never exercised. The lock case is cheap — it throws on the first
established hold — so it is specifically the no-lock case, the common one, that pays.

**Cheapest fix:** probe at most the first refused key (or the first few), or stop probing once
one probe has answered "this bucket has no Object Lock". Either keeps every property the four
tests assert.

### F3 — an account with no buckets now connects and lands on a blank pane; §6.1's "offer the one action that resolves it rather than being blank" is met only by an unlabelled toolbar menu

**Severity: low-to-medium, and it is the flow this branch deliberately unlocked.** Verified by
reading `BrowserPane.swift` whole and by reading `RemoteBrowserViewModel.State`.

Files and symbols: `Sources/macSCPCore/S3/S3FileSystem.swift` (the `.bucketList` arm of
`connect`, now `_ = try await fs.listBuckets()`); `Sources/MacSCPAppKit/BrowserPane.swift`
(the body's overlays).

**What is wrong.** Task 6 removed the `RemoteFSError.bucketListEmpty` refusal so the first
bucket of an account can be created. The spec's own sentence for that task (§6.1) is: "the empty
state it creates must offer the one action that resolves it rather than being blank."
`RemoteBrowserViewModel.State` has three cases — `loading`, `loaded`, `failed` — so a
zero-bucket account reaches `.loaded` with zero items, and `BrowserPane`'s body draws an overlay
only for `.loading` (a `ProgressView`) and `.failed` (the message plus "Try again"). There is no
empty-state view anywhere in the pane. The only route to the action is the toolbar's
`ellipsis.circle` menu, whose own label is "Connection Actions" and which carries no hint that
it contains the thing that resolves what the user is looking at.

**Failure scenario.** A person creates a fresh S3 account, enters their key in macSCP and
connects. Before this branch they got a refusal on the form that at least said something. Now
the connection succeeds and they are looking at an empty table with column headers, no message,
and no visible button. Nothing on screen says "this account has no buckets" or "create one".
They have to find an unlabelled ellipsis menu in the toolbar.

I did NOT find a coordinator ruling on this; `blank` appears in the ledger only in the Task 6
review's quotation of the implementer's report ("an empty account opens on a blank browser"),
which was cited there to withdraw a different claim, and the state was not revisited after
Task 11 landed the sheet. This is also one of the things that "has never been verified visually"
covers, so I am reporting the code shape, not a screenshot.

**Cheapest fix:** one sentence over an empty `.loaded` bucket list, with the catalogue key and
four translations, saying the account has no buckets yet and naming where Create Bucket is. The
`en` string already exists in spirit — `s3.cors.none` is the same shape.

## Section 7 — Notes (no failure scenario I can state, so labelled as notes)

VERDICT: resolved — see this section's closing VERDICT line and Section 8.

**N1 — the Object Lock surface guard's negative half buys one spelling.**
`S3ObjectLockTests.theProtocolOffersNoWayToEnableLockOnAnExistingBucket` filters the scanned
surface for names containing both `enable` and `lock` (lowercased). `enableObjectLock`,
`objectLockEnable`, `setObjectLockEnabled` all match; `turnOnObjectLock(ofBucket:)` or
`allowObjectLock(…)` would not. The guard is otherwise exemplary — ten positive anchors read
from the declaration, plus a companion test that drives the scanner with a plant and shows it
finds one. I am not calling it a finding because the protocol is nine methods long and the
property is also carried structurally by `setObjectLockDefault` refusing a lockless bucket. It
is the shape CLAUDE.md warns about ("a scan that keeps buying one spelling"), worth knowing if
the surface ever grows.

**N2 — `BucketCORSModel.reanalyze` runs five XML passes on the MainActor per keystroke.**
Setting `text` calls `reanalyze`, which calls `read`, which does `parseCORS`, `corsBody`, two
`ElementCensus.of` and a second `parseCORS` — all synchronous, all on the main actor, on every
character typed in the text pane and on every field edit in the form pane. CORS configurations
are small (AWS caps rules at 100) so I cannot state a scenario where this is felt, and
`read(_:)` is already `nonisolated static` so it could be moved off if it ever is.

**N3 — `ObjectLockStateCache`'s in-flight read outlives teardown.** The read is an unstructured
`Task` holding `settings` (the `S3FileSystem`) strongly, and nothing cancels it. If a tab tears
down while a `hasObjectLock` read is in flight, the file system stays alive until the request
finishes or fails. The unstructured `Task` is the right call for its stated reason (a dismissed
sheet must not cancel a read another caller awaits) and S3 has no channel to leak, so this is a
note rather than a lifecycle finding.

**N4 — the gated half and the screen remain unmeasured, which the branch says plainly.**
`MACSCP_ITEST=1 swift test` has never run on this branch and nothing has been seen on screen;
both are recorded as open items, I did not start the rig and did not launch the app, and I
flag them here only because F1 and F3 are both in territory those two would have covered.
F1's mechanism is pinned by a gated test that has never been run
(`recreatingABucketTheKeyOwnsDoesNotEnableObjectLockButDoesEnableVersioning`) and by the manual
2026-10-19 probe recorded in the spec, which did run.

## Section 8 — Overall verdict

**SHIP WITH F1 AND F2 FIXED. F3 at the maintainer's discretion.**

The branch is sound work, and unusually so: 2848 AppKit tests and 5085 Core tests pass with the
one known pre-existing failure, the four catalogues are at exact key parity and every one of the
121 keys the new code names is present, no test target blocks the cooperative pool and no test
carries a wall-clock ceiling, the five refusal mappers agree with each other, the audit trail
carries no store text and handles the `#expect` second exit correctly, the COMPLIANCE gate holds
under every path I could find, the rebuilt seam came back on the terms its deletion set, the
guards this branch touched were all STRENGTHENED (the audit-label guard widened from `en` to all
four languages, the sort-wiring guard moved onto blanked source, the German du-form guard's stale
figure withdrawn and removed from its own failure message), and six committed verification
commands reproduced their figures unrepaired, including one whose own text changes its answer and
which accounts for that.

F1 is the one I would not ship: it is a flat success sentence over a write nobody checked, on the
one switch whose whole purpose is to be trustworthy, and the measurement that makes it a real
outcome is the branch's own.

Not verified: `MACSCP_ITEST=1` (rig down, out of reach, not started — the gated suites have never
run on this branch); anything on screen (no GUI run, no screenshot, app never launched); line-by-line
correctness of the thirteen tasks (re-running that pass was explicitly out of scope and I did not);
whether AWS answers a re-create with `BucketAlreadyOwnedByYou` in every region, which is what would
bound F1's reach on AWS specifically; the `docs/` half beyond the six-command spot check in Section 5;
the user-documentation pages, which live in a `noix-docs` worktree this session cannot reach. I planted
no mutation and ran no `scripts/mutation-probe`, so no claim here rests on a probe; the two scan guards
I examined (`S3BucketSettingsSurface`, `ConnectedTabFormInvariantTests`) each already carry a plant or
`#require`d positive anchors of their own, which is why I did not add one.

Not verified.
