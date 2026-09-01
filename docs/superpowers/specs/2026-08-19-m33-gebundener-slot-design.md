# M33 — A bound session's own slot (design)

Status 2026-08-19. "Damage 1" from the M30 spec, deliberately carved out
there.

## The finding

A session bound to a login set keeps its own keychain slot. It is
invisible (the form never loads secrets), unused (connect resolves via
the set) and has no expiry.

Since M30 it can no longer silently become active again — leaving set
mode requires the validator to demand a new secret. What remains is a
credential the user believes superseded, and that still sits in the
keychain.

## Why four attempts failed

All four (2026-08-09, reverted in `479d018`) deleted **at bind time**.
That is the worst possible moment: at that point nobody knows whether the
set even holds a usable secret. A set from an import without secrets, a
set whose own slot is empty, an `authKind` that does not match the
`kind` — each round closed off one of these paths and opened a new one,
and each ended by destroying the only copy of a credential.

**The way out is not a better guard, but a different moment.** A later
pass can check what was unknown at bind time: whether the set actually
resolves a secret for this session.

## The design

**A cleanup pass, triggered by the user**, in "Settings › Manage Data" —
the same place and the same construction as M27's pass for orphaned jump
slots.

**Candidates.** Sessions with `loginSetID != nil` that hold a non-empty
own slot. Derived from `sessions.json`, not from an enumeration of the
keychain — `SecretStore` deliberately has none, and a candidate list from
the store can never hit a foreign ID.

**The guard all four attempts lacked.** A slot is deleted only if the
bound set resolves a **non-empty** secret for this session. If it
resolves nothing — set without a secret, set deleted, schema without a
visible secret field — the slot stays. It may then be the only copy.

**What checks it — measured 2026-08-19.**
`SessionListViewModel.resolvedCredentials(for:)` is exactly this guard:
it resolves via the set, delivers the values including the secret, and
**throws** on a dangling `loginSetID` instead of silently falling back to
the session's own data (spec §2 from M22/T9). A failure is thereby
structurally distinguishable from "the set holds nothing" — the
distinction all four attempts failed on. Whether the resolved secret is
non-empty is answered by
`BackendDescriptor.visibleSecretField(for: session)` via the
corresponding key in the field bag.

**Failed reads are not "nothing there".** Every read error leads to
skipping this candidate, never to a deletion. This is the same rule that
M28/T2 enforced for `applyMerge`: a keychain that does not respond would
otherwise look like a collection of empty slots.

**The set's secret is never touched.** The pass removes only sessions'
own slots, and only those for which a replacement demonstrably exists.

**Feedback.** The pass returns the count of removed slots; the app layer
renders it via the existing plural catalog that exists there. Zero
removed slots is a normal result and is reported as such, not as an
error.

## Tests

Four cases that together pin down the rule in both directions:

1. Bound session, set resolves a secret → slot is gone.
2. Bound session, set resolves **nothing** → slot stays. **This is the
   test the four attempts would not have passed.**
3. Unbound session with its own slot → untouched.
4. Read error on the set → slot stays.

Case 1 is also the positive control: without it, 2–4 would also be
satisfied by a pass that deletes nothing at all.

## What does not belong here

- **No automatic cleanup.** Neither at bind time nor at startup. The
  user triggers it and sees the result — for an operation that removes
  credentials, that is not a matter of convenience.
- **No change to the bind path.** It stays exactly as M28 and M30 left
  it.
- **No enumeration API for `SecretStore`.** Its absence is a deliberate
  boundary, and also the reason the candidates must come from the store.
