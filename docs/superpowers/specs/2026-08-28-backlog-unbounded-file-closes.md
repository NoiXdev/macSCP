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
