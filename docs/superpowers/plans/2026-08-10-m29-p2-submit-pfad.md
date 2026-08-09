# M29-P2 — Der Submit-Pfad nach Core (Implementation Plan)

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> superpowers:subagent-driven-development (recommended) or
> superpowers:executing-plans to implement this plan task-by-task. Steps use
> checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move the submit path's three login resolutions out of
`ContentView` into Core, so the guard-before-fill ordering that closed M28's
Critical becomes assertable by a test.

**Architecture:** A new `SubmitRefusal` enum names every way a submit can be
refused and maps each case to the form field to highlight. Four new methods
on `SessionListViewModel` — three resolutions plus a coordinator that never
short-circuits — live in a new extension file. `ContentView`'s closure
collapses to translating refusals into localized text.

**Tech Stack:** Swift 6 (`.swiftLanguageMode(.v5)`), SwiftPM, macOS 15+,
Swift Testing (`@Test`/`#expect`).

Spec: `../specs/2026-08-10-m29-p2-submit-pfad-design.md`.

## Global Constraints

- **Code, comments, identifiers, test names: English only.** Internal docs
  (`docs/`) may be German.
- **No behaviour change except one**, named in the spec: the target picker
  gains a `kind` guard. Everything else — every message, every highlighted
  field — must behave exactly as today.
- Swift tools 6.0, **every target `.swiftLanguageMode(.v5)`**, macOS 15+.
- Tests: Swift Testing, TDD red→green. New logic ships with tests.
- **A secret's value is never printed, logged, or embedded in an error** —
  including a test failure message. Assert on identity, emptiness, or the
  refusal case, never on the secret text.
- **Never commit key material or secrets.**
- **Never write a line number into a comment.** Name the thing.
- **A comment asserting something about the code needs the same verification
  as a test.** In P1, five plan errors reached implementers and three became
  false comments. **Treat this plan's prose as claims to verify.**
- **Do NOT run `scripts/release`.** **Do NOT launch the GUI app.**
- Conventional Commits, English. Footer exactly:
  `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`
- **Commit, but never push.**
- Baseline: **1715 tests in 140 suites, green.**

## Verified APIs (checked against the source while writing this plan)

- `ConnectionViewModel` (Core, `@MainActor`): `public var kind: ConnectionKind`,
  `loginMode: LoginMode`, `selectedLoginSetID: UUID?`, `jumpEnabled: Bool`,
  `jumpSourceMode: JumpSourceMode`, `jumpLoginMode: LoginMode`,
  `jumpSelectedLoginSetID: UUID?`, `jumpSessionID: UUID?`,
  `jumpPassword: String`, `public private(set) var mode: FormMode` (case
  `.edit(UUID)`), `applyResolvedCredentials(_ resolved: FieldValues)`,
  `showFailure(message:field:)`, `static func authChoice(for:)`.
- `ConnectionViewModel.Field` is **public** with cases `.schema(String)`,
  `.saveName`, `.jumpHost`, `.jumpPort`, `.jumpUsername`, `.jumpPassword`,
  `.jumpKeyPath`, `.jumpSession`.
- `SessionListViewModel` (Core): `public private(set) var sessions:
  [StoredSession]`, `loginSets: [LoginSet]`, `credentials(of set: LoginSet)
  -> FieldValues`, `password(for session: StoredSession) -> String?`,
  `resolvedJump(for session: StoredSession) throws -> ResolvedJump?`.
- `LoginResolveError` cases used here: `.missingJumpSession`,
  `.jumpChainNotSupported`, `.jumpSessionNotSSH`.
- `JumpLoginSetEligibility.isEligible(_ set: LoginSet) -> Bool`.

---

## File Structure

| File | Responsibility |
|---|---|
| `Sources/macSCPCore/Presentation/SubmitRefusal.swift` | **New.** The refusal cases and their field mapping |
| `Sources/macSCPCore/Presentation/SessionListViewModel+Submit.swift` | **New.** The three resolutions and the coordinator |
| `Sources/MacSCPAppKit/ContentView.swift` | Closure collapses; the four private resolution funcs go |
| `Sources/MacSCPAppKit/Resources/*.lproj/Localizable.strings` | One new key, four catalogs |
| `Tests/macSCPCoreTests/SubmitPreparationTests.swift` | **New.** All of the above |

---

### Task 1: `SubmitRefusal` and the target resolution

The refusal vocabulary, its field mapping, and the first of the three
resolutions — the one that gains the new `kind` guard.

**Files:**
- Create: `Sources/macSCPCore/Presentation/SubmitRefusal.swift`
- Create: `Sources/macSCPCore/Presentation/SessionListViewModel+Submit.swift`
- Create: `Tests/macSCPCoreTests/SubmitPreparationTests.swift`

**Interfaces:**
- Produces: `public enum SubmitRefusal` with the eight cases below and
  `public var field: ConnectionViewModel.Field?`.
- Produces: `SessionListViewModel.resolveTargetLoginSet(form:) -> SubmitRefusal?`
  — `nil` means "nothing to refuse". Tasks 2 and 3 extend the same extension
  file.

- [ ] **Step 1: Write the failing tests**

```swift
import Foundation
import Testing
@testable import macSCPCore

@Suite("SubmitPreparation")
@MainActor
struct SubmitPreparationTests {
    /// Same shape as `SessionListViewModelTests.makeVM` — read that helper
    /// and mirror it rather than inventing a second construction.
    private func makeVM() -> (SessionListViewModel, InMemorySecretStore, URL) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-submit-\(UUID().uuidString)")
        let secrets = InMemorySecretStore()
        let vm = SessionListViewModel(
            store: SessionStore(directory: dir), secrets: secrets,
            loginSetStore: LoginSetStore(directory: dir))
        return (vm, secrets, dir)
    }

    /// A form with no connector: none of these tests connects, and a
    /// throwing stub is the smallest value satisfying the signature.
    private func makeForm() -> ConnectionViewModel {
        ConnectionViewModel(connector: { _, _ in throw CancellationError() })
    }

    /// A live set resolves silently and fills the credential fields.
    @Test func aLiveTargetSetResolvesAndFills() throws {
        let (vm, _, dir) = makeVM()
        defer { try? FileManager.default.removeItem(at: dir) }
        let set = LoginSet(name: "Root", username: "root")
        vm.saveLoginSet(set, secret: "s3cr3t")

        let form = makeForm()
        form.loginMode = .set
        form.selectedLoginSetID = set.id

        #expect(vm.resolveTargetLoginSet(form: form) == nil)
        // Assert the username arrived, NOT the secret's text.
        #expect(form.values.raw(for: "\(SSHField.namespace).\(SSHField.username.rawValue)") == "root")
    }

    /// The set was deleted while the form stayed open.
    @Test func aDanglingTargetSetIsRefused() throws {
        let (vm, _, dir) = makeVM()
        defer { try? FileManager.default.removeItem(at: dir) }
        let form = makeForm()
        form.loginMode = .set
        form.selectedLoginSetID = UUID()

        #expect(vm.resolveTargetLoginSet(form: form) == .targetSetMissing)
    }

    /// NEW in P2: a set belonging to another protocol is refused rather than
    /// written into fields the form never reads. That was harmless only
    /// because `applyResolvedCredentials` namespaces values per backend — a
    /// coincidence, not a rule.
    @Test func aTargetSetOfAnotherKindIsRefused() throws {
        let (vm, _, dir) = makeVM()
        defer { try? FileManager.default.removeItem(at: dir) }
        let share = LoginSet(name: "Share", username: "dav", kind: .webdav)
        vm.saveLoginSet(share, secret: "share-secret")

        let form = makeForm()
        form.kind = .ssh
        form.loginMode = .set
        form.selectedLoginSetID = share.id

        #expect(vm.resolveTargetLoginSet(form: form) == .targetSetKindMismatch)
    }

    /// Manual mode and "nothing selected yet" are both no-ops — the submit
    /// buttons are already disabled for the latter, so this is the
    /// belt-and-suspenders half rather than the only guard.
    @Test func manualModeAndNoSelectionResolveSilently() throws {
        let (vm, _, dir) = makeVM()
        defer { try? FileManager.default.removeItem(at: dir) }

        let manual = makeForm()
        manual.loginMode = .manual
        #expect(vm.resolveTargetLoginSet(form: manual) == nil)

        let unselected = makeForm()
        unselected.loginMode = .set
        unselected.selectedLoginSetID = nil
        #expect(vm.resolveTargetLoginSet(form: unselected) == nil)
    }

    /// The field mapping is part of the contract: a refusal that highlighted
    /// the wrong control would be a silent regression the user sees but no
    /// test does.
    @Test func eachRefusalNamesItsField() {
        #expect(SubmitRefusal.targetSetMissing.field == nil)
        #expect(SubmitRefusal.targetSetKindMismatch.field == nil)
        #expect(SubmitRefusal.jumpSetMissing.field == .jumpHost)
        #expect(SubmitRefusal.jumpSetNotSSH.field == .jumpHost)
        #expect(SubmitRefusal.jumpSessionMissing.field == .jumpSession)
        #expect(SubmitRefusal.jumpChainNotSupported.field == .jumpSession)
        #expect(SubmitRefusal.jumpSessionNotSSH.field == .jumpSession)
        #expect(SubmitRefusal.jumpSessionLoginUnresolvable.field == .jumpSession)
    }
}
```

**Two things in that code are this plan's guesses, not verified facts, and
they are the likeliest thing to be wrong:** the exact spelling of the
namespaced field key in `aLiveTargetSetResolvesAndFills`
(`SSHField.namespace` / `SSHField.username.rawValue` / `form.values.raw(for:)`)
and `saveLoginSet(_:secret:)`'s signature. Check both against the source and
against how `SessionListViewModelTests` reads field values today; adapt the
call, keep the assertion's intent. **Say in your report what differed.**

The remaining tasks reuse `makeVM()` and `makeForm()` from this file — do not
redefine them.

- [ ] **Step 2: Run them and watch them fail**

Run: `swift test --filter SubmitPreparation 2>&1 | tail -6`
Expected: compile failure — `SubmitRefusal` does not exist yet.

- [ ] **Step 3: Write `SubmitRefusal`**

```swift
import Foundation

/// Every way the connection form's submit can be refused before a connect
/// or save is attempted (M29-P2).
///
/// Cases, not text: the App layer maps each to a localized message, the same
/// split `LoginResolveError` uses. The field each case highlights belongs
/// here rather than at the call site — it used to live scattered across four
/// catch branches in the view, where nothing could check it.
public enum SubmitRefusal: Equatable, Sendable {
    /// The selected target login set no longer exists.
    case targetSetMissing
    /// The selected target login set belongs to another protocol.
    case targetSetKindMismatch
    /// The selected jump login set no longer exists.
    case jumpSetMissing
    /// The selected jump login set is not an SSH login. Refused BEFORE the
    /// set's keychain slot is read — see the resolution's own doc comment.
    case jumpSetNotSSH
    /// The connection used as jump host no longer exists.
    case jumpSessionMissing
    /// The referenced jump connection itself connects through a jump host.
    case jumpChainNotSupported
    /// The referenced jump connection is not an SSH connection.
    case jumpSessionNotSSH
    /// The referenced jump connection's own login could not be resolved —
    /// a dangling login set on it, or any other resolution failure. Named
    /// rather than left as an unlabelled catch-all so a test can reach it.
    case jumpSessionLoginUnresolvable

    /// The form control to highlight, or `nil` when no single control
    /// corresponds — the target cases refuse a picker whose failure has no
    /// matching field row.
    public var field: ConnectionViewModel.Field? {
        switch self {
        case .targetSetMissing, .targetSetKindMismatch:
            return nil
        case .jumpSetMissing, .jumpSetNotSSH:
            return .jumpHost
        case .jumpSessionMissing, .jumpChainNotSupported,
            .jumpSessionNotSSH, .jumpSessionLoginUnresolvable:
            return .jumpSession
        }
    }
}
```

- [ ] **Step 4: Write the target resolution**

Create `Sources/macSCPCore/Presentation/SessionListViewModel+Submit.swift`:

```swift
import Foundation

extension SessionListViewModel {
    /// Resolves the form's TARGET login set before a submit: fills the
    /// credential fields from the set, or refuses.
    ///
    /// Returns `nil` outside Set mode and while nothing is selected — the
    /// submit buttons are already disabled for the latter, so this is the
    /// defensive half rather than the only guard.
    ///
    /// The `kind` check is new in M29-P2. Without it a set belonging to
    /// another protocol was accepted and its values written under that
    /// protocol's own field namespace, which the form never reads — harmless
    /// by coincidence rather than by rule, and only for as long as no two
    /// backends share a field id.
    public func resolveTargetLoginSet(form: ConnectionViewModel) -> SubmitRefusal? {
        guard form.loginMode == .set, let id = form.selectedLoginSetID else { return nil }
        guard let set = loginSets.first(where: { $0.id == id }) else {
            return .targetSetMissing
        }
        guard set.kind == form.kind else { return .targetSetKindMismatch }
        form.applyResolvedCredentials(credentials(of: set))
        return nil
    }
}
```

- [ ] **Step 5: Run the tests**

Run: `swift test --filter SubmitPreparation 2>&1 | tail -4`
Expected: all PASS.

- [ ] **Step 6: Add the new catalog key to all four App catalogs**

Key `form.loginSet.kindMismatch`, English:
`"The selected stored login belongs to a different kind of connection. Choose a login for this connection's protocol, or enter the credentials here."`
Supply German, French and Polish too; flag FR/PL in your report as
machine-provided and unreviewed, the standing caveat for this project.

Verify: `plutil -lint` on all four, and the existing key-set guard test.

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "feat(core): name the ways a submit can be refused, and resolve the target set"
```

---

### Task 2: The two jump resolutions

The security-critical half. `resolveJumpLoginSet` must refuse **before** any
keychain read; `resolveJumpSession` carries the four resolver failures.

**Files:**
- Modify: `Sources/macSCPCore/Presentation/SessionListViewModel+Submit.swift`
- Modify: `Tests/macSCPCoreTests/SubmitPreparationTests.swift`

**Interfaces:**
- Consumes: `SubmitRefusal` from Task 1.
- Produces: `resolveJumpLoginSet(form:) -> SubmitRefusal?` and
  `resolveJumpSession(form:) -> SubmitRefusal?`.

**The jump fill moves with the resolution.** Today `ContentView.fillJumpForm`
sets `jumpUsername`, `jumpAuthChoice`, `jumpKeyPath` and `jumpPassword`,
reading the secret through a synthetic `StoredSession` carrying the SET's id
— because `password(for:)` addresses the keychain by id alone. **Carry that
construction over unchanged.** Do not invent a second way to read it, and do
not read it for an agent set, which has no slot.

- [ ] **Step 1: Write the failing tests**

The two that matter most, in full:

```swift
    /// M28's Critical, now assertable. A jump bound to a WebDAV set must be
    /// refused — AND the set's secret must never reach the form. The second
    /// assertion is the one that matters: it pins the ORDER of the guard and
    /// the fill. Swap those two lines and this goes red with the credential
    /// sitting in the form, not merely with a differing flag.
    @Test func aJumpBoundToANonSSHSetIsRefusedBeforeItsSecretIsRead() throws {
        // Build a WebDAV set whose keychain slot holds a secret, bind the
        // form's jump to it, then:
        //   #expect(vm.resolveJumpLoginSet(form: form) == .jumpSetNotSSH)
        //   #expect(form.jumpPassword.isEmpty)
        // Never assert the secret's text — only that the field stayed empty.
    }

    /// The refusal must not depend on the set holding a secret at all: an
    /// empty slot would make the assertion above pass for the wrong reason.
    @Test func theRefusalDoesNotDependOnTheSetHoldingASecret() throws {
        // Same as above with no secret stored; still `.jumpSetNotSSH`.
    }
```

Plus one test per remaining case: a live SSH jump set fills and returns
`nil`; a dangling jump set gives `.jumpSetMissing`; an agent jump set fills
without any keychain read; jump disabled, session mode, and manual mode each
return `nil`; and the four session-mode failures
(`.jumpSessionMissing`, `.jumpChainNotSupported`, `.jumpSessionNotSSH`,
`.jumpSessionLoginUnresolvable`) each reached through the real resolver.

- [ ] **Step 2: Run and watch them fail**

Run: `swift test --filter SubmitPreparation 2>&1 | tail -6`
Expected: compile failure — the two methods do not exist.

- [ ] **Step 3: Write the two resolutions**

Port the bodies from `ContentView.resolveSelectedJumpLoginSet`,
`fillJumpForm` and `resolveSelectedJumpSession`, replacing each
`showFailure(...)` with the matching `SubmitRefusal` and each `return
false`/`return true` with the refusal/`nil`. The mode guards, the
`JumpLoginSetEligibility.isEligible` check, the synthetic `StoredSession`
construction and the `catch` classification all carry over unchanged.

**The one thing that must not move:** `isEligible` stays **above** the fill.
Write a doc comment saying so and why — and verify the sentence against the
code you actually wrote.

- [ ] **Step 4: Run the tests**

Run: `swift test --filter SubmitPreparation 2>&1 | tail -4`
Expected: all PASS.

- [ ] **Step 5: Prove the ordering test guards the ordering**

Mutation probe. Move the `isEligible` guard **below** the fill in
`resolveJumpLoginSet`.

Run: `swift test --filter aJumpBoundToANonSSHSetIsRefusedBeforeItsSecretIsRead 2>&1 | tail -6`
Expected: RED, and the failure must show the credential reached the form —
`form.jumpPassword.isEmpty` false. Copy the output verbatim into your report.

Revert:

```bash
git checkout -- Sources/macSCPCore/Presentation/SessionListViewModel+Submit.swift
git status --porcelain
```

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "feat(core): resolve the jump's login set and session before a submit"
```

---

### Task 3: The coordinator

**Files:**
- Modify: `Sources/macSCPCore/Presentation/SessionListViewModel+Submit.swift`
- Modify: `Tests/macSCPCoreTests/SubmitPreparationTests.swift`

**Interfaces:**
- Produces: `prepareForSubmit(form:) -> [SubmitRefusal]` — empty means the
  submit may proceed. Task 4 consumes it.

- [ ] **Step 1: Write the failing tests**

```swift
    /// All three resolutions run even when the first already refused, so
    /// every problem gets its own message instead of the user fixing them
    /// one reload at a time. A short-circuiting coordinator would return one
    /// refusal here.
    @Test func everyResolutionRunsEvenAfterOneRefuses() throws {
        // Form with BOTH a dangling target set and a dangling jump set.
        // #expect(vm.prepareForSubmit(form: form) == [.targetSetMissing, .jumpSetMissing])
    }

    /// The order is fixed so the App can present them deterministically.
    @Test func refusalsComeBackInTargetJumpSetJumpSessionOrder() throws {
        // Construct a form that refuses on the target and on the jump
        // SESSION, and assert the pair's order.
    }

    /// A clean form yields an empty list — the "may proceed" answer.
    @Test func acleanFormYieldsNoRefusals() throws {
        // #expect(vm.prepareForSubmit(form: form).isEmpty)
    }
```

- [ ] **Step 2: Run and watch them fail**

Run: `swift test --filter SubmitPreparation 2>&1 | tail -6`
Expected: compile failure.

- [ ] **Step 3: Write the coordinator**

```swift
    /// Runs every resolution the form needs before a submit and returns each
    /// refusal, in a fixed order. An empty result means the submit may
    /// proceed.
    ///
    /// None of the three is skipped when an earlier one refuses: each
    /// surfaces its own message, so a form with two problems reports both
    /// rather than making the user discover them one submit at a time.
    public func prepareForSubmit(form: ConnectionViewModel) -> [SubmitRefusal] {
        let target = resolveTargetLoginSet(form: form)
        let jumpSet = resolveJumpLoginSet(form: form)
        let jumpSession = resolveJumpSession(form: form)
        return [target, jumpSet, jumpSession].compactMap { $0 }
    }
```

The three `let`s before the array are load-bearing: folding them into the
literal would still evaluate all three, but a later reader could "simplify"
it into a short-circuiting chain. The test above is what stops that.

- [ ] **Step 4: Run the tests, then the whole suite**

Run: `swift test --filter SubmitPreparation 2>&1 | tail -4`, then
`swift test 2>&1 | tail -3`
Expected: green.

- [ ] **Step 5: Prove the no-short-circuit test guards it**

Mutation: rewrite the coordinator to return early on the first refusal.

Run: `swift test --filter everyResolutionRunsEvenAfterOneRefuses 2>&1 | tail -5`
Expected: RED. Copy verbatim, then revert and prove `git status --porcelain`
is clean.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "feat(core): collect every submit refusal instead of the first"
```

---

### Task 4: The App collapses onto it

**Files:**
- Modify: `Sources/MacSCPAppKit/ContentView.swift`

**Interfaces:**
- Consumes: `prepareForSubmit(form:) -> [SubmitRefusal]` and
  `SubmitRefusal.field`.

- [ ] **Step 1: Replace the closure**

```swift
                    resolveLoginSetForSubmit: {
                        let form = tab.connectionViewModel
                        let refusals = sessionListViewModel.prepareForSubmit(form: form)
                        for refusal in refusals {
                            form.showFailure(message: message(for: refusal), field: refusal.field)
                        }
                        return refusals.isEmpty
                    },
```

- [ ] **Step 2: Add the message mapping**

One private function on `ContentView` mapping each case to its existing
`L10n.string(key, default)` call — the exact key and default text each case
uses today, taken from the functions you are about to delete. The mapping
table is in the spec; **verify each pair against the current code** rather
than against the spec, and report any disagreement.

- [ ] **Step 3: Delete the four private functions**

`resolveSelectedLoginSet`, `resolveSelectedJumpLoginSet`, `fillJumpForm` and
`resolveSelectedJumpSession` go. `fillForm` stays only if something else
still calls it — check with the compiler, not with grep, and say which in
your report.

- [ ] **Step 4: Build and run the whole suite**

Run: `swift build 2>&1 | tail -3` then `swift test 2>&1 | tail -3`
Expected: build clean including the App target; suite green.

- [ ] **Step 5: Confirm the submit path holds no guard any more**

Run: `grep -n "isEligible\|JumpLoginSetEligibility\|\.kind ==" Sources/MacSCPAppKit/ContentView.swift`
Expected: no hit inside the submit path. Hits elsewhere (the picker filter,
for instance) are fine — say in your report which remain and why.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "refactor(app): let Core decide whether a submit may proceed"
```

---

### Task 5: Verification and close record

**Files:**
- Create: `docs/superpowers/specs/2026-08-10-m29-p2-abschluss.md`

- [ ] **Step 1: Run everything**

```bash
swift build 2>&1 | tail -3
swift test 2>&1 | tail -3
docker compose -f docker/test-server/compose.yml up -d
MACSCP_ITEST=1 swift test 2>&1 | tail -3
MACSCP_KEYCHAIN=1 swift test --filter Keychain 2>&1 | tail -2
for f in Sources/MacSCPAppKit/Resources/*.lproj/Localizable.strings Sources/macSCPCore/Resources/*.lproj/Localizable.strings; do printf "%s: " "$f"; plutil -lint "$f"; done
pgrep -fl swiftpm-testing-helper || echo "no orphans"
git status --porcelain
```

The Docker rig starts from the **main checkout**, never a worktree.

- [ ] **Step 2: Write the close record**

In German, following `2026-08-09-m29-p1-abschluss.md`'s shape. Cover: the
commit list; unpushed and ahead-of-`origin/main` counts; test counts before
and after; each of the eleven success criteria with its evidence; **the two
mutation outputs verbatim** with proof of a clean revert; the seven cases
whose message and field were checked against the old code, case by case;
and what is NOT verified — the GUI was not launched, so the new refusal's
wording and placement are unobserved.

- [ ] **Step 3: Commit**

```bash
git add -A
git commit -m "docs(m29): record the P2 close"
```

---

## Notes for the executing agent

- **Task 2 Step 5 is the milestone.** Everything else is plumbing that makes
  that one probe possible. If the probe does not go red with the credential
  visibly in the form, the port is wrong — report it rather than adjusting
  the test.
- **Seven of the eight refusals must reproduce today's behaviour exactly.**
  When in doubt, read the function you are replacing rather than this plan.
- **This plan's prose is a claim, not a fact.** Its predecessor shipped five
  errors that reached implementers. Verify, and say what you verified.
