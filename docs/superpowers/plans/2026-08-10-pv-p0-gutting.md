# PV + P0: Check view testability and tear down `ContentView` — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Determine whether SwiftUI views in this package are testable, and
tear down `ContentView` (3464 lines, ~3330 in a single `View` struct) so
that the decision logic lives in tested types and the file breaks into
readable pieces.

**Architecture:** Two kinds of work, clearly separated. **Extraction:**
pure decision functions become their own types with tests — that is the
line from M29-P2. **Splitting:** the `@ViewBuilder` blocks move as
`extension ContentView` into their own files, **without a single `@State`
changing owner** — moving state ownership is the riskiest operation in
SwiftUI, and the only one no test here can catch.

**Tech Stack:** Swift 6 (`.swiftLanguageMode(.v5)`), SwiftPM, macOS 15+,
SwiftUI, Swift Testing (`@Test`/`#expect`), two test targets
(`macSCPCoreTests`, `macSCPAppKitTests`).

## Global Constraints

- **Code, comments, test names, `reason:` strings: English.** No German
  identifiers or comments in source files.
- **User-facing strings** go through `L10n.string(_:_:)` or
  `String(localized:)`; never hardcoded. New keys in **all four**
  catalogs (en/de/fr/pl), verified with the existing guard test and
  `plutil -lint`.
- **Never write a line number into a comment.** Name the thing, not the
  line.
- **A comment that claims something about the code needs the same
  scrutiny as a test.** The prose in this plan is a claim to verify, not a
  truth: if it does not match the code, **the plan** is wrong — report it,
  don't silently rework it.
- **No secret gets logged, printed, or written into an error message** —
  not even into a test failure message. `#expect` expands its expression
  into the message; lift a value carrying a secret into a `Bool` first.
- **No `try?` decides a deletion.**
- **Commit/push only on explicit request** from the coordinator. No
  `scripts/release` — that publishes.
- **The GUI is not launched.** `scripts/package-app` (build) is allowed,
  `open dist/macSCP.app` is not.
- Commit footer on every commit:
  `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`
- Conventional Commits, commit messages in English.
- Full suite before every commit: `swift test`. Expected green:
  **1756 tests in 144 suites** (state before this plan; the number grows with
  every task and is measured freshly in the report, never copied from the plan).

## File structure

**New (extraction — one type per file, one test file per type):**

| File | Responsibility |
|---|---|
| `Sources/MacSCPAppKit/TabCloseWarning.swift` | Warning text when closing a tab |
| `Sources/MacSCPAppKit/SubmitRefusalText.swift` | `SubmitRefusal` → localized text |
| `Sources/macSCPCore/Sessions/SessionSecretPolicy.swift` | Which value gets written into a session's own secret slot |
| `Sources/MacSCPAppKit/CrossSessionTargets.swift` | Deriving target sessions from the tabs |
| `Sources/MacSCPAppKit/ImportFeedbackText.swift` | Error and result text for session import/export |

**New (splitting — `extension ContentView`, no state relocation):**

| File | Contents |
|---|---|
| `Sources/MacSCPAppKit/ContentView+Sheets.swift` | `sheetsAndAlerts` |
| `Sources/MacSCPAppKit/ContentView+Lifecycle.swift` | `lifecycleAndToolbar`, `performWindowSetup`, `handleWindowWillClose`, `updateMainWindowPresence`, `wireMenuBarBridge` |
| `Sources/MacSCPAppKit/ContentView+Detail.swift` | `detail`, `mainContent`, `splitLayout`, `windowChrome`, `terminalPanel` |
| `Sources/MacSCPAppKit/ContentView+Transfers.swift` | `uploadButton`, `downloadButton`, `transferSelection`, `transferToSession`, `uploadDropped`, `remotePromiseProvider`, `copyPaths`, `openInEditor` |
| `Sources/MacSCPAppKit/ContentView+ExportImport.swift` | `performExport`, `handleExportResult`, `handleImportFileSelection`, `decodeImport`, `applyImport` |

**Changed:** `Sources/MacSCPAppKit/ContentView.swift` (shrinks),
`Tests/macSCPAppKitTests/` (new test files),
`Sources/MacSCPAppKit/Resources/Localizable.xcstrings` + the three other
catalogs, in case a task relocates keys (it relocates them unchanged —
**no new key is created in P0**).

---

# PV — The pilot trial

### Task 1: Are SwiftUI views in this package testable?

**Time budget: at most one work session.** This task delivers an answer,
not a product. **No production code** is changed.

**Files:**
- Create: `docs/superpowers/specs/2026-08-10-pv-view-testability-report.md`
- Possibly temporary: `Tests/macSCPAppKitTests/ViewTestabilitySpike.swift` (will
  either be kept or deleted at the end — see step 6)
- Possibly temporary: `Package.swift` (only if a dependency is tried)

**Interfaces:**
- Consumes: nothing.
- Produces: the report. Subsequent tasks do **not** depend on it.

- [ ] **Step 1: Establish the current state**

There is already an app test target. Check what already works there:

```bash
ls Tests/macSCPAppKitTests/ && swift test --filter macSCPAppKitTests 2>&1 | tail -5
```

Note in the report which types are already tested there — they are
exclusively non-view types. That is the starting point.

- [ ] **Step 2: The cheapest attempt first — does it work without any new dependency?**

Write a test in `Tests/macSCPAppKitTests/ViewTestabilitySpike.swift` that
builds a real view from this project and asserts something about it.
`SheetSearchField` is the smallest candidate; look at its signature and
instantiate it. Try in this order:

1. Pure instantiation — does that even compile from the test target?
2. Apply `ImageRenderer` (SwiftUI, from macOS 13) to the view and check
   whether an `NSImage` with a size greater than zero comes out.
3. If (2) holds: render the same view with two different inputs and check
   that the resulting bitmaps **differ**.

Point 3 is the real test: a renderer that produces the same output for
every input proves nothing. **A pilot trial without a positive control
cannot distinguish its own failure from success.**

- [ ] **Step 3: Does it get along with Swift Testing?**

Write the trial as a `@Test` function, not as an `XCTestCase`. If that
fails, note the exact error message — it is the result.

- [ ] **Step 4: Does it run without a GUI session?**

```bash
swift test --filter ViewTestabilitySpike 2>&1 | tail -20
```

Also check whether the test needs a running window server session. One
way to establish that without involving CI: check whether the test
touches `NSApplication` or throws an exception about a missing window
server. Note what you actually observed — not what you expect.

- [ ] **Step 5: Only if step 2 fails — examine a dependency**

Only now, and only then. Check which SwiftUI test libraries exist,
whether they support Swift 6 and Swift Testing, and what they tie to the
toolchain. **Do not add anything to `Package.swift` without justifying it
in the report**, and revert the change if it fails.

- [ ] **Step 6: Write and commit the report**

The report answers exactly these five questions, each with what you
measured:

1. Can a view from `MacSCPAppKit` be instantiated in the test target?
2. Can its content be checked — and does the result **differ** for
   different inputs?
3. Does it get along with Swift Testing?
4. Does it run without a GUI session?
5. What does it cost in dependencies?

At the end stands a **one-sentence recommendation** and, if positive, the
runnable example test. If negative: delete `ViewTestabilitySpike.swift`,
reset `Package.swift`, and the report states the reason.

**"Probably works" is not a result.** If you could not measure it, write
down what stopped you.

```bash
git add docs/superpowers/specs/2026-08-10-pv-view-testability-report.md
git commit -m "docs(app): record whether SwiftUI views in this package can be tested"
```

**STOP.** After this task, the coordinator decides together with the
maintainer whether view tests belong in P0. The following tasks proceed
independently of the result.

---

# P0 — Teardown

## Part A: Extraction (logic + tests)

### Task 2: `TabCloseWarning`

The warning text shown when closing a tab decides which two reasons are
named and in what order. That is pure logic sitting in a view file.

**Files:**
- Create: `Sources/MacSCPAppKit/TabCloseWarning.swift`
- Create: `Tests/macSCPAppKitTests/TabCloseWarningTests.swift`
- Modify: `Sources/MacSCPAppKit/ContentView.swift` (`hasIncomingTransfers`,
  `closeWarningMessage`, and their callers)

**Interfaces:**
- Consumes: `SessionTab` (app-side, has `id`, `transferQueue`).
- Produces:
  - `enum TabCloseWarning { static func hasIncomingTransfers(for tabID: UUID, in tabs: [SessionTab]) -> Bool }`
  - `static func message(activeTransfers: Bool, incomingTransfers: Bool) -> String`

- [ ] **Step 1: Read the existing code**

Look at `closeWarningMessage(for:)` and `hasIncomingTransfers(for:)` in
`ContentView.swift`, plus their callers (`requestClose` and the
confirmation gate). **The text must not change** — the L10n keys
`tabs.close.activeTransfers` and `tabs.close.incomingTransfers` carry over
unchanged.

- [ ] **Step 2: Write the failing test**

```swift
import Foundation
import Testing
@testable import MacSCPAppKit

@Suite("TabCloseWarning")
struct TabCloseWarningTests {
    /// Both reasons can hold at once, and when they do the user sees both —
    /// one per line. A message that named only the first would leave them
    /// guessing which of the two applied.
    @Test func bothReasonsAreNamedWhenBothHold() {
        let text = TabCloseWarning.message(activeTransfers: true, incomingTransfers: true)

        #expect(text.split(separator: "\n").count == 2)
    }

    /// Neither reason holds: the message is empty, not a stray newline. The
    /// caller decides whether to show a dialog at all; an "empty" message
    /// that is actually "\n" makes an empty dialog look like a real warning.
    @Test func noReasonMeansNoText() {
        #expect(TabCloseWarning.message(activeTransfers: false, incomingTransfers: false).isEmpty)
    }

    /// One reason each, in isolation — proves the two lines are independent
    /// rather than one string that happens to contain both.
    @Test func eachReasonStandsAlone() {
        let active = TabCloseWarning.message(activeTransfers: true, incomingTransfers: false)
        let incoming = TabCloseWarning.message(activeTransfers: false, incomingTransfers: true)

        #expect(!active.isEmpty)
        #expect(!incoming.isEmpty)
        #expect(active != incoming)
    }
}
```

- [ ] **Step 3: Run the test red**

Run: `swift test --filter TabCloseWarning`
Expected: FAIL, `cannot find 'TabCloseWarning' in scope`.

- [ ] **Step 4: Create the type**

`Sources/MacSCPAppKit/TabCloseWarning.swift`:

```swift
import Foundation
import macSCPCore

/// The two reasons closing a tab is worth warning about, and the text that
/// names them. Lifted out of `ContentView` so the wording and the
/// both-reasons-at-once case are held by tests rather than by reading.
enum TabCloseWarning {
    /// True while any OTHER tab's queue holds a non-terminal item that
    /// targets this tab — closing it would sever those incoming
    /// cross-session streams.
    static func hasIncomingTransfers(for tabID: UUID, in tabs: [SessionTab]) -> Bool {
        tabs.contains { $0.id != tabID && $0.transferQueue.hasActiveItems(destinationTabID: tabID) }
    }

    /// One line per reason that holds, in a fixed order. Empty when neither
    /// holds — the caller decides whether a dialog appears at all.
    static func message(activeTransfers: Bool, incomingTransfers: Bool) -> String {
        var lines: [String] = []
        if activeTransfers {
            lines.append(L10n.string(
                "tabs.close.activeTransfers", "Active transfers in this tab will be canceled."))
        }
        if incomingTransfers {
            lines.append(L10n.string(
                "tabs.close.incomingTransfers",
                "Other tabs are streaming to this session; closing cancels those transfers."))
        }
        return lines.joined(separator: "\n")
    }
}
```

- [ ] **Step 5: Run the test green**

Run: `swift test --filter TabCloseWarning`
Expected: PASS, three tests.

- [ ] **Step 6: Switch `ContentView` over to the new type**

Delete `closeWarningMessage(for:)` and `hasIncomingTransfers(for:)` from
`ContentView` and replace **every** caller. `requestClose` then calls:

```swift
let incoming = TabCloseWarning.hasIncomingTransfers(for: tab.id, in: tabsModel.tabs)
closeWarningText = TabCloseWarning.message(
    activeTransfers: tab.transferQueue.isActive, incomingTransfers: incoming)
```

Verify with the compiler, not with `grep`, that no callers remain: a
build without errors is the proof.

- [ ] **Step 7: Full suite**

Run: `swift test`
Expected: everything green, three more tests than before.

- [ ] **Step 8: Commit**

```bash
git add Sources/MacSCPAppKit/TabCloseWarning.swift Tests/macSCPAppKitTests/TabCloseWarningTests.swift Sources/MacSCPAppKit/ContentView.swift
git commit -m "refactor(app): hold the tab-close warning text in a tested type"
```

---

### Task 3: `SubmitRefusalText`

`message(for refusal:)` maps the eight `SubmitRefusal` cases to text.
M29-P2 moved the refusal type into Core; its translation into text stayed
behind in `ContentView`, untested.

**Files:**
- Create: `Sources/MacSCPAppKit/SubmitRefusalText.swift`
- Create: `Tests/macSCPAppKitTests/SubmitRefusalTextTests.swift`
- Modify: `Sources/MacSCPAppKit/ContentView.swift`

**Interfaces:**
- Consumes: `SubmitRefusal` from `macSCPCore` with the cases
  `targetSetMissing`, `targetSetKindMismatch`, `jumpSetMissing`,
  `jumpSetNotSSH`, `jumpSessionMissing`, `jumpChainNotSupported`,
  `jumpSessionNotSSH`, `jumpSessionLoginUnresolvable`.
- Produces: `enum SubmitRefusalText { static func message(for refusal: SubmitRefusal) -> String }`

- [ ] **Step 1: Read the existing code**

`message(for refusal:)` in `ContentView.swift`. Carry over **every**
L10n key and every default text unchanged. Some cases interpolate values
into the text — carry over that formatting verbatim too.

- [ ] **Step 2: Write the failing test**

The valuable test is not "case X yields text Y" — that just copies the
implementation. What's valuable is **completeness**: no case may be empty
or identical to another.

```swift
import Foundation
import Testing
@testable import MacSCPAppKit
@testable import macSCPCore

@Suite("SubmitRefusalText")
struct SubmitRefusalTextTests {
    /// Every refusal case, listed by hand. A new case added to
    /// `SubmitRefusal` without a line here is caught by the exhaustive
    /// switch below, which fails to compile until it is handled.
    static let allCases: [SubmitRefusal] = [
        .targetSetMissing, .targetSetKindMismatch,
        .jumpSetMissing, .jumpSetNotSSH,
        .jumpSessionMissing, .jumpChainNotSupported,
        .jumpSessionNotSSH, .jumpSessionLoginUnresolvable,
    ]

    /// A refusal the user cannot read is a refusal that looks like a
    /// silent failure — the submit simply does nothing and no text appears.
    @Test func everyRefusalHasText() {
        for refusal in Self.allCases {
            let isEmpty = SubmitRefusalText.message(for: refusal).isEmpty
            #expect(isEmpty == false, "\(refusal) has no message")
        }
    }

    /// Two refusals that read identically send the user to fix the wrong
    /// thing. This is what a copy-paste slip in the mapping looks like.
    @Test func noTwoRefusalsReadTheSame() {
        var seen: [String: SubmitRefusal] = [:]
        for refusal in Self.allCases {
            let text = SubmitRefusalText.message(for: refusal)
            #expect(seen[text] == nil, "\(refusal) reads the same as \(String(describing: seen[text]))")
            seen[text] = refusal
        }
    }

    /// The list above is hand-maintained; this switch makes the compiler
    /// reject a new `SubmitRefusal` case that nobody added to it.
    @Test func theCaseListIsComplete() {
        for refusal in Self.allCases {
            switch refusal {
            case .targetSetMissing, .targetSetKindMismatch,
                .jumpSetMissing, .jumpSetNotSSH,
                .jumpSessionMissing, .jumpChainNotSupported,
                .jumpSessionNotSSH, .jumpSessionLoginUnresolvable:
                continue
            }
        }
        #expect(Self.allCases.count == 8)
    }
}
```

- [ ] **Step 3: Run the test red**

Run: `swift test --filter SubmitRefusalText`
Expected: FAIL, `cannot find 'SubmitRefusalText' in scope`.

- [ ] **Step 4: Create the type**

Move the body of `message(for refusal:)` **verbatim** into

```swift
enum SubmitRefusalText {
    static func message(for refusal: SubmitRefusal) -> String { … }
}
```

in `Sources/MacSCPAppKit/SubmitRefusalText.swift`. Change no text and no
key. If the existing code accesses `self` or `ContentView` state,
**stop and report it** — then it is not pure, and this plan was wrong.

- [ ] **Step 5: Run the test green**

Run: `swift test --filter SubmitRefusalText`
Expected: PASS.

- [ ] **Step 6: Switch `ContentView` over**

Delete `message(for:)`, switch callers to `SubmitRefusalText.message(for:)`.
Build as proof.

- [ ] **Step 7: Full suite and commit**

```bash
swift test
git add Sources/MacSCPAppKit/SubmitRefusalText.swift Tests/macSCPAppKitTests/SubmitRefusalTextTests.swift Sources/MacSCPAppKit/ContentView.swift
git commit -m "refactor(app): hold every submit refusal's text in a tested mapping"
```

---

### Task 4: `SessionSecretPolicy` (Core)

Which value gets written into a session's own secret slot is today
decided by a `private func` in a view file that builds its own two
stores — which is why it cannot be tested. This is the kind of decision
this project has already lost data over.

**Files:**
- Create: `Sources/macSCPCore/Sessions/SessionSecretPolicy.swift`
- Create: `Tests/macSCPCoreTests/SessionSecretPolicyTests.swift`
- Modify: `Sources/MacSCPAppKit/ContentView.swift`

**Interfaces:**
- Consumes: `ManagedKeyPassphrase.hasStoredPassphrase(keyPath:store:secrets:)`,
  `ManagedKeyStore`, `SecretStore`, `ConnectionKind`, `AuthKind`.
- Produces:
  ```swift
  public enum SessionSecretPolicy {
      public static func usesStoredManagedPassphrase(
          kind: ConnectionKind, authChoice: AuthKind, keyPath: String,
          keys: ManagedKeyStore, secrets: SecretStore) -> Bool
      public static func valueToPersist(
          resolvedSecret: String, kind: ConnectionKind, authChoice: AuthKind,
          keyPath: String, keys: ManagedKeyStore, secrets: SecretStore) -> String
  }
  ```

- [ ] **Step 1: Read the existing code**

`isManagedKeyWithStoredPassphrase(_:)` and `passwordToPersist(for:)` in
`ContentView.swift`, along with their doc comments. Pay particular
attention to the `catch` branch: it returns **`true`**, i.e. "do not
persist". That is intentional — an error while looking it up must not
cause a passphrase to be written a second time. **Do not flip this
direction.**

- [ ] **Step 2: Write the failing test**

Mind the secret rule: **no test may carry a secret value into a failure
message.** `#expect` expands its expression — that's why the code below
lifts into a `Bool` first.

```swift
import Foundation
import Testing
@testable import macSCPCore

@Suite("SessionSecretPolicy")
struct SessionSecretPolicyTests {
    private func emptyStores() throws -> (ManagedKeyStore, InMemorySecretStore) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (ManagedKeyStore(directory: dir), InMemorySecretStore())
    }

    /// A password login has no managed key involved at all, so its own
    /// secret is what gets persisted.
    @Test func aPasswordLoginPersistsItsOwnSecret() throws {
        let (keys, secrets) = try emptyStores()

        let value = SessionSecretPolicy.valueToPersist(
            resolvedSecret: "s3cret", kind: .ssh, authChoice: .password,
            keyPath: "", keys: keys, secrets: secrets)

        let matches = value == "s3cret"
        #expect(matches)
    }

    /// An agent login holds no secret at all; nothing is written.
    @Test func anAgentLoginPersistsNothing() throws {
        let (keys, secrets) = try emptyStores()

        let isEmpty = SessionSecretPolicy.valueToPersist(
            resolvedSecret: "", kind: .ssh, authChoice: .agent,
            keyPath: "", keys: keys, secrets: secrets).isEmpty
        #expect(isEmpty)
    }

    /// A private-key login whose key is NOT managed here still persists its
    /// own passphrase — the exemption is only for keys whose passphrase this
    /// app already keeps under the key's own identifier.
    @Test func anUnmanagedKeyPersistsItsOwnPassphrase() throws {
        let (keys, secrets) = try emptyStores()

        let isEmpty = SessionSecretPolicy.valueToPersist(
            resolvedSecret: "passphrase", kind: .ssh, authChoice: .privateKey,
            keyPath: "/nowhere/id_ed25519", keys: keys, secrets: secrets).isEmpty
        #expect(isEmpty == false)
    }

    /// The whitespace around a pasted path must not decide the answer — a
    /// trailing space would otherwise make a managed key look unmanaged and
    /// duplicate its passphrase into a second keychain slot.
    @Test func aPaddedKeyPathAnswersLikeItsTrimmedForm() throws {
        let (keys, secrets) = try emptyStores()

        let padded = SessionSecretPolicy.usesStoredManagedPassphrase(
            kind: .ssh, authChoice: .privateKey, keyPath: "  /nowhere/id_ed25519  ",
            keys: keys, secrets: secrets)
        let trimmed = SessionSecretPolicy.usesStoredManagedPassphrase(
            kind: .ssh, authChoice: .privateKey, keyPath: "/nowhere/id_ed25519",
            keys: keys, secrets: secrets)

        #expect(padded == trimmed)
    }
}
```

- [ ] **Step 3: Run the test red**

Run: `swift test --filter SessionSecretPolicy`
Expected: FAIL, `cannot find 'SessionSecretPolicy' in scope`.

- [ ] **Step 4: Create the type**

The body is the existing one, just with stores passed in instead of
self-built. **The `catch` branch stays `true`.** Write the reason as a
doc comment on the function, not as a repetition of this plan.

- [ ] **Step 5: Run the test green**

Run: `swift test --filter SessionSecretPolicy`
Expected: PASS, four tests.

- [ ] **Step 6: Switch `ContentView` over**

Delete both `private func`; the callers pass in
`ManagedKeyStore(directory: SessionStore.defaultDirectory)` and
`KeychainSecretStore()` — the same values as before, just now visible at
the call site.

- [ ] **Step 7: Full suite and commit**

```bash
swift test
git add Sources/macSCPCore/Sessions/SessionSecretPolicy.swift Tests/macSCPCoreTests/SessionSecretPolicyTests.swift Sources/MacSCPAppKit/ContentView.swift
git commit -m "refactor(core): move the session secret-slot decision out of the view"
```

---

### Task 5: `CrossSessionTargets`

Which other tabs get offered as a transfer target is a derivation over
the tab list — today it sits in `ContentView`, untested, even though it
decides where files go.

**Files:**
- Create: `Sources/MacSCPAppKit/CrossSessionTargets.swift`
- Create: `Tests/macSCPAppKitTests/CrossSessionTargetsTests.swift`
- Modify: `Sources/MacSCPAppKit/ContentView.swift`

**Interfaces:**
- Consumes: `SessionTab` (with `id`, `displayTitle`, `session`,
  `connectionViewModel.kind`), `CrossSessionTarget` from `macSCPCore`
  (`init(id:title:remotePath:kind:)`).
- Produces:
  `enum CrossSessionTargets { static func targets(excluding tabID: UUID, in tabs: [SessionTab]) -> [CrossSessionTarget] }`

- [ ] **Step 1: Read the existing code**

`crossSessionTargets(for:)` in `ContentView.swift`. Two rules live inside
it: the tab's own entry drops out, and a tab **without** a session drops
out.

- [ ] **Step 2: Write the failing test**

First look at `Tests/macSCPAppKitTests/SessionTabTests.swift` — it shows
how a `SessionTab` is built in a test. Use the same approach; don't
invent a second one.

```swift
import Foundation
import Testing
@testable import MacSCPAppKit
@testable import macSCPCore

@Suite("CrossSessionTargets")
struct CrossSessionTargetsTests {
    /// A tab never offers itself as a transfer destination — "copy to
    /// here" through the cross-session path would enqueue a job whose
    /// source and destination are the same remote.
    @Test func aTabIsNotOfferedAsItsOwnTarget() {
        let mine = SessionTab()
        let targets = CrossSessionTargets.targets(excluding: mine.id, in: [mine])

        #expect(targets.isEmpty)
    }

    /// A tab that is not connected has no remote to receive anything, so it
    /// is skipped rather than offered as a target that silently does
    /// nothing when clicked.
    @Test func aTabWithoutASessionIsSkipped() {
        let mine = SessionTab()
        let other = SessionTab()
        let targets = CrossSessionTargets.targets(excluding: mine.id, in: [mine, other])

        #expect(targets.isEmpty)
    }
}
```

**If `SessionTab()` cannot be built this way, or a connected session
cannot be produced in a test:** stop and report it. Write **no** test
that checks only the two empty cases and pretends that is the whole
rule — instead report what is missing, so the coordinator can decide.

- [ ] **Step 3: Run the test red**

Run: `swift test --filter CrossSessionTargets`
Expected: FAIL, `cannot find 'CrossSessionTargets' in scope`.

- [ ] **Step 4: Create the type, run the test green, switch `ContentView` over**

```swift
enum CrossSessionTargets {
    static func targets(excluding tabID: UUID, in tabs: [SessionTab]) -> [CrossSessionTarget] {
        tabs.compactMap { other in
            guard other.id != tabID, let session = other.session else { return nil }
            return CrossSessionTarget(
                id: other.id, title: other.displayTitle,
                remotePath: session.remote.currentPath,
                kind: other.connectionViewModel.kind)
        }
    }
}
```

Run: `swift test --filter CrossSessionTargets` → PASS.
Then delete `crossSessionTargets(for:)` and switch the callers over.

- [ ] **Step 5: Full suite and commit**

```bash
swift test
git add Sources/MacSCPAppKit/CrossSessionTargets.swift Tests/macSCPAppKitTests/CrossSessionTargetsTests.swift Sources/MacSCPAppKit/ContentView.swift
git commit -m "refactor(app): derive cross-session transfer targets in a tested type"
```

---

### Task 6: `ImportFeedbackText`

Three text mappings for session import and export sit as `private func`
in `ContentView`: `readErrorMessage(_:)`, `importErrorText(for:)`, and
`importResultText(…)`.

**Files:**
- Create: `Sources/MacSCPAppKit/ImportFeedbackText.swift`
- Create: `Tests/macSCPAppKitTests/ImportFeedbackTextTests.swift`
- Modify: `Sources/MacSCPAppKit/ContentView.swift`

**Interfaces:**
- Consumes: `SessionExportError` from `macSCPCore`.
- Produces: `enum ImportFeedbackText` with the three functions under the
  same names and signatures they have today in `ContentView`.

- [ ] **Step 1: Read the three functions and note their exact signatures**

`readErrorMessage(_:)`, `importErrorText(for:)`, `importResultText(…)` in
`ContentView.swift`. Note `importResultText`'s parameter list verbatim —
it has several parameters, and the plan deliberately does not copy it, so
that no invented signature results here.

- [ ] **Step 2: Write the failing test**

The same shape as in Task 3: not text against text, but completeness and
distinguishability.

```swift
import Foundation
import Testing
@testable import MacSCPAppKit
@testable import macSCPCore

@Suite("ImportFeedbackText")
struct ImportFeedbackTextTests {
    /// An import that failed and says nothing is indistinguishable from one
    /// that silently did nothing.
    @Test func everyExportErrorHasText() {
        for error in SessionExportError.allTestCases {
            let isEmpty = ImportFeedbackText.importErrorText(for: error).isEmpty
            #expect(isEmpty == false, "\(error) has no message")
        }
    }

    /// Two different failures that read the same send the user to fix the
    /// wrong thing.
    @Test func noTwoExportErrorsReadTheSame() {
        var seen = Set<String>()
        for error in SessionExportError.allTestCases {
            let text = ImportFeedbackText.importErrorText(for: error)
            #expect(seen.insert(text).inserted, "\(error) duplicates another message")
        }
    }
}
```

`SessionExportError.allTestCases` does not exist yet. Create it in the
**test target** (not in Core), as an `extension SessionExportError` with
a hand-maintained list plus an exhaustive `switch` that makes the
compiler flag a new case — exactly as in Task 3.

- [ ] **Step 3: Run the test red**

Run: `swift test --filter ImportFeedbackText`
Expected: FAIL.

- [ ] **Step 4: Create the type, run the test green, switch `ContentView` over**

Move the bodies verbatim, change no text, switch the callers over, build
as proof.

- [ ] **Step 5: Full suite and commit**

```bash
swift test
git add Sources/MacSCPAppKit/ImportFeedbackText.swift Tests/macSCPAppKitTests/ImportFeedbackTextTests.swift Sources/MacSCPAppKit/ContentView.swift
git commit -m "refactor(app): hold import and export feedback text in a tested mapping"
```

---

## Part B: Splitting (no state relocation)

**The same guarantee and the same procedure apply to every task in Part
B.** Read this once here; the tasks do not repeat it.

**The guarantee: no behavior changes.** Nothing is renamed, nothing is
reordered, no `@State` changes owner, no modifier order changes.

**The procedure:** The block moves as an `extension ContentView` into a
new file of the same module. Because `private` in Swift applies
**file-wide**, moved members lose access to the `private` members that
remain in `ContentView.swift`. Therefore:

- A moved member is changed from `private` to **module-wide** (no access
  modifier).
- A member that remains in `ContentView.swift` and needs a moved member
  also becomes module-wide.
- **Nothing becomes `public`.** Visibility ends at `MacSCPAppKit`.

**Why not a genuine, separate view type:** A new `struct SomeView: View`
would require every piece of state it reads to be passed in explicitly —
and that is exactly where the errors that no test here can catch would
arise. An `extension` solves the readability problem without touching
state ownership. Where a separate type is easily possible, the task says
so explicitly.

**The proof for each task:** `swift build` without errors **and** without
new warnings, `swift test` fully green, and `git diff --stat` shows
almost only deletions for `ContentView.swift`. If the diff shows changes
to lines you only meant to move, that is a finding — look into it, don't
wave it through.

---

### Task 7: `ContentView+Detail.swift`

**Files:**
- Create: `Sources/MacSCPAppKit/ContentView+Detail.swift`
- Modify: `Sources/MacSCPAppKit/ContentView.swift`

- [ ] **Step 1: Identify the blocks**

`detail`, `mainContent`, `splitLayout`, `windowChrome(_:)`,
`terminalPanel(_:)`, `tabIDs`. Note the line count of `ContentView.swift`
**before** moving anything:

```bash
wc -l Sources/MacSCPAppKit/ContentView.swift
```

- [ ] **Step 2: Move**

New file with `import SwiftUI`, `import macSCPCore`, and
`extension ContentView { … }`. Move the six members in verbatim, remove
`private`. Any other `private` members in `ContentView.swift` that become
unreachable as a result also become module-wide — the compiler tells you
exactly which.

- [ ] **Step 3: Build and suite**

```bash
swift build 2>&1 | tail -20 && swift test
```
Expected: build without errors and without new warnings, suite fully green.

- [ ] **Step 4: Check the diff**

```bash
git diff --stat Sources/MacSCPAppKit/ContentView.swift
```
Expected: almost exclusively deletions. Changes to lines that were
supposed to stay are a finding.

- [ ] **Step 5: Commit**

```bash
git add Sources/MacSCPAppKit/ContentView+Detail.swift Sources/MacSCPAppKit/ContentView.swift
git commit -m "refactor(app): move the detail pane builders into their own file"
```

---

### Task 8: `ContentView+Sheets.swift`

**Files:**
- Create: `Sources/MacSCPAppKit/ContentView+Sheets.swift`
- Modify: `Sources/MacSCPAppKit/ContentView.swift`

Same procedure as Task 7, with `sheetsAndAlerts(_:)` plus the bindings
used only there (`passwordHintPresented`, `externalTerminalErrorPresented`)
and the sheet presentation functions `presentSnippets`,
`presentLoginSetsFromSettings`, `presentServerCertificatesFromSettings`,
`presentHiddenImportsFromSettings`.

This is the largest block. After moving it, check especially that the
**order** of the `.sheet` and `.alert` modifiers is unchanged: with
several sheets on the same view, order decides which one wins.

- [ ] Step 1: Note the line count, identify the blocks
- [ ] Step 2: Move, `private` → module-wide
- [ ] Step 3: `swift build` and `swift test` — both green
- [ ] Step 4: Check `git diff --stat` — almost only deletions
- [ ] Step 5: Commit

```bash
git add Sources/MacSCPAppKit/ContentView+Sheets.swift Sources/MacSCPAppKit/ContentView.swift
git commit -m "refactor(app): move the sheet and alert wiring into its own file"
```

---

### Task 9: `ContentView+Lifecycle.swift`

**Files:**
- Create: `Sources/MacSCPAppKit/ContentView+Lifecycle.swift`
- Modify: `Sources/MacSCPAppKit/ContentView.swift`

Contents: `lifecycleAndToolbar(_:)`, `performWindowSetup`,
`handleWindowWillClose(_:)`, `updateMainWindowPresence`,
`wireMenuBarBridge`, `handleCloseActiveTabCommand`, `resizeWindow(toWidth:height:)`,
`shrinkIfPristine`, `makeTab`, `attachAuditRecorder(…)`, `teardown(_:)`,
`activate(_:)`, `selectTab(atIndex:)`, `requestClose(_:)`, `performClose(_:)`.

Here the order of the cleanup steps hangs on a project invariant:
**`cancelAll` → `shutdown` → `disconnect`** in `teardown`. If anything
gets reordered here, this is no longer just a move.

- [ ] Step 1: Note the line count, identify the blocks
- [ ] Step 2: Move, `private` → module-wide
- [ ] Step 3: `swift build` and `swift test` — both green
- [ ] Step 4: Check `git diff --stat`; additionally hold the order in
      `teardown` against the state before the move
      (`git show HEAD:Sources/MacSCPAppKit/ContentView.swift`)
- [ ] Step 5: Commit

```bash
git add Sources/MacSCPAppKit/ContentView+Lifecycle.swift Sources/MacSCPAppKit/ContentView.swift
git commit -m "refactor(app): move tab lifecycle and window setup into their own file"
```

---

### Task 10: `ContentView+Transfers.swift`

**Files:**
- Create: `Sources/MacSCPAppKit/ContentView+Transfers.swift`
- Modify: `Sources/MacSCPAppKit/ContentView.swift`

Contents: `uploadButton(in:session:)`, `downloadButton(in:session:)`,
`transferSelection(…)`, `transferToSession(…)`, `uploadDropped(_:in:)`,
`remotePromiseProvider(…)`, `copyPaths(of:)`, `openInEditor(…)`.

- [ ] Step 1: Note the line count, identify the blocks
- [ ] Step 2: Move, `private` → module-wide
- [ ] Step 3: `swift build` and `swift test` — both green
- [ ] Step 4: Check `git diff --stat` — almost only deletions
- [ ] Step 5: Commit

```bash
git add Sources/MacSCPAppKit/ContentView+Transfers.swift Sources/MacSCPAppKit/ContentView.swift
git commit -m "refactor(app): move the transfer actions into their own file"
```

---

### Task 11: `ContentView+ExportImport.swift`

**Files:**
- Create: `Sources/MacSCPAppKit/ContentView+ExportImport.swift`
- Modify: `Sources/MacSCPAppKit/ContentView.swift`

Contents: `performExport(…)`, `handleExportResult(_:)`,
`handleImportFileSelection(_:)`, `decodeImport(data:password:)`,
`applyImport(_:)`.

**Caution:** secret paths live in this area. When moving code, no value
may end up in a log or error output that wasn't there before — and none
that was there is silently removed (that would also be a behavior
change; if you notice one, **report it instead of fixing it** — that is
its own finding).

- [ ] Step 1: Note the line count, identify the blocks
- [ ] Step 2: Move, `private` → module-wide
- [ ] Step 3: `swift build` and `swift test` — both green
- [ ] Step 4: Check `git diff --stat` — almost only deletions
- [ ] Step 5: Commit

```bash
git add Sources/MacSCPAppKit/ContentView+ExportImport.swift Sources/MacSCPAppKit/ContentView.swift
git commit -m "refactor(app): move session export and import wiring into their own file"
```

---

## Part C: Closeout

### Task 12: Phase closeout

**Files:**
- Create: `docs/superpowers/specs/2026-08-10-p0-gutting-closeout.md`

- [ ] **Step 1: Measure again**

```bash
wc -l Sources/MacSCPAppKit/*.swift | sort -rn | head -12
swift test 2>&1 | tail -5
```

Write the **measured** numbers into the report. The starting value was
`ContentView.swift` at 3464 lines and the suite at 1756 tests in 144
suites; both numbers are measurements from before this plan and are not
copied down, but held against the result.

- [ ] **Step 2: Dev build**

```bash
MACSCP_VERSION="1.2.0-dev" MACSCP_BUILD="$(git rev-list --count HEAD)" ./scripts/package-app
```

Expected: `wrote dist/macSCP.app`. **The app is not launched.**

- [ ] **Step 3: Write the report**

It states:

1. The measured line counts before/after and the new test count.
2. Which decision logic is now held by tests and which is not yet.
3. **Explicitly:** that the guarantee "no behavior changed" is backed by
   the build and the suite, **not** by a visual check — the GUI was not
   launched, and the visual check is the maintainer's job.
4. The result of PV and what follows from it for the views.
5. What remains open.

- [ ] **Step 4: Commit**

```bash
git add docs/superpowers/specs/2026-08-10-p0-gutting-closeout.md
git commit -m "docs(app): record the ContentView teardown"
```

---

## Self-review of this plan

**Spec coverage.** PV → Task 1. P0 "splitting" → Tasks 7–11. P0
"extraction with tests" → Tasks 2–6. "Small, individually committed
steps" → every task commits individually, Part B additionally with a
diff check. "A dev build at the end of the phase is mandatory" → Task 12
step 2. "Only `ContentView`" → no other large file appears.

**Deliberate gap.** The spec also names "which path is taken to the
external terminal" as a candidate. `ExternalTerminalLauncher` has
**already** been its own tested type since M29-P1; what remains in
`ContentView` (`requestExternalTerminal`, `performExternalOpen`) is
wiring and moves along with Task 9. No separate task needed.

**Two places where this plan could have guessed** — both are marked as
stop-and-report rather than as a prescription: the exact signature of
`importResultText` (Task 6, step 1) and the question of whether a
`SessionTab` with a connected session can even be produced in a test
(Task 5, step 2). A plan that had invented both would have sent
implementers into the wrong tests.
