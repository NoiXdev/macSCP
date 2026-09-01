# macSCP M5g — Design polish for the browser main view (Design spec)

**Date:** 2026-07-11
**Status:** approved by the maintainer (brainstorming after the design review on 2026-07-11)
**Reference:** `docs/design/assets/macscp-ci-mockup.html` (interactive CI draft,
section „Das Hauptfenster") — binding blueprint; `docs/design/ci.md`.

## Goal & context

User feedback: the mockup is beautiful in spacing, shapes and design — the app
by contrast feels "very lifeless". Analysis: what gives the mockup its life is
surface hierarchy, hairlines, dense typographic detail and a fine radius
language; the app uses flat system defaults. Maintainer's decision:

- **Direction:** "mockup as blueprint" — adopt surfaces, hairlines,
  typographic rhythm and radii exactly; system controls stay only where they
  are invisible.
- **Scope staging:** all areas follow, but one at a time. **M5g = only the
  browser main view** (file list, pane heads, pane divider). Follow-up
  rounds: sidebar surface & rhythm · transfer bar & terminal strip · form &
  buttons.

## Mockup values (binding, from the draft's CSS)

| Element | Value |
|---|---|
| Line color `line` | light `#DAE3EB`, dark `#24374A` |
| Text `ink` | light `#14212E`, dark `#E8EFF5` |
| Text `ink-2` | light `#4A5B6B`, dark `#A7B7C5` |
| Text `ink-3` | light `#7E8FA0`, dark `#6E8093` |
| `remote-soft` | light `#E3EEF9`, dark `#142C42` |
| `local-soft` | light `#FBF1DF`, dark `#2C2415` |
| Column headers | 10.5pt, semibold, uppercase, letter spacing ~0.08em, `ink-3`, padding 5×12pt, hairline below |
| Table cells | padding 4.5×12pt, hairline below in `line` @45% opacity, `white-space: nowrap` |
| Cell typography | first column `ink`, others `ink-2`; number columns right-aligned with tabular figures |
| Row selection | background `remote-soft` (in BOTH panes — blue is the selection/primary color, CI rule) |
| Pane head | padding 7×12pt, hairline below, gap 8pt, font weight ~650 |
| Pane badge | uppercase 10.5pt, letter spacing .09em, padding 2×8pt, radius 5pt, color/soft per side |
| Pane-head path | `ink-3`, 11.5pt, ellipsis |
| Pane divider | 1pt hairline between the panes |

## Implementation

### 1. Extend DesignTokens (`Sources/MacSCPApp/DesignTokens.swift`)

New appearance-aware tokens (following the pattern of the existing
`localAmber`/`remoteBlue` with `NSColor(name:dynamicProvider:)`): `hairline`,
`ink`, `inkSecondary`, `inkTertiary`, `remoteSoft`, `localSoft` with the table
values above. Existing views that currently improvise soft tones via
`opacity` (pane badge 0.18, active sidebar row 0.12) switch over ONLY where
M5g touches them anyway (pane badge); the sidebar follows in its own round.

### 2. File list (`Sources/MacSCPApp/RemoteFileTableView.swift`, AppKit — RISK)

- Custom `NSTableHeaderCell`: uppercase titles (catalog strings stay as-is,
  display is uppercase), 10.5pt semibold, letter spacing, `inkTertiary`,
  hairline below; header height ~22pt (10.5pt font + 2×5pt padding, as in
  the mockup).
- Rows: height ~24pt; cell padding 12pt on the sides; separation as a
  hairline (`hairline` @45%) BELOW every row (NSTableView `gridStyleMask`
  isn't enough for the transparency — either custom drawing in an
  `NSTableRowView` subclass or the grid color
  `hairline.withAlphaComponent(0.45)` via `gridColor`, if that is visually
  identical; the plan fixes the approach).
- Selection: `selectionHighlightStyle = .none` + a custom `NSTableRowView`
  that, on selection, draws `remoteSoft` as a rounded rectangle (radius 0 —
  the mockup's `tr.sel` is rectangular); text stays legible in both
  appearances. Selection color `remoteSoft` in BOTH panes.
- Typography: name column `ink` (or the `labelColor`-equivalent of the
  token), size/date `inkSecondary`, number/date columns right-aligned with
  a `monospacedDigit` font (system size stays in the 12–12.5pt range).
- Behavior UNCHANGED: sorting, selection logic, double-click (folder +
  onOpenFile), context menus, drag sources/promise, symlink " →" suffix.

### 3. Pane heads + divider (`Sources/MacSCPApp/BrowserPane.swift`, `ContentView.swift`)

- Pane head: padding 7×12pt, gap 8pt; badge on `localSoft`/`remoteSoft`
  (instead of `tint.opacity(0.18)`), padding 2×8pt, radius 5pt, uppercase
  with letter spacing .09em as before; path `inkTertiary` 11.5pt,
  `lineLimit(1)` + `truncationMode(.middle)`; below it a hairline (1pt
  `hairline`) instead of `Divider()`.
- Pane divider: bring the HSplitView look between local/remote to a 1pt
  hairline — it must stay functionally draggable. Approach (the plan fixes
  it): a custom slim divider look, or panes without a split bar with a
  hairline overlay, as long as dragging is preserved. If draggability would
  be sacrificed to the look, draggability wins (function > look) and the bar
  is made as thin as possible.

## Error handling / invariants

- NO behavior change to selection, transfers, drag & drop, context menus,
  queue, terminal — pure view layer.
- Both appearances (light/dark) must hit the table values; tokens are
  dynamic, no static colors in views.
- CI rules stay: amber only local (badge), blue selection/remote, phosphor
  status only, error system red.
- Localization untouched (column titles stay catalog keys; uppercase
  display is a display transform).

## Tests

- No new unit tests (pure AppKit/SwiftUI view layer; `FileListFormatter`
  and all view models unchanged); the existing 295 must stay green.
- Visual smoke test (wrap-up task): side by side with the mockup in light AND
  dark — column headers, hairlines, selection color, cell typography/tabular
  figures, pane-head measurements, badge soft tones, 1pt divider; behavior
  regression: sorting, double-click (folder + editor), selection +
  upload/download, drag & drop, context menu.

## Deliberately NOT in M5g

- Sidebar surface & row rhythm (its own round).
- Transfer bar (pill progress) & terminal strip (its own round).
- Form grid & button radii (its own round).
- App-wide surface hierarchy `paper`/`card` (comes with the sidebar round,
  where the intermediate tone is needed).
