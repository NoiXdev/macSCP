# M32 — Partial successes that delete anyway (design)

Status 2026-08-19. From the inherited backlog, rescoped after a
measurement.

## The measurement that determined the scope

The backlog listed five technical points. Remeasured against the branch:

| Point | Status |
|---|---|
| `applyMerge` reads with `try?` and deletes anyway | **done** in M28/T2 — the read throws, with a detailed justification in the code. The note was stale. |
| Jump binding, same construction | **not found** — the binding sites write with `try`, not `try?` |
| `applyMerge` rewire loop | **real**, see below |
| Orphans from key generation | **done** — the `catch` around `store.add` removes both files and rethrows the original error. When this spec was first written, this was wrongly carried as open, because only the order of calls was read, not their `catch`. |
| Test suite hang | not solvable on demand (280 runs without reproduction); tooling is in place |

A backlog entry is the same case as a comment: a claim with an expiry
date. **Three of five had expired** — the third one was only noticed
while writing the plan, after this very spec had already carried it as
open. So the lesson applies to this spec itself too: reading a sequence
of calls is not a measurement as long as the `catch` beside it stays
unread.

## The one real finding

### `applyMerge` — costs a credential

```swift
for session in groupSessions {
    var updated = session
    updated.loginSetID = set.id
    try? store.upsert(updated)
    try? secrets.deletePassword(for: session.id)
}
```

If the store write fails, the session keeps `loginSetID == nil` — so it
still fetches its secret from its own slot — and that very slot gets
deleted in the same iteration. The session ends up with no credential at
all.

This is documented as behavior, not as a finding: the doc comment says,
verbatim, "both are `try?`, so a store-write failure for one session does
not stop that session's secret from being deleted." It had been seen and
accepted.

## The rule

**A step that takes something away runs only if the step that creates its
replacement has demonstrably succeeded.**

- **`applyMerge`:** `try? store.upsert` becomes `do/catch`. If the write
  fails, this session's slot is **not** deleted; it keeps its secret and
  its non-binding, and thereby stays functional. The loop keeps running
  for the remaining members — a failure on one member must not drag the
  others down with it —, and at the end a message states that sessions
  were not rebound and kept their own password. **Without a count:**
  plurals need `.stringsdict`, which exists only in `MacSCPAppKit`, while
  this message lives in Core's catalog — a count here would mean plural
  infrastructure for one sentence. The return value stays the created
  set: it exists, and the members that succeeded point to it.
Key generation already satisfies this rule and stays untouched; its
`catch` is the pattern `applyMerge` follows.

## Tests

**`applyMerge`.** The failure is not simulated, it is **produced**: the
session directory is set read-only so `upsert` genuinely fails. No test
seam that would exist only for this test — and the test thereby also
proves that an unwritable directory actually leads to an error, instead
of assuming it.

- On a failed write, the session keeps its secret.
- **Positive control:** without the write protection, the secret does
  get deleted and the session does point to the set. Without this second
  test, the first would stay green even if `applyMerge` deleted nothing
  at all anymore.

## What does not belong here

- **Damage 1 from M30** — the own slot of a session that **is** bound to
  a set. Different construction: no failure is involved, it is a cleanup
  question. Its own pass.
- **The app-wide audit surface.** After M31 the ad-hoc half is solved;
  the rest is a deliberate non-decision (M27), not a defect.
- **The test suite hang.** Stays defused and documented.
