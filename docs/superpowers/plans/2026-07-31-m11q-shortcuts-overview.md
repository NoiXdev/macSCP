# M11q — Tastenkürzel-Übersicht Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ein read-only „Tastenkürzel"-Tab in den Einstellungen, der alle Kürzel gruppiert auflistet, gespeist aus einem hand-gepflegten `KeyboardShortcutsCatalog`.

**Architecture:** Rein App-Schicht. Ein statischer `KeyboardShortcutsCatalog` (Gruppen → Zeilen; Doc-Kommentar nennt die sechs Definitions-Stellen, die er spiegelt) wird von einem neuen `ShortcutsSettingsTab` in einem `Form` gerendert. Labels via `L10n` (neue `settings.shortcuts.*`-Keys in EN/DE/FR/PL); die Kürzel-Symbole sind feste, unlokalisierte Anzeigestrings.

**Tech Stack:** SwiftUI, Swift 6 (`.swiftLanguageMode(.v5)`), macOS 15.

## Global Constraints

- Swift-tools 6.0, alle Targets `.swiftLanguageMode(.v5)`, min. macOS 15.
- Code/Kommentare **English only**.
- UI-Strings über `Sources/MacSCPApp/Resources/{en,de,fr,pl}.lproj/Localizable.strings`, Lookup `L10n.string(key, "English default")`.
- **Kein ASCII-`"` im Wert** eines nicht-englischen Katalogs (bricht den Katalog; `plutil -lint` + `LocalizableStringsTests` bewachen das). Format-Platzhalter kommen hier nicht vor.
- Kürzel-Anzeigestrings sind fest und **nicht** lokalisiert.
- Read-only — kein Umbelegen. Kein Core, keine neue Logik.
- FR/PL neue Strings sind KI-generiert (konsistent mit M11p), vor Release muttersprachlich zu prüfen.
- **M11n-Lektion:** neue GUI-Wege vor Auslieferung per Runtime-Idle-CPU-Rauchtest prüfen.
- Conventional Commits; Footer `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- Baseline: **903 Tests / 62 Suiten** grün. Kein Release/Tag ohne Maintainer-Anordnung.

---

### Task 1: KeyboardShortcutsCatalog + ShortcutsSettingsTab + L10n

**Files:**
- Create: `Sources/MacSCPApp/KeyboardShortcutsCatalog.swift`
- Modify: `Sources/MacSCPApp/SettingsView.swift` (`ShortcutsSettingsTab` + Tab im `TabView`)
- Modify: `Sources/MacSCPApp/Resources/{en,de,fr,pl}.lproj/Localizable.strings`

**Interfaces:**
- Consumes (bestehend, verifiziert): `SettingsView.body`s `TabView` (General/Transfers/Open with/Terminal, `.frame(width: 460, height: 460)`); Tab-Muster `SomeTab(...) .tabItem { Label(L10n.string("settings.tab.X", "…"), systemImage: "…") }`; `L10n.string`.
- Produces: `KeyboardShortcutsCatalog.groups: [Group]` mit `Group{titleKey,titleDefault,rows:[Row{labelKey,labelDefault,shortcut}]}`.

- [x] **Step 1: Katalog-Datei.** Neue Datei `Sources/MacSCPApp/KeyboardShortcutsCatalog.swift`:

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
  - Am Dateiende einen privaten Tab hinzufügen:

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

  - Im `TabView` (nach dem `TerminalSettingsTab`-Block, vor der schließenden `}` des `TabView`) den fünften Tab einfügen:

```swift
            ShortcutsSettingsTab()
                .tabItem {
                    Label(
                        L10n.string("settings.tab.shortcuts", "Shortcuts"),
                        systemImage: "keyboard")
                }
```

- [x] **Step 3: Strings EN.** In `Sources/MacSCPApp/Resources/en.lproj/Localizable.strings` anfügen:

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

- [x] **Step 4: Strings DE.** In `de.lproj/Localizable.strings` anfügen (kein ASCII-`"` im Wert):

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

- [x] **Step 5: Strings FR.** In `fr.lproj/Localizable.strings` anfügen (Guillemets/kein ASCII-`"`; Apostroph `'` ist erlaubt):

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

- [x] **Step 6: Strings PL.** In `pl.lproj/Localizable.strings` anfügen (kein ASCII-`"`):

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

  (Hinweis: `settings.shortcuts.label.cancel` wird von zwei Katalog-Zeilen genutzt — nur EINMAL je Sprache eintragen.)

- [x] **Step 7: Katalog-Lint + Parität.**

```bash
for l in en de fr pl; do plutil -lint "Sources/MacSCPApp/Resources/$l.lproj/Localizable.strings"; done
swift test --filter Localizable
```
  Expected: alle „OK"; `Localizable`-Suite PASS (die 30 neuen Keys sind in allen vier Katalogen → Parität bleibt).

- [x] **Step 8: Build + Suite + Runtime-Rauchtest.**

```bash
swift build
swift test
MACSCP_VERSION=1.2.0-dev MACSCP_BUILD=m11q scripts/package-app
codesign --force --deep --sign - dist/macSCP.app; xattr -cr dist/macSCP.app
open dist/macSCP.app; sleep 7
ps -o pid,%cpu,state -p "$(pgrep -f 'dist/macSCP.app/Contents/MacOS/macSCP' | head -1)"
pkill -f 'dist/macSCP.app/Contents/MacOS/macSCP'
```
  Expected: `Build complete` (keine neuen Warnungen); `swift test` **903** grün (keine neue Core-Logik); App idle `%CPU` nahe 0, state `S`. Bei Spin (>50%) STOP + BLOCKED.

- [x] **Step 9: Trace-Verifikation.** Bestätigen: jede Katalog-Zeile hat einen `labelKey`, der in allen vier Katalogen existiert (durch Parität abgedeckt); jeder `shortcut` ist nicht leer; der Tab ist read-only (keine Bindings/Buttons); die Fensterhöhe reicht (das `Form` scrollt sonst — kein Abschneiden, nur ggf. Scrollen).

- [x] **Step 10: Commit.**

```bash
git add Sources/MacSCPApp/KeyboardShortcutsCatalog.swift Sources/MacSCPApp/SettingsView.swift Sources/MacSCPApp/Resources
git commit -m "feat: add a read-only keyboard shortcuts overview in Settings"
```

---

### Task 2: Abschluss-Verifikation (Koordinator)

- [x] Gated Suiten: `MACSCP_ITEST=1 MACSCP_KEYCHAIN=1 swift test` → grün, zero skips.
- [x] `swift build` sauber; `plutil -lint` alle vier Kataloge OK; `LocalizableStringsTests` grün (Parität EN↔{DE,FR,PL}).
- [x] Runtime-Idle-CPU-Rauchtest bestanden; Einstellungen ▸ Tastenkürzel öffnet ohne Spin.
- [x] Whole-Task Opus-Review (kleiner App-Diff): Fokus auf (a) Katalog spiegelt die tatsächlichen Kürzel korrekt (Inventur-Abgleich: keine erfundenen/falschen Zuordnungen, ⌘⇧Y/⌘T/⌘↑ etc. stimmen); (b) alle 30 neuen Keys in allen vier Katalogen, kein ASCII-`"` in Nicht-EN; (c) Tab read-only, kein Interaktions-/Layout-Bruch; (d) `cancel`-Key nur einmal je Sprache. Fix-Runden bis „Ready to merge: Yes".
- [ ] Visueller Smoke — Maintainer (Tab „Tastenkürzel" erscheint; Gruppen + Zeilen lesbar; Kürzel rechtsbündig monospaced; DE/FR/PL Labels korrekt; hell/dunkel; Fenster scrollt sauber).
- [x] Plan-Checkboxen, Ledger, Push develop, `gh run watch`, Dev-Build deployen, Memory. **KEIN Release** (FR/PL vor Release muttersprachlich prüfen). Roadmap: Umbelegung bleibt eigener späterer Meilenstein.
