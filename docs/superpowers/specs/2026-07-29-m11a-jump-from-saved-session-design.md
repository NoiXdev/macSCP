# M11a — Jump host from a saved connection (design)

Date: 2026-07-29 · Status: approved by the maintainer ("go ahead then")

## Goal

In the jump block of the connection form, be able to select a saved
connection as the jump host instead of retyping host/port/login. The
selection is persisted as a REFERENCE: if the bastion connection changes,
that applies everywhere.

**Maintainer decisions (2026-07-29):**

1. REFERENCE, not a copy — and explicitly NOT reusing another tab's live
   connection (that would break the "one connection per tab" invariant
   and couple lifecycles).
2. Deleting a referenced connection resets the affected jumps (copy the
   values + secret, detach the reference) — the same pattern as the
   login-set deletion from M10b. Never broken connections.

## 1. Model

- `StoredSession.JumpSpec.sessionID: UUID?` — non-nil = session mode;
  its own fields (`host`, `port`, `username`, `authKind`, `keyPath`,
  `loginSetID`) are then inactive (kept as a data carrier for the reset).
  Optional WITHOUT a custom decoder (pattern
  `groupID`/`loginSetID`/`jump`) — an old `sessions.json` reads nil.
- `secretID` stays unchanged: unused in session mode, cleaned up on
  switching to session mode the same way as on a set switch (slot hygiene
  from M10c/M10d).

## 2. Resolution on connect

- `LoginResolver.resolveJump` additionally gets the session list (and the
  ID of the referencing session, to detect self-reference).
- Session mode: look up the session by `sessionID`.
  - **not found** ⇒ `LoginResolveError.missingJumpSession`
  - **the referenced session itself has a jump** ⇒
    `LoginResolveError.jumpChainNotSupported` (ONE hop remains the rule;
    the picker filters this out beforehand, but the reference can later
    break if the bastion is subsequently given a jump)
  - **self-reference** (`sessionID == referencing session id`) ⇒
    likewise `jumpChainNotSupported`
  - otherwise: host/port from the referenced session; the LOGIN via the
    EXISTING `LoginResolver.resolve(session:sets:secrets:)` — so login
    set, manual password/key, and agent all work automatically at the
    jump, with no new code path. A missing login set on the referenced
    session propagates as `missingSet` (unchanged).
- No silent fallback in any case (M10b/M10c principle).
- Eligibility as a pure Core function:
  `JumpSessionEligibility.eligible(for editingSessionID: UUID?, in sessions: [StoredSession]) -> [StoredSession]`
  — excludes the session currently being edited and any session with its
  own jump; sorted like the sidebar (name, case-insensitive).

## 3. Form

- In the jump block above the host row, a toggle
  `Saved connection | Manual` (default manual — existing behavior).
- **Session mode:** a picker over the eligible sessions; below it a
  non-editable summary of the resolved target
  (`host:port · user · auth short form`, auth short form as in the
  login-sets sheet). NO host/port/login fields, NO login three-way, no
  "Save as new login set".
- **Manual mode:** exactly today's behavior (host/port + three-way).
- Validation: session mode requires a selection; the referenced session
  must be eligible (chains/self-reference are already rejected at save
  time, with the same message as at connect time).
- Edit prefill: `sessionID` set ⇒ session mode with a preselection.
- New `ConnectionViewModel` fields: `jumpSourceMode`
  (`enum JumpSourceMode: String, CaseIterable, Sendable { case session, manual }`,
  default `.manual`), `jumpSessionID: UUID?`. Both get reset along with
  `exitEditMode()`/`endEditing()` (M10b lesson).

## 4. Deletion = reset

- `SessionListViewModel.delete(_:)` checks before deletion which sessions
  reference the one being deleted as a jump; the delete confirmation
  names the count (App layer).
- On confirming: for each affected session, host/port/username/
  authKind/keyPath of the DELETED session get copied into its JumpSpec
  and its resolved secret (from the session slot or the login set of the
  deleted session) gets written into the jump's `secretID` slot;
  `sessionID` gets nulled. Agent logins carry over no secret (M10d rule).
  Keychain errors get counted, not aborted on
  (`restored`/`secretFailures` like `LoginSetDeleteResult`).
- A referencing jump in SET mode of the deleted session does not keep its
  set reference — the reset writes exactly the resolved values, so the
  connection keeps working without the deleted session.

## 5. Export/import

- Export resolves a session jump to concrete values (M10c pattern:
  `jumpHost`/`jumpPort`/`jumpUsername`/`jumpAuthKind`/`jumpKeyPath`
  + `jumpPassword` only with `includePasswords`); the reference UUID does
  NOT travel along (imported sessions get fresh IDs anyway).
- Missing/broken reference ⇒ export exports the spec's own values and
  never aborts (a missing secret counts as before in
  `missingPasswordCount`).
- Import: unchanged — it always produces a manual jump.

## 6. Tests

- Decode compatibility (`sessions.json` without `sessionID` ⇒ nil),
  roundtrip.
- Resolution across all three login kinds of the referenced session
  (password, key, agent) including a login set of the referenced session.
- The three error cases: `missingJumpSession`, chain, self-reference.
- Eligibility function (chains and the session being edited filtered
  out, sorting).
- Reset on deletion: values + secret copied, reference nulled, agent
  carries over no secret, keychain error counts instead of aborting.
- Export: session jump resolved; broken reference ⇒ own values, no
  abort.
- Gated: a connection via a SESSION-referenced jump
  (container 1 as a saved bastion → sshd2), plus the chain guard against
  a bastion with its own jump.

## 7. Breakdown

T1 Core (JumpSpec.sessionID + resolver + eligibility) → T2 VM
(reset + export) → T3 App (toggle, picker, display,
error messages, L10n) → T4 closeout (gated rig test, final review).
NO release.

## 8. Deliberately NOT in M11a

No use of another tab's LIVE connection; no chains (more than one hop);
no session picker for the TARGET host (the session IS the target); no
export of the reference; no automatic switching of existing manual jumps
to matching saved connections.
