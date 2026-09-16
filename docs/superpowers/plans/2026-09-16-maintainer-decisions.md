# Maintainer decisions of 2026-09-16 — implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Carry out three decisions the maintainer made on 2026-09-16: host-key fingerprints no longer reach the diagnostic log (or any other place the fixed reason sentence is persisted); a PEM conversion on a login-set session offers to re-point the set itself, after a confirmation; and the passphrase-slot rule after a re-point is recorded as decided. The fourth decision (measure "At login" with a signed build and a real login) is a manual measurement outside this plan; its outcome is recorded in Task 3.

**Architecture:** Task 1 changes one arm of `DialSupport.reason(for:)` (`Sources/macSCPCore/Diagnostics/DialProbes.swift:207`) and pins it with a test. Task 2 adds a pure App plan type that decides whether and how to offer the set re-point, a confirmation dialog in `ContentView+Sheets.swift`, one Core method that drops a login set's own Keychain slot, and the wiring in `ContentView.convertedKeyImported(_:for:)`. Task 3 records the decisions in the design and the backlog.

**Tech Stack:** Swift 6 strict, SwiftPM, Swift Testing, SwiftUI (`MacSCPAppKit`), macOS 15.

## Global Constraints

- The decisions, verbatim from the maintainer on 2026-09-16: (1) login-set session with a PEM key → "Set umhängen, nachfragen" — a confirmation names the set and how many sessions use it; yes re-points the set's key path to the managed key, no keeps the one-attempt behaviour; (2) passphrase slot after re-pointing → "Ja, löschen" — confirmed as built; (3) host-key fingerprints in the diagnostic log → "Weglassen" — the log line names the host and the mismatch, the App's mismatch alert keeps showing both fingerprints; (4) "At login" → measure with a signed build and a real login first.
- Derived from decision 2 and applied to decision 1, stated so the reviewer can reject it: after a login set is re-pointed, the SET's own Keychain slot (under `set.id`) is dropped when `ManagedKeyPassphrase.hasStoredPassphrase` says the managed key's slot holds the passphrase — one passphrase, one place, for every session the set serves. When the probe says no (or throws), the set's slot stays.
- TOFU untouched; the only dial is `retryConnect(_:)` → `connect(in:stored:)`. A mismatch stays a hard stop. `CLIErrorMapping` (the CLI's stderr to the person at the terminal) and the App's `core.hostkey.mismatch %@ %@ %@` alert keep both fingerprints — they are shown to the person deciding, not persisted.
- No secret in any store, state, log, reason string or test failure message; no real host name in tests.
- Every App string through `L10n.string(_:_:)` in `en`, `de`, `fr`, `pl` (German du-form); a count goes through `Localizable.stringsdict` in all four catalogs the way `tabs.closeOthers.activeTransfers %1$lld %2$lld` does (`pl` carries `one`/`few`/`many`/`other`).
- Swift Testing, red first (recorded), every wait an `await`, no wall-clock ceiling, no `#require` on a non-optional. Source-scanning guards read `SwiftSource.blankingCommentsAndStrings` (App) / `stripCommentsAndStrings` (Core); a negative check has a positive beside it; probes are reverted with a file-scoped reverse patch, never `git checkout` on a file holding edits.
- Comments naming counts or callers are counted in the same pass; scripted edits assert their anchor; the report is written from `git diff --numstat` and `grep -n`.
- Zero warnings (`swift build --build-tests`). Conventional Commits, English, footer exactly `Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>`. Do not push; do not launch the GUI.

---

### Task 1: The mismatch reason names the host, not the fingerprints

**Files:**
- Modify: `Sources/macSCPCore/Diagnostics/DialProbes.swift` (`DialSupport.reason(for:)`, the `HostKeyError.mismatch` arm, ~212)
- Modify: every comment that quotes the old sentence (grep `expected \\(expected), got` and `MISMATCH for` across `Sources` and `Tests`; `HostKeyError.mismatch`'s own doc; `docs/BACKLOG.md` is Task 3's)
- Test: the existing test that asserts the mismatch sentence (grep `MISMATCH for` in `Tests`; `DiagnosticLogSharedSinkTests.swift` names it today) and one new case in the suite that tests `DialSupport.reason(for:)`

**Interfaces:**
- Produces: `DialSupport.reason(for: HostKeyError.mismatch(host:expected:presented:))` returns exactly `host key MISMATCH for <host>: the presented key differs from the recorded one`.

- [x] **Step 1: Failing test.** A case building `HostKeyError.mismatch(host: "rig.invalid", expected: <fixed fingerprint constant A>, presented: <fixed fingerprint constant B>)` asserts the sentence equals the new text and — as named Bools computed first — contains neither constant. Update the existing assertion of the old sentence to the new one. Run → red (record the first failing line).
- [x] **Step 2: Find every consumer of the sentence** (`grep -rn "DialSupport.reason(for:" Sources`) and write in the report which of them PERSIST it (diagnostic log, audit rows via `lastFailureReason`, the tunnel failure reason, the diagnostics report) and which DISPLAY it; the change covers all of them by construction. State in the report which surface, if any, loses the fingerprints a person saw before (the tunnel profile's failure reason is the candidate) and what that surface still offers (the known-hosts sheet).
- [x] **Step 3: Implement** the one arm; fix every comment that quoted the old sentence.
- [x] **Step 4: Run** the filter, then `swift test` whole suite green, zero warnings. Probe: restore `expected \(expected)` in the sentence → the new case red.
- [x] **Step 5: Commit** `fix(diagnostics): a host-key mismatch reason names the host, never the fingerprints`.

---

### Task 2: A PEM conversion on a login-set session offers to re-point the set

**Files:**
- Create: `Sources/MacSCPAppKit/LoginSetRepointPlan.swift`
- Modify: `Sources/macSCPCore/Presentation/SessionListViewModel.swift` (add `dropLoginSetSecret(for:)` beside `dropSessionSecret(for:)`)
- Modify: `Sources/MacSCPAppKit/ContentView.swift` (`convertedKeyImported(_:for:)`; a `@State var setRepointRequest: LoginSetRepointRequest?`; `repointLoginSet(_:)`, `convertForThisAttemptOnly(_:)`)
- Modify: `Sources/MacSCPAppKit/ContentView+Sheets.swift` (the confirmation dialog)
- Modify: the four App catalogs `Localizable.strings` and `Localizable.stringsdict`
- Test: `Tests/macSCPAppKitTests/LoginSetRepointPlanTests.swift`, `Tests/macSCPCoreTests/SessionListViewModelTests.swift` (one case), `Tests/macSCPAppKitTests/ConvertKeyWiringGuardTests.swift` (extend)

**Interfaces:**
- Produces:
  ```swift
  struct LoginSetRepointRequest: Identifiable, Equatable {
      let id = UUID()
      let tab: SessionTab            // captured at the moment the import finished, as ImportKeyTarget does
      let key: ManagedKey
      let keyPath: String            // managedKeyStore.privateKeyURL(for: key), already resolved
      let set: LoginSet
      let usageCount: Int            // SessionListViewModel.usageCount(of: set.id), read when the request is made
  }
  enum LoginSetRepointPlan {
      /// nil when the failed attempt's stored session is not bound to a set, the set no
      /// longer exists, or the set is not an SSH private-key set — the caller then keeps
      /// today's behaviour for a session without a set.
      static func request(session: StoredSession?, sets: [LoginSet], usageCount: (UUID) -> Int,
                          key: ManagedKey, keyPath: String, tab: SessionTab) -> LoginSetRepointRequest?
  }
  // SessionListViewModel
  public func dropLoginSetSecret(for setID: UUID)   // secrets.deletePassword(for: setID), try?; no reload; mirrors dropSessionSecret(for:)
  ```
  Catalog keys (en): `connection.convertKey.repoint.title %@` = `Update the login set “%@”?`; `connection.convertKey.repoint.message %lld %@` (stringsdict; one: `This login set is used by one session. Its key will point to the converted key “%2$@”.`; other: `This login set is used by %1$lld sessions. Its key will point to the converted key “%2$@” for all of them.`); `connection.convertKey.repoint.confirm` = `Update login set`; `connection.convertKey.repoint.thisAttempt` = `This attempt only`. `pl` fills `one`/`few`/`many`/`other`; German du-form ("Login-Set „%@“ aktualisieren?" …).

- [x] **Step 1: Failing tests.**
  - `LoginSetRepointPlanTests`: no set on the session → nil; a set id that no longer exists → nil; a set whose `kind != .ssh` or `authKind != .privateKey` → nil; an SSH private-key set → a request carrying that set, the key, the path and `usageCount(set.id)` (a closure returning 3 → 3).
  - `SessionListViewModelTests`: `dropLoginSetSecret(for:)` removes the set's slot and leaves a session slot and a jump slot with other ids untouched (in-memory `SecretStore`; the passphrase in a named constant, compared as a Bool).
  - `ConvertKeyWiringGuardTests` (claims recounted in the header and MARKs): (a) `convertedKeyImported`'s body no longer takes the ad-hoc route for a set-bound session silently — it contains `LoginSetRepointPlan.request(` and assigns `setRepointRequest`; (b) `repointLoginSet(`'s body contains `saveLoginSet(`, `hasStoredPassphrase(`, `dropLoginSetSecret(` INSIDE the `if` whose condition carries the probe's identifier (reuse the structural gate scanner the suite already has for the session-slot drop, and require no other `dropLoginSetSecret(` in the body), and `retryConnect(`; no `CitadelFileSystem.connect` or `connect(in:` (negative, pinned by the `retryConnect(` positive); (c) `convertForThisAttemptOnly(`'s body contains `dismissConnectFailure(` and no `saveLoginSet(`; (d) `ContentView+Sheets.swift` presents a `.confirmationDialog(` bound to `setRepointRequest` whose buttons call `repointLoginSet(` and `convertForThisAttemptOnly(`, and the dialog's text reads catalog keys only.
  - Run → red (record).
- [x] **Step 2: Implement.** `convertedKeyImported`: stored session without a set → unchanged; with a set → `if let request = LoginSetRepointPlan.request(...) { setRepointRequest = request } else { convertForThisAttemptOnly(...) }`. `repointLoginSet(request)`: `var set = request.set; set.keyPath = request.keyPath; sessionListViewModel.saveLoginSet(set, secret: nil)`; probe `ManagedKeyPassphrase.hasStoredPassphrase(keyPath: request.keyPath, store: managedKeyStore, secrets: secretStore)` with `try?` → `== true` → `dropLoginSetSecret(for: set.id)`; `retryConnect(request.tab)`. `convertForThisAttemptOnly`: `tab.connectionViewModel.keyPath = path; dismissConnectFailure(tab)` (today's else-branch, moved). Cancel of the dialog = this attempt only. Before writing the retry, READ `LoginResolver.resolve` and `ManagedKeyPassphrase.resolve` and state in the report, with line numbers, that a re-pointed set whose slot was dropped dials with the managed key's passphrase (the set's empty slot → typed empty → the managed slot); if it does not, stop and report.
- [x] **Step 3: Run** the filters, whole suite, zero warnings; catalog parity and German du-form tests green. Probes: invert the probe gate (`if !…`) → guard red; drop `retryConnect(` from `repointLoginSet` → guard red; make the plan return a request for an agent set → plan test red.
- [x] **Step 4: Commit** `feat(keys): converting a PEM key for a login-set session offers to update the set`.

Four review-driven fix rounds followed the Step 4 commit: round 1
`d8db692c` (jump-hop predicates gate both slot drops; dialog buttons
paired with their handlers); round 2 `5680442c` (dialog's button set
bounded to exactly two; the CLI secret chain gains the managed key's
slot as its last link); round 3 `79e161ab` (a Keychain error on that
link is thrown, not swallowed); round 4 `12573d5a` (an unreadable key
store answers "not managed" instead of stopping the chain, while a
Keychain error still stops it).

---

### Task 3: Closeout

- [x] `docs/superpowers/specs/2026-09-10-pem-private-keys-design.md`: a dated "Decisions 2026-09-16" section — the passphrase-slot rule confirmed; the login-set re-point with its confirmation and the derived set-slot rule; the Task 2 commit. `docs/BACKLOG.md`: the row "A login-set session's converted PEM key applies for one retry only" → Done with the commit; the row "Host-key fingerprints in the diagnostic log (maintainer decision)" → Done, decision "leave them out", with the Task 1 commit and the one surface that lost them (from the Task 1 report); the row "Forwardings \"At login\"" gains "2026-09-16: maintainer decided to measure; measurement build prepared (see the row's own procedure)" and nothing more until the measurement is back. This plan's checkboxes. Commit `docs(backlog): the maintainer decisions of 2026-09-16 are recorded`.

## Self-review

- Coverage: decision 3 → Task 1; decision 1 (+ derived set-slot rule) → Task 2; decision 2 → Task 3 record (already built, `38e1e062`); decision 4 → outside, recorded in Task 3.
- Placeholders: the German/French/Polish strings are left to the implementer's translation under the catalog rules; every key, en text, signature and test case is spelled.
- Type consistency: `LoginSetRepointRequest`, `LoginSetRepointPlan.request(session:sets:usageCount:key:keyPath:tab:)`, `dropLoginSetSecret(for:)`, `setRepointRequest`, `repointLoginSet(_:)`, `convertForThisAttemptOnly(_:)` are spelled the same in every step.
