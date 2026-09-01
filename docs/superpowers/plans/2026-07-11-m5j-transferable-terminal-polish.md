# M5j — Design polish: transfer bar & terminal strip Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The transfer bar and terminal panel adopt the dimensions, typography, and pill-progress shape from the CI mockup — pure view layer, zero behavior change.

**Architecture:** `TransferQueueBar` gets a hairline top edge, 8×14 dimensions, 12-pt typography with ink/inkSecondary, and a new private `PillProgress` capsule (shape from the mockup, fill semantically amber/blue per the CI rule); `terminalPanel` in `ContentView` gets a hairline top edge and the "shell ended" state gets the strip dimensions. All tokens already exist (M5g/M5h).

**Tech Stack:** Swift 6 toolchain / `.swiftLanguageMode(.v5)`, SwiftUI, macOS 15+. No new unit tests (view layer); the existing 295 stay green.

## Global Constraints

- Spec: `docs/superpowers/specs/2026-07-11-m5j-transferable-terminal-polish-design.md` — binding, including the value table and color decision (pill FILL is semantic `localAmber` upload / `remoteBlue` download; only the SHAPE — 5-pt capsule r99, track in hairline — comes from the mockup).
- NO behavior change: queue status semantics (queued/running/finished/failed/cancelled/skipped/interrupted), cleanup-button logic, rate/ETA label logic, resume banner, conflict sheet, terminal lifecycle/⌘T/replay — exactly as today. Errors stay system red, "interrupted" stays `.orange`.
- Both appearances via existing dynamic tokens (`hairline`, `ink`, `inkSecondary`, `localAmber`, `remoteBlue`); no new static colors.
- Code + comments English ONLY; Conventional Commits (English), footer: `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- `swift build` and the full `swift test` (295) green after every task.
- Environment note: Bash errors "claude-opus-4-8 is temporarily unavailable … cannot determine the safety" are NOT permission denials — wait and retry identically.

## Schedule

T1 → T2 → T3 sequential (T1 and T2 share no file but are each small; sequential is simpler).

---

### Task 1: Transfer bar in the mockup rhythm + PillProgress

**Files:**
- Modify: `Sources/MacSCPApp/TransferQueueBar.swift` (currently 109 lines; structure/status branches stay, only styling + the determinate progress branch change)

**Interfaces:**
- Consumes: `DesignTokens.hairline`, `.ink`, `.inkSecondary`, `.localAmber`, `.remoteBlue` (all exist).
- Produces: a private `PillProgress(fraction: Double, fill: Color)` view in the same file — no API export.

- [x] **Step 1: Switch over the styling** — exact changes:

a) `Divider()` (line 18) →

```swift
                Rectangle()
                    .fill(DesignTokens.hairline)
                    .frame(height: 1)
```

b) Header row: title modifier `.font(.caption.weight(.semibold)).foregroundStyle(.secondary)` → `.font(.system(size: 12, weight: .semibold)).foregroundStyle(DesignTokens.inkSecondary)`; header padding `.padding(.horizontal, 12).padding(.vertical, 4)` → `.padding(.horizontal, 14).padding(.vertical, 8)`.

c) List container: `.padding(.horizontal, 12).padding(.bottom, 6)` → `.padding(.horizontal, 14).padding(.bottom, 8)`.

d) Row: `HStack(spacing: 8)` → `HStack(spacing: 12)`; at the end of the row `.font(.callout)` → `.font(.system(size: 12))`; the filename `Text(item.fileName)` additionally gets `.foregroundStyle(DesignTokens.ink)`; ALL `.foregroundStyle(.secondary)` occurrences in the status branches (queued/rate label/cancelled/skipped) → `.foregroundStyle(DesignTokens.inkSecondary)`; the `.font(.caption)` occurrences in the status branches stay `.caption` (11 pt — secondary, smaller than the 12-pt row, matching the mockup's proportion). Leave the error branch (red) and the interrupted branch (orange) unchanged, other than the font size.

e) Replace the determinate progress branch (lines 78–81):

```swift
                if let fraction = progress.fraction {
                    PillProgress(fraction: fraction, fill: tint(for: item.direction))
                        .frame(width: 120)
                } else {
```

- [x] **Step 2: Append PillProgress** — at the end of the file:

```swift
/// Mockup-style progress pill: 5pt capsule track in the hairline color,
/// capsule fill in the transfer direction's brand color (CI rule: amber =
/// upload, blue = download — only the SHAPE comes from the mockup).
private struct PillProgress: View {
    let fraction: Double
    let fill: Color

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(DesignTokens.hairline)
                Capsule()
                    .fill(fill)
                    .frame(width: max(5, geometry.size.width * min(max(fraction, 0), 1)))
            }
        }
        .frame(height: 5)
        .animation(.linear(duration: 0.2), value: fraction)
    }
}
```

  (The `max(5, …)` floor keeps the fill capsule round while fraction > 0 is small; fraction is defensively clamped to 0…1.)

- [x] **Step 3: Build + full suite** — `swift build` error-free, `swift test` 295/295.
- [x] **Step 4: Commit** — `feat: restyle the transfer bar with the mockup pill progress`.

---

### Task 2: Terminal panel — hairline top edge + ended dimensions

**Files:**
- Modify: `Sources/MacSCPApp/ContentView.swift:404-421` (`terminalPanel`)

**Interfaces:**
- Consumes: `DesignTokens.hairline` (exists).
- Produces: no new APIs.

- [x] **Step 1: Implement** — `terminalPanel` becomes:

```swift
    @ViewBuilder
    private func terminalPanel(_ session: BrowserSession) -> some View {
        ZStack {
            Color(nsColor: DesignTokens.terminalBackground)
            switch session.terminal.state {
            case .running, .opening:
                SSHTerminalView(viewModel: session.terminal)
            case .ended(let message):
                VStack(spacing: 8) {
                    Text(message ?? L10n.string("terminal.ended", "Shell ended."))
                        .font(.system(size: 12))
                        .foregroundStyle(Color(nsColor: DesignTokens.terminalText))
                    Button(L10n.string("terminal.reopen", "Reopen")) { session.terminal.openIfNeeded() }
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 14)
            case .closed:
                Color.clear
            }
        }
        // Mockup: the terminal strip carries a hairline top border.
        .overlay(alignment: .top) {
            Rectangle()
                .fill(DesignTokens.hairline)
                .frame(height: 1)
                .allowsHitTesting(false)
        }
    }
```

  (The only changes versus today: the two padding modifiers + `font` in the ended branch and the hairline overlay; lifecycle/state switch identical.)

- [x] **Step 2: Build + full suite** — `swift build`, `swift test` 295/295.
- [x] **Step 3: Commit** — `feat: add the mockup hairline edge to the terminal panel`.

---

### Task 3: Final verification (coordinator)

- [x] `swift test` overall; rig up (`docker compose -f docker/test-server/compose.yml start` — `start`, not `up`/`down`, host keys stay) and `MACSCP_ITEST=1 MACSCP_KEYCHAIN=1 swift test` fully green.
- [x] **Visual smoke in LIGHT and DARK** (light app-only via `NSRequiresAquaSystemAppearance`, then REMOVE it):
  - In Settings, set the download limit to ~200 KB/s, drag an ~8 MB file remote→local (or the download button) → the pill visibly fills: 5-pt capsule, track in the hairline color, fill BLUE (download); then an upload → fill AMBER; limit back to 0.
  - Hairline above the transfer bar and as the terminal top edge (⌘T) visible; header/row dimensions 8×14; filename in ink, secondary text in inkSecondary.
  - "Shell ended" state: type `exit` in the terminal → 12-pt text with 8×14 padding, reopen works.
  - Behavior regression: a transfer runs through (✓ checkmark in the direction color), cleanup empties it, ⌘T opens/closes, the rate/ETA label appears.
- [x] Check off the plan's checkboxes, commit `docs: mark M5j plan tasks as completed` (+ footer).

## Outlook

Round 4 (last): form grid (110-pt labels) & button radii r7. After that, M6 — release.
