# M31 — Logging ad-hoc connections (design)

Status 2026-08-19. From the M27 backlog, never commissioned.

## The finding, measured

The entire store-and-log block in the submit path hangs off one
condition: `if form.shouldSaveSession { … }` (`ContentView`). If the
save toggle is off, no `StoredSession` is created, therefore no
`AuditRecorder` — and therefore **not a single entry**: no `connected`,
no transfers, no `disconnected`.

The fourth missing entry is the serious one: `attachAuditRecorder` also
writes the **M21 plaintext note** (`plaintextConfirmed`, "connected
without TLS after an explicit confirmation"). It is missing precisely
when the connection is not saved. Remeasured in the source, not taken
from the comment.

**The actual defect is the nesting.** Logging sits inside saving. The log
therefore does not depend on whether a connection happens, but on whether
it is saved.

## The decision

Maintainer decision 2026-08-19: log ad-hoc connections under **one fixed
pseudo-session**, readable in the existing audit sheet, retained like any
other log.

Rejected: a separate ID per connection (would need a list through which
to find these logs at all — otherwise writing without reading, exactly
the gap M27 named), only the plaintext note, and closing the point as a
non-finding.

## The design

**Un-nesting.** Attaching the recorder moves out of the save branch:
with `stored.id` if it was saved, otherwise with the ad-hoc ID. The
plaintext note thereby comes along automatically, because it sits inside
`attachAuditRecorder`.

**The pseudo-session.** A constant in Core with a fixed UUID, so every
unsaved connection writes into *the same* log. It is a value, not a
record: no entry in `sessions.json`, no sidebar row, nothing that can be
connected to, renamed, deleted, or exported.

**Readability.** An entry in the Sessions menu opens the existing
`AuditLogSheet` with a synthetic `StoredSession` built from this ID and a
localized name. The menu already lists Known Hosts, server certificates,
logins, and SSH keys — checked, the pattern for app-wide sheets exists
and is simply continued. The sheet itself does not change.

**Distinguishability.** All ad-hoc connections share one log. That works
because `recordConnected(summary:)` already writes host and user into the
detail text today; the rows stay distinguishable without new machinery.

**Retention** as for any other session. The sheet's delete button with
confirmation applies unchanged.

## Testability

The attaching sits in `ContentView`, i.e. in the untested part of the app
layer. Following the M29 pattern, it is therefore not the call that
moves out but the **decision**: "under which session ID does this
connect get logged?" — saved session → its ID, otherwise the ad-hoc ID —
into a small, tested type.

Both directions get a test. This satisfies the **constant-return probe**:
a function that always returns the ad-hoc ID makes the first test red; one
that always returns the session ID makes the second test red. Plus a
test that the ad-hoc ID is **stable** across calls — otherwise the one log
would fall apart into many unreachable ones.

## What does not belong here

- No global audit view. That stays deliberately out (M27), and this
  design does not need it: it uses the existing session view.
- No change to `AuditLogSheet`, `AuditRecorder`, or `AuditLogStore`.
- No setting to turn logging off. An option that disables logging would
  itself be a security-relevant decision and would belong, if at all, in
  its own round.
