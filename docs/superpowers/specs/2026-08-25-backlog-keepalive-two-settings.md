# Backlog: keep-alive as two settings instead of one

**Created:** 2026-08-25, from a review finding on Task 9 of the
connection-state work. Small, clearly scoped — and the cause was a wrong
directive of mine, not an implementation error.

## What holds today

`SettingsStore.keepAliveIntervalSeconds` is **one** stored `Int`: `0`
means "off", any other value gets clamped to 15…600. The UI represents
this via a toggle plus interval field, with a **view-local, unsaved**
memory of the last-used interval.

## The cost, measured

Turn keep-alive off, quit the app, restart, turn it on again — the
self-chosen interval is gone and back at 60. The memory lives only in
the view, and the stored value got overwritten with `0` on turning it
off.

This is disclosed (the explanatory text in the settings section says
so), but it's not good behavior.

## Why it happened this way

**The directive "one stored value, no second setting" came from my own
brief and was wrong.** As a pattern I had explicitly named the
auto-refresh section of the same file — and that consists of **two**
settings:

```
autoRefreshEnabled          Bool
autoRefreshIntervalSeconds  Int, geklemmt 2…300
```

There the interval is always valid, there's no magic value, and a
restart loses nothing. I decided against the house convention that I had
myself cited.

## What would need doing

Introduce `keepAliveEnabled: Bool`, clamp `keepAliveIntervalSeconds` to
15…600 without the `0` special case, and drop the view-local memory
entirely.

**Not done in Task 9, with reason:** the `0` special case is already
shipped in Core and is read by the probe — both checked and closed.
Changing the Core API at the end of a long branch buys a small
improvement for a real regression risk, in code nobody's currently
looking at.

When touching it: a migration is needed, but trivial — a stored `0`
becomes `enabled: false` plus the default interval. And the clamping
belongs, like its neighbor, in **both getter and setter**, so a
hand-edited file produces neither spam nor a dead timer.

## Done 2026-09-02

Shipped in six commits, listed in the order they landed: `726ffb9`,
`e75a049`, `bc8becf`, `192ed54`, `4f6e661`, `8f04e83`.

- **The two settings.** `SettingsStore` gained `keepAliveEnabled: Bool`
  (default `true`) alongside `keepAliveIntervalSeconds`, now clamped
  15…600 on both getter and setter with no `0` special case — the same
  shape as `autoRefreshEnabled`/`autoRefreshIntervalSeconds`, exactly as
  this entry proposed (`726ffb9`).
- **The read-side migration, and the one correction to it.** An old file
  with `keepAliveIntervalSeconds: 0` and no `keepAliveEnabled` key reads
  as `enabled: false` with the interval at the **default, 60** — not the
  floor, 15. The first implementation had the getter clamp any stored `0`
  to the floor like any other out-of-range value, which put `15` in this
  case; a coordinator ruling (`e75a049`) corrected this on the grounds
  that a stored `0` is the retired sentinel and was never an interval, so
  reading it back as a plausible-looking `15` would just be a new
  surprise in place of the old one. This entry's own draft above also
  said `60`; the record is worth keeping straight about the fact that the
  implementation passed through `15` first and was corrected, not that
  `60` was obvious throughout. Proved with raw JSON fixtures
  (`oldOffFileWithoutKeepAliveEnabledKeyMigratesOnRead`,
  `explicitKeepAliveEnabledKeyWinsOverStoredZeroInterval` in
  `Tests/macSCPCoreTests/SettingsStoreTests.swift`) and a byte-unchanged
  check — opening the store on an old file does not rewrite it. A later
  write of either setting persists both keys from then on
  (`bc8becf` corrected a stale doc-comment reference to the retired
  sentinel left over from the first pass).
- **The probe loop.** `LivenessProbeRunner.body`'s loop
  (`Sources/MacSCPAppKit/ContentView+Detail.swift`) now reads
  `keepAliveEnabled` before the interval on every lap, replacing the old
  `interval > 0` gate — the interval always reads 15…600 now, so it could
  never again signal "off". `LivenessProbeWiringGuardTests` gained an
  ordered claim that the enabled-check precedes the interval-read inside
  the loop body, proved red against the pre-change loop.
  `ConnectionLiveness.idleRecheckSeconds`'s doc comment was corrected to
  describe the switch instead of the retired zero-interval sentinel
  (`192ed54`).
- **The UI.** In `SettingsView.swift`, the Toggle binds straight to
  `store.keepAliveEnabled`, the Stepper straight to
  `store.keepAliveIntervalSeconds`, with `.disabled(!enabled)` on the
  Stepper — the same shape as the auto-refresh pair a few sections up.
  Deleted: `KeepAliveControlPlan` (the sentinel-translation enum) and its
  tests, `SSHSettingsSection.lastKnownKeepAliveInterval` (the view-local
  memory this entry exists to retire), `KeepAliveStepperWiringGuardTests`
  (there is no longer a sentinel to bypass, so nothing left for that
  guard to watch for), and `defaultKeepAliveIntervalSeconds` (zero
  production readers once the Settings-UI read was gone; a test reading
  a constant is not a caller of it). The footer text in all four
  catalogs (`en`/`de`/`fr`/`pl`) no longer discloses a lost interval,
  because there is no longer one to lose. A store-level test
  (`togglingKeepAliveEnabledNeverTouchesTheInterval`) pins that flipping
  the switch off and back on never touches the stored interval
  (`4f6e661`, `8f04e83`).
- **What this does not do.** No rewrite of an old file happens until the
  user next touches a setting — the migration above is read-side only.
  No downgrade guarantee: an older build reading a file with
  `keepAliveEnabled: false` and interval `60` would still probe, the same
  accepted shape as the auto-refresh pair this entry named as the
  pattern to follow in the first place.

The connection-state ledger's parked item — "the stepper guard proves
the call is reached, not its arguments; not closable without a SwiftUI
harness" — is closed by removing the thing that needed the harness,
rather than by building one.
