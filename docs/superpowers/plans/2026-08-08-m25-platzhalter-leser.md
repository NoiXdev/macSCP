# M25 — The Last Placeholder Readers Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Clear out the five unguarded readers of `StoredSession.host`/`port`/
`username`/`authKind` in `SessionListViewModel`, and then use a compiler probe
to decide whether the four accessors can be deleted.

**Architecture:** One of the three sites isn't a protocol problem at all
(`delete` computes values it never uses when `affected` is empty — hoist it
out). The other two ask the same question in SSH vocabulary; that gets a
member on `BackendDescriptor` that serves three call sites.

**Tech Stack:** Swift 6 (`.swiftLanguageMode(.v5)`), SwiftPM, macOS 15+,
Swift Testing (`@Test`/`#expect`).

**Spec:** `docs/superpowers/specs/2026-08-08-m25-platzhalter-leser-design.md`

## Global Constraints

- **Code and comments: English only.** Identifiers, doc comments, inline
  comments, test names. No German in source files.
- **Commit messages: English, Conventional Commits.** Footer on every commit:
  `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`
- **Commit/push only on explicit request.** No `scripts/release`.
- **A secret value must never be logged, printed, or embedded in an error.**
  Secrets live exclusively in the Keychain; never in JSON stores.
- **Do not start the GUI app.** Never commit key material.
- `swift build` stays clean **including the App target**. Test count **≥ 1587**.
- **No new localization keys.** The four app catalogs keep identical key sets
  (`LocalizableStringsTests` enforces it).
- Build sessions in tests **only** via the fixtures in
  `Tests/macSCPCoreTests/SessionFixtures.swift` (`sshSession`,
  `s3Session`, `webdavSession`), never `StoredSession` directly.
- **M25 is a pure internal restructuring.** Any observed behavior change is a
  finding and belongs in the report, not silently written away.

---

## File Structure

| File | Responsibility | Task |
|---|---|---|
| `Sources/macSCPCore/Presentation/SessionListViewModel.swift` | hoist `delete`; `updateSession`/`exportPayload` onto the new member | 1, 3 |
| `Sources/macSCPCore/Capabilities/BackendDescriptor.swift` | `visibleSecretField(for:)` | 2 |
| `Sources/macSCPCore/Connection/StoredSessionConnectionConfig.swift` | fold the spelled-out copy onto the member | 2 |
| `Sources/macSCPCore/Sessions/StoredSession.swift` | delete the four accessors if applicable | 4 |
| `docs/superpowers/specs/2026-08-08-m25-abschluss.md` | closing report | 4 |

New tests belong in the existing suite of the type under test
(`SessionListViewModelTests`, `BackendDescriptorTests`). **No new test file.**

## Why the tests are laid out as a table

M23 and M24 together found fourteen defects that were sitting **in the
plan** and not in the implementation — almost all in never-executed test
code. Production code therefore stands below verbatim, tests as a table
(name, setup, expectation) plus a pointer to the shape to copy. Whoever
writes the test also runs it.

---

## Task 1: `delete` only computes when there is something to restore

**Files:**
- Modify: `Sources/macSCPCore/Presentation/SessionListViewModel.swift:244-290`
- Test: `Tests/macSCPCoreTests/SessionListViewModelTests.swift`

**Interfaces:**
- Produces: nothing new. `delete(_:) -> JumpRestoreResult` keeps its
  signature and semantics.

**Why this is not a descriptor case:** `bastionUsername`, `bastionAuthKind`,
`bastionKeyPath` and `bastionSecret` are read **exclusively** in the loop
over `affected`. Since M24, `affected` is empty for every non-SSH session.
The computation is therefore dead work — including a Keychain access that,
for an S3 session, fetches its **Secret Access Key** and discards it.

- [ ] **Step 1: Write the test (red)**

Append to `SessionListViewModelTests`. For the read-hostile store, copy the
shape at the end of `Tests/macSCPCoreTests/LoginMergePlannerTests.swift`
(a `SecretStore` whose `password(for:)` fails the test via `Issue.record`).

| Test | Setup | Expectation |
|---|---|---|
| `deletingANonSSHSessionNeverReadsTheKeychain` | one `s3Session`, stored, **no** referencing session; ViewModel with a read-hostile `SecretStore`; `delete(bucket)` | not a single `password(for:)` call; `result.restored == 0`; the session is deleted. **Without the hoist it fails**, because `bastionSecret` is read unconditionally today |

- [ ] **Step 2: Confirm red**

Run: `swift test --filter SessionListViewModel`
Expected: `deletingANonSSHSessionNeverReadsTheKeychain` fails with the
store's `Issue.record`.

- [ ] **Step 3: Pull the computation and the loop into a guard**

Replace the block from `// The deleted session's effective login, …` through
the end of the `for referencing in affected` loop. `var secretFailures = 0`
stays **outside**, because the return value needs it:

```swift
        var secretFailures = 0
        // Nothing below is needed unless something actually references this
        // session as its bastion, and since M24 `affected` is empty for every
        // non-SSH session. Computing it anyway was not merely wasted work: the
        // `secrets.password(for:)` call reaches into the Keychain, and for an
        // `.s3` session the slot it reads holds that session's SECRET ACCESS
        // KEY -- fetched only to be discarded. A read of a secret nobody needs
        // is one read too many.
        if !affected.isEmpty {
            // The deleted session's effective login, via `resolvedSSHLogin(for:)`:
            // nil for a manual session (use its own fields + own keychain secret
            // below), a set's values otherwise. An
            // agent session/set reads no keychain at all (M10d rule).
            let resolvedBastionLogin = resolvedSSHLogin(for: session)
            let bastionUsername = resolvedBastionLogin?.username ?? session.username
            let bastionAuthKind = resolvedBastionLogin?.authKind ?? session.authKind
            let bastionKeyPath = resolvedBastionLogin?.keyPath ?? session.keyPath
            var bastionSecret: String?
            if let resolvedBastionLogin {
                bastionSecret = resolvedBastionLogin.secret
            } else if session.authKind != .agent {
                bastionSecret = (try? secrets.password(for: session.id)) ?? nil
            }

            for referencing in affected {
                guard var jump = referencing.jump else { continue }
                jump.host = session.host
                jump.port = session.port
                jump.username = bastionUsername
                jump.authKind = bastionAuthKind
                jump.keyPath = bastionKeyPath
                jump.loginSetID = nil
                jump.sessionID = nil

                var hadSecretFailure = false
                if let bastionSecret {
                    do {
                        try secrets.savePassword(bastionSecret, for: jump.secretID)
                    } catch {
                        hadSecretFailure = true
                    }
                }

                var updated = referencing
                // `referencing.jump` was non-nil above, so the SSH block exists:
                // only an SSH session can carry a jump at all since M23/T8.
                updated.ssh?.jump = jump
                // Throw-free by design (M10b pattern): a store-write failure for
                // one referencing session must not abort restoring the others,
                // nor the deletion that follows.
                try? store.upsert(updated)
                if hadSecretFailure {
                    secretFailures += 1
                }
            }
        }
```

- [ ] **Step 4: Confirm green**

Run: `swift test --filter SessionListViewModel`
Expected: PASS — **including the existing `delete` tests, unchanged.**
If an existing `delete` test needs touching, the hoist shifted behavior:
that is a **finding** for the task report, not a test adjustment.

- [ ] **Step 5: Commit**

```bash
git add Sources/macSCPCore/Presentation/SessionListViewModel.swift Tests/macSCPCoreTests/SessionListViewModelTests.swift
git commit -m "perf(core): compute a bastion's login only when something references it"
```

---

## Task 2: The schema question gets a name

**Files:**
- Modify: `Sources/macSCPCore/Capabilities/BackendDescriptor.swift` (new member next to `hasStoredConfiguration`)
- Modify: `Sources/macSCPCore/Connection/StoredSessionConnectionConfig.swift:108-112`
- Test: `Tests/macSCPCoreTests/BackendDescriptorTests.swift`

**Interfaces:**
- Produces: `BackendDescriptor.visibleSecretField(for session: StoredSession) -> ConnectionField?`
  — Task 3 calls it twice.

- [ ] **Step 1: Write the tests (red)**

Append to `BackendDescriptorTests`. Sessions via the fixtures; for SSH set
the auth kind via `sshSession(..., authKind:)`.

| Test | Setup | Expectation |
|---|---|---|
| `sshAgentSessionShowsNoSecretField` | `sshSession(authKind: .agent)` | `visibleSecretField(for:) == nil` |
| `sshPasswordSessionShowsItsPasswordField` | `sshSession(authKind: .password)` | field `id` is `SSHField.password.rawValue` |
| `sshPrivateKeySessionShowsItsPassphraseField` | `sshSession(authKind: .privateKey, keyPath: "/k")` | field `id` is `SSHField.passphrase.rawValue` |
| `s3SessionAlwaysShowsItsSecretField` | `s3Session(name:)` | field `id` is `S3Field.secretAccessKey.rawValue` |
| `webdavSessionAlwaysShowsItsPasswordField` | `webdavSession(name:)` | field `id` is `WebDAVField.password.rawValue` |
| `anSSHSessionWithoutItsBlockStillShowsAPasswordField` | an `.ssh` session **without** its SSH block — build it **directly** via `StoredSession(id:name:groupID:loginSetID:kind:)` for this (the one allowed exception to the fixture rule, because no fixture produces a blockless state; comment in the test why) | field `id` is `SSHField.password.rawValue` — pins the spec's equivalence table: `sessionValues` reads through the fallbacks into a populated bag, the result is the same as today |

- [ ] **Step 2: Confirm red**

Run: `swift test --filter BackendDescriptor`
Expected: compile error — the member doesn't exist.

- [ ] **Step 3: Add the member**

In `BackendDescriptor.swift`, right **after** `hasStoredConfiguration(_:)`:

```swift
    /// The secret field this stored session currently shows, or nil when it
    /// needs none (M25).
    ///
    /// The schema's answer to "does this login carry a secret at all", asked
    /// WITHOUT `StoredSession.authKind` — which for a `.s3`/`.webdav` session
    /// fabricates `.password`, the placeholder M23 set out to remove. Only
    /// ssh-agent shows no secret field, so the nil case IS the agent case for
    /// SSH and never arises for the other two backends.
    ///
    /// Deliberately does NOT ask `hasStoredConfiguration` itself. Its three
    /// callers want different things from a session whose block is missing —
    /// the CLI refuses it, both view-model paths carry on — and a member that
    /// guards sometimes would be worse than three callers asking their own
    /// question. What it DOES inherit is `sessionValues`'s asymmetry: for
    /// `.ssh` a missing block still reads through `StoredSession`'s own
    /// fallbacks into a POPULATED bag, while `.s3`/`.webdav` yield an empty
    /// one (see `sessionValues(_:)`).
    public func visibleSecretField(for session: StoredSession) -> ConnectionField? {
        credentialSchema.visibleSecretField(
            in: sessionValues(session), namespace: fieldNamespace)
    }
```

- [ ] **Step 4: Fold the spelled-out copy in the CLI path**

In `StoredSessionConnectionConfig.build`, replace the two lines

```swift
        let secretField = descriptor.credentialSchema.visibleSecretField(
            in: values, namespace: descriptor.fieldNamespace)
```

with

```swift
        let secretField = descriptor.visibleSecretField(for: session)
```

The long comment block above it stays **unchanged** — it explains the
secret rule, not the spelling. The member recomputes `sessionValues` a
second time in the process (`values` is already there); that is a pure
dictionary build with no side effect, and one rule in one place is worth it.

- [ ] **Step 5: Confirm green**

Run: `swift test --filter "BackendDescriptor|StoredSessionConnectionConfig"`
Expected: PASS.
Run: `swift build`
Expected: clean including the App target.

- [ ] **Step 6: Commit**

```bash
git add Sources/macSCPCore Tests/macSCPCoreTests/BackendDescriptorTests.swift
git commit -m "feat(core): let the descriptor say whether a session carries a secret"
```

---

## Task 3: The two call sites in the ViewModel

**Files:**
- Modify: `Sources/macSCPCore/Presentation/SessionListViewModel.swift:336` (`updateSession`) and `:772` + `:791` (`exportPayload`)
- Test: `Tests/macSCPCoreTests/SessionListViewModelTests.swift`

**Interfaces:**
- Consumes: `BackendDescriptor.visibleSecretField(for:)` from Task 2.

**This task's trap** is in the spec and is repeated here because it's the
only way to get the task wrong: in `exportPayload`, the agent-ness of a
**set-bound** session comes from the SET (`resolved?.authKind`), not from
the session. Anyone who replaces the whole line with a schema question
against the session's own values suddenly has a session behind an
agent set looking for a secret, and it gets counted in the user-visible
"N passwords missing". **Only the fallback branch is replaced.**

- [ ] **Step 1: Write the tests (red)**

| Test | Setup | Expectation |
|---|---|---|
| `updateSessionClearsALeftoverSlotWhenSwitchingToAgent` | `sshSession(authKind: .password)` stored, secret under the session ID; the same session with `authKind: .agent` via `updateSession(_:newSecret: nil)` | no secret sits under the session ID anymore |
| `updateSessionKeepsAnS3SessionsSecret` | `s3Session` stored, secret under the session ID; `updateSession(_:newSecret: nil)` with the session renamed | the secret is still sitting there unchanged. **Without the right restructuring it disappears** if someone asks the question the wrong way round |
| `updateSessionKeepsAWebDAVSessionsSecret` | as above with `webdavSession` | ditto |
| `exportingASessionBoundToAnAgentLoginSetCarriesNoPasswordAndCountsNone` | a `LoginSet` with `authKind: .agent`, an `sshSession(loginSetID:)` bound to it, export with `includePasswords: true` | the exported session carries no password **and** `missingPasswordCount == 0`. **This is success criterion 4** — the test a blanket restructuring would turn red |
| `exportingAManualAgentSessionCarriesNoPasswordAndCountsNone` | `sshSession(authKind: .agent)`, not set-bound, export with `includePasswords: true` | ditto — this is where the new schema branch applies |

Copy the export tests' setup from the existing `exportPayload` tests in the
same file (search term `includePasswords`).

- [ ] **Step 2: Confirm red**

Run: `swift test --filter SessionListViewModel`
Expected: the agent export tests and at least one of the secret-preservation
tests do not fail yet — they partly describe today's behavior. **That is
fine and is the point:** they are the regression clamp for Step 3. Which
ones are red and which are already green belongs in the task report.

- [ ] **Step 3: Restructure `updateSession`**

```swift
            if BackendDescriptor.descriptor(for: updated.kind)
                .visibleSecretField(for: updated) == nil {
                // No secret field on screen means this login needs none, which
                // today is ssh-agent and nothing else (M10d) -- clean up a
                // leftover manual slot from before the switch. Asking the
                // schema rather than `updated.authKind` keeps a `.s3`/`.webdav`
                // session out of this branch by its own declaration instead of
                // by the accident that its fabricated auth kind is not `.agent`.
                try? secrets.deletePassword(for: updated.id)
            } else if let newSecret, !newSecret.isEmpty {
```

- [ ] **Step 4: Restructure `exportPayload`**

The binding

```swift
            let authKind = resolved?.authKind ?? session.authKind
```

**gets removed outright without replacement** — within this function it is
read at exactly one place, namely the guard below (double-checked: the other
two `authKind` occurrences are `resolved.authKind.rawValue` for the field
bag, and the jump's own `authKind`). Instead:

```swift
            // Whether a secret can be fetched at all. The two branches are NOT
            // interchangeable: for a set-bound session the agent-ness belongs
            // to the SET, so asking the schema about the SESSION's own values
            // would make a session behind an agent set start looking for a
            // secret and count itself in the user-visible "N passwords
            // missing". Only the fallback -- the manual session, which is where
            // `StoredSession.authKind` used to be read -- becomes a schema
            // question. The `.agent` comparison on `ResolvedLogin` stays: that
            // type is SSH-shaped on purpose since M22/T9, and is not one of
            // the placeholder accessors.
            let needsSecret = resolved.map { $0.authKind != .agent }
                ?? (BackendDescriptor.descriptor(for: session.kind)
                        .visibleSecretField(for: session) != nil)
```

and in the guard replace `authKind != .agent` with `needsSecret`:

```swift
            if includePasswords, needsSecret, session.kind != .s3,
                session.kind != .webdav || session.webdav != nil {
```

The two `session.kind` conditions stay **untouched** (spec: they are format
logic, and M23/P3 deliberately restored them after a finding).

- [ ] **Step 5: Confirm green**

Run: `swift test --filter SessionListViewModel`
Expected: PASS.
Run: `swift test`
Expected: everything green, ≥ 1587.
Run: `swift build`
Expected: clean including the App target.

- [ ] **Step 6: Commit**

```bash
git add Sources/macSCPCore/Presentation/SessionListViewModel.swift Tests/macSCPCoreTests/SessionListViewModelTests.swift
git commit -m "refactor(core): ask the schema, not authKind, whether a session has a secret"
```

---

## Task 4: The probe and the close-out

**Files:**
- Modify: possibly `Sources/macSCPCore/Sessions/StoredSession.swift` (the four accessors)
- Create: `docs/superpowers/specs/2026-08-08-m25-abschluss.md`

- [ ] **Step 1: Run the probe**

Temporarily attach to the four accessors `host`, `port`, `username`,
`authKind` in `StoredSession.swift`:

```swift
    @available(*, deprecated, message: "M25 probe — every reader must be SSH-guarded")
```

Then `swift build 2>&1 | grep -A 2 deprecated`. **One compiler run, not a
`grep` on `.host`** — M24 showed that the grep returns 241 hits, most of
which are URLs and unrelated types.

- [ ] **Step 2: Judge every hit**

For each reported reader, decide: **guarded** (sits behind
`kind == .ssh`, or is `SSHFieldSchema.values(from:)`, the sanctioned
reader) or **unguarded**. The full list with file and line goes into the
report — even if it is empty.

- [ ] **Step 3: Decide and act**

- **All guarded** → delete the four accessors **and** the `@available`,
  then `swift test` and `swift build` again. If something breaks, a reader
  wasn't guarded after all: revert and report it the same way as the other
  case.
- **At least one unguarded** → remove the `@available` again, the
  accessors stay, and **every unguarded reader is named by file and line
  in the report**.

Either is a valid outcome. The spec promises the check, not the deletion —
don't force the outcome.

- [ ] **Step 4: Full verification**

```bash
swift build
swift test
```
Note the test count (≥ 1587).

Start the Docker rig from the **main checkout**, never from a worktree:

```bash
docker compose -f docker/test-server/compose.yml up -d
MACSCP_ITEST=1 swift test
MACSCP_KEYCHAIN=1 swift test --filter Keychain
```

If a run stalls at 0% CPU, that is the hang known since M20
(`docs/superpowers/specs/2026-08-08-testsuite-haenger-untersuchung.md`) —
abort, restart, note it in the report, **do not** count it as an M25
finding. Afterward check that no orphan process was left behind:
`pgrep -fl swiftpm-testing-helper`.

Catalogs:
```bash
for f in Sources/MacSCPApp/Resources/*.lproj/Localizable.strings Sources/macSCPCore/Resources/*.lproj/Localizable.strings; do plutil -lint "$f"; done
```

- [ ] **Step 5: Write the closing report**

`docs/superpowers/specs/2026-08-08-m25-abschluss.md`, copy the shape of
`2026-08-08-m24-abschluss.md`. Must contain: the verification (test counts,
gated runs, catalogs); the spec's seven success criteria with **evidence,
not assertion**; the full result of the probe; every finding from Task 1
Step 4 and Task 3 Step 2; what remains open; and the count of unpushed
commits (`git rev-list --count origin/develop..develop`).

- [ ] **Step 6: Commit, do not push**

```bash
git add docs/superpowers/specs/2026-08-08-m25-abschluss.md
git commit -m "docs(m25): record the milestone close"
```

The push happens only on the maintainer's explicit order.

---

## Plan self-review

**Spec coverage.** Criterion 1 → T1; 2 → T1/Step 4 (regression clamp);
3 → T3; 4 → T3 (the set-bound agent export); 5 → T2/Step 4; 6 → T4;
7 → T4/Step 4. The new descriptor member → T2. The format guards
deliberately left untouched are an omission and stand as such in
T3/Step 4.

**Type consistency.** `visibleSecretField(for session: StoredSession) ->
ConnectionField?` is defined in T2 and called exactly the same way in
T2/Step 4, T3/Step 3 and T3/Step 4. `BackendDescriptor.descriptor(for:)` is
the existing registry function.

**One deliberate deviation from the skill directive:** test code stands as
a table instead of as source, with a pointer to the shape to copy.
Rationale above in its own section.

**One deliberate exception to a rule of its own:** the test
`anSSHSessionWithoutItsBlockStillShowsAPasswordField` builds `StoredSession`
directly instead of via a fixture, because no fixture produces a blockless
state. The test comments on that.
