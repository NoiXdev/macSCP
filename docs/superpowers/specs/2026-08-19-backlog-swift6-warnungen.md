> **Resolved on 2026-08-26** via
> `docs/superpowers/plans/2026-08-26-swift6-sprachmodus.md`. All six targets
> are on `.swiftLanguageMode(.v6)`, the project builds warning-free, and CI
> turns red as soon as the count of distinct warning locations exceeds 1 (the
> one permitted one is named explicitly in `ci.yml`).
>
> **The number below is wrong.** "1472 warnings" was a line count: the same
> location gets printed on average seventeen times across multiple compile
> passes. Measured, it was **37 distinct locations**. The entry stays as is,
> because this counting error is the actual lesson.

# Backlog: the Swift 6 warnings in the CI log

**Created:** 2026-08-19, after error-looking messages seemed to stand out in
the GitHub Actions log. **They are not errors.** All runs show `success`,
zero `error:`. Measured against run `32248172604` (CI, develop).

## The finding

**1472 warnings**, the vast majority of them from **our own** code, not
from dependencies:

| Location | Count | Dominant cause |
|---|---|---|
| `Tests/macSCPCoreTests` | 661 | 528× a lock, taken in an async context |
| `Sources/macSCPCore` | 72 | non-Sendable Citadel types (`SFTPFile`) in `@Sendable` closures |
| `Sources/MacSCPCLI` | 3 | same pattern |

In production code only three files are affected: `RemoteFS/TransferEngine.swift`,
`SSH/CitadelFileSystem.swift`, and `MacSCPCLI/MacSCPCLI.swift`.

## Why this isn't noise

Around 1200 of these warnings literally say *"this is an error in the Swift 6
language mode"*. All targets are on `.swiftLanguageMode(.v5)`. Today they're
warnings; the moment someone switches the language mode — voluntarily, or
because a toolchain forces it — it's a build stop.

This is **deferred debt**, not a wish for cleanup.

## Two separate natures

1. **The 528 lock warnings in the tests.** A test helper takes a lock in an
   async context. Presumably a single pattern, fixable in one spot — the
   number is large because the same pattern is used across many tests, not
   because they'd be many different problems. **Recount before touching it,
   whether it really is one pattern**; this hypothesis is not measured.
2. **The Sendable warnings in Core.** Citadel's types travel through our
   closures. That's real work across three files, not a search-and-replace —
   either `@preconcurrency import`, or actually keeping the types out of the
   closures. The first is papering over it, the second is a restructuring.

## Ordering

No rush, as long as the language mode stays at v5. It's sensible **before**
the next toolchain jump, and the tests first: that's where the bulk sits,
and it's presumably the cheaper half.
