# M26 — The blockless SSH record (design)

**As of:** 2026-08-08. Predecessor: M25 (`2026-08-08-m25-closeout.md`),
whose wrap-up posed the question this milestone answers.

## Goal

`StoredSession.host`/`port`/`username`/`authKind` return the fallback
values `""`/`22`/`""`/`.password` for a session without an SSH block. M25
showed that **no reader is unprotected any more** — but also that deletion
is only possible once **zero mentions** remain, and there are fifteen in
production code. The blocker was never technical, it was an open question:

> What should a `.ssh` session whose block is missing from the file do?

**Maintainer decision 2026-08-08: discard it on load.**

After that, `.ssh` ⇒ `ssh != nil` holds in practice, the fifteen readers
can switch to `guard let ssh`, and the four accessors go away.

## How the state arises at all

`StoredSession.init(from:)` reads the block with `decodeIfPresent`
(`StoredSession.swift:130`). That is deliberate and stays so: M23
established that **one broken entry must not fail the whole file**. The
app itself cannot produce this state — every save path writes the block.
It is only reachable through a hand-edited or corrupted `sessions-v2.json`.

## The three changes

### 1. Discard on load

`SessionStore.load()` already sweeps through one hygiene rule today: a
`groupID` whose group no longer exists is set to `nil`
(`SessionStore.swift:70-76`). The second rule joins it there: a record
with `kind == .ssh` and `ssh == nil` is **removed from the loaded list**.

**Without rewriting the file on read.** The next regular save leaves the
entry out anyway; a write on the read path would be a new failure mode for
a problem nobody has, and would change the file without the user doing
anything. Until then, the entry is silently skipped on every launch —
harmless, and more honest than a repair that would have to guess the
missing host.

**The price, stated plainly:** the session disappears from the sidebar
without anyone saying why. It was, however, already unusable before that —
no host, no username, no connecting. A visible notice (audit log) was
considered and dropped: the store today has no recorder, and giving it one
is a bigger change than this milestone is worth.

**Only `.ssh`, not all three protocols — and that is a deliberate
asymmetry.** A blockless `.s3` or `.webdav` record is just as unusable but
is **not** discarded. Two reasons: first, this milestone has a narrowly
scoped goal, namely the four SSH accessors, and the other two protocols
have none at all — they already return the empty bag for a missing block,
so nothing is invented there. Second, the blockless non-SSH case is
already explicitly caught in several places (`hasStoredConfiguration`,
`LoginMergePlanner`, `applyMerge`'s guard from the M25 follow-up), and
discarding on load would make these guards unreachable without removing
them — guards that would then merely assert something nobody can verify
any more.

Whoever extends the rule to all protocols later has to touch these guards
too. That is its own pass, not a side clause here.

### 2. The fifteen readers get `guard let ssh`

| Location | Readers | Behavior on a missing block |
|---|---|---|
| `LoginResolver.resolveJump` | 6 | throws `.missingJumpSession` |
| `SessionListViewModel.delete` | 5 | skips the restoration |
| `SSHFieldSchema.values(from:)` | 4 | returns the **empty** bag |

On `.missingJumpSession`: this is not the next-best error, it is the
literally correct one. A discarded record, from the reference's point of
view, is simply no longer there — and the `sessions.first(where:)` lookup
already fails before the guard, because the list no longer contains it.
The guard is belt and suspenders, and it says the same thing as the path
in front of it.

On `delete`: the same rule M24 introduced for non-SSH bastions — restore
nothing, leave the reference dangling, fail honestly on the next connect.

On `values(from:)`: the empty bag is the point where SSH finally behaves
**exactly like S3 and WebDAV** (`BackendDescriptor.sessionValues` already
returns `FieldValues()` for both of those today when the block is
missing). The documented asymmetry disappears.

### 3. The four accessors go away

`host`, `port`, `username`, `authKind` are deleted.

**`keyPath` and `jump` stay.** They return optionals, invent nothing, and
their eighteen readers are legitimate (already recorded as such in the
M23 wrap-up).

## Two tests from M25 flip

`anSSHSessionWithoutItsBlockStillShowsAPasswordField` and its twin today
pin down that a blockless `.ssh` record returns a **filled** bag — with
`authKind == "password"` from the fallback. After M26 it returns an empty
one.

**This is not a broken promise, it is the promise's purpose.** The tests
were the brace holding the transition period during which the accessors
still stood. They are **rewritten, not deleted**, with a doc comment
naming M26 as the point where the answer changed — the same procedure as
with the characterization tests in M24.

The `.s3`/`.webdav` twin from the M25 fix wave (`visibleSecretField` is
**not** nil for a blockless record) remains valid unchanged: it pins a
property of the schema, not of the accessors.

## Success criteria

| # | Criterion | Evidence |
|---|---|---|
| 1 | A `.ssh` record without a block does not appear in `sessions` | a test that writes such a file and loads it through the real `SessionStore` |
| 2 | The file is **not** changed on load | same test: file content identical byte-for-byte before and after loading |
| 3 | Other records in the same file survive | same test: a healthy neighbor is present |
| 4 | The four accessors no longer exist | `grep`, and the compiler |
| 5 | `keyPath` and `jump` continue to exist unchanged | grep |
| 6 | `values(from:)` returns the empty bag for a blockless `.ssh` record | the rewritten M25 test |
| 7 | No behavior changes for healthy data | the full suite stays green; any adjustment needed beyond the two rewritten tests is a **finding** |
| 8 | Test count ≥ 1604 | full suite, gated suites, catalogs `plutil`-clean |

## Test notes

- Criteria 1–3 need a **real `SessionStore`** over a file in a temporary
  directory, not a mock: the read path itself is what is being checked.
  The pattern for this is in the existing `SessionStore` tests and in the
  frozen legacy fixtures from M22/M23.
- The fixture file is **written by hand** (a `.ssh` record without an
  `ssh` key plus a healthy neighbor), because no write path in the app can
  produce it. This is the same justified special case as with the
  blockless sessions in `BackendDescriptorTests`.
- Sessions otherwise via the fixtures in `SessionFixtures.swift`.

## For the release notes

**One sentence.** A connection whose stored data is incomplete — reachable
only by hand-editing the file or through file damage — is skipped on
launch instead of shown as a row that cannot connect.

## Open, deliberately not part of M26

- Making the state **unrepresentable** (one payload per `kind` instead of
  three optional blocks). That would be the actual root fix, but it is a
  model and persistence rework with a format question — its own milestone,
  if ever.
- A visible notice of the discard (audit log).
- The 0%-CPU test-suite hang (its own file).
- The release backlog: 313+ commits ahead of `main`.
