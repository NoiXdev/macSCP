# The typed-findings tails — design

**Status:** approved by the maintainer 2026-10-01. Closes the seven
`docs/BACKLOG.md` rows the typed-findings plan left behind on 2026-09-28
(rows at lines 172–178), and three stale spots in `docs/BACKLOG.md` itself
found while reading them.

**Base:** `develop` at `0f55446d`. Every number and line citation below was
measured at that commit on 2026-10-01, not carried over from the rows.

---

## Why this is one piece of work

The seven rows are not seven unrelated defects. Four of them
(`resumeNotSupported`, `readsAsConnectionFailure`, `logSentence`, the
Depth-0 PROPFIND wording) are statements about one type,
`RemoteFSFinding`, and two more are the last two untyped copies of
conditions that type already names. They were deferred together because
the typed-findings plan's scope was "convert the sites", and each of these
is a question about the type rather than about a site.

## What was measured first, and what it changed

Three measurements made before the design, each of which moved the answer
away from what the row assumed.

### 1. `readsAsConnectionFailure` does not decide resumability alone

The row says one property "decides the localized frame AND whether a
mid-transfer failure is resumable", and asks for the two questions to be
split. Read at `TransferQueueViewModel.swift:1204`, `isConnectionFailure`
only selects a BRANCH; inside it four further gates decide the status:

| gate | line | outcome |
|---|---|---|
| `job.bypassConflictCheck` (editor write-back) | `:1207` | `.failed(.interrupted)` |
| `job.destinationTabID != nil` (cross-session) | `:1216` | `.failed(.interrupted)` |
| `!destination.supportsAppendResume` | `:1231` | `.failed(.interrupted)` |
| otherwise | `:1240` | `.interrupted`, job retained — resumable |

The case the row calls "close to the opposite of resumable",
`.redirectBodyNotResendable`, cannot reach the last row of that table, for
two independent reasons:

1. It is recorded only when `request.httpBodyStream != nil ||
   task.originalRequest?.httpBodyStream != nil`
   (`S3RedirectSessionDelegate.swift:119`), and the comment above that line
   records that the S3 path builds no such body today — every body is a
   `Data` in memory or absent. It is the announcement site for a future
   streaming upload.
2. A request carrying a body is an upload, so the transfer's DESTINATION is
   S3, and `S3FileSystem.supportsAppendResume` is `false`
   (`S3FileSystem.swift:927`) — gate 3 catches it.

What IS reachable is `.redirectUnreadable` / `.redirectNotResignable`
during a DOWNLOAD, where the destination is the local file system and
appendable. There `.interrupted` is the right answer: the request never
reached a server that answered it, and the partial file is sound.

**So the two questions do not collide on any reachable path**, and
splitting the property would change no behaviour while adding a second
exhaustive switch to keep. The decision (maintainer, 2026-10-01) is to
close the row by measurement and pin the argument instead.

### 2. `logSentence` is derivable from the `en` catalogue — with one exception

The row asks for a guard comparing `logSentence` against the `en` entry for
the same key, and names three existing tests as the pattern. Those three
compare preserved CONSTANTS, not `logSentence`, and `logSentence` is
deliberately written differently: the doc comment at
`RemoteFSFinding.swift:188` says the log's sentences are lower-case phrases
that a `reason=` field completes. A plain equality guard is therefore
impossible.

Measured across all 17 findings on 2026-10-01, comparing each
`logSentence` with its `en` entry lower-cased at the first character:
**16 of 17 match exactly.** The one exception is `resumeRangeIgnored`,
whose sentence opens with the proper noun "S3" — lower-casing it yields
"s3".

The relation that holds for all 17 is therefore: equal, with the first
character compared case-insensitively. That still fails on any wording
change anywhere in either text, which is what the row wants.

Counted in the same pass: **0 of the 17** `en` finding sentences end with
a period, so no trailing punctuation has to be stripped. A guard that
stripped one anyway would carry a branch nothing exercises.

**Recount, 2026-10-01, after execution.** T2 added the eighteenth finding
on the same day, so the figures above are the design-time ones and the
count in them is not the count at HEAD. Re-measured at `424512a4` for the
closeout: **17 of 18** match under the naive rule — the exception is
still `resumeRangeIgnored` and its "S3" — **18 of 18** under the
first-character rule, and **0 of 18** `en` finding sentences end with a
period. The relation itself is unchanged.

### 3. `supportsAppendResume` defaults to `true`, in a protocol extension

Not named in any of the seven rows. `RemoteFileSystem.swift:207` gives the
requirement a default of `true`, so a conformer that does not override is
appendable by silence. Counted 2026-10-01: six conformers in `Sources/` —
`S3FileSystem` (`:45`), `LocalFileSystem` (`:8`), `CitadelFileSystem`
(`:38`), `WebDAVFileSystem` (`:6`), and two diagnostics stand-ins,
`ThroughputPayload` (`ThroughputProbe.swift:581`) and `ThroughputSink`
(`:638`). Exactly two override, both to `false`: S3 and WebDAV.

This is the general form of what the `resumeNotSupported` row calls its
unpinned PAIR — "a backend that later answers `true` would make the
finding live with nothing announcing it".

### Citations checked rather than trusted

26 line citations from the seven rows were re-read at `0f55446d`. All are
substantively correct. One is wrong in its path:
`RemoteBrowserViewModel.swift` is in `Sources/macSCPCore/Presentation/`,
not `Sources/MacSCPAppKit/`. That is the third stale spot this work fixes.

**Correction, 2026-10-01, after execution.** That last sentence is false,
and so is the third item of the T7 list below: `docs/BACKLOG.md` never
carried the App module's path for `RemoteBrowserViewModel.swift`. The
`:172` row cites a BARE `RemoteBrowserViewModel.swift:938` with no module
path at all. The wrong one comes from this plan's own Task 7 step
(`docs/superpowers/plans/2026-10-01-typed-findings-tails.md:1418`), the
one line in the repository spelling the FULL
`Sources/MacSCPAppKit/RemoteBrowserViewModel.swift`. The shorter string
now stands in four places, three of them these corrections, which is why
the absence claim below is anchored at a commit rather than at the tree.
`git grep "MacSCPAppKit/RemoteBrowserViewModel" 0f55446d -- docs/`
returns nothing — anchored at the base commit, because a document that
quotes the string it calls absent makes that string present, which is how
the first attempt at this verification falsified itself. There were TWO
stale spots in that file, not three; the closeout qualified the bare
citation to `Sources/macSCPCore/Presentation/` anyway and recorded the
correction in the row.

---

## Decisions taken by the maintainer, 2026-10-01

1. **One new finding, not two.** The Depth-0 PROPFIND wording (row at
   `:173`) gets its own finding. `S3MultipartXML.parseUploadID` (row at
   `:175`) does not: its in-scope half is the single phrase "no UploadId
   element", which reaches no reader today, and a second finding would add
   four more sentences to the `fr`/`pl` catalogues, whose native-speaker
   review was closed unreviewed on 2026-09-28.
2. **Row `:177` closes by measurement**, with no behaviour change and no
   property split — see measurement 1.

**Correction, 2026-10-01, after execution.** Decision 1's stated reason
for `parseUploadID` is false: the phrase DOES reach a reader.
`parseUploadID` <- `S3Uploader.uploadMultipart` <- `S3FileSystem.write`,
which rethrows unchanged; the app's `TransferFailureLabel` renders
`.protocolError` as the translated `transfers.failure.protocolError` with
this English text appended as a MARKED technical detail, and the CLI
prints it after `Error: `. The decision stands, with its reason corrected:
the reader already gets a translated sentence with the English arriving
labelled as technical, so typing the in-scope half would trade that pair
for one translated sentence with no suffix — a real but small gain
against four catalogue sentences, two of them unreviewed. The maintainer
was given a false premise for this choice and should know it. The same
correction applies to T4's paragraph below, which repeats the phrase
"reaches no reader"; the comment committed at the site says the corrected
thing.

---

## The seven items and their resolution

### T1 — `supportsAppendResume` pinned per conformer

Closes the open half of row `:172` and completes row `:177`.

A test asserts each of the four production backends' answer by name
(`LocalFileSystem` and `CitadelFileSystem` take the extension default
`true`; `S3FileSystem` and `WebDAVFileSystem` override to `false`), and a
source scan asserts two sets by name: the conformers in `Sources/` (the six
above) and the types that override `supportsAppendResume` (S3 and WebDAV,
both `false`). A set is stronger than a count — a conformer swapped for
another turns it red too. Both halves are positive checks: set equalities
that fail loudly the moment what they name moves, per `CLAUDE.md`,
"Guards that name what they watch".

**Correction, 2026-10-01, after execution.** Two claims in the paragraph
above were weaker in the tree than on the page, and both are corrected
here rather than quietly rewritten.

1. There is no "count that must match". The guard asserts set EQUALITIES
   — the conformer set, the override set, and the protocol extension's
   own default read into a third, separate expectation — and no count
   anywhere. The sentence as first written is what this spec's own section
   argues against.
2. "A seventh cannot inherit `true` in silence" promises more than the
   code delivers. The source half is BEST-EFFORT over declaration headers.
   Eight defects were found in its scans during execution: six misses (a
   keyword list without `extension`; an `enum`; a header wrapped over two
   lines; a conformance through a refined protocol; a refinement composed
   with `&`; an attribute before the type) and two non-misses (an override
   attributed by walking back to its enclosing type; the protocol
   extension's own default counted as an overrider). Five of the six
   misses were found by a fresh reader planting a spelling the previous
   list did not contain. The guard's own doc comment now says this, and
   names the spellings it does not read as an open list rather than a
   closed one.

The structural alternative — deleting the extension default so the
compiler demands an answer — is an open row in `docs/BACKLOG.md` for
the maintainer, not something this plan decided. Its cost, corrected in
fix round 1 of the closeout: **30 single-line conformer headers across 22
files under `Tests/`**, not the 32 across 23 first written here. Three
counters on this branch produced three different totals (32, 30, 43) from
three different regexes, so the figure is only a measurement when it
travels with its derivation; the row in `docs/BACKLOG.md` carries the
grep, its 37 matches in 25 files, and all seven excluded lines named one
by one. What the first count got wrong: it excluded the two string-literal
fixture lines in the append-resume guard and missed the two in
`RemoteFileSystemReadStreamCycleGuardTests.swift` (`:133`, `:152`), which
were never read.

The decision recorded in code at `WebDAVFileSystem.supportsAppendResume`:
plain WebDAV has no partial PUT, so `false` is permanent rather than
provisional, and the `resumeNotSupported` throw in
`write(path:mode:contents:)` stays as defence in depth with its catalogue
entries accepted as unreached from production. (Written as `:417` and
`:450` here at design time; Task 5's bound-stream seam moved them to
`:452` and `:485`, so both are named by symbol instead — corrected in
fix round 1 of the closeout.)

The reachability argument of measurement 1 is written at
`RemoteFSFinding.readsAsConnectionFailure`, naming the four gates and both
independent reasons.

### T2 — a finding of its own for a Depth-0 PROPFIND body

Closes row `:173`.

`WebDAVPropfindParser.parsed(_:)` (`:77`) is private and shared by three
readers, and throws `.listingUnparsable` at `:101` for all of them. It
gains a parameter naming the finding to throw, and each reader passes its
own:

| reader | line | depth | finding |
|---|---|---|---|
| `parse(_:base:requestedPath:)` | `:15` | 1, a real listing | `.listingUnparsable` (unchanged) |
| `firstResourceIsCollection(_:)` | `:49` | 0, one resource | the new finding |
| `entityTag(_:base:at:)` | `:67` | 0, one resource | the new finding |

The new case is added to `RemoteFSFinding`, to `Name`, to `name`, to
`messageKey(for:)` (no format specifier — it takes no payload), to
`message`, to `logSentence`, and to `readsAsConnectionFailure` (`false`:
a malformed body is a fact about the answer, which a retry would meet
again). Every one of those switches is exhaustive with no `default:`, so
the compiler demands each arm.

Four catalogue sentences: `en`, `de` (addressing the user as *du*), `fr`,
`pl`. `LocalizationParityTests.everyRemoteFSFindingHasItsOwnSentence`
already walks `Name.allCases` and requires a sentence per finding per
catalogue, and requires it to be unique within its catalogue — so the
guard enforces both the presence and the distinctness without being
edited.

The finding count goes from 17 to 18.

### T3 — `parseObjectKeys` throws the finding it describes

Closes row `:174`. `S3FileSystem.swift:1204` throws
`RemoteFSError.protocolError(reason:)` with the same English condition
`.listingUnparsable` names and `S3ListParser.swift:41` already throws as a
finding. It becomes `RemoteFSError.finding(.listingUnparsable)`, removing
the last untyped copy of that condition.

Behaviour today: the text is dropped before any reader, because
`allObjectKeys(bucket:underPrefix:)` (`:1128`) is reached only from
`rename` (`:804`) and `deleteTree` (`:880`), neither of which the transfer
queue's mapper catches. The change is therefore invisible today and
correct the moment either operation joins the queue's catch set, which is
the row's own argument.

**Correction, 2026-10-01, after execution.** Both halves of the paragraph
above are false, and they were false when it was written — they were
carried over from `docs/BACKLOG.md:174` and not re-measured.

1. There were TWO untyped copies of this condition, not one:
   `S3FileSystem.parseObjectKeys` and `S3ListParser.hasAnyEntries`, the
   second in the same file as the sibling cited above as already typed. It
   was found by `grep -rn "Failed to parse S3 ListObjectsV2" Sources/`
   after the first had been converted, and T3 was amended to type both.
2. The change is NOT invisible. `RmCommand.swift:40`/`:48` calls
   `deleteTree(at:)` and `delete(path:)`, which reach both sites; the CLI
   prints the error through `Sources/macSCPCore/CLI/CLIErrorMapping.swift`
   (`:313` for `.protocolError`, `:332` for `.finding`), and
   `RemoteBrowserViewModel.message(for:path:)` renders it in the browse
   banner (`.protocolError` at `:1288`, `.finding` at `:1275`).

Measured delta: the CLI's `rm` loses Foundation's detail text in exchange
for the fixed sentence "the folder listing the server sent could not be
read", and the browse banner goes from the frame
`core.browse.protocolError %@` around a FIXED English tail to the
finding's own translated sentence. The one part of the old paragraph that
held is the transfer queue: neither `rename` nor `deleteTree` reaches its
mapper. The corrected premise is in the now-closed row at
`docs/BACKLOG.md:174`.

### T4 — `parseUploadID` recorded as a deliberate passthrough

Closes row `:175` without a code change beyond a comment at
`S3MultipartXML.swift:20`, per the maintainer's decision. The comment names
both provenances — Foundation's `parserError?.localizedDescription` (out of
scope by the maintainer's decision of 2026-09-28) and this project's own
"no UploadId element" — and records why they were not split: the in-scope
half reaches no reader, and the cost is four catalogue sentences, two of
them unreviewed. A later reader finds a decision, not an oversight.

### T5 — a seam for the upload-stream finding

Closes row `:176`. `WebDAVFileSystem.write(path:mode:contents:)` calls the
static `Stream.getBoundStreams` at `:459` and throws
`.uploadStreamUnavailable` at `:462` when it hands back no pair. A reviewer
proved the site unpinned on 2026-09-28 by substituting a different finding
with the suite staying green.

`WebDAVFileSystem` gains a second injected dependency beside `transport`
(`:8`): a bound-stream-pair factory, defaulted to `Stream.getBoundStreams`,
so no production call site changes. The shape follows `DetachedProbe.Launch`
— a `@Sendable` closure type alias rather than a protocol for one call.
The test injects a factory returning no pair, which reaches the throw for
the first time.

### T6 — `logSentence` anchored to the `en` catalogue

Closes row `:178`. One test iterates `RemoteFSFinding.Name.allCases` and,
through an exhaustive switch mapping each name to a representative value
and the argument its key interpolates, compares `logSentence` against the
`en` entry read off disk — compared case-insensitively at the first
character only, and formatted with the same argument for the three names whose key carries ` %@` (`unexpectedStatus`,
`pathExistsAndIsNotADirectory`, `uploadPartUnacknowledged`, counted at
`RemoteFSFinding.swift:153-154`).

Reading the catalogue off disk rather than through `CoreL10n.string` is the
existing pattern's reason, preserved: the runtime lookup resolves through
the test process's locale, and this property must hold whatever locale runs
the test.

The exhaustive switch is what makes the guard grow by itself: a finding
added later does not compile until it is given a representative value.
This anchors all 18 at once and replaces nothing — the three existing
constant-comparison tests keep their own subjects.

### T7 — closeout

The seven rows are closed in `docs/BACKLOG.md` with what was measured,
including the two whose premise the measurements changed. The stale spots
are corrected — **two of the three listed, because the third does not
exist**; see the correction under "Citations checked rather than
trusted" above:

1. The row "Wall-clock ceilings still in the tree" (`:20`) states that
   `ConnectionDiagnosticsTests.theRunnerWalksTheUniversalStepsInTheOrderTheReportPrints`
   "keeps the shape and is open". It does not: the `[.ok, .ok, .ok, .ok,
   .ok]` assertion is gone, and `grep -rn "\[\.ok" Tests/macSCPCoreTests/ConnectionDiagnostics*.swift`
   returned nothing on 2026-10-01.
2. "If you don't know where to start" (`:301`) recommends three
   candidates. Its third, the capability boundary, has been
   **Implemented since 2026-08-28** by the row at `:120`; the other two
   have no row in the file at all.
3. ~~The module path in the `resumeNotSupported` row, as above.~~ **Not a
   stale spot: the row never carried that path.** Corrected 2026-10-01;
   the bare citation was qualified rather than fixed, and the row records
   why.

Whether any of this reaches the user documentation is decided in this task
by reading the changed sentences, not assumed: T2 changes one user-visible
error sentence, for a server answering malformed XML to a single-resource
request.

---

## Testing

Every task ships its test in the same commit, red first. Three properties
of this project's test rules bear on this work specifically:

- **No wall-clock ceilings.** Nothing here measures time; no task may add
  an `elapsed <` bound.
- **No blocking waits.** None of these tests needs one.
- **A value a test must not leak has two exits.** Not applicable here: no
  finding carries a secret, which `RemoteFSFindingTests.noFindingCarriesForeignText`
  already holds.

The suite's known state at the base commit is 6623 tests in 568 suites with
exactly one known failure, `ViewTestabilitySpike`'s pixel comparison, which
`docs/BACKLOG.md` records as an expired measurement on macOS 27 and which
is not touched here.

**T2 carries a build hazard.** The row "An incremental build can crash
after `RemoteFSFinding` gains a case" is about exactly this change; that
task's steps include a clean build rather than trusting an incremental one.

## Out of scope

- Splitting `readsAsConnectionFailure` into two properties — see
  measurement 1 and the maintainer's decision.
- A finding for `S3MultipartXML.parseUploadID` — the maintainer's decision.
- Foundation's own error text anywhere: out of scope since 2026-09-28 and
  unchanged here.
- The remaining `docs/BACKLOG.md` rows, including the WebDAV 412 pair and
  the `ViewTestabilitySpike` re-measurement.
