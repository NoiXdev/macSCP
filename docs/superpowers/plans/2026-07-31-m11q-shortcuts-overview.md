# M11q — Keyboard Shortcuts Overview Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A read-only "Keyboard Shortcuts" tab in Settings that lists all shortcuts grouped, fed from a hand-maintained `KeyboardShortcutsCatalog`.

**Architecture:** Pure App layer. A static `KeyboardShortcutsCatalog` (groups → rows; doc comment names the six definition sites it mirrors) is rendered by a new `ShortcutsSettingsTab` inside a `Form`. Labels via `L10n` (new `settings.shortcuts.*` keys in EN/DE/FR/PL); the shortcut glyphs are fixed, unlocalized display strings.

**Tech Stack:** SwiftUI, Swift 6 (`.swiftLanguageMode(.v5)`), macOS 15.

## Global Constraints

- Swift-tools 6.0, all targets `.swiftLanguageMode(.v5)`, min. macOS 15.
- Code/comments **English only**.
- UI strings via `Sources/MacSCPApp/Resources/{en,de,fr,pl}.lproj/Localizable.strings`, lookup `L10n.string(key, "English default")`.
- **No ASCII `"` in the value** of a non-English catalog (breaks the catalog; `plutil -lint` + `LocalizableStringsTests` guard this). Format placeholders don't occur here.
- Shortcut display strings are fixed and **not** localized.
- Read-only — no rebinding. No Core, no new logic.
- FR/PL new strings are AI-generated (consistent with M11p), to be reviewed by a native speaker before release.
- **M11n lesson:** check new GUI paths with a runtime idle-CPU smoke test before shipping.
- Conventional Commits; footer `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- Baseline: **903 tests / 62 suites** green. No release/tag without maintainer directive.

---

### Task 1: KeyboardShortcutsCatalog + ShortcutsSettingsTab + L10n

**Files:**
- Create: `Sources/MacSCPApp/KeyboardShortcutsCatalog.swift`
- Modify: `Sources/MacSCPApp/SettingsView.swift` (`ShortcutsSettingsTab` + tab in `TabView`)
- Modify: `Sources/MacSCPApp/Resources/{en,de,fr,pl}.lproj/Localizable.strings`

**Interfaces:**
- Consumes (existing, verified): `SettingsView.body`'s `TabView` (General/Transfers/Open with/Terminal, `.frame(width: 460, height: 460)`); tab pattern `SomeTab(...) .tabItem { Label(L10n.string("settings.tab.X", "…"), systemImage: "…") }`; `L10n.string`.
- Produces: `KeyboardShortcutsCatalog.groups: [Group]` with `Group{titleKey,titleDefault,rows:[Row{labelKey,labelDefault,shortcut}]}`.

- [x] **Step 1: Catalog file.** New file `Sources/MacSCPApp/KeyboardShortcutsCatalog.swift`:

```swift
import Foundation

/// Read-only overview of the app's keyboard shortcuts (M11q). This is a
/// HAND-MAINTAINED mirror — there is no central shortcut registry. The real
/// bindings live across six sites; when a shortcut changes at ANY of them,
/// update this catalog too:
///   1. SwiftUI `.keyboardShortcut` in `MacSCPApp.swift` menus (⌘N, ⌘W,
///      ⌘1–9, ⌘⇧., ⌘⇧Y, ⌘⇧K, ⌘⇧L, ⌘⇧I; ⌘, is the SwiftUI Settings default).
///   2. The ⌘T terminal toolbar button in `ContentView.swift`.
///   3. `KeyboardDrivenTableView` hardcoded keyCodes in
///      `RemoteFileTableView.swift`, resolved via `BrowserKeyCommand` (Core).
///   4. ⌘F / search-Esc wiring (`RemoteFileTableView.swift`,
///      `FileSearchBar.swift`).
///   5. Path-bar completion keys in `PathBar.swift` (⇥ / ⇧⇥ / ⎋ / ⏎).
///   6. Sheet `.keyboardShortcut(.defaultAction)` (⏎) and `role: .cancel` (⎋).
/// The `shortcut` strings are FIXED display glyphs and are NOT localized;
/// the labels are localized via `L10n`.
enum KeyboardShortcutsCatalog {
    struct Row: Identifiable {
        let id = UUID()
        let labelKey: String
        let labelDefault: String
        let shortcut: String
    }

    struct Group: Identifiable {
        let id = UUID()
        let titleKey: String
        let titleDefault: String
        let rows: [Row]
    }

    static let groups: [Group] = [
        Group(titleKey: "settings.shortcuts.group.tabs", titleDefault: "Tabs & Windows", rows: [
            Row(labelKey: "settings.shortcuts.label.newTab", labelDefault: "New Tab", shortcut: "⌘N"),
            Row(labelKey: "settings.shortcuts.label.closeTab", labelDefault: "Close Tab", shortcut: "⌘W"),
            Row(labelKey: "settings.shortcuts.label.selectTab", labelDefault: "Select Tab 1–9", shortcut: "⌘1–9"),
            Row(labelKey: "settings.shortcuts.label.settings", labelDefault: "Settings", shortcut: "⌘,"),
        ]),
        Group(titleKey: "settings.shortcuts.group.view", titleDefault: "View", rows: [
            Row(labelKey: "settings.shortcuts.label.hiddenFiles", labelDefault: "Show/Hide Hidden Files", shortcut: "⌘⇧."),
            Row(labelKey: "settings.shortcuts.label.transfers", labelDefault: "Show/Hide Transfers", shortcut: "⌘⇧Y"),
            Row(labelKey: "settings.shortcuts.label.terminal", labelDefault: "Show/Hide Terminal", shortcut: "⌘T"),
        ]),
        Group(titleKey: "settings.shortcuts.group.sessions", titleDefault: "Sessions", rows: [
            Row(labelKey: "settings.shortcuts.label.knownHosts", labelDefault: "Known Hosts", shortcut: "⌘⇧K"),
            Row(labelKey: "settings.shortcuts.label.logins", labelDefault: "Logins", shortcut: "⌘⇧L"),
            Row(labelKey: "settings.shortcuts.label.hiddenImports", labelDefault: "Hidden Imports", shortcut: "⌘⇧I"),
        ]),
        Group(titleKey: "settings.shortcuts.group.browser", titleDefault: "File browser", rows: [
            Row(labelKey: "settings.shortcuts.label.goUp", labelDefault: "Go to parent folder", shortcut: "⌘↑"),
            Row(labelKey: "settings.shortcuts.label.open", labelDefault: "Open", shortcut: "⌘↓ / ⌘O"),
            Row(labelKey: "settings.shortcuts.label.info", labelDefault: "Info & Permissions", shortcut: "⌘I"),
            Row(labelKey: "settings.shortcuts.label.delete", labelDefault: "Delete", shortcut: "⌘⌫"),
            Row(labelKey: "settings.shortcuts.label.transferItem", labelDefault: "Transfer to other pane", shortcut: "␣"),
            Row(labelKey: "settings.shortcuts.label.rename", labelDefault: "Rename", shortcut: "⏎"),
            Row(labelKey: "settings.shortcuts.label.clearSelection", labelDefault: "Clear selection", shortcut: "⎋"),
            Row(labelKey: "settings.shortcuts.label.search", labelDefault: "Search", shortcut: "⌘F"),
        ]),
        Group(titleKey: "settings.shortcuts.group.pathbar", titleDefault: "Path bar", rows: [
            Row(labelKey: "settings.shortcuts.label.complete", labelDefault: "Complete path", shortcut: "⇥"),
            Row(labelKey: "settings.shortcuts.label.cycleBack", labelDefault: "Previous candidate", shortcut: "⇧⇥"),
            Row(labelKey: "settings.shortcuts.label.cancel", labelDefault: "Cancel", shortcut: "⎋"),
            Row(labelKey: "settings.shortcuts.label.navigate", labelDefault: "Go to path", shortcut: "⏎"),
        ]),
        Group(titleKey: "settings.shortcuts.group.sheets", titleDefault: "Dialogs", rows: [
            Row(labelKey: "settings.shortcuts.label.confirm", labelDefault: "Confirm", shortcut: "⏎"),
            Row(labelKey: "settings.shortcuts.label.cancel", labelDefault: "Cancel", shortcut: "⎋"),
        ]),
    ]
}
```

- [x] **Step 2: ShortcutsSettingsTab + Tab.** In `Sources/MacSCPApp/SettingsView.swift`:
  - Add a private tab at the end of the file:

```swift
/// Read-only keyboard-shortcuts overview (M11q) — renders
/// `KeyboardShortcutsCatalog` as one grouped, non-interactive list.
private struct ShortcutsSettingsTab: View {
    var body: some View {
        Form {
            ForEach(KeyboardShortcutsCatalog.groups) { group in
                Section(L10n.string(group.titleKey, group.titleDefault)) {
                    ForEach(group.rows) { row in
                        HStack {
                            Text(L10n.string(row.labelKey, row.labelDefault))
                            Spacer()
                            Text(row.shortcut)
                                .font(.system(.body, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}
```

  - In the `TabView` (after the `TerminalSettingsTab` block, before the closing `}` of the `TabView`) insert the fifth tab:

```swift
            ShortcutsSettingsTab()
                .tabItem {
                    Label(
                        L10n.string("settings.tab.shortcuts", "Shortcuts"),
                        systemImage: "keyboard")
                }
```

- [x] **Step 3: Strings EN.** Append to `Sources/MacSCPApp/Resources/en.lproj/Localizable.strings`:

```
"settings.tab.shortcuts" = "Shortcuts";
"settings.shortcuts.group.tabs" = "Tabs & Windows";
"settings.shortcuts.group.view" = "View";
"settings.shortcuts.group.sessions" = "Sessions";
"settings.shortcuts.group.browser" = "File browser";
"settings.shortcuts.group.pathbar" = "Path bar";
"settings.shortcuts.group.sheets" = "Dialogs";
"settings.shortcuts.label.newTab" = "New Tab";
"settings.shortcuts.label.closeTab" = "Close Tab";
"settings.shortcuts.label.selectTab" = "Select Tab 1–9";
"settings.shortcuts.label.settings" = "Settings";
"settings.shortcuts.label.hiddenFiles" = "Show/Hide Hidden Files";
"settings.shortcuts.label.transfers" = "Show/Hide Transfers";
"settings.shortcuts.label.terminal" = "Show/Hide Terminal";
"settings.shortcuts.label.knownHosts" = "Known Hosts";
"settings.shortcuts.label.logins" = "Logins";
"settings.shortcuts.label.hiddenImports" = "Hidden Imports";
"settings.shortcuts.label.goUp" = "Go to parent folder";
"settings.shortcuts.label.open" = "Open";
"settings.shortcuts.label.info" = "Info & Permissions";
"settings.shortcuts.label.delete" = "Delete";
"settings.shortcuts.label.transferItem" = "Transfer to other pane";
"settings.shortcuts.label.rename" = "Rename";
"settings.shortcuts.label.clearSelection" = "Clear selection";
"settings.shortcuts.label.search" = "Search";
"settings.shortcuts.label.complete" = "Complete path";
"settings.shortcuts.label.cycleBack" = "Previous candidate";
"settings.shortcuts.label.cancel" = "Cancel";
"settings.shortcuts.label.navigate" = "Go to path";
"settings.shortcuts.label.confirm" = "Confirm";
```

- [x] **Step 4: Strings DE.** Append to `de.lproj/Localizable.strings` (no ASCII `"` in the value):

```
"settings.tab.shortcuts" = "Tastenkürzel";
"settings.shortcuts.group.tabs" = "Tabs & Fenster";
"settings.shortcuts.group.view" = "Ansicht";
"settings.shortcuts.group.sessions" = "Sitzungen";
"settings.shortcuts.group.browser" = "Dateibrowser";
"settings.shortcuts.group.pathbar" = "Pfadzeile";
"settings.shortcuts.group.sheets" = "Dialoge";
"settings.shortcuts.label.newTab" = "Neuer Tab";
"settings.shortcuts.label.closeTab" = "Tab schließen";
"settings.shortcuts.label.selectTab" = "Tab 1–9 wählen";
"settings.shortcuts.label.settings" = "Einstellungen";
"settings.shortcuts.label.hiddenFiles" = "Versteckte Dateien ein-/ausblenden";
"settings.shortcuts.label.transfers" = "Übertragungen ein-/ausblenden";
"settings.shortcuts.label.terminal" = "Terminal ein-/ausblenden";
"settings.shortcuts.label.knownHosts" = "Known Hosts";
"settings.shortcuts.label.logins" = "Logins";
"settings.shortcuts.label.hiddenImports" = "Versteckte Importe";
"settings.shortcuts.label.goUp" = "Zum übergeordneten Ordner";
"settings.shortcuts.label.open" = "Öffnen";
"settings.shortcuts.label.info" = "Infos & Rechte";
"settings.shortcuts.label.delete" = "Löschen";
"settings.shortcuts.label.transferItem" = "In das andere Pane übertragen";
"settings.shortcuts.label.rename" = "Umbenennen";
"settings.shortcuts.label.clearSelection" = "Auswahl aufheben";
"settings.shortcuts.label.search" = "Suchen";
"settings.shortcuts.label.complete" = "Pfad vervollständigen";
"settings.shortcuts.label.cycleBack" = "Vorheriger Vorschlag";
"settings.shortcuts.label.cancel" = "Abbrechen";
"settings.shortcuts.label.navigate" = "Zum Pfad";
"settings.shortcuts.label.confirm" = "Bestätigen";
```

- [x] **Step 5: Strings FR.** Append to `fr.lproj/Localizable.strings` (guillemets/no ASCII `"`; apostrophe `'` is allowed):

```
"settings.tab.shortcuts" = "Raccourcis";
"settings.shortcuts.group.tabs" = "Onglets et fenêtres";
"settings.shortcuts.group.view" = "Affichage";
"settings.shortcuts.group.sessions" = "Sessions";
"settings.shortcuts.group.browser" = "Explorateur de fichiers";
"settings.shortcuts.group.pathbar" = "Barre de chemin";
"settings.shortcuts.group.sheets" = "Boîtes de dialogue";
"settings.shortcuts.label.newTab" = "Nouvel onglet";
"settings.shortcuts.label.closeTab" = "Fermer l'onglet";
"settings.shortcuts.label.selectTab" = "Sélectionner l'onglet 1–9";
"settings.shortcuts.label.settings" = "Réglages";
"settings.shortcuts.label.hiddenFiles" = "Afficher/masquer les fichiers cachés";
"settings.shortcuts.label.transfers" = "Afficher/masquer les transferts";
"settings.shortcuts.label.terminal" = "Afficher/masquer le terminal";
"settings.shortcuts.label.knownHosts" = "Hôtes connus";
"settings.shortcuts.label.logins" = "Identifiants";
"settings.shortcuts.label.hiddenImports" = "Imports masqués";
"settings.shortcuts.label.goUp" = "Aller au dossier parent";
"settings.shortcuts.label.open" = "Ouvrir";
"settings.shortcuts.label.info" = "Infos et autorisations";
"settings.shortcuts.label.delete" = "Supprimer";
"settings.shortcuts.label.transferItem" = "Transférer vers l'autre volet";
"settings.shortcuts.label.rename" = "Renommer";
"settings.shortcuts.label.clearSelection" = "Effacer la sélection";
"settings.shortcuts.label.search" = "Rechercher";
"settings.shortcuts.label.complete" = "Compléter le chemin";
"settings.shortcuts.label.cycleBack" = "Proposition précédente";
"settings.shortcuts.label.cancel" = "Annuler";
"settings.shortcuts.label.navigate" = "Aller au chemin";
"settings.shortcuts.label.confirm" = "Confirmer";
```

- [x] **Step 6: Strings PL.** Append to `pl.lproj/Localizable.strings` (no ASCII `"`):

```
"settings.tab.shortcuts" = "Skróty klawiszowe";
"settings.shortcuts.group.tabs" = "Karty i okna";
"settings.shortcuts.group.view" = "Widok";
"settings.shortcuts.group.sessions" = "Sesje";
"settings.shortcuts.group.browser" = "Przeglądarka plików";
"settings.shortcuts.group.pathbar" = "Pasek ścieżki";
"settings.shortcuts.group.sheets" = "Okna dialogowe";
"settings.shortcuts.label.newTab" = "Nowa karta";
"settings.shortcuts.label.closeTab" = "Zamknij kartę";
"settings.shortcuts.label.selectTab" = "Wybierz kartę 1–9";
"settings.shortcuts.label.settings" = "Ustawienia";
"settings.shortcuts.label.hiddenFiles" = "Pokaż/ukryj ukryte pliki";
"settings.shortcuts.label.transfers" = "Pokaż/ukryj transfery";
"settings.shortcuts.label.terminal" = "Pokaż/ukryj terminal";
"settings.shortcuts.label.knownHosts" = "Znane hosty";
"settings.shortcuts.label.logins" = "Dane logowania";
"settings.shortcuts.label.hiddenImports" = "Ukryte importy";
"settings.shortcuts.label.goUp" = "Przejdź do folderu nadrzędnego";
"settings.shortcuts.label.open" = "Otwórz";
"settings.shortcuts.label.info" = "Informacje i uprawnienia";
"settings.shortcuts.label.delete" = "Usuń";
"settings.shortcuts.label.transferItem" = "Prześlij do drugiego panelu";
"settings.shortcuts.label.rename" = "Zmień nazwę";
"settings.shortcuts.label.clearSelection" = "Wyczyść zaznaczenie";
"settings.shortcuts.label.search" = "Szukaj";
"settings.shortcuts.label.complete" = "Uzupełnij ścieżkę";
"settings.shortcuts.label.cycleBack" = "Poprzednia propozycja";
"settings.shortcuts.label.cancel" = "Anuluj";
"settings.shortcuts.label.navigate" = "Przejdź do ścieżki";
"settings.shortcuts.label.confirm" = "Potwierdź";
```

  (Note: `settings.shortcuts.label.cancel` is used by two catalog rows — enter it only ONCE per language.)

- [x] **Step 7: Catalog lint + parity.**

```bash
for l in en de fr pl; do plutil -lint "Sources/MacSCPApp/Resources/$l.lproj/Localizable.strings"; done
swift test --filter Localizable
```
  Expected: all "OK"; `Localizable` suite PASS (the 30 new keys are in all four catalogs → parity holds).

- [x] **Step 8: Build + suite + runtime smoke test.**

```bash
swift build
swift test
MACSCP_VERSION=1.2.0-dev MACSCP_BUILD=m11q scripts/package-app
codesign --force --deep --sign - dist/macSCP.app; xattr -cr dist/macSCP.app
open dist/macSCP.app; sleep 7
ps -o pid,%cpu,state -p "$(pgrep -f 'dist/macSCP.app/Contents/MacOS/macSCP' | head -1)"
pkill -f 'dist/macSCP.app/Contents/MacOS/macSCP'
```
  Expected: `Build complete` (no new warnings); `swift test` **903** green (no new Core logic); app idle `%CPU` near 0, state `S`. On spin (>50%) STOP + BLOCKED.

- [x] **Step 9: Trace verification.** Confirm: every catalog row has a `labelKey` that exists in all four catalogs (covered by parity); every `shortcut` is non-empty; the tab is read-only (no bindings/buttons); the window height is sufficient (the `Form` scrolls otherwise — no clipping, just possible scrolling).

- [x] **Step 10: Commit.**

```bash
git add Sources/MacSCPApp/KeyboardShortcutsCatalog.swift Sources/MacSCPApp/SettingsView.swift Sources/MacSCPApp/Resources
git commit -m "feat: add a read-only keyboard shortcuts overview in Settings"
```

---

### Task 2: Final verification (coordinator)

- [x] Gated suites: `MACSCP_ITEST=1 MACSCP_KEYCHAIN=1 swift test` → green, zero skips.
- [x] `swift build` clean; `plutil -lint` all four catalogs OK; `LocalizableStringsTests` green (parity EN↔{DE,FR,PL}).
- [x] Runtime idle-CPU smoke test passed; Settings ▸ Shortcuts opens without spinning.
- [x] Whole-task Opus review (small App diff): focus on (a) catalog correctly mirrors the actual shortcuts (inventory check: no invented/wrong mappings, ⌘⇧Y/⌘T/⌘↑ etc. are correct); (b) all 30 new keys in all four catalogs, no ASCII `"` in non-EN; (c) tab read-only, no interaction/layout break; (d) `cancel` key only once per language. Fix rounds until "Ready to merge: Yes".
- [ ] Visual smoke — maintainer (tab "Shortcuts" appears; groups + rows readable; shortcuts right-aligned monospaced; DE/FR/PL labels correct; light/dark; window scrolls cleanly).
- [x] Plan checkboxes, ledger, push develop, `gh run watch`, deploy dev build, memory. **NO release** (FR/PL to be reviewed by a native speaker before release). Roadmap: rebinding remains its own future milestone.
