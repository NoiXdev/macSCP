# M11a — Jump host from a saved connection Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Reference a saved connection as a jump host (picker in the jump block instead of typing); changes to the bastion take effect everywhere; deleting the bastion restores the referencing jumps without loss.

**Architecture:** `JumpSpec.sessionID: UUID?` (decode-compatible, non-nil = session mode) + resolution in `LoginResolver.resolveJump`, which reuses the existing `resolve(session:sets:secrets:)` for the LOGIN (automatically covers set/manual/agent of the referenced session); a pure eligibility function for the picker; restoration and export resolution in `SessionListViewModel` following the M10b/M10c pattern; the app wires up the toggle + picker + read-only summary.

**Tech Stack:** Swift 6 / `.swiftLanguageMode(.v5)`, Swift Testing, SwiftUI.

## Global Constraints

- Spec: `docs/superpowers/specs/2026-07-29-m11a-jump-from-saved-session-design.md` — binding. Branch: **develop**.
- REFERENCE, not a copy; NEVER share another tab's live connection (the "one connection per tab" invariant).
- ONE hop: a referenced session with its own jump is rejected (the picker filters, the resolver bars it); self-reference likewise.
- No silent fallback: a missing reference and chains are typed errors with a localized message (M10b/M10c principle).
- Secrets NEVER in JSON; slot hygiene on mode switch (session mode clears the manual `secretID` slot just like a set switch); agent logins carry no secret and read no keychain.
- `JumpSpec.sessionID` optional WITHOUT a custom decoder — legacy JSON reads nil.
- Export stays format v1: the session jump is exported RESOLVED, the reference UUID does not travel along; export never aborts.
- TOFU invariants and the M10c two-hop connect semantics stay untouched — M11a only changes WHERE the jump values come from.
- All new UI text EN/DE (both app catalogs), Core error text in both Core catalogs; code + comments English ONLY; no new dependencies.
- Conventional Commits (English), footer: `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- `swift build` + full `swift test` green after every task (starting point 595 tests / 43 suites); gated suites in T4; tests run SYNCHRONOUSLY in the foreground; TDD red→green for Core.
- Docker rig only `start`/`stop` from the main checkout.
- NO release, no merge to main.

## Schedule

T1 (Core: sessionID + resolver + eligibility) → T2 (Core: restoration + export) → T3 (App: toggle + picker + wiring + L10n) → T4 wrap-up (coordinator).

---

### Task 1: JumpSpec.sessionID + Resolver + Eligibility (Core)

**Files:**
- Modify: `Sources/macSCPCore/Sessions/StoredSession.swift`, `Sources/macSCPCore/Sessions/LoginResolver.swift`
- Create: `Sources/macSCPCore/Sessions/JumpSessionEligibility.swift`
- Test: `Tests/macSCPCoreTests/LoginResolverTests.swift` (extend), `Tests/macSCPCoreTests/JumpSessionEligibilityTests.swift` (new), `Tests/macSCPCoreTests/StoredSessionCompatTests.swift` (or whichever file holds the decode-compat tests — find it via grep for `legacySessionJSONDecodesNilJump`)

**Interfaces:**
- Consumes: `StoredSession`/`JumpSpec` (M10c), `LoginResolver.resolve(session:sets:secrets:)` + `ResolvedLogin` + `LoginResolveError` (M10b/M10d), `SecretStore`, `InMemorySecretStore`.
- Produces (T2/T3 rely on this exactly):
  - `StoredSession.JumpSpec.sessionID: UUID?` (public var, init parameter with default nil, last parameter)
  - `LoginResolveError.missingJumpSession` and `.jumpChainNotSupported` (two NEW cases; existing ones unchanged)
  - `LoginResolver.resolveJump(spec:sets:secrets:sessions:referencingSessionID:) throws -> ResolvedJump` — NEW return type `ResolvedJump` (`host: String`, `port: Int`, `login: ResolvedLogin`), because in session mode host/port are resolved too. The EXISTING `resolveJump(spec:sets:secrets:)` either stays as a thin wrapper (continuing to return `ResolvedLogin` from the spec's own values) OR is replaced — the implementer picks the smaller solution and documents it; all callers must compile.
  - `JumpSessionEligibility.eligible(for editingSessionID: UUID?, in sessions: [StoredSession]) -> [StoredSession]`

**Behavior requirements (spec §1/§2, binding):**
1. `sessionID` non-nil ⇒ session mode: host/port from the referenced session; the login via `LoginResolver.resolve(session:sets:secrets:)` of the REFERENCED session (covers its set/manual/agent). `resolve` returns `nil` for manual sessions (no set) — in that case use the session's own values + its keychain secret (agent: no secret, no keychain read).
2. Session not in the supplied list ⇒ `LoginResolveError.missingJumpSession`.
3. The referenced session itself has `jump != nil` ⇒ `.jumpChainNotSupported`. Self-reference (`sessionID == referencingSessionID`, when non-nil) ⇒ also `.jumpChainNotSupported`.
4. `sessionID == nil` ⇒ today's behavior byte-for-byte (spec's own values, set resolution, agent special case).
5. Eligibility: excludes `editingSessionID` and every session with `jump != nil`; sorted by name case-insensitively (sidebar order).
6. Decode compatibility: `sessions.json` without `sessionID` reads nil; a round trip preserves the value.
7. Two new CoreL10n messages (both catalogs): `core.connect.jumpSessionMissing` (EN "The connection used as jump host no longer exists." / DE „Die als Zwischenhost genutzte Verbindung existiert nicht mehr.") and `core.connect.jumpChainNotSupported` (EN "The selected jump host connects through another jump host; chains are not supported." / DE „Die gewählte Verbindung nutzt selbst einen Zwischenhost; Ketten werden nicht unterstützt.").

- [x] **Step 1: Failing tests**

```swift
    // LoginResolverTests (additions):
    // resolveJumpFromSessionUsesItsHostAndLogin: bastion session
    //   (host "b", port 2022, user "deploy", .password, secret "s")
    //   + jump spec with sessionID -> ResolvedJump(host "b", port 2022,
    //   login.username "deploy", login.secret "s").
    // resolveJumpFromSessionWithLoginSet: bastion references a set ->
    //   values + secret of the SET.
    // resolveJumpFromAgentSessionReadsNoKeychain: bastion with .agent ->
    //   login.authKind == .agent, secret nil, NoReadAllowedSecretStore double
    //   trips if it is read after all.
    // resolveJumpMissingSessionThrows: sessionID points at an unknown UUID
    //   -> LoginResolveError.missingJumpSession.
    // resolveJumpChainThrows: the referenced session itself has a jump
    //   -> .jumpChainNotSupported.
    // resolveJumpSelfReferenceThrows: sessionID == referencingSessionID
    //   -> .jumpChainNotSupported.
    // resolveJumpManualUnchanged: sessionID nil -> exactly the previous
    //   values (regression guard for all three auth kinds).
    //
    // JumpSessionEligibilityTests:
    // excludesEditedSessionAndChains: four sessions (A without jump, B without
    //   jump, C with jump, D == the one being edited) -> [A, B] in name
    //   order.
    // nilEditingIDKeepsAll: editingSessionID nil -> only chains are filtered.
    //
    // Decode-compat file:
    // legacyJumpJSONDecodesNilSessionID: raw sessions.json with a jump object
    //   WITHOUT sessionID -> jump?.sessionID == nil, other fields intact.
```

- [x] **Step 2: Prove red.** `swift test --filter LoginResolverTests` and `--filter JumpSessionEligibility` → FAIL.
- [x] **Step 3: Implementation** (model → eligibility → resolver; document the wrapper decision from the interfaces block).
- [x] **Step 4: Green + full suite.** `swift test` → 595 + new.
- [x] **Step 5: Commit.** `feat: reference a saved connection as the jump host`

---

### Task 2: Restoration on delete + export resolution (Core)

**Files:**
- Modify: `Sources/macSCPCore/Presentation/SessionListViewModel.swift`
- Test: `Tests/macSCPCoreTests/SessionListViewModelTests.swift`

**Interfaces:**
- Consumes (T1): `JumpSpec.sessionID`, `ResolvedJump`, `LoginResolver.resolveJump(…sessions:referencingSessionID:)`, `LoginResolveError.missingJumpSession/.jumpChainNotSupported`.
- Produces (T3):
  - `SessionListViewModel.sessionsUsingAsJump(_ id: UUID) -> [StoredSession]` (for the delete confirmation)
  - `delete(_:) -> JumpRestoreResult` (`restored: Int`, `secretFailures: Int`, Equatable) — existing callers ignore the return value (`@discardableResult`)
  - `resolvedJump(for session: StoredSession) throws -> ResolvedJump?` (nil when there is no jump; throws the typed errors) — T3 uses it for the form summary and connect

**Behavior requirements (spec §4/§5, binding):**
1. `delete(_:)` collects, BEFORE deleting, the sessions with `jump?.sessionID == session.id`. For each: copy the DELETED session's host/port/username/authKind/keyPath into its JumpSpec, write its resolved secret into the jump's `secretID` slot, null out `sessionID`, set the JumpSpec's `loginSetID` to nil (the restoration writes concrete values, not a set reference), upsert. Only then delete the session itself (order: persist the restoration first, then delete — a failure during deletion must not leave a half-restored world; justify in the report if the other order is chosen instead).
2. Agent logins of the deleted session carry NO secret across (no keychain read, no write).
3. Keychain errors during the secret transfer count in `secretFailures`, do not abort; the session is restored regardless (M10b pattern, including the B2 lesson: never delete/move a secret whose replacement write failed — here nothing is deleted, only copied).
4. `exportPayload`: sessions with a session jump export the RESOLVED jump values (`resolveJump` with the session list); `jumpPassword` only with `includePasswords`; a missing/broken reference ⇒ the spec's own values, export never aborts; a missing secret counts in `missingPasswordCount`. Format stays v1, the reference does NOT travel along.
5. `reload()`/remaining APIs unchanged.

- [x] **Step 1: Failing tests**

```swift
    // deleteRestoresJumpReferences: bastion session (user/pass "s"),
    //   two sessions reference it as jump -> delete(bastion):
    //   both carry the bastion's host/port/user/authKind in their JumpSpec,
    //   secret "s" in the jump.secretID slot, sessionID == nil, loginSetID == nil;
    //   result restored == 2, secretFailures == 0.
    // deleteRestoresFromAgentBastionWithoutSecret: bastion with .agent ->
    //   JumpSpec carries .agent, no secret written (NoReadAllowed double).
    // deleteCountsSecretFailure: SecretStore double whose savePassword for
    //   the jump slot throws -> restored == 1, secretFailures == 1, values
    //   restored regardless.
    // sessionsUsingAsJumpFindsReferences: returns exactly the referencing ones.
    // exportResolvesSessionJump: session with a session jump ->
    //   ExportedSession carries the bastion's host/port/user + jumpPassword
    //   (includePasswords true); broken reference -> spec's own values,
    //   no abort.
```

- [x] **Step 2: Prove red.** `swift test --filter SessionListViewModelTests` → FAIL.
- [x] **Step 3: Implementation.** **Step 4: Green + full suite.** **Step 5: Commit** `feat: restore jump references when their connection is deleted`.

---

### Task 3: Toggle + picker + wiring + L10n (App)

**Files:**
- Modify: `Sources/macSCPCore/Presentation/ConnectionViewModel.swift` (fields + validation + JumpSpec building), `Sources/MacSCPApp/ConnectionFormView.swift` (toggle, picker, summary), `Sources/MacSCPApp/ContentView.swift` (connect resolution, save paths, edit pre-fill, delete confirmation, error mapping), `Sources/MacSCPApp/SessionSidebar.swift` (delete confirmation text, if worded there — find via grep), `Sources/MacSCPApp/Resources/en.lproj/Localizable.strings` + `de.lproj`
- Test: three Core tests for the new VM fields/validation (see below); otherwise none (app target; smoke in T4)

**Interfaces:**
- Consumes (T1/T2): `JumpSessionEligibility.eligible(for:in:)`, `ResolvedJump`, `resolvedJump(for:)`, `sessionsUsingAsJump(_:)`, `delete(_:) -> JumpRestoreResult`, the two new `LoginResolveError` cases; existing: the M10c jump block, `showFailure`, `fillJumpForm`, the M10b/M10d segment patterns.

**Behavior requirements (spec §3, binding):**
1. `ConnectionViewModel`: `jumpSourceMode: JumpSourceMode` (`.session`/`.manual`, default `.manual`), `jumpSessionID: UUID?`. `exitEditMode()`/`endEditing()` reset BOTH (M10b sticky-state lesson). New `Field` case `.jumpSession` for highlighting.
2. Validation in `connect()` AND `validateForEditSave()`: when `jumpEnabled && jumpSourceMode == .session`, a selection is required (`jumpSessionID != nil`, otherwise `.failed` with `.jumpSession`); the manual checks (host/port/login) are skipped entirely in this mode. `buildJumpSpec` sets `sessionID` and leaves the manual fields untouched (they are ignored); `buildJumpConfig` is NO LONGER built from the form fields in session mode — the app fills the jump fields before connecting, from the resolution (point 4a).
3. Form: segmented toggle "Saved connection | Manual" above the jump host row. Session mode: picker over `JumpSessionEligibility.eligible(for: <the session being edited, or nil>, in: sessionListViewModel.sessions)` (display: session name), below it a non-editable summary `host:port · user · <auth short form>` from `resolvedJump`; on a resolution error, the localized error message appears there in red instead of the summary. Manual mode: today's block unchanged.
4. Wiring in ContentView:
   a. Before `form.connect()`, in session mode resolve the reference and fill host/port/login into the jump form fields (`fillJumpForm` pattern); errors (`missingJumpSession`/`jumpChainNotSupported`) ⇒ `showFailure` with the respective message and field `.jumpSession`, NO connect.
   b. `connect(in:stored:)`: `resolvedJump(for: stored)` — non-nil fills the jump fields; either error ⇒ do not connect, show the message.
   c. Edit pre-fill: `jump?.sessionID` set ⇒ `jumpSourceMode = .session` + pre-selection; otherwise `.manual` (today's pre-fill).
   d. The sidebar's delete confirmation additionally names the number of referencing connections when `sessionsUsingAsJump` is non-empty (EN "%lld connections use this connection as their jump host and will keep its data directly." / DE „%lld Verbindungen nutzen diese Verbindung als Zwischenhost und behalten deren Daten direkt hinterlegt."); `secretFailures > 0` after deletion ⇒ a red message like the login-set delete.
5. All new keys EN/DE in both app catalogs (+ the two Core keys from T1); grep cross-check for key-set equality.

- [x] **Step 1:** VM fields + validation + 3 tests (`jumpSessionModeRequiresSelection`, `jumpSessionModeSkipsManualChecks`, `jumpSourceFieldsResetOnExitEditMode`) red→green. **Step 2:** Form (toggle, picker, summary). **Step 3:** ContentView wiring a–d. **Step 4:** L10n + cross-check. **Step 5:** `swift build` (0 errors, no new warnings) + full `swift test`. **Step 6:** Commit `feat: pick a saved connection as the jump host in the form`.

---

### Task 4: Closing verification (coordinator)

- [x] Add a gated rig test (in the existing Docker suite): saved bastion session (127.0.0.1:2222) as a `sessionID` jump for a target on `sshd2:2222` ⇒ `list("/")` ok; second test: bastion session with its own jump ⇒ `jumpChainNotSupported` (no network access).
- [x] Rig `start`, `MACSCP_ITEST=1 MACSCP_KEYCHAIN=1 swift test` → all green, zero skips, no leftovers (ssh-agent, temp directories); rig `stop`.
- [ ] Visual smoke — delegated to the maintainer (checklist: toggle + picker, connecting via a saved bastion, deleting the bastion ⇒ the confirmation names the count ⇒ the connection keeps working afterward, chain rejection, export/import of a session with a session jump).
- [x] Plan checkboxes, ledger, Opus final review (package based on `git merge-base origin/develop HEAD`), fix rounds until "Yes", push develop, `gh run watch`, memory, summary. NO release.
