# macSCP M5j — Design polish transfer bar & terminal strip (design spec)

**Date:** 2026-07-11
**Status:** approved by the maintainer (round 3 of the staged polish rounds)
**Reference:** `docs/design/assets/macscp-ci-mockup.html` (binding blueprint);
predecessors `…-m5g-browser-polish-design.md`, `…-m5h-sidebar-polish-design.md`.

## Goal

The transfer bar and terminal panel adopt dimensions, typography, and the
pill progress shape from the CI mockup. Pure view layer, zero behavior
change. Third of four rounds (followed by: form & buttons).

## Mockup values (binding)

| Element | Value |
|---|---|
| Transfer bar | `border-top` 1 pt hairline, padding 8 pt vertical / 14 pt sides, font 12 pt, text `ink-2`, gap 12 pt |
| Progress pill | height 5 pt, radius 99 (capsule), track in `line` (hairline color), capsule fill |
| Terminal strip | `border-top` 1 pt hairline, padding 8 pt vertical / 14 pt sides, font 12 pt |

**Color decision (maintainer/CI rule):** The pill fill stays SEMANTIC in
the direction color (amber `localAmber` = upload, ocean blue `remoteBlue`
= download) — the mockup example shows blue, but the CI rule
(`docs/design/ci.md`) is binding; only the SHAPE (5-pt capsule r99) comes
from the mockup.

## Implementation

### 1. Transfer bar (`Sources/MacSCPApp/TransferQueueBar.swift`)

- `Divider()` → `Rectangle().fill(DesignTokens.hairline).frame(height: 1)`.
- Header row: padding 14 pt horizontal / 8 pt vertical (instead of 12/4);
  title 12 pt semibold in `inkSecondary` (instead of `.caption`/
  `.secondary`).
- Row container: padding 14 pt horizontal, 8 pt bottom (instead of 12/6);
  row HStack gap 12 pt (instead of 8).
- Row typography: base `font(.system(size: 12))` (instead of `.callout`);
  filename `DesignTokens.ink`; status/rate texts `inkSecondary` instead
  of `.secondary` (errors stay system red, "interrupted" stays `.orange`
  — M5d semantics).
- **PillProgress** (new private view in the same file):
  `PillProgress(fraction: Double, fill: Color)` — 5 pt tall capsule as
  track in `DesignTokens.hairline`, fill as a capsule in `fill` with
  width `fraction × total width` (GeometryReader), `animation(.linear(
  duration: 0.2))` on fraction changes; total width 120 pt as with
  today's `ProgressView`. Replaces the determinate
  `ProgressView(value:)` branch; the indeterminate branch
  (`ProgressView().controlSize(.small)`) stays.
- Icon/checkmark colors (amber/blue per direction) and all status
  branches content-wise unchanged.

### 2. Terminal panel (`Sources/MacSCPApp/ContentView.swift`, `terminalPanel`)

- 1-pt hairline as the panel's top edge:
  `.overlay(alignment: .top) { Rectangle().fill(DesignTokens.hairline)
  .frame(height: 1).allowsHitTesting(false) }` on the panel ZStack.
- "Shell beendet" state: font 12 pt (`font(.system(size: 12))`), padding
  8 pt vertical / 14 pt sides around the content; colors unchanged
  (phosphor on deep sea).
- SwiftTerm view, terminal lifecycle, ⌘T, replay: untouched.

## Invariants

- NO behavior change: queue status semantics, cleanup button, resume
  banner, conflict sheet, terminal lifecycle — exactly as today.
- Both appearances via dynamic tokens; no new static colors.
- CI rules: amber upload only, blue download/remote only, phosphor
  status/terminal only, errors system red, orange "interrupted" only.

## Tests

- No new unit tests (view layer); existing 295 stay green.
- Visual smoke: light AND dark; a running transfer with a low bandwidth
  limit so the pill visibly fills (track/fill/5 pt/capsule shape, upload
  amber + download blue); hairline over the bar and terminal panel;
  "Shell beendet" dimensions; behavior regression: transfer runs to
  completion, cleanup, ⌘T open/close.

## Deliberately NOT in M5j

- Form grid & button radii (round 4).
- No restructuring of the queue row layout (element order stays).
- Terminal inner padding of the SwiftTerm content (renderer-internal,
  do not touch).
