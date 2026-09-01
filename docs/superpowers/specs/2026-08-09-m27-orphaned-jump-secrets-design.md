# M27 — Orphaned jump secrets from the M23 migration (Design)

**Status:** 2026-08-09. Predecessor: the cleanup pass after M26
(`2026-08-08-m26-closeout.md`, addenda). This milestone resolves the last
technical point left open from M23.

## Goal

`LegacyStoredSession`'s doc comment has said, since M23, that migrating a
non-SSH session discards its `jump` and **leaves the associated** keychain
entry standing — and points the cleanup work to "a dedicated pass that owns a
`SecretStore` and can report its errors". That pass does not exist. M27
builds it.

Today the entry is reachable through **no** deletion path: every caller of
`deletePassword` derives its ID from a record the list still contains, and
the orphaned record is exactly the one that's no longer there.

## Why this is dangerous, and what follows from it

All secrets live under **one** keychain service, with the account in each
case a bare UUID. Session secrets, jump secrets, login-set secrets, and
managed-key passphrases sit side by side, indistinguishable. A sweep that
implements "delete whatever no session claims" would delete login-set
secrets and key passphrases along with it.

The inventory found **seven** concrete paths on which the set of claimed IDs
comes out too small. Four of them share the same root — between the file and
the enumeration sits a filter or a `try?`:

| Trap | Mechanism |
|---|---|
| Login set with an unknown `authKind` | `LoginSetStore.all()` withholds the record (forward compatibility, pinned by a test); for a newer build, its secret is live |
| Store not readable | `reload()` falls back to empty lists on a throw, and reads login sets with `try? … ?? []` |
| `managed_keys.json` not decodable | `all()` **throws**; a caller using `try?` turns that into "there are no keys" |
| Blockless `.ssh` record | `dropsOnLoad` hides it from `all()` while it's still sitting in the file |

The remaining three: a failing keychain read proves nothing (house rule
since M19); the secret of a session switched to login-set mode is stale but
still claimed; and the actual M23 orphans are only reachable from a file
that nobody reads today.

**That is where the shape follows from**, and it is the core of this
design: not "delete everything nobody claims", but **only delete what is
positively identified as an orphan**.

## The shape

### Candidates come from the legacy file, not from the keychain

`sessions.json` is **never deleted** by M23 — `migrateFromLegacy()` only
writes the new file, and the store's doc comment explicitly calls the old
one the snapshot that stays behind for a downgrade. The orphaned
`secretID`s are therefore still sitting there, nameable rather than
inferred.

**This is the decisive property of this design.** An entry that a *future*
macSCP build created can, by construction, never become a candidate,
because it cannot appear in a file from before M23. The forward-
compatibility trap is thereby not sidestepped, but excluded.

Enumerating the keychain is not necessary. **The `SecretStore` protocol
stays unchanged** — and with it the twelve conformances across eight files.

### The claim set, and which part of it actually carries weight

What gets subtracted is the union of all IDs that anything claims today:
session IDs, jump `secretID`s, login-set IDs, managed-key IDs.

**A restriction is due here, one this design imposed on itself while
double-checking the math.** The first draft required reading all of that
from the **raw files** instead of from `all()`, and justified that with the
four filter traps in the table above. On recalculation, that argument does
**not** hold up here:

- `dropsOnLoad` only hides blockless `.ssh` records — and such a record has
  no `ssh` block, and therefore no jump `secretID` that would need
  protecting.
- `LoginSetStore.all()` hides login sets with an unknown `authKind` — their
  IDs are assigned separately and cannot be a jump `secretID` from before
  M23.

Because candidates are **exclusively** jump `secretID`s from the legacy
file, neither of the two hidden kinds can ever become a candidate. The
raw-file path is therefore **belt and suspenders, not the load-bearing
wall** — and the spec says so, instead of claiming a safety that comes
from somewhere else.

**What is load-bearing is something else, and it is serious:** if the
session file is not read but silently treated as empty, **no** jump
`secretID` is claimed anymore — and the sweep deletes the secrets of every
jump connection that still exists. That is exactly the path `reload()`
opens up, falling back to empty lists on a throw.

Hence the rule: **the sweep never uses the ViewModel's state**, but the
stores themselves, and lets them throw. The generous subtraction across all
four kinds stays anyway — it costs nothing and makes "only what appears
nowhere gets deleted" true without a case distinction.

### Every read error aborts

No `try? … ?? []` anywhere on this milestone's path. If one of the files
cannot be read, **the sweep does not run**, and says so. "I could not read"
must never turn into "there is nothing" — that is the mistake three of the
seven traps consist of.

This also applies to the legacy file itself: if it's there and not
readable, that's an abort. If it's **not** there, there's nothing to do —
no error.

### Nothing is read, only deleted

The sweep never calls `password(for:)`. That means no access dialogs, and
no decision hangs on a failing read. Deleting a non-existent entry is a
no-op — already pinned in the repo by `deleteRemovesAndIsIdempotent`.

### The legacy file stays put

It is read and not touched. The downgrade promise from M23 stays valid. For
this, the sweep needs a **narrow, read-only** access path to a file that is
`private` today.

## Operation

A button in **Settings › Manage Data** — the section already exists and so
far only contains links, no action of its own.

- **Confirmation follows house pattern:** `.confirmationDialog` with a
  destructive button, as when deleting sessions, login sets and known
  hosts.
- **No preview count, but a report afterward.** Originally it was meant to
  say "N entries removed", and a second run was meant to report zero.
  **That doesn't work, and the reason came to light during implementation:**
  `KeychainSecretStore.deletePassword` maps `errSecItemNotFound` to
  **success**. A deletion therefore reports success even when nothing was
  there — `removed` counts successful delete *calls*, not removed entries.
  And since the legacy file stays put as the downgrade promise, the
  candidate set on the second run is the same: it would again report "N
  removed", even though nothing was there. That could only be
  distinguished by reading (forbidden: access dialogs, and a failing read
  proves nothing) or by a new protocol member (forbidden).
  **So the report states no removal count.** It says the run finished, and
  names the number of **errors**, if there were any. A number nobody can
  trust is worse than no number. This still needs no **done marker**.
- **The button is always enabled.** A greyed-out state would need a file
  access while drawing the settings, for an action that is idempotent
  anyway.
- **A partial failure does not stop it.** As with removing several known
  hosts, the loop keeps going and the report names the error count.

### No audit entry — and why the first decision was reversed

Originally the run was meant to be audited: this is where credentials
disappear that the user never saw. While writing the plan, it turned out
this cannot be honored in today's model.

**The audit log is strictly session-bound.** `AuditRecorder` is created
with a `sessionID`, `AuditLogStore` creates one file per session, and a
recorder only comes into being when a connection window attaches one.
Settings have no session. On top of that, there is **deliberately no
global audit view** — a created entry would not be readable from within the
app.

"Audited" would therefore mean: a file on disk that nobody can open. That
is not a log, it is the claim of a log.

**Decision (maintainer, 2026-08-09): no audit entry.** Instead, the report
immediately after the run — the user triggered the action themselves and is
standing right in front of it. That puts M27 in line with deleting
sessions, login sets and managed keys, none of which are audited.

An app-wide audit area was considered and rejected: it would solve the
problem properly, but it has its own design questions (retention, view,
volume) and would be bigger than this milestone. **Belongs on the backlog,
not in M27.**

## What is explicitly out of scope

- **Orphans from failed managed-key rollbacks.** Three rollback paths
  delete with `try?`; if that fails, an entry is left behind under an ID
  that never made it into `managed_keys.json`. These IDs appear
  **nowhere** — with this milestone's method they are not discoverable.
  Finding them would mean enumerating the keychain, and that is exactly
  what this design rules out.
- **The stale secret of a session switched to login-set mode.**
  `save()` skips the secret block when a login set is set, and
  `updateSession`'s cleanup checks the schema, which doesn't know
  `loginSetID` — so the old entry stays behind. The ID is claimed, the
  entry is **not an orphan**, and the sweep does not touch it. A different
  class of error: not a leftover, but a gap in the live save path. **Own
  finding, own fix, own test** — maintainer decision 2026-08-09.
- **A distinguishing mark in the keychain** (label, prefix, a separate
  service per kind). Considered and rejected: keychain ACLs attach to the
  individual entry, a rewritten account is a new entry, and that would
  wipe out all the "Always Allow" consents the CLI needs for unattended
  runs. An older build would also see zero secrets, without the file
  detour M23 deliberately kept open.
- **An automatic run at startup.** The code explicitly holds that a read
  path must never have a keychain write effect; a silent run would need
  its own hook after startup and would take the decision away from the
  user.

## Success criteria

| # | Criterion | Proof |
|---|---|---|
| 1 | A legacy jump `secretID` that no current record claims is deleted | Test over temporary files + `InMemorySecretStore`: ID present before, gone after |
| 2 | A legacy `secretID` still claimed by a current record is **not** deleted | Same test, second ID, stays behind |
| 3 | **An unreadable session file deletes nothing** — the worst case: silently empty would mean deleting every live jump secret | Test with an unreadable file; `InMemorySecretStore` **unchanged** afterward, run reports the error |
| 4 | The sweep does not read ViewModel state | Sweep gets the stores, not the ViewModel; fixed as the signature and checked in review |
| 5 | Every single unreadable file aborts the run without deleting | one test per file; `InMemorySecretStore` unchanged |
| 6 | A missing legacy file is not an error | Run reports zero removed, no throw |
| 7 | The sweep never reads a secret | Test double whose `password(for:)` fails the test |
| 8 | A partial failure does not stop the run | Double that throws for one ID; the rest get removed, the report names the error |
| 9 | The legacy file is byte-identical after the run | Bytes before/after |
| 10 | The report claims no removal count and never names an ID or a value | **by inspection** — a test over the generated text cannot exist in this structure: the text is created in `ManageDataSettingsSection.runReap()`, a `private` method of a `private struct` in the App target `MacSCPApp`, and the package only has the test target `macSCPCoreTests`. **Left unsecured as a result:** a later `text += "\(result.removed)"` would break this milestone's central user-visible decision without anything turning red. Whoever wants to pin this must first pull the formatting out of the view into a callable function — a separate pass, noted in the wrap-up report's backlog |
| 11 | All four catalogs carry the new keys | the existing catalog guard test |

## Test notes

- The core logic belongs in Core and is tested **without a real keychain**:
  temporary files plus `InMemorySecretStore`. Its `storedIDs` — introduced
  in the cleanup pass — is exactly the tool for criteria 1–3: it shows that
  **nowhere** did anything remain, or that **nothing** was touched, not
  just under the one ID that was asked about.
- **Two tests that aren't really tests, and belong in anyway.** The
  fixtures for the blockless `.ssh` record and for the login set with an
  unknown `authKind` are kept around — but with a doc comment saying that
  under today's candidate rule they **cannot fail**, and stand as a guard
  for a later extension. Whoever ever widens the candidate set to "everything
  in the keychain" makes them sharp. Without that comment, they would be
  two tests faking safety.
- Criterion 7 needs a double whose `password(for:)` fails the test. The
  pattern already exists in the repo multiple times.
- The gated `MACSCP_KEYCHAIN` suite stays **untouched**. It covers the real
  keychain, this milestone adds nothing to it.
- Fixtures for the blockless record and for the unknown `authKind` already
  exist and are reused rather than reinvented.

## For the release notes

**One sentence.** Settings › Manage Data can now remove credentials left
behind in the keychain during the upgrade from version 1.0, that nothing
has used since.

## Open, deliberately not part of M27

- The stale secret in login-set mode (see above) — **on the backlog**.
- **An app-wide audit area** with no session binding, including a view — the
  prerequisite for logging an action from Settings at all. **On the
  backlog.**
- Orphans from failed managed-key rollbacks — only reachable through a
  keychain enumeration, which this design rejects.
- The 0%-CPU test-suite hang.
- The release backlog.
