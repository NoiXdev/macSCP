# M32 — Partial successes that still delete: Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> superpowers:subagent-driven-development (recommended) or
> superpowers:executing-plans to implement this plan task-by-task.

**Goal:** A failed store write in `applyMerge` must no longer delete the
secret of the affected session.

**Architecture:** `try? store.upsert` becomes `do/catch`; deletion of the
slot hangs on the success of the write. The loop continues for the
remaining members, and a message says that sessions kept their own
password.

**Tech Stack:** Swift 6 (`.swiftLanguageMode(.v5)`), SwiftPM, macOS 15+,
Swift Testing.

**Spec:** `docs/superpowers/specs/2026-08-19-m32-teilerfolge-design.md`

## Global Constraints

- Code, comments, test names, commit messages **English**; docs German.
- Conventional Commits, footer:
  `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`
- User-visible strings via `CoreL10n.string`, in **all four** languages
  under `Sources/macSCPCore/Resources/<lang>.lproj/`.
- **No secret in a message**, not even a test message: lift it into a
  `Bool` first, then check.
- TDD red→green. Suite: `swift test`.
- **This plan's prose is a claim to be verified.** If something is wrong:
  report it, do not quietly rework it.

## What the test needs to know

Two measured properties, without which the test does not work:

1. **`SessionStore.persist` writes with `options: .atomic`.** A
   read-only `sessions.json` is therefore useless — the atomic write
   creates a temp file and renames it, which only requires the
   **directory** to be writable. So it is the directory that gets locked.
2. **`applyMerge` writes the login set FIRST.** If it lived in the same
   locked directory, this write would fail first and the function would
   return before the loop runs. The test therefore gives the two stores
   **separate directories**.

---

### Task 1: Tie deletion to the success of the write

**Files:**
- Modify: `Sources/macSCPCore/Presentation/SessionListViewModel.swift` (rewire loop in `applyMerge`, plus its doc comment)
- Modify: `Sources/macSCPCore/Resources/{en,de,fr,pl}.lproj/Localizable.strings`
- Test: `Tests/macSCPCoreTests/SessionListViewModelTests.swift`

**Interfaces:**
- Consumes: `SessionListViewModel.applyMerge(_:name:)`, `InMemorySecretStore`
- Produces: nothing

- [ ] **Step 1: Write the two tests**

At the end of `SessionListViewModelTests`. The second is the positive
control: without it the first would stay green even if `applyMerge`
deleted nothing at all anymore.

```swift
    /// M32: a failed session write must not take the session's secret with
    /// it. Before this, the loop rewired and deleted with two `try?` in a
    /// row, so a store that refused the write left the session unbound --
    /// still reading its own slot -- and deleted exactly that slot.
    ///
    /// The failure is PRODUCED, not simulated: the session directory is made
    /// read-only, so `upsert` genuinely fails. `SessionStore.persist` writes
    /// with `.atomic`, which renames a temp file into place, so locking the
    /// FILE would not do it -- the directory has to go. The login-set store
    /// gets its own writable directory, because `applyMerge` writes the set
    /// first and would otherwise fail before reaching the loop.
    @Test func aFailedRewireKeepsTheSessionsOwnSecret() throws {
        let sessionDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-m32-sessions-\(UUID().uuidString)")
        let loginDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-m32-logins-\(UUID().uuidString)")
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700], ofItemAtPath: sessionDir.path)
            try? FileManager.default.removeItem(at: sessionDir)
            try? FileManager.default.removeItem(at: loginDir)
        }
        let secrets = InMemorySecretStore()
        let vm = SessionListViewModel(
            store: SessionStore(directory: sessionDir), secrets: secrets,
            loginSetStore: LoginSetStore(directory: loginDir))

        let stored = vm.save(
            name: "web",
            values: sshValues(host: "h", port: 22, username: "u"),
            password: "the-only-copy")!

        // Lock the directory only AFTER the session exists, or there would be
        // nothing to merge.
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o500], ofItemAtPath: sessionDir.path)

        let candidate = LoginMergeCandidate(
            kind: .ssh, values: sshValues(host: "h", port: 22, username: "u"),
            sessionIDs: [stored.id])
        _ = vm.applyMerge(candidate, name: "Shared")

        // Hoisted into a Bool first: `#expect` expands its receiver, and a
        // secret must never reach a failure message.
        let keptItsSecret = try secrets.password(for: stored.id) == "the-only-copy"
        #expect(keptItsSecret)
    }

    /// Positive control for the test above: with a writable directory the
    /// merge does its job -- the session is rewired and its own slot goes.
    /// Without this, a version of `applyMerge` that deleted nothing at all
    /// would satisfy the first test.
    @Test func asuccessfulRewireStillTakesTheSessionsOwnSecret() throws {
        let (vm, secrets, dir) = makeVM()
        defer { try? FileManager.default.removeItem(at: dir) }

        let stored = vm.save(
            name: "web",
            values: sshValues(host: "h", port: 22, username: "u"),
            password: "carried")!
        let candidate = LoginMergeCandidate(
            kind: .ssh, values: sshValues(host: "h", port: 22, username: "u"),
            sessionIDs: [stored.id])

        let set = vm.applyMerge(candidate, name: "Shared")

        #expect(set != nil)
        let slotIsGone = try secrets.password(for: stored.id) == nil
        #expect(slotIsGone)
        #expect(vm.sessions.first { $0.id == stored.id }?.loginSetID == set?.id)
    }
```

- [ ] **Step 2: Run the tests, confirm red**

```bash
swift test --filter "aFailedRewireKeepsTheSessionsOwnSecret"
```

Expected: FAIL — the secret is gone even though the write failed.

If the test does **not** fail, the assumption that a read-only directory
makes `upsert` fail is wrong: then the test measures nothing and the cause
belongs reported, not worked around.

- [ ] **Step 3: Rework the loop**

```swift
        var unlinkedCount = 0
        for session in groupSessions {
            var updated = session
            updated.loginSetID = set.id
            do {
                try store.upsert(updated)
            } catch {
                // M32: the delete below hangs on THIS write. Without that, a
                // refused write left the session unbound -- still resolving
                // its login from its own slot -- and then deleted exactly
                // that slot, leaving it with no credential at all. Skipping
                // both keeps this member exactly as it was; the others are
                // unaffected, which is why the loop continues rather than
                // aborting.
                unlinkedCount += 1
                continue
            }
            try? secrets.deletePassword(for: session.id)
        }
        if unlinkedCount > 0 {
            errorMessage = CoreL10n.string("core.login.mergePartial")
        }
```

And in the function's doc comment, the sentence

```
    /// is rewired and has its own secret deleted in the same iteration —
    /// both are `try?`, so a store-write failure for one session does not
    /// stop that session's secret from being deleted.
```

replaced with

```
    /// is rewired and, ONLY if that write succeeded, has its own secret
    /// deleted in the same iteration (M32). A member whose write fails keeps
    /// both its binding and its secret and is reported; the others still
    /// merge.
```

- [ ] **Step 4: Add the message in all four languages**

In `Sources/macSCPCore/Resources/<lang>.lproj/Localizable.strings`, next to
`core.login.mergeFailed`:

```
en: "core.login.mergePartial" = "Some sessions could not be linked to the new login set. They kept their own password.";
de: "core.login.mergePartial" = "Einige Sitzungen konnten nicht mit dem neuen Login-Set verknüpft werden. Sie haben ihr eigenes Passwort behalten.";
fr: "core.login.mergePartial" = "Certaines sessions n’ont pas pu être liées au nouveau jeu d’identifiants. Elles ont conservé leur propre mot de passe.";
pl: "core.login.mergePartial" = "Niektórych sesji nie udało się powiązać z nowym zestawem logowania. Zachowały własne hasło.";
```

- [ ] **Step 5: Run the tests, confirm green**

```bash
swift test --filter "SessionListViewModelTests"
```

- [ ] **Step 6: Full suite**

```bash
swift test
```

Expected: PASS. An existing test turning red is a finding about the scope
of the rule and belongs reported.

- [ ] **Step 7: Commit**

```bash
git add Sources/macSCPCore Tests/macSCPCoreTests/SessionListViewModelTests.swift
git commit -m "fix(core): keep a session's secret when its merge write fails

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: Close-out

**Files:**
- Create: `docs/superpowers/specs/2026-08-19-m32-abschluss.md`

- [ ] **Step 1: Full suite, read the output BEFORE committing**

```bash
swift test
```

- [ ] **Step 2: Check that no `try?` pair remains in the loop**

```bash
awk '/for session in groupSessions/,/^        \}$/' Sources/macSCPCore/Presentation/SessionListViewModel.swift | grep -c "try? store.upsert"
```

Expected: `0`. Positive control, so an empty `awk` excerpt does not pass as
success:

```bash
awk '/for session in groupSessions/,/^        \}$/' Sources/macSCPCore/Presentation/SessionListViewModel.swift | grep -c "deletePassword"
```

Expected: at least 1 — otherwise the excerpt missed the loop and the first
number means nothing.

- [ ] **Step 3: Write the close-out report**

`docs/superpowers/specs/2026-08-19-m32-abschluss.md`, German: what was
implemented, the result of Step 2, the suite numbers, and explicitly that
three of the five inherited backlog items resolved themselves during
measurement — one of them only after the spec had already listed it as
open.

- [ ] **Step 4: Commit**

```bash
git add docs/superpowers/specs/2026-08-19-m32-abschluss.md
git commit -m "docs(m32): record the close

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```
