# The WebDAV 412 complex — design

**Status:** approved by the maintainer 2026-10-01, both parts.

**Base:** `develop` at `ba924413`. Every citation and count below was measured
at that commit on 2026-10-01 with the command written beside it, per
`CLAUDE.md`, "A number travels with the command that produced it".

Closes two `docs/BACKLOG.md` rows and makes one bounded attempt at a third:

1. "`WebDAVFileSystem.mapStatus` renders a source-precondition 412 as
   \"The destination already exists\"" (open, recorded 2026-09-27)
2. "An unguarded WebDAV 412 outside the resume path reads as a MOVE's
   refusal" (open, recorded 2026-09-24)
3. "`fullCRUDRoundTripOverBasic` is not a flake: it is deterministic at
   full-suite load" (open, recorded 2026-09-27) — **Part B, bounded**

---

## What was measured first

### The defect is one ignored parameter

`WebDAVFileSystem.mapStatus(_:path:method:)` is declared at
`Sources/macSCPCore/WebDAV/WebDAVFileSystem.swift:674` and **takes the HTTP
method**. Its `412` arm (`:693`) ignores it and throws
`RemoteFSError.finding(.destinationAlreadyExists)` for every caller. Two
callers reach it with two different meanings:

| caller | what a 412 means there | today's sentence |
|---|---|---|
| `rename`, a MOVE | ambiguous — see below | "The destination already exists" |
| `readStream`, a GET with no precondition sent | nothing about a destination | the same sentence |

### A MOVE's 412 is genuinely ambiguous, and the code cannot resolve it

`rename(from:to:)` sends `Overwrite: F`
(`WebDAVFileSystem.swift`, read 2026-10-01), so RFC 4918's
destination-exists case is live. But mod_dav answers the **source**
precondition with the same status: the row for item 3 records Apache's own
line, `Could not MOVE …/note.txt due to a failed precondition on the source
(e.g. locks). [412, #0]`, 25 occurrences in one gated run.

Nothing in the status line distinguishes them. Apache's free text does, and
that text is a foreign string this project decided on 2026-09-28 not to
carry into a finding. **So the honest sentence names both possibilities**;
asserting either one is a claim the code cannot support.

### The replacement is free of collateral damage

Counted 2026-10-01 with
`grep -rn destinationAlreadyExists Sources/ Tests/`: the finding has
**exactly one thrower**, the 412 arm itself. Everything else is the type's
own switches (`RemoteFSFinding.swift`, seven places), the four catalogues,
and three test sites. Replacing the case is therefore a swap, not an
addition — **the finding count stays at 18**, and four catalogue sentences
are rewritten rather than four new ones added.

### macSCP never takes a lock

Counted 2026-10-01 with
`grep -rn -e '"LOCK"' -e 'Lock-Token' -e 'If:' Sources/macSCPCore/WebDAV/`:
**zero hits**. macSCP sends no `LOCK` and no `If:` header, so a source
precondition mod_dav reports as a lock is not one this app took. That is a
fact Part B starts from and the first investigation did not have.

### No COPY exists to generalise for

Counted 2026-10-01 with `grep -rn 'httpMethod = ' Sources/macSCPCore/WebDAV/`:
the backend sends `PUT`, `PROPFIND`, `OPTIONS`, `MOVE`, `GET` and one
dynamic `method`. **No `COPY`.** The new arm therefore matches `MOVE` only;
widening it to a method the app never sends would be a guess dressed as
generality.

---

## Part A — the 412 arm learns which method asked

### The arm

```swift
case 412 where method == "MOVE":
    throw RemoteFSError.finding(.movePreconditionFailed)
```

Everything else falls through to the existing `default:`, which throws
`.unexpectedStatus(code: status)` — "the server answered with status 412".
That is exactly what is known about a 412 from a GET, and it costs no new
catalogue entry.

### The finding

`destinationAlreadyExists` is **renamed** to `movePreconditionFailed`. The
catalogue key is derived from the case name (`messageKey(for:)`), so the
rename carries the key with it; the old key is removed with the old name.
The case takes no payload, so it joins the specifier-free list in
`messageKey(for:)` and the unformatted list in `message`.

`readsAsConnectionFailure` answers **`false`**: a refused precondition is a
fact about the server's state, which a retry would meet again.

### The four sentences

`en` is the source text, and `logSentence` is it with the first character
lower-cased — the relation
`RemoteFSFindingTests.everyLogSentenceMatchesItsEnglishCatalogueEntry`
enforces since 2026-10-01.

| locale | sentence |
|---|---|
| `en` | The server refused the move: either something is already at the new name, or the item is locked on the server |
| `de` | Der Server hat das Verschieben abgelehnt: entweder liegt unter dem neuen Namen schon etwas, oder der Eintrag ist auf dem Server gesperrt |
| `fr` | Le serveur a refusé le déplacement : soit quelque chose se trouve déjà sous le nouveau nom, soit l'élément est verrouillé sur le serveur |
| `pl` | Serwer odmówił przeniesienia: albo pod nową nazwą już coś jest, albo element jest zablokowany na serwerze |

`logSentence`: `the server refused the move: either something is already at
the new name, or the item is locked on the server`

The German sentence addresses nobody, so the catalogue's *du* rule has no
pronoun to apply to, exactly as its `listingUnparsable` sibling does.

### The three tests that pin today's behaviour, and which become the red

All three change, and two of them are the defect's own witnesses:

| site | today | after |
|---|---|---|
| `WebDAVFileSystemTests.swift:630`, `aPreconditionFailureReportsAnExistingDestination` | expects `.destinationAlreadyExists` from `mapStatus(412, method: "MOVE")` | expects `.movePreconditionFailed`; the name becomes `aMovesPreconditionFailureNamesBothEnds` |
| `WebDAVFileSystemWriteTests.swift:371`, `renameOn412ReportsDestinationConflict` | expects `.destinationAlreadyExists` from a real `rename` | expects `.movePreconditionFailed`; renamed to match |
| `WebDAVFileSystemTests.swift:326-327` | expects `.destinationAlreadyExists` for a **GET**, under a comment reading "wrong-but-preserved, see docs/BACKLOG.md" | expects `.unexpectedStatus(code: 412)`, and the comment's apology goes with it |

The third is the closing of row 2. Its two expectations sit beside two
negatives as their positive companion, and that role is unchanged — only the
case they name.

A fourth test is **added**: a GET and a MOVE that both answer 412 produce
**different** findings. Without it, nothing holds the two arms apart, and a
later edit could collapse them again exactly as they are collapsed today.

---

## Part B — one bounded attempt at `fullCRUDRoundTripOverBasic`

Part A ships first, so the investigation reads a message that no longer
points at the wrong end — which is what the row records as having misled the
first round.

**What is already known**, from the row: red in 10 of 10 gated runs, green
alone, green with its own suite, green with the whole `WebDAV` family; the
directory is UUID-unique; the retry hypothesis is refuted by Apache's access
log (113 MOVEs across 113 distinct paths, maximum 1 per path); the error
names the source, 25 occurrences, always on the first rename.

**What this design adds to it:** macSCP takes no locks (measured above). So
either mod_dav is reporting a lock nobody took, or "precondition on the
source" is standing in for something that is not a lock at all.

**The one run.** Start the rig from the main checkout
(`docker compose -f docker/test-server/compose.yml up -d`), run the gated
suite, and correlate the failing MOVE against Apache's error log and lock
database at the moment it fails — the question being which precondition
mod_dav believes failed, not what macSCP was told.

**The stop condition, fixed in advance:** if that one run does not localise
the cause, write what was measured into the row — including the negative
results, which are the row's value — and stop. No second round, no open
search. The row has already consumed one investigation.

**Part B may close no row, and that is an acceptable outcome.** What it may
not do is end with a guess recorded as a finding.

---

## Out of scope

- Carrying Apache's free text into a finding. Foreign error text has been out
  of scope since 2026-09-28 and this design does not reopen it.
- A `COPY` arm — the backend sends no `COPY` (measured above).
- The resume path's own guarded 412 at `readStream`, which takes its 412
  before `mapStatus` sees it whenever a validator was sent; that behaviour is
  correct and unchanged.
- Any change to `directoryAlreadyExists`, which is MKCOL's answer and a
  different condition.

## Testing

Red before green at every step, and the two witnesses above make the red
real rather than a compile error: they assert the **wrong** finding today, so
they fail on the value when the arm changes.

The project's standing rules bind as usual — no `default:` in a switch over
`RemoteFSFinding` or its `Name`, no wall-clock ceiling, no blocking wait,
`MAX_WARNINGS` 0, and every number written into a comment counted in that
moment with its command.

The suite at the base commit is 6631 tests in 569 suites with exactly one
known failure, `ViewTestabilitySpike`'s pixel comparison on macOS 27.

## User documentation

Part A changes a user-visible sentence, so
`src/content/docs/macscp/reference/troubleshooting.md` in the separate
`noix-docs` repository gains the new wording. That page already has a
section added on 2026-10-01 for the two "could not be read" messages and an
`## Unreleased` entry in its changelog; this is a third sentence for the
same unreleased batch, not a new convention.
