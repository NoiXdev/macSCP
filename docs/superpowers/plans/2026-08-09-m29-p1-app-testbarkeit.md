# M29-P1 — Das App-Target prüfbar machen: Fundament (Implementation Plan)

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> superpowers:subagent-driven-development (recommended) or
> superpowers:executing-plans to implement this plan task-by-task. Steps use
> checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the App layer reachable by tests — split `MacSCPApp` into a
library plus a one-file executable, add a second test target, and fix the
localization lookup so it resolves under `swift test` for the first time.

**Architecture:** `Sources/MacSCPApp/` is renamed to
`Sources/MacSCPAppKit/` and declared as a `.target` (library). A new
`Sources/MacSCPMain/` holds the `@main` entry and nothing else. A new
`macSCPAppKitTests` target uses `@testable import MacSCPAppKit`. Both
localization helpers gain the one search candidate that makes the resource
bundle findable next to the test bundle.

**Tech Stack:** Swift 6 (`.swiftLanguageMode(.v5)`), SwiftPM, macOS 15+,
Swift Testing (`@Test`/`#expect`).

Spec: `../specs/2026-08-09-m29-p1-app-testbarkeit-design.md`.

## Global Constraints

- **Code, comments, identifiers, test names: English only.** Internal docs
  (`docs/`) may be German.
- **No behaviour change.** The app must do exactly what it did before. Any
  observed difference is a defect, not a result.
- Swift tools 6.0, **every target `.swiftLanguageMode(.v5)`**, minimum
  macOS 15.
- Tests: Swift Testing, TDD red→green. New logic ships with tests; prove a
  regression red first.
- **Never commit key material or secrets.** Secrets live only in the macOS
  Keychain.
- **A secret's value is never printed, logged, or embedded in an error** —
  including a test failure message.
- **Never write a line number into a comment.** Name the thing, not the line.
- **A comment asserting something about the code needs the same verification
  as a test.** Check each sentence against the function it describes.
- **Do NOT run `scripts/release`** — it publishes. Read it, edit it, never
  execute it.
- **Do NOT launch the GUI app.**
- Conventional Commits, English. Footer on every commit:
  `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`
- Commit only; **never push**.
- Unit suite: `swift test`. Gated suites: `MACSCP_ITEST=1` (Docker rig) and
  `MACSCP_KEYCHAIN=1` (real keychain).
- Baseline before this plan: **1679 tests in 131 suites, green.**

---

## File Structure

| File | Responsibility |
|---|---|
| `Package.swift` | Declares the library, the thin executable, and the second test target |
| `Sources/MacSCPAppKit/**` | Everything that was `Sources/MacSCPApp/**`, unchanged content except `MacSCPApp.swift` and `L10n.swift` |
| `Sources/MacSCPAppKit/AppMain.swift` | **New.** The single `public` symbol: starts the SwiftUI app |
| `Sources/MacSCPAppKit/MacSCPApp.swift` | Loses `@main`, stays internal |
| `Sources/MacSCPAppKit/L10n.swift` | Gains the sibling-directory search candidate and a `BundleFinder` |
| `Sources/MacSCPMain/Main.swift` | **New.** `@main`, one call, nothing else |
| `Sources/macSCPCore/…/CoreL10n.swift` | Same search candidate; its false doc claim corrected |
| `Tests/macSCPAppKitTests/**` | **New.** The App layer's tests |
| `scripts/package-app`, `scripts/release` | Bundle name follows the target rename |

---

### Task 1: The package split

Turns the executable into a library plus a one-file entry point, adds the
test target, and follows the bundle rename through the two packaging
scripts. **No logic changes anywhere.**

**Files:**
- Rename: `Sources/MacSCPApp/` → `Sources/MacSCPAppKit/` (use `git mv`)
- Create: `Sources/MacSCPAppKit/AppMain.swift`
- Create: `Sources/MacSCPMain/Main.swift`
- Modify: `Sources/MacSCPAppKit/MacSCPApp.swift` (remove `@main`)
- Modify: `Sources/MacSCPAppKit/L10n.swift` (bundle name string only)
- Modify: `Package.swift`
- Modify: `scripts/package-app`, `scripts/release`
- Test: `Tests/macSCPAppKitTests/TargetReachabilityTests.swift`

**Interfaces:**
- Produces: `public enum AppMain { public static func main() }` in module
  `MacSCPAppKit` — the only new `public` symbol in the whole plan.
- Produces: test target `macSCPAppKitTests`, which later tasks extend.

- [ ] **Step 1: Move the sources**

```bash
git mv Sources/MacSCPApp Sources/MacSCPAppKit
```

- [ ] **Step 2: Add the public entry wrapper**

Create `Sources/MacSCPAppKit/AppMain.swift`:

```swift
import Foundation

/// The one symbol the executable target needs. Everything else in this
/// module stays `internal`.
///
/// `MacSCPApp` itself is deliberately NOT made `public`: the `App` protocol
/// requires `body`, so a public conformer would force `public` onto `body`
/// and its whole scene tree — spreading access widening through the UI for
/// no benefit. A wrapper keeps the widening at exactly one symbol.
///
/// `App.main()` is the standard programmatic entry point; the executable
/// calls it instead of carrying `@main` on the app struct, because that
/// attribute has to sit in the executable target.
public enum AppMain {
    public static func main() {
        MacSCPApp.main()
    }
}
```

- [ ] **Step 3: Add the executable's only file**

Create `Sources/MacSCPMain/Main.swift`:

```swift
import MacSCPAppKit

/// The executable target: an entry point and nothing else. All app code
/// lives in `MacSCPAppKit`, where tests can reach it.
@main
struct Main {
    static func main() {
        AppMain.main()
    }
}
```

- [ ] **Step 4: Remove `@main` from the app struct**

In `Sources/MacSCPAppKit/MacSCPApp.swift`, delete the `@main` line directly
above `struct MacSCPApp: App {`. Change nothing else in that file — the
struct stays internal.

- [ ] **Step 5: Follow the bundle rename in `L10n`**

In `Sources/MacSCPAppKit/L10n.swift`, change the bundle name literal:

```swift
let bundleName = "macSCP_MacSCPAppKit.bundle"
```

Leave the rest of `L10n` alone — the search itself is Task 2.

- [ ] **Step 6: Rewrite the package manifest's targets and products**

In `Package.swift`, replace the `.executable(name: "macSCP", …)` product and
the `MacSCPApp` target. The `macSCPCore`, `MacSCPCLI` and `macSCPCoreTests`
targets are untouched.

```swift
        .executable(name: "macSCP", targets: ["MacSCPMain"]),
```

```swift
        .target(
            name: "MacSCPAppKit",
            dependencies: [
                "macSCPCore",
                .product(name: "SwiftTerm", package: "SwiftTerm"),
            ],
            resources: [.process("Resources")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "MacSCPMain",
            dependencies: ["MacSCPAppKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "macSCPAppKitTests",
            dependencies: ["MacSCPAppKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
```

The product name stays `macSCP`, so the built binary keeps its name and
`scripts/package-app` finds `$BIN` unchanged.

- [ ] **Step 7: Write the failing reachability test**

Create `Tests/macSCPAppKitTests/TargetReachabilityTests.swift`:

```swift
import Foundation
import Testing
@testable import MacSCPAppKit

@Suite("Target reachability")
struct TargetReachabilityTests {
    /// The whole point of P1: App-layer code that is not a SwiftUI view can
    /// be named from a test. Before the split this file could not compile —
    /// there was no test target that could import the app.
    ///
    /// `KeyboardShortcutsCatalog` is `internal`, so this also pins that
    /// `@testable import` reaches internal symbols, which every later App
    /// test depends on.
    @Test func internalAppSymbolsAreVisibleToTests() {
        #expect(KeyboardShortcutsCatalog.groups.isEmpty == false)
    }
}
```

- [ ] **Step 8: Run it and watch it fail before the manifest is right**

Run: `swift build 2>&1 | tail -20`

Expected while the manifest is still wrong: an error naming the missing
target or module. Once Step 6 is applied correctly, the build succeeds. Do
not proceed until `swift build` exits 0 — including the executable.

- [ ] **Step 9: Update the two packaging scripts**

In `scripts/package-app`, both the copy and the assertion:

```bash
cp -R "$ARM_BIN/macSCP_MacSCPAppKit.bundle" "$APP/Contents/Resources/"
```

```bash
test -d "$APP/Contents/Resources/macSCP_MacSCPAppKit.bundle"
```

In `scripts/release`, the codesign argument list:

```bash
    "$APP/Contents/Resources/macSCP_MacSCPAppKit.bundle" \
```

**Do not run `scripts/release`.** Verify by reading, and by grepping that no
`macSCP_MacSCPApp.bundle` occurrence remains anywhere:

Run: `grep -rn "macSCP_MacSCPApp\.bundle" . --exclude-dir=.build --exclude-dir=.git`
Expected: no output.

- [ ] **Step 10: Run the whole suite**

Run: `swift test 2>&1 | tail -3`
Expected: **1680 tests** (1679 + the reachability test), all green, in 132
suites.

- [ ] **Step 11: Commit**

```bash
git add -A
git commit -m "refactor(app): split MacSCPApp into a library and a one-file entry point"
```

---

### Task 2: The localization lookup, and the guard on it

Adds the one missing search candidate to both helpers, so the resource
bundle is found next to the test bundle, and pins that with a test in each
layer. Corrects `CoreL10n`'s doc comment, which claims this already works.

**Files:**
- Modify: `Sources/macSCPCore/…/CoreL10n.swift`
- Modify: `Sources/MacSCPAppKit/L10n.swift`
- Test: `Tests/macSCPCoreTests/CoreL10nTests.swift` (create)
- Test: `Tests/macSCPAppKitTests/L10nTests.swift` (create)

**Interfaces:**
- Consumes: the test target from Task 1.
- Produces: nothing new for later tasks — but after this task
  `L10n.string(_:_:)` returns real localized text under `swift test`, which
  Task 3's `UpdateAlertContent` tests and Task 4's `SessionTab.displayTitle`
  test rely on.

**Why the assertions look the way they do.** The tests must NOT assert a
specific translation. `NSLocalizedString` picks the host's preferred
language — German on the maintainer's Mac, English in CI — so asserting
either text would make the suite pass on one machine and fail on the other.
What the tests assert instead is that the lookup **resolved at all**:
the returned string differs from a deliberately absurd fallback. That holds
in every language and still goes red on a renamed bundle, a missing key, or
a removed candidate.

- [ ] **Step 1: Write the failing Core test**

Create `Tests/macSCPCoreTests/CoreL10nTests.swift`:

```swift
import Foundation
import Testing
@testable import macSCPCore

@Suite("CoreL10n")
struct CoreL10nTests {
    /// `CoreL10n.string` returns the KEY when the resource bundle cannot be
    /// found. Under `swift test` that was always the case, which silently
    /// made dozens of `#expect(error == CoreL10n.string(…))` assertions
    /// compare a key against itself — they could not fail.
    ///
    /// Deliberately not asserting a specific translation: the host's
    /// preferred language decides which one comes back, so any fixed text
    /// would pass on one machine and fail on another. "Resolved at all" is
    /// the property that matters and it is language-independent.
    @Test func aKnownKeyResolvesToSomethingOtherThanItself() {
        let key = "core.login.mergeConflictingSecrets"
        #expect(CoreL10n.string(key) != key)
    }

    /// A key that exists in no catalog must still come back as itself — the
    /// documented graceful degradation. Pins that the fix did not turn a
    /// missing key into a crash or an empty string.
    @Test func anUnknownKeyStillReturnsItself() {
        let key = "core.this.key.does.not.exist"
        #expect(CoreL10n.string(key) == key)
    }
}
```

- [ ] **Step 2: Run it and confirm the first test fails**

Run: `swift test --filter CoreL10n 2>&1 | tail -6`
Expected: `aKnownKeyResolvesToSomethingOtherThanItself` FAILS — the lookup
returns the key. `anUnknownKeyStillReturnsItself` passes already.

- [ ] **Step 3: Add the missing candidate in Core**

In `Sources/macSCPCore/…/CoreL10n.swift`, extend the candidate list:

```swift
    static let bundle: Bundle = {
        let candidates = [
            Bundle.main.resourceURL,
            Bundle(for: BundleFinder.self).resourceURL,
            Bundle.main.bundleURL,
            Bundle(for: BundleFinder.self).bundleURL.deletingLastPathComponent(),
        ].compactMap { $0 }
```

Append it last so no existing resolution order changes.

- [ ] **Step 4: Correct the doc comment's false claim**

The comment currently ends with: "In the test target `Bundle.module`'s own
search succeeds normally, so tests exercise the same lookup as production
code." That was untrue. Replace that sentence with:

```swift
/// Under `swift test` the module is linked into the test runner, so
/// `Bundle(for:)` returns the `.xctest` bundle and `Bundle.main` is the
/// test helper — neither CONTAINS the resource bundle. It sits BESIDE the
/// test bundle instead, which is why the last candidate walks up one level
/// from `Bundle(for:)`'s own URL. Without it every lookup fell through to
/// `Bundle.main` and `string(_:)` returned the raw key, which is what made
/// key-against-key assertions vacuous for several milestones.
```

- [ ] **Step 5: Run the Core test again**

Run: `swift test --filter CoreL10n 2>&1 | tail -4`
Expected: both tests PASS.

- [ ] **Step 6: Run the FULL suite and collect the fallout**

Run: `swift test 2>&1 | tail -40`

Existing assertions that compared a key against itself now compare real text
against a key and **may go red**. This is expected and is the proof the fix
works. For each failure:

1. Read the assertion. If it compares an error message against
   `CoreL10n.string(key)` on both sides, it is still correct — both sides
   moved together and it should stay green.
2. If it compares against a **literal key string**, the literal is the bug:
   replace it with `CoreL10n.string(key)` so the test asserts the mapping
   rather than the raw identifier.
3. **Never** revert the fix to keep a test green. A test that only passed
   because nothing resolved was asserting nothing.

Record every repaired test by name — the close report lists them
individually.

- [ ] **Step 7: Commit the Core half**

```bash
git add -A
git commit -m "fix(core): find the string catalog next to the test bundle"
```

- [ ] **Step 8: Write the failing App test**

Create `Tests/macSCPAppKitTests/L10nTests.swift`:

```swift
import Foundation
import Testing
@testable import MacSCPAppKit

@Suite("L10n")
struct L10nTests {
    /// The App layer's lookup falls back to `Bundle.main`, where the key is
    /// absent, so `NSLocalizedString` hands back the `defaultValue` — every
    /// string in English, with no crash and no failing test. Renaming the
    /// target's bundle would have re-armed exactly that.
    ///
    /// The fallback here is deliberately absurd: if the real catalog is
    /// found, no language can return this string, so the assertion holds in
    /// German, English, French and Polish alike.
    @Test func aKnownKeyResolvesInsteadOfFallingBackToTheDefault() {
        let resolved = L10n.string("tabs.newConnection", "ZZ-UNRESOLVED-ZZ")
        #expect(resolved != "ZZ-UNRESOLVED-ZZ")
    }

    /// The graceful-degradation half: an unknown key must return the
    /// supplied default rather than an empty string, so a typo shows up as
    /// readable English in the UI instead of a blank control.
    @Test func anUnknownKeyReturnsTheSuppliedDefault() {
        #expect(L10n.string("app.this.key.does.not.exist", "Readable default") == "Readable default")
    }

    /// The bundle the lookup settled on must not be `Bundle.main` — that is
    /// the silent-failure state itself, and the assertion above would still
    /// pass if some unrelated main-bundle key happened to match.
    @Test func theLookupDidNotSettleForTheMainBundle() {
        #expect(L10n.bundle != Bundle.main)
    }
}
```

- [ ] **Step 9: Run it and confirm two tests fail**

Run: `swift test --filter L10n 2>&1 | tail -8`
Expected: `aKnownKeyResolvesInsteadOfFallingBackToTheDefault` and
`theLookupDidNotSettleForTheMainBundle` FAIL.

- [ ] **Step 10: Add the missing candidate in the App layer**

In `Sources/MacSCPAppKit/L10n.swift`, add a finder class and the sibling
candidate:

```swift
enum L10n {
    private final class BundleFinder {}

    static let bundle: Bundle = {
        let bundleName = "macSCP_MacSCPAppKit.bundle"
        let candidates = [
            Bundle.main.bundleURL,
            Bundle.main.resourceURL,
            Bundle.main.executableURL?.deletingLastPathComponent(),
            Bundle(for: BundleFinder.self).bundleURL.deletingLastPathComponent(),
        ].compactMap { $0 }
```

Keep the rest of the closure as it is. The new candidate goes last, so the
app's own resolution order is unchanged; in a real `.app` it resolves to the
directory containing the bundle, finds nothing there, and is skipped.

Extend the type's doc comment with why the candidate exists — the same
reasoning as in Core, phrased for this target. Do not copy Core's wording
verbatim; state what THIS lookup does.

- [ ] **Step 11: Run the App tests**

Run: `swift test --filter L10n 2>&1 | tail -4`
Expected: all three PASS.

- [ ] **Step 12: Prove the guard actually guards**

Mutation probe. Temporarily change the bundle name in
`Sources/MacSCPAppKit/L10n.swift` to `"macSCP_WrongName.bundle"`.

Run: `swift test --filter L10n 2>&1 | tail -6`
Expected: `aKnownKeyResolvesInsteadOfFallingBackToTheDefault` and
`theLookupDidNotSettleForTheMainBundle` go RED. Copy the output verbatim
into the task report.

Revert:

```bash
git checkout -- Sources/MacSCPAppKit/L10n.swift
git status --porcelain
```

Expected: no output for that file.

- [ ] **Step 13: Run the whole suite and commit**

Run: `swift test 2>&1 | tail -3`
Expected: green.

```bash
git add -A
git commit -m "fix(app): resolve the string catalog under swift test and guard it"
```

---

### Task 3: Tests for the pure content types

`UpdateAlertContent` maps a Core result to display copy; `KeyboardShortcuts
Catalog` is hand-maintained data whose whole risk is drifting from the
bindings it mirrors. Both are pure and need no UI.

**Files:**
- Test: `Tests/macSCPAppKitTests/UpdateAlertContentTests.swift` (create)
- Test: `Tests/macSCPAppKitTests/KeyboardShortcutsCatalogTests.swift` (create)

**Interfaces:**
- Consumes: `L10n` resolving for real (Task 2) — without it every assertion
  below would compare fallback text and prove nothing.
- Consumes from Core, verified against the source while this plan was
  written: `AppVersion.init?(_ string: String)` and its `description`;
  `UpdateCheckResult` with **labelled** cases `.upToDate(current:)`,
  `.updateAvailable(latest:current:url:)`, `.unknownLocalVersion`,
  `.failed(UpdateCheckError)`; `UpdateCheckError` with `.offline`,
  `.httpStatus(Int)`, `.rateLimited`, `.malformedResponse`. The labels are
  required — positional construction does not compile.

- [ ] **Step 1: Write the update-copy tests**

```swift
import Foundation
import Testing
@testable import MacSCPAppKit
@testable import macSCPCore

@Suite("UpdateAlertContent")
struct UpdateAlertContentTests {
    /// Every result must produce a non-empty title and message, except the
    /// `nil` case which is the "nothing to show" state. A missing catalog
    /// key would surface here as the raw key or an empty string.
    @Test func everyResultProducesCopy() throws {
        let current = try #require(AppVersion("1.1.0"))
        let latest = try #require(AppVersion("1.2.0"))
        let url = try #require(URL(string: "https://example.invalid/releases"))

        let results: [UpdateCheckResult] = [
            .updateAvailable(latest: latest, current: current, url: url),
            .upToDate(current: current),
            .unknownLocalVersion,
            .failed(.offline),
            .failed(.httpStatus(503)),
            .failed(.rateLimited),
            .failed(.malformedResponse),
        ]

        for result in results {
            #expect(UpdateAlertContent.title(for: result).isEmpty == false)
            #expect(UpdateAlertContent.message(for: result).isEmpty == false)
        }
    }

    /// No result may show the empty-state copy, and the no-result case must.
    @Test func theNilResultIsTheOnlyEmptyOne() {
        #expect(UpdateAlertContent.title(for: nil).isEmpty)
        #expect(UpdateAlertContent.message(for: nil).isEmpty)
    }

    /// The two versions are spec-mandated to BOTH appear, and in the right
    /// roles: an update alert that named only one version, or swapped them,
    /// would read as if the installed build were the new one.
    @Test func theUpdateMessageNamesBothVersions() throws {
        let current = try #require(AppVersion("1.1.0"))
        let latest = try #require(AppVersion("1.2.0"))
        let url = try #require(URL(string: "https://example.invalid/releases"))

        let message = UpdateAlertContent.message(
            for: .updateAvailable(latest: latest, current: current, url: url))

        #expect(message.contains(latest.description))
        #expect(message.contains(current.description))
    }

    /// The HTTP status must reach the user — a generic failure message
    /// would make a 503 indistinguishable from a 404 in a bug report.
    @Test func theHTTPFailureMessageNamesItsStatusCode() {
        #expect(UpdateAlertContent.message(for: .failed(.httpStatus(503))).contains("503"))
    }

    /// The unknown-version case must never read like an update claim: the
    /// spec forbids building one on a version that could not be read.
    @Test func theUnknownVersionCopyDiffersFromTheUpdateCopy() throws {
        let current = try #require(AppVersion("1.1.0"))
        let latest = try #require(AppVersion("1.2.0"))
        let url = try #require(URL(string: "https://example.invalid/releases"))

        #expect(
            UpdateAlertContent.message(for: .unknownLocalVersion)
                != UpdateAlertContent.message(
                    for: .updateAvailable(latest: latest, current: current, url: url)))
    }
}
```

- [ ] **Step 2: Run them**

Run: `swift test --filter UpdateAlertContent 2>&1 | tail -4`
Expected: all PASS. If `everyResultProducesCopy` fails, a catalog key is
missing — fix the catalog, not the test.

- [ ] **Step 3: Write the shortcut-catalog tests**

```swift
import Foundation
import Testing
@testable import MacSCPAppKit

@Suite("KeyboardShortcutsCatalog")
struct KeyboardShortcutsCatalogTests {
    /// The catalog is a HAND-MAINTAINED mirror of bindings that live at six
    /// other sites, so its failure mode is quiet drift. These tests cannot
    /// detect a binding that changed elsewhere — nothing can, short of a
    /// central registry — but they do catch the catalog rotting on its own.
    @Test func everyGroupHasATitleAndRows() {
        for group in KeyboardShortcutsCatalog.groups {
            #expect(group.titleKey.isEmpty == false)
            #expect(group.titleDefault.isEmpty == false)
            #expect(group.rows.isEmpty == false)
        }
    }

    /// Every row must carry a key, an English default and a glyph. An empty
    /// glyph renders as a blank cell in the settings table.
    @Test func everyRowIsComplete() {
        for row in KeyboardShortcutsCatalog.groups.flatMap(\.rows) {
            #expect(row.labelKey.isEmpty == false)
            #expect(row.labelDefault.isEmpty == false)
            #expect(row.shortcut.isEmpty == false)
        }
    }

    /// Every label and group title must resolve through the catalog. This is
    /// the check that would have caught a typo'd key, which previously
    /// rendered as English and looked correct.
    @Test func everyLabelKeyResolves() {
        for group in KeyboardShortcutsCatalog.groups {
            #expect(
                L10n.string(group.titleKey, "ZZ-UNRESOLVED-ZZ") != "ZZ-UNRESOLVED-ZZ",
                "group title key does not resolve: \(group.titleKey)")
            for row in group.rows {
                #expect(
                    L10n.string(row.labelKey, "ZZ-UNRESOLVED-ZZ") != "ZZ-UNRESOLVED-ZZ",
                    "row label key does not resolve: \(row.labelKey)")
            }
        }
    }

    /// Two rows may legitimately share a glyph across contexts (⎋ cancels in
    /// several places, ⏎ confirms in several), but the same LABEL KEY twice
    /// inside one group is a copy-paste slip.
    @Test func noGroupRepeatsALabelKey() {
        for group in KeyboardShortcutsCatalog.groups {
            let keys = group.rows.map(\.labelKey)
            #expect(Set(keys).count == keys.count, "duplicate label key in group \(group.titleKey)")
        }
    }
}
```

- [ ] **Step 4: Run them**

Run: `swift test --filter KeyboardShortcutsCatalog 2>&1 | tail -4`
Expected: all PASS. A failure in `everyLabelKeyResolves` means a real
missing catalog entry — add it to all four App catalogs, English text
matching the row's `labelDefault`.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "test(app): pin the update copy and the shortcut catalog"
```

---

### Task 4: Tests for the tab state and the menu-bar rollup

`SessionTab` carries a continuation-based confirmation whose contract is
exactly-once resumption; `MenuBarStatusModel` aggregates over tabs.

**Files:**
- Test: `Tests/macSCPAppKitTests/SessionTabTests.swift` (create)
- Test: `Tests/macSCPAppKitTests/MenuBarStatusModelTests.swift` (create)

**Interfaces:**
- Consumes from `MacSCPAppKit`: `SessionTab.init(connectionViewModel:certificateBridge:limiter:maxConcurrent:)`,
  `confirmPlaintext() async -> Bool`, `resolvePlaintextConfirmation(confirmed:)`,
  `markPlaintextConfirmed()`, `resetPendingPlaintextConfirmation()`,
  `displayTitle`, `isConnected`, `plaintextConfirmationPending`;
  `MenuBarStatusModel.tabs`, `anyTransferActive`, `connectedCount`.
- Verified against the source while this plan was written:
  `ConnectionViewModel` (Core) has **no** no-argument initializer — it is
  `init(connector: @escaping Connector)` with
  `Connector = @Sendable (ConnectionConfig, @escaping HostKeyDecider) async throws -> any RemoteFileSystem`.
  `BandwidthLimiter()` (Core) and `CertificatePromptBridge()` take no
  arguments. `CertificatePromptBridge` lives in the **App** layer
  (`CertificatePromptView.swift`), so `@testable import MacSCPAppKit`
  reaches it — no Core import is needed for it.

Both types are `@MainActor`, so every test function is marked `@MainActor`.

- [ ] **Step 1: Write the tab tests**

```swift
import Foundation
import Testing
@testable import MacSCPAppKit
@testable import macSCPCore

@Suite("SessionTab")
@MainActor
struct SessionTabTests {
    /// Builds a tab with the same collaborators `ContentView` hands it.
    /// Adjust only the initializer arguments if Core's signatures differ.
    private func makeTab() -> SessionTab {
        SessionTab(
            connectionViewModel: ConnectionViewModel(connector: { _, _ in
                // Never called: none of these tests connects. A throwing
                // stub is the smallest value that satisfies the signature.
                throw CancellationError()
            }),
            certificateBridge: CertificatePromptBridge(),
            limiter: BandwidthLimiter(),
            maxConcurrent: 2)
    }

    /// A tab with no session is not connected, and shows the generic title
    /// rather than a stale name.
    @Test func aFreshTabIsNotConnectedAndUsesTheGenericTitle() {
        let tab = makeTab()

        #expect(tab.isConnected == false)
        #expect(tab.displayTitle.isEmpty == false)
        #expect(tab.displayTitle != "tabs.newConnection")
    }

    /// A named tab shows its own name.
    @Test func aNamedTabShowsItsName() {
        let tab = makeTab()
        tab.titleName = "prod-web"

        #expect(tab.displayTitle == "prod-web")
    }

    /// The confirmation suspends until answered, then reports the answer and
    /// clears the pending flag. A dialog that stayed "pending" after being
    /// answered would block every later connect on this tab.
    @Test func answeringTheConfirmationResumesItAndClearsThePendingFlag() async {
        let tab = makeTab()

        async let answer = tab.confirmPlaintext()
        while tab.plaintextConfirmationPending == false { await Task.yield() }
        tab.resolvePlaintextConfirmation(confirmed: true)

        #expect(await answer == true)
        #expect(tab.plaintextConfirmationPending == false)
    }

    /// A refusal must come back as `false`, not merely as "not true" — the
    /// connector treats the two identically only by accident today.
    @Test func refusingTheConfirmationReportsFalse() async {
        let tab = makeTab()

        async let answer = tab.confirmPlaintext()
        while tab.plaintextConfirmationPending == false { await Task.yield() }
        tab.resolvePlaintextConfirmation(confirmed: false)

        #expect(await answer == false)
    }

    /// Resolving twice must not resume the continuation twice — that traps
    /// at runtime. The second call is a no-op by design.
    @Test func resolvingTwiceIsHarmless() async {
        let tab = makeTab()

        async let answer = tab.confirmPlaintext()
        while tab.plaintextConfirmationPending == false { await Task.yield() }
        tab.resolvePlaintextConfirmation(confirmed: true)
        tab.resolvePlaintextConfirmation(confirmed: false)

        #expect(await answer == true)
    }

    /// Resolving without a pending prompt must not trap either — the UI can
    /// dismiss a sheet that was never asked for.
    @Test func resolvingWithNothingPendingIsHarmless() {
        let tab = makeTab()

        tab.resolvePlaintextConfirmation(confirmed: true)

        #expect(tab.plaintextConfirmationPending == false)
    }

    /// The audit flag must be resettable to false at the start of a connect:
    /// its whole purpose is that a previous connect's confirmation cannot
    /// leak into a later, unrelated connect's audit record.
    @Test func theConfirmationFlagCanBeSetAndCleared() {
        let tab = makeTab()

        tab.markPlaintextConfirmed()
        #expect(tab.pendingPlaintextConfirmation)

        tab.resetPendingPlaintextConfirmation()
        #expect(tab.pendingPlaintextConfirmation == false)
    }
}
```

- [ ] **Step 2: Run them**

Run: `swift test --filter SessionTab 2>&1 | tail -4`
Expected: all PASS. If a test hangs, the polling loop never saw
`plaintextConfirmationPending` — report it rather than adding a sleep; a
timing-dependent test is worse than none.

- [ ] **Step 3: Write the menu-bar rollup tests**

```swift
import Foundation
import Testing
@testable import MacSCPAppKit
@testable import macSCPCore

@Suite("MenuBarStatusModel")
@MainActor
struct MenuBarStatusModelTests {
    private func makeTab() -> SessionTab {
        SessionTab(
            connectionViewModel: ConnectionViewModel(connector: { _, _ in
                // Never called: none of these tests connects. A throwing
                // stub is the smallest value that satisfies the signature.
                throw CancellationError()
            }),
            certificateBridge: CertificatePromptBridge(),
            limiter: BandwidthLimiter(),
            maxConcurrent: 2)
    }

    /// With no tabs the status item must read idle and count zero — not
    /// crash on an empty aggregation.
    @Test func anEmptyModelIsIdleAndCountsNothing() {
        let model = MenuBarStatusModel()

        #expect(model.anyTransferActive == false)
        #expect(model.connectedCount == 0)
    }

    /// Disconnected tabs must not be counted: the header counter says how
    /// many sessions are live, not how many tabs are open.
    @Test func disconnectedTabsDoNotCount() {
        let model = MenuBarStatusModel()
        model.tabs = [makeTab(), makeTab()]

        #expect(model.connectedCount == 0)
    }

    /// A tab with no running transfer must not light the active icon. This
    /// is the state the icon spends most of its life in, and an aggregation
    /// that defaulted to "active" would make it useless.
    @Test func tabsWithoutRunningTransfersLeaveTheIconIdle() {
        let model = MenuBarStatusModel()
        model.tabs = [makeTab()]

        #expect(model.anyTransferActive == false)
    }

    /// The closures must be callable defaults, so a status item built before
    /// `ContentView` wires them does not trap when clicked.
    @Test func theDefaultClosuresAreSafeToCall() {
        let model = MenuBarStatusModel()

        model.showMainWindow()
        model.focusTab(UUID())
    }
}
```

- [ ] **Step 4: Run them**

Run: `swift test --filter MenuBarStatusModel 2>&1 | tail -4`
Expected: all PASS.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "test(app): pin the tab confirmation contract and the menu-bar rollup"
```

---

### Task 5: Tests for the two filesystem-touching helpers

`EditorResolver` picks an app by rule then by default, skipping paths that
no longer exist. `ExternalTerminalLauncher` validates a chosen app and
sweeps orphaned temp directories under a root it accepts as a parameter.

**Files:**
- Test: `Tests/macSCPAppKitTests/EditorResolverTests.swift` (create)
- Test: `Tests/macSCPAppKitTests/ExternalTerminalLauncherTests.swift` (create)

**Interfaces:**
- Consumes: `EditorResolver.applicationURL(forFileName:settings:) -> URL?`
  (`@MainActor`), `ExternalTerminalLauncher.isValidCustomApp(atPath:) -> Bool`,
  `ExternalTerminalLauncher.sweepOrphanedTempDirectories(root:)`.
- Verified against the source while this plan was written:
  `SettingsStore.init(directory: URL)`, the settable
  `var defaultEditorPath: String?`, and the settable
  `var fileAssociations: [String: String]` keyed by a normalized extension
  (lowercase, no leading dot). `associatedApp(forExtension:)` reads that
  dictionary. Constructing the store against a **temporary directory** is
  what keeps these tests off the maintainer's real settings file.

**`EditorResolver.systemApplicationURL(for:)` gets no test**: it is a single
call into `NSWorkspace`, and a test would assert that the system association
on the machine running it is whatever it happens to be.

- [ ] **Step 1: Write the resolver tests**

```swift
import Foundation
import Testing
@testable import MacSCPAppKit
@testable import macSCPCore

@Suite("EditorResolver")
@MainActor
struct EditorResolverTests {
    /// Creates a directory that stands in for an installed app bundle, and
    /// removes it when the test ends.
    private func makeExistingAppPath() throws -> (path: String, cleanup: () -> Void) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("macSCP-test-\(UUID().uuidString).app")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return (url.path, { try? FileManager.default.removeItem(at: url) })
    }

    /// A store rooted in a throwaway directory. Never the real settings
    /// file — these tests write associations and a default editor, and
    /// doing that to the maintainer's own configuration would be a defect
    /// of the test suite, not of the code under test.
    private func makeSettingsStore() throws -> SettingsStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("macSCP-settings-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return SettingsStore(directory: directory)
    }

    private func setAssociation(
        in settings: SettingsStore, extension ext: String, path: String
    ) {
        settings.fileAssociations[ext] = path
    }

    private func setDefaultEditor(in settings: SettingsStore, path: String) {
        settings.defaultEditorPath = path
    }

    /// With nothing configured the resolver must decline, so the caller
    /// falls through to the post-download system association.
    @Test func nothingConfiguredResolvesToNil() throws {
        let settings = try makeSettingsStore()

        #expect(EditorResolver.applicationURL(forFileName: "notes.md", settings: settings) == nil)
    }

    /// A per-extension rule wins when its app still exists.
    @Test func anExtensionRuleWinsWhenItsAppExists() throws {
        let app = try makeExistingAppPath()
        defer { app.cleanup() }
        let settings = try makeSettingsStore()
        setAssociation(in: settings, extension: "md", path: app.path)

        let resolved = EditorResolver.applicationURL(forFileName: "notes.md", settings: settings)

        #expect(resolved?.path == app.path)
    }

    /// A rule pointing at an app that was deleted must be SKIPPED, not
    /// returned — handing the caller a path that no longer exists turns a
    /// stale setting into a failed open.
    @Test func anExtensionRuleWhoseAppIsGoneFallsThrough() throws {
        let settings = try makeSettingsStore()
        setAssociation(
            in: settings, extension: "md",
            path: "/nonexistent/\(UUID().uuidString).app")

        #expect(EditorResolver.applicationURL(forFileName: "notes.md", settings: settings) == nil)
    }

    /// The configured default editor covers extensions with no rule.
    @Test func theDefaultEditorCoversUnruledExtensions() throws {
        let app = try makeExistingAppPath()
        defer { app.cleanup() }
        let settings = try makeSettingsStore()
        setDefaultEditor(in: settings, path: app.path)

        let resolved = EditorResolver.applicationURL(forFileName: "notes.xyz", settings: settings)

        #expect(resolved?.path == app.path)
    }

    /// The rule must take precedence over the default — that ordering is the
    /// entire point of having both.
    @Test func theExtensionRuleOutranksTheDefaultEditor() throws {
        let ruled = try makeExistingAppPath()
        defer { ruled.cleanup() }
        let fallback = try makeExistingAppPath()
        defer { fallback.cleanup() }
        let settings = try makeSettingsStore()
        setAssociation(in: settings, extension: "md", path: ruled.path)
        setDefaultEditor(in: settings, path: fallback.path)

        let resolved = EditorResolver.applicationURL(forFileName: "notes.md", settings: settings)

        #expect(resolved?.path == ruled.path)
    }

    /// A file with no extension must not match a rule keyed on one.
    @Test func aFileWithoutAnExtensionDoesNotMatchARule() throws {
        let app = try makeExistingAppPath()
        defer { app.cleanup() }
        let settings = try makeSettingsStore()
        setAssociation(in: settings, extension: "md", path: app.path)

        #expect(EditorResolver.applicationURL(forFileName: "README", settings: settings) == nil)
    }
}
```

- [ ] **Step 2: Run them**

Run: `swift test --filter EditorResolver 2>&1 | tail -4`
Expected: all PASS.

- [ ] **Step 3: Write the launcher tests**

```swift
import Foundation
import Testing
@testable import MacSCPAppKit

@Suite("ExternalTerminalLauncher")
struct ExternalTerminalLauncherTests {
    /// No path means no custom app — the settings UI must not accept an
    /// empty choice as valid.
    @Test func noPathIsNotAValidCustomApp() {
        #expect(ExternalTerminalLauncher.isValidCustomApp(atPath: nil) == false)
        #expect(ExternalTerminalLauncher.isValidCustomApp(atPath: "") == false)
    }

    /// A path to something that does not exist is not valid, however
    /// plausible it looks.
    @Test func aMissingPathIsNotAValidCustomApp() {
        #expect(
            ExternalTerminalLauncher.isValidCustomApp(
                atPath: "/Applications/\(UUID().uuidString).app") == false)
    }

    /// The sweep removes leftover directories under the root it is given —
    /// and must tolerate a root that does not exist at all, which is the
    /// normal state on a machine that never used the feature.
    @Test func sweepingAMissingRootIsHarmless() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("macSCP-sweep-\(UUID().uuidString)")

        ExternalTerminalLauncher.sweepOrphanedTempDirectories(root: root)

        #expect(FileManager.default.fileExists(atPath: root.path) == false)
    }

    /// A populated root is cleared. The assertion is on the leftover being
    /// gone, not on the root itself — the sweep is free to remove or keep
    /// the root, and pinning that would over-specify it.
    @Test func sweepingRemovesALeftoverDirectory() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("macSCP-sweep-\(UUID().uuidString)")
        let leftover = root.appendingPathComponent("orphan")
        try FileManager.default.createDirectory(at: leftover, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        ExternalTerminalLauncher.sweepOrphanedTempDirectories(root: root)

        #expect(FileManager.default.fileExists(atPath: leftover.path) == false)
    }
}
```

- [ ] **Step 4: Run them**

Run: `swift test --filter ExternalTerminalLauncher 2>&1 | tail -4`
Expected: all PASS. If `sweepingRemovesALeftoverDirectory` fails because the
sweep only removes directories matching a naming or age rule, read that rule
and build the fixture to satisfy it — then say in the report what the rule
is. Do not weaken the assertion to "something happened".

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "test(app): pin the editor resolution order and the launcher's guards"
```

---

### Task 6: Milestone verification and close record

**Files:**
- Create: `docs/superpowers/specs/2026-08-09-m29-p1-abschluss.md`

- [ ] **Step 1: Run every suite and record the numbers**

```bash
swift build 2>&1 | tail -3
swift test 2>&1 | tail -3
docker compose -f docker/test-server/compose.yml up -d
MACSCP_ITEST=1 swift test 2>&1 | tail -3
MACSCP_KEYCHAIN=1 swift test --filter Keychain 2>&1 | tail -2
```

The Docker rig must be started from the **main checkout**, never a worktree.

- [ ] **Step 2: Verify the catalogs and check for orphans**

```bash
for f in Sources/MacSCPAppKit/Resources/*.lproj/Localizable.strings Sources/macSCPCore/Resources/*.lproj/Localizable.strings; do printf "%s: " "$f"; plutil -lint "$f"; done
pgrep -fl swiftpm-testing-helper || echo "no orphans"
git status --porcelain
```

- [ ] **Step 3: Verify the packaging path without publishing**

Run `scripts/package-app` and confirm it completes, including its
`test -d` assertion on `macSCP_MacSCPAppKit.bundle`.

**Do not run `scripts/release`.** Confirm by reading that its codesign list
names the new bundle.

- [ ] **Step 4: Write the close record**

Cover, with numbers measured in this session rather than carried forward:

- the commit list and the unpushed count;
- test counts before and after, per target;
- **every existing test that turned red from the L10n fix, by name**, and
  what was wrong with it — this is the milestone's main evidence;
- the mutation output from Task 2 Step 12, verbatim, with proof of a clean
  revert;
- each of the eleven success criteria from the spec with its evidence;
- the six files deliberately left untested, repeated with their reasons;
- what is NOT verified: the GUI was not launched, so criterion 1 (unchanged
  behaviour) rests on the maintainer's visual check, and the packaged app
  was built but not run.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "docs(m29): record the P1 close"
```

---

## Notes for the executing agent

- **The reachability test in Task 1 is the milestone in miniature.** If it
  compiles and runs, the App layer is testable; that file existing at all
  was impossible before.
- **Do not add `public` beyond `AppMain`.** If something seems to need it,
  the split was drawn wrong — report it rather than widening access.
- **Expect red tests in Task 2 Step 6 and treat them as findings**, not as
  obstacles. Each one is a test that asserted nothing for several
  milestones. Name them all.
- **If a Core initializer in Tasks 3–5 differs from what this plan assumed**,
  adapt the construction and keep the assertion. Say in the report what
  differed — a plan's API guesses are hypotheses, and this project has
  recorded that lesson twice.
