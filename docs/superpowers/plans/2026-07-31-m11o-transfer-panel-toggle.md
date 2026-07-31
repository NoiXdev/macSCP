# M11o — Transfer-Leiste ein-/ausblendbar Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Die Transfer-Leiste per Toolbar-Icon (neben dem Terminal-Icon), Menüeintrag und ⌘⇧Y ein-/ausblendbar machen — pro Tab, nicht persistiert, mit Auto-Einblenden bei jeder neuen Übertragung und einem Leerzustand.

**Architecture:** Rein App-Schicht. Ein neues Pro-Tab-Bool `SessionTab.transfersPanelVisible` besitzt die Sichtbarkeit (spiegelt `TerminalPanelViewModel.isVisible`). `ContentView` rendert `TransferQueueBar` nur bei sichtbarem Bool und setzt es per `.onChange` auf die Item-Anzahl automatisch, wenn eine Übertragung dazukommt. Toolbar-Button + Menüeintrag (über `TabCommands.toggleTransfers`) schalten das Bool.

**Tech Stack:** SwiftUI + AppKit, Swift 6 (`.swiftLanguageMode(.v5)`), macOS 15.

## Global Constraints

- Swift-tools 6.0, alle Targets `.swiftLanguageMode(.v5)`, min. macOS 15.
- Code/Kommentare/`reason:`-Strings **English only**.
- UI-Strings über `Sources/MacSCPApp/Resources/{en,de}.lproj/Localizable.strings`, EN-Default + DE, Lookup `L10n.string(key, "English default")`.
- **Typografische Anführungszeichen `„ "` / `…`; ein ASCII-`"` in einer DE-Zeile macht den ganzen DE-Katalog ungültig** (`plutil -lint` + `LocalizableStringsTests` bewachen das).
- Sichtbarkeit **pro Tab**, **nicht persistiert** (kein `SettingsStore`-Key, kein Singleton).
- Kein Core; **kein App-Test-Target** — Verifikation per `swift build` (keine neuen Warnungen), Katalog-Parität + `plutil`, volle `swift test` unverändert grün, Lesen/Trace + **Runtime-Idle-CPU-Rauchtest**.
- **M11n-Lektion:** keine `MenuBarExtra`; dieses Feature berührt sie nicht. Vor Auslieferung Dev-Build starten und Idle-CPU (~0%) prüfen.
- Conventional Commits; Footer `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- Baseline: **900 Tests / 62 Suiten** grün.
- Kein Release/Tag ohne ausdrückliche Maintainer-Anordnung.

---

### Task 1: Transfer-Leiste ein-/ausblendbar (App)

**Files:**
- Modify: `Sources/MacSCPApp/SessionTab.swift` (`transfersPanelVisible`)
- Modify: `Sources/MacSCPApp/TransferQueueBar.swift` (Leerzustand statt `EmptyView`)
- Modify: `Sources/MacSCPApp/ContentView.swift` (Sichtbarkeits-Gate + `.onChange`-Auto-Einblenden + Toolbar-Button + `toggleTransfers`-Closure)
- Modify: `Sources/MacSCPApp/MacSCPApp.swift` (`TabCommands.toggleTransfers` + Menüeintrag)
- Modify: `Sources/MacSCPApp/Resources/en.lproj/Localizable.strings`
- Modify: `Sources/MacSCPApp/Resources/de.lproj/Localizable.strings`

**Interfaces:**
- Consumes (bestehend, verifiziert): `SessionTab` (`@Observable`, `id: UUID`, `transferQueue: TransferQueueViewModel`, `isConnected`); `TransferQueueViewModel.items: [Item]`; `TabCommands` (`@Observable`, App-Schicht in `MacSCPApp.swift`, `isActiveTabConnected`, `toggleTerminal`-Muster); `ContentView.activeTab`, `window?.isKeyWindow`; die `ToolbarItemGroup(.primaryAction)` (gated `if let session = activeTab.session`) mit dem Terminal-`Button`; `CommandGroup(after: .sidebar)` mit „Show/Hide Hidden Files"; `L10n.string`.
- Produces: `SessionTab.transfersPanelVisible: Bool`; `TabCommands.toggleTransfers: (() -> Void)?`.

- [x] **Step 1: Pro-Tab-Bool.** In `Sources/MacSCPApp/SessionTab.swift`, direkt nach `let conflictBridge = ConflictPromptBridge()` (um Zeile 31):

```swift
    /// Whether the transfer bar is shown for this tab (M11o). Per-tab and
    /// in-memory, mirroring `TerminalPanelViewModel.isVisible` — the toolbar
    /// icon / menu / ⌘⇧Y toggle it, and a newly enqueued transfer auto-reveals
    /// it (see `ContentView`). Not persisted.
    var transfersPanelVisible = false
```

- [x] **Step 2: Leerzustand in der Leiste.** In `Sources/MacSCPApp/TransferQueueBar.swift` den `if viewModel.items.isEmpty { EmptyView() }`-Zweig durch einen sichtbaren Leerzustand ersetzen (die Sichtbarkeit selbst steuert jetzt `ContentView`; erreicht die Leiste den leeren Fall, ist sie bewusst offen gehalten). Ersetze:

```swift
        if viewModel.items.isEmpty {
            EmptyView()
        } else {
```

durch:

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

(Der `else`-Zweig mit Kopfzeile/Liste bleibt unverändert.)

- [x] **Step 3: Sichtbarkeits-Gate + Auto-Einblenden in `ContentView`.** In `Sources/MacSCPApp/ContentView.swift` die Render-Zeile (aktuell Zeile 1001):

```swift
                    TransferQueueBar(viewModel: tab.transferQueue)
```

ersetzen durch:

```swift
                    if tab.transfersPanelVisible {
                        TransferQueueBar(viewModel: tab.transferQueue)
                    }
```

Und am selben `VStack`-Container (der die Panes + Banner + Leiste hält, unmittelbar vor `.task(id: session.id)` bei Zeile 1003) die Auto-Einblende-Beobachtung anhängen — jede neu eingereihte Übertragung (steigende Item-Anzahl) enthüllt die Leiste:

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

- [x] **Step 4: Toolbar-Icon.** In `Sources/MacSCPApp/ContentView.swift`, in der `ToolbarItemGroup(placement: .primaryAction)` den neuen Button **zwischen** dem Terminal-`Button` (endet mit dem `.help(...)`-Modifier um Zeile 780) und dem „Disconnect"-`Button` einfügen. **Kein** `.keyboardShortcut` hier — das ⌘⇧Y lebt ausschließlich am Menüeintrag (Step 7), damit SwiftUI nicht zwei Kommandos für dieselbe Taste sieht (dasselbe Muster nutzt der Terminal-Knopf für ⌘T). Der Hilfetext nennt das Kürzel dennoch als Hinweis:

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

- [x] **Step 5: `toggleTransfers`-Closure in `.task`.** In `Sources/MacSCPApp/ContentView.swift`, im `.task { … }`-Block neben `tabCommands.toggleTerminal` (um Zeile 574) ergänzen:

```swift
            // Transfer-bar menu bridge (M11o) — same key-window guard as the
            // other tab commands; toggles the active tab's per-tab flag.
            tabCommands.toggleTransfers = {
                guard window?.isKeyWindow == true else { return }
                activeTab.transfersPanelVisible.toggle()
            }
```

- [x] **Step 6: `TabCommands`-Feld.** In `Sources/MacSCPApp/MacSCPApp.swift`, im `TabCommands`-Klassenkörper (nach `var openExternalTerminal: (() -> Void)?`, um Zeile 40):

```swift
    /// Transfer-bar toggle (M11o): the "Show/Hide Transfers" menu entry and
    /// ⌘⇧Y drive this; `ContentView.task` wires it against `window?.isKeyWindow`
    /// and toggles the active tab's `transfersPanelVisible`. Enabled state
    /// mirrors `isActiveTabConnected` (same as the Terminal entries).
    var toggleTransfers: (() -> Void)?
```

- [x] **Step 7: Menüeintrag + Kürzel.** In `Sources/MacSCPApp/MacSCPApp.swift`, im `CommandGroup(after: .sidebar)` (Zeilen 164–169) den neuen Eintrag NACH dem „Show/Hide Hidden Files"-Button einfügen:

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

- [x] **Step 8: Strings EN.** In `Sources/MacSCPApp/Resources/en.lproj/Localizable.strings` anfügen (bei den `transfers.*`/`browser.*`/`menu.*`-Blöcken oder am Ende):

```
"browser.transfersToggle" = "Transfers";
"browser.transfersToggleHelp" = "Show/hide transfers (⌘⇧Y)";
"menu.transfers.toggle" = "Show/Hide Transfers";
"transfers.empty" = "No transfers";
```

- [x] **Step 9: Strings DE.** In `Sources/MacSCPApp/Resources/de.lproj/Localizable.strings` anfügen (nur ASCII-`"` als Delimiter, keine im Wert; ⌘⇧Y wörtlich):

```
"browser.transfersToggle" = "Übertragungen";
"browser.transfersToggleHelp" = "Übertragungen ein-/ausblenden (⌘⇧Y)";
"menu.transfers.toggle" = "Übertragungen ein-/ausblenden";
"transfers.empty" = "Keine Übertragungen";
```

- [x] **Step 10: Katalog-Lint + Parität.**

```bash
plutil -lint Sources/MacSCPApp/Resources/en.lproj/Localizable.strings
plutil -lint Sources/MacSCPApp/Resources/de.lproj/Localizable.strings
```
Expected: beide „OK". Dann `swift test --filter Localizable` → PASS (EN/DE-Schlüssel-Parität).

- [x] **Step 11: Build + volle Suite.** `swift build`
Expected: `Build complete`, keine NEUEN Warnungen (die vier vorbestehenden Citadel/`_`-Warnungen bleiben). Dann `swift test`
Expected: **900 Tests / 62 Suiten** grün (unverändert — keine neue/geänderte Core-Logik).

- [x] **Step 12: Trace-Verifikation (kein App-Test-Target).** Lesen und bestätigen:
  - `TransferQueueBar` wird in `ContentView` nur bei `tab.transfersPanelVisible` gerendert; leer ⇒ Leerzustand „Keine Übertragungen", nicht leer ⇒ unveränderte Kopfzeile/Liste.
  - `.onChange(of: tab.transferQueue.items.count)` setzt bei Anstieg `transfersPanelVisible = true`; „Aufräumen"/Fertigstellen (fallende/gleiche Anzahl) blendet nie zwangsweise aus.
  - Toolbar-Button (nur bei aktiver Session, da in der gated Gruppe) und Menüeintrag (disabled ohne Verbindung) schalten dasselbe Pro-Tab-Bool; **⌘⇧Y liegt nur am Menüeintrag** (kein Doppel-Binding), das Toolbar-Icon ist ein reiner klickbarer Knopf mit Hilfetext.
  - `toggleTransfers` ist key-window-guarded wie die übrigen `tabCommands`.

- [x] **Step 13: Runtime-Idle-CPU-Rauchtest.** Dev-Build bauen und starten, Idle-CPU prüfen (muss ~0% sein — fängt SwiftUI-Layout-Stürme ab, die Build/Tests nicht sehen):

```bash
MACSCP_VERSION=1.2.0-dev MACSCP_BUILD=m11o scripts/package-app
codesign --force --deep --sign - dist/macSCP.app; xattr -cr dist/macSCP.app
open dist/macSCP.app; sleep 7
ps -o pid,%cpu,state -p "$(pgrep -f 'dist/macSCP.app/Contents/MacOS/macSCP' | head -1)"
pkill -f 'dist/macSCP.app/Contents/MacOS/macSCP'
```
Expected: `%CPU` nahe 0, Status `S`.

- [x] **Step 14: Commit.**

```bash
git add Sources/MacSCPApp/SessionTab.swift Sources/MacSCPApp/TransferQueueBar.swift \
        Sources/MacSCPApp/ContentView.swift Sources/MacSCPApp/MacSCPApp.swift \
        Sources/MacSCPApp/Resources/en.lproj/Localizable.strings \
        Sources/MacSCPApp/Resources/de.lproj/Localizable.strings
git commit -m "feat: toggle the transfer bar via a toolbar icon, menu and ⌘⇧Y"
```

---

### Task 2: Abschluss-Verifikation (Koordinator)

- [x] Gated Suiten: `MACSCP_ITEST=1 MACSCP_KEYCHAIN=1 swift test` → grün, zero skips (Docker-Rig aus dem Haupt-Checkout).
- [x] `swift build` sauber; `plutil -lint` beide Kataloge OK; `LocalizableStringsTests` grün.
- [x] Runtime-Idle-CPU-Rauchtest bestanden (Step 13).
- [x] Whole-Task Opus-Review (kleiner App-Diff): Fokus auf (a) Auto-Einblenden nur bei Anstieg, nie Zwangs-Ausblenden; (b) Pro-Tab-Bool, kein Singleton/keine Persistenz; (c) Toolbar-/Menü-/Kürzel-Verdrahtung + key-window-Guard; (d) Leerzustand vs. Liste; (e) L10n-Parität + kein ASCII-`"` in DE. Fix-Runden bis „Ready to merge: Yes".
- [ ] Visueller Smoke — Maintainer (Icon neben Terminal, ⌘⇧Y, Menüeintrag; Wegklappen während Transfer; leer öffnen + „Aufräumen"; neue Übertragung klappt auf; pro Tab getrennt; hell/dunkel; DE ↔ EN).
- [x] Plan-Checkboxen, Ledger, Push develop, `gh run watch`, Dev-Build deployen, Memory. **KEIN Release.** Kürzel ⌘⇧Y für die spätere Tastenkürzel-Übersicht vormerken.
