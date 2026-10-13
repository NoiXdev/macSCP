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
returns a reason when it cannot. **Corrected 2026-10-13 (Task 6): this
sentence continued "Two refusals, both new in this design:", and the count is
withdrawn.** `DiffRefusal` carries **four** cases — `.binary`, `.notUTF8`,
`.tooLarge`, `.tooManyLines` — under the **two** bullets below: the first
covers the two cases Task 5 split apart, and the second covers the two bounds,
one of which is Task 6's. Neither number is the other, which is why both are
written down.
Counted 2026-10-13 from the repository root with
`grep -c '^    case ' Sources/macSCPCore/Compare/DiffEligibility.swift`,
which prints 4 and is the right tool here because each case is on its own
line. They fall in two dimensions: bytes per side, and the two line counts
multiplied.

- **Binary.** A NUL byte within the first 8000 bytes of either side, which is
  git's own heuristic and is adopted here by name rather than invented; or
  content that is not valid UTF-8.
- **Too large, and too many lines.** A ceiling of **4 MiB per side**, refusing
  above it, and a ceiling of **33,554,432 (`1 << 25`) on the product of the
  two LINE counts**, checked after the split.
  **Corrected 2026-10-13 (Task 6): this bullet opened "A starting ceiling of
  **4 MiB per side**, refusing above it." The word "starting" is withdrawn —
  the measurement below exists and the number survived it — and the bullet is
  no longer about one bound, because one is not enough.**
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

  **Corrected 2026-10-13 (Task 6).** This bullet continued: "**This number is
  a starting value and not a measurement.** Nothing in the tree sets a
  precedent, and a line diff's cost is dominated by the number of differences
  rather than by the file size, so the plan carries the measurement that
  either keeps this number or replaces it. Until that measurement exists, no
  document here may describe 4 MiB as a measured limit." The measurement now
  exists, so the prohibition in the last sentence is lifted and 4 MiB is a
  measured limit — this document and `DiffEligibility.ceilingBytes` describe
  it as one. The middle clause, "a line diff's cost is dominated by the number
  of differences rather than by the file size", is withdrawn as **false of
  this diff**: the cost is dominated by neither. It is the two line counts
  multiplied, and the figures below are what say so.

  **Measured 2026-10-13** on an Apple M1 Max (10 cores, 64 GiB, macOS 27.0.1
  build 26A434, Swift 6.4), against a RELEASE build. Two commands, and they
  divide the record:

  ```
  scripts/measure-diff-cost
  ```

  ```
  MACSCP_DIFF_COST=1 swift test -c release --filter FileDiffCostTests
  ```

  Both run the same grid. **The script is the memory record and the suite
  reports only time**, and the division is a limit rather than a preference:
  the script runs one process per case, so its baseline really is a fresh
  process, while the suite runs every case in one process, where
  `phys_footprint` counts pages the allocator has not handed back. An earlier
  draft of the suite sampled the footprint anyway, and on `ladder/5792` (one
  line differing) it reported a delta of **409,600 bytes** for a
  **268,470,792**-byte table where the script reports **284,606,704** — a
  figure that depends on what the case before it happened to leave behind, and
  therefore says nothing. That sampler was removed rather than annotated. The
  TIME figures agree within 7.5% (`ladder/16384`, one line differing:
  2.297442875 s in the suite, 2.468680542 s in the script), which is what
  makes the division safe. **Every figure quoted below is the script's.** `swift build --build-tests -c
  release` builds neither, and did not before this task: it fails in
  `AdHocAuditTests.swift:3` and `AgentAuthTests.swift:18` with "unable to
  resolve Swift module dependency to a compatible module".

  **1. The grid the byte ceiling admits.** Three sizes against three line
  shapes, both densities: eighteen cases, of which **four ran and fourteen
  were abandoned** over a stated 2,500,000,000-byte table budget. Line counts
  are `size / (lineBytes + 1)`, one newline per line.

  | size | line | lines/side | table bytes | 1 differs | every 10th |
  |---|---|---|---|---|---|
  | 256 KiB | 80 B | 3,236 | 83,825,352 | 0.096034 s, 93,700,192 B | 0.101448958 s, 93,749,344 B |
  | 256 KiB | 8 B | 29,127 | 6,787,523,072 | abandoned | abandoned |
  | 256 KiB | 1 B | 131,072 | 137,441,050,632 | abandoned | abandoned |
  | 1 MiB | 80 B | 12,945 | 1,340,791,328 | 1.496644167 s, 1,492,911,184 B | 1.59848225 s, 1,493,386,320 B |
  | 1 MiB | 8 B | 116,508 | 108,594,776,648 | abandoned | abandoned |
  | 1 MiB | 1 B | 524,288 | 2,199,031,644,168 | abandoned | abandoned |
  | 4 MiB | 80 B | 51,781 | 21,451,004,192 | abandoned | abandoned |
  | 4 MiB | 8 B | 466,033 | 1,737,501,513,248 | abandoned | abandoned |
  | 4 MiB | 1 B | 2,097,152 | 35,184,405,643,272 | abandoned | abandoned |

  The last row is the 35 TB cell the arithmetic above names, reproduced by the
  run rather than only derived. **Only the longest-line shape is affordable at
  any size the ceiling admits, and not even that one at 4 MiB.**

  **2. Bytes are not the axis.** 4096 lines per side at five line lengths,
  every tenth line differing. The table is 134,283,272 bytes in all five.

  | line bytes | bytes/side | elapsed | peak |
  |---|---|---|---|
  | 1 B | 8,192 | 0.106928667 s | 200,294,544 B |
  | 2 B | 12,288 | 0.107052541 s | 200,294,544 B |
  | 8 B | 36,864 | 0.10468875 s | 201,146,512 B |
  | 40 B | 167,936 | 0.167267875 s | 202,703,016 B |
  | 80 B | 331,776 | 0.170179458 s | 202,801,320 B |

  A fortyfold spread in file size moves peak memory by **1.25%**. It moves
  time by **1.6×**, in one step between 8 and 40 bytes, which is where a
  Swift `String` stops comparing inline — a constant on the comparison, not a
  change in what the cost grows with.

  **3. Long thin tables**, which a per-side line bound would refuse.

  | pair | product | table bytes | elapsed | peak |
  |---|---|---|---|---|
  | 100,000 × 20 | 2,000,000 | 16,800,168 | 0.030626792 s | 33,800,264 B |
  | 500,000 × 20 | 10,000,000 | 84,000,168 | 0.153434875 s | 162,119,824 B |
  | 2,097,152 × 20 | 41,943,040 | 352,321,704 | 0.485232958 s | 674,431,480 B |

  **4. The square ladder**, 40-byte lines, which the bound is read off.

  | lines/side | product | table bytes | 1 differs | every 10th |
  |---|---|---|---|---|
  | 1,024 | 1,048,576 | 8,405,000 | 0.009730459 s, 9,666,560 B | 0.010553208 s, 9,879,552 B |
  | 2,048 | 4,194,304 | 33,587,208 | 0.037634125 s, 42,631,192 B | 0.04097075 s, 45,039,640 B |
  | 4,096 | 16,777,216 | 134,283,272 | 0.153218208 s, 200,016,016 B | 0.160900792 s, 200,343,696 B |
  | 5,792 | 33,547,264 | 268,470,792 | 0.290292125 s, 284,606,704 B | 0.314235625 s, 286,769,392 B |
  | 8,192 | 67,108,864 | 537,001,992 | 0.590658333 s, 675,021,304 B | 0.638620333 s, 675,054,072 B |
  | 10,000 | 100,000,000 | 800,160,008 | 0.864224583 s, 824,263,280 B | 0.959617166 s, 824,328,816 B |
  | 11,585 | 134,212,225 | 1,073,883,168 | 1.163917958 s, 1,145,471,840 B | 1.260838833 s, 1,145,537,376 B |
  | 16,384 | 268,435,456 | 2,147,745,800 | 2.468680542 s, 2,428,585,736 B | 2.557657666 s, 2,428,847,880 B |

  Density moves the time by at most **11%** anywhere in this measurement — the
  largest gap is the 10,000 row — and one rung was *faster* with ten times the
  differences (16,384 one-byte lines, below: 1.612165458 s against
  1.56624075 s).

  **5. The pathological shape, started well below the ceiling**, at one content
  byte and a newline. **This is where the ladder was abandoned, and the rung is
  the result**: 64 KiB per side, which is **one sixty-fourth of what the byte
  ceiling admits**, asks for an 8,590,458,888-byte table and was not run.

  | per side | lines/side | table bytes | 1 differs | every 10th |
  |---|---|---|---|---|
  | 8 KiB | 4,096 | 134,283,272 | 0.102817541 s, 202,326,160 B | 0.103796209 s, 199,508,112 B |
  | 16 KiB | 8,192 | 537,001,992 | 0.398348625 s, 673,497,568 B | 0.405818792 s, 675,037,688 B |
  | 32 KiB | 16,384 | 2,147,745,800 | 1.612165458 s, 2,428,569,352 B | 1.56624075 s, 2,428,585,712 B |
  | 64 KiB | 32,768 | 8,590,458,888 | **abandoned** | **abandoned** |

  **6. The two corners of the chosen bound**, both exact integers.

  | corner | pair | product | table bytes | elapsed | peak |
  |---|---|---|---|---|---|
  | largest square | 5,792 × 5,792 | 33,547,264 | 268,470,792 | 0.289843041 s | 285,425,880 B |
  | largest square, every 10th | 5,792 × 5,792 | 33,547,264 | 268,470,792 | 0.312620667 s | 285,671,640 B |
  | most asymmetric | 2,097,152 × 16 | 33,554,432 | 285,212,808 | 0.455469583 s | 606,978,504 B |

  5,793 × 5,793 = 33,558,849 is the first square refused; 2,097,152 × 17 the
  first asymmetric pair.

  **The decision.** The product bound, at `1 << 25`. The ladder is smooth —
  both peak memory and elapsed time track the product linearly, with no knee
  to put a bound at — so the number comes from a budget of about **300 MB of
  transient peak for a square pair**, and `1 << 25` is the largest power of
  two inside it. The product is chosen over a per-side line count because
  500,000 × 20 costs 162,119,824 bytes and any per-side bound low enough to
  make a square pair safe (about 5,800) refuses it by a factor of
  eighty-six. Hirschberg's linear-space LCS was weighed and **not** taken:
  it removes the memory term and leaves the time term, measured at 9.195 ns
  per table entry, so a 100,000-line square pair is 10,000,200,001 entries,
  about 92 s before Hirschberg's own constant and roughly twice that after —
  the bound would move from memory to time rather than disappear, at the
  price of replacing an implementation that 29 cases in `FileDiffTests`
  currently hold correct. What would genuinely widen the admissible set is a
  diff whose cost follows the differences (Myers); that is its own piece of
  work.

  **What the bound refuses that this machine managed comfortably**, named
  because the cost of a bound belongs beside it: two 8,192-line files
  (0.590658333 s, 675,021,304 B), two 10,000-line ones (0.864224583 s,
  824,263,280 B) and two 11,585-line ones (1.163917958 s, 1,145,471,840 B).
  Generated sources, long logs and minified bundles reach those lengths. The
  refusal is the deliberate price of not asking an 8 GB Mac for a gigabyte to
  show a diff, and the user is told which two line counts stopped it.

  **The bound's known imprecision**, stated rather than modelled: peak memory
  ran from **1.03 to 2.13** times the bare eight-bytes-per-entry arithmetic
  across every shape measured — 824,263,280 against 800,160,008 at the low
  end, 606,978,504 against 285,212,808 at the high end — because a row of 17
  `Int`s costs more in its own heap allocation than in its entries. So the two
  corners of one product differ by 2.1× in memory. A bound on an estimated
  footprint instead of the product would narrow that, at the cost of a
  malloc-overhead constant that goes stale the moment `editScript` stops using
  `[[Int]]`; the product is what a reader can check by hand, and this
  paragraph is the error bar on it.

The folder comparison does NOT depend on eligibility: a binary, oversized or
too-many-lines pair is still classified `same` / `differs` / `undetermined` by
size and checksum. (**Corrected 2026-10-13 (Task 6): this sentence read "a
binary or oversized pair is still classified", which named the refusals that
existed when it was written.** Nothing about the rule changed; the list did.)
Only the content diff of that pair refuses, with its reason shown
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
  the size ceiling on both sides of its boundary. **Extended 2026-10-13 (Task
  6)** with the line-count bound on both sides of each of its two corners —
  5792 against 5793 for the square one, 2,097,152 × 16 against × 17 for the
  asymmetric one — plus an overflowing product, which must come back as a
  refusal and not as a trap, and a positive control that the BYTE check
  admits the pair the LINE check refuses, so the line cases are not being
  satisfied by the byte ceiling standing in front of them.
- The diff's cost is measured, never asserted: `FileDiffCostTests` is gated
  behind `MACSCP_DIFF_COST=1`, reports every figure through `Issue.record` at
  warning severity and `print`, and compares none of them to a threshold.
  A case whose table exceeds the suite's own stated budget is reported as
  abandoned with its arithmetic, because where a ladder stopped is a result.
- The ownership rule gets a wiring guard: the comparison model is reached
  through the tab, and the window holds no connection of its own.
- No test asserts a wall-clock ceiling. Hang bounds are `.timeLimit`.

## What this design does not do

It does not edit either side, does not merge, does not compare across
sessions, and does not hand anything to an external tool. Each of those is a
separate wish or a separate row.
