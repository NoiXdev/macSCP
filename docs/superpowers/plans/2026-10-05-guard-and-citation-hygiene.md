# Guard and Citation Hygiene Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Repair three source-scanning guards so each catches what it claims
to, correct one doc comment that counted three deciders where four decide,
and re-derive six `docs/BACKLOG.md` rows whose citations were stale before
the typed-findings plan.

**Architecture:** Five independent tasks on one branch. Tasks 1 and 2 touch
one test file each and are proven by planting a violation and measuring the
guard red and green. Task 3 is prose about code with a re-run `grep` as its
only check. Tasks 4 and 5 edit `docs/BACKLOG.md` only. Nothing here changes
what the app does.

**Tech Stack:** Swift 6 strict, SwiftPM, Swift Testing. Build and test with
`swift test --build-system native` — the default build system fails on
SwiftTerm's `Shaders.metal`.

**Spec:** `docs/superpowers/specs/2026-10-05-guard-and-citation-hygiene-design.md`
(committed `a496c825`). **Base:** `develop` at `35664708`.
**Worktree:** `/Users/noidee/macSCP/.claude/worktrees/guard-and-citation-hygiene`,
branch `guard-and-citation-hygiene`.

## Global Constraints

- **Every written artifact is English** — code, comments, test names, commit
  messages, plans, specs, backlog rows. Chat with the maintainer is German;
  that is not an artifact.
- **Commit footer on every commit:** `Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>`
- **Conventional Commits**, enforced by CI.
- **Run the whole suite with** `swift test --build-system native`. One
  failure is known and expected: `ViewTestabilitySpike` (its own backlog
  row — a pixel comparison macOS 27 falsifies). Any other red is yours.
- **A number travels with the command that produced it** (CLAUDE.md). Write
  the command beside the figure, run it in the form it is committed, and
  **run it again after writing the sentence** — the sentence can change the
  answer.
- **Prefer the symbol to the line number.** A line number is written only
  where no symbol names the thing, and then it carries the date it was
  derived.
- **A correction quotes what it withdraws** (CLAUDE.md). In
  `docs/BACKLOG.md`, a row may be corrected in place provided every
  withdrawal quotes the wording it replaces, **verbatim**.
- **Never `git checkout -- <file>`** — it restores from the index and takes
  uncommitted edits with it. Planted probe files are untracked; remove them
  with `rm` and read back `git status --porcelain`.
- **Do not launch the GUI or the app binary.** Do not start the Docker rig;
  no task here needs it.
- **Do not push.** The coordinator pushes after the whole-branch review.

---

### Task 1: The pane-visibility guard reads code, and exempts by path

**Files:**
- Modify: `Tests/macSCPAppKitTests/PaneVisibilityOwnershipGuardTests.swift`
  (inside `onlySessionTabReadsShowsFilesOffTheSession`, and that function's
  doc comment)

**Interfaces:**
- Consumes: `SourceCorpus.code(of:)` and the suite's own
  `relativePath(of:)`, both already present. `SourceCorpus.code(of:)` is
  `SwiftSource.blankingCommentsAndStrings` of the file — comments **and**
  string literals blanked, length and line count preserved, which
  `SourceCorpus.lengthCheckedView` enforces for every view it serves. The
  offender message reports `index + 1` of a `components(separatedBy: "\n")`
  split, so preserved length means the reported line numbers do not move.
- Produces: nothing later tasks consume.

- [ ] **Step 1: Plant the A1 violation — a doc comment that spells the property**

Create an untracked file
`Sources/MacSCPAppKit/ProbeA1Scratch.swift` with exactly this content:

```swift
/// Probe A1. This comment spells `session.showsFiles` on purpose.
enum ProbeA1Scratch {}
```

The guard scans every `.swift` file under `Sources/MacSCPAppKit` at any
depth, so a new file in the target is scanned without registering it
anywhere.

- [ ] **Step 2: Measure A1 red, three times**

Run three times:
`swift test --build-system native --filter onlySessionTabReadsShowsFilesOffTheSession`

Expected: **FAIL** all three, with `ProbeA1Scratch.swift:1` among the
offenders. Record the count (expected `3 of 3`) and quote one failure
message verbatim — that quote goes into the commit message as the observed
red. If it is green even once, stop and report: the guard is not reading
what this task assumes.

- [ ] **Step 3: Make the A1 change**

In `onlySessionTabReadsShowsFilesOffTheSession`, change the read from
`text(of:)` to `code(of:)`:

```swift
            let lines = try SourceCorpus.code(of: file).components(separatedBy: "\n")
```

Do not change anything else in this step.

- [ ] **Step 4: Measure A1 green, three times**

Run the same filter three times. Expected: **PASS** all three, with the
probe file still in the tree. Record `3 of 3`.

- [ ] **Step 5: Remove the A1 probe and confirm the tree**

```bash
rm Sources/MacSCPAppKit/ProbeA1Scratch.swift
git status --porcelain
```

Expected: exactly one line,
`M  Tests/macSCPAppKitTests/PaneVisibilityOwnershipGuardTests.swift` (or its
unstaged form). Any other path means something else was touched — stop and
report. **Do not use `git checkout --` to clean up.**

- [ ] **Step 6: Plant the A2 violation — the exemption's blind spot**

Create an untracked file
`Sources/MacSCPAppKit/Presentation/SessionTab.swift` with exactly this
content:

```swift
/// Probe A2. A second file carrying the exempted NAME, one directory down.
struct ProbeA2Session {
    var showsFiles = false
}

enum ProbeA2Scratch {
    static func read(_ session: ProbeA2Session) -> Bool {
        session.showsFiles
    }
}
```

Three things make this the right plant, each checked 2026-10-05:

- `Sources/MacSCPAppKit/Presentation/` already exists, so the task creates
  no directory.
- Two files named `SessionTab.swift` in one module is legal Swift — file
  names carry no meaning — and the type names above clash with nothing.
- The scanner, `readsShowsFilesOffASession(_:)`, needs only a `.showsFiles`
  member access whose receiver name contains `session`
  case-insensitively. It does **not** need `BrowserSession`, which is
  declared in `Sources/MacSCPAppKit/SessionTab.swift` and would drag the
  probe into the App's real types for nothing.

Build before concluding anything about red or green:
`swift build --build-system native` must succeed first.

- [ ] **Step 7: Measure A2 green-before, three times**

Run three times:
`swift test --build-system native --filter onlySessionTabReadsShowsFilesOffTheSession`

Expected: **PASS** all three *with the violation present* — that is the
defect, and it is what makes the change worth making. Record `3 of 3`
green. If it is red, the bare-name exemption is not doing what the row
says; stop and report.

- [ ] **Step 8: Make the A2 change**

Replace the exemption filter:

```swift
        let files = try Self.appSwiftFiles()
            .filter { Self.relativePath(of: $0) != "SessionTab.swift" }
```

- [ ] **Step 9: Measure A2 red-after, three times**

Run the same filter three times. Expected: **FAIL** all three, naming
`Presentation/SessionTab.swift` — by its relative path, which is the other
half of the point. Record `3 of 3` and quote one message.

- [ ] **Step 10: Remove the A2 probe and confirm the tree**

```bash
rm Sources/MacSCPAppKit/Presentation/SessionTab.swift
git status --porcelain
```

Expected: again exactly the one modified test file. If
`Sources/MacSCPAppKit/Presentation/` was created by this task rather than
already present, remove it too and say so in the report.

- [ ] **Step 11: Write both measurements into the suite's doc comment**

The doc comment on `onlySessionTabReadsShowsFilesOffTheSession` currently
reads:

```swift
    /// The guard: `SessionTab.swift` owns this property, nobody else touches
    /// it.
```

Replace it with the text below, substituting the counts you actually
measured for `3 of 3` if they differed:

```swift
    /// The guard: `SessionTab.swift` owns this property, nobody else touches
    /// it.
    ///
    /// Reads `code(of:)`, not `text(of:)`: a doc comment or a string literal
    /// spelling `session.showsFiles` is not a read of it, and this project
    /// scans source while writing long explanatory comments, which is
    /// exactly where the two collide (CLAUDE.md, "Source-scanning guards
    /// read comments too"). Measured 2026-10-05: a planted doc comment
    /// spelling the property was red 3 of 3 against `text(of:)` and green
    /// 3 of 3 against `code(of:)`. The two views are the same length in
    /// `Character`s — `SourceCorpus.lengthCheckedView` refuses one that is
    /// not — so the offender line numbers are unchanged.
    ///
    /// Exempts by `relativePath(of:)`, not by `lastPathComponent`: the walk
    /// descends, so a bare name would exempt a `SessionTab.swift` anywhere
    /// in the target from the one negative this suite exists for. Measured
    /// 2026-10-05: a violation planted in
    /// `Sources/MacSCPAppKit/Presentation/SessionTab.swift` was green 3 of 3
    /// against the bare name — silently exempted — and red 3 of 3 against
    /// the relative path.
```

- [ ] **Step 12: Run the whole suite**

Run: `swift test --build-system native`

Expected: PASS except the known `ViewTestabilitySpike` failure. Quote the
final summary line into your report.

- [ ] **Step 13: Commit**

Stage only the test file and commit:

```
test(appkit): the pane-visibility guard reads code, and exempts by path

Two defects in one negative check, both found by the cleanup plan's final
review on 2026-09-28 and both widened by a22658df, which took the walk from
116 to 119 files without touching either.

It read SourceCorpus.text(of:), so a doc comment or a string literal
spelling session.showsFiles was reported as an offender — the collision
CLAUDE.md describes under "Source-scanning guards read comments too". And
it exempted by lastPathComponent, so now that the walk descends, a
SessionTab.swift in any subdirectory would have been silently exempted from
the one negative this suite exists for. The suite already carried the
helper the fix needs: relativePath(of:).

Both measured, both directions. A planted doc comment spelling the property
was red 3 of 3 against text(of:) and green 3 of 3 against code(of:). A
violation planted in Presentation/SessionTab.swift was green 3 of 3 against
the bare name — the defect — and red 3 of 3 against the relative path. The
counts are in the suite's own doc comment beside the 2026-09-27
measurement that widened the walk.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
```

---

### Task 2: The CLI source walk descends

**Files:**
- Modify: `Tests/macSCPCoreTests/CLITunnelStartTests.swift` (inside
  `CLISourceWalk.init(directory:)` and its doc comment)

**Interfaces:**
- Consumes: `SourceCorpus.files(under:)` — every regular file under the
  directory at any depth, in enumerator order. `SourceCorpus.children(of:)`
  is the flat variant being replaced.
- Produces: nothing later tasks consume.

- [ ] **Step 1: Read what the walk feeds**

`CLISourceWalk.init(directory:)` builds `slices` and `declarations` from the
files it reads. `derivedBuilder()` asks
`walk.deciderBuilders(reachableFrom: lsCommandFile)` and asserts
`#expect(builders.count == 1, …)`. That assertion is what a missed
subdirectory would silently satisfy. Read both before changing anything.

- [ ] **Step 2: Plant the violation — a second builder one directory down**

Create an untracked directory and file
`Sources/MacSCPCLI/ProbeA3/ProbeA3Builder.swift` with exactly this content:

```swift
import Foundation
import macSCPCore

/// Probe A3. A second function returning a HostKeyDecider, one directory
/// below the flat listing, under a name LsCommand.swift already calls.
func parse(probeA3: Int) -> HostKeyDecider {
    .refusing
}
```

Why `parse`, derived rather than guessed (measured 2026-10-05): the walk
reaches a function only if its name appears as `name(` with a lowercase
first letter in `LsCommand.swift` or in the body of something already
reached (`CLISourceWalk.calledNames(in:)`). `LsCommand.swift` calls exactly
**five** such names, and of those exactly **two** — `list` and `parse` —
have no `func` of that name anywhere under `Sources/MacSCPCLI`. A name that
is already declared would overwrite that entry in `CLISourceWalk.slices`,
which is keyed by name, rather than adding a second builder. `parse` is
free, so the probe adds one.

`SessionReference.parse(…)` is a static method on a type and does not clash
with a free function. `HostKeyDecider.refusing` is a `public static let` on
the type (`Sources/macSCPCore/Connection/HostKeyDecider.swift`), so the body
needs no closure.

**No tracked file is edited by this probe** — that is the whole reason for
deriving the name rather than adding a call to `LsCommand.swift`.

Build first: `swift build --build-system native` must succeed.

- [ ] **Step 3: Measure green-before, three times**

Run three times:
`swift test --build-system native --filter CLITunnelStartTests`

Expected: **PASS** all three with the second builder present — the flat
listing never saw it. Record `3 of 3`. If it is red, the plant is reachable
some other way or the walk already descends; stop and report what you
observed rather than adjusting the plant to get the answer this plan
predicts.

- [ ] **Step 4: Make the change**

In `CLISourceWalk.init(directory:)`:

```swift
        let files = try SourceCorpus.files(under: directory)
            .filter { $0.pathExtension == "swift" }
```

- [ ] **Step 5: Measure red-after, three times**

Run the same filter three times. Expected: **FAIL** all three on
`#expect(builders.count == 1, …)`, the message naming both builders. Record
`3 of 3` and quote one message.

- [ ] **Step 6: Remove the probe and confirm the tree**

```bash
rm -r Sources/MacSCPCLI/ProbeA3
git status --porcelain
```

Expected: exactly one modified path,
`Tests/macSCPCoreTests/CLITunnelStartTests.swift`. Nothing tracked was
edited by this task's probe, so anything else in this output is a stray
edit — find it before continuing.

- [ ] **Step 7: Write the measurement into the walk's doc comment**

`CLISourceWalk`'s doc comment currently ends:

```swift
/// It is a test fixture, not a parser, and every question put to it is
/// checked for having found something at all.
```

Append to that doc comment:

```swift
///
/// Reads `SourceCorpus.files(under:)`, which descends, not
/// `children(of:)`, which does not. `Sources/MacSCPCLI` is flat today, so
/// this changes nothing at HEAD — it closes a latent hole:
/// `derivedBuilder()`'s `#expect(builders.count == 1)` would have stayed
/// green at 1 if a second function returning `HostKeyDecider` appeared
/// under a future subdirectory, which is a negative that reads like a
/// check that is satisfied (CLAUDE.md, "a negative check whose SPAN is
/// wrong can never match"). Measured 2026-10-05: a second builder planted
/// one directory down was green 3 of 3 against the flat listing and red
/// 3 of 3 against this walk.
/// `CLISessionsCommandGuardTests.everySessionTargetCommandCarriesTheCompletion`
/// made the same choice for the same reason.
```

- [ ] **Step 8: Run the whole suite**

Run: `swift test --build-system native`

Expected: PASS except the known `ViewTestabilitySpike` failure.

- [ ] **Step 9: Commit**

```
test(cli): the CLI source walk descends into subdirectories

The last flat whole-directory reader among this project's source-scanning
guards. CLISourceWalk.init(directory:) read SourceCorpus.children(of:),
which by construction does not descend, and derivedBuilder()'s
#expect(builders.count == 1) would have stayed green at 1 if a second
function returning HostKeyDecider had appeared under a future
Sources/MacSCPCLI subdirectory.

Sources/MacSCPCLI is flat today, so this changes nothing at HEAD; it closes
a hole before it opens. Its sibling
CLISessionsCommandGuardTests.everySessionTargetCommandCarriesTheCompletion
chose files(under:) for this reason in 2026-09-02 and says so in a comment.

Measured 2026-10-05, both directions: a second builder planted one
directory down was green 3 of 3 against the flat listing and red 3 of 3
against the descending walk. The counts are in the walk's doc comment.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
```

---

### Task 3: A comment that counted three where four decide

**Files:**
- Modify: `Sources/macSCPCore/Diagnostics/ConnectionDiagnostics+Jump.swift`
  (the doc comment on `outcome(forUnanswered:)` only)

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: nothing later tasks consume.

- [ ] **Step 1: Count, before writing anything**

Run: `grep -rn "outcome(forUnanswered" Sources/`

Expected 5 lines: the declaration in
`ConnectionDiagnostics+Jump.swift`, exactly three calls
(`ConnectionDiagnostics.swift`, and two in
`ConnectionDiagnostics+Jump.swift`), and one mention inside a different doc
comment in `ConnectionDiagnostics.swift`. Record the five paths and lines
as you observed them, not as this plan predicts them. The comment being
corrected is **not** among them — it spells the name with the argument
label alone.

- [ ] **Step 2: Read the fourth decider**

Run: `grep -n 'neverBegan\|probeNotStarted\|notStarted' Sources/macSCPCore/Diagnostics/InternetSpeedProbe.swift`

Confirm two things with your own eyes before writing about them: that it
maps `.unanswered(.neverBegan)` to `DiagnosticReason.probeNotStarted`, and
that it later turns that back into `.notStarted` by **comparing against the
symbol** rather than against a copied string. If either is not what you
see, report it — the comment you are about to write says both.

- [ ] **Step 3: Replace the comment**

The current comment on `outcome(forUnanswered:)` is:

```swift
    /// The outcome a step reports when its probe did not answer: the
    /// deadline's own `timedOut` for a body that ran and overran, and
    /// `notStarted` for one this Mac never gave a thread.
    ///
    /// Spelled ONCE, and read from three places (counted 2026-09-27:
    /// `dialJump`, `race` above, and `bounded(_:_:)` for a contribution), so
    /// the three cannot come to disagree about what a probe that never began
    /// says to a reader.
```

Replace it with:

```swift
    /// The outcome a step reports when its probe did not answer: the
    /// deadline's own `timedOut` for a body that ran and overran, and
    /// `notStarted` for one this Mac never gave a thread.
    ///
    /// Spelled ONCE here and called from three places (recounted
    /// 2026-10-05: `dialJump`, `race` above, and `bounded(_:_:)` for a
    /// contribution), so those three cannot come to disagree about what a
    /// probe that never began says to a reader.
    ///
    /// FOUR places decide that question, not three. `InternetSpeedProbe`
    /// maps `.unanswered(.neverBegan)` to
    /// `DiagnosticReason.probeNotStarted` without calling this, and reads
    /// it back as `.notStarted` later. It cannot drift apart from this one
    /// either, because it compares the SYMBOL rather than carrying a second
    /// copy of the sentence — but it is a second decision site, and this
    /// comment said "read from three places" in a sentence whose whole
    /// point was that every reader is here. Counted 2026-09-28 by the
    /// cleanup plan's final review, recounted before this was written.
```

- [ ] **Step 4: Re-run the count AFTER writing the comment**

Run again: `grep -rn "outcome(forUnanswered" Sources/`

Expected: still 5 lines, the same five. The new comment must not have added
a sixth — it does not spell `outcome(forUnanswered`. If the count moved,
reword the comment, never the count. This step is not optional: CLAUDE.md
records two cases where a sentence changed the answer to its own command,
the second inside the fix for the first.

- [ ] **Step 5: Build**

Run: `swift build --build-system native`

Expected: success. A doc comment cannot break the build, which is the
point of checking.

- [ ] **Step 6: Commit**

```
docs(core): outcome(forUnanswered:) names its fourth decider

The comment said the mapping is "Spelled ONCE, and read from three places
… so the three cannot come to disagree about what a probe that never began
says to a reader". The three calls are right — grep -rn
"outcome(forUnanswered" Sources/ returns the declaration, exactly three
calls and one mention in another doc comment, recounted 2026-10-05 and
again after this comment was written.

But a fourth place decides the same question without calling it:
InternetSpeedProbe maps .unanswered(.neverBegan) to
DiagnosticReason.probeNotStarted itself and reads it back as .notStarted.
It compares the symbol rather than copying the sentence, so it cannot
drift — but the claim that every reader is here was a claim about the rest
of the project, and it was one site short. Found 2026-09-28 by the cleanup
plan's final review.

The maintainer chose naming the fourth site over dropping the count: the
count is countable here, unlike the 412 sentence of 2026-10-02 that
enumerated causes nothing could enumerate. Making InternetSpeedProbe call
this function was rejected for this pass — a code change on a path the
finding never measured.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
```

---

### Task 4: Six backlog rows re-derived at HEAD

**Files:**
- Modify: `docs/BACKLOG.md` (six rows; no other row)

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: the corrected rows Task 5 then closes `147`, `148` and `285`
  against.

**The six rows,** named by the title in their first cell, with the stale
citations row 285 records them carrying:

1. **Diagnostics: error text as a leak route** — nine `S3FileSystem.swift`
   sites at `:730`, `:736`, `:1045`, `:1052`, `:1062`, `:1156`, `:1162`,
   `:1171`, `:1215`, and four English sentences quoted by hand.
2. **S3 `delete(path:)` on a directory is a silent no-op** —
   `delete(path:)` at `:387-395`, `RootMode.resolve(path:)` at `:76-92`.
3. **Raw error text can still reach the CLI and the browser banner** — a
   ten-site census pinned to `2bc3fa90`.
4. **S3: the tools of s3Manager** — `S3FileSystem.createDirectory` at
   `:521`, `rename` at `:552`.
5. **the first delete-lookup row** — `deleteLookup` at `:350-379`,
   `DeleteLookup` at `:320-324`, `listedEntry(at:)` at `:310`.
6. **the second delete-lookup row** — `deleteLookup` at `:360-402`,
   `DeleteLookup` at `:323-328`.

Rows 5 and 6 are the two the backlog itself calls the delete-lookup rows;
find them by `grep -n 'deleteLookup' docs/BACKLOG.md`.

- [ ] **Step 1: Derive every replacement from the tree**

Run each of these from the repository root and record exactly what it
printed, with today's date:

```
grep -n 'S3EndpointReason\.' Sources/macSCPCore/S3/S3FileSystem.swift
grep -n 'enum S3EndpointReason' Sources/macSCPCore/S3/S3RequestSigning.swift
grep -n 'func delete(path' Sources/macSCPCore/S3/S3FileSystem.swift
grep -n 'enum RootMode' Sources/macSCPCore/S3/S3FileSystem.swift
grep -n 'func resolve(path' Sources/macSCPCore/S3/S3FileSystem.swift
grep -n 'func createDirectory' Sources/macSCPCore/S3/S3FileSystem.swift
grep -n 'func rename' Sources/macSCPCore/S3/S3FileSystem.swift
grep -n 'func deleteLookup' Sources/macSCPCore/S3/S3FileSystem.swift
grep -n 'enum DeleteLookup' Sources/macSCPCore/S3/S3FileSystem.swift
grep -n 'func listedEntry(at' Sources/macSCPCore/S3/S3FileSystem.swift
```

At `35664708` on 2026-10-05 the first printed **nine** lines and the others
one each. Your run governs, not this sentence — if a count differs, say so
in your report and write what you measured.

- [ ] **Step 2: Correct row 1 — the nine sites become a command and four constants**

This row's nine line numbers and four hand-quoted sentences are both
superseded: the sentences are now the constants of `S3EndpointReason` in
`S3RequestSigning.swift`. Replace the enumeration with:

- the **symbol** `S3EndpointReason`, and the four constant names you read
  in step 1,
- the command `grep -n 'S3EndpointReason\.' Sources/macSCPCore/S3/S3FileSystem.swift`
  written into the cell, with the number of lines it printed on 2026-10-05,
- and a group sentence withdrawing the old citations, in this form (fill in
  the exact old wording from the row — **verbatim**, copied, not retyped
  from this plan):

  > Corrected 2026-10-05. This row cited the nine sites as `S3FileSystem.swift:730`, `:736`, … and quoted the four English sentences by hand; those sentences are now the constants of `S3EndpointReason` (`S3RequestSigning.swift`), and the line numbers were derived at a head this row no longer describes. Nothing the old citations asserted is dropped — they are named here so the earlier measurement stays findable.

  The command must run **in the form it is committed**. This is a markdown
  table cell, so a pipe would split the cell: use several `-e` patterns, never
  one `-E` alternation. The command above has no pipe and is safe as written —
  verify that by extracting it from the committed file and running it, which
  is step 6.

- [ ] **Step 3: Correct rows 2, 4, 5 and 6 — line numbers become symbols**

Each of these cites a function or type by line number where the symbol name
alone identifies it. Replace each citation with the symbol
(`S3FileSystem.delete(path:)`, `RootMode.resolve(path:)`,
`S3FileSystem.createDirectory(at:)`, `S3FileSystem.rename(from:to:)`,
`deleteLookup(path:)`, `DeleteLookup`, `listedEntry(at:)`), and give each
row one group sentence of the same shape as step 2, quoting that row's own
withdrawn citations verbatim.

Use the exact signatures you read in step 1 — do not copy the
parenthesised argument labels from this plan without checking them against
the `grep` output.

- [ ] **Step 4: Correct row 3 — a census is not a symbol**

The ten-site census is a **count**, and no symbol names it. Two honest
options; take the first unless your step-1 reading rules it out:

(a) Re-derive the census at HEAD and write it with the command that
produced it, the date, and the raw total with its exclusions named one by
one.

(b) If the census cannot be reproduced because what it counted no longer
exists in that form (the endpoint sentences became constants), mark it as
the **dated snapshot it is** — "Counted at `2bc3fa90`; the endpoint half of
this census is superseded by `S3EndpointReason`" — rather than silently
leaving a bare number that reads as current.

Either way the row gains the same group sentence withdrawing what it
replaces.

- [ ] **Step 5: Confirm no other row moved**

Run: `git diff --stat docs/BACKLOG.md` and
`git diff -U0 docs/BACKLOG.md | grep -c '^[+-]|'`

Read the diff and confirm that exactly six table rows changed. A seventh
means a stray edit; find it before continuing.

- [ ] **Step 6: Extract every committed command and run it**

Do not retype the commands. Extract them from the file as committed and run
each one:

```bash
git diff -U0 docs/BACKLOG.md | grep '^+' | grep -o 'grep -n[^`]*' | while read -r c; do echo "### $c"; eval "$c" | wc -l; done
```

Every command must run without repair and print the number of lines the row
claims for it. A command that needs repairing before it runs is the exact
failure CLAUDE.md records under "a command that did not run as committed" —
fix the row, not your invocation.

- [ ] **Step 7: Commit**

```
docs(backlog): six rows re-derived, their stale citations quoted as withdrawn

Found 2026-09-28 by the typed-findings plan's closeout, which deliberately
did not fix them — shifting a wrong number by two makes it look freshly
measured.

Re-derived at 35664708 rather than adjusted. Where a symbol names the
thing, the symbol replaces the line number: S3FileSystem.delete(path:),
RootMode.resolve(path:), createDirectory, rename, deleteLookup,
DeleteLookup, listedEntry(at:). The nine endpoint sites become the
re-runnable grep that finds them plus the four S3EndpointReason constants
that replaced the hand-quoted sentences.

The reason not to write fresh numbers is measured: the row recording these
findings gave the nine endpoint sites as :1064, :1069, :1380, :1387, :1397,
:1496, :1502, :1511, :1555 at 2428a642, and seven of the nine had moved by
four lines a week later. Fresh numbers would have been stale before anyone
read them.

Each row carries one group sentence quoting the citations it withdraws,
verbatim — the maintainer's call on 2026-10-05, following the pattern the
412 row in this file already uses. Every committed command was extracted
from the committed text and run in that form.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
```

---

### Task 5: Close the three rows, and refill the index they emptied

**Files:**
- Modify: `docs/BACKLOG.md` (the three rows this branch closes, and the
  closing section "If you don't know where to start")

**Interfaces:**
- Consumes: Task 4's corrected rows, and Tasks 1-3's commits.
- Produces: nothing.

- [ ] **Step 1: Close the three rows in place**

Each of the three rows below gets a `**Done 2026-10-05**` passage naming
what closed it and the commit. A closure **adds** a finding; it withdraws
no earlier measurement, so it owes no quote.

- `Three guard suites still read raw source or exempt by file name` —
  closed by Tasks 1 and 2. Record both directions of all three
  measurements.
- `` `outcome(forUnanswered:)`'s comment claims three readers where a fourth decides the same question ``
  — closed by Task 3.
- `Four rows in this file carry citations that were stale before the typed-findings plan`
  — closed by Task 4.

While closing the first, correct its one stale citation: it names the
`files(under:)` precedent at `CLISessionsCommandGuardTests.swift:408`,
and on 2026-10-05 that is at `:414`, inside
`everySessionTargetCommandCarriesTheCompletion`. Replace the number with
the symbol and quote the withdrawn citation — this correction is inside a
row of the measurement record, so the rule binds it.

- [ ] **Step 2: Choose three new candidates by READING the rows**

The section "If you don't know where to start" names exactly the three rows
this branch closes. Leaving them would point a reader at three defects this
same file records as fixed — the failure the section's own preamble
documents having made on 2026-10-02.

Choose three replacements by reading the table, not from memory. Start
from the rows that open `**Open` and carry no closure marker:

```
awk -F'|' '/^\|/ && $3 ~ /^ \*\*Open/ && $3 !~ /\*\*(Done|Closed|Fixed|Resolved)[^*]*\*\*/ { t=$2; gsub(/^ +| +$/,"",t); printf "%d\t%s\n", NR, t }' docs/BACKLOG.md
```

Exclude the maintainer's own rows — every `Sight checks for the …` row and
anything marked a maintainer wishlist or a decision taken for the
maintainer. From what remains, pick three that a fresh contributor could
finish in one sitting, and say in one clause each **why that one**.

- [ ] **Step 3: Rewrite the section's assertion command for the new three**

The section carries a committed `awk` command asserting that each named row
opens `**Open` and ends `Not started.`, and prints how many rows it
matched. Rewrite it for the three you chose, keeping its shape: matched by
title, reporting each property as `1` or `0` rather than only staying
silent when it holds, and ending with the match count against the expected
count.

Keep it anchored to a leading `|` so it reads the table and not its own
text in that section.

- [ ] **Step 4: Run the rewritten command, from the committed file**

Extract the command from the file as committed — do not retype it — and
run it. Record what it printed, per row, into the section exactly as the
previous version did ("Run 2026-10-05, it printed … for rows N, M and K and
`rows matched=3, expected 3`").

If it prints `ends-Not-started=0` for a row you chose, that row does not
end `Not started.`; either choose another or change the claim the preamble
makes. Do not change the command to make the answer come out right.

- [ ] **Step 5: Account for what the section replaced**

Add a short passage recording that the three previous candidates were
closed by this branch, naming them. The section already carries two such
passages (2026-10-01 and 2026-10-02); follow their form.

- [ ] **Step 6: Run the whole suite one last time**

Run: `swift test --build-system native`

Expected: PASS except the known `ViewTestabilitySpike` failure.

- [ ] **Step 7: Commit**

```
docs(backlog): three rows closed, and the index that named them refilled

Closes the three rows this branch set out to clear: the guard suites that
read raw source or exempted by bare file name, the comment that counted
three deciders where four decide, and the six rows whose citations were
stale before the typed-findings plan.

Closing them empties the file's own "If you don't know where to start"
section, which named exactly these three — leaving it would point a reader
at three defects this same file records as fixed, which is the failure that
section's preamble documents having made on 2026-10-02. Three replacements
are read out of the table rather than remembered, and the section's
assertion command is rewritten for them and re-run from the committed text.

The first closed row also had one stale citation of its own: it named the
files(under:) precedent at CLISessionsCommandGuardTests.swift:408, which on
2026-10-05 is at :414. Replaced by the symbol, with the withdrawn citation
quoted.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
```

---

## Notes for the coordinator

- **Baseline, measured 2026-10-05 in this worktree at `a496c825`:**
  `swift test --build-system native` ran **6632 tests in 569 suites** and
  failed with **exactly one issue** — `ViewTestabilitySpike`, "Varying only
  isRegex leaves the pixels unchanged", `ViewTestabilitySpike.swift:202:9`,
  `Expectation failed: off == on`. That is the known expected failure and
  it has its own backlog row. Any other red in this branch is the branch's.
  A first attempt at this baseline piped the run through `tail -40` and so
  threw away the `✘ Test … recorded an issue` line, leaving only the run
  summary — which reads exactly like the unattributed-failure row in
  `docs/BACKLOG.md` and is not one. Capture the whole log.
- **Probes and a shared checkout.** `docs/BACKLOG.md` carries an open row
  saying these do not mix. This work runs in a worktree, not the main
  checkout, and plants only untracked files under `Sources/`. The Docker
  rig is **not** started — no task needs it, and the rig may only be started
  from the main checkout.
- **No probe edits a tracked file.** Task 2's plant reaches the walk
  through `parse`, a name `LsCommand.swift` already calls and nothing under
  `Sources/MacSCPCLI` declares, so no call has to be added anywhere. Every
  task still reads `git status --porcelain` back after removing its probe.
- **Nothing here is user-visible**, so no noix-docs work is owed.
