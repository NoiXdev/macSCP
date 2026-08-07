# M23 Phase 2 — One Way to Build a Connection Config Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `BackendDescriptor.makeConfig` the only way a `ConnectionConfig` comes into existence, so the second path — `StoredSessionConnectionConfig`'s three private builders, which already disagree with it — stops being a second truth.

**Architecture:** `StoredSessionConnectionConfig.build` keeps its typed errors (the CLI maps them to messages) but stops assembling configs itself: it reads the session through `descriptor.sessionValues`, validates through `descriptor.firstViolation` and `descriptor.requiresSecret`, and hands the values to `descriptor.makeConfig`. The three private builders go. An equivalence test, written first and red, is what proves the two paths agreed at the end and could not silently drift again.

**Tech Stack:** Swift 6 toolchain in `.swiftLanguageMode(.v5)`, SwiftPM, macOS 15+, SwiftUI, Swift Testing.

**Spec:** `docs/superpowers/specs/2026-08-07-m23-sitzungs-lebenszyklus-design.md`
**Phase 1 close record:** `docs/superpowers/specs/2026-08-07-m23-phase1-abschluss.md`

## Global Constraints

- **Code and comments: English only.** No German in source files, test names or `reason:` strings.
- **App UI is localized** across four catalogs (`en`/`de`/`fr`/`pl`) with identical key sets, enforced by a guard test. Core's catalogs are `Sources/macSCPCore/Resources/<lang>.lproj/Localizable.strings`. **CLI output is English-only and NOT localized** — this constraint drives a design decision in Task 1.
- Swift tools 6.0, all targets `.swiftLanguageMode(.v5)`, minimum macOS 15.
- Tests: Swift Testing (`@Test`/`#expect`), TDD red→green. Prove every regression red first.
- Unit suite: `swift test`. Gated: `MACSCP_ITEST=1` (Docker rig), `MACSCP_KEYCHAIN=1`.
- Docker rig: `docker compose -f docker/test-server/compose.yml up -d`, **always from the main checkout, never a git worktree.**
- **Never commit key material or secrets.** Secrets live only in the Keychain; a `StoredSession` never holds one. A secret's value must never be printed, logged or embedded in an error.
- **TOFU is a hard stop.** Nothing in this phase should go near host-key or certificate validation. If you find yourself editing it, stop and report.
- Conventional Commits, English messages. Footer on every commit: `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`. **Commit only; never push.**
- Do not launch the GUI app.

## Starting state

Phase 1 is complete: `d499f26..35532ac`, 1544 tests in 128 suites green, gated suites green. `develop` has 30 unpushed commits.

`StoredSessionConnectionConfig.build` has exactly **one** production caller, `Sources/MacSCPCLI/SessionConnecting.swift:47`. Its errors are rendered by `Sources/macSCPCore/CLI/CLIErrorMapping.swift:100-118`.

## The disagreements this phase resolves

Three are known before you start. The equivalence guard exists to find the ones that are not.

1. **S3 trimming.** `S3FieldSchema.makeConfig` trims `accessKeyID`, `region`, `endpoint`, `bucket` and the secret. `S3ConnectionConfig(stored:secretAccessKey:)`, which `buildS3` uses, trims nothing. Phase 1 made `S3FieldSchema.stored(from:)` trim on write, so a session saved *after* M23 is already clean — but a session migrated from an older file is not, and the two paths give it different configs.
2. **The empty secret.** `buildS3`/`buildWebDAV` throw `.secretRequired` on an empty secret; `makeConfig` accepts it and builds a config that fails at the server. `buildSSH` requires a non-empty secret under password auth; `SSHFieldSchema.makeConfig` builds `.password("")`.
3. **`.ssh` has no missing-block check.** `buildS3` and `buildWebDAV` throw `.missingBackendConfiguration(kind:)` when their block is nil; `buildSSH` has no such arm, so a block-less `.ssh` session — representable on disk since Phase 1, deliberately, so one bad record cannot fail the whole file — reports `SSHConnectionConfig.ConfigError.emptyHost` instead.

**Resolution direction, decided:** keep the *guards* (failing locally with a clear message beats failing at the server with an opaque one) and let the *factory* build. `descriptor.requiresSecret(values)` already answers "does this backend need a secret at all", including SSH's agent case, so the guard generalizes without a protocol branch.

## One deliberate CLI message change

`StoredSessionConnectionError.missingKeyPath` is SSH vocabulary in a generic function — keeping it means keeping an `authKind == .privateKey` branch in `build`, which is the thing this phase removes. It becomes:

```swift
case incompleteConfiguration(field: String)
```

carrying the field's **English label** (`ConnectionField.labelDefault`), because CLI output is not localized and a message key would drag `CoreL10n` into it.

| | |
|---|---|
| before | `Error: the stored session uses a private key but has no key path` |
| after | `Error: the stored session's Key path is missing or invalid` |

Slightly less explanatory, names the offending field, English by construction, and a fourth backend gets it for free. **Flag it in the phase close so it can reach the release notes.**

## File structure

**Modified**

| File | Change |
|---|---|
| `Sources/macSCPCore/Connection/StoredSessionConnectionConfig.swift` | The three private builders go; `build` routes through the descriptor. `missingKeyPath` → `incompleteConfiguration(field:)`. |
| `Sources/macSCPCore/CLI/CLIErrorMapping.swift:100-118` | Renders the new case. |
| `Sources/macSCPCore/Capabilities/BackendDescriptor.swift` | Gains `hasStoredConfiguration(_:)`. |
| `Sources/macSCPCore/Capabilities/ConnectionFieldSchema.swift` | `missingRequiredFields` stops trimming secrets (Task 2). |
| `Sources/macSCPCore/Presentation/ConnectionViewModel.swift` | `makeConfig(secret:)` and `makeWebDAVConfig()` retired (Task 3). |
| `Tests/macSCPCoreTests/StoredSessionConnectionConfigTests.swift` | 13 existing tests; several change shape, none is deleted. |

**Created**

| File | Responsibility |
|---|---|
| `Tests/macSCPCoreTests/ConfigFactoryEquivalenceTests.swift` | The guard for success criterion 4. Its own file because it is about the *relationship* between two APIs, not about either one. |

---

### Task 1: The equivalence guard, then route `build` through the factory

**Files:**
- Create: `Tests/macSCPCoreTests/ConfigFactoryEquivalenceTests.swift`
- Modify: `Sources/macSCPCore/Connection/StoredSessionConnectionConfig.swift` (all of it)
- Modify: `Sources/macSCPCore/Capabilities/BackendDescriptor.swift`
- Modify: `Sources/macSCPCore/CLI/CLIErrorMapping.swift:100-118`
- Modify: `Tests/macSCPCoreTests/StoredSessionConnectionConfigTests.swift`

**Interfaces:**
- Consumes: `BackendDescriptor.sessionValues(_:) -> FieldValues`, `.makeConfig: (FieldValues, String) throws -> ConnectionConfig`, `.requiresSecret: (FieldValues) -> Bool`, `.firstViolation(in:requireSecrets:) -> (messageKey: String, fieldKey: String)?`, `.connectionSchema`, `.credentialSchema`, `.fieldNamespace` — all from Phase 1.
- Produces: `BackendDescriptor.hasStoredConfiguration(_ session: StoredSession) -> Bool`; `StoredSessionConnectionError.incompleteConfiguration(field: String)` replacing `.missingKeyPath`.

- [ ] **Step 1: Write the equivalence guard and watch it fail**

This test is the point of the phase. Write it first — it should be **red on at least the S3 trimming case**, and what else it catches is information you want before you refactor.

`Tests/macSCPCoreTests/ConfigFactoryEquivalenceTests.swift`:

```swift
import Foundation
import Testing
@testable import macSCPCore

/// Success criterion 4: `StoredSessionConnectionConfig.build` and
/// `descriptor.makeConfig` must produce the SAME config for the same input.
///
/// Two ways to build one thing is the defect this phase removes, and the two
/// had already drifted — S3's factory trims every field while the stored-config
/// initializer trims none, so a session migrated from an older file got a
/// different config depending on which path reached it. Nothing failed loudly;
/// the two simply ran in different contexts.
///
/// This suite is that guarantee's only enforcement. If it is ever deleted or
/// weakened, the two paths are free to drift apart again in silence.
@Suite struct ConfigFactoryEquivalenceTests {
    private func s3Stored(padded: Bool) -> StoredS3Config {
        let pad = padded ? "  " : ""
        return StoredS3Config(
            accessKeyID: "\(pad)AKIAEXAMPLE\(pad)",
            region: "\(pad)eu-central-1\(pad)",
            endpoint: "\(pad)https://s3.example.com\(pad)",
            bucket: "\(pad)archive\(pad)",
            usePathStyle: true)
    }

    /// The clean case: whatever `build` returns, the factory returns too.
    @Test(arguments: ConnectionKind.allCases)
    func buildAgreesWithTheFactory(kind: ConnectionKind) throws {
        let secret = "s3cr3t"
        let session: StoredSession
        switch kind {
        case .ssh:
            session = sshSession(
                name: "prod", host: "prod.example.com", port: 2222, username: "deploy")
        case .s3:
            session = s3Session(name: "archive", config: s3Stored(padded: false))
        case .webdav:
            session = webdavSession(name: "cloud")
        }

        let viaBuild = try StoredSessionConnectionConfig.build(for: session, secret: secret)
        let descriptor = BackendDescriptor.descriptor(for: kind)
        let viaFactory = try descriptor.makeConfig(descriptor.sessionValues(session), secret)
        #expect(viaBuild == viaFactory)
    }

    /// The case that was already broken. A session whose stored fields carry
    /// whitespace — an older file, migrated — must not produce two different
    /// configs depending on which path reads it.
    @Test func buildAgreesWithTheFactoryOnAPaddedS3Session() throws {
        let session = s3Session(name: "archive", config: s3Stored(padded: true))
        let viaBuild = try StoredSessionConnectionConfig.build(for: session, secret: "s3cr3t")
        let descriptor = BackendDescriptor.descriptor(for: .s3)
        let viaFactory = try descriptor.makeConfig(descriptor.sessionValues(session), "s3cr3t")
        #expect(viaBuild == viaFactory)
    }

    /// SSH under private-key auth: the passphrase convention (empty means an
    /// unencrypted key, not an empty passphrase) must be the same on both.
    @Test func buildAgreesWithTheFactoryForAnUnencryptedKey() throws {
        let session = sshSession(
            name: "prod", host: "prod.example.com", username: "deploy",
            authKind: .privateKey, keyPath: "/keys/id_ed25519")
        let viaBuild = try StoredSessionConnectionConfig.build(for: session, secret: nil)
        let descriptor = BackendDescriptor.descriptor(for: .ssh)
        let viaFactory = try descriptor.makeConfig(descriptor.sessionValues(session), "")
        #expect(viaBuild == viaFactory)
    }
}
```

**`ConnectionConfig` is already `Equatable`** — verified before this plan was written, along with `SSHConnectionConfig`, `S3ConnectionConfig`, `WebDAVConnectionConfig` and `SSHConnectionConfig.AuthMethod`. So `#expect(viaBuild == viaFactory)` compiles as written and compares every field, including the secret. **Do not replace it with a field-by-field comparison** — a hand-written one is one more place a newly added field can be forgotten, which is precisely the failure this suite exists to catch.

- [ ] **Step 2: Run it and record exactly what disagrees**

Run: `swift test --filter ConfigFactoryEquivalence 2>&1 | tail -30`

Expected: at least `buildAgreesWithTheFactoryOnAPaddedS3Session` fails. **Copy the full failure output into your report before changing anything** — that list is the evidence for what this phase fixed, and it is the only moment it exists.

- [ ] **Step 3: Add `hasStoredConfiguration` to the descriptor**

In `Sources/macSCPCore/Capabilities/BackendDescriptor.swift`, next to `sessionValues(_:)`:

```swift
    /// Whether this session actually carries the stored block its `kind`
    /// claims (M23/P2).
    ///
    /// A computed answer rather than a check at each call site, because the
    /// three call sites disagreed: `buildS3` and `buildWebDAV` threw
    /// `missingBackendConfiguration`, while the SSH path had no such arm at
    /// all and surfaced a blank host as `ConfigError.emptyHost` instead. The
    /// shape is representable on disk on purpose — `StoredSession.init(from:)`
    /// accepts a record with no block so that one bad entry cannot fail the
    /// whole file — so every reader needs the same answer to the same question.
    public func hasStoredConfiguration(_ session: StoredSession) -> Bool {
        switch kind {
        case .ssh: return session.ssh != nil
        case .s3: return session.s3 != nil
        case .webdav: return session.webdav != nil
        }
    }
```

- [ ] **Step 4: Replace the error case**

In `StoredSessionConnectionConfig.swift`, replace `case missingKeyPath` with:

```swift
    /// A field the stored session needs is blank or unparsable — which field
    /// is named by its ENGLISH label (`ConnectionField.labelDefault`), not a
    /// localization key, because CLI output is not localized.
    ///
    /// Replaced the SSH-specific `missingKeyPath` in M23/P2: naming a field by
    /// protocol meant an `authKind == .privateKey` branch inside a function
    /// whose whole point is not to have one. The schema already knows which
    /// fields are required and when, so this case carries the answer instead
    /// of re-deriving it.
    case incompleteConfiguration(field: String)
```

- [ ] **Step 5: Rewrite `build` and delete the three private builders**

Replace everything from `public static func build` to the end of `buildWebDAV` with:

```swift
    public static func build(for session: StoredSession, secret: String?) throws -> ConnectionConfig {
        guard session.loginSetID == nil else {
            throw StoredSessionConnectionError.loginSetSessionsNotSupported
        }
        guard session.jump == nil else {
            throw StoredSessionConnectionError.jumpSessionsNotSupported
        }

        let descriptor = BackendDescriptor.descriptor(for: session.kind)
        guard descriptor.hasStoredConfiguration(session) else {
            throw StoredSessionConnectionError.missingBackendConfiguration(kind: session.kind)
        }

        let values = descriptor.sessionValues(session)
        // The guards stay even though the factory would build without them:
        // failing here says which field is wrong, while failing at the server
        // says "access denied" with nothing pointing at the cause.
        //
        // `requiresSecret` is what keeps this from being a protocol branch —
        // it already answers "does this backend need a secret at all",
        // including SSH's agent case, where asking for one would be wrong.
        if descriptor.requiresSecret(values), secret?.isEmpty != false {
            throw StoredSessionConnectionError.secretRequired
        }
        // `requireSecrets: false` because the secret is not IN `values` — it
        // arrives as the parameter and was just checked above. This call is
        // for the non-secret fields: a private-key session with no key path, a
        // blank host, an unparsable port.
        if let violation = descriptor.firstViolation(in: values, requireSecrets: false) {
            throw StoredSessionConnectionError.incompleteConfiguration(
                field: descriptor.fieldLabel(forKey: violation.fieldKey))
        }
        return try descriptor.makeConfig(values, secret ?? "")
    }
```

and add the label lookup to `BackendDescriptor`, next to `hasStoredConfiguration`:

```swift
    /// The English label of the field a namespaced `FieldValues` key names, or
    /// the key itself when nothing matches (M23/P2).
    ///
    /// English rather than localized: the one caller renders CLI output, which
    /// is not localized. The fallback keeps a caller from printing nothing at
    /// all if a key ever arrives that no schema declares.
    public func fieldLabel(forKey key: String) -> String {
        let fields = connectionSchema.fields + credentialSchema.fields
        return fields.first { "\(fieldNamespace).\($0.id)" == key }?.labelDefault ?? key
    }
```

- [ ] **Step 6: Render the new case in the CLI**

In `Sources/macSCPCore/CLI/CLIErrorMapping.swift`, replace the `case .missingKeyPath` arm with:

```swift
            case .incompleteConfiguration(let field):
                return "Error: the stored session's \(field) is missing or invalid"
```

- [ ] **Step 7: Update the existing tests, changing shape and not meaning**

`Tests/macSCPCoreTests/StoredSessionConnectionConfigTests.swift` has 13 tests. Two assert `.missingKeyPath` (`privateKeyAuthWithoutAKeyPathThrows`, `privateKeyAuthWithAnEmptyKeyPathThrows`) — point them at `.incompleteConfiguration(field: "Key path")`. **Do not weaken them to "throws something".** The rest should pass unchanged; if any does not, that is a behaviour change you must explain in your report rather than edit away.

Then add one test for the gap this task closes:

```swift
/// A `.ssh` session with no stored block is representable on disk — the
/// decoder accepts it deliberately, so one bad record cannot fail the whole
/// file. Before M23/P2 only S3 and WebDAV reported that honestly; SSH fell
/// through to a blank host and surfaced `ConfigError.emptyHost` instead.
@Test func anSSHSessionWithoutItsStoredBlockThrowsMissingConfiguration() {
    var session = sshSession(name: "broken")
    session.ssh = nil
    #expect(throws: StoredSessionConnectionError.missingBackendConfiguration(kind: .ssh)) {
        try StoredSessionConnectionConfig.build(for: session, secret: "pw")
    }
}
```

- [ ] **Step 8: Run everything**

```bash
swift build 2>&1 | tail -3
swift test 2>&1 | tail -3
```

Expected: green, including all three equivalence tests. Baseline before this task is 1544 tests in 128 suites.

Then the gated suite — the CLI's own round-trip test drives the built binary against the rig, and it is the only thing that proves the new error path still renders:

```bash
docker compose -f docker/test-server/compose.yml up -d
MACSCP_ITEST=1 swift test 2>&1 | tail -5
```

- [ ] **Step 9: Commit**

```bash
git add Sources Tests
git commit -m "refactor(core): build every stored session's config through the factory

StoredSessionConnectionConfig's three private builders are gone; build now
reads the session through sessionValues, validates through requiresSecret
and firstViolation, and hands the values to descriptor.makeConfig. An
equivalence test written red first proves the two paths agreed at the end —
they did not before, because S3's factory trims every field while the
stored-config initializer trims none.

Closes the gap where a block-less .ssh session reported a blank host
instead of a missing configuration, and replaces the SSH-specific
missingKeyPath with a schema-derived incompleteConfiguration(field:).

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: One rule for secrets across both validators

**Files:**
- Modify: `Sources/macSCPCore/Capabilities/ConnectionFieldSchema.swift` (`missingRequiredFields`)
- Test: `Tests/macSCPCoreTests/LoginResolverSchemaTests.swift`, `Tests/macSCPCoreTests/FieldValidationTests.swift`

**Interfaces:**
- Consumes: `ConnectionField.isSecret`, `firstViolation(in:namespace:requireSecrets:)` from Phase 1.
- Produces: no new API — `missingRequiredFields` changes behaviour only.

**The defect:** `firstViolation` compares a secret **verbatim** and documents why at `ConnectionFieldSchema.swift:159-161` — a password of spaces is a legal password, and trimming it would refuse a user their own server. `missingRequiredFields`, two functions above, trims everything including secrets. Its sole caller is `LoginSetsSheet.swift:859` (`isSaveDisabled`). Net effect today: an SSH login set with the password `"  "` is refused by the editor's Save button and accepted by `connect()`. Two rules for one question.

- [ ] **Step 1: Write the failing test**

Add to `Tests/macSCPCoreTests/FieldValidationTests.swift`:

```swift
/// The two validators must answer the same question the same way. A password
/// of spaces is a legal password — `firstViolation` has said so since M23/P1,
/// and the login-set editor said the opposite, so a set that connects fine
/// could not be saved.
@Test func bothValidatorsTreatASecretOfSpacesAsFilled() {
    let descriptor = BackendDescriptor.descriptor(for: .ssh)
    var values = descriptor.defaultValues
    values[SSHField.username] = "tim"
    values[SSHField.password] = "  "

    #expect(descriptor.firstViolation(in: values, requireSecrets: true) == nil)
    #expect(descriptor.credentialSchema.missingRequiredFields(
        in: values, namespace: SSHField.namespace).isEmpty)
}

/// And an EMPTY secret is still missing on both — the fix must not turn the
/// trim off in a way that also stops catching a genuinely blank field.
@Test func bothValidatorsTreatAnEmptySecretAsMissing() {
    let descriptor = BackendDescriptor.descriptor(for: .ssh)
    var values = descriptor.defaultValues
    values[SSHField.username] = "tim"
    values[SSHField.password] = ""

    #expect(descriptor.firstViolation(in: values, requireSecrets: true)?.fieldKey
            == "SSHField.password")
    #expect(descriptor.credentialSchema.missingRequiredFields(
        in: values, namespace: SSHField.namespace).map(\.id) == [SSHField.password.rawValue])
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `swift test --filter bothValidatorsTreat 2>&1 | tail -20`
Expected: `bothValidatorsTreatASecretOfSpacesAsFilled` FAILS on the `missingRequiredFields` assertion.

- [ ] **Step 3: Make `missingRequiredFields` follow the same rule**

In `Sources/macSCPCore/Capabilities/ConnectionFieldSchema.swift`, change the body of `missingRequiredFields` so a secret is compared verbatim and everything else is trimmed — the same split `firstViolation` makes — and say why in the doc comment, pointing at `firstViolation` as the shared rule rather than restating it.

- [ ] **Step 4: Run the tests**

Run: `swift test 2>&1 | tail -3`
Expected: green. If a login-set test goes red, read it before touching it — a set that was previously unsaveable becoming saveable is the point, and a test pinning the old rule should be updated with its reasoning; a test failing for any other reason is a finding.

- [ ] **Step 5: Commit**

```bash
git add Sources/macSCPCore/Capabilities/ConnectionFieldSchema.swift Tests
git commit -m "fix(core): one rule for a whitespace secret in both validators

missingRequiredFields trimmed secrets while firstViolation compares them
verbatim, so a login set whose password is spaces was refused by the
editor's Save button and accepted by connect(). A password of spaces is a
legal password; both validators now say so.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 3: Retire the two test-only config wrappers

**Files:**
- Modify: `Sources/macSCPCore/Presentation/ConnectionViewModel.swift` (remove `makeConfig(secret:)` and `makeWebDAVConfig()`)
- Modify: `Tests/macSCPCoreTests/ConnectionViewModelWebDAVTests.swift` and any other caller the compiler names

**Why:** both have **zero** callers in `Sources` — Phase 1's close record recorded them as test-only seams over `descriptor.makeConfig`. A phase whose thesis is "the factory is the only way" should not leave two wrappers that exist purely so tests can avoid it.

- [ ] **Step 1: Confirm they are still uncalled**

```bash
grep -rn --include='*.swift' 'makeWebDAVConfig\|makeConfig(secret:' Sources Tests
```

Expected: declarations plus test call sites only, nothing in `Sources` outside `ConnectionViewModel.swift` itself. **If a production caller appeared, stop and report it** — that changes this task from a deletion into a decision.

- [ ] **Step 2: Delete both methods**

Remove `makeConfig(secret:)` and `makeWebDAVConfig()` from `ConnectionViewModel`.

- [ ] **Step 3: Repoint the tests at the factory**

`swift build --build-tests` names every broken call site. Each becomes:

```swift
let descriptor = BackendDescriptor.descriptor(for: vm.kind)
let config = try descriptor.makeConfig(vm.values, secret)
```

**Keep every assertion.** These tests are about what the config contains; only the way they obtain it changes. A test that asserted on `WebDAVConnectionConfig` directly should still do so — unwrap `case .webdav(let webdav) = config`.

- [ ] **Step 4: Run the tests**

Run: `swift test 2>&1 | tail -3` — expected green, same count as after Task 2.

- [ ] **Step 5: Commit**

```bash
git add Sources/macSCPCore/Presentation/ConnectionViewModel.swift Tests
git commit -m "refactor(core): retire the two test-only config wrappers

makeConfig(secret:) and makeWebDAVConfig() had no production callers left
after M23 phase 1 — they existed so tests could build a config without
going through the descriptor, which is exactly what this phase makes the
only way. The tests now call descriptor.makeConfig directly and assert the
same things.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 4: Phase close

- [ ] **Step 1: Prove success criterion 4**

The criterion is: *`StoredSessionConnectionConfig.build` and `descriptor.makeConfig` produce identical configs for the same input, enforced by a test.* Confirm `ConfigFactoryEquivalenceTests` covers all three backends and both the clean and the whitespace-carrying case, and that it would fail if a fourth backend were added without wiring — the parameterization is over `ConnectionKind.allCases`, so check that it genuinely enumerates rather than filtering.

- [ ] **Step 2: Confirm the phase did not widen criterion 1**

Phase 1 proved that a fourth `ConnectionKind` forces edits only in `BackendDescriptor.swift`, `StoredSessionConnectionConfig.swift:48` and `SessionImportPlanner.swift:359`. This phase touches the second of those. Re-run the probe:

```bash
# add `case ftp` to ConnectionKind, then:
swift build 2>&1 | grep -E 'error:' | sort
```

`StoredSessionConnectionConfig` should now force **at most** the `hasStoredConfiguration` switch — the `switch session.kind` at the old `:48` is gone. Report the exact list, then **revert the probe and confirm `git status` is clean.**

- [ ] **Step 3: Run the full matrix**

```bash
swift build 2>&1 | tail -2
swift test 2>&1 | tail -2
docker compose -f docker/test-server/compose.yml up -d
MACSCP_ITEST=1 swift test 2>&1 | tail -2
MACSCP_KEYCHAIN=1 swift test --filter Keychain 2>&1 | tail -2
for lang in en de fr pl; do
  plutil -lint "Sources/macSCPCore/Resources/$lang.lproj/Localizable.strings"
done
```

- [ ] **Step 4: Whole-phase review**

Dispatch a fresh reviewer over the phase diff with this plan and the spec as context. The three questions that matter:

1. **Did any config change shape?** The equivalence guard proves the two paths agree with *each other* — it does not prove either still produces what it produced before the phase. Compare a config built today against what `git show <phase-base>` would have produced for the same session, at least for the padded-S3 case where the two paths disagreed. Whichever way that one resolved, it changed behaviour for somebody.
2. **Are the guards still guards?** `secretRequired` and `incompleteConfiguration` must still fire before `makeConfig`, so a user gets the specific local error rather than an opaque server error. A refactor that quietly let the factory throw first would pass the equivalence test and degrade every CLI message.
3. **Is `hasStoredConfiguration` the only new `switch`?** If the phase added another, criterion 1 got worse rather than better.

- [ ] **Step 5: Write the close record and commit**

Append to `docs/superpowers/specs/2026-08-07-m23-phase1-abschluss.md` — or write a sibling `…-phase2-abschluss.md` if that file has grown unwieldy — covering: what the equivalence guard caught when it was first red, the CLI message change (`missingKeyPath` → `incompleteConfiguration`) **flagged for the release notes**, and what Phase 3 inherits.

**Do not push.**

---

## Self-review

**Spec coverage.** Phase 2's spec section names one job — "this phase makes the factory the only way" — and criterion 4 as its proof. Task 1 does the job and writes the proof; Task 4 Step 1 verifies the proof covers what the criterion claims. The two disagreements the spec names explicitly (the S3/WebDAV `.secretRequired` asymmetry and `buildSSH`'s non-empty-secret rule) are resolved by Task 1's `requiresSecret` guard. The two the Phase 1 close record added — the secret-trim disagreement between the validators, and the test-only wrappers — are Tasks 2 and 3.

**Deliberate scope addition.** The spec does not mention `.ssh`'s missing `missingBackendConfiguration` arm; Phase 1's final review found it. It is fixed here because `hasStoredConfiguration` makes it free, and leaving it would mean a function whose whole purpose is uniform treatment still treating one backend differently.

**Soft spot, checked and closed.** The guard depends on `ConnectionConfig` being `Equatable`. It is, along with all three payload types and `AuthMethod` — verified before writing this plan rather than left for the implementer to discover.

**Where this plan is deliberately less prescriptive.** Task 2 Step 3 says what `missingRequiredFields` must do and why, but does not paste the body: it is a four-line function and the split it needs (`field.isSecret ? raw : raw.trimmed`) is already written two functions below it in the same file. Copying it here would invite transcription rather than reading the neighbour it has to match.

**Not covered, on purpose.** The CLI cannot resolve a login-set-bound or jump-configured session — `build` still throws `loginSetSessionsNotSupported` and `jumpSessionsNotSupported`. That predates this milestone and neither the spec nor this phase claims to change it.
