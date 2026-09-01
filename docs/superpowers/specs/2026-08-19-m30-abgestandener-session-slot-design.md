# M30 — The stale session slot on login-set switch (design)

As of 2026-08-19. Replaces the attempt reverted on 2026-08-09 in `479d018`.

## Starting point

A session bound to a login set keeps its own password in the keychain. If
the user later switches back to manual and leaves the field empty, nothing
gets written — and the next connect picks up the old value.

Four attempts have failed at this. Each wanted to delete the slot **at
bind time**, and each review round closed the previously named loss path
and delivered a new one. The revert message names three of the four paths;
one of them checked `LoginSet.authKind == .agent`, even though the comment
right next to it warns in so many words against making exactly that
substitution. The revert's commit message sums it up: the defect is real
but mild — an invisible slot whose value still works — and every time,
what stood against it was a path that destroys the only copy of a
credential.

## What was measured beforehand

Four measurements that carry the design. Without them, the same trap would
have been set again:

1. **The form never loads the secret from the keychain.** An empty field
   at save time means "leave unchanged" project-wide — a deliberate,
   documented rule.
2. **`visibleSecretField(for session:)` knows nothing of the set
   binding.** It only reads the session's own values; the delete branch in
   `updateSession` (which cleans up for ssh-agent) therefore does not
   apply here. The slot genuinely survives.
3. **The edit-save validator runs with `requireSecrets: false`** — exactly
   why the empty field goes through today.
4. **`requireSecrets: true` demands only visible secret fields declared as
   required.** The SSH passphrase is explicitly optional, and agent
   logins show no secret field at all. So there is no false rejection —
   the assumption on which this approach would otherwise have failed.

## The cut

The finding splits into two harms:

- **Harm 1:** A secret the user considers superseded stays in the
  keychain — invisible, unused, with no expiry.
- **Harm 2:** Switching back to manual silently reactivates it.

**M30 fixes harm 2. Harm 1 stays deliberately open** (maintainer decision
2026-08-19). All four failed attempts targeted harm 1 — by deleting at the
exact moment deletion is most dangerous, because the set may hold the only
copy.

## The rule

On leaving set mode, an empty secret field means **not** "unchanged" but a
validation error. The existing validator says so with the message it
already declares for that field.

In `ConnectionViewModel.validateForEditSave()`, the secret requirement is
therefore no longer a constant but follows from the transition:

```swift
let leftLoginSet = editingOriginal.loginSetID != nil && loginMode == .manual
if let violation = descriptor.firstViolation(in: values, requireSecrets: leftLoginSet) { … }
```

Symmetrically for the jump, via `editingOriginal.jump?.loginSetID` and
`jumpLoginMode`; `validateJump(requireSecret:)` already carries the
parameter. A session-referencing jump (`jumpSourceMode == .session`)
already returns early there and has no secret of its own, so the case
cannot arise.

**The change contains no `delete` call.** The typed value overwrites the
old slot via the existing write path. The four loss paths are thus not
guarded but structurally excluded — that is the actual difference from the
reverted attempt.

## Why the rule sits in the validator

Validation belongs in the validator. `validateForEditSave` is the one
function through which an edit save assembles its session; both call sites
in the form go through it. A future caller therefore cannot forget the
rule — the same reasoning as the jump guard in `updateSession`.

`editingOriginal` is provably non-nil there, not merely "always has been
so far": `mode` is `private(set)`, `beginEditing` is the only place that
sets `.edit`, and it sets `editingOriginal` before that. The existing doc
comment already lays this out.

The alternative — putting the rule in `SessionListViewModel.updateSession`,
which also knows the previous state — was rejected: a new rejection path
would have to grow through the persistence layer there, for a question
validation can already answer.

## Edge cases

| Case | Behavior |
|---|---|
| Set → manual, password auth, field empty | rejected, password field named |
| Set → manual, password typed | saved, old value overwritten |
| Set → manual, key auth without passphrase | saved (passphrase is optional) |
| Set → manual, agent auth | saved (no secret field visible) |
| Set A → Set B | unchanged, no manual mode in play |
| Manual session, no mode change, field empty | saved — "empty = unchanged" stays intact |

### The other door: the set gets deleted

A session also leaves set mode when its login set is deleted. This path is
**already correct** and is not touched: it writes the set's secret into
the session's slot before nulling `loginSetID`. The old value is thus
overwritten, not left stale — the finding does not arise here at all.
Remeasured 2026-08-19; without that measurement it would have been the
most obvious gap in M30's scope.

## The cost

Anyone who leaves the set and wanted to keep their old password has to
type it in again once. That is the price of "empty" no longer being able
to mean two things at this spot. Decided deliberately, not overlooked.

## Tests

Six cases, one per row of the edge-case table, plus the two jump forms of
rows 1 and 2.

The **constant-return probe** is satisfied: row 1 goes red if
`requireSecrets` is hardcoded to `false`, row 6 goes red if it is
hardcoded to `true`. The rule is thus pinned in both directions, not only
the one the fix establishes.

Rows 3 and 4 are the false-rejection guards: they pin down measurement 4,
so that a future rework of the field schemas — say, a passphrase that
becomes required — surfaces here instead of for the user.

## What remains open

Harm 1: the own slot of a session that **is** bound is not touched.
Likewise untouched are the neighbors named in the revert, `applyMerge` and
the jump binding, which read with `try?` and delete anyway — they belong
to harm 1 and to no path M30 touches.
