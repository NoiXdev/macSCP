# M30 — Stale Session Slot on Login-Set Switch: Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> superpowers:subagent-driven-development (recommended) or
> superpowers:executing-plans to implement this plan task-by-task. Steps use
> checkbox (`- [ ]`) syntax for tracking.

**Goal:** When leaving login-set mode, an empty secret field no longer
means "unchanged" — it is a validation error, so that an old password
cannot silently become active again.

**Architecture:** A single change to two calls in
`ConnectionViewModel.validateForEditSave()`: the previously fixed
`requireSecrets: false` resp. `requireSecret: false` is now derived from
the transition (previously bound to a set, now manual). The message comes
from the existing validator from the field declaration. **Nothing is
deleted** — the typed value overwrites the old slot via the existing write
path.

**Tech Stack:** Swift 6 (`.swiftLanguageMode(.v5)`), SwiftPM, macOS 15+,
Swift Testing (`@Test`/`#expect`).

**Spec:** `docs/superpowers/specs/2026-08-19-m30-stale-session-slot-design.md`

## Global Constraints

- Code, comments, test names, commit messages: **English**. Internal docs
  (`docs/`) may stay German.
- Conventional Commits, footer on every commit:
  `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`
- **No secret may ever reach an error message**, not even a test message:
  `#expect` expands its expression, so hoist it into a `Bool` first and
  check that.
- **This change contains no `delete` call.** Whoever needs one while
  implementing has left the design and reports it instead of building it in.
- New logic comes with tests, TDD red→green. Suite: `swift test`.
- **The prose of this plan is a claim to be verified, not a finding.**
  If a signature, field name, or message key claimed here does not hold:
  report it, do not silently rework it.

## Files

| File | Role in this plan |
|---|---|
| `Sources/macSCPCore/Presentation/ConnectionViewModel.swift` | carries `validateForEditSave()`; this is where the whole behaviour change sits |
| `Tests/macSCPCoreTests/ConnectionViewModelTests.swift` | the validation tests, Task 1 and 2 |
| `Tests/macSCPCoreTests/SessionListViewModelTests.swift` | the one test that pins the overwrite of the slot (Task 1) |

No new files, no new types, no new L10n keys: the messages
`core.connect.passwordEmpty` and `core.connect.jumpPasswordEmpty`
are already declared and translated.

---

### Task 1: The rule for the session

**Files:**
- Modify: `Sources/macSCPCore/Presentation/ConnectionViewModel.swift` (in `validateForEditSave()`, at the `descriptor.firstViolation` call)
- Test: `Tests/macSCPCoreTests/ConnectionViewModelTests.swift`
- Test: `Tests/macSCPCoreTests/SessionListViewModelTests.swift`

**Interfaces:**
- Consumes: `BackendDescriptor.firstViolation(in:requireSecrets:)`, `ConnectionViewModel.editingOriginal`, `ConnectionViewModel.loginMode`, the fixture `sshSession(name:host:username:authKind:keyPath:loginSetID:jump:)` from `Tests/macSCPCoreTests/SessionFixtures.swift`
- Produces: nothing new — Task 2 changes the same function on the line below

- [ ] **Step 1: Write the five failing tests**

Insert at the end of `ConnectionViewModelTests`. `beginEditing` sets
`loginMode` from `stored.loginSetID`; the line `vm.loginMode = .manual`
therefore reproduces exactly the user's reach for the switch.

```swift
    /// M30: Leaving Set mode is the one moment when an empty secret field
    /// does NOT mean "leave unchanged". Without this rule, the previous
    /// configuration's password stays in the keychain and is silently
    /// reused on the next connect.
    ///
    /// The opposite direction — a manual session that does not switch mode
    /// at all — is pinned by
    /// `validateForEditSaveAllowsEmptyPasswordAndBuildsTheSession` further up
    /// this file. Together the two nail the rule down in both directions: a
    /// hard-wired `true` or `false` would turn one of them red.
    @Test @MainActor func leavingLoginSetModeWithAnEmptyPasswordIsRefused() {
        let vm = makeVM()
        vm.beginEditing(sshSession(name: "web", host: "h", username: "u",
                                   loginSetID: UUID()))
        vm.loginMode = .manual
        vm.password = ""

        #expect(vm.validateForEditSave() == nil)
        #expect(vm.state == .failed(
            message: CoreL10n.string("core.connect.passwordEmpty"),
            field: .schema("\(SSHField.namespace).\(SSHField.password.rawValue)")))
    }

    @Test @MainActor func leavingLoginSetModeWithATypedPasswordSaves() {
        let vm = makeVM()
        vm.beginEditing(sshSession(name: "web", host: "h", username: "u",
                                   loginSetID: UUID()))
        vm.loginMode = .manual
        vm.password = "typed"

        let result = vm.validateForEditSave()
        #expect(result?.loginSetID == nil)
        #expect(vm.state == .idle)
    }

    /// False-refusal guard. The SSH passphrase is explicitly declared NOT
    /// required in `SSHFieldSchema.credential` — an unencrypted key has
    /// none. Should that ever change, it will show up here instead of on
    /// the user.
    @Test @MainActor func leavingLoginSetModeWithAKeyLoginNeedsNoPassphrase() {
        let vm = makeVM()
        vm.beginEditing(sshSession(name: "web", host: "h", username: "u",
                                   authKind: .privateKey, keyPath: "/k",
                                   loginSetID: UUID()))
        vm.loginMode = .manual
        vm.password = ""

        #expect(vm.validateForEditSave() != nil)
    }

    /// Second false-refusal guard: an agent login shows no secret field at
    /// all, so `requireSecrets` has nothing to demand there.
    @Test @MainActor func leavingLoginSetModeWithAnAgentLoginNeedsNoSecret() {
        let vm = makeVM()
        vm.beginEditing(sshSession(name: "web", host: "h", username: "u",
                                   authKind: .agent, loginSetID: UUID()))
        vm.loginMode = .manual
        vm.password = ""

        #expect(vm.validateForEditSave() != nil)
    }

    /// Switching from one set to another is not leaving: there is no
    /// manual mode in which an old slot could become active again.
    @Test @MainActor func switchingBetweenLoginSetsNeedsNoSecret() {
        let vm = makeVM()
        vm.beginEditing(sshSession(name: "web", host: "h", username: "u",
                                   loginSetID: UUID()))
        vm.selectedLoginSetID = UUID()
        vm.password = ""

        #expect(vm.validateForEditSave() != nil)
    }
```

- [ ] **Step 2: Write the sixth test — the overwrite**

Insert in `SessionListViewModelTests`. It pins the second half of the
assertion: the typed value really replaces the old slot, instead of
landing next to it. Without it, Task 1 only proves that saving is
*allowed*.

The secret is hoisted into a `Bool` before `#expect` sees it — the macro
expansion would otherwise print the value into the failure message.

```swift
    /// M30: the value demanded when leaving Set mode must REPLACE the old
    /// slot. Otherwise the new validation rule would be pointless -- the
    /// user types a password and the old one would stay put regardless.
    @Test func aNewSecretOnEditReplacesTheStoredOne() throws {
        let (vm, secrets, dir) = makeVM()
        defer { try? FileManager.default.removeItem(at: dir) }
        let session = sshSession(name: "web", host: "h", username: "u")
        try secrets.savePassword("old", for: session.id)

        vm.updateSession(session, newSecret: "new")

        // Hoisted into a Bool first: `#expect` expands its receiver, and a
        // secret must never reach a failure message.
        let replaced = try secrets.password(for: session.id) == "new"
        #expect(replaced)
    }
```

- [ ] **Step 3: Run the tests, confirm red**

```bash
swift test --filter "leavingLoginSetModeWithAnEmptyPasswordIsRefused"
```

Expected: FAIL — `validateForEditSave()` today returns a session instead of
`nil`, because `requireSecrets` is fixed to `false`. The four other new
tests from Step 1 and the one from Step 2 are already green; they are the
controls that bound the rule, not the drivers.

- [ ] **Step 4: Build in the rule**

In `validateForEditSave()`, immediately before the `descriptor.firstViolation`
call. `editingOriginal` rather than the local copy `session`: the copy is
mutated further down, and a future reordering of that would otherwise
silently falsify this question.

```swift
        let descriptor = BackendDescriptor.descriptor(for: kind)
        // M30: leaving Set mode is the one moment where an empty secret field
        // does NOT mean "leave the stored one unchanged". The stored one
        // belongs to a configuration the user is walking away from, so letting
        // it stand silently reactivates it on the next connect. Demanding the
        // secret here makes the write path overwrite that slot, which is why
        // this fix deletes nothing -- every earlier attempt deleted on BINDING
        // instead and was reverted, four times, for destroying the only copy
        // of a credential.
        //
        // Read from `editingOriginal`, not from the local `session` copy: that
        // copy is mutated further down, and reordering those mutations would
        // otherwise change this answer without touching this line.
        let leftLoginSet = editingOriginal?.loginSetID != nil && loginMode == .manual
        if let violation = descriptor.firstViolation(in: values, requireSecrets: leftLoginSet) {
```

- [ ] **Step 5: Run the tests, confirm green**

```bash
swift test --filter "ConnectionViewModelTests|SessionListViewModelTests"
```

Expected: PASS, all six new tests plus the existing ones in the same
files.

- [ ] **Step 6: Full suite**

```bash
swift test
```

Expected: PASS. Should an existing test turn red, that is a finding
about the scope of the rule and needs to be reported — not smoothed over
by adjusting the old test.

- [ ] **Step 7: Commit**

```bash
git add Sources/macSCPCore/Presentation/ConnectionViewModel.swift Tests/macSCPCoreTests/ConnectionViewModelTests.swift Tests/macSCPCoreTests/SessionListViewModelTests.swift
git commit -m "fix(core): demand the secret when a session leaves its login set

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: The jump symmetry

**Files:**
- Modify: `Sources/macSCPCore/Presentation/ConnectionViewModel.swift` (in `validateForEditSave()`, at the `validateJump` call directly below Task 1's change)
- Test: `Tests/macSCPCoreTests/ConnectionViewModelTests.swift`

**Interfaces:**
- Consumes: `ConnectionViewModel.validateJump(requireSecret:)` — the parameter already exists and is today called with `false`; `StoredSession.JumpSpec(host:port:username:authKind:keyPath:loginSetID:secretID:sessionID:)`
- Produces: nothing — last code change of the plan

- [ ] **Step 1: Write the two failing tests**

The session itself stays manual and unbound in both, so that only the
jump rule is tested. `beginEditing` sets `jumpLoginMode` from
`jump.loginSetID`, exactly as `loginMode` is set from the session's.

```swift
    /// M30, the jump's half of the same rule: the jump has its own
    /// keychain slot and the same set binding, and therefore the same way
    /// back for an old secret to silently become active again. The session
    /// itself stays unbound here so the test checks the jump rule alone,
    /// without also exercising the one from Task 1.
    @Test @MainActor func aJumpLeavingLoginSetModeWithAnEmptyPasswordIsRefused() {
        let vm = makeVM()
        vm.beginEditing(sshSession(
            name: "web", host: "h", username: "u",
            jump: StoredSession.JumpSpec(host: "bastion", username: "j",
                                         loginSetID: UUID())))
        vm.jumpLoginMode = .manual
        vm.jumpPassword = ""

        #expect(vm.validateForEditSave() == nil)
        #expect(vm.state == .failed(
            message: CoreL10n.string("core.connect.jumpPasswordEmpty"),
            field: .jumpPassword))
    }

    @Test @MainActor func aJumpLeavingLoginSetModeWithATypedPasswordSaves() {
        let vm = makeVM()
        vm.beginEditing(sshSession(
            name: "web", host: "h", username: "u",
            jump: StoredSession.JumpSpec(host: "bastion", username: "j",
                                         loginSetID: UUID())))
        vm.jumpLoginMode = .manual
        vm.jumpPassword = "typed"

        #expect(vm.validateForEditSave() != nil)
        #expect(vm.state == .idle)
    }
```

- [ ] **Step 2: Run the tests, confirm red**

```bash
swift test --filter "aJumpLeavingLoginSetModeWithAnEmptyPasswordIsRefused"
```

Expected: FAIL — `validateJump` is today called with a fixed
`requireSecret: false`.

- [ ] **Step 3: Build in the rule**

The existing comment above the call ("requireSecret: false for the same
reason as above") is replaced, because it is no longer true after this
change — the value is no longer a constant.

```swift
        // M30: the jump's own half of the rule above. Its `loginSetID` and
        // its `secretID` slot mirror the session's, so it has the same way
        // back into a stale credential. A session-mode jump cannot reach this
        // at all -- `validateJump` returns early for it and such a jump owns
        // no secret.
        let jumpLeftLoginSet = editingOriginal?.jump?.loginSetID != nil && jumpLoginMode == .manual
        if let jumpFailure = validateJump(requireSecret: jumpLeftLoginSet) {
            state = jumpFailure
            return nil
        }
```

- [ ] **Step 4: Run the tests, confirm green**

```bash
swift test --filter "ConnectionViewModelTests"
```

Expected: PASS.

- [ ] **Step 5: Full suite**

```bash
swift test
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/macSCPCore/Presentation/ConnectionViewModel.swift Tests/macSCPCoreTests/ConnectionViewModelTests.swift
git commit -m "fix(core): demand the jump's secret when it leaves its login set

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 3: Close-out

**Files:**
- Create: `docs/superpowers/specs/2026-08-19-m30-closeout.md`

**Interfaces:**
- Consumes: the commits from Task 1 and 2
- Produces: nothing

- [ ] **Step 1: Full suite, read the output BEFORE committing**

```bash
swift test
```

Note the number of tests and suites. (An earlier phase committed a red
test because the run and the commit were in the same command — that is
why they are kept separate here.)

- [ ] **Step 2: Verify that the change really deletes nothing**

```bash
git diff origin/develop..HEAD -- Sources/ | grep -n "deletePassword" || echo "no deletePassword in the diff"
```

Expected: `no deletePassword in the diff`. This is the central assertion
of the spec — it is verified, not claimed.

- [ ] **Step 3: Write the close-out report**

`docs/superpowers/specs/2026-08-19-m30-closeout.md`, German, with: what
was implemented, the result of Step 2, the suite counts from Step 1, and
explicitly what remains open (defect 1 — the slot of a session that IS
bound, plus `applyMerge` and the jump binding, which read with `try?` and
delete regardless).

- [ ] **Step 4: Commit**

```bash
git add docs/superpowers/specs/2026-08-19-m30-closeout.md
git commit -m "docs(m30): record the close

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```
