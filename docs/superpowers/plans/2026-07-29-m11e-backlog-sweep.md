# M11e — Backlog Sweep Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Clear the hardening and hygiene items collected from M10 (agent frame limit, signature timeout, honest reporting for unusable identities, target-set asymmetry), add the jump context to the audit entry, repair test hygiene, and document the two user-relevant limits in the README.

**Architecture:** Purely additive hardening on existing types (`SSHAgentClient`, `AgentBackedPrivateKey`, `AgentError`, `CitadelFileSystem.connectHop`), a signature alignment in the App (`resolveSelectedLoginSet` → `Bool`, matching its jump counterpart), an optional parameter on `AuditRecorder`, plus test and documentation work. No new feature, no new files other than tests.

**Tech Stack:** Swift 6 / `.swiftLanguageMode(.v5)`, Swift Testing, SwiftUI.

## Global Constraints

- Spec: `docs/superpowers/specs/2026-07-29-m11e-backlog-sweep-design.md` — binding. Branch: **develop**.
- NO behavior change outside the listed items; in particular the TOFU invariants, the M10d reconnect semantics (cap `min(n,6)`, each identity once, rethrow except for `allAuthenticationOptionsFailed`), and the agent rule "no keychain access on agent paths" stay untouched.
- The private key never leaves the agent; no new secrets, no new dependencies.
- All new UI/error text EN/DE in BOTH corresponding catalogs; code + comments English ONLY; README English.
- Conventional Commits (English), footer: `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- `swift build` + full `swift test` green after every task (starting point 589 tests / 43 suites); gated suites in T3; tests run SYNCHRONOUSLY in the foreground; TDD red→green for Core.
- Docker rig only `start`/`stop` from the main checkout; gated agent tests start their OWN ssh-agent and terminate it (never touch the user's agent).
- NO release, no merge to main.

## Schedule

T1 (Core hardening + target-set asymmetry) → T2 (audit jump context + test hygiene) → T3 (README + wrap-up, coordinator).

---

### Task 1: Agent hardening + target-set asymmetry

**Files:**
- Modify: `Sources/macSCPCore/SSH/SSHAgentClient.swift` (frame limit), `Sources/macSCPCore/SSH/AgentBackedPrivateKey.swift` (signature timeout), `Sources/macSCPCore/SSH/SSHAgentCodec.swift` (only if `AgentError` is defined there — check via grep), `Sources/macSCPCore/SSH/CitadelFileSystem.swift` (`noUsableIdentities`, redundant variable), `Sources/MacSCPApp/ContentView.swift` (`resolveSelectedLoginSet`), `Sources/MacSCPApp/ConnectionFormView.swift` (caller, if the signature change propagates there — the three button handlers already use `guard resolveLoginSetForSubmit() else { return }`), Core L10n catalogs (EN + DE)
- Test: `Tests/macSCPCoreTests/SSHAgentClientTests.swift`, `Tests/macSCPCoreTests/AgentAuthTests.swift`

**Interfaces:**
- Produces: `AgentError.noUsableIdentities` (new case; existing cases unchanged), `SSHAgentClient` with a frame upper bound, `AgentBackedPrivateKey` with a signature deadline, on the App side `resolveSelectedLoginSet(in:) -> Bool`.
- Consumes: existing `AgentError` cases, `AgentAuthContext`/`connectHop` from M10d, the jump counterpart `resolveSelectedJumpLoginSet(in:) -> Bool` as the model (same error message `loginSets.missingSet`, same return semantics).

**Behavior requirements (spec §2, binding):**
1. **Frame limit:** `SSHAgentClient`'s response accumulator accepts a declared length up to a maximum of `256 * 1024`. Larger ⇒ immediately `AgentError.protocolError(reason:)` with the length in the text, without buffering further and without waiting for the deadline. Constant named (`maxFrameLength`) and commented (OpenSSH maximum).
2. **Signature timeout:** the wait in `AgentBackedPrivateKey.signature(for:)` (semaphore) gets a wall-clock limit of 15 s; expiry ⇒ `AgentError.protocolError(reason: "agent sign timed out")`. The existing transport deadline stays; this limit is the second line of defense (promise is never fulfilled, e.g. a task on a shut-down event loop).
3. **`noUsableIdentities`:** if, after the `AgentPrivateKeyFactory.supports` filter, NO identity remains even THOUGH the agent delivered identities, the connect throws `AgentError.noUsableIdentities` instead of `.noIdentities`. Empty agent ⇒ still `.noIdentities`. Both cases are typed and go through the existing mapping chain (no stringifying).
4. **Redundant variable:** `authRejectionError` in the reconnect loop is removed; the behavior (error on leaving the loop) stays identical — after the M10d fix the last error IS always the auth error, because other errors are rethrown immediately. Adjust the comment.
5. **Target-set asymmetry:** `resolveSelectedLoginSet(in:)` returns `Bool`: `true` in nil-set mode (nothing to do) and on successful resolution; `false` when `loginMode == .set` and the referenced ID is NOT in `sessionListViewModel.loginSets` — in that case `form.showFailure(message: L10n.string("loginSets.missingSet", …), field: nil)` (identical to the jump counterpart, which uses `.jumpHost`; for the target `nil` is correct since no matching field exists). The existing aggregating caller (`resolveLoginSetForSubmit`) ANDs both results and keeps returning `Bool`; the three button handlers stay unchanged.
6. New Core message for `noUsableIdentities` in both Core catalogs (EN: "The SSH agent has no usable identities (unsupported key types)." / DE: „Der SSH-Agent hat keine nutzbaren Identitäten (nicht unterstützte Schlüsseltypen)."), wired at the same place as the existing agent messages (grep `socketUnavailable` in the App/VM error mapping).

- [x] **Step 1: Failing tests**

```swift
    // SSHAgentClientTests:
    // oversizedFrameThrowsProtocolError: Mock-Transport liefert ein Frame,
    //   dessen deklarierte Länge 256*1024 + 1 ist -> AgentError.protocolError;
    //   kein Hänger (Test läuft in Millisekunden, nicht bis zum Deadline).
    // maxAllowedFrameStillParses: Länge exakt 256*1024 mit gültiger
    //   IDENTITIES_ANSWER-Payload -> parst normal (Grenzwert inklusiv).
    //
    // AgentAuthTests:
    // signTimesOutWithProtocolError: Mock-Transport, der NIE antwortet
    //   (await-Suspension ohne Rückgabe) -> signature(for:) wirft
    //   AgentError.protocolError; Test injiziert ein KURZES Limit, damit er
    //   nicht 15 s läuft (Timeout als injizierbarer Parameter mit Default 15,
    //   im Report begründen).
    // allUnsupportedIdentitiesThrowNoUsableIdentities: Agent liefert zwei
    //   Identitäten mit Typ "ssh-dss" (nicht unterstützt) -> Connect wirft
    //   AgentError.noUsableIdentities (NICHT .noIdentities).
    // emptyAgentStillThrowsNoIdentities: bestehender Test bleibt grün
    //   (Regression-Guard, nicht neu schreiben).
```

- [x] **Step 2: Prove red.** `swift test --filter SSHAgentClientTests` and `--filter AgentAuthTests` → FAIL.
- [x] **Step 3: Implementation** in the order 1→5 of the behavior requirements; compile after each item.
- [x] **Step 4: Green + full suite.** `swift test` → 589 + new, 0 failures.
- [x] **Step 5: Commit.** `fix: harden the agent client and refuse dangling target login sets`

---

### Task 2: Audit jump context + test hygiene

**Files:**
- Modify: `Sources/macSCPCore/Sessions/AuditRecorder.swift` (`recordConnected`), `Sources/MacSCPApp/ContentView.swift` (callers — grep `recordConnected`, two places: form connect and `connect(in:stored:)`), `Tests/macSCPCoreTests/AuditRecorderTests.swift` (or the file that tests `recordConnected` — via grep), `Tests/macSCPCoreTests/AgentAuthTests.swift` + `Tests/macSCPCoreTests/CitadelFileSystemIntegrationTests.swift` (env serialization, temp cleanup), `Tests/macSCPCoreTests/SSHAgentClientTests.swift` (mock queue test)

**Interfaces:**
- Produces: `AuditRecorder.recordConnected(host:username:viaJumpHost: String? = nil)` (defaulted — existing callers keep compiling).

**Behavior requirements (spec §3/§4, binding):**
1. **Audit detail:** without a jump, byte-identical to today (`connected to <host> as <user>`); with a jump `connected to <host> as <user> via <jumphost>`. ONLY the jump HOST — no bastion username, no credentials, no forced port (port only if it's already part of the host string anyway). The App passes through `stored.jump?.host` or the form value (only if the jump is active).
2. **env race:** `AgentAuthTests` and the gated agent tests both mutate `SSH_AUTH_SOCK`. Secure both places with ONE shared serialization — preferably a small, shared helper (e.g. `AgentEnvLock` in a test helper file) with a global lock around set/reset; alternatively pull both suites into the same `.serialized` suite. Justify the chosen solution in the report.
3. **Temp cleanup:** every test in `CitadelFileSystemIntegrationTests` that creates a temporary known-hosts directory cleans it up via `defer { try? FileManager.default.removeItem(at: dir) }` — including the three pre-existing spots (grep `NSTemporaryDirectory` / `temporaryDirectory` in the file; the pattern already exists in one place).
4. **Mock queue test:** `transportErrorMapsToProtocolErrorDuringOperation` currently tests the mock-exhaustion path. Switch it to a single do/catch with ONE injected transport error, so the assertion actually hits the error mapping.

- [x] **Step 1: Failing tests**

```swift
    // AuditRecorder-Suite:
    // connectedWithoutJumpKeepsDetail: recordConnected(host:"h", username:"u")
    //   -> Detail exakt "connected to h as u" (Regression-Guard).
    // connectedWithJumpNamesTheHop: recordConnected(host:"h", username:"u",
    //   viaJumpHost: "bastion") -> Detail "connected to h as u via bastion";
    //   Detail enthält KEINEN Bastion-Benutzernamen (kein " as " nach "via").
```

- [x] **Step 2: Prove red.** `swift test --filter Audit` → FAIL.
- [x] **Step 3: Implementation** item 1, then the test-hygiene items 2–4 (pure test work, no production code).
- [x] **Step 4: Green + full suite + gated.** `swift test` AND `MACSCP_ITEST=1 swift test --filter CitadelFileSystemIntegrationTests` → green; additionally run gated twice in a row and confirm no temporary `known_hosts` directories remain (path count before/after in the report).
- [x] **Step 5: Commit.** `test: serialize the agent env and record the jump host in the audit log`

---

### Task 3: README + wrap-up (coordinator)

**Files:**
- Modify: `README.md` (new `## Known limitations` section before `## Install`)

- [x] **Step 1: README section** (English, three items exactly per spec §1: RSA-over-agent against Go-based servers; multiple agent identities as separate login attempts + fail2ban risk; audit log location). Factual tone, no marketing language, no stack terms in the README's intro part (the new section itself may be technical).
- [x] **Step 2: Gated suites** at the final state: rig `start`, `MACSCP_ITEST=1 MACSCP_KEYCHAIN=1 swift test` → all green, zero skips, no leftover ssh-agent processes; rig `stop`.
- [x] **Step 3:** Plan checkboxes, ledger, Opus final review (package via `git merge-base origin/develop HEAD`), fix rounds until "Yes", push develop, `gh run watch`, memory, summary. NO release.
