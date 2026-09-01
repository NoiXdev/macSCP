# M5h — Sidebar design polish implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The sessions sidebar takes on surface (tinted blend + right hairline), row rhythm, and label typography from the CI mockup — pure view layer, zero behavior change.

**Architecture:** Three new surface tokens (`paper`, `card`, `sidebarSurface`) via the existing `dynamicNS` helper; `SessionSidebar` gets the tinted container surface with a hairline edge, the three section-label spots get the exact mockup typography, `SessionRow` gets the 5×10 metrics with a `remoteSoft` active fill. A coordinator closeout task verifies visually in both appearances and may fine-tune the list alignment by a few points.

**Tech Stack:** Swift 6 toolchain / `.swiftLanguageMode(.v5)`, SwiftUI, macOS 15+. No new unit tests (view layer); the existing 295 stay green.

## Global Constraints

- Spec: `docs/superpowers/specs/2026-07-11-m5h-sidebar-polish-design.md` — binding, including the value table.
- NO behavior change: context menus, inline rename (Enter/Escape/blur cancel), drag & drop, delete dialog, new-group alert, collapse state, `interactionsDisabled`, error-text area — exactly as today. All callbacks/state machines in `SessionSidebar`/`SessionRow` untouched.
- Both appearances via dynamic tokens; no static colors in views.
- CI rules: blue = active/selection (`remoteSoft`/`remoteBlue`), phosphor for status only.
- Code + comments English ONLY; Conventional Commits (English), footer: `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- `swift build` and full `swift test` (295) green after every task.
- Environment note: Bash errors "claude-opus-4-8 is temporarily unavailable … cannot determine the safety" are NOT permission denials — wait and retry identically.

## Schedule

T1 → T2 → T3 sequential.

---

### Task 1: Surface tokens

**Files:**
- Modify: `Sources/MacSCPApp/DesignTokens.swift` (add below the M5g tokens)

**Interfaces:**
- Consumes: existing private helper `dynamicNS(light:dark:alpha:)`.
- Produces (T2 relies on this exactly):
  - `DesignTokens.paper: Color` — light `#F4F7FA`, dark `#0D1720`
  - `DesignTokens.card: Color` — light `#FFFFFF`, dark `#14212E`
  - `DesignTokens.sidebarSurface: Color` — light `#FCFDFE`, dark `#121E2A`

- [x] **Step 1: Implement** — insert after `localSoft`:

```swift
    // Surface hierarchy (mockup: paper ground, card content surface).
    // `paper`/`card` are staged for the transfer-bar and form polish
    // rounds; M5h consumes only `sidebarSurface`.
    static let paper = Color(nsColor: dynamicNS(light: 0xF4F7FA, dark: 0x0D1720))
    static let card = Color(nsColor: dynamicNS(light: 0xFFFFFF, dark: 0x14212E))
    /// The mockup's sidebar tint: color-mix(card 70%, paper), precomputed
    /// per appearance so it stays a single deterministic dynamic color.
    static let sidebarSurface = Color(nsColor: dynamicNS(light: 0xFCFDFE, dark: 0x121E2A))
```

- [x] **Step 2: Build + suite** — `swift build` error-free, `swift test` 295/295.
- [x] **Step 3: Commit** — `feat: add surface hierarchy design tokens`.

---

### Task 2: Sidebar surface, label typography, row metrics

**Files:**
- Modify: `Sources/MacSCPApp/SessionSidebar.swift` (currently 368 lines; ONLY the styling spots shown below — all logic, callbacks, menus, rename/drop/alert machinery stays byte-identical)

**Interfaces:**
- Consumes: T1 `sidebarSurface` + M5g tokens `hairline`, `inkTertiary`, `remoteSoft`.
- Produces: no new APIs.

- [x] **Step 1: Container surface + hairline edge** — on the outer `VStack` (after `.disabled(interactionsDisabled)`, before `.alert`):

```swift
        .padding(.top, 12)
        .background(DesignTokens.sidebarSurface)
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(DesignTokens.hairline)
                .frame(width: 1)
        }
```

  (The 12 pt top padding is the container padding from the spec table; the
  horizontal ~8 pt come from list insets + label/row padding, no
  additional modifier needed.)

- [x] **Step 2: Label typography in three spots** — identical style, replace each:

The "SESSIONS" label (lines 39–44), old `.font(.caption2.weight(.semibold)) .tracking(0.8) .foregroundStyle(.secondary) .padding(.horizontal, 12) .padding(.vertical, 6)` → new:

```swift
                .font(.system(size: 10.5, weight: .semibold))
                .tracking(1.0)
                .foregroundStyle(DesignTokens.inkTertiary)
                .padding(.top, 2)
                .padding(.horizontal, 10)
                .padding(.bottom, 6)
```

The `groupHeader` text (lines 168–172) and the "IMPORTED" header (lines 210–213): the same three modifiers (`font`/`tracking(1.0)`/`foregroundStyle(DesignTokens.inkTertiary)`) in place of `.font(.caption2.weight(.semibold)) .tracking(0.8) .foregroundStyle(.secondary)`; the headers sit in the list and keep their list insets (no extra padding), context menu/drop/rename unchanged.

- [x] **Step 3: Row metrics in `SessionRow`** — replace padding and active fill (lines 323–330):

```swift
        .padding(.vertical, 5)
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isActive
                      ? DesignTokens.remoteSoft
                      : (isHovering ? Color.secondary.opacity(0.08) : Color.clear))
        )
```

  and apply to `SessionRow` in `sessionRows(_:)`: `.listRowInsets(EdgeInsets(top: 1, leading: 0, bottom: 1, trailing: 6))` (2 pt effective row spacing; leading 0, because the row carries its own 10 pt inner padding and aligns with the 10 pt label padding).

- [x] **Step 4: Build + full suite** — `swift build`, `swift test` 295/295.
- [x] **Step 5: Commit** — `feat: tint the sidebar surface and align rows with the mockup rhythm`.

---

### Task 3: Closeout verification (coordinator)

- [x] `swift test` overall; rig up (`docker compose -f docker/test-server/compose.yml start` — the container exists stopped, `start` keeps host keys) and `MACSCP_ITEST=1 MACSCP_KEYCHAIN=1 swift test` fully green.
- [x] **Visual smoke test in LIGHT and DARK** (light app-only via forcing `NSRequiresAquaSystemAppearance` in the wrapper Info.plist, then REMOVE it afterward):
  - The tinted sidebar surface stands out against the pane surface; 1 pt hairline visible on the right edge.
  - Labels ("SESSIONS", group name, "IMPORTED") 10.5 pt small caps with tracking in inkTertiary; alignment labels ↔ rows (both 10 pt from the edge) — on a mismatch the coordinator may adjust the `listRowInsets` values by ±2 pt (as its own `fix:` commit).
  - Active row: `remoteSoft` pill (r6) + blue semibold text + phosphor dot; hover subtle.
  - Behavior regression: connect click, context menu (session + group + background), inline rename Enter/Escape, expand/collapse group, delete dialog (cancel).
- [x] Check off the plan checkboxes, commit `docs: mark M5h plan tasks as completed` (+ footer).

## Outlook

Round 3: transfer bar (5 pt pill progress r99, 8×14 metrics) & terminal strip · Round 4: form grid (110 pt labels) & button radii r7. After that, M6 — release.
