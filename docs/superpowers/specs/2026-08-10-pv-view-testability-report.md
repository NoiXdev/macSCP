# Are SwiftUI views testable in this package? (Spike, 2026-08-10)

Result of one work session. **No production code was changed**, no
dependency added, `Package.swift` unchanged. All numbers below are
measured, not estimated.

## Short answer

**Yes — with `ImageRenderer` and without any new dependency.** And in a way
that *discriminates*: the same view with **exactly one** changed input
produces two different bitmaps, while the first input then comes back
pixel-identical afterward.

**But only with method.** `ImageRenderer` delivers *different* pixels for
the same view in a process's first renderings than afterward. Anyone who
does not eliminate this gets differences that have nothing to do with the
inputs. See "Fix round 1" at the end.

The recommendation sentence is at the end.

## Step 1 — Starting point

`Tests/macSCPAppKitTests/` contained nine files, all about **non-view
types**: `SessionTabTests`, `MenuBarStatusModelTests`,
`UpdateAlertContentTests`, `EditorResolverTests`,
`ExternalTerminalLauncherTests`, `KeyboardShortcutsCatalogTests`,
`L10nTests`, `SnippetsPresentationTests`, `TargetReachabilityTests`.

Measured with `swift test --filter macSCPAppKitTests`:

```
Test run with 39 tests in 9 suites passed after 0.010 seconds.
```

Not a single one of these tests touches a `View`. That is the gap in
question.

## Step 2 — The cheapest attempt: does it work without a new dependency?

New file `Tests/macSCPAppKitTests/ViewTestabilitySpike.swift`, seven tests.

### 2.1 Instantiating

`SheetSearchField` is `internal`; the test target already uses
`@testable import MacSCPAppKit` anyway, so the type is directly visible.
The `@Binding` parameters are filled with `.constant(…)`. Compiles and
runs. The stored properties (`text`, `isRegex`, `errorText`) are readable
from the test — so one can already assert what went into the view *without*
rendering.

### 2.2 `ImageRenderer` delivers an image

`ImageRenderer(content:).cgImage` at `scale = 2` with a fixed
`.frame(width: 420, height: 40)` reproducibly yields an **840×80** image,
268,800 bytes RGBA. Not fully transparent — something was actually drawn.

The pixels are read back through an explicit `CGContext`, not through a PNG
encoder; the comparison thus sees pixels, not container metadata.

### 2.3 The actual test: does it discriminate?

Yes — but only after two confounders are eliminated. Both were found in the
same-day fix round and are detailed under "Fix round 1" at the end of this
document; here is the cleaned-up result.

Two renderings of the same `SheetSearchField` are compared, where
**exactly one** input differs (`errorText`); `text` and `isRegex` stay
fixed. Each rendering is taken only after three discarded warm-up renders
(rationale: section "Fix round 1").

| Render (settled) | Size | Fingerprint (FNV-1a over all pixels) |
|---|---|---|
| `errorText: nil` | 840×80 | `7dc27e7c7c85d45c` |
| `errorText: "Invalid regular expression"` | 840×80 | `b4adf3924f8fdfc4` |
| `errorText: nil` (A/B/A control) | 840×80 | `7dc27e7c7c85d45c` |

Same dimensions, different pixels, and repeating the first input comes back
**byte-identical**. Proved red: flip `!=` to `==` ⇒ the test fails.

The second single variable is also measured: only `isRegex` toggled,
`errorText` fixed ⇒ **identical pixels** (`7dc27e7c7c85d45c` in both cases).
So the regex checkbox contributes nothing to the image — which makes clear
that the difference above comes solely from the error text.

A second, independent view (`PolishedButtonStyle`, `prominent` on/off, also
a single variable with an A/B/A control) likewise discriminates
(`6ea7c7548e08687b` vs. `542f5bbbfda8f78`). So the finding does not hinge
on one lucky view.

### 2.4 The measured limit — AppKit-backed controls don't render along with it

`SheetSearchField` with `text: "a"` and with
`text: "a very much longer needle to search for"` yields **the same
pixels**. `TextField` is AppKit-backed, and `ImageRenderer` does not draw
`NSViewRepresentable` content. This is not a guess but measured, and the
spike records it as a test (`textFieldContentDoesNotReach…`); if this
behavior changes in a future macOS version, the test goes red and the
comment corrects itself.

**Consequence for planning:** pixel comparisons work for anything made of
SwiftUI primitives (text, shapes, colors, layout, `ButtonStyle`, branch
visibility). For content in `TextField`, `Toggle`, `NSTableView` & co. they
**do not** work. For those, the assertion belongs on the input state (2.1)
or on the extracted non-view type — exactly what P0 already plans to do.

## Step 3 — Does it work with Swift Testing?

Yes, without restriction. Everything is `@Test`/`#expect`/`#require`, no
`XCTestCase`. `ImageRenderer` is `@MainActor`, so the suite carries
`@MainActor` — that is the only adjustment. The suite is additionally
`.serialized`, because one of the measurements touches process-wide state
(`NSApp`).

```
✔ Test run with 7 tests in 1 suite passed after 0.191 seconds.
```

A practical warning: a failed `#expect` on a raw `[UInt8]` writes hundreds
of thousands of bytes into the test log (1.9 MB during the red-proof).
The spike therefore wraps the pixels in a `Bitmap` type that compares
fully but only *prints* a short fingerprint. Anyone adding pixel
comparisons in P0 must carry this over.

## Step 4 — Does it run without a GUI session?

Partially answered; the open half is named.

Measured, with isolated single runs (each a fresh test process):

- In a clean test process, `NSApp` is **nil** — the test runner itself does
  not create an `NSApplication`.
- Rendering a **pure SwiftUI view** (Button + `PolishedButtonStyle`, also a
  bare `Text`): the image comes out, `NSApp` stays **nil**.
- Rendering `SheetSearchField` (contains `TextField`/`Toggle`): the image
  comes out, and afterward `NSApp` is **no longer nil** — the AppKit-backed
  controls pull up the shared `NSApplication`.

No window, no run loop, no event needed; no crash, no exception over a
missing window server, no delay. The complete spike runs in 0.19 s.

**What I could not measure:** whether `NSApplication.shared` works in a
session *without* a window server. The local machine runs in a logged-in
GUI session; a bootstrap namespace without a window server
(`launchctl bsexec 1`) requires root, and passwordless `sudo` is not
available here. That is the one remaining uncertainty.

But it is cheap to resolve and **needs no dedicated task**: CI already runs
`swift test` on `macos-15` (`.github/workflows/ci.yml`). If
`ViewTestabilitySpike.swift` stays in the tree, the next CI run is the
measurement. Anyone who wants to avoid the risk entirely should stick to
pure SwiftUI views — those provably do not need `NSApp`.

## Step 5 — Check dependencies

**Skipped, because step 2 held up.** No library was evaluated and nothing
was added to `Package.swift`. Cost in dependencies: **zero** — `SwiftUI`,
`AppKit`, and `CoreGraphics` are system frameworks the test target already
loads via `MacSCPAppKit` anyway.

## The five questions, briefly

1. **Instantiable?** Yes. `@testable import` suffices, `@Binding` via
   `.constant(…)`.
2. **Content checkable — and discriminating?** Yes, with exactly one input
   varied: 840×80, `7dc27e7c7c85d45c` (without error text) vs.
   `b4adf3924f8fdfc4` (with), the A/B/A control comes back to
   `7dc27e7c7c85d45c`. Two caveats: content of AppKit-backed controls does
   not appear in the bitmap, and renderings must be settled (fix round 1).
3. **Swift Testing?** Yes, `@Test`/`#expect`, suite `@MainActor` and
   `.serialized`.
4. **Without a GUI session?** Pure SwiftUI views: yes, without
   `NSApplication`. Views with `TextField`/`Toggle`: run locally, but pull
   up `NSApp` while doing so — unproven for a window-server-less session
   (see step 4).
5. **Dependencies?** None.

## Effect on the suite

| | Tests | Suites | Duration |
|---|---|---|---|
| before | 1756 | 144 | — |
| after | **1763** | **145** | 4.35 s total, of which 0.33 s spike |

Full `swift test` run green, no disruption of other tests from the pulled-up
`NSApplication`.

## Recommendation

**View tests are feasible here without third-party code and are worth it
for anything made of SwiftUI primitives — provided every pixel comparison
varies exactly one input, renders settled, and carries its own A/B/A
control; for content of AppKit-backed controls (`TextField`, `Toggle`,
tables), extracting into checkable non-view types remains the only way,
and exactly there is where the last milestone's three bugs sat.**

`ViewTestabilitySpike.swift` stays in the tree: it is the runnable example
test, costs 0.33 s, and the next CI run answers the open window-server
question as a side effect.

## Notes on the brief

The brief's prose matched the code; one point deviates:

- The brief names only `Tests/…/ViewTestabilitySpike.swift`, `Package.swift`,
  and the report as touched files. `Package.swift` stayed untouched because
  step 5 was skipped — the test target needs no declaration change to see
  `SwiftUI`/`AppKit`.
- The brief recommends checking with "`NSImage` with a size greater than
  zero". That would be exactly the check the brief itself warns against:
  `NSImage` with size > 0 would also be obtained from an empty image. The
  spike checks the read-back pixels instead.

## Fix round 1 — two confounders in the showcase example

The review noted: the showcase comparison changed **two** inputs at once
(`isRegex` *and* `errorText`), while the table and text sold it as a single
variable. Fair. While eliminating it, a second, larger confounder turned
up that nobody knew about.

### Confounder 1 — the second variable

Fixed: the comparison holds `text` and `isRegex` fixed and varies only
`errorText`. In addition, the other half is now independently measured —
only `isRegex` toggled, `errorText` fixed ⇒ **pixel-identical**. So the
regex checkbox doesn't even reach the bitmap (like the `TextField` content,
section 2.4) — it genuinely was not a factor in the old comparison. It just
was not stated anywhere, and that was exactly the objection.

### Confounder 2 — `ImageRenderer` settles over time

While remeasuring the fingerprints, **the same input** produced two
different values in two different tests. A throwaway probe test that
renders the same view several times in a row shows the cause:

```
DRIFT off #0: 71186a2f4b11fdad      PURE prominent #0: 540076827d8d1edd
DRIFT off #1: 71186a2f4b11fdad      PURE prominent #1: 540076827d8d1edd
DRIFT off #2: 7dc27e7c7c85d45c      PURE prominent #2: 6ea7c7548e08687b
DRIFT off #3: 7dc27e7c7c85d45c      PURE prominent #3: 6ea7c7548e08687b
DRIFT off #4: 7dc27e7c7c85d45c      PURE prominent #4: 6ea7c7548e08687b
DRIFT off #5: 7dc27e7c7c85d45c
```

A view's first renderings return a different value than all subsequent
ones; after that it is stable. This affects **pure SwiftUI views too**
(right column, without any `NSApplication`), so it has nothing to do with
AppKit controls or the window server. It is reproducible: across multiple
`swift test` runs, exactly the same numbers come out.

**This made the old table wrong in two ways.** Its two values
(`71186a2f4b11fdad`, `7ef4c012bd35263d`) are *unwarmed* renderings. The old
showcase comparison would have reported a difference even if both inputs
had been identical — it happened to compare rendering #2 against
rendering #3.

### The method that holds up

Three rules, all measured, not guessed:

1. **Vary exactly one input.**
2. **Render settled**: discard three renderings, take the fourth
   (`renderSettled`).
3. **A/B/A control**: after the second rendering, render the first input
   again and require equality.

Rule 3 is the safety net for rule 2: it turns too short a warm-up phase
**red instead of silent**. Counter-proof, warm-up phase set to 0:

```
✘ Expectation failed: (withoutError → Bitmap(840x80, …, fingerprint 71186a2f4b11fdad))
  == (withoutErrorAgain → Bitmap(840x80, …, fingerprint 7dc27e7c7c85d45c))
```

Exactly the old, unwarmed value — the control catches the mistake the
first attempt made.

### Consequence for P0

The answer to the original question remains **yes**; the recommendation
above is now supplemented with the method. Anyone writing pixel
comparisons in P0 adopts the three rules — otherwise they produce tests
that read meaning out of renderer warm-up. That is one more argument for
extracting logic into non-view types and using pixel comparisons sparingly.
