# Backlog: toolchain divergence between workstation and CI

**Status:** open
**Logged:** 2026-08-26, after a red CI run on `develop`

## What happened

Run `32938674467` failed at the build, not at a test:

```
Sources/MacSCPAppKit/ContentView+Lifecycle.swift:233:45:
error: expression is 'async' but is not marked with 'await'
```

The line read `settingsStore.connectTimeoutSeconds`. `SettingsStore` is
`@MainActor`; `ConnectionViewModel.Connector` is a non-isolated
`@Sendable` function type. Whether the connector closure itself counts
as main-actor-isolated is thus decided by the compiler's closure
isolation inference — and that's exactly what differs:

| | Swift | Result |
|---|---|---|
| Workstation | 6.3.3 (macOS 26) | builds |
| CI (`macos-15`) | older | error |

Fixed in `750ccc6` with an explicit `await MainActor.run { … }`, which
both compilers accept.

## Why this is a backlog entry and not a closed matter

The fix removes the one spot found. It does not remove the cause: **a
green local build is not evidence about the CI build.** The whole claim
"2648 tests green" before the push referred exclusively to the local
toolchain. For anything that depends on concurrency inference, it says
nothing.

This hits the same recurring lesson as the shell classification further
up in the backlog: the *local* environment was consulted as the oracle,
even though the claim was supposed to hold for a *different* one.

## Possible paths (not decided)

1. **A second CI job on `macos-26`.** Cheap, and it's a measurement
   instead of an assumption: both inference regimes actually get built.
   Only covers, doesn't prevent.
2. **Pin feature flags in `Package.swift`.** The divergence presumably
   traces back to `NonisolatedNonsendingByDefault` (SE-0461), which the
   newer compiler defaults on. *Presumably* — this hasn't been
   re-measured, the older toolchain is missing here for that. If it's
   true, an explicit flag brings both compilers into alignment and fixes
   the class, not just the spot found.
3. **Raise Xcode in CI**, so CI follows the workstation version. Only
   shifts the divergence, once the workstation moves ahead again.

Path 2 is the only one that closes the class — and the only one that
needs a measurement before implementation.

## Side finding

`ContentView+Lifecycle.swift` was the only spot found. However, the
compiler aborts the file at the first error; whether further spots of
the same class lie behind this line only a green run will show.
