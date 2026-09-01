# M28 — The two deleting binders (design)

**As of:** 2026-08-09. Predecessor: the login-set slot fix retracted the
same day (`479d018`). This milestone attacks the problem at the point that
four previous attempts missed.

## How this milestone arrived at its goal

The retracted fix wanted to get rid of the **stale slot**: a session that
gets bound to a login set keeps its old password in the keychain, and it
takes effect again when switching back to manual. Four adversarial
reviews, four paths on which the **only** copy of a secret disappeared in
the process. Retracted.

The follow-up investigation refuted the goal itself:

> **The stale slot is the mild condition.** Nothing is lost, and for SSH
> password and S3 the connect honestly refuses
> ("Password must not be empty." / "Fill in all required S3 fields.").
>
> **Dangerous are two spots the retracted fix never touched** — and that
> were already there before it.

Five spots bind a session or a jump to a login set. **Exactly two of them
delete a keychain slot while doing so, and neither of the two checks any
condition today.**

| # | Binder | deletes? |
|---|---|---|
| 1 | form "Save & Connect" (`save`) | no — the secret block is entirely skipped once `loginSetID` is set |
| 2 | edit-save (`validateForEditSave`) | no — pure value computation |
| 3 | **`applyMerge`** | **yes** — deletes each merged session's own slot |
| 4 | "Save as new set" (`onSaveEdited`) | only indirectly, and only for agent sessions |
| 5 | **jump binding (`buildJumpSpec` → `cleanOrphanedJumpSlot`)** | **yes** — deletes the previous manual jump slot, *because* the new jump is in set mode |

## The two defects

### `applyMerge` confuses "no secret" with "not readable"

The source secrets are read with `try?`. If all reads return `nil` — the
slot is empty **or the keychain isn't answering** —, `carryError` stays
empty, **no rollback fires**, the set is created without a secret, every
session gets bound to it, and in the same loop pass each own slot gets
deleted.

`LoginMergePlanner` narrows this but does not close it: a `.credential`
secret that isn't readable drops out during candidate formation — so at
*plan time* at least one member had a readable secret. `applyMerge`,
however, reads **again**, and a confirmation dialog sits between the two
reads. A `.passphrase` secret is never read at plan time in the first
place.

### The jump binding deletes because of the mode, not because of coverage

`cleanOrphanedJumpSlot` deletes the slot of the previous manual jump as
soon as the new jump carries a `loginSetID`. Whether this set holds a
secret is never asked. An ordinary user path: switch the jump from
"Manual" to a secret-less set ⇒ bastion password gone, jump no longer able
to log in.

### How a secret-less set even comes about — easier than expected

Login-set **export has secrets off by default**, and **import says not a
word** about the sets arriving without a password: the result message has
lines for renamed, keys imported, missing paths, secret failures — but
none for "these sets arrived without a password." The export side reports
it ("Exported without a password: %lld"), the import side does not.

## The rule

**A binder that deletes asks the same question as the connection path:**

> Does this set's **currently visible secret field** declare itself
> **required**?

Not `LoginSet.authKind`. That is precisely where the last attempt failed:
`authKind` and `kind` are independent columns that the login-set import
copies verbatim from the file — an `.s3` set with `authKind: agent` cuts
short every guard built on that assumption.

The schema question already exists and correctly distinguishes all five
configurations in the connection path:

| Configuration | visible secret field | required? | a set without a secret is… |
|---|---|---|---|
| SSH password | `password` | yes | **not covered** |
| SSH private key | `passphrase` | no | covered (unencrypted key) |
| SSH agent | none visible | — | covered |
| S3 | `secretAccessKey` | yes | **not covered** |
| WebDAV | `password` | no | covered (anonymous share — maintainer decision from M23) |

Plus the special case the schema **cannot** answer: a key set whose
passphrase sits under the **managed key's own ID**. There is an existing
probe for that, and it **throws** instead of returning `false` when it
cannot answer. That property is preserved.

### And the second half, where four rounds failed

**A throwing read aborts. A `try?` read never decides on a deletion.** A
locked keychain looks like an empty set; deriving "not covered" from that
and deleting anyway destroys an intact secret. Deriving "covered" from
that does too.

The same rule applies to the coverage check itself: if it cannot be
answered, **nothing is deleted**.

## What happens when it isn't covered

**The binding takes place, the slot stays, the user is told.**

Not refusal: the investigation showed that a refusal sends users into the
login-set editor — and that editor demands the secret again on **edit**,
before saving is unlocked, even if only the name is changed. Pointing
there points into that friction.

Not silent: for `applyMerge` the difference is severe — instead of deleting
all slots and leaving behind an empty set, every session stays able to
connect.

For `applyMerge` the pattern that already exists there for the carry error
additionally applies: **roll the set back, reassign nothing, delete
nothing, report it.** A merge that cannot carry over the secrets must not
do half the work.

## Second part: the import says so

If sets without a password arrive during login-set import, the result
message names their count — the same form the export side already uses.
That is the spot where the condition arises; that it arises unnoticed
today is the reason nobody expects it later.

## What explicitly does **not** belong here

- **The stale slot of a set-bound session is not deleted.** That was the
  goal of the retracted fix. Four attempts showed that exactly this
  deletion carries the risk, and the investigation showed that the
  condition is mild. Whoever tackles it later has, with this milestone,
  the precondition they need for it — but it is its own pass with its own
  decision.
- **The three non-deleting binders stay untouched.** Guarding them was the
  mistake of the four rounds: there is nothing to lose there.
- **Collecting existing orphans.** Needs a keychain enumeration; two
  milestones have deliberately rejected it.
- **The editor friction** (retyping a secret to change a name). A real
  finding, its own fix.

## Success criteria

| # | Criterion | Proof |
|---|---|---|
| 1 | `applyMerge` deletes no slot when the set does not hold the secret | test: set without secret, merge runs, `storedIDs` of all members unchanged |
| 2 | `applyMerge` aborts instead of deleting on an unreadable keychain | test with a throwing read: set rolled back, **no** slot touched, error reported |
| 3 | The jump binding deletes the old jump slot only for a covered set | test per coverage case |
| 4 | All five configurations are distinguished correctly | one test per row of the table above |
| 5 | An `.s3` set with `authKind: agent` counts **as not** covered | the test that would have caught the last attempt |
| 6 | The coverage question never asks `LoginSet.authKind` | review; in the code as a doc commitment |
| 7 | An unanswerable coverage check does not delete | test with a throwing probe |
| 8 | The import names the count of sets without a password | test on the generated text |
| 9 | No secret value in message, log, or test failure text | review |
| 10 | All four catalogs carry the new keys | the existing guard test |

## Test notes

- **Every deletion must visibly disappear under mutation.** Remove the
  guard ⇒ the test shows the credential as gone, not merely a deviating
  flag. The four failed rounds had tests that stayed green while the loss
  path was open.
- The existing doubles suffice: the in-memory double with its set
  enumeration for "nothing has disappeared anywhere," the failing variants
  for throwing reads and deletes.
- **Criterion 5 is the most important test of the milestone.** It builds a
  set whose `kind` and `authKind` contradict each other — exactly the
  shape that import lets through unchecked.

## For the release notes

**One sentence.** A stored password is no longer removed when a connection
or a jump host is switched to a login that itself has none stored.

## Open, deliberately not part of M28

- The stale slot of the set-bound session (see above).
- The editor friction when editing a set.
- The app-wide audit area.
- The release backlog.
