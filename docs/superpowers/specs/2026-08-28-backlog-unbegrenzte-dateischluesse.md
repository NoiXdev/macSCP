# Backlog: unbounded file closes

**Logged:** 2026-08-28, as a side finding of two measurements on
teardown against a frozen peer. **Not a design, and explicitly not a
measured bug** — a read observation with a known precedent beside it.

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

## What this is not

- **Not a confirmed bug.** Nobody has seen a hanging file close; it is a
  shape similarity to two cases that did hang.
- **No reason to touch `deinit`.** The detached close there is a
  separate question (a leaked task, not a hang) and does not belong in
  the same change.
- No generalization to other backends. S3 and WebDAV run over
  `URLSession`, which manages its own deadlines.
