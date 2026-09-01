# M29-P1 — Making the App Target Testable: Foundation (Design)

**As of:** 2026-08-09. Predecessor: M28, whose whole-branch review found
a **Critical** that no test could catch.

## Why this milestone exists

M28 closed a path on which a WebDAV or S3 password could reach an
SSH bastion host. As a safeguard, the new `kind` guard was experimentally
**removed entirely** — the full suite stayed **green**.

The reason is structural, not carelessness: `Tests/` contains exactly one
directory, `macSCPCoreTests`. `MacSCPApp` is an `executableTarget` without
a test target. Nothing there can be reached by a test. On top of that,
the affected logic is a `private func` **on the `ContentView` struct**:
even with a test target, you would have to construct a SwiftUI view along
with its environment just to query it.

**A test target alone would therefore not have caught M28's Critical.** Both
are needed: a place where app code is testable, **and** logic that
does not live inside a view.

## Breakdown: why P1 is only the foundation

The overall wish — a test target, gutting `ContentView` (3540 lines, 65
functions), splitting it into smaller views — is on the order of M22
or M23, both of which ran in phases. Breakdown, fixed with the
maintainer on 2026-08-09:

| Phase | Content |
|---|---|
| **P1 (this milestone)** | Library split, thin `@main` target, second test target, L10n hardening, tests for the existing non-view logic. **No behavior change.** |
| P2 | The submit path (target-set, jump-set, jump-session resolution and their order) moved to Core, as a decision function with an error case instead of text. Closes M28's gap. |
| P3 | Remaining non-view logic out of `ContentView`; the view broken into named subviews. |

**P1 first**, because P2 and P3 could not otherwise pin down their results.

### A clarification that shaped the scope

Small subviews make **nothing** testable. A subview is again a view and
has no assertion surface without rendering; that would need XCUITest or
ViewInspector, both deliberately not in use in this project. Splitting
pays into **readability**, gutting pays into **testability**. Both are
worthwhile, but on different accounts — that is why they sit together in
P3 and not in P1.

## Target structure

`MacSCPApp` becomes the library **`MacSCPAppKit`**; all current sources
and resources move over unchanged, the directory is renamed to
`Sources/MacSCPAppKit/` (rather than keeping the old path via `path:`
— a target whose directory is named differently from the target itself
is exactly the kind of silent divergence this milestone abolishes).

Alongside it, a new executable target **`MacSCPMain`** under
`Sources/MacSCPMain/` with exactly one file:

```swift
import MacSCPAppKit

@main
struct Main {
    static func main() { MacSCPApp.main() }
}
```

The `App` protocol brings `static func main()` along, so the executable
needs no scene of its own. `MacSCPApp: App` stays a `public struct` in the
kit. Alongside that, a second test target **`macSCPAppKitTests`**.

**The product keeps the name `macSCP`.** That keeps the binary name, so
`scripts/package-app` finds its `$BIN` unchanged.

### What the restructuring requires in terms of access levels

Within a module, `internal` is visible, so the 36 app files need
**no** adjustment among themselves. `public` is needed at exactly one
place: `MacSCPApp` itself, so the executable can call it. Whoever sets
`public` beyond that has made a mistake.

The test target uses `@testable import MacSCPAppKit` and thereby also
sees `internal` — the same mechanism as in `macSCPCoreTests`.

## The bundle name: the silent trap

`L10n.bundle` looks for **one hardcoded name**, `macSCP_MacSCPApp.
bundle`, formed by SwiftPM from `<package>_<target>`. After the rename,
the bundle is named `macSCP_MacSCPAppKit.bundle`. If the lookup finds
nothing, it falls back to `Bundle.main`, and `NSLocalizedString` returns
the `defaultValue` — **every app string in English, with no crash and no
red test.** In an English screenshot, everything would look correct.

Three places depend on the name, and they behave differently:

| Place | Behavior on a wrong name |
|---|---|
| `scripts/package-app` | **loud** — `test -d` fails |
| `scripts/release` | **loud** — `cp` aborts |
| `Sources/MacSCPApp/L10n.swift` | **silent** — falls back to English |

The maintainer decided on 2026-08-09 to rename **and** harden,
once the silent class was identified.

## The L10n hardening — and why it is more than name maintenance

In a throwaway probe against the running suite (measured 2026-08-09,
probe deleted afterward, `git status --porcelain` clean):

```
xctest bundleURL:  .build/arm64-apple-macosx/debug/macSCPPackageTests.xctest
parent:            .build/arm64-apple-macosx/debug
candidate exists:  true
localized:         "they store different credentials"
CoreL10n today:    core.login.mergeConflictingSecrets
```

The resource bundle sits **next to** the test bundle and loads just fine
under `swift test`. Today's lookup does not find it because it asks
`Bundle(for:).resourceURL` — i.e. **inside** the `.xctest` — instead of
`Bundle(for:).bundleURL.deletingLastPathComponent()`, i.e. **next to** it. A
single missing candidate.

**Both layers get this candidate**, `L10n` as well as `CoreL10n`. That
makes localization resolve for real under tests for the first time, and
that lets us set a guard: a test that, for a known key, expects the
**translated text** — not the key, not the fallback. It goes red on
rename, on a missing key, and if someone removes the candidate again.

This closes the `CoreL10n` finding from M28's section 5, which until now
was its own backlog item — including its incorrect doc comment, which
already claimed exactly this property.

### The side effect that creates work

Dozens of existing `#expect(error == CoreL10n.string(…))` today compare
**key with key** and cannot fail. After the fix, they compare
text with text. **Some of them will go red** — not because the fix is
wrong, but because they previously checked nothing. This repair belongs
to P1 and is deliberately planned for.

Every case found this way is named **individually** in the wrap-up
report: it is the proof that the guard works.

## What P1 brings in terms of tests

The maintainer decided to pin down the existing non-view logic at the
same time. **Not every file deserves this**, and the omissions are
justified rather than kept quiet — this project has twice noted that a
test whose assertion is trivially satisfied is not regression protection.

| File | Lines | Tests? | Reason |
|---|---|---|---|
| `EditorResolver` | 63 | **yes** | Extension/rule resolution, pure function |
| `ExternalTerminalLauncher` | 160 | **yes** | Command construction; `LaunchError` is already `Equatable` |
| `KeyboardShortcutsCatalog` | 71 | **yes** | Data catalog — duplicates, completeness, L10n keys |
| `MenuBarStatusModel` | 30 | **yes** | Aggregation over session states |
| `SessionTab` | 153 | **yes** | `BrowserSession` + tab state, constructible without UI |
| `UpdateCheckModel` | 197 | **yes** | `UpdateAlertContent` derivation, version comparison |
| `AppRelauncher` | 18 | **no** | Starts a process; only the path construction would be testable, and that's one line |
| `RemoteFilePromise` | 53 | **no** | `NSFilePromiseProvider` subclass, driven by AppKit |
| `MenuBarController` | 219 | **no** | `NSStatusItem` wiring; needs a running app |
| `DesignTokens`, `PolishedButtonStyle` | 98 / 54 | **no** | Constants and style — a test would just check that a number is there |
| `L10n` | — | via the guard | see above |
| `MacSCPApp` | 334 | **no** | Entry point and scene |

**Correction to the exploration:** an earlier count listed 14 files
"without a view". `ImportConflictSheet` does in fact contain one
(`private struct … : View`) and slipped through only due to the
detection. The reliable count of test-worthy files is **six**.

## What P1 explicitly is **not**

- **No behavior change.** The app does exactly the same thing afterward. Any
  observed deviation is a bug, not a result.
- **No gutting of `ContentView`.** That's P2 and P3.
- **No view splitting.** P3.
- **No UI testing.** Neither XCUITest nor ViewInspector enter the project;
  when P1 is done, SwiftUI code remains untestable, and
  that's intentional.

## Risks

- **Resource bundling.** `.process("Resources")` moves along with the kit.
  If that breaks, icons, catalogs, and the shader are affected. `package-app`
  checks loudly, but only at the end.
- **Signing and packaging.** `scripts/release` and `scripts/package-app`
  know the bundle name in three places. **Do not run** — `release`
  publishes. The adjustment is read and checked against a `package-app`
  run without publishing.
- **The silent fallback.** The milestone's biggest risk, and the reason
  the guard is created in the same pass rather than afterward.
- **Existing tests going red.** Expected, see above. A test that is red
  after the fix gets **repaired, not reverted** — the assertion
  was worthless before.
- **CI.** Two test targets instead of one; the run time increases. `timeout-minutes:
  20` stays.

## Success criteria

| # | Criterion | Proof |
|---|---|---|
| 1 | The app launches and behaves unchanged | `package-app` run, then a visual check by the maintainer (the GUI does **not** launch from reviews or CI) |
| 2 | `MacSCPAppKit` is a library, the executable contains only the entry point | The executable source is one file with `@main` and one call |
| 3 | Exactly one type is newly `public` | Review; more `public` means the split was drawn wrong |
| 4 | `macSCPAppKitTests` exists and runs under `swift test` | Test output names both suite sets |
| 5 | Localization resolves for real under `swift test` | A test expects the **translated text**, not the key — one each for the app and core layers |
| 6 | The guard goes red on rename | Mutation: corrupt the bundle name in the code, red output verbatim in the report |
| 7 | Existing, previously ineffective L10n assertions are repaired | Every case that went red is named **individually** in the report |
| 8 | The six non-view files have tests | At least one test per file that would go red without the logic |
| 9 | The **six** omitted files are justified, not forgotten | This section, repeated in the report: `AppRelauncher`, `RemoteFilePromise`, `MenuBarController`, `DesignTokens`, `PolishedButtonStyle`, `MacSCPApp` |
| 10 | Packaging and signing work with the new name | `package-app` run green, `release` **only read** |
| 11 | No secret value in a message, log, or test failure text | Review |

## For the release notes

**No line.** P1 changes nothing a user sees. That is the
success condition, not a shortcoming.

## Open, deliberately not part of P1

- P2 (submit path moved to Core) and P3 (gutting + view splitting).
- The stale slot of a set-bound session.
- The editor friction when editing a login set.
- The target picker without the `kind` guard — today harmless only
  by a namespace coincidence.
- An app-wide audit area.
- The release backlog: 385 commits ahead of `origin/main`.
- The 0% CPU test suite hang.
