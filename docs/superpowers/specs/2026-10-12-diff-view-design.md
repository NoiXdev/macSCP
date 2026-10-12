# A diff view for files and folders — design

**Date:** 2026-10-12
**Backlog row:** `docs/BACKLOG.md`, "A diff view for files and folders
(maintainer wishlist)" — maintainer wishlist item 31, recorded 2026-09-16.
**Status:** design approved in chat 2026-10-12. No code written.

## What was already decided, and when

Carried out of the backlog row rather than re-opened here:

- **2026-09-16, maintainer, in chat:** a folder comparison means BOTH the
  counts — files only on one side, files that differ — AND a content diff of
  the files inside, "like `git diff`". Not one or the other.
- **2026-09-16, maintainer, accepting the proposal in chat:** the pairs come
  in an order. First local↔remote and two files of the same session; across
  sessions and across backends later.

Decided on 2026-10-12, in the brainstorming this document closes:

- **Built in, files and folders.** Not a hand-off to an external diff tool.
  The folder comparison is the half no external tool can do, because the
  remote side is not a filesystem it can walk.
- **Size first, hash only where the sizes match.** Two files of different
  size differ, and that needs no checksum.
- **A third state.** Where the sizes match and the connection cannot hash,
  the pair is `undetermined` with its reason, never `same`, and the user can
  ask for that one pair to be settled by fetching both sides.
- **Its own window**, not a tab and not a sheet. The measurement behind this
  is in "Why a window and not a tab" below; it reverses a recommendation
  made earlier in the same conversation.

## What exists today

Measured 2026-10-12 at `863f1969`, from the repository root.

- **No diff of any kind, no binary test, and no ceiling on reading a file.**
  Two probes, each a NEGATIVE check and therefore each with a positive
  control beside it, because a pattern that has gone stale prints the same
  zero as a real absence:

  ```
  /usr/bin/grep -rln -e 'isBinary' -e 'looksBinary' -e 'isProbablyText' Sources
  /usr/bin/grep -rn -e 'maxBytes' -e 'maximumSize' -e 'sizeLimit' -e 'maxFileSize' Sources/macSCPCore
  ```

  Both print nothing and exit 1 on 2026-10-12. The controls: for the first,
  `/usr/bin/grep -rlc 'func ' Sources` prints 840 lines, so the search path
  is alive; for the second,
  `/usr/bin/grep -rn -e 'maxPendingBytes' Sources/macSCPCore` DOES match, at
  `TerminalPanelViewModel.swift:55`.

  That second control also narrows the claim, and the narrower one is the
  true one: the tree does carry a byte ceiling — the terminal panel's 64 KiB
  cap on pending input, itself the subject of an open backlog row — but it
  carries no ceiling on how large a file may be read, and no test for
  binary content. **Both the binary test and the size ceiling this design
  introduces are new.** This document claims no precedent for either.
- **Checksums exist on every backend.** The protocol method is
  `remoteChecksum(forFileAt:algorithm:) async throws -> RemoteChecksumOutcome`
  (`Sources/macSCPCore/RemoteFS/RemoteChecksumProvider.swift`), implemented by
  `S3FileSystem`, `LocalFileSystem`, `CitadelFileSystem` and
  `WebDAVFileSystem` — the four printed by
  `/usr/bin/grep -rn 'forFileAt path: String, algorithm' Sources/macSCPCore`
  beside the protocol's own declaration. `ChecksumAlgorithm` is
  `sha256`/`sha1` with `sha256` preferred, and the user's choice is
  `SettingsStore.checksumAlgorithm`.
- **`unavailableOnThisConnection` is NOT an exotic case.** It is a case of
  `RemoteChecksumOutcome`, not a throw, and the enum's own doc comment names
  two sources for it: an SSH far side with no checksum tool, and WebDAV,
  "which has no digest to report at all". So **every WebDAV connection
  answers this way for every file**, and the third state below is load
  bearing rather than defensive.
- **Fetching a remote file to a local one already has one route.**
  `EditSessionManager.downloadAndRegister`
  (`Sources/macSCPCore/Presentation/EditSessionManager.swift`) creates a
  per-file temp directory under its session directory and downloads through
  `TransferQueueViewModel.enqueueAndWait(fileName:direction:source:sourcePath:destination:destinationDirectory:)`,
  with the comment "Download through the queue so it appears in the transfer
  bar."
- **Listing is one method:** `func list(path: String) async throws -> [RemoteFileItem]`
  (`Sources/macSCPCore/RemoteFS/RemoteFileSystem.swift`).
- **The checksum column and action** can already tell two files apart without
  showing how — that is the backlog row's own description of today's state,
  and it is what this feature replaces.

## Scope

**In:** local↔remote pairs, and two REMOTE files of one session — the second
half is written out because "two files of one session" reads equally well as
two local ones, which is not what was decided and is a job the Finder already
does. Files and folders. A folder comparison is recursive.

**Two entry shapes, and they do not share a path.** Comparing a FOLDER pair
runs the classification below, where size and checksum exist to avoid
fetching. Comparing a FILE pair the user picked explicitly skips that
entirely: they have asked to see the content, so both sides are fetched and
diffed, and a checksum would only delay the answer it cannot replace. The
classification is a way to avoid work nobody asked for, not a gate in front
of work they did.

**A path whose type differs between the sides** — a folder on one, a file on
the other — is neither `same` nor `differs`: it is its own row, reported as a
type mismatch, because no content comparison of the two is meaningful and
calling it `differs` would invite a user to open a diff that cannot exist.

**Out, and recorded as out rather than forgotten:** across sessions and
across backends (the maintainer's 2026-09-16 ordering puts it later); a
three-way merge; editing either side from the diff; handing the pair to an
external tool.

## Why a window and not a tab

The brainstorming first chose a tab, on a recommendation that called a window
"the biggest intervention of the three". **That recommendation was wrong, and
it is withdrawn here rather than quietly dropped.** The measurement that
reversed it, taken 2026-10-12:

- The tab world is concrete, not generic over kinds of tab. `TabRegistry`
  holds `private var tabsByID: [UUID: SessionTab]`, and
  `MenuBarStatusModel.tabs`, `TabCloseWarning` and
  `ContentView+Detail.tabsToProbe` are each `[SessionTab]`. A comparison tab
  therefore means generalising that model across the window area — the
  registry, the move between windows, and the quit sweep.
- The scene list is short and additive. `MacSCPApp.body` declares a
  `WindowGroup("macSCP", for: WindowSeed.self)` and a `Settings` scene. A
  third scene touches none of the above, and `openWindow` is available to
  views.

**What was NOT measured:** how much of `SessionTab`'s surface a comparison
tab would really need. The size of that refactor is an estimate in this
document, not a count.

## Ownership: the work belongs to the tab, the window only shows it

This is the load-bearing decision of the design, and it comes from the
project's own invariant: connection and session state belongs to the window
scope, never to an app-wide singleton, and `TabRegistry` holds ownership —
which window has which tab — never state.

So:

- The **comparison model is owned by the tab** whose connection it uses. The
  listing walk, the checksums and the fetches all run there.
- The **comparison window is a view onto that model.** Its seed carries the
  owning tab's id and resolves the tab through `TabRegistry.tab(for:)` — the
  same shape a detached window already uses, where `WindowSeed.tabIDs` names
  "the live tabs this window takes over from another one".
- The connection never leaves its owner, and **teardown has an owner**: when
  the tab closes, the existing `TabTeardown.run(_:reason:)` ends the
  comparison, and the window states that the session it belonged to was
  closed. ⌘Q needs no new sweep, because it already runs each window's close
  sequence and each of those ends in `TabTeardown`.

A comparison whose owning tab is gone is not an error to recover from: it is
a window showing a finished thing, and it says so.

## Core: three pieces, no UI, under `macSCPCore/Compare/`

**`FolderComparison`** pairs the two sides' listings by relative path and
classifies each pair:

| State | When |
|---|---|
| `onlyLeft` / `onlyRight` | the relative path exists on one side only |
| `differs` | the sizes differ, or the sizes match and the checksums differ |
| `same` | the sizes match and the checksums match |
| `undetermined(reason)` | the two sides cannot be compared — see the reasons below |
| `typeMismatch` | the relative path is a folder on one side and a file on the other |

**Corrected 2026-10-12, during the plan's pre-flight scan**, which found that
two checksums cannot simply be compared by their hex. The `undetermined` row
above read "the sizes match and at least one side answered
`unavailableOnThisConnection`", and the `differs` row's second clause read
"or the sizes match and the checksums differ" — both are withdrawn as
written, because each assumed the two sides answer in the same currency. They
do not. `FileChecksum` carries an `algorithm` and a `ChecksumProvenance`, and
an S3 side answers from its ETag with `algorithm: .md5` and a provenance of
`.objectStorageETagSinglePart` or `.objectStorageETagMultipart(partCount:)`,
the latter documented in the tree as "An MD5 over the parts' MD5s. Not the
file's hash, whatever it looks like." Comparing a locally computed sha256
against a multipart ETag finds them unequal and would have reported `differs`
for two IDENTICAL files on every S3 connection holding a multipart object —
a comparison that lies, which is the one outcome this design exists to
prevent.

**Corrected 2026-10-13**, on Task 3's report, which added a fifth reason —
`unreadable`, for a path whose listing or classification threw, described
under Error handling. Two withdrawals, both quoted. The sentence below read
"So `undetermined` has four reasons, not one". And the table's
`undetermined(reason)` cell read "the sizes match and the two checksums
cannot be compared — see the four reasons below", which the fifth reason
falsifies twice over: `unreadable` says nothing about the sizes matching, and
it is not a statement about checksums at all. The count is five as of this
correction. The four the original sentence named are unchanged and follow.

So `undetermined` has these reasons, not one: the connection cannot hash at
all (an SSH far side with no tool, every WebDAV connection, a backend that is
not a `RemoteChecksumProvider`); the connection cannot hash with the chosen
algorithm; the two sides answered with different algorithms; and one side's
value is a multipart ETag, which is not a hash of the file's bytes. A
multipart ETag is never compared in either direction — it can neither
establish `same` nor `differs` — and the pair is settled, where the user asks
for it, by reading the bytes.

The order matters and is the cheap half of the design: **size decides
first**, and a checksum is asked for only where the sizes are equal. A grown
folder costs almost no checksums; a mirrored one costs almost one per file,
which is the honest price of the question being asked.

**`FileDiff`** is a line-based diff over two LOCAL files, producing hunks
with line ranges on both sides. A pure function over two line arrays: no file
system, no connection, no UI. It is where the tests live.

**`DiffEligibility`** answers "can this pair be shown as a content diff", and
returns a reason when it cannot. Two refusals, both new in this design:

- **Binary.** A NUL byte within the first 8000 bytes of either side, which is
  git's own heuristic and is adopted here by name rather than invented; or
  content that is not valid UTF-8.
- **Too large.** A starting ceiling of **4 MiB per side**, refusing above it.
  **Corrected 2026-10-13, on Task 5's report: this bullet described the whole
  of the protection, and it is not.** `FileDiff`'s table grows with the
  PRODUCT of the two LINE counts, and a 4 MiB file of one-character lines
  holds about two million lines. Derived 2026-10-13 with the command below,
  which is on one line so that it runs in the form it is committed — an
  earlier draft of this bullet wrapped it mid-sentence, where it could not be
  extracted and run at all:

  ```
  /usr/bin/python3 -I -c "c=4*1024*1024; n=c//2; e=(n+1)*(n+1); print(f'{n:,} lines, {e:.3e} entries, {e*8/1e12:.1f} TB')"
  ```

  It prints `2,097,152 lines, 4.398e+12 entries, 35.2 TB`.
  A pair that passes this ceiling can therefore still ask for 35 terabytes. A
  bound in bytes cannot bound a quantity measured in lines, and no byte
  ceiling small enough to do so would admit an ordinary source file. Task 6
  settles the bound that binds — a line count, a product, or a diff that does
  not allocate the table — and the refusal reaches the user as a reason
  rather than as a crash.
  **This number is a starting value and not a measurement.** Nothing in the
  tree sets a precedent, and a line diff's cost is dominated by the number of
  differences rather than by the file size, so the plan carries the
  measurement that either keeps this number or replaces it. Until that
  measurement exists, no document here may describe 4 MiB as a measured
  limit.

The folder comparison does NOT depend on eligibility: a binary or oversized
pair is still classified `same` / `differs` / `undetermined` by size and
checksum. Only the content diff of that pair refuses, with its reason shown
in place of the hunks. Telling the user that two binaries differ is useful;
refusing to compare them at all would not be.

## Fetching remote content

Never a new download path. Both sides reach a per-comparison temp directory
through `TransferQueueViewModel.enqueueAndWait(...)`, exactly as the edit
session does, so that **every fetch a comparison causes is visible in the
transfer bar**. A comparison that silently moved bytes would be the one thing
this app does not do elsewhere.

The temp directory is per comparison and is removed when the comparison ends.

## The surface

A third scene beside `WindowGroup` and `Settings`.

- **Top: the folder overview.** One row per relative path with its state, and
  a count per state, so "how different are these" is answerable without
  reading the list. The `undetermined` rows carry their reason, and each
  offers "compare anyway", which fetches both sides and settles that one pair
  by bytes.
- **Bottom: the content diff** of the row selected above, or its refusal
  reason.
- **A progress line while the walk runs**, with a cancel. A recursive
  comparison of a large tree is a long operation over a network, and an
  operation the user can neither see nor stop is not acceptable here.

Entry points: the context menu of both browser panes, which already carries a
typed entry list (`BrowserMenuEntry`, `BrowserContextMenu.entries(...)`),
plus a menu item.

## Error handling

- Every refusal names its reason, and the reasons are localized in all four
  catalogues (`en`, `de`, `fr`, `pl`; German in du-form).
- `undetermined` is never rendered as `same`, in any view. The state is in
  the model, not in a footnote above the table.
- A failed fetch fails that one pair, not the comparison.
- **The same rule governs a listing and a classification, added 2026-10-13**
  on Task 3's report. A directory below the root whose listing throws, and a
  pair whose classification throws, each become one `undetermined(unreadable)`
  row naming the path; the walk does not descend into it and carries on with
  the rest of the tree. A comparison that threw away an hour's work over one
  permission-denied subdirectory would not be used twice, and the row names
  what could not be read, so nothing is hidden by finishing.
  **Two boundaries on that, and both are load bearing.** The ROOT still
  throws: the user chose those two folders, and if neither can be listed
  there is no comparison to report. And `CancellationError` is re-thrown
  rather than caught — a blanket catch would turn a user's cancel into a tree
  full of "unreadable" rows and run the walk to completion, which is the
  cancellation failure arriving through the error path.
- A comparison whose owning tab closed shows that, and offers nothing it can
  no longer do.

## Testing

- `FileDiff` is a pure function and carries the bulk of the tests: equal
  files, one-sided empties, an insert, a delete, a change, a file with no
  trailing newline, CRLF against LF.
- `FolderComparison` is tested against fake filesystems, including a side
  that answers `unavailableOnThisConnection`, which must produce
  `undetermined` and never `same`. That case is the one a regression would
  make dangerous rather than merely wrong, so it gets a guard of its own.
  Also: a path that is a folder on one side and a file on the other reaches
  `typeMismatch` and no other state, and an explicitly chosen file pair
  reaches the diff without asking either side for a checksum — the second is
  pinned by a fake that records the calls it was asked for, so "it skips the
  checksum" is an assertion about behaviour and not about intent.
- `DiffEligibility`: a NUL at byte 7999 and at byte 8001, invalid UTF-8, and
  the size ceiling on both sides of its boundary.
- The ownership rule gets a wiring guard: the comparison model is reached
  through the tab, and the window holds no connection of its own.
- No test asserts a wall-clock ceiling. Hang bounds are `.timeLimit`.

## What this design does not do

It does not edit either side, does not merge, does not compare across
sessions, and does not hand anything to an external tool. Each of those is a
separate wish or a separate row.
