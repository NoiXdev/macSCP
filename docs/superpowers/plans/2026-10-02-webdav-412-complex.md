# The WebDAV 412 complex — implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> superpowers:subagent-driven-development (recommended) or
> superpowers:executing-plans to implement this plan task-by-task. Steps use
> checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make a WebDAV 412 say what is actually known about it, and spend one
bounded run on the gated case the old wording misled.

**Architecture:** `WebDAVFileSystem.mapStatus(_:path:method:)` already takes
the HTTP method and ignores it in its `412` arm, so a GET's 412 and a MOVE's
412 get the same sentence about a destination. Task 1 renames the finding to
one whose text the code can support; Task 2 makes the arm read `method`;
Task 3 is one measured attempt at `fullCRUDRoundTripOverBasic` with a stop
condition fixed in advance; Task 4 closes the record.

**Tech Stack:** Swift 6 (`swiftLanguageMode(.v6)`), SwiftPM, Swift Testing,
macOS 15 minimum. Spec:
`docs/superpowers/specs/2026-10-01-webdav-412-complex-design.md`.

**Worktree:** `/Users/noidee/macSCP/.claude/worktrees/webdav-412`, branch
`webdav-412`, base `develop` at `24e6db21`. Run everything from the worktree.
Never `cd` to `/Users/noidee/macSCP` — Task 3 is the single exception, and it
says so explicitly.

## Global Constraints

- **Build and test:** `swift test --build-system native`. The default build
  system fails on SwiftTerm's `Shaders.metal`.
- **Code and comments: English only.** No German in source files.
- **Four catalogues, always together:** `en` (the source text every other is
  measured against), `de`, `fr`, `pl`, under
  `Sources/macSCPCore/Resources/<locale>.lproj/Localizable.strings`. The
  German catalogue addresses the user as **du**.
- **No `default:`** in any switch over `RemoteFSFinding` or its `Name`.
- **A finding carries no server-written text and no endpoint.** Apache's free
  text stays out; that has been the rule since 2026-09-28.
- **No wall-clock ceiling in a test.** No blocking waits
  (`syncShutdownGracefully`, `futureResult.wait()`, `DispatchSemaphore.wait()`)
  — every wait is an `await`. No `#require` on a non-optional.
- `MAX_WARNINGS` is 0 on CI. No `_ =` to silence a warning.
- **A number travels with the command that produced it** (`CLAUDE.md`, added
  2026-10-01): write the command beside the figure, it must run in the form it
  is committed, and run it again after writing the sentence.
- **Prefer a symbol to a line number** in any comment or row you write.
- **Every scripted replacement asserts its anchor before writing.**
- **Never `git checkout -- <path>`** to undo a probe — it restores from the
  index and takes other uncommitted edits with it.
- Conventional Commits, English. **Trailer on every commit:**
  `Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>`
- **Do not push.** The coordinator pushes after the whole-branch review.
- **Do not launch the GUI or the app binary.**

**The known red:** the suite carries exactly one pre-existing failure,
`"Varying only isRegex leaves the pixels unchanged"` at
`ViewTestabilitySpike.swift:202`, an expired platform measurement recorded in
`docs/BACKLOG.md`. At the base commit the suite is **6631 tests in 569
suites** with that one issue. Any other failure is yours.

---

## File structure

| File | Responsibility | Task |
|---|---|---|
| `Sources/macSCPCore/RemoteFS/RemoteFSFinding.swift` | the renamed case and its seven arms | 1 |
| `Sources/macSCPCore/Resources/{en,de,fr,pl}.lproj/Localizable.strings` | the four replacement sentences | 1 |
| `Tests/macSCPCoreTests/RemoteFSFindingTests.swift` | the type's own switches follow the rename | 1 |
| `Sources/macSCPCore/WebDAV/WebDAVFileSystem.swift` | the `412` arm reads `method` | 2 |
| `Tests/macSCPCoreTests/WebDAVFileSystemTests.swift` | the GET witness, the MOVE case, the new separation test | 2 |
| `Tests/macSCPCoreTests/WebDAVFileSystemWriteTests.swift` | `rename`'s 412 | 2 |
| `docs/BACKLOG.md` | the measurement record: Task 3's result, then two rows closed | 3, 4 |

---

## Task 1: the finding says what the code can support

Renames `destinationAlreadyExists` to `movePreconditionFailed` and rewrites
its four sentences. **No behaviour changes here** — the arm still throws this
finding for every 412; Task 2 is what makes it depend on the method.

**Files:**
- Modify: `Sources/macSCPCore/RemoteFS/RemoteFSFinding.swift` (seven places)
- Modify: `Sources/macSCPCore/Resources/en.lproj/Localizable.strings`
- Modify: `Sources/macSCPCore/Resources/de.lproj/Localizable.strings`
- Modify: `Sources/macSCPCore/Resources/fr.lproj/Localizable.strings`
- Modify: `Sources/macSCPCore/Resources/pl.lproj/Localizable.strings`
- Modify: `Sources/macSCPCore/WebDAV/WebDAVFileSystem.swift` (the arm's case
  name only — its logic is Task 2's)
- Modify: `Tests/macSCPCoreTests/RemoteFSFindingTests.swift`
- Modify: `Tests/macSCPCoreTests/WebDAVFileSystemTests.swift`
- Modify: `Tests/macSCPCoreTests/WebDAVFileSystemWriteTests.swift`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `RemoteFSFinding.movePreconditionFailed` (no payload) and the
  catalogue key `core.finding.movePreconditionFailed`. Task 2 throws it.

**Background.** The catalogue key is **derived** from the case name by
`messageKey(for:)`, so renaming the case moves its key — the old key must be
removed from all four catalogues and the new one added, or
`LocalizationParityTests.everyRemoteFSFindingHasItsOwnSentence` goes red for
a missing sentence. A second guard,
`RemoteFSFindingTests.everyLogSentenceMatchesItsEnglishCatalogueEntry`
(added 2026-10-01), requires `logSentence` to equal the `en` entry with only
the **first character's case** allowed to differ. Both reds are the point of
step 2 below.

Counted 2026-10-02 with
`grep -c destinationAlreadyExists Sources/macSCPCore/RemoteFS/RemoteFSFinding.swift`:
**7** places in that file.

- [ ] **Step 1: Rename the case everywhere except the catalogues**

In `Sources/macSCPCore/RemoteFS/RemoteFSFinding.swift`, rename the case and
all six other mentions. Replace the case's own doc comment, which currently
describes a destination conflict, with one the new name earns:

```swift
    /// A `MOVE` was refused because a precondition failed, and the status
    /// alone does not say which one. `Overwrite: F` makes RFC 4918's
    /// destination-exists case live, and mod_dav answers a failed precondition
    /// on the SOURCE with the same 412 — its free text distinguishes them and
    /// is a foreign string this project does not carry into a finding. So the
    /// sentence names both ends rather than asserting one.
    case movePreconditionFailed
```

and the `logSentence` arm:

```swift
        case .movePreconditionFailed:
            return "the server refused the move: either something is already "
                + "at the new name, or the item is locked on the server"
```

`messageKey(for:)`: the new name joins the **specifier-free** list (it carries
no payload). `message`: it joins the **unformatted** list.
`readsAsConnectionFailure`: it joins the **`false`** list — a refused
precondition is a fact about the server's state, which a retry would meet
again.

Then rename the mentions in the three test files and in
`WebDAVFileSystem.swift`'s `412` arm. Use a scripted replacement with an
asserted anchor rather than an editor sweep, and do **not** touch the four
catalogues yet — the next step needs them stale.

- [ ] **Step 2: Run the two guards and watch them go red**

Run: `swift test --build-system native --filter "LocalizationParityTests|RemoteFSFindingTests"`

Expected: **FAIL**, and record both messages verbatim — this is the step that
proves yesterday's two guards catch a missing and a mismatched sentence
rather than merely existing:

1. `everyRemoteFSFindingHasItsOwnSentence` names
   `core.finding.movePreconditionFailed` as missing from each of the four
   catalogues.
2. `everyLogSentenceMatchesItsEnglishCatalogueEntry` fails for
   `movePreconditionFailed`, because `#require(catalogue[key])` finds no entry.

If either passes at this point, stop and report it: a guard that does not
notice a finding with no sentence is a defect in the guard, and it is more
important than this task.

- [ ] **Step 3: Write the four sentences**

Replace the `destinationAlreadyExists` line in each catalogue, in place, so
the new entry keeps its neighbours:

`en.lproj/Localizable.strings`:

```
"core.finding.movePreconditionFailed" = "The server refused the move: either something is already at the new name, or the item is locked on the server";
```

`de.lproj` — the sentence addresses nobody, so there is no pronoun for the
*du* rule to apply to, exactly as its `listingUnparsable` sibling:

```
"core.finding.movePreconditionFailed" = "Der Server hat das Verschieben abgelehnt: entweder liegt unter dem neuen Namen schon etwas, oder der Eintrag ist auf dem Server gesperrt";
```

`fr.lproj`:

```
"core.finding.movePreconditionFailed" = "Le serveur a refusé le déplacement : soit quelque chose se trouve déjà sous le nouveau nom, soit l'élément est verrouillé sur le serveur";
```

`pl.lproj`:

```
"core.finding.movePreconditionFailed" = "Serwer odmówił przeniesienia: albo pod nową nazwą już coś jest, albo element jest zablokowany na serwerze";
```

- [ ] **Step 4: Run the guards green, then the whole suite**

Run: `swift test --build-system native --filter "LocalizationParityTests|RemoteFSFindingTests"`
Expected: PASS. If `everyLogSentenceMatchesItsEnglishCatalogueEntry` still
fails, the `logSentence` and the `en` entry differ by more than the first
character's case — fix the texts, not the guard.

Then: `swift test --build-system native`
Expected: PASS except the one known `ViewTestabilitySpike` failure. The
finding count is unchanged at 18 — count it rather than assuming, with this
exact command, which needs no adjusting:

```bash
grep -c '^"core\.finding\.' Sources/macSCPCore/Resources/en.lproj/Localizable.strings
```

It reads the catalogue rather than the enum because the enum declares its
cases in grouped lines and a line count would not be the case count. Run it
against all four catalogues and report all four numbers.

- [ ] **Step 5: Commit**

```bash
git add Sources/macSCPCore/RemoteFS/RemoteFSFinding.swift \
        Sources/macSCPCore/Resources/en.lproj/Localizable.strings \
        Sources/macSCPCore/Resources/de.lproj/Localizable.strings \
        Sources/macSCPCore/Resources/fr.lproj/Localizable.strings \
        Sources/macSCPCore/Resources/pl.lproj/Localizable.strings \
        Sources/macSCPCore/WebDAV/WebDAVFileSystem.swift \
        Tests/macSCPCoreTests/RemoteFSFindingTests.swift \
        Tests/macSCPCoreTests/WebDAVFileSystemTests.swift \
        Tests/macSCPCoreTests/WebDAVFileSystemWriteTests.swift
git commit -F - <<'MSG'
refactor(webdav): a 412 finding that does not pick an end it cannot see

destinationAlreadyExists asserted which end of a MOVE failed. The status
cannot carry that: rename sends Overwrite: F, so RFC 4918's
destination-exists case is live, and mod_dav answers a failed precondition on
the SOURCE with the same 412. Apache's free text separates them and is a
foreign string this project does not carry into a finding.

Renamed to movePreconditionFailed, whose four sentences name both ends. The
key is derived from the case name, so the rename moved it; the old key is gone
from all four catalogues. Exactly one site throws this finding, so nothing
else had to change with it.

No behaviour change: the arm still throws it for every 412. Which method asked
is the next commit's subject.

Observed red first, and it is the two guards from 2026-10-01 doing their job:
with the case renamed and the catalogues untouched,
everyRemoteFSFindingHasItsOwnSentence named the missing key in all four
catalogues and everyLogSentenceMatchesItsEnglishCatalogueEntry failed on the
absent entry.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
MSG
```

---

## Task 2: the arm reads the method

**Files:**
- Modify: `Sources/macSCPCore/WebDAV/WebDAVFileSystem.swift`, the `412` arm of
  `mapStatus(_:path:method:)`
- Modify: `Tests/macSCPCoreTests/WebDAVFileSystemTests.swift`
- Modify: `Tests/macSCPCoreTests/WebDAVFileSystemWriteTests.swift`

**Interfaces:**
- Consumes: `RemoteFSFinding.movePreconditionFailed` from Task 1.
- Produces: nothing later tasks consume.

**Background.** Two callers reach the `412` arm. `rename` sends a MOVE with
`Overwrite: F`. `readStream` sends a GET, and when it sends **no** validator
its 412 falls through to `mapStatus` as well — which is why the GET is
currently told about a destination. The resume path's own guarded read takes
the 412 before `mapStatus` sees it **whenever a validator was sent**, and that
behaviour is correct and must not change.

- [ ] **Step 1: Turn the two witnesses red**

`Tests/macSCPCoreTests/WebDAVFileSystemTests.swift` carries two expectations
for the GET case, under a comment that calls the behaviour
"wrong-but-preserved, see docs/BACKLOG.md". Change the expectations to the
right answer and rewrite the comment, which is no longer an apology:

```swift
        // A second positive: each 412 still fell through to `mapStatus`,
        // whose 412 arm reports what is actually known about a read's 412 —
        // the status itself, since nothing was moved and no precondition was
        // sent. A case that threw nothing at all cannot pass the two
        // negatives above by accident.
        #expect(fresh.finding == .unexpectedStatus(code: 412))
        #expect(unvalidatedResume.finding == .unexpectedStatus(code: 412))
```

- [ ] **Step 2: Run them and record the red**

Run: `swift test --build-system native --filter WebDAVFileSystemTests`

Expected: **FAIL** on both expectations, reporting
`.movePreconditionFailed` where `.unexpectedStatus(code: 412)` was expected.
Quote both verbatim in the report — this is the defect of row "An unguarded
WebDAV 412 outside the resume path reads as a MOVE's refusal", caught by its
own witness.

- [ ] **Step 3: Make the arm read the method**

In `Sources/macSCPCore/WebDAV/WebDAVFileSystem.swift`, replace the `412` arm
and the long comment above it — that comment records the defect being fixed
and must go rather than contradict the code:

```swift
        // A 412 means different things to the two callers that reach this
        // arm, and only the method tells them apart. `rename` sends a MOVE
        // with `Overwrite: F`, where a precondition really did fail — on the
        // destination or, as mod_dav answers identically, on the source.
        // `readStream` sends a GET, and one that sent no validator lands here
        // too; nothing was moved, so a sentence about a move is false for it.
        // The read keeps what is actually known, the status itself.
        //
        // No `COPY` arm: counted 2026-10-02 with
        // `grep -rn 'httpMethod = ' Sources/macSCPCore/WebDAV/`, this backend
        // sends PUT, PROPFIND, OPTIONS, MOVE and GET, and one method it is
        // handed. Widening to a method the app never sends would be a guess.
        case 412 where method == "MOVE":
            throw RemoteFSError.finding(.movePreconditionFailed)
```

Everything else falls through to the existing `default:`, which throws
`.unexpectedStatus(code: status)`.

- [ ] **Step 4: Fix the MOVE-side tests, which now name the wrong thing**

In `Tests/macSCPCoreTests/WebDAVFileSystemTests.swift`, the case named
`aPreconditionFailureReportsAnExistingDestination` no longer describes what it
asserts. Rename it and say what it holds:

```swift
    /// A MOVE's 412 names both ends, because the status cannot say which one
    /// failed — see `RemoteFSFinding.movePreconditionFailed`.
    @Test func aMovesPreconditionFailureNamesBothEnds() {
        #expect(throws: RemoteFSError.finding(.movePreconditionFailed)) {
            try WebDAVFileSystem.mapStatus(412, path: "/a", method: "MOVE")
        }
    }
```

In `Tests/macSCPCoreTests/WebDAVFileSystemWriteTests.swift`, the case named
`renameOn412ReportsDestinationConflict` has the same problem, and its doc
comment asserts "412 is the answer to `Overwrite: F` — the destination
exists", which is the claim this work removes:

```swift
    /// A rename's 412 reports a failed precondition without choosing an end.
    /// Pinning the exact case matters here: `mapStatus` maps 409 to
    /// `.notFound`, and a weaker assertion could not tell the two apart.
    @Test func renameOn412ReportsAFailedPrecondition() async throws {
        let transport = FakeHTTPTransport(replies: [.init(status: 412, body: Data(), headers: [:])])
        let fs = WebDAVFileSystem(config: config, transport: transport)

        await #expect(throws: RemoteFSError.finding(.movePreconditionFailed)) {
            try await fs.rename(from: "/a.txt", to: "/b.txt")
        }
    }
```

- [ ] **Step 5: Add the test that holds the two arms apart**

Nothing yet asserts that the two methods get **different** findings, so a
later edit could collapse them again exactly as they are collapsed today. Add
to `Tests/macSCPCoreTests/WebDAVFileSystemTests.swift`, beside the MOVE case:

```swift
    /// The separation itself, as one case: the same status, two methods, two
    /// findings. Each expectation above pins one side; this pins that the
    /// sides differ, which is the property the `where method ==` clause
    /// exists for and the one a collapse would break.
    @Test func theSameStatusReadsDifferentlyForAMoveAndARead() {
        var moveFinding: RemoteFSFinding?
        var readFinding: RemoteFSFinding?
        do { try WebDAVFileSystem.mapStatus(412, path: "/a", method: "MOVE") } catch {
            if case RemoteFSError.finding(let f) = error { moveFinding = f }
        }
        do { try WebDAVFileSystem.mapStatus(412, path: "/a", method: "GET") } catch {
            if case RemoteFSError.finding(let f) = error { readFinding = f }
        }

        #expect(moveFinding == .movePreconditionFailed)
        #expect(readFinding == .unexpectedStatus(code: 412))
        #expect(moveFinding != readFinding, """
            A MOVE's 412 and a read's 412 must not resolve to the same finding \
            — that collapse is the defect docs/BACKLOG.md recorded.
            """)
    }
```

- [ ] **Step 6: Run the WebDAV suites, then the whole suite**

Run: `swift test --build-system native --filter "WebDAVFileSystemTests|WebDAVFileSystemWriteTests"`
Expected: PASS, including the three renamed cases and the new one.

Then: `swift test --build-system native`
Expected: PASS except the one known `ViewTestabilitySpike` failure. Report the
real counts; the base was 6631 in 569 and this task adds one test.

- [ ] **Step 7: Prove the separation is load-bearing**

Plant the collapse the new test exists to catch — drop the `where` clause so
every 412 is a MOVE's again:

```bash
python3 - <<'PY'
import pathlib
p = pathlib.Path("Sources/macSCPCore/WebDAV/WebDAVFileSystem.swift")
s = p.read_text()
old = '        case 412 where method == "MOVE":'
new = '        case 412:'
assert old in s and s.count(old) == 1, "ANCHOR MISS — do not proceed"
p.write_text(s.replace(old, new))
print("planted")
PY
swift test --build-system native --filter theSameStatusReadsDifferentlyForAMoveAndARead
```

Expected: **FAIL**. Quote it. Then revert with the inverse asserted
replacement and prove the file is unchanged:

```bash
git diff --stat -- Sources/macSCPCore/WebDAV/WebDAVFileSystem.swift
```

will not do here, because the arm is still uncommitted at this point — the
commit is step 8. Take the file's `shasum` **before** planting and again
after reverting, and report both; identical hashes are the proof.

- [ ] **Step 8: Commit**

```bash
git add Sources/macSCPCore/WebDAV/WebDAVFileSystem.swift \
        Tests/macSCPCoreTests/WebDAVFileSystemTests.swift \
        Tests/macSCPCoreTests/WebDAVFileSystemWriteTests.swift
git commit -F - <<'MSG'
fix(webdav): a read's 412 no longer reports a move it never made

mapStatus takes the HTTP method and its 412 arm ignored it, so a GET that
sent no validator was told about a destination conflict. The arm now matches
MOVE for the precondition finding and lets everything else fall through to
unexpectedStatus(code:), which is what is actually known about a read's 412.

No COPY arm: counted while writing it, this backend sends PUT, PROPFIND,
OPTIONS, MOVE and GET.

Red first, from the defect's own witnesses: the two GET expectations in
WebDAVFileSystemTests sat under a comment calling the behaviour
"wrong-but-preserved", and changing them to the right answer turned them red
against .movePreconditionFailed before the arm changed.

Two cases are renamed because their names asserted the removed claim, and a
new case pins that the two methods resolve to DIFFERENT findings — nothing
held that before, so a later edit could collapse them again. Proved by
dropping the `where` clause: the new case went red.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
MSG
```

---

## Task 3: one bounded run at `fullCRUDRoundTripOverBasic`

**Files:**
- Modify: `docs/BACKLOG.md`, the row
  "`fullCRUDRoundTripOverBasic` is not a flake: it is deterministic at
  full-suite load"

**Interfaces:**
- Consumes: Tasks 1 and 2, so the message read during the run no longer points
  at the wrong end.
- Produces: nothing. **This task may close no row, and that is an acceptable
  outcome.**

**What is already known**, from the row, and not to be re-measured: red in 10
of 10 gated runs; green alone, green with its own suite, green with the whole
`WebDAV` family; the test's directory is UUID-unique; the retry hypothesis is
refuted by Apache's access log (113 MOVEs across 113 distinct paths, maximum 1
per path); Apache's error names the source, 25 occurrences, always on the
first rename.

**What this task adds to it:** macSCP sends no `LOCK` and no `If:` header —
counted 2026-10-02 with
`grep -rn -e '"LOCK"' -e 'Lock-Token' -e 'If:' Sources/macSCPCore/WebDAV/`,
zero hits. So a source precondition mod_dav reports as a lock is not one this
app took.

**The stop condition, fixed before the run:** one gated run. If it does not
localise the cause, write what was measured into the row — including the
negative results, which are the row's value — and stop. No second round and no
open search. The row has already consumed one investigation.

- [ ] **Step 1: Start the rig from the MAIN checkout**

The rig's seed mount is relative to the compose file, so it must be started
from `/Users/noidee/macSCP` and **not** from this worktree. This is the one
command in this plan that runs there, and it starts a container rather than
touching the checkout's files:

```bash
cd /Users/noidee/macSCP && docker compose -f docker/test-server/compose.yml up -d
```

Then return to the worktree for everything else.

- [ ] **Step 2: Run the gated case alone first, to confirm it is still green alone**

Run, from the worktree:
`MACSCP_ITEST=1 swift test --build-system native --filter fullCRUDRoundTripOverBasic`

Expected: PASS. The row records 0.168 s alone. If it is red alone, the premise
changed since 2026-09-27 and that is itself the finding — record it and stop.

- [ ] **Step 3: The one gated full run, with Apache's own view captured**

Run, from the worktree, and keep the output:

```bash
MACSCP_ITEST=1 swift test --build-system native 2>&1 | tee /tmp/gated-run.log
```

Immediately afterwards, capture what the server saw:

```bash
docker compose -f /Users/noidee/macSCP/docker/test-server/compose.yml logs --no-color > /tmp/rig-logs.txt
```

Then answer, from those two files only:
1. Did `fullCRUDRoundTripOverBasic` fail in this run?
2. Which MOVE did it fail on, and what did Apache log for that exact request?
3. Does mod_dav's lock database hold anything at that moment? Inspect it
   inside the container rather than guessing from the host.
4. What else was running against the same server in the seconds around it?

- [ ] **Step 4: Write the answer into the row, whatever it is**

Append to the row. If the cause is localised, say it with the evidence. If it
is not, say **that**, and record the negative results — this plan's position
is that a measured negative is worth more than a plausible guess, and the row
already carries one investigation's worth of refuted hypotheses that are its
most useful content.

State explicitly which of the four questions in step 3 you could answer and
which you could not, and name the stop condition as the reason you went no
further.

- [ ] **Step 5: Commit**

```bash
git add docs/BACKLOG.md
git commit -F - <<'MSG'
docs(backlog): one bounded run at the WebDAV 412 case, and what it showed

The row's first investigation was misled by a message that named the
destination for a precondition that failed on the source; Tasks 1 and 2 of
this plan removed that wording, so this run read what the server actually
said.

The run was bounded before it started: one gated run, and if it did not
localise the cause, record what was measured and stop rather than open a
second search.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
MSG
```

---

## Task 4: closeout

**Files:**
- Modify: `docs/BACKLOG.md` — two rows closed
- Report only: the `noix-docs` troubleshooting sentence

**Interfaces:**
- Consumes: Tasks 1–3, by commit hash.
- Produces: nothing.

- [ ] **Step 1: Close the two rows from the diff**

Read `git log --oneline` and `git diff --stat 24e6db21..HEAD` first, and write
each closing sentence from what the diff shows rather than from this plan's
intent.

**Append** to each row, never replacing its text — these rows are an
append-only measurement record:

1. "`WebDAVFileSystem.mapStatus` renders a source-precondition 412 as \"The
   destination already exists\"" — **Done**, with the new finding's name, why
   the sentence names both ends, and that the status cannot resolve the
   ambiguity.
2. "An unguarded WebDAV 412 outside the resume path reads as a MOVE's
   refusal" — **Done**, naming the two witnesses that were red first and what
   a read's 412 now says.

Both rows cite `WebDAVFileSystem.swift` line numbers from when they were
written. Replace those citations with symbol names rather than re-deriving
numbers that have already moved twice in this file.

- [ ] **Step 2: Check the finding count claim anywhere it appears**

The rename kept the count at 18, but **verify** rather than assume, and fix
any row or comment that states a count which this work changed. Run the
command and write it beside any number you touch.

- [ ] **Step 3: Decide the user documentation and report it**

Part A changes a user-visible sentence. The user docs are the separate
repository `/Users/noidee/_dev/noix-docs` (GitHub `NoiXdev/noix-docs`), under
`src/content/docs/macscp/`. Its `reference/troubleshooting.md` already gained
a section on 2026-10-01 for two "could not be read" messages, and its
changelog has an `## Unreleased` entry; this is a third sentence for the same
unreleased batch.

**Read the page and say exactly what you would add and where — but do not
edit that repository in this task.** It is shared with other products and
other sessions, and the coordinator owns that edit. Note that `npm run build`
and `npm run check` must both pass there.

- [ ] **Step 4: Run the whole suite one last time**

Run: `swift test --build-system native`
Expected: PASS except the one known `ViewTestabilitySpike` failure. Report the
counts.

- [ ] **Step 5: Commit**

```bash
git add docs/BACKLOG.md
git commit -F - <<'MSG'
docs(backlog): the two 412 rows, closed by what the diff shows

The sentence a 412 earns no longer picks an end the status cannot see, and a
read's 412 no longer reports a move. Both rows closed from the diff, their
stale line citations replaced by symbols rather than by numbers that have
already moved twice in this file.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
MSG
```

---

## Task 5: the sentence stops enumerating

**Added 2026-10-02, after Task 3.** Task 3 measured the cause of the gated
412 and it is **neither** of the two this plan's own sentence names: Apache
answers 412 because URLSession attaches revalidation headers to the MOVE.
Nothing is at the new name and nothing is locked. The maintainer's ruling:
stop enumerating causes entirely — say what the server did, not why.

That is the same overclaim this plan set out to remove, one enumeration
further on. "Either A or B" is a two-element version of "A", and a third
clause would be the same bug with worse odds.

**Runs BEFORE Task 4**, which is the closeout and must describe the final
state.

**Files:**
- Modify: `Sources/macSCPCore/RemoteFS/RemoteFSFinding.swift` (the case's doc
  comment and its `logSentence` arm)
- Modify: `Sources/macSCPCore/Resources/{en,de,fr,pl}.lproj/Localizable.strings`

**Interfaces:**
- Consumes: `RemoteFSFinding.movePreconditionFailed` from Task 1. **The case
  name does not change** — it was always about a failed precondition and is
  still exactly right. Only its text does.
- Produces: nothing later tasks consume.

- [ ] **Step 1: Change the `en` sentence only, and watch the guard catch it**

Replace the `en` entry, leaving `logSentence` and the other three catalogues
untouched:

```
"core.finding.movePreconditionFailed" = "The server refused the move because a condition it checked first was not met";
```

Run: `swift test --build-system native --filter everyLogSentenceMatchesItsEnglishCatalogueEntry`

Expected: **FAIL**, naming `movePreconditionFailed`, because `logSentence`
still carries the old enumeration. Quote it verbatim — this is the red, and
it is the guard added 2026-10-01 doing the job it was built for.

- [ ] **Step 2: Bring `logSentence` and the other three catalogues with it**

`logSentence`, which must equal the `en` entry with only the first
character's case differing:

```swift
        case .movePreconditionFailed:
            return "the server refused the move because a condition it "
                + "checked first was not met"
```

`de.lproj` — the sentence addresses nobody, so the *du* rule has no pronoun
to apply to:

```
"core.finding.movePreconditionFailed" = "Der Server hat das Verschieben abgelehnt, weil eine Bedingung, die er vorher prüft, nicht erfüllt war";
```

`fr.lproj`:

```
"core.finding.movePreconditionFailed" = "Le serveur a refusé le déplacement parce qu'une condition qu'il vérifie au préalable n'était pas remplie";
```

`pl.lproj`:

```
"core.finding.movePreconditionFailed" = "Serwer odmówił przeniesienia, ponieważ warunek, który sprawdza najpierw, nie został spełniony";
```

- [ ] **Step 3: Rewrite the case's doc comment, which names both ends**

The doc comment currently explains why the sentence names the destination
and the source. That reasoning is now known to be incomplete. Replace it:

```swift
    /// A `MOVE` was refused because a precondition failed, and the status
    /// does not say which one. Three causes are known to produce it here —
    /// `Overwrite: F` meeting an occupied destination, a failed precondition
    /// on the source, and (measured 2026-10-02) a revalidation header
    /// `URLSession` attached to the request without this project asking.
    /// An earlier version of this sentence named the first two and was
    /// falsified by the third, so the text no longer enumerates causes at
    /// all: it says what the server did. Where the cause matters, the
    /// diagnostic log carries the exchange.
    case movePreconditionFailed
```

- [ ] **Step 4: Run the guards, then the whole suite**

Run: `swift test --build-system native --filter "LocalizationParityTests|RemoteFSFindingTests"`
Expected: PASS. If the logSentence guard still fails, the two texts differ by
more than the first character's case — fix the texts, never the guard.

Then: `swift test --build-system native`
Expected: PASS except the one known `ViewTestabilitySpike` failure.

- [ ] **Step 5: Commit**

Stage the finding type and the four catalogues, and use this message:

```
fix(webdav): the 412 sentence stops naming causes it cannot know

Task 1 of this plan replaced a sentence that named one end of a MOVE with
one that named both. Task 3 then measured the actual cause of the gated
case and it is neither: Apache answers 412 because URLSession attaches
revalidation headers to the MOVE, so nothing is at the new name and nothing
is locked.

"Either A or B" is a two-element version of "A". A third clause would be the
same overclaim with worse odds, so the text now says what the server did and
stops there. The case name is unchanged — it was always about a failed
precondition and still is.

Red first, from the guard added 2026-10-01: changing the en entry alone left
logSentence carrying the old enumeration, and
everyLogSentenceMatchesItsEnglishCatalogueEntry named the finding.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
```

---

## Task 6: two rules written down

**Added 2026-10-02.** Both are maintainer decisions taken during this plan's
execution, and both exist so the next contributor does not decide them by
precedent.

**Files:**
- Modify: `CLAUDE.md`

**Interfaces:** none.

- [ ] **Step 1: The commit trailer**

`CLAUDE.md:482` prescribes a footer naming `Claude Fable 5`. Measured
2026-10-02 by listing the `Co-Authored-By` trailer of the last 30 commits on
`develop`: all 30 carry `Claude Opus 5`. The maintainer ruled the file is the
stale one. Change that line to `Claude Opus 5`, then run the same listing
again and confirm the file and the history now agree.

- [ ] **Step 2: The record's correction rule**

The backlog rows were treated as append-only. Task 3's fix round corrected a
row **in place**, quoting the wording it withdrew at every point, and the
maintainer ruled that pattern allowed. Write it into `CLAUDE.md`, beside the
existing records rules, as its own short section:

```markdown
## A correction quotes what it withdraws

Measured 2026-10-02, on the WebDAV 412 row: a round that corrected three
wrong counts, a withdrawn attribution and two over-general sentences did it
**in place** rather than by appending, and quoted the replaced wording at
every point. A reviewer checked every withdrawal and found nothing erased.

The rows in `docs/BACKLOG.md` were treated as append-only until then. The
rule is now the weaker and more useful one: **a row may be corrected in
place, provided every withdrawal quotes the wording it replaces.**
Append-only guarantees that earlier text is untouched; quoting guarantees
that nothing is lost, which is the property that actually protects a
measurement record — and a stack of appendices pointing backwards is harder
to read than one corrected cell that shows its own history.

What this does not license: deleting a measurement because it turned out
inconvenient, or rewording a finding without saying that is what happened. If
a sentence changes meaning, the old meaning is quoted beside the new one.
```

- [ ] **Step 3: Verify both claims the new text makes**

Run the trailer listing from step 1 and confirm it prints one value. Then
read the `docs/BACKLOG.md` 412 row and confirm the count the new section
states for what was corrected matches what is actually there — count it, do
not copy it from this plan.

- [ ] **Step 4: Commit**

Stage `CLAUDE.md` and use this message:

```
docs(claude): the trailer this project actually uses, and how a row is corrected

Two rules the maintainer settled while the WebDAV 412 plan ran.

The footer line prescribed Claude Fable 5 while the last 30 commits on
develop carried Claude Opus 5 without exception. The file was the stale one.

And the backlog rows were treated as append-only until a fix round corrected
one in place, quoting the wording it withdrew at every point. A reviewer
checked each withdrawal and found nothing erased, and raised the rule itself
as a maintainer's call rather than deciding it by precedent. The rule is now
that a row may be corrected in place provided every withdrawal quotes what it
replaces — append-only guarantees earlier text is untouched, quoting
guarantees nothing is lost, and only the second is what protects a
measurement record.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
```

---

## Notes for the coordinator

- **Execution order is 1, 2, 3, 5, 6, 4.** Tasks 5 and 6 were added on
  2026-10-02 after Task 3's measurement and two maintainer decisions; Task 4
  is the closeout and must run last so it describes the final state.
- **Task order is strict for 1 → 2.** Task 2 throws a case Task 1 creates.
  Task 3 depends on both only for the message it reads. Task 4 is last.
- **Task 3 may close no row.** Judge it on whether the run happened, the four
  questions were answered or honestly marked unanswerable, and the stop
  condition was honoured — not on whether a cause was found.
- **Task 3 is the only task that touches the main checkout**, and only to
  start a container.
- **The known red** (`ViewTestabilitySpike`) is not this plan's to fix.
- **The gated suite is slow and shares one Apache.** Do not run Task 3's gated
  run concurrently with anything else that uses the rig.
