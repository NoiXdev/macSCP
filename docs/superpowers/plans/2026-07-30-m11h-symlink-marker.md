# M11h — Symlinks kennzeichnen: Implementierungsplan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Symlinks sind in der Dateiliste an einem Symbol erkennbar, und ein Doppelklick auf einen Symlink, der auf ein Verzeichnis zeigt, öffnet es.

**Architecture:** Ein `NSImageView` im Namens-Zellenaufbau von `RemoteFileTableView`, sichtbar nur bei `kind == .symlink`; der Doppelklick-Handler bekommt einen dritten Fall, der denselben Weg nutzt wie die Pfadeingabe (`navigate(to:)` aus M11g).

**Tech Stack:** Swift 6 (`.swiftLanguageMode(.v5)`), SwiftUI + AppKit, Swift Testing.

**Spec:** `docs/superpowers/specs/2026-07-30-m11h-symlink-marker-design.md`

## Global Constraints

- Code und Kommentare **nur Englisch**; Anzeigetexte über die Kataloge
  (EN Default + DE), niemals hartkodiert. Deutsche Texte nur mit
  typografischen Anführungszeichen („…“) — ein ASCII-`"` macht die ganze
  deutsche Datei ungültig (M11d-Blocker).
- **Zeilenhöhe und Textposition der Liste ändern sich NICHT.** M5g hat
  beide gegen ein eingefrorenes Mockup abgeglichen; eine Verschiebung wäre
  eine stille Design-Regression.
- Nur `.symlink` bekommt ein Symbol. `.file`, `.directory`, `.other` sehen
  aus wie heute — kein Symbol, kein Platzhalter, keine Einrückung.
- Symlinks bekommen **kein** angehängtes `/`, auch wenn sie auf ein
  Verzeichnis zeigen: ohne `stat` pro Eintrag ist das nicht feststellbar.
- Kein zusätzliches `stat`/`readlink` pro Listeneintrag.
- Kein Audit-Eintrag.
- Tests: Swift Testing, TDD rot→grün. Baseline vor T1: **775 Tests / 55 Suiten**.
- Kein Release, kein Merge auf `main`, kein Tag.

---

### Task 1: Symbol, Doppelklick, Tooltip (App + Core-Kleinigkeit)

**Files:**
- Modify: `Sources/MacSCPApp/RemoteFileTableView.swift` (Namens-Zelle + `doubleClicked`), `Sources/MacSCPApp/BrowserPane.swift` (Weiterleitung, falls nötig), `Sources/MacSCPApp/Resources/{en,de}.lproj/Localizable.strings`
- Modify (nur falls der Test es verlangt): `Sources/macSCPCore/Presentation/FileListFormatter.swift`
- Test: `Tests/macSCPCoreTests/FileListFormatterTests.swift`, `Tests/macSCPCoreTests/BrowserContextMenuTests.swift` (pinnen)

**Interfaces:**
- Consumes: `RemoteFileItem.kind` (`.file`/`.directory`/`.symlink`/`.other`), `RemoteBrowserViewModel.navigate(to:) async -> String?` (M11g), `DesignTokens.inkTertiaryNS`, das bestehende `onOpen`/`onOpenFile`-Muster.
- Produces: nichts für spätere Tasks.

- [ ] **Step 1: Failing test — kein `/` für Symlinks.**
  In `FileListFormatterTests` (oder wo `displayName` heute getestet wird):
  ein Eintrag mit `kind == .symlink` und Namen `current` muss als `current`
  formatiert werden, NICHT als `current/`. Dazu zwei Regressionsfälle:
  ein Verzeichnis behält sein `/`, eine Datei bekommt keins.
  Prüfe zuerst, ob `displayName` heute schon so arbeitet — es liest
  `item.isDirectory`, und `isDirectory` ist `kind == .directory`, also
  ist das Verhalten vermutlich bereits richtig. **Ist der Test sofort grün,
  dann sage das im Report und lasse ihn als Regressionswächter stehen** —
  keine Änderung an `FileListFormatter` erfinden, nur um etwas zu ändern.

- [ ] **Step 2: Kontextmenü-Verhalten pinnen.**
  In `BrowserContextMenuTests` sicherstellen, dass für einen Symlink
  weiterhin KEIN Übertragen-, Editor- und Rechte-Eintrag erscheint (M7b-
  Regel). Falls es diesen Test schon gibt, nichts doppeln — nur prüfen und
  im Report festhalten.

- [ ] **Step 3: Symbol in der Namensspalte.**
  In `tableView(_:viewFor:row:)` erhält der `"name"`-Zellaufbau neben dem
  bestehenden `NSTextField` ein `NSImageView` mit
  `NSImage(systemSymbolName: "arrow.up.forward", accessibilityDescription:)`,
  `contentTintColor` = `DesignTokens.inkTertiaryNS`, Symbolgröße passend zu
  12,5 pt Text.

  Layout: das Symbol sitzt im vorhandenen linken Innenabstand, das
  Textfeld bleibt bei **12 pt** Einzug. Das heißt: das Symbol wird links
  neben dem Text platziert, ohne den Text zu verschieben, und die
  Zeilenhöhe bleibt unverändert. Prüfe die bestehenden Constraints, bevor
  du neue hinzufügst — es gibt bereits `leadingAnchor +12`,
  `trailingAnchor -12`, `centerYAnchor`.

  **Recycling-Hygiene (kritisch):** Zellen kommen aus
  `makeView(withIdentifier:)`. Das Symbol muss bei JEDER Zuweisung
  explizit ein- oder ausgeblendet werden (`isHidden`), sonst erscheint es
  auf einer falschen Zeile, sobald gescrollt wird. Der bestehende Code
  setzt `stringValue` und Font/Color unbedingt bei jeder Wiederverwendung —
  folge genau diesem Muster.

- [ ] **Step 4: Tooltip.**
  Die Namens-Zelle einer Symlink-Zeile bekommt einen `toolTip` mit einem
  lokalisierten Text („Symbolic link" / „Symbolischer Link"), der
  gleichzeitig die Accessibility-Beschreibung des Symbols ist. Andere
  Zeilen bekommen `toolTip = nil` (Recycling!).

- [ ] **Step 5: Doppelklick.**
  `doubleClicked(_:)` bekommt einen dritten Zweig: bei `kind == .symlink`
  wird der Pfad des Eintrags an einen neuen Closure-Parameter gegeben
  (Muster wie `onOpenFile`), den `BrowserPane`/`ContentView` an
  `viewModel.navigate(to: item.path)` weiterreichen. Gelingt es, wechselt
  das Pane hinein — mit dem **Symlink-Pfad**, nicht dem aufgelösten Ziel
  (`navigate(to:)` verhält sich schon so, und ein aufgelöster Pfad würde
  `goUp()` an eine Stelle führen, von der der Benutzer nie gekommen ist).
  Schlägt es fehl, wird die Meldung aus `navigate(to:)` angezeigt — nutze
  die Stelle, an der das Pane schon Fehler zeigt, statt eine neue zu
  erfinden. `.other` bleibt No-op.

- [ ] **Step 6: EN/DE.**
  Neue Keys in BEIDE App-Kataloge, Englisch zuerst. `plutil -lint` auf
  alle vier Kataloge OK, `LocalizableStringsTests` grün.

- [ ] **Step 7: Verifikation.**
  `swift build` aus einem SAUBEREN Build-Verzeichnis (ein inkrementeller
  Lauf zeigt keine Warnungen, weil nichts neu übersetzt wird — nur der
  saubere Lauf ist eine ehrliche Aussage): keine NEUEN Warnungen; die vier
  vorbestehenden sind erwartet (`BrowserPane` redundantes `_`,
  `TransferEngine:137`, zwei Citadel-Sendable). Volle `swift test`.

- [ ] **Step 8: Commit.** `feat: mark symlinks in the file list and follow them on double-click`

---

### Task 2: „Jetzt prüfen" in den Einstellungen (App)

Maintainer-Wunsch 2026-07-30: „in den einstellungen gerne auch noch einen
check for updates einbauen". Die Update-Prüfung existiert seit M11b — der
Schalter „Automatisch nach Updates suchen" steht im Tab **Allgemein**, die
manuelle Prüfung im Menü **macSCP ▸ Nach Updates suchen…**. Was in den
Einstellungen fehlt, ist der sofortige Weg samt Zustandsanzeige.

**Files:**
- Modify: `Sources/MacSCPApp/SettingsView.swift` (Abschnitt Update-Prüfung im Tab „Allgemein"), `Sources/MacSCPApp/Resources/{en,de}.lproj/Localizable.strings`
- Ggf. modify: `Sources/macSCPCore/Settings/SettingsStore.swift` (nur falls der Zeitstempel noch nicht lesbar ist), `Sources/MacSCPApp/UpdateCheckModel.swift`

**Interfaces:**
- Consumes: `UpdateCheckModel` (M11b, treibt schon die manuelle Prüfung aus dem Menü), `SettingsStore.updateCheckEnabled` und den dort bereits gespeicherten Zeitstempel der letzten Prüfung, `AppVersion`.

- [ ] **Step 1: Bestand lesen, nicht neu bauen.** `UpdateCheckModel` und
  der Menüeintrag machen die Arbeit bereits. Finde heraus, wie der
  Menüeintrag die Prüfung auslöst und wie das Ergebnis dargestellt wird,
  und benutze exakt denselben Weg — kein zweiter Prüfpfad, keine zweite
  Ergebnisdarstellung. Halte im Report fest, welchen Weg du gefunden hast.

- [ ] **Step 2: Der Abschnitt.** Unter dem bestehenden Schalter im Tab
  „Allgemein":
  - die laufende Version (aus dem Bundle, wie „Über macSCP" sie liest),
  - der Zeitpunkt der letzten Prüfung, oder ein Satz, dass noch nie geprüft
    wurde,
  - ein Knopf „Jetzt prüfen" im `PolishedButtonStyle`, deaktiviert während
    eine Prüfung läuft.
  Der bestehende Schalter und sein Fußtext bleiben unverändert — der Text
  über „höchstens einmal täglich, keine Daten über dich" ist eine Zusage,
  die dieser Task nicht aufweichen darf.

- [ ] **Step 3: Ergebnis ehrlich.** Erfolg ohne Fund, Erfolg mit Fund
  (Version + Link, wie das Menü es zeigt) und Fehlschlag (kein Netz,
  Rate-Limit) sind drei unterschiedliche Zustände mit je eigenem Text.
  Kein stilles Nichts nach einem Klick.

- [ ] **Step 4: EN/DE + Verifikation.** Neue Keys in BEIDE Kataloge,
  `plutil -lint` OK, `LocalizableStringsTests` grün, `swift build` aus
  einem sauberen Build-Verzeichnis ohne neue Warnungen, volle `swift test`.
  **Kein Test darf das Netz benutzen** — M11b erzwingt das bereits mit
  einem lauten Stub-Fehlschlag; wenn du Tests ergänzt, halte dich daran.

- [ ] **Step 5: Commit.** `feat: check for updates from the settings window`

---

### Task 3: Abschluss-Verifikation (Koordinator)

- [ ] Gated Suiten am finalen Stand: `MACSCP_ITEST=1 MACSCP_KEYCHAIN=1 swift test` → alle grün, zero skips. Dazu ein gated Rig-Test: ein Symlink auf ein Verzeichnis und einer auf eine Datei, über `navigate(to:)` — der erste gelingt, der zweite liefert die Meldung.
- [ ] Visueller Smoke — an den Maintainer delegiert (Checkliste: das Symbol erscheint NUR bei Symlinks; Zeilenhöhe und Textkante sehen aus wie vorher; beim Scrollen durch eine lange Liste wandert kein Symbol auf eine falsche Zeile; Tooltip erscheint; Doppelklick auf einen Ordner-Symlink öffnet ihn und die Pfadzeile zeigt den Symlink-Pfad; Doppelklick auf einen Datei-Symlink zeigt eine Meldung statt nichts zu tun; hell und dunkel).
- [ ] Plan-Checkboxen, Ledger, Opus-Final-Review, Fix-Runden bis „Yes", Push develop, `gh run watch`, Memory. KEIN Release.
