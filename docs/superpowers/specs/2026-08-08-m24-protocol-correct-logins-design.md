# M24 — Protocol-Correct Logins (Design)

**Status:** 2026-08-08. Predecessor: M23 (`2026-08-07-m23-closeout.md`),
whose completion report named both bugs and deliberately left them unfixed.

## Goal

Fix two real bugs of the same class: an SSH-shaped layer that has let
non-protocol sessions through since M12.

1. **`LoginMergePlanner` can delete the secret of an S3 or WebDAV
   session.** A data-loss path, not cosmetics.
2. **`JumpSessionEligibility` does not filter by protocol.** A bucket is
   selectable as a bastion; the resolver then reads `host: ""`.

Both are currently pinned by characterization tests that explain what is
wrong. These tests flip to commitments in this milestone.

**Not part of this milestone:** the intermittent 0% CPU hang of the test
suite. Open cause, own investigation with systematic-debugging.

## Bug 1 — the merge proposal

### Current state

`LoginMergePlanner.candidates` filters exclusively on `loginSetID == nil`.
There is no `kind` predicate, and `SessionListViewModel.mergeCandidates()`
feeds in every session. For an `.s3` session, `session.authKind` returns
the fallback value `.password` and `session.username` returns the
fallback value `""`; the `.password` branch then reads the session's
keychain slot — which for S3 holds the **secret access key**.

Two S3 sessions on one credential pair (one account, two buckets — the
normal case) thus appear as a merge proposal. Whoever accepts it gets, via
`SessionListViewModel.applyMerge`, a `LoginSet` whose `kind` is
pre-populated as `.ssh` and whose `accessKeyID` stays `nil`; both
sessions are rehung onto it and afterward **each session's own keychain
slot is deleted**. WebDAV has the same shape.

The resulting damage is complete: the set cannot carry the login (wrong
`kind`, no `accessKeyID`), and `LoginResolver.resolve` correctly rejects
the binding on connect with `kindMismatch` — except by then the secret is
already gone and has to be retyped.

### Decision (maintainer, 2026-08-08)

**Make the merge protocol-correct**, not restrict it to SSH. S3 login
sets have existed since M15 and are meant for exactly this case; a
filter would eliminate the data loss and keep the benefit at the same time.

### The grouping key

Today hard SSH-shaped (`username` + `authKind` + `keyPath` + `password`).
Going forward, derived from the schema:

> `kind`
> + the values of all **visible** fields of the `credentialSchema` that
>   are not a secret
> + the secret, **if** the visible secret field is the login itself
>   (see `SecretRole` below)

`ConnectionFieldSchema.visibleFields(in:namespace:)` handles the case
distinction that the `switch` makes today. The result reproduces the SSH
behavior exactly, without naming SSH:

**All values are compared literally** — including the non-secret fields,
including case, including whitespace. That is the current behavior (the
planner reads `session.username` raw) and deliberately **not** the
`FieldIdentity` vocabulary from M23/P3: that answers "is this the same
connection" for the import duplicate check, far from all credential
fields carry it (`SSHField.authKind`, for instance, does not), and a
field without `identity` would then drop out of the key — exactly the
field that distinguishes SSH's three auth kinds.

| Configuration | Visible non-secret fields | Secret in the key |
|---|---|---|
| SSH `.password` | `username`, `authKind` | yes |
| SSH `.privateKey` | `username`, `authKind`, `keyPath` | no |
| SSH `.agent` | `username`, `authKind` | no secret field visible |
| S3 | `accessKeyID` | yes |
| WebDAV | `username` | yes |

### `SecretRole` — why `isRequired` is not enough

The obvious derivation path "the secret counts if its field is
`isRequired`" gets the right answer for SSH and S3 and **the wrong one
for WebDAV**: its `password` has been optional since M23 (anonymous
shares are supported), so it would drop out of the key. Two WebDAV
sessions with the same username and **different passwords** would again
be a merge candidate — the same data loss in a different color.

The distinction is substantive and not derivable, so it is declared.
SSH's `passphrase` **unlocks** a login that is already in the key (the
key file via `keyPath`): two sessions on the same file are the same
login, regardless of whether the passphrase happens to be stored.
`password` and `secretAccessKey` **are** the login.

New in `FieldVocabulary.swift`, next to `FieldFormat` and `FieldIdentity`:

```swift
public enum SecretRole: Sendable {
    /// The secret IS the credential — two logins with different secrets are
    /// different logins.
    case credential
    /// The secret unlocks a credential named by another field (SSH's key
    /// path). Two logins to the same key file are the same login whether or
    /// not the passphrase happens to be stored.
    case passphrase
}
```

Carried by `ConnectionField` (meaningful only for `kind == .secret`),
declared on four fields: `SSHField.password` → `.credential`,
`SSHField.passphrase` → `.passphrase`, `S3Field.secretAccessKey` →
`.credential`, `WebDAVField.password` → `.credential`. A fourth backend
declares it once alongside.

### Participation rule

- Visible secret field with `.credential` and **no** secret in the
  keychain → the session does not participate. That is exactly the
  current SSH rule ("nothing to compare"), now also for S3 and WebDAV.
  Anonymous WebDAV sessions are therefore never proposed.
- Visible secret field with `.passphrase`, or no visible secret field
  at all (ssh-agent) → **the keychain is not touched.** This preserves
  M10d's structural commitment, pinned by
  `agentSetResolvesWithoutKeychainRead` with a read-hostile store.

### `LoginMergeCandidate`

Loses `username`, `authKind` and `keyPath`. Gains:

- `kind: ConnectionKind`
- `values: FieldValues` — the candidate's credential values, **without
  the secret**
- `displayLabel: String` — the value of the first visible non-secret
  field of the credential schema. For SSH and WebDAV the username, for
  S3 the access key ID.
- `sessionIDs: [UUID]` (unchanged)

Sorting (today `username`, then `keyPath`, then group size) will run
via `displayLabel`, then group size. The ignored groups
(`ignoredMergeGroups`) are sets of session IDs and stay untouched.

### `applyMerge`

Builds the set via the `BackendDescriptor.loginSet(id:name:from:)` that
has existed since M22 — the inverse that can handle any `kind`. The
secret transport (first group session that actually has one → store it
under `set.id` → only then delete the session slots, with rollback on
write failure) stays unchanged; it was never the problem.

**In addition, a hard gate**, even though the rebuilt planner should
never trigger it: a candidate whose sessions do not all carry the
candidate's `kind` is rejected and nothing is written. M23 found twelve
comments that claimed something about the code that nobody had
verified — the gate costs a few lines and a test and turns the claim
into a fact.

### App layer

`LoginSetsSheet` reads `candidate.username` in three places (banner,
confirmation dialog, suggested name via `suggestedSetName(forUsername:)`).
All three will read `candidate.displayLabel` going forward. The banner
text ("%lld connections use the same login "%@".") remains literally
valid — it names no protocol terms. `suggestedSetName(forUsername:)` is
renamed to `suggestedSetName(forLabel:)` so the parameter name does not lie.

## Bug 2 — the jump host

### Current state

`JumpSessionEligibility.eligible(for:in:)` filters on the session
currently being edited and on chains, nothing else. An `.s3` or
`.webdav` session is offered as a bastion, even though only SSH tunnels.
`LoginResolver.resolveJump(spec:sets:secrets:sessions:referencingSessionID:)`
does not reject it either: it checks chain and self-reference and then
reads `referenced.host`/`referenced.port` — for an S3 session, the
internal fallback values `""` and `22`.

### Three sites, in ascending order of importance

**1. The picker.** `JumpSessionEligibility.eligible` additionally filters
on `kind == .ssh`. A bucket disappears from the selection.

**2. The hard gate in the resolver — the actual fix.** A picker filter
only protects what gets created going forward. Anyone who already has a
session whose `jump.sessionID` points at a bucket (creatable since M12)
still runs into it. So `resolveJump(…sessions:
referencingSessionID:)` gets a third check besides the chain and
self-reference ones: if `sessionID` points at a non-SSH session, it
throws before host and port are read.

An **own** error case, not the existing `kindMismatch` — that means
"session and its login set speak different protocols" and would name
the wrong cause here:

```swift
/// A jump's `sessionID` points at a session that is not an SSH connection.
/// Only SSH tunnels; an object-storage or WebDAV session has no host to dial
/// through. Distinct from `kindMismatch`, which is about a session and its
/// login set disagreeing.
case jumpSessionNotSSH
```

Cost: three existing `catch` sites (`ContentView` twice,
`ConnectionFormView` once) get an arm, one new L10n key in all four App
catalogs (en/de/fr/pl, identical key sets).

**3. `SessionListViewModel.delete`.** If a session that serves others as
a bastion is deleted, `delete` copies its login into the referencing
sessions — including `session.host` and `session.port`. For a non-SSH
session, those are the placeholders.

Going forward: **if the deleted session is not SSH, nothing is
restored.** The reference stays dangling and, on the next connect,
yields `.missingJumpSession` ("the referenced connection was deleted")
— true and fixable, whereas `host: ""` looks like a configured bastion
nobody can select.
`JumpRestoreResult.restored` comes out correspondingly lower.

### Deliberately not: a migration

Existing broken jump references are **not** rewritten. They fail after
the gate with a message that names the cause. A sweep that touches the
user's stored `JumpSpec` blocks is riskier than the bug it would be
healing.

## Success criteria

| # | Criterion | Evidence |
|---|---|---|
| 1 | Two S3 sessions with the **same** credential pair yield an `.s3` candidate whose merge produces an `.s3` set with `accessKeyID` set | test over `applyMerge` that reads the resulting set |
| 2 | Two S3 or WebDAV sessions with **different** secrets are **not** a candidate | test per backend |
| 3 | No merge ever deletes a secret the target set does not carry | test: after `applyMerge`, exactly the group's secret sits under `set.id` |
| 4 | Today's SSH behavior is unchanged | see below — the narrowest allowed adjustment of the existing `LoginMergePlannerTests` |
| 5 | `.passphrase` and ssh-agent do not read the keychain | read-hostile `SecretStore` as in `agentSetResolvesWithoutKeychainRead` |
| 6 | A non-SSH session is neither selectable nor resolvable as a bastion | picker test **and** resolver test; the resolver test builds the `JumpSpec` directly, without the picker |
| 7 | `delete` never writes a placeholder host into a foreign `JumpSpec` | test with an S3 bastion and a referencing SSH session |
| 8 | Both characterization tests are rewritten into commitments, not deleted | `nonSSHSessionsAreStillOfferedAsJumpHosts`, `nonSSHSessionsSharingASecretAreStillOfferedAsAMergeCandidate` |

### Criterion 4 in detail

The existing `LoginMergePlannerTests` read `candidate.username`,
`candidate.authKind` and `candidate.keyPath` — all three fall away with
the new candidate shape. "Green without adjustment" is therefore not
achievable; the clamp instead is **which** adjustment is allowed.

Allowed is exclusively re-reading an assertion at its new seat — the
asserted value stays the same:

| before | after |
|---|---|
| `candidate.username == "deploy"` | `candidate.displayLabel == "deploy"` |
| `candidate.authKind == .privateKey` | `candidate.values[SSHField.authKind] == "privateKey"` |
| `candidate.keyPath == "/k1"` | `candidate.values[SSHField.keyPath] == "/k1"` |

**Not allowed — and a finding for the task report — is any change to a
test's inputs, to its `sessionIDs` result, or to the number of
candidates.** If any of these lines needs to be touched, the rebuild has
shifted SSH behavior, and that belongs reported rather than silently
rewritten.

## Test notes

- Sessions are built via the M23 fixtures (`sshSession`, `s3Session`,
  `webdavSession` in `Tests/macSCPCoreTests/SessionFixtures.swift`) —
  the one place where tests assemble a `StoredSession`.
- Secrets come from `InMemorySecretStore`; real keychain access stays
  behind `MACSCP_KEYCHAIN=1`.
- Criterion 4 is the regression clamp: the existing SSH tests must
  **not** need adjustment for the new candidate shape, except where
  they read `candidate.username`. Where an adjustment becomes
  necessary, it belongs in the task report.
- L10n parity is enforced by the existing `LocalizableStringsTests`; the
  new key must appear in all four App catalogs.

## For the release notes

1. **Merge proposals now also exist for S3 and WebDAV** — and they
   produce a set of the correct protocol. Previously the proposal for
   these protocols was broken and deleted the stored credentials on
   accept.
2. **Object-storage and WebDAV connections can no longer be selected as
   a jump host.** An existing configuration that points at one now
   reports plainly on connect that only SSH connections can serve as an
   intermediate stop, instead of producing an unselectable bastion.
3. **If a non-SSH connection that a jump host points to is deleted,
   nothing is copied back into the referencing connection anymore.** It
   reports on the next connect that the referenced connection is missing.

## Open, deliberately not part of M24

- The 0% CPU hang of the test suite (own investigation; as an immediate
  measure a `timeout-minutes` in the CI job).
- Orphaned jump keychain slots from the M23 migration.
- The eight dead S3/WebDAV form shims on `ConnectionViewModel`.
- Whether the four `internal` accessors `host`/`port`/`username`/`authKind`
  on `StoredSession` become deletable after this milestone will be
  **checked** at completion, not promised in advance: after M24 every
  remaining reader is either SSH-guarded or `SSHFieldSchema.values(from:)`,
  but that is a side effect, not a goal.
