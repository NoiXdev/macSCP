# Backlog: unbounded file closes

**Logged:** 2026-08-28, as a side finding of two measurements on
teardown against a frozen peer. **Not a design.** Logged as a read
observation with a known precedent beside it; **partially confirmed by
measurement 2026-09-02** — see below.

## Where this comes from

Two calls were measured that day, and both hung against a silent peer:

- `SFTPClient.close()` in `disconnect()` — fixed with a deadline
  (`7ac7f7e`)
- `CitadelShell.close()` in `terminal.shutdown()` — fixed with a staged
  deadline (`eed1c8a`)

Both had the same shape: an `await` on a response from the other side,
with no ceiling. While recounting the second case, a third family of the
same shape turned up.

## The counted finding

**8 literal `SFTPFile.close()` call sites**, all in
`Sources/macSCPCore/SSH/CitadelFileSystem.swift`, nowhere else under
`Sources/`. None of them is bounded.

The number is ambiguous and is therefore broken down, because an earlier
report stated it without a breakdown: **5** have `SFTPFile` as direct
receiver, the other **3** go through the `SFTPReadHandle` box and all
converge at the same spot.

**Read, not measured:** four of them sit in cancellation and error
branches and one in a path reachable via `cancelAll` step 3 — i.e. on a
teardown path, and before `terminal.shutdown()`. Another sits in a
`deinit` and runs detached: it blocks nobody, but it can leak a task.

**Five further unbounded closes in the same file explicitly do NOT
belong to this**, counted in this pass so the next reader does not
mistake them for a finding: the closes on `jumpAgent`/`targetAgent`.
These are `AgentAuthContext` connections to the local SSH agent over a
Unix socket — they do not talk to the remote side and cannot hang on a
silent peer. They also sit on the connect path, not the teardown path.

## Why this is not "fixed by the same move"

`cancelAll` has since been **measured** and returns —
0.0045 s with an 8 MB download in flight against the frozen peer, three
for three. The one teardown path that runs through these calls therefore
does not hang today.

That is the reason there is an entry here and not a task: the shape is
suspicious, the case is not. Putting a deadline around eight calls, none
of which is demonstrably hanging, would be exactly what was already
reverted this week — the deadline around `cancelAll` caught nothing and
cost a visible behavior change.

## What would need doing if someone takes this on

**Measure first, do not bound it.** A transfer mid-write or mid-read
while the other side goes silent — does the file close return? The rig
can do this (`docker pause`), and the technique is in
`.superpowers/sdd/frozen-peer-measurement.md` and
`.superpowers/sdd/shell-close-measurement.md`.

If it returns, the result belongs here and the entry is closed. If it
does not return, the fix is already built: `BoundedClose` carries the
shape, and `TeardownStage` shows how an abandoned stage becomes visible.

**The trap when measuring**, learned expensively the same day: every
postcondition is read **before** the thaw. One run of this series was
green while the defect was present, because it only queried the state
afterward. This has stood as a rule in `CLAUDE.md` since 2026-08-28.

## Measured 2026-09-02

Full measurement: `.superpowers/sdd/2026-09-02-unbounded-file-closes-measurement/task-1-report.md`.

Setup: a disposable OpenSSH container on its own ports (2226–2229), never
the shared rig's 2222; an 8 MB file uploaded; `docker pause` to freeze the
peer; every postcondition captured before `docker unpause`; a 10 s bound;
three runs per measurement.

**Measured, and confirmed:** `SFTPFile.close()` alone — no request in
flight, no cancellation — hangs against a frozen peer. Opened through
Citadel's `SFTPClient.openFile` exactly as `CitadelFileSystem` does (via
`BoundedSFTPSession`'s passthrough). 6 of 6 runs never returned within the
bound:

| Path | `elapsed` (3 runs) |
|---|---|
| read handle | 10.424879708999999 s / 10.556509084 s / 10.365250416 s |
| write file | 10.6655905 s / 10.600569125 s / 10.564797167 s |

Against a live peer the same close returned in ~1 ms (0.001006042 s read,
0.001760375 s write). This confirms the entry's suspicion for the two
counted sites this measurement covered — `readStream`'s and `write`'s
`catch is CancellationError` closes. **The other six counted sites were
not measured** and stay in the "read, not measured" register above.

**Measured, not part of the counted finding — a separate, new result:** a
cancelled Swift `Task` does not interrupt an in-flight SFTP read or write
against a frozen peer. `SFTPClient.sendRequest`
(`.build/checkouts/Citadel/Sources/Citadel/SFTP/Client/SFTPClient.swift:87-100`)
awaits a bare `EventLoopFuture.get()` with no cancellation handler, and
none of `SFTPFile.read`, `.write`, `.close()` check `Task.isCancelled`
anywhere. 6 of 6 runs:

| Path | `elapsed` (3 runs) |
|---|---|
| read | 10.104154583 s / 10.323723167 s / 10.637901167 s |
| write | 10.129350249999998 s / 10.150931375 s / 10.2078625 s |

A round-1 review caught that the first version of this measurement
conflated the two findings above — read as "the cancellation-branch
`close()` hangs," when in fact the in-flight request ahead of it never
returns, so the `catch is CancellationError` arm (and its `close()`) is
never reached while the peer stays silent. **Consequence for a fix:** a
bounded `close()` alone would not be reached by the `readStream`/`write`
cancellation branches as they exist today — the in-flight request ahead of
it is what does not return first. This is a new, measured finding in its
own right — a transfer cancelled against a dead peer stays stuck until the
peer answers — with its fix direction left open (a deadline/race around
the request itself, or channel-level teardown on cancel; not designed
here).

**What this means for the entry:** "not a confirmed bug" is withdrawn for
`SFTPFile.close()` — two of the eight counted sites are now confirmed to
hang, structurally, not by coincidence. `BoundedClose` is the shape for a
fix. Nothing was committed: four gated tests sit red against these two
real defects in the SDD workspace (two assert `returned == true` for the
close-only sites, turning green once close is bounded; the two
cancellation tests are the separate defect above and will not turn green
from a close-only fix).

## What this is not

- **Withdrawn 2026-09-02 for `SFTPFile.close()`: this is now a confirmed
  bug**, not just a shape similarity — measured hanging in isolation, 6 of
  6 runs, for the two counted sites this measurement covered (`readStream`'s
  and `write`'s cancellation-branch closes). See "Measured 2026-09-02"
  above. The other six counted sites remain unmeasured and the withdrawal
  does not extend to them.
- **No reason to touch `deinit`.** The detached close there is a
  separate question (a leaked task, not a hang) and does not belong in
  the same change.
- No generalization to other backends. S3 and WebDAV run over
  `URLSession`, which manages its own deadlines.

## Fixed 2026-09-02

Three commits, `develop`, not pushed: `a2b98df` (red), `55e6830` (fix),
`17abf12` (review-driven comment fixes). Full record:
`.superpowers/sdd/2026-09-02-bounded-file-closes/task-{1,2}-report.md`.

**Measured, closed:** the two counted sites this entry's own measurement
had confirmed hanging — `readStream`'s and `write`'s cancellation-branch
`SFTPFile.close()` calls, and with them all eight counted call sites,
since the fix is structural and does not distinguish among them (see
below). `SFTPFile.close()` no longer hangs against a frozen peer through
any path this file system uses.

**Assumed, per the plan and unmeasured beyond the two red tests:** the
other six counted sites — recounted against the tree
(`grep -n "closeBounded()" Sources/macSCPCore/SSH/CitadelFileSystem.swift`)
rather than carried forward from the 2026-08-28 count — split as **four
direct** (`write`'s successful-completion close, `write`'s error arm,
`SFTPReadHandle.closeBounded()`'s own body, `SFTPReadHandle.deinit`) and
**two box-routed** (`readStream`'s EOF close, `readStream`'s error arm —
both call `handle.closeBounded()`, not `file.closeBounded()` directly). The two measured sites are `readStream`'s `CancellationError`
arm (box-routed) and `write`'s `CancellationError` arm (direct); an
earlier draft of this paragraph said "five direct plus one further
`SFTPReadHandle` site", which does not match either the original
2026-08-28 breakdown (five direct, three box-routed) or which two sites
the measurement actually covered. All six were "read, not measured" in
this entry and stayed that way — the fix closes them by construction
(the raw `SFTPFile` type is no longer reachable from
`CitadelFileSystem.swift` at all), not because each was independently
measured hanging.

**The type.** `Sources/macSCPCore/SSH/BoundedSFTPSession.swift` gained
`BoundedSFTPFile`: `private let raw: SFTPFile`, `fileprivate init(raw:)`,
no `close()` member at all — `closeBounded()` is the only close, and it
runs on `BoundedClose.run` against the session's own
`static let closeBoundSeconds = 5`, not a new or copied constant.
`BoundedSFTPSession.openFile` returns `BoundedSFTPFile` in place of
Citadel's `SFTPFile`. `final class`, `@unchecked Sendable` (Citadel's
`SFTPFile` is not `Sendable`; the crossing is argued at the declaration,
including — after the review round — the two-tasks-one-object case: an
abandoned `closeBounded()` parked in `sendRequest` while
`SFTPReadHandle.deinit` starts a second close on the same file, safe
because Citadel's `close()` writes `isActive = false` before it sends
anything).

**The compile-error proof, quoted verbatim** (`task-2-report.md`, planted
in `CitadelFileSystem.write`, removed in the same pass, file restored
byte-for-byte):

```
/Users/noidee/macSCP/Sources/macSCPCore/SSH/CitadelFileSystem.swift:804:45: error: cannot convert value of type 'BoundedSFTPFile' to specified type 'SFTPFile'
     |                                             `- error: cannot convert value of type 'BoundedSFTPFile' to specified type 'SFTPFile'
/Users/noidee/macSCP/Sources/macSCPCore/SSH/CitadelFileSystem.swift:806:28: error: value of type 'BoundedSFTPFile' has no member 'close'
     |                            `- error: value of type 'BoundedSFTPFile' has no member 'close'
```

The raw type can no longer be named from a value this file can obtain,
and the type it can obtain has no `close`. Not covered by this proof,
unchanged from the session type's own doc: `client.openSFTP()` is still
reachable in `CitadelFileSystem` (it holds the `SSHClient`), so a fresh
SFTP channel could still be opened and a raw file obtained from it — a
new and different gap, not the old one persisting.

**The eight moved sites**, matching this entry's 2026-08-28 count of
eight (five direct, three through `SFTPReadHandle`). Line numbers are
deliberately not given here: the ones first recorded (from
`task-2-report.md`, pinned at `55e6830`) had already shifted by the very
next commit (`17abf12`), and this project's stated preference for a
number that goes stale in prose is to drop it and keep the description.

| # | Site | Was | Now |
| --- | --- | --- | --- |
| 1 | `readStream`, EOF arm | `try await handle.close()` | `_ = await handle.closeBounded()` |
| 2 | `readStream`, `CancellationError` arm | `try? await handle.close()` | `_ = await handle.closeBounded()` |
| 3 | `readStream`, error arm | `try? await handle.close()` | `_ = await handle.closeBounded()` |
| 4 | `write`, successful completion | `try await file.close()` | `_ = await file.closeBounded()` + a decision comment |
| 5 | `write`, `CancellationError` arm | `try? await file.close()` | `_ = await file.closeBounded()` |
| 6 | `write`, error arm | `try? await file.close()` | `_ = await file.closeBounded()` |
| 7 | `SFTPReadHandle.close()` body | `try await file.close()` | renamed `closeBounded() async -> Bool`, body `await file.closeBounded()` |
| 8 | `SFTPReadHandle.deinit` | `Task { try? await file.close() }` | `Task { _ = await file.closeBounded() }` |

`grep -rnw "SFTPFile" Sources/` now finds `SFTPFile` only inside
`BoundedSFTPSession.swift` (the stored property, the `fileprivate init`,
and prose) and in prose inside `CitadelFileSystem.swift`'s top-of-file
`@preconcurrency` comment. Plain `grep -rn "SFTPFile\b" Sources/` is NOT
that proof: `\b` only requires a word boundary after the match, so it
also matches the `SFTPFile` substring inside `BoundedSFTPFile`. (A first
draft of this sentence carried the two hit counts; they were wrong the day
they were written, and a count that has to be retaken on every read is
not a proof — the `-w` command is.)

**The `deinit`, what changed and what did not.** Forced by the type and
nothing beyond it: the call became
`Task { _ = await file.closeBounded() }` because `close()` no longer
exists on the value the box holds. **The leaked-task question is
unchanged and still open** — nothing awaits that task and nothing
observes its answer. The bound shortens the leak's life from unbounded
to `closeBoundSeconds` (5 s); it does not answer whether the task should
be there at all.

**Green.** `MACSCP_ITEST=1 swift test --filter
"AgainstAStillFrozenPeerReturnsInsideTheBound"`, three consecutive runs
on the final committed code (`task-2-report.md`):

| Run | read-handle `closeBounded` returned after | write-handle `closeBounded` returned after |
| --- | --- | --- |
| 1 | 5.261970542 s | 5.324833667 s |
| 2 | 5.264201708 s | 5.332092958 s |
| 3 | 5.222510875 s | 5.327176750 s |

Against the red's ~10.5 s and `returned == false`, every close now comes
back within 0.34 s of `closeBoundSeconds` (5 s), each reporting `false`
(bound fired, close abandoned — the intended path, not a live answer).

Full unit suite (`swift test`): 3437 tests in 301 suites passed after
9.644 s (task-2's final count, including the added
`FileCloseBoundRelationTests` pin). Full gated suite
(`MACSCP_ITEST=1 swift test`), run once against the fix commit: 3436
tests in 300 suites passed after 85.524 s, no failures, the known
wall-clock flake (`ConnectMainActorLivenessTests`) green without a
re-run. The review-fix commit (`17abf12`) touched only comments and one
new ungated test, so the gated suite was not re-run against it —
argued in `task-2-report.md` as no measured code having changed.

**One more measured consequence, not itself a new number.**
`readStream`'s and `write`'s cancellation and error arms now cost up to
`closeBoundSeconds` (5 s) on the path where they previously never
returned at all against a frozen peer — strictly better, since "up to
5 s" replaces "forever", but it is a cost that did not exist before this
fix and is worth naming rather than leaving for the next person to
rediscover by timing something. It bears on a number already on the
record: `LivenessProbeDropIntegrationTests`' `teardownBoundSeconds`
comment cites `cancelAll` returning in 0.0056 s, three for three,
against this same frozen-peer scenario, and treats that as evidence
`cancelAll` "contributes nothing" to the sum it derives. That 0.0056 s
run is not evidence `cancelAll` is always fast — this entry's own
"Measured, not part of the counted finding" section above records why:
a cancelled `Task` does not interrupt an in-flight SFTP request against
a frozen peer, so a cancellation landing while a request is still
outstanding never reaches the cancellation arm's close at all in that
scenario. The fast number came from the arm never running, not from the
arm running quickly. The next time that lap is measured — with a
cancellation that DOES land after the in-flight request resolves, so the
arm's `closeBounded()` actually executes — expect the bound to show up
in the total, up to 5 s, where the current comment shows none.

**`@preconcurrency import Citadel` — measured still load-bearing, not
assumed.** Removing it from `CitadelFileSystem.swift` fails to build;
first error, quoted verbatim from `task-2-report.md`:

```
/Users/noidee/macSCP/Sources/macSCPCore/SSH/CitadelFileSystem.swift:411:49: error: capture of 'method' with non-Sendable type 'SSHAuthenticationMethod' in a '@Sendable' closure [#SendableClosureCaptures]
```

The annotation was restored; the comment above the import now describes
in prose what it still suppresses (created, jumped through, stored,
closed on every failure arm, handed to child channels, captured by a
detached task) rather than enumerating call sites, after a first attempt
at enumerating them (three names) was itself found short during review
(`17abf12`).

**Parked for the maintainer — an open decision, not a fix.** Two sites,
not one: `write`'s successful-completion close and `readStream`'s EOF
close both used to `try await handle/file.close()`, which throws
(`SFTPError.errorStatus`) on a non-`ok` CLOSE status — the class of
error a server defers to close time, e.g. `ENOSPC`/`EDQUOT` reported only
when the last write is flushed. `closeBounded()` answers only a `Bool`,
so that status is now swallowed at both sites — the upload reports
success, and the read's EOF is treated the same as any other clean EOF.
This is not the same question as an abandoned close: a close abandoned
because the bound fired **is** correctly reported as success/clean-EOF,
because every chunk was individually awaited and acknowledged (write) or
already delivered to the caller (read) before the close was ever
reached — the abandonment says nothing about whether the bytes arrived
or were fully read. The swallowed case is different — a close that
**completed** and came back with a failing status, which today is
indistinguishable from one that came back `ok`. The review's suggested
shape: a three-case outcome on `closeBounded()` (`closed` /
`failed(Error)` / `abandoned`) so both call sites can map `failed` to a
`RemoteFSError`. Its cost, corrected here: this needs NO change to
`BoundedClose` or to `BoundedSFTPSession` — `BoundedClose.run` already
returns whether the bound won, and the operation closure inside
`BoundedSFTPFile.closeBounded()` can capture `raw.close()`'s own
success/failure locally and fold it into a three-case return without
either of those two types changing at all. Only `BoundedSFTPFile`'s
return type and its two call sites would move. An earlier version of
this paragraph said the change "touches `BoundedSFTPSession`/
`BoundedSFTPFile`, which this plan barred changing beyond adding the
file type" — that reason was inaccurate; the actual barrier is simply
that this plan did not ask for it. Left for the maintainer to decide,
not implemented here.

**The cancellation finding stays open, unchanged.** Measured 2026-09-02
above: a cancelled Swift `Task` does not interrupt an in-flight SFTP
read or write against a frozen peer, because `SFTPClient.sendRequest`
awaits a bare `EventLoopFuture.get()` with no cancellation handler and
none of `SFTPFile.read`/`.write`/`.close()` check `Task.isCancelled`.
This fix does not touch it — a bounded `close()` is never reached by the
`readStream`/`write` cancellation branches while the in-flight request
ahead of it stays stuck. Its two tests remain uncommitted, sitting red in
`.superpowers/sdd/2026-09-02-unbounded-file-closes-measurement/red-tests-round2.patch`;
its fix direction (a deadline/race around the request itself, or
channel-level teardown on cancel) is still undesigned.
