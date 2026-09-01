# M11o — Transfer Bar Show/Hide Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the transfer bar show/hide-able via a toolbar icon (next to the terminal icon), a menu entry, and ⌘⇧Y — per tab, not persisted, with auto-reveal on every new transfer and an empty state.

**Architecture:** App layer only. A new per-tab bool `SessionTab.transfersPanelVisible` owns visibility (mirroring `TerminalPanelViewModel.isVisible`). `ContentView` renders `TransferQueueBar` only when the bool is visible, and sets it automatically via `.onChange` on the item count when a transfer is added. Toolbar button + menu entry (via `TabCommands.toggleTransfers`) toggle the bool.

**Tech Stack:** SwiftUI + AppKit, Swift 6 (`.swiftLanguageMode(.v5)`), macOS 15.

## Global Constraints

- Swift-tools 6.0, all targets `.swiftLanguageMode(.v5)`, min. macOS 15.
- Code/comments/`reason:` strings **English only**.
- UI strings via `Sources/MacSCPApp/Resources/{en,de}.lproj/Localizable.strings`, EN default + DE, lookup `L10n.string(key, "English default")`.
- **Typographic quotation marks `„ "` / `…`; one ASCII `"` in a DE line invalidates the whole DE catalogue** (guarded by `plutil -lint` + `LocalizableStringsTests`).
- Visibility **per tab**, **not persisted** (no `SettingsStore` key, no singleton).
- No Core; **no app test target** — verification via `swift build` (no new warnings), catalogue parity + `plutil`, the full `swift test` unchanged and green, reading/tracing + a **runtime idle-CPU smoke test**.
- **M11n lesson:** no `MenuBarExtra`; this feature does not touch it. Start a dev build before shipping and check idle CPU (~0%).
- Conventional Commits; footer `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- Baseline: **900 tests / 62 suites** green.
- No release/tag without explicit maintainer direction.

---

### Task 1: Transfer bar show/hide (App)

**Files:**
- Modify: `Sources/MacSCPApp/SessionTab.swift` (`transfersPanelVisible`)
- Modify: `Sources/MacSCPApp/TransferQueueBar.swift` (empty state instead of `EmptyView`)
- Modify: `Sources/MacSCPApp/ContentView.swift` (visibility gate + `.onChange` auto-reveal + toolbar button + `toggleTransfers` closure)
- Modify: `Sources/MacSCPApp/MacSCPApp.swift` (`TabCommands.toggleTransfers` + menu entry)
- Modify: `Sources/MacSCPApp/Resources/en.lproj/Localizable.strings`
- Modify: `Sources/MacSCPApp/Resources/de.lproj/Localizable.strings`

**Interfaces:**
- Consumes (existing, verified): `SessionTab` (`@Observable`, `id: UUID`, `transferQueue: TransferQueueViewModel`, `isConnected`); `TransferQueueViewModel.items: [Item]`; `TabCommands` (`@Observable`, app layer in `MacSCPApp.swift`, `isActiveTabConnected`, the `toggleTerminal` pattern); `ContentView.activeTab`, `window?.isKeyWindow`; the `ToolbarItemGroup(.primaryAction)` (gated `if let session = activeTab.session`) with the terminal `Button`; `CommandGroup(after: .sidebar)` with "Show/Hide Hidden Files"; `L10n.string`.
- Produces: `SessionTab.transfersPanelVisible: Bool`; `TabCommands.toggleTransfers: (() -> Void)?`.

- [x] **Step 1: Per-tab bool.** In `Sources/MacSCPApp/SessionTab.swift`, right after `let conflictBridge = ConflictPromptBridge()` (around line 31):

```swift
    /// Whether the transfer bar is shown for this tab (M11o). Per-tab and
    /// in-memory, mirroring `TerminalPanelViewModel.isVisible` — the toolbar
    /// icon / menu / ⌘⇧Y toggle it, and a newly enqueued transfer auto-reveals
    /// it (see `ContentView`). Not persisted.
    var transfersPanelVisible = false
```

- [x] **Step 2: Empty state in the bar.** In `Sources/MacSCPApp/TransferQueueBar.swift`, replace the `if viewModel.items.isEmpty { EmptyView() }` branch with a visible empty state (visibility itself is now controlled by `ContentView`; if the bar reaches the empty case, it is deliberately being kept open). Replace:

```swift
        if viewModel.items.isEmpty {
            EmptyView()
        } else {
```

with:

```swift
        if viewModel.items.isEmpty {
            VStack(spacing: 0) {
                Rectangle()
                    .fill(DesignTokens.hairline)
                    .frame(height: 1)
                HStack {
                    Text(L10n.string("transfers.empty", "No transfers"))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(DesignTokens.inkSecondary)
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
            }
        } else {
```

(The `else` branch with the header/list stays unchanged.)

- [x] **Step 3: Visibility gate + auto-reveal in `ContentView`.** In `Sources/MacSCPApp/ContentView.swift`, replace the render line (currently line 1001):

```swift
                    TransferQueueBar(viewModel: tab.transferQueue)
```

with:

```swift
                    if tab.transfersPanelVisible {
                        TransferQueueBar(viewModel: tab.transferQueue)
                    }
```

And on the same `VStack` container (the one holding the panes + banner + bar, right before `.task(id: session.id)` at line 1003) attach the auto-reveal observation — every newly queued transfer (a rising item count) reveals the bar:

```swift
                .onChange(of: tab.transferQueue.items.count) { oldCount, newCount in
                    // A newly enqueued transfer reveals the bar (M11o) — the
                    // pre-M11o auto-appear behavior, now gated by the per-tab
                    // visibility flag. Only an INCREASE reveals; clearing or
                    // finishing items never force-hides.
                    if newCount > oldCount {
                        tab.transfersPanelVisible = true
                    }
                }
```

- [x] **Step 4: Toolbar icon.** In `Sources/MacSCPApp/ContentView.swift`, in the `ToolbarItemGroup(placement: .primaryAction)`, insert the new button **between** the terminal `Button` (ending with its `.help(...)` modifier around line 780) and the "Disconnect" `Button`. **No** `.keyboardShortcut` here — ⌘⇧Y lives exclusively on the menu entry (Step 7), so SwiftUI does not see two commands for the same key (the terminal button uses the same pattern for ⌘T). The help text still names the shortcut as a hint:

```swift
                    Button {
                        activeTab.transfersPanelVisible.toggle()
                    } label: {
                        Label(L10n.string("browser.transfersToggle", "Transfers"),
                              systemImage: "tray.full")
                    }
                    .help(L10n.string("browser.transfersToggleHelp",
                                      "Show/hide transfers (⌘⇧Y)"))
```

- [x] **Step 5: `toggleTransfers` closure in `.task`.** In `Sources/MacSCPApp/ContentView.swift`, in the `.task { … }` block next to `tabCommands.toggleTerminal` (around line 574), add:

```swift
            // Transfer-bar menu bridge (M11o) — same key-window guard as the
            // other tab commands; toggles the active tab's per-tab flag.
            tabCommands.toggleTransfers = {
                guard window?.isKeyWindow == true else { return }
                activeTab.transfersPanelVisible.toggle()
            }
```

- [x] **Step 6: `TabCommands` field.** In `Sources/MacSCPApp/MacSCPApp.swift`, in the `TabCommands` class body (after `var openExternalTerminal: (() -> Void)?`, around line 40):

```swift
    /// Transfer-bar toggle (M11o): the "Show/Hide Transfers" menu entry and
    /// ⌘⇧Y drive this; `ContentView.task` wires it against `window?.isKeyWindow`
    /// and toggles the active tab's `transfersPanelVisible`. Enabled state
    /// mirrors `isActiveTabConnected` (same as the Terminal entries).
    var toggleTransfers: (() -> Void)?
```

- [x] **Step 7: Menu entry + shortcut.** In `Sources/MacSCPApp/MacSCPApp.swift`, in `CommandGroup(after: .sidebar)` (lines 164–169), insert the new entry AFTER the "Show/Hide Hidden Files" button:

```swift
            CommandGroup(after: .sidebar) {
                Button(L10n.string("menu.toggleHidden", "Show/Hide Hidden Files")) {
                    settingsStore.showHiddenFiles.toggle()
                }
                .keyboardShortcut(".", modifiers: [.command, .shift])

                Button(L10n.string("menu.transfers.toggle", "Show/Hide Transfers")) {
                    tabCommands.toggleTransfers?()
                }
                .keyboardShortcut("y", modifiers: [.command, .shift])
                .disabled(!tabCommands.isActiveTabConnected)
            }
```

- [x] **Step 8: Strings EN.** Append to `Sources/MacSCPApp/Resources/en.lproj/Localizable.strings` (with the `transfers.*`/`browser.*`/`menu.*` blocks, or at the end):

```
"browser.transfersToggle" = "Transfers";
"browser.transfersToggleHelp" = "Show/hide transfers (⌘⇧Y)";
"menu.transfers.toggle" = "Show/Hide Transfers";
"transfers.empty" = "No transfers";
```

- [x] **Step 9: Strings DE.** Append to `Sources/MacSCPApp/Resources/de.lproj/Localizable.strings` (ASCII `"` as delimiter only, none inside the value; ⌘⇧Y verbatim):

```
"browser.transfersToggle" = "Übertragungen";
"browser.transfersToggleHelp" = "Übertragungen ein-/ausblenden (⌘⇧Y)";
"menu.transfers.toggle" = "Übertragungen ein-/ausblenden";
"transfers.empty" = "Keine Übertragungen";
```

- [x] **Step 10: Catalogue lint + parity.**

```bash
plutil -lint Sources/MacSCPApp/Resources/en.lproj/Localizable.strings
plutil -lint Sources/MacSCPApp/Resources/de.lproj/Localizable.strings
```
Expected: both "OK". Then `swift test --filter Localizable` → PASS (EN/DE key parity).

- [x] **Step 11: Build + full suite.** `swift build`
Expected: `Build complete`, no NEW warnings (the four pre-existing Citadel/`_` warnings remain). Then `swift test`
Expected: **900 tests / 62 suites** green (unchanged — no new/changed Core logic).

- [x] **Step 12: Trace verification (no app test target).** Read and confirm:
  - `TransferQueueBar` is rendered in `ContentView` only when `tab.transfersPanelVisible`; empty ⇒ empty state "Keine Übertragungen", non-empty ⇒ unchanged header/list.
  - `.onChange(of: tab.transferQueue.items.count)` sets `transfersPanelVisible = true` on an increase; "cleaning up"/completing (falling or equal count) never force-hides.
  - The toolbar button (only present for an active session, since it is in the gated group) and the menu entry (disabled without a connection) toggle the same per-tab bool; **⌘⇧Y lives only on the menu entry** (no double binding), the toolbar icon is a plain clickable button with help text.
  - `toggleTransfers` is key-window-guarded like the other `tabCommands`.

- [x] **Step 13: Runtime idle-CPU smoke test.** Build and launch a dev build, check idle CPU (must be ~0% — this catches SwiftUI layout storms that build/tests don't see):

```bash
MACSCP_VERSION=1.2.0-dev MACSCP_BUILD=m11o scripts/package-app
codesign --force --deep --sign - dist/macSCP.app; xattr -cr dist/macSCP.app
open dist/macSCP.app; sleep 7
ps -o pid,%cpu,state -p "$(pgrep -f 'dist/macSCP.app/Contents/MacOS/macSCP' | head -1)"
pkill -f 'dist/macSCP.app/Contents/MacOS/macSCP'
```
Expected: `%CPU` near 0, state `S`.

- [x] **Step 14: Commit.**

```bash
git add Sources/MacSCPApp/SessionTab.swift Sources/MacSCPApp/TransferQueueBar.swift \
        Sources/MacSCPApp/ContentView.swift Sources/MacSCPApp/MacSCPApp.swift \
        Sources/MacSCPApp/Resources/en.lproj/Localizable.strings \
        Sources/MacSCPApp/Resources/de.lproj/Localizable.strings
git commit -m "feat: toggle the transfer bar via a toolbar icon, menu and ⌘⇧Y"
```

---

### Task 2: Final verification (coordinator)

- [x] Gated suites: `MACSCP_ITEST=1 MACSCP_KEYCHAIN=1 swift test` → green, zero skips (Docker rig from the main checkout).
- [x] `swift build` clean; `plutil -lint` both catalogues OK; `LocalizableStringsTests` green.
- [x] Runtime idle-CPU smoke test passed (Step 13).
- [x] Whole-task Opus review (small app diff): focus on (a) auto-reveal only on an increase, never a forced hide; (b) per-tab bool, no singleton/no persistence; (c) toolbar/menu/shortcut wiring + key-window guard; (d) empty state vs. list; (e) L10n parity + no ASCII `"` in DE. Fix rounds until "Ready to merge: Yes".
- [ ] Visual smoke — maintainer (icon next to Terminal, ⌘⇧Y, menu entry; collapsing during a transfer; opening empty + "cleaning up"; new transfer expands it; separate per tab; light/dark; DE ↔ EN).
- [x] Plan checkboxes, ledger, push develop, `gh run watch`, deploy dev build, memory. **NO release.** Note the ⌘⇧Y shortcut for the later keyboard-shortcut overview.
