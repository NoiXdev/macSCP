# macSCP M5k — Design polish form & buttons (design spec)

**Date:** 2026-07-25
**Status:** approved by the maintainer (round 4 — last of the staged polish rounds)
**Reference:** `docs/design/assets/macscp-ci-mockup.html` (binding blueprint);
predecessors M5g/M5h/M5j.

## Goal

The connection form (New/Edit/fingerprint prompt) adopts the field grid
and button style from the CI mockup. Pure view layer, zero behavior
change. After this, the design polish series is complete → M6.

## Mockup values (binding)

| Element | Value |
|---|---|
| Field grid | Label column fixed 110 pt, right-aligned, 12.5 pt, `inkSecondary`; gap label→field 10 pt; line spacing 10 pt |
| Button | Radius 7, padding 5 pt vertical / 14 pt horizontal, 12.5 pt |
| Button secondary | Ground `card`, 1-pt border `hairline`, text `inkSecondary` |
| Button primary | Fill `remoteBlue`, text white semibold; pressed slightly darkened (opacity ~0.85) |

## Implementation

### 1. `PolishedButtonStyle` (new file `Sources/MacSCPApp/PolishedButtonStyle.swift`)

- `struct PolishedButtonStyle: ButtonStyle` with `let prominent: Bool`:
  radius-7 RoundedRectangle, padding 5×14, `font(.system(size: 12.5,
  weight: prominent ? .semibold : .regular))`; prominent: fill
  `DesignTokens.remoteBlue`, text `.white`, `opacity(configuration.isPressed
  ? 0.85 : 1)`; secondary: fill `DesignTokens.card`, `strokeBorder`
  `DesignTokens.hairline` 1 pt, text `DesignTokens.inkSecondary`, pressed
  opacity 0.85. Disabled rendering via `.opacity` through environment
  `\.isEnabled` (0.5). Convenience: `static` accessors
  `.polished` / `.polishedProminent` via a `ButtonStyle` extension.

### 2. Form grid (`Sources/MacSCPApp/ConnectionFormView.swift`)

- Private helper view `FormRow<Content: View>`:
  `FormRow(label: String) { content }` → `HStack(alignment: .firstTextBaseline,
  spacing: 10)` with `Text(label).font(.system(size: 12.5))
  .foregroundStyle(DesignTokens.inkSecondary).frame(width: 110,
  alignment: .trailing)` + content.
- The `Form { … }` becomes a `VStack(alignment: .leading, spacing: 10)`
  with `FormRow` rows (Host, Port, Username, Authentication [segmented
  picker as content], Password/key path/passphrase, session name, group
  [picker], save toggle [`FormRow(label: "")` — the toggle aligns on the
  field column]). Labels come from the existing catalog strings (today's
  TextField label parameters become `FormRow` labels; the TextFields keep
  their prompts/placeholders).
- `errorHighlight` is applied to the respective `FormRow` (border around
  label+field, the existing outer-padding look from design review
  `6e03c7a` stays unchanged).
- Tab order/focus: TextFields remain system controls in hierarchy order —
  NO behavior change (the Host→Port→User→Password[…] tab chain must
  function identically).
- The fingerprint prompt keeps its layout; only its buttons switch to the
  new style.
- `.disabled(isConnecting)` grouping, fileImporter, alert, edit-mode
  branches, callbacks: unchanged.

### 3. Button application (ConnectionFormView only)

- Primary (`.polishedProminent`): "Verbinden" (New), "Speichern &
  verbinden" (Edit), "Vertrauen & verbinden" (Prompt). The previous
  `.buttonStyle(.borderedProminent)` is dropped in favor of the new
  style.
- Secondary (`.polished`): "Zurück", "Speichern", "…" browse.
- `keyboardShortcut(.defaultAction)` assignments and `disabled` logic
  stay exactly as they are.
- NOT converted: toolbar (native macOS toolbar), alerts, sheets, settings
  window, sidebar — system chrome stays system (M5f line).

## Invariants

- NO behavior change: validation/alert, edit-mode semantics (password
  "unchanged"), TOFU flow, fileImporter, shortcuts, disabled states.
- Both appearances via existing tokens; no new static colors (white on
  remoteBlue is deliberately static — mockup `#fff` on brand blue, correct
  in both appearances).
- CI rules: blue = primary action; amber does not appear in the form.
- Localization untouched (label keys identical).

## Tests

- No new unit tests (view layer); existing 295 stay green.
- Visual smoke, light AND dark: grid alignment (110-pt labels flush),
  validation error (connect with empty fields → alert + border around
  row), edit mode (buttons Zurück/Speichern/Speichern & verbinden in the
  new style), TOFU prompt (delete pin → prompt with new buttons, trust
  flow works), **tab-chain regression** Host→Port→User→Password, "…"
  browse opens panel.

## Deliberately NOT in M5k

- Settings window restyling (system form stays).
- Toolbar/sheet/alert buttons (system chrome).
- Custom TextField look (system fields stay — focus ring/tab native).
