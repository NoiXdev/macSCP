# M26 — The blockless SSH record Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Drop a `.ssh` record with no stored SSH block on load, switch
the fifteen readers to `guard let ssh`, and delete the four inventing
`StoredSession` accessors.

**Architecture:** The drop sits at the hygiene seam that already exists in
the `SessionStore` read path (orphaned group IDs). After that,
`.ssh` ⇒ `ssh != nil` holds in practice, and `host`/`port`/`username`/`authKind`
have no readers left.

**Tech Stack:** Swift 6 (`.swiftLanguageMode(.v5)`), SwiftPM, macOS 15+,
Swift Testing (`@Test`/`#expect`).

**Spec:** `docs/superpowers/specs/2026-08-08-m26-blockless-ssh-record-design.md`

## Global Constraints

- **Code and comments: English only.** Identifiers, doc comments, inline
  comments, test names. No German in source files.
- **Commit messages: English, Conventional Commits.** Footer on every commit:
  `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`
- **Commit/push only on explicit request.** No `scripts/release`.
- **A secret value must never be logged, printed, or embedded in an
  error.** Secrets live exclusively in the keychain.
- **Do not launch the GUI app.** Do not commit key material.
- `swift build` stays clean **including the App target**. Test count
  **≥ 1604**.
- **No new localization keys.**
- **Only `.ssh` is dropped**, not `.s3`/`.webdav` — a deliberate asymmetry
  justified in the spec. Whoever extends it must also touch the existing
  blockless guards; that is not this milestone.
- **The read path does not write the file.** No `persist` inside `load()`.
- Sessions in tests via the fixtures in `SessionFixtures.swift`; the
  fixture FILE for Task 1 is written by hand (no write path in the app can
  produce it), with a comment explaining why.

---

## File Structure

| File | Responsibility | Task |
|---|---|---|
| `Sources/macSCPCore/Sessions/SessionStore.swift` | drop in the read path | 1 |
| `Sources/macSCPCore/Sessions/LoginResolver.swift` | 6 readers → `guard let ssh` | 2 |
| `Sources/macSCPCore/Presentation/SessionListViewModel.swift` | 5 readers → `guard let ssh` | 2 |
| `Sources/macSCPCore/SSH/SSHFieldSchema.swift` | 4 readers → empty bag | 2 |
| `Sources/macSCPCore/Sessions/StoredSession.swift` | delete the four accessors | 2 |
| `docs/superpowers/specs/2026-08-08-m26-closeout.md` | close-out report | 3 |

New tests go into the existing suite of the checked type
(`SessionStoreTests`, `BackendDescriptorTests`). **No new test file.**

## Why the tests are laid out as a table

Three milestones together found seventeen defects that sat **in the plan**
rather than in the implementation — almost all in test code that was never
run. Production code is therefore given verbatim below, tests as a table
of (name, setup, expectation) plus a pointer to the form to copy.

---

## Task 1: The drop on load

**Files:**
- Modify: `Sources/macSCPCore/Sessions/SessionStore.swift:61-78` (`load()`)
- Test: `Tests/macSCPCoreTests/SessionStoreTests.swift`

**Interfaces:**
- Produces: nothing new. `load()` stays `private`; the effect is visible
  through the store's public read interface.

- [ ] **Step 1: Write the tests (red)**

Copy the setup from the existing `SessionStore` tests: a real store over
a file in a temporary directory, not a mock — the read path itself is
what is under test.

The fixture file is written **by hand as JSON**: a record with
`"kind": "ssh"` and **without** an `"ssh"` key, alongside a healthy
SSH neighbour. Comment in the test why it is written by hand — no write
path in the app can produce this state.

| Test | Setup | Expectation |
|---|---|---|
| `aBlocklessSSHRecordIsDroppedWhenLoading` | the fixture file, then read the store | the loaded list does **not** contain the blockless record |
| `aHealthyNeighbourSurvivesTheDrop` | the same file | the healthy neighbour is present, with all fields — **a broken entry does not make the file fail** |
| `loadingDoesNotRewriteTheFile` | capture the file contents as `Data` before reading, read the store, read the contents again | byte-identical. Pins the decision that the read path does not write |
| `aBlocklessS3RecordIsKept` | a file with a `"kind": "s3"` record with no `"s3"` key | the record is **still there** — pins the deliberate asymmetry from the spec, so a later extension is a decision rather than an oversight |

- [ ] **Step 2: Confirm red**

Run: `swift test --filter SessionStore`
Expected: `aBlocklessSSHRecordIsDroppedWhenLoading` fails (the record is
loaded today). The other three describe today's behaviour and are
already green — **that is intended**, they are the bracket. Which were
red and which were green belongs in the task report.

- [ ] **Step 3: Build in the drop**

In `load()`, **after** the existing group sweep and **before**
`return file`:

```swift
        // Second hygiene rule, same shape as the group sweep above: an `.ssh`
        // record with no stored SSH block is unusable -- no host, no user
        // name, nothing to dial -- and before M26 it was the last thing that
        // made `StoredSession`'s SSH accessors invent `""`/`22`/`""`/
        // `.password` for a session that never had them.
        //
        // Only `.ssh`. An `.s3`/`.webdav` record with no block is equally
        // unusable, but those backends have no inventing accessors (a missing
        // block yields the EMPTY bag) and their blockless case is already
        // caught explicitly in several places -- dropping them here would make
        // those guards unreachable without removing them. See the design doc.
        //
        // Deliberately does NOT rewrite the file: a write on the read path
        // would be a new failure mode for a problem nobody has, and would
        // change the user's data without being asked. The next regular save
        // omits the record anyway; until then it is skipped on every start.
        file.sessions.removeAll { $0.kind == .ssh && $0.ssh == nil }
```

- [ ] **Step 4: Confirm green**

Run: `swift test --filter SessionStore`
Expected: PASS.
Run: `swift test`
Expected: everything green. **If an existing test fails, that is a
finding** — it goes into the report, not papered over.

- [ ] **Step 5: Commit**

```bash
git add Sources/macSCPCore/Sessions/SessionStore.swift Tests/macSCPCoreTests/SessionStoreTests.swift
git commit -m "fix(core): drop an SSH record with no stored block when loading"
```

---

## Task 2: The fifteen readers and the four accessors

**Files:**
- Modify: `Sources/macSCPCore/SSH/SSHFieldSchema.swift:288-296` (`values(from:)`)
- Modify: `Sources/macSCPCore/Sessions/LoginResolver.swift:214-231` (`resolveJump`)
- Modify: `Sources/macSCPCore/Presentation/SessionListViewModel.swift:252-275` (`delete`)
- Modify: `Sources/macSCPCore/Sessions/StoredSession.swift` (the four accessors)
- Test: `Tests/macSCPCoreTests/BackendDescriptorTests.swift`

**Interfaces:**
- Consumes: the drop from Task 1 — it makes the guards unreachable in
  practice, which is why their behaviour is "defensive" rather than
  "normal".

**Everything in ONE task**, because the accessor deletion and the reader
switch must compile together.

- [ ] **Step 1: Rewrite the two M25 tests (red)**

`BackendDescriptorTests` has `anSSHSessionWithoutItsBlockStillShowsAPasswordField`
(M25). It pins that a blockless `.ssh` record produces a **filled**
bag. After this task it produces an empty one.

**Rewrite, do not delete** — to `anSSHSessionWithoutItsBlockYieldsTheEmptyBag`
or equivalent. The doc comment states what now holds, and names **M26** as
the point where the answer changed. Expectation: `visibleSecretField(for:)`
is `nil` **and** `descriptor.sessionValues(session).raw.isEmpty`.

**The `.s3`/`.webdav` twin stays unchanged** — it pins a property of the
schema, not of the accessors, and still holds.

- [ ] **Step 2: Confirm red**

Run: `swift test --filter BackendDescriptor`
Expected: the rewritten test fails (today the bag is filled).

- [ ] **Step 3: Switch over `SSHFieldSchema.values(from:)`**

The body today starts with `var values = ...` and then reads the four
accessors. Prepend:

```swift
        // A record whose kind says `.ssh` but carries no block is dropped when
        // the store loads (M26), so this cannot be reached through the app --
        // it is the structural counterpart of that rule, and it puts SSH on
        // the same footing as the other two backends, whose `sessionValues`
        // has always returned the empty bag for a missing block.
        guard let ssh = session.ssh else { return FieldValues() }
```

and switch the four lines below it from `session.` to `ssh.`:
`ssh.host`, `String(ssh.port)`, `ssh.username`, `ssh.authKind.rawValue`.
`keyPath`, `managedKeyID`, and the jump block stay as they are — they
already read via `session.ssh?` or via the accessors that remain.

- [ ] **Step 4: Switch over `LoginResolver.resolveJump`**

After the `kind == .ssh` guard and before the first read access:

```swift
        // Defensive, and unreachable in practice: a blockless `.ssh` record is
        // dropped when the store loads (M26), so `sessions` cannot contain one
        // and the lookup above would already have thrown. `.missingJumpSession`
        // is the literally correct answer either way -- from the reference's
        // point of view a dropped record IS gone.
        guard let ssh = referenced.ssh else {
            throw LoginResolveError.missingJumpSession
        }
```

Then switch the six read accesses: `referenced.authKind` → `ssh.authKind`
(twice), `referenced.username` → `ssh.username` (twice), and in
`ResolvedJump` `referenced.host`/`referenced.port` → `ssh.host`/`ssh.port`.
`referenced.keyPath` stays (a remaining accessor).

- [ ] **Step 5: Switch over `SessionListViewModel.delete`**

Inside the `if !affected.isEmpty` block, at the very top:

```swift
            // Defensive, and unreachable in practice for the same reason as
            // above: `affected` is non-empty only for `.ssh`, and a blockless
            // `.ssh` record is dropped when the store loads (M26). Skipping
            // restoration is the rule M24 established for a bastion whose
            // host cannot be read -- leave the reference dangling and let the
            // next connect say so honestly.
            guard let ssh = session.ssh else { return finishDeleting(session, secretFailures: 0) }
```

**Careful:** an early `return` here would skip the deletion itself. Check
how the body is structured after the loop, and choose the form that does
**not** skip the deletion — either an `if let ssh { … }` around the
computation and the loop (preferred, because it restructures nothing), or
an extraction of the tail into a helper. **The `finishDeleting` call above
is a sketch, not an existing function** — if you do not need the helper,
do not add it. The test from step 8 catches the bug if the deletion is
lost.

Then switch `session.username`/`session.authKind`/`session.host`/`session.port`
in this block to `ssh.`. `resolvedSSHLogin(for: session)` stays.

- [ ] **Step 6: Delete the four accessors**

In `StoredSession.swift`, remove the four lines:

```swift
    var host: String { ssh?.host ?? "" }
    var port: Int { ssh?.port ?? 22 }
    var username: String { ssh?.username ?? "" }
    var authKind: AuthKind { ssh?.authKind ?? .password }
```

**`keyPath` and `jump` stay.** Update the doc comment above the group:
it currently describes four inventing and two honest accessors; going
forward, only the two honest ones. Whatever it says about the deleted
ones goes away — no comment about code that no longer exists.

- [ ] **Step 7: Build and follow up the test readers**

Run: `swift build`
Expected: errors in **tests** that read the accessors (M25 counted 38
read sites). Follow up each individually: onto `session.ssh?.host` or
similar, or onto the fixture values, depending on what the test asserts.
**Do not weaken any test assertion** — where a test expected a fallback
value that no longer exists, the correct change is to turn the
expectation onto the real value, not to strike the assertion. Any change
that is more than re-reading the same value goes into the report.

- [ ] **Step 8: Add the `delete` test**

| Test | Setup | Expectation |
|---|---|---|
| `deletingASessionStillRemovesItWhenItsBlockIsMissing` | an `.ssh` session with no block, built **directly** via `StoredSession(...)` (comment explaining why) and saved via the store; a second session references it via `jump.sessionID`; `delete(broken)` | the session is deleted **and** the reference is unchanged. Catches the bug from step 5 if an early `return` skips the deletion |

- [ ] **Step 9: Confirm green**

Run: `swift test`
Expected: everything green, ≥ 1604.
Run: `swift build`
Expected: clean, including the App target.
Run: `grep -n "var host\|var port\|var username\|var authKind" Sources/macSCPCore/Sessions/StoredSession.swift`
Expected: no hits.

- [ ] **Step 10: Commit**

```bash
git add Sources/macSCPCore Tests/macSCPCoreTests
git commit -m "refactor(core): read the SSH block directly and retire the inventing accessors"
```

---

## Task 3: Milestone close-out

**Files:**
- Create: `docs/superpowers/specs/2026-08-08-m26-closeout.md`

- [ ] **Step 1: Full verification**

```bash
swift build
swift test
```
Note the test count (≥ 1604).

Start the Docker rig from the **main checkout**, never from a worktree:

```bash
docker compose -f docker/test-server/compose.yml up -d
MACSCP_ITEST=1 swift test
MACSCP_KEYCHAIN=1 swift test --filter Keychain
```

If a run stalls at 0% CPU, that is the hang known since M20
(`docs/superpowers/specs/2026-08-08-testsuite-hang-investigation.md`) —
abort, restart, note it in the report, do **not** count it as an M26
finding. Then check `pgrep -fl swiftpm-testing-helper`: killed runs leave
orphans behind.

Catalogs:
```bash
for f in Sources/MacSCPApp/Resources/*.lproj/Localizable.strings Sources/macSCPCore/Resources/*.lproj/Localizable.strings; do plutil -lint "$f"; done
```

- [ ] **Step 2: The counter-check**

```bash
grep -rn "\.host\b" Sources/ --include=*.swift | grep -v "URL\|url\|endpoint\|baseURL" | head -20
```

Judge whether any remaining hit still concerns `StoredSession`. Expected:
none — the accessors no longer exist, the compiler would have reported
it. The result goes into the report regardless, even if empty.

- [ ] **Step 3: Write the close-out report**

`docs/superpowers/specs/2026-08-08-m26-closeout.md`, copy the shape of
`2026-08-08-m25-closeout.md`. Must contain: the verification (test
counts, gated runs, catalogs); the spec's eight success criteria with
**evidence rather than claims**; the number of tests adjusted in Task 2
step 7 and every adjustment that was more than a re-read; every finding
from Task 1 step 4; the one release note from the spec; what remains
open (the asymmetry against `.s3`/`.webdav`, the unrepresentable state as
a possible later milestone); and the number of unpushed commits
(`git rev-list --count origin/develop..develop`).

- [ ] **Step 4: Commit, do not push**

```bash
git add docs/superpowers/specs/2026-08-08-m26-closeout.md
git commit -m "docs(m26): record the milestone close"
```

Pushing happens exclusively on the maintainer's explicit instruction.

---

## Self-review of the plan

**Spec coverage.** Criteria 1–3 → T1/Step 1; 4 → T2/Step 6 + T2/Step 9;
5 → T2/Step 6 (the two that stay) and T3/Step 2; 6 → T2/Step 1; 7 → T2/Step 7
(the finding rule) and T1/Step 4; 8 → T3/Step 1. The asymmetry against
`.s3`/`.webdav` is pinned as a **test** (T1, `aBlocklessS3RecordIsKept`), not
just as prose — otherwise a later extension would be an oversight instead
of a decision.

**Type consistency.** `guard let ssh = session.ssh` / `referenced.ssh` yields
`StoredSSHConfig` with `host`/`port`/`username`/`authKind`/`keyPath`/`jump`;
every switch reads exactly these names.

**One deliberate imprecision, disclosed rather than hidden:** Task 2 step 5
gives the guard as a sketch and explicitly states that `finishDeleting`
does **not** exist. An early `return` at this point would skip the
deletion itself, and which form is correct depends on the body the
implementer has in front of them. The test from step 8 is the bracket
that catches the bug — more reliable than a plan line I have not run
myself.
