# P3d: Die Snippet-Auswahl im Terminal — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Das Snippet-Popover in der Terminal-Kopfzeile wird eine flache
Liste statt verschachtelter Untermenüs — mit Kontextmenü je Zeile,
Aktionsfenster beim Doppelklick und dem Befehl beim Überfahren.

**Architecture:** `SnippetMenuModel` (Core) bleibt die **eine** Quelle für
alle vier Auslöseflächen. Nur die **Darstellung** trennt sich: drei Flächen
sind echte `NSMenu`s und behalten `SnippetMenuItems`; das Popover bekommt
eine zweite Ansicht über dasselbe Modell.

**Tech Stack:** Swift 6, `.swiftLanguageMode(.v5)`, SwiftPM, macOS 15+,
SwiftUI, Swift Testing, zwei Testtargets.

Spec: `docs/superpowers/specs/2026-08-18-p3-ordnung-design.md`, Abschnitt P3d.

## Global Constraints

- **Code, Kommentare, Testnamen: Englisch.** Interne Doku (`docs/`) Deutsch.
- **Jeder neue L10n-Schlüssel in allen vier Katalogen** (en/de/fr/pl),
  identische Schlüsselmengen, `plutil -lint` sauber.
- **Nie eine Zeilennummer in einen Kommentar.**
- **Kein Secret in Log, Fehler oder Testfehlermeldung.**
- **Jede Tatsachenbehauptung dieses Plans ist am Code zu prüfen.** Im
  laufenden Meilenstein enthielten **vierzehn** meiner Aufgabenbeschreibungen
  einen sachlichen Fehler. Die unten zitierten Stellen sind am 2026-08-18
  gemessen; weicht etwas ab, ist **der Plan** falsch — melden, nicht anpassen.
- **Zwei Proben vor jedem Commit**, beide:
  1. Bliebe ein Test grün, wenn die Funktion konstant zurückgäbe?
  2. **Welche Behauptung meines Doc-Kommentars beobachtet kein Test?**
     Im laufenden Meilenstein waren **fünf** Doc-Kommentare schlicht falsch.
- **Die GUI wird nicht gestartet.** `scripts/package-app` erlaubt,
  `scripts/release` nicht.
- Conventional Commits, Englisch, Footer:
  `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`
- Volle Suite grün vor jedem Commit. Ausgangsstand: **2076 Tests in 178
  Suiten** — selbst nachmessen.

## Gemessener Ist-Zustand (2026-08-18)

**Vier Auslöseflächen rendern heute alle `SnippetMenuItems`:**

| Stelle | Art |
|---|---|
| `MacSCPApp.swift` (Menüzeile) | echtes Menü |
| `SSHTerminalView.swift` (`NSHostingMenu`, Rechtsklick im Terminal) | echtes Menü |
| `SessionSidebar.swift` (`.contextMenu` am Host) | echtes Menü |
| `ContentView+Detail.swift` (Popover der Kopfzeile) | **Liste in einem Panel** |

`SnippetMenuItems` rendert pro Snippet ein `Menu(entry.snippet.name)` mit
zwei Knöpfen; das Einfügen trägt bei den ersten Einträgen ⌃⌘n
(`SnippetMenuPlan.Entry.insertShortcutDigit`), das Ausführen **nie** — ein
Wächter (`SnippetMenuItemsKeyboardShortcutGuardTests`) hält das fest.

**Nur die vierte Stelle kann eine flache Liste werden.** Die drei Menüs
müssen Menüs bleiben. Prüfe das selbst, bevor du etwas umbaust.

---

### Task 1: Die Zeilen-Entscheidung als testbarer Typ (Core oder testbare App-Datei)

**Warum zuerst:** Was eine Zeile anbietet — ausführen, einfügen, beides
gesperrt — hängt am selben Modell wie die Menüs. Diese Entscheidung gehört
**nicht** in den View-Body. In P2 hat diese Form ein leeres Fenster erzeugt,
in P3a leere Gruppen verschwinden lassen.

**Files:**
- Create: eine Datei für die Projektion (Ort begründen: Core, wenn sie ohne
  SwiftUI auskommt; sonst eine testbare App-Datei neben `SnippetMenuPlan`)
- Create: die zugehörigen Tests

**Interfaces:**
- Consumes: `SnippetMenuModel` (Core), wie `SnippetMenuPlan` es tut
- Produces: eine flache Projektion — Abschnitte mit Tag-Überschrift (bzw.
  ohne für Ungetaggte) und Zeilen, jede mit Snippet, Anzeigename und der
  Angabe, ob ihre Aktionen verfügbar sind.

**Nimm `SnippetMenuPlan` als Vorbild** — es macht dieselbe Art Projektion für
die Menüs, inklusive der Regel, dass ein Snippet mit zwei Tags in **zwei**
Gruppen auftaucht. Entscheide bewusst, ob die flache Liste das genauso hält
oder jede Zeile nur einmal zeigt, und **begründe es im Bericht**: in einem
Menü ist Doppelung harmlos, in einer scrollbaren Liste ist sie verwirrend.

- [ ] **Schritt 1: Tests zuerst** — leeres Modell, ein Snippet ohne Tags,
      eines mit zwei Tags, ein gesperrtes (keine Shell / nicht verbunden).
- [ ] **Schritt 2: Rot laufen lassen.**
- [ ] **Schritt 3: Die Projektion.**
- [ ] **Schritt 4: Volle Suite + Commit**

```bash
swift test
git commit -m "feat(app): project the snippet model into a flat list"
```

---

### Task 2: Das Aktionsfenster

**Files:**
- Create: die Fenster-/Sheet-Ansicht
- Modify: die vier `Localizable.strings`
- Create/Modify: Tests für alles, was ohne Rendering prüfbar ist

**Was es zeigt:** den Namen, den **Befehl im Klartext**, und drei Aktionen.

**Die Kürzel sind entschieden und nicht zu verhandeln:**
- **Esc** bricht ab.
- **Return** liegt auf **„Einfügen"**.
- **⌘Return** führt aus.

Der Grund steht in der Spec: Return löst den Standardknopf aus, und auf
„Ausführen" wäre Doppelklick + Return zwei Anschläge bis zu einem Befehl auf
einem fremden Rechner. **Pinne die Zuordnung**, so wie
`SnippetMenuItemsKeyboardShortcutGuardTests` das Kürzel am Einfügen-Eintrag
pinnt — sonst verschiebt sie der nächste Umbau unbemerkt.

Neue Schlüssel (alle vier Kataloge):
- `snippets.action.title` — Fenstertitel
- `snippets.action.command` — Überschrift über dem Befehl
- `snippets.action.insert`, `snippets.action.execute`, `snippets.action.cancel`

- [ ] **Schritt 1: Kürzel-Zuordnung als Test.**
- [ ] **Schritt 2: Das Fenster.**
- [ ] **Schritt 3: Katalog-Nachweis + volle Suite + Commit**

```bash
for f in $(git ls-files '*.strings'); do plutil -lint "$f"; done
swift test
git commit -m "feat(app): offer insert, run and cancel in one window"
```

---

### Task 3: Das Popover auf die flache Liste

**Files:**
- Modify: `Sources/MacSCPAppKit/ContentView+Detail.swift`
- Modify: die vier `Localizable.strings`
- Create/Modify: Tests

**Was sich ändert — und was ausdrücklich nicht:**

- Das Popover rendert die Projektion aus Task 1 statt `SnippetMenuItems`.
- **Die drei Menü-Flächen bleiben unberührt.** Sie rendern weiter
  `SnippetMenuItems`. Fass sie nicht an.
- Suchfeld und Regex-Kästchen bleiben, wo sie sind.

**Die drei Wege:**
- **Rechtsklick auf eine Zeile** → Ausführen, Einfügen, Vorschau.
- **Doppelklick** → das Fenster aus Task 2.
- **Überfahren** → der Befehl als **feste Zeile unten im Popover**, nicht als
  Tooltip. Miss nach, ob das Popover dafür höher werden muss, und ob die
  Zeile bei sehr langen Befehlen kürzt oder umbricht — beides ist eine
  Entscheidung, keine Nebensache.
- **Einfacher Klick wählt nur aus** und löst nichts aus.

**„Vorschau" ist beim Bauen zu entscheiden:** dasselbe Fenster ohne
Aktionen, oder nur die Befehlszeile hervorheben. Sieh dir an, was mit dem
vorhandenen Fenster billiger und ehrlicher ist, und begründe die Wahl.

**⌃⌘n:** das Kürzel hängt heute an den Einfüge-Einträgen der **Menüs**. Das
Popover ist kein Menü. Prüfe, ob es dort überhaupt greifen kann, und wenn
nicht, sag es im Bericht, statt es stillschweigend zu verlieren.

- [ ] **Schritt 1: Das Popover umbauen.**
- [ ] **Schritt 2: Was ohne Rendering prüfbar ist, prüfen** — und im Bericht
      klar sagen, was nicht. Das Projekt hat sieben Quelltext-Wächter und
      eine Review nannte das Muster über seiner nützlichen Größe: einen
      achten nur mit Begründung.
- [ ] **Schritt 3: Katalog-Nachweis + volle Suite + Commit**

```bash
for f in $(git ls-files '*.strings'); do plutil -lint "$f"; done
swift test
git commit -m "feat(app): flatten the terminal snippet picker"
```

---

### Task 4: Phasenabschluss

**Files:**
- Create: `docs/superpowers/specs/2026-08-18-p3d-abschluss.md`

- [ ] **Schritt 1: Messen**

```bash
swift test 2>&1 | tail -3
for f in $(git ls-files '*.strings'); do plutil -lint "$f"; done
MACSCP_VERSION="1.2.0-dev" MACSCP_BUILD="$(git rev-list --count HEAD)" ./scripts/package-app
```

Build **im Hintergrund** starten; danach beide Binaries, beide
Ressourcen-Bundles, alle vier `.lproj`, `plutil -lint` auf die Info.plist,
alle drei `UTExportedTypeDeclarations`. **Die App wird nicht gestartet.**

- [ ] **Schritt 2: Bericht**

Er nennt die gemessenen Zahlen; **dass dies eine Bedienbarkeits-Änderung
ist und keine Sicherheitskorrektur** — die Auswahl hatte nie ein „ein Klick
führt aus"; wie sich Modell und Darstellung teilen und warum drei Flächen
Menüs bleiben; was mit ⌃⌘n geschah; und **ausdrücklich**, dass die GUI nicht
gestartet wurde — mit der Maintainer-Liste: das Popover ohne Untermenüs, das
Kontextmenü je Zeile, der Doppelklick samt Fenster, Esc/Return/⌘Return, die
Befehlszeile beim Überfahren, und dass Menüzeile und Rechtsklick im Terminal
unverändert funktionieren.

- [ ] **Schritt 3: Commit**

```bash
git commit -m "docs(app): record the snippet picker phase"
```

---

## Selbstreview dieses Plans

**Spec-Abdeckung:** flache Liste → Tasks 1 und 3. Kontextmenü je Zeile,
Doppelklick, Überfahren, einfacher Klick wählt nur → Task 3. Aktionsfenster
mit Esc/Return/⌘Return → Task 2. Die offenen Punkte der Spec (Vorschau,
Aufteilung der vier Flächen, ⌃⌘n) → in den Tasks als Entscheidungen mit
Begründungspflicht benannt, nicht offen gelassen.

**Platzhalter:** keine. Task 1 nennt bewusst keine fertige Typdefinition,
weil der Zuschnitt am gelesenen `SnippetMenuPlan` zu bestimmen ist.

**Typkonsistenz:** die Projektion aus Task 1 wird in Task 3 benutzt; ihr
Name ist dort frei, muss aber an beiden Stellen derselbe sein.
