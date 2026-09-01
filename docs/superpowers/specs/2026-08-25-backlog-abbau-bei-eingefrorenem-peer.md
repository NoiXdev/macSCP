# Backlog: Teardown against a frozen peer

**Created:** 2026-08-25, from a self-report in Task 10 of the
connection-state work. Small, but the gap sits in an uncomfortable
spot.

## The finding

The integration test freezes the peer (`docker pause`): the sockets
remain, sshd never answers. The probe correctly detects this after two
seven-second deadlines, measured at 14.1–14.9 s.

**The test thaws before the teardown run — on purpose.** Because
`disconnect()` calls `try? await sftp.close()`, and whether this call
**terminates** against a peer that never answers is open.

Against a *killed* container the full teardown runs through and finishes
in milliseconds. Only the frozen case is unverified.

## Why it matters

If `disconnect()` hangs there, `teardown` hangs — and with it the path
through which `handleLivenessGiveUp` writes the `.lost` state in the
first place. Detection would then be correct and the response would
still not happen.

The frozen case is also the more realistic one: a network that
disappears rarely kills the socket. It simply stops answering.

## What would need doing

Extend the existing freeze test with a teardown, **without** thawing
first, and measure whether it returns. If it does not return,
`disconnect()` needs the same treatment the probe already has: a deadline
that holds even when the underlying call does not — the pattern already
exists in the tree as `LivenessProbeRace`.

To note: the test must thaw and remove the container in every case,
even if it runs into a deadline. Task 10 solves this via `defer`
and a `docker rm -f`, which also removes a paused container.

---

## Measured and fixed (2026-08-28, `7ac7f7e`)

**The open question is answered, and the answer is "no".** `disconnect()`
does not terminate against a frozen peer.

Measured on the real teardown path: entered, never left — within two
independent bounds of 120 s and 30 s. After `docker unpause`, the same
abandoned call returned in 0.000491834 s. So it was never slow; it
was waiting for a response.

The attribution, on a throwaway rig directly against the Citadel objects:

| Call | returns while the peer is frozen? | measured |
|---|---|---|
| `SFTPClient.close()` | **no** | 20.01678975 s against a 20 s bound |
| `SSHClient.close()` | **yes** | 0.051039125 s |

So exactly one line hangs, and the path around it was open. `try?`
swallows an error; it does not bound a wait.

**The fix:** `BoundedClose` gives this one call a deadline in the
form of `LivenessProbeRace`, outside the main actor, and gives it up
when the deadline wins — which is what lets `client.close()` and
`jumpClient?.close()` run at all. The teardown order is unaffected.

**Five seconds**, backed from both sides: the slowest of ten healthy
`disconnect()` runs against the rig was 0.001507583 s, and the deadline
is spent on top of a detection that already costs 14.1–14.9 s.

| | before | after |
|---|---|---|
| frozen peer | 127.946259083 s, **no** return, tab stays `.degraded` | **5.050603459 s**, tab becomes `.lost`, session `nil` |
| killed container | 0.006492291 s | 0.006294584 s |

The gated test derives its own bound from the production constant,
instead of keeping a second copy of the number.

## Addendum from the same day: the fix only helps without a terminal

**The numbers above are correct and still describe the exceptional case.**
The test that produced them opens no shell — its placeholder opener
throws, which is a deliberate decision from another test and not an
environment gap.

Measured **with an open shell**, three independent runs:

| | with an open shell | control without a shell |
|---|---|---|
| does teardown return? | **no**, ≥30 s (a deadline that does not abort) | yes, 5.340685209 s |
| does `disconnect()` get entered? | **no** | yes |
| Tab | `.degraded`, session stays set | `.lost`, session `nil` |

The only difference is the open terminal. After `docker unpause`, the
abandoned teardown returned in 0.0022 / 0.0017 / 0.0019 s.

**The cause is the ordering.** `teardown` waits on four stages:

```
cancelAll → editManager.stopAll() → terminal.shutdown() → disconnect()
```

The deadline from `7ac7f7e` sits in the **last** one. `CitadelShell.close()`
is `pump.cancel(); await pump.value` — an unbounded wait on a
cancelled task — and it hangs in the third. The deadline is never
reached.

At least two further unbounded wait points sit before it: `cancelAll`
step 3 waits on running transfers, and `editManager.stopAll()` is
not investigated.

**Maintainer decision (2026-08-28): bound each stage individually.**
Not the teardown as a whole — its ordering is an invariant of this
project, and a deadline wrapped around it would abort mid-sequence and
not say which stage hung.

**A lesson from the measuring itself, unrelated to SSH:** the
first run was **green while the defect was present**. Its postconditions
read `enteredAt` and `liveness` only **after** the thaw block — that is,
after the peer answered again and teardown had caught up. A check
that reads after the healing is not a check.

## What remains open — and a question for the maintainer

**Ungated, nothing holds the wiring in place.** That `BoundedClose` does
the right thing is verified ungated. That `disconnect()` *uses* it is
held only by the gated integration test. A regression to
`try? await sftp.close()` would stay green in a CI without Docker.

A source-scanning guard was **deliberately not** built: it would have
to spell two names it cannot derive — exactly the kind `CLAUDE.md`
warns about under "Guards that name what they watch". The question was
therefore not "which guard" but whether the unbound call can be
excluded **structurally**, as was done for connecting.

**Answered and built (2026-08-28, `c71a7c3`): yes.** `BoundedSFTPSession`
keeps the raw client `private`, has a `private init` and a
`closeBounded()` **with no arguments**; the deadline is a property of
the type. Nine forwards carry the remaining operations. **Zero
test changes**, because `init` was already `private` and no test
names `SFTPClient`.

Six violations planted, all red — including the one a reader would
actually write who "just needs the raw client":

```swift
extension BoundedSFTPSession { var unbounded: SFTPClient { raw } }
// error: 'raw' is inaccessible due to 'private' protection level
```

That this fails depends on `private` rather than `fileprivate` — the
reason the type must live in its own file. As a control, the gap was
confirmed at the prior state: there, `try? await sftp.close()` compiles.

**What the boundary does not prevent**, both executed and documented in
the type: deleting the close call **entirely** compiles, and
`try? await client.openSFTP().close()` also compiles — a fresh
channel, the stored session untouched (and because `openSFTP()` itself
is a round trip, it would bring back the same hang). It enforces the
**how**, never the **whether**. A source-scanning guard deliberately does
*not* sit beside it: one placed next to a structural guarantee would
give the suite's next reader more confidence than it has earned.

Further named boundaries: the five seconds are sized against loopback;
`client.close()` was only measured fast in *this* ordering, with an
abandoned `sftp.close()` still in flight; and `docker pause` is a model
of a vanished network, not the network itself.
