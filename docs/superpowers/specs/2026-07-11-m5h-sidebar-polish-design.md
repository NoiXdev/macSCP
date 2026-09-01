# macSCP M5h — Design polish sidebar (design spec)

**Date:** 2026-07-11
**Status:** approved by the maintainer (round 2 of the staged polish rounds)
**Reference:** `docs/design/assets/macscp-ci-mockup.html` (binding blueprint);
predecessor round `docs/superpowers/specs/2026-07-11-m5g-browser-polish-design.md`.

## Goal

The sessions sidebar adopts surface, row rhythm, and label typography
from the CI mockup. Pure view layer, zero behavior change. Second of four
rounds (after M5g browser; followed by transfer bar/terminal strip, then
form).

## Mockup values (binding, from the design's CSS)

| Element | Value |
|---|---|
| `paper` | light `#F4F7FA`, dark `#0D1720` |
| `card` | light `#FFFFFF`, dark `#14212E` |
| Sidebar surface | `color-mix(card 70%, paper)` → precomputed light `#FCFDFE`, dark `#121E2A` |
| Sidebar edge | 1 pt hairline on the right (`hairline` token from M5g) |
| Container padding | 12 pt vertical, 8 pt horizontal |
| Section labels | 10.5 pt semibold, uppercase, tracking ~1 pt (`.1em`), `inkTertiary`, padding top 2 / sides 10 / bottom 6 |
| Session rows | padding 5×10 pt, radius 6, row spacing 2 pt |
| Active row | background `remoteSoft` (token replacing the previous `remoteBlue.opacity(0.12)`), text semibold `remoteBlue`, phosphor dot |
| Inactive rows | text default; hover `Color.secondary.opacity(0.08)` (as in M5f, unchanged) |

## Implementation

### 1. Tokens (`Sources/MacSCPApp/DesignTokens.swift`)

New, via the existing `dynamicNS` helper:

- `paper: Color` — light `#F4F7FA`, dark `#0D1720`
- `card: Color` — light `#FFFFFF`, dark `#14212E`
- `sidebarSurface: Color` — light `#FCFDFE`, dark `#121E2A` (precomputed
  70/30 blend; static instead of runtime blending — deterministic)

`paper`/`card` are NOT consumed in M5h (staging for the transfer-bar and
form round, as already done for `ink`/`inkSecondary` — comment
accordingly).

### 2. Sidebar (`Sources/MacSCPApp/SessionSidebar.swift`)

- Container (outer VStack): `.background(DesignTokens.sidebarSurface)` +
  `.overlay(alignment: .trailing)` with a 1-pt `hairline` rectangle.
- The "SESSIONS" label and group/IMPORTED headers: `font(.system(size:
  10.5, weight: .semibold))`, `.tracking(1.0)`,
  `.foregroundStyle(DesignTokens.inkTertiary)`, padding top 2 / sides 10
  / bottom 6 (group headers keep their context menu/drop/rename function
  unchanged; only typography/color/padding change).
- Session rows (`SessionRow`): inner padding 5 pt vertical / 10 pt
  horizontal, radius 6 for hover and active background; the active row
  uses `DesignTokens.remoteSoft` instead of `remoteBlue.opacity(0.12)`;
  adjust list insets so rows align with the labels; row spacing ~2 pt
  (list row spacing or padding — the plan fixes the mechanism, the
  visual result is binding).
- `List(.sidebar)` + `scrollContentBackground(.hidden)` stay; the tinted
  surface comes from the container underneath.
- The error-text area at the bottom is unchanged.

## Invariants

- NO behavior change: context menus, inline rename (Enter/Escape/Blur),
  drag & drop, delete dialog, new-group alert, collapse state,
  `interactionsDisabled` — all exactly as in M5f.
- Both appearances via dynamic tokens; no static colors in views.
- CI rules unchanged (blue = active/selection, phosphor status only).
- Localization untouched (label keys stay; uppercase rendering was
  already a display transformation).

## Tests

- No new unit tests (view layer); existing 295 stay green.
- Visual smoke: light AND dark, side by side with the mockup — tinted
  surface visible against the pane surface, right-hand hairline, label
  typography, active row in remoteSoft, row dimensions; behavior
  regression: context menu, inline rename, group expand/collapse,
  connect click.

## Deliberately NOT in M5h

- Transfer bar & terminal strip (round 3), form & buttons (round 4).
- No app-wide `paper` ground (the panes stay on `controlBackgroundColor`
  until the following rounds complete the card hierarchy).
