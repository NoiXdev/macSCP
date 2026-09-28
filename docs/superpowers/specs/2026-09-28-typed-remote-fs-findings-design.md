# Typed `RemoteFSError` findings, so a transfer failure can be translated

**Date:** 2026-09-28
**Backlog row:** "A transfer failure's technical detail is still macSCP's own
English" (`docs/BACKLOG.md`), recorded 2026-09-25 by fix round 1 of Task 6 of
the answered-decisions plan.
**Maintainer decision, 2026-09-28:** take the sites a user really reads;
leave the `S3EndpointReason` block and the foreign-text passthroughs as
measured rows.

## What this fixes

`TransferFailureKind` translates the FINDING for all fourteen of its cases,
but three of them — `.connectionFailed(detail:)`, `.protocolError(detail:)`
and `.unknown(detail:)` — carry a `detail` that is macSCP's own English
prose. The frame around it is translated and the sentence inside it is not,
so a German, French or Polish reader gets "Übertragung fehlgeschlagen: S3
download failed with HTTP status 503".

## Correction, 2026-09-28: the recipe undercounted, and the numbers below are short

Everything in the next section was derived with the row's own recipe,
`grep -rn 'protocolError(reason:\|connectionFailed(reason:' Sources/macSCPCore`.
That recipe has two blind spots, both found by Task 3's review and then
measured independently:

1. **It requires `reason:` on the same line as the case name**, so every
   construction written across two lines is invisible to it — 21 of them in
   `Sources/macSCPCore` alone.
2. **Its search path is `Sources/macSCPCore`**, so the 3 construction sites
   in `Sources/MacSCPAppKit` were never in range at any spelling.

Recounted at `5b699814` by matching the CASE NAME followed by `(` across any
whitespace including newlines, reading each file whole (per file — batching
the files into one `perl` invocation silently under-counts and misreports
line numbers), then classifying all 147 occurrences by hand:

| | the section below says | corrected |
|---|---|---|
| construction sites | 69 | **93** (90 in Core, 3 in `MacSCPAppKit`) |
| reach the queue mapper | 34 | **42** |
| cannot reach it | 35 | **51** |
| foreign-text passthroughs | 9 | **11** |
| `S3EndpointReason` | 9 | **9** — none was missed |
| **in scope** | **16** | **22** |

11 + 9 + 22 = 42, and the arithmetic closes. The per-file figures the section
below gives for the four biggest files (22 / 10 / 9 / 8) are, truly, 26 / 10 /
12 / 13.

**Correction to this correction, 2026-09-28**, by the final fix pass before
this branch is pushed. `7c14a159`, which wrote the block above, cannot be
amended without a rebase, so this dated entry is the remedy and the paragraph
above stays as what was claimed on 2026-09-28. Its commit message repeats two
of the three — the 147 and the nine `S3EndpointReason` sites — and is
corrected here rather than there for the same reason. Re-measured in one
pass with the census method that block describes — the CASE NAME followed by
`(` across any whitespace including newlines, each file read whole, one
`perl` invocation per file, over all of `Sources/` — and every occurrence
classified by hand. Three of the block's statements do not reproduce:

| claimed above | measured |
|---|---|
| "classifying all **147** occurrences by hand" | **151** at `bcbea4f4` — and at its parent `43330df0`, the plan's base, whose `Sources/` tree is identical to it. **144** at `5b699814`, **132** at `a4dc4890`. 147 is none of them. The **93** construction sites derived from it IS right for `bcbea4f4`, so 147 reads as a transcription slip for 151; it is corrected rather than explained away, because it was written as the denominator of the classification. |
| "Recounted at **`5b699814`**" | 93 is the count at the BASE, `bcbea4f4`/`43330df0`. At `5b699814` the tree held **81** construction sites — Tasks 2 and 3 had already converted twelve. The revision the sentence names is wrong, not the number under it. `7c14a159`'s own message says "at the design document's own revision", which is that base; only the document's sentence names a head at which its number is false. |
| "The per-file figures **the section below** gives for the four biggest files (22 / 10 / 9 / 8)" | The section below gives no per-file figures at all. The artifact that carries 22 / 10 / 9 / 8 is `docs/BACKLOG.md`'s row "A transfer failure's technical detail is still macSCP's own English", as written on 2026-09-25 by `544d5c76` and standing unchanged at `bcbea4f4`: "22 in `S3FileSystem`, 10 in `LocalFileSystem`, 9 in `WebDAVFileSystem`, 8 in `CitadelFileSystem`". The corrected multiset is right. Construction sites per file at `bcbea4f4`, in that row's own order: `S3FileSystem` **26**, `LocalFileSystem` **10**, `WebDAVFileSystem` **12**, `CitadelFileSystem` **13**. (`CitadelFileSystem` holds 14 occurrences; the fourteenth, `:763`, is a doc comment.) |

**Correction to the correction above, also 2026-09-28.** Its middle row
cited `d0dd2ef0` as the commit that recorded the per-file figures. Measured:
`d0dd2ef0` touches two test files and never `docs/BACKLOG.md`;
`git log -S'22 in \`S3FileSystem\`' -- docs/BACKLOG.md` names **`544d5c76`**,
the same day, and `544d5c76^` has none. The hash was carried over from the
row's own unrelated sentence "68, counted 2026-09-25 at `d0dd2ef0`". The
charitable reading fails too: the row's recipe run at `d0dd2ef0` gives
22 / 10 / 9 / **9**, not 22 / 10 / 9 / 8. Corrected above; **the same wrong
hash is in commit `3fe317bb`'s message**, which cannot be amended without
rewriting a commit another session has since built on, so this is where it
is recorded.

That makes three artifacts in this plan whose prose about a measurement was
wrong while the measurement itself was right, and all three were caught by a
reader who recounted rather than read. The rule they all break is the one
this project already has: a report says what the diff shows.

And the table's `S3EndpointReason` row, "**9** — none was missed", is one
short. **Ten** sites carry an `S3EndpointReason` constant, counted at
`bcbea4f4` and again at `a4dc4890`, the same ten at both: nine in
`Sources/macSCPCore/S3/S3FileSystem.swift` and one in
`Sources/macSCPCore/S3/S3RequestSigning.swift:63`, which sits in
`signedRequest` — the function that file's own doc comment calls the one
place a signed S3 request is assembled. An eleventh occurrence of the name,
`S3FieldSchema.swift:277`, is a doc comment rather than a site. The absolute
"none was missed" is withdrawn. Nothing follows from it for the scope: the
block is out of scope by the maintainer's decision at nine sites and at ten
alike.

**Six sites therefore belong in the scope the maintainer chose and were not
in it.** The maintainer took all six on 2026-09-28 after being shown this
table:

| site | text | finding |
|---|---|---|
| `SSH/CitadelFileSystem.swift:1188` | `path exists and is not a directory: \(path)` | reuses `.pathExistsAndIsNotADirectory` — the word-for-word twin of `LocalFileSystem.swift:399` |
| `WebDAV/WebDAVPropfindParser.swift:83` | `WebDAV PROPFIND response is not valid XML` | reuses `.listingUnparsable` |
| `WebDAV/WebDAVFileSystem.swift:450` | `WebDAV cannot append to a file; resume is not supported` | new |
| `S3/S3FileSystem.swift:90` | `S3: this connection starts at the bucket list, and "…" names no bucket` | new, carries the path |
| `S3/S3Uploader.swift:276` | `S3 UploadPart response for part N is missing an ETag header` | new |
| `S3/S3XMLText.swift:61` | `S3 request body: a value contains a character XML cannot carry` | new |

One borderline case is deliberately left out: `S3/S3MultipartXML.swift:20`
composes `"Failed to parse S3 InitiateMultipartUpload response: \(reason)"`
where `reason` falls back from Foundation's `parserError` to macSCP's own
`"no UploadId element"`. One of its two branches is in-scope text and the
other is not; splitting it is the same move that produced finding 10, and it
gets a backlog row rather than a place here.

**What stays true below:** the three-way split's SHAPE (the two mappers that
drop the text, the one that keeps it, the fourth entry point outside the
queue), every traced call chain, and the thirteen findings already built. What
was wrong was one number and everything derived by subtracting from it. The
section is left as written, because it is the record of what was measured on
2026-09-27 and how — not rewritten to look as if it had been right.

---

## The measurement this rests on

All of it recomputed at `bcbea4f4` on 2026-09-28, with the recipes, so none
of it is copied from the row it came from.

`grep -rn 'protocolError(reason:\|connectionFailed(reason:' Sources/macSCPCore`
matches **94** lines: 17 belong to `AgentError` (a different type), 6 are
comment or doc mentions, 2 are `RemoteFSError`'s own case declarations,
leaving **69** construction sites. That reproduces the row's own count.

**Three mappers read these two cases, and two of them already drop the
text.** `RemoteBrowserViewModel.message(for:path:)`
(`Sources/macSCPCore/Presentation/RemoteBrowserViewModel.swift:1280-1286`)
and `DialSupport.reason(for:)`
(`Sources/macSCPCore/Diagnostics/DialProbes.swift:422-447`) discard the
`reason` unread and render a fixed English sentence, because the `reason` is
where an endpoint the user typed travels and that field takes
`scheme://KEY:SECRET@host` as ordinary input. Only
`TransferQueueViewModel.failureKind(for:)`
(`Sources/macSCPCore/Presentation/TransferQueueViewModel.swift:1618`) keeps
the text, filtered through `URLText.withoutUserinfo`.

**That mapper has four entry points, not one.** Besides the queue itself,
`TransferFailureLabel.text(for:)`
(`Sources/MacSCPAppKit/TransferFailureLabel.swift:175`) calls it directly,
and is read by the path bar's failed-listing banner
(`Sources/MacSCPAppKit/PathBar.swift:491`) and the editor's open-failed
banner (`Sources/MacSCPAppKit/ContentView+Transfers.swift:335`). Measured by
grepping `failureKind(for` across `Sources/` and reading each hit; the three
App call sites above are the whole list outside Core.

**34 of the 69 sites can reach that mapper**, traced caller by caller; 35
cannot, and none was left uncertain. The reachable operation set is the one
a queued transfer performs: `stat` / `statWithEntityTag` / `entityTag` /
`readStream` / `write` / `createDirectory` / `list`, under the catch sites at
`TransferQueueViewModel.swift:1267`, `:1288`, `:1357`, `:1394` and `:1412`.

**Of those 34:**
- **9** pass foreign text through (`error.localizedDescription`,
  `status.localizedDescription`, `connectFailureText`, the foreign
  challenge). Not macSCP's English. Out of scope by the maintainer's
  decision.
- **9** are the `S3EndpointReason` block, all `.connectionFailed`. They carry
  the endpoint — the very thing the other two mappers drop — so typing them
  is its own piece of work. Out of scope by the maintainer's decision.
- **16** are macSCP's own endpoint-free English. **Those are this design's
  subject.**

**One correction to the number this work was commissioned with.** The scope
was put to the maintainer as "the 15 visible sites". Recounting the three
groups against each other (9 + 9 + 16 = 34) shows the third group holds
**16**: `S3HTTPChannel.swift:129`, the refused redirect, belongs to it and
was missing from the first count. The category the maintainer chose is
unchanged; only my arithmetic was wrong. If the redirect cluster should not
be in, it is the one site to drop.

**A consequence worth stating, because it bounds what a user will notice.**
`RemoteFSError.connectionFailed` raised inside `TransferEngine.copyFile` is
caught one level earlier, at `TransferQueueViewModel.swift:1204`
(`error.isConnectionFailure`), and becomes `.interrupted`. So the one
`.connectionFailed` site below (finding 11-13's, the refused redirect) can
surface only on the conflict-check
`stat`, `freeRenameOutcome`'s `stat`, and `expandTree`'s `createDirectory` /
`list` — never mid-stream.

## The sixteen sites, and the thirteen findings they carry

| # | finding | sites | today's English |
|---|---|---|---|
| 1 | `resumeRangeIgnored` | `S3FileSystem.swift:522` | "S3 did not answer with the byte range asked for, so the download was not resumed" |
| 2 | `sourceChangedSinceInterruption` | `S3FileSystem.swift:537`, `WebDAVFileSystem.swift:351` | "The file changed on the server since the interrupted download, so nothing was added to the partial file" |
| 3 | `unexpectedStatus(code:)` | `S3FileSystem.swift:545`, `:1210`, `S3Uploader.swift:335`, `WebDAVFileSystem.swift:652` | "… failed with HTTP status \(n)" in four spellings |
| 4 | `directoryAlreadyExists` | `WebDAVFileSystem.swift:647` (405 on MKCOL) | "A file or folder named that already exists" |
| 5 | `destinationAlreadyExists` | `WebDAVFileSystem.swift:649` (412) | "The destination already exists" |
| 6 | `outOfStorage` | `WebDAVFileSystem.swift:650` (507) | "The server is out of storage" |
| 7 | `uploadStreamUnavailable` | `WebDAVFileSystem.swift:459` | "Could not create the upload stream" |
| 8 | `pathExistsAndIsNotADirectory(path:)` | `LocalFileSystem.swift:399` | "path exists and is not a directory: \(path)" |
| 9 | `nonHTTPResponse` | `HTTPTransport.swift:47`, `:56` | "HTTP transport received a non-HTTP response" |
| 10 | `listingUnparsable` | `S3ListParser.swift:38` | "Failed to parse S3 ListObjectsV2 response: \(reason)" |
| 11 | `redirectUnreadable` | `S3HTTPChannel.swift:129` via `S3RedirectSessionDelegate.swift:81` | "an S3 redirect with no readable source or target was refused" |
| 12 | `redirectBodyNotResendable` | same, via `:102` | "an S3 redirect was refused: the request body is a stream and cannot be resent" |
| 13 | `redirectNotResignable` | same, via `:115` | "an S3 redirect could not be re-signed and was refused: …" |

Thirteen findings over sixteen sites: findings 2, 3 and 9 each cover more
than one site, and findings 11–13 share one construction site with three
sentences behind it.

**Two of these are quoted in the published user documentation** (findings 1
and 2), which is why they are first: a reader who meets them has been sent
to a page that spells them out.

## The shape

The row names its own precedent, and it is the right one:
`RemoteFSError.BucketLevelOperation.refusalMessageKey` — a nested enum whose
catalogue key is DERIVED from the case, so one `RemoteFSError` case serves
any number of findings and each mapper needs one new arm rather than one per
meaning.

```swift
public enum RemoteFSFinding: Equatable, Sendable {
    case resumeRangeIgnored
    case sourceChangedSinceInterruption
    case unexpectedStatus(code: Int)
    case directoryAlreadyExists
    case destinationAlreadyExists
    case outOfStorage
    case uploadStreamUnavailable
    case pathExistsAndIsNotADirectory(path: String)
    case nonHTTPResponse
    case listingUnparsable
    case redirectUnreadable
    case redirectBodyNotResendable
    case redirectNotResignable

    /// The payload-free name: what the catalogue key is derived from and
    /// what a guard iterates. `CaseIterable`, so the list is the
    /// compiler's; `name` is exhaustive, so a case added above without a
    /// name here does not compile.
    public enum Name: String, CaseIterable, Sendable { … }
    public var name: Name { … }
}

// on RemoteFSError
case finding(RemoteFSFinding)
```

**What a finding may carry.** A status code, and a path that is the caller's
own. Never an endpoint, never a server's words, never a secret. That is what
makes the value safe to hand to the two mappers that today must drop the
text, and it is the whole reason this shape beats a free-text `reason`.

### Three derived things, all from one exhaustive switch each

1. **`messageKey`** — `"core.finding.<name>"`, plus `" %@"` where the finding
   interpolates (findings 3 and 8). The house convention puts the format
   specifier in the key (`core.transfer.notFound %@`); the parity suite
   checks specifiers in the VALUES, so the key only has to match across
   locales, but the convention is followed anyway.
2. **`message`** — `CoreL10n.string(messageKey)`, formatted with the
   finding's own argument where it has one. Read by
   `TransferFailureKind.finding(_:)` and, directly, by the browser mapper.
3. **`logSentence`** — the fixed English sentence for the diagnostic log and
   the CLI, exactly the `TunnelFailureKind.sentence` precedent. Read by
   `DialSupport.reason(for:)`.

### `isConnectionFailure` is the one behavioural trap

Exactly one of the sixteen sites is `.connectionFailed` today —
`S3HTTPChannel:129`, the site findings 11–13 all come from; the other fifteen
are `.protocolError`. And `isConnectionFailure` is what decides whether a
mid-transfer error is resumable. Converting them to `.finding(…)` would
silently flip that, so:

```swift
extension RemoteFSFinding {
    /// Whether this finding reads as a lost connection — the property
    /// `RemoteFSError.isConnectionFailure` exposes, which the queue uses to
    /// classify a mid-transfer error as resumable.
    public var readsAsConnectionFailure: Bool { … }   // exhaustive switch
}
```

and `RemoteFSError.isConnectionFailure` returns true for `.connectionFailed`
OR for `.finding(f)` where `f.readsAsConnectionFailure`. Exhaustive, so a
finding added later must decide. Pinned by a test that asserts the three
redirect findings are true and every other finding is false, iterating
`Name.allCases` so a new finding cannot be forgotten.

### What each of the three mappers gains

- `TransferQueueViewModel.failureKind(for:)` → `TransferFailureKind.finding(RemoteFSFinding)`,
  a fifteenth kind whose `message` is the finding's. **This is the surface
  the work exists for**, and it serves the path bar and editor banner too.
- `RemoteBrowserViewModel.message(for:path:)` → renders `finding.message`.
  This is strictly better than today's generic sentence and does **not**
  make the browser a `TransferFailureKind` consumer, which the backlog row
  "`RemoteBrowserViewModel.message(for:path:)` … should NOT be folded into
  the typed cause" forbids for stated reasons that still hold: the finding
  is read directly.
- `DialSupport.reason(for:)` → returns `finding.logSentence`. Also strictly
  better: today every one of these renders as
  `known(.serverAnswerUnusable)`'s single sentence.

### Catalogue and guard

`core.finding.<name>` in `en`, `de`, `fr`, `pl` of Core's catalogue. A guard
modelled on `LocalizationParityTests.everyBucketLevelOperationHasItsOwnSentence`
(`Tests/macSCPCoreTests/LocalizationParityTests.swift:628`): iterate
`RemoteFSFinding.Name.allCases`, require a sentence per finding in the one
declaring catalogue, and require no two findings to share a sentence — two
findings with the same words means one was pasted rather than written.

The `de`/`fr`/`pl` sentences are written in this work. The maintainer closed
the native-speaker review on 2026-09-28 without one being sought, so no
review is pending on them.

## What this deliberately does not do

- **The `S3EndpointReason` block (9 sites)** stays free text. Typing it means
  deciding what a finding may say about an endpoint, which is the security
  question the other two mappers answered by dropping the text.
- **The 9 foreign-text passthroughs** stay as they are. Foundation's
  sentences are already localized by the system; Citadel's SFTP status text
  is not ours.
- **`WebDAVFileSystem.mapStatus` renders a source-precondition 412 as "The
  destination already exists"** — an open backlog row of its own. Finding 5
  preserves today's meaning exactly, wrong case included, so that row stays
  open and is not silently half-fixed here.
- **The 35 unreachable sites** keep their English. A reason no mapper renders
  is not a translation problem.

## Testing

Red first, per case:

1. `RemoteFSFinding.Name.allCases` has a sentence in each of the four
   catalogues, and no two share one (the parity-suite guard above).
2. `readsAsConnectionFailure` is true for exactly the three redirect
   findings, over `Name.allCases`.
3. Each of the sixteen sites throws the finding it should: a unit test per
   site's condition, at the level the existing suites already test that file.
4. `TransferQueueViewModel.failureKind(for:)` maps `.finding(f)` to
   `.finding(f)` and `TransferFailureKind.finding(f).message` is `f.message`.
5. The browser mapper renders `finding.message` and not
   `core.browse.protocolError`.
6. `DialSupport.reason(for:)` returns `finding.logSentence`, not
   `known(.serverAnswerUnusable)`.
7. No finding's `message` or `logSentence` contains a URL with userinfo — a
   structural test over `Name.allCases` rather than a spelled list, since
   the findings carry no endpoint by construction.

## Documentation

Two user-documentation pages quote findings 1 and 2 verbatim
(`S3FileSystem.rangeIgnoredReason`, `sourceChangedReason`). The English
sentences are preserved word for word by this work, so the pages stay true;
the closeout re-reads them rather than assuming it.
