# M28 — The Two Deleting Binders: Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> superpowers:subagent-driven-development (recommended) or
> superpowers:executing-plans to implement this plan task-by-task. Steps use
> checkbox (`- [ ]`) syntax for tracking.

**Goal:** The two places that delete a Keychain slot when binding to a login
set stop doing that unconditionally.

**Architecture:** A coverage question in Core answers "does this set hold
what a login bound to it needs" via the schema. The jump binding asks it
before deleting. `applyMerge` does **not** need it — there the defect is a
different one (see below). In addition, login-set import reports when sets
arrive without a password.

**Tech Stack:** Swift 6, `.swiftLanguageMode(.v5)`, SwiftPM, macOS 15+,
Swift Testing, SwiftUI.

Spec: `../specs/2026-08-09-m28-loeschende-binder-design.md`

## Deviation from the spec, flagged rather than smoothed over

The spec states **one** rule for both binders. It does not hold up during
planning: the two defects are different.

- **The jump binding** deletes a slot that **nothing carries** — the old
  bastion slot is the only copy. There, the coverage question is the right
  one: does the new set hold something, or does it need nothing?
- **`applyMerge`** does in fact carry — it reads a member's secret and writes
  it onto the set. Its defect is not the missing question but the
  **swallowed read**: `try?` turns "not readable" into "nothing there", and
  the deletion follows. The coverage question would not improve anything
  here; a **throwing** read would: not readable ⇒ abort, genuinely empty ⇒
  there is nothing to lose, and deleting empty slots is consequence-free.

Both fixes are in the plan, each with its own justification. The spec
remains correct in substance — its generalization was one level too coarse.

**Second deviation — and its correction after the Task 1 review.** The spec
names the managed-key probe as a special case the schema cannot answer. The
plan initially concluded from that, that it was not needed at all. **That
was too broad, and the Task 1 review caught it:**

- For the **coverage question itself** it holds: a `.privateKey` set shows
  `passphrase`, the field is not `isRequired`, and the "not required ⇒
  covered" branch carries the case. Task 1 needs no `ManagedKeyStore`
  dependency and has none.
- For the **deletion decision** it does **not** hold. A binder that deletes
  based solely on this answer removes the passphrase slot of a session whose
  key is encrypted and whose set holds nothing — the passphrase is then
  nowhere at all. The coverage question says "does the set need a secret",
  not "does the login lose something it needs".

**Task 3 therefore combines both questions**, and the probe keeps throwing
instead of guessing. Task 2 is unaffected by this: there, something is
carried, not covered.

## Global Constraints

- **Code, comments, identifiers, test names: English only.** Internal docs
  German.
- **A secret value is never printed, logged, or embedded in an error — not
  even in a test failure message.**
- **No `try?` read decides a deletion.** A throwing read aborts. An
  unanswerable coverage question does not delete.
- **The coverage question never asks `LoginSet.authKind`.** `authKind` and
  `kind` are independent and are copied verbatim by the import.
- The `SecretStore` protocol gets **no** new member.
- The stale slot of a set-bound session is **not** deleted; the three
  non-deleting binders stay untouched.
- App UI across all four catalogs en/de/fr/pl with identical key sets.
- Conventional Commits, English message, footer on every commit:
  `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`
- **Do not push.** Do not start the GUI. Do not run `scripts/release`.
- Test-count baseline: **1640**.

---

### Task 1: The coverage question

**Files:**
- Modify: `Sources/macSCPCore/Capabilities/BackendDescriptor.swift`
- Modify: `Sources/macSCPCore/Presentation/SessionListViewModel.swift`
- Test: `Tests/macSCPCoreTests/BackendDescriptorTests.swift`,
  `Tests/macSCPCoreTests/SessionListViewModelTests.swift`

**Interfaces:**
- Produces: `BackendDescriptor.visibleSecretField(for set: LoginSet) -> ConnectionField?`
  — the twin of the existing `StoredSession` version, via
  `loginSetValues(_:)` instead of `sessionValues(_:)`.
- Produces: `SessionListViewModel.setCoversItsLogin(_ set: LoginSet) throws -> Bool`
  — `true` when the set needs no secret at all **or** holds one. **Throws**
  when the Keychain does not answer.

- [ ] **Step 1: Write the tests**

For the twin, in `BackendDescriptorTests`:

```swift
/// The LoginSet twin of the StoredSession question. Both ask
/// `visibleSecretField` over the same schema; only the value source differs.
@Test func aPasswordLoginSetShowsItsPasswordField() throws { … }
@Test func anAgentLoginSetShowsNoSecretField() throws { … }
@Test func aPrivateKeyLoginSetShowsAnOptionalPassphraseField() throws { … }
```

For the coverage question, in `SessionListViewModelTests` — **one per row
of the spec table**, that is success criterion 4:

```swift
@Test func aPasswordSetWithoutASecretIsNotCovered() throws { … }
@Test func aPasswordSetHoldingASecretIsCovered() throws { … }
@Test func anAgentSetIsCoveredWithoutReadingTheKeychain() throws { … }
@Test func aPrivateKeySetIsCoveredWithoutASetSecret() throws { … }
@Test func anS3SetWithoutASecretIsNotCovered() throws { … }
@Test func aWebDAVSetIsCoveredWithoutASecret() throws { … }
```

Plus the two that the last attempt would have failed on:

```swift
/// Success criterion 5, the most important test of this milestone. `kind` and
/// `authKind` are independent columns and the login-set importer copies both
/// verbatim, so a set can declare S3 storage with agent auth. Asking
/// `authKind` would call this covered and delete a session's only secret
/// access key. Asking the schema does not.
@Test func anS3SetDeclaringAgentAuthIsStillNotCovered() throws { … }

/// A keychain that will not answer is not an empty one. Everything in M28
/// hangs on this: the two deleting binders decide from this answer.
@Test func anUnreadableKeychainMakesCoverageThrowRatherThanFalse() throws { … }
```

`anAgentSetIsCoveredWithoutReadingTheKeychain` needs a double whose
`password(for:)` fails the test — the pattern occurs several times in the
repo.

- [ ] **Step 2: See red**

```bash
swift test --filter Covered
swift test --filter LoginSetShows
```
Expected: FAIL, the members do not exist.

- [ ] **Step 3: Implement the twin**

In `BackendDescriptor`, next to `visibleSecretField(for session:)`:

```swift
/// The login set's currently visible secret field, or nil when the set needs
/// no secret at all.
///
/// The twin of the `StoredSession` question above, over `loginSetValues`
/// instead of `sessionValues`. Both exist because "which field is the secret
/// right now" is a schema question, and a login set answers it from its own
/// values -- never from `LoginSet.authKind`, which is a separate column from
/// `kind` and is copied verbatim out of an imported file, so the two can
/// disagree.
public func visibleSecretField(for set: LoginSet) -> ConnectionField? {
    credentialSchema.visibleSecretField(
        in: loginSetValues(set), namespace: fieldNamespace)
}
```

- [ ] **Step 4: Implement the coverage question**

In `SessionListViewModel`:

```swift
/// Whether `set` holds what a login bound to it will need.
///
/// Two arms, and the order matters: a set whose visible secret field is
/// absent or optional needs nothing, and answering that FIRST is what keeps
/// the Keychain from being read for an agent or key login that has no slot
/// (the M10d rule). Only a set that declares a required secret is asked
/// whether it actually holds one.
///
/// THROWS rather than answering false when the Keychain will not respond. A
/// failed read is not proof of an empty slot, and the callers of this decide
/// whether to delete a credential from its answer -- reading "not covered"
/// out of a locked Keychain would destroy an intact secret.
func setCoversItsLogin(_ set: LoginSet) throws -> Bool {
    let descriptor = BackendDescriptor.descriptor(for: set.kind)
    guard descriptor.visibleSecretField(for: set)?.isRequired == true else { return true }
    return !((try secrets.password(for: set.id)) ?? "").isEmpty
}
```

- [ ] **Step 5: See green and run the counter-check**

```bash
swift test --filter Covered
swift test --filter LoginSetShows
```

Then, one at a time, revert each:

1. Replace `descriptor.visibleSecretField(for: set)?.isRequired == true` with
   `set.authKind != .agent` → `anS3SetDeclaringAgentAuthIsStillNotCovered`
   must go red. **This is the previous attempt's bug**, pinned down here.
2. Replace `try secrets.password` with `(try? secrets.password(for: set.id)) ?? nil`
   → `anUnreadableKeychainMakesCoverageThrowRatherThanFalse` must go red.

Put both red states verbatim into the report, then revert cleanly and prove
`git status --porcelain` is empty.

- [ ] **Step 6: Commit**

```bash
git add Sources/macSCPCore Tests/macSCPCoreTests
git commit -m "feat(core): ask the schema whether a login set holds what it needs"
```

---

### Task 2: `applyMerge` stops treating "not readable" as "empty"

**Files:**
- Modify: `Sources/macSCPCore/Presentation/SessionListViewModel.swift`
- Test: `Tests/macSCPCoreTests/SessionListViewModelTests.swift`

**Interfaces:**
- Consumes: nothing from Task 1 — see the deviation note above.

- [ ] **Step 1: Write the tests**

```swift
/// The merge carries one member's secret onto the set and then deletes every
/// member's own slot. A read that FAILS must abort that -- otherwise a locked
/// Keychain looks like a group of empty slots, nothing is carried, no
/// rollback fires, and every member's only copy is deleted.
@Test func anUnreadableMemberSecretRollsTheMergeBackAndDeletesNothing() throws {
    // Double whose password(for:) throws for one member.
    // Expect: set gone from the store, storedIDs unchanged, errorMessage set.
}

/// Genuinely empty slots are not the same case: there is nothing to carry and
/// nothing to lose, so the merge proceeds.
@Test func genuinelyEmptyMemberSlotsStillMerge() throws { … }

/// The carry itself is unchanged: one member's secret lands on the set and
/// the members' own slots go.
@Test func aReadableMemberSecretIsCarriedAndTheOwnSlotsGo() throws { … }
```

- [ ] **Step 2: See red**

```bash
swift test --filter Merge
```
Expected: the first test red — today it deletes instead of aborting.

- [ ] **Step 3: Implement**

Make the two `try?` reads throw and route the throw into the same rollback
branch that already exists for the carry error. The comment must say
**why**, not just what:

```swift
// Both reads throw rather than swallowing: a Keychain that will not answer
// looks exactly like a group of empty slots, and the loop below deletes every
// member's own slot. Reading "nothing to carry" out of a failure would take
// the only copy each member has. A genuinely empty group is a different case
// and still merges -- there is nothing to carry and nothing to lose.
```

The rollback branch stays as it is: delete the set, reassign nothing, delete
nothing, report.

- [ ] **Step 4: See green and run the counter-check**

```bash
swift test --filter Merge
```

Counter-check: put the reads back on `try?` → the first test must go red,
and specifically with a **vanished credential** (`storedIDs` empty), not just
a deviating flag. Put the red output in the report, revert,
`git status --porcelain` empty.

- [ ] **Step 5: Commit**

```bash
git add Sources/macSCPCore Tests/macSCPCoreTests
git commit -m "fix(core): abort the merge on an unreadable secret instead of deleting"
```

---

### Task 3: The jump binding asks before it deletes

**Files:**
- Modify: `Sources/macSCPCore/Presentation/SessionListViewModel.swift`
  (`cleanOrphanedJumpSlot`)
- Test: `Tests/macSCPCoreTests/SessionListViewModelTests.swift`

**Interfaces:**
- Consumes: `setCoversItsLogin(_:)` from Task 1.

- [ ] **Step 1: Write the tests**

```swift
/// Switching a jump from manual to a login set deletes the old bastion slot
/// -- and nothing carries it, so that slot is the only copy. It may only go
/// when the set holds what the jump will need.
@Test func switchingAJumpToASetWithoutASecretKeepsTheBastionSlot() throws { … }
@Test func switchingAJumpToASetThatHoldsItsSecretDropsTheOldSlot() throws { … }
@Test func switchingAJumpToAnAgentSetDropsTheOldSlot() throws { … }

/// An unanswerable Keychain does not delete.
@Test func switchingAJumpWhileTheKeychainIsSilentKeepsTheBastionSlot() throws { … }
```

The existing `cleanOrphanedJumpSlot` tests must stay **green unchanged** —
the manual-to-manual case does not change.

- [ ] **Step 2: See red**

```bash
swift test --filter Jump
```

- [ ] **Step 3: Implement**

`cleanOrphanedJumpSlot` gets the coverage question before the delete. If the
new jump is set-bound and the set is **not** covered — or the question
cannot be answered — the slot stays.

The function is currently throw-free, called by `save` and `updateSession`;
it stays throw-free. An unanswerable read means **do not delete** here, not
**abort**: the binding itself is fine, only the cleanup is skipped. That is
the conservative direction, and the comment must say it was chosen
deliberately.

- [ ] **Step 4: See green and run the counter-check**

Remove the guard → `switchingAJumpToASetWithoutASecretKeepsTheBastionSlot`
must go red with the slot deleted. Revert, prove the tree clean.

- [ ] **Step 5: Commit**

```bash
git add Sources/macSCPCore Tests/macSCPCoreTests
git commit -m "fix(core): keep the bastion secret when the jump's set holds none"
```

---

### Task 4: The import reports when sets arrive without a password

**Files:**
- Modify: `Sources/macSCPCore/Presentation/SessionListViewModel.swift`
  (the login-set import result)
- Modify: `Sources/MacSCPApp/LoginSetsSheet.swift` (`importResultText`)
- Modify: `Sources/MacSCPApp/Resources/{en,de,fr,pl}.lproj/Localizable.strings`
- Test: `Tests/macSCPCoreTests/SessionListViewModelTests.swift`

- [ ] **Step 1: Add the count**

The login-set import result gets a field for "arrived without a password",
counted at creation time. **Only count, do not read** — the number comes
from the planned secret, not from a Keychain read.

- [ ] **Step 2: Write the test**

```swift
/// The export leaves secrets out by default and the import said nothing, so
/// the state that M28's guards exist for used to arrive unannounced.
@Test func importingSetsWithoutSecretsReportsTheirNumber() throws { … }
```

- [ ] **Step 3: Add the four catalogs**

English as reference, in the style of the neighboring lines:

```
"loginSets.import.withoutPassword %lld" = "Arrived without a password: %lld";
```

German:

```
"loginSets.import.withoutPassword %lld" = "Ohne Passwort angekommen: %lld";
```

FR and PL correspondingly — the same key set, enforced by the existing
guard test.

- [ ] **Step 4: Hook into the result message**

Next to the existing lines, only when the count is greater than zero.

- [ ] **Step 5: Verify and commit**

```bash
for f in Sources/MacSCPApp/Resources/*.lproj/Localizable.strings; do plutil -lint "$f"; done
swift test --filter LocalizableStrings
swift build
swift test
```

```bash
git add Sources Tests
git commit -m "feat(app): say when imported logins arrived without a password"
```

---

### Task 5: Milestone close-out

**Files:**
- Create: `docs/superpowers/specs/2026-08-09-m28-abschluss.md`

- [ ] **Step 1: Full verification**

```bash
swift build
swift test
```

Docker rig **from the main checkout**, never from a worktree:

```bash
docker compose -f docker/test-server/compose.yml up -d
MACSCP_ITEST=1 swift test
MACSCP_KEYCHAIN=1 swift test --filter Keychain
```

If a run stalls at 0% CPU, that is the hang known since M20 — abort, restart,
note it, do **not** count it as an M28 finding. Afterward
`pgrep -fl swiftpm-testing-helper`.

Catalogs:

```bash
for f in Sources/MacSCPApp/Resources/*.lproj/Localizable.strings Sources/macSCPCore/Resources/*.lproj/Localizable.strings; do plutil -lint "$f"; done
```

- [ ] **Step 2: The counter-check for the loss path**

Run the test from Task 1 that would have caught the last attempt
(`anS3SetDeclaringAgentAuthIsStillNotCovered`) against the **then-current**
formulation: switch the coverage question to `set.authKind != .agent` as a
trial, see the test go red, revert. The result goes in the report — it is
the evidence that M28 genuinely catches its predecessor's bug rather than
just writing it differently.

- [ ] **Step 3: Write the report**

Shape of `2026-08-08-m26-abschluss.md`. Must contain: the verification with
numbers; the ten success criteria of the spec with **evidence rather than
claims**; the red states of all three counter-checks verbatim; the
**deviation from the spec** (one rule became two) and what it says about
generalizing; the backstory in one paragraph (four reverted rounds, and why
the goal shifted); what remains open (the stale slot, the editor friction,
the app-wide audit area, the release backlog); and the number of unpushed
commits.

- [ ] **Step 4: Commit, do not push**

```bash
git add docs/superpowers/specs/2026-08-09-m28-abschluss.md
git commit -m "docs(m28): record the milestone close"
```

---

## Plan self-review

**Spec coverage.** Criteria 1–2 → T2; 3 → T3; 4 → T1/Step 1 (six tests,
one per table row); 5 → T1 (`anS3SetDeclaringAgentAuthIsStillNotCovered`)
and T5/Step 2; 6 → T1/Step 5, counter-check 1; 7 → T1
(`anUnreadableKeychainMakesCoverageThrowRatherThanFalse`) and T3; 8 → T4;
9 → review; 10 → T4/Step 5.

**Type consistency.** `BackendDescriptor.loginSetValues(_:)` and
`credentialSchema.visibleSecretField(in:namespace:)` both exist and are
quoted above with their real signatures; `ConnectionField.isRequired` is the
field that `StoredSessionConnectionConfig` already queries in the same
composition.

**Two deliberate imprecisions, flagged rather than hidden:**

1. **The test bodies in T2 and T3 are names plus doc comment**, not finished
   code. What each test must prove is fixed; the setup — merge group, jump
   spec, matching double — occurs repeatedly in the repo and is better left
   to the implementer than to a plan line I have not executed.
2. **The exact shape of the import count in T4 is open.** I know the result
   has count fields and the message prints them line by line; which field is
   named what and exactly where it is counted, the implementer looks up in
   the code. A plan line I have not verified is a hypothesis — and this one
   is marked as such.

**What this plan deliberately does not do.** It does not touch the three
non-deleting binders and does not delete the stale slot. Four rounds have
worked exactly there and each time left behind a loss path. Whoever tackles
that later has, with T1, the precondition it needs.
