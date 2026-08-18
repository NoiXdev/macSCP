# P2: Terminal-Fassung — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Das Terminal bekommt den Rand, den der Rest der App schon
benutzt, und beide Fensterhälften — Dateien und Terminal — werden in der
Toolbar unabhängig schaltbar, mit einem Zustand, der die Sitzung überlebt.

**Architecture:** Die Entscheidung, welche Hälften sichtbar sind und
welcher Schalter gesperrt ist, liegt als testbarer Typ in Core; die Toolbar
und das Layout lesen daraus. Der Zustand wandert als optionales Feld an
`StoredSession` — neben `groupID`, nicht in den Backend-Feldbeutel, weil er
keine Verbindungseigenschaft ist.

**Tech Stack:** Swift 6, `.swiftLanguageMode(.v5)`, SwiftPM, macOS 15+,
SwiftUI, Swift Testing, zwei Testtargets.

## Global Constraints

- **Code, Kommentare, Testnamen: Englisch.** Interne Doku (`docs/`) Deutsch.
- **Jeder neue L10n-Schlüssel in allen vier Katalogen** (en/de/fr/pl),
  identische Schlüsselmengen; Nachweis per Wächtertest und
  `for f in $(git ls-files '*.strings'); do plutil -lint "$f"; done`.
- **Nie eine Zeilennummer in einen Kommentar.**
- **Kein Secret in Log, Fehler oder Testfehlermeldung.**
- **Die Prosa dieses Plans ist eine zu prüfende Behauptung.** In der
  Vorphase steckte in fünf von elf Tasks ein echter Fehler im Brief.
- **Zwei Proben vor jedem Commit**, nicht eine:
  1. Bliebe ein Test grün, wenn die Funktion konstant zurückgäbe?
  2. **Welche Behauptung meines Doc-Kommentars beobachtet kein Test?**
     Die zweite hat in P1 sieben echte Lücken gefunden, die erste keine
     davon.
- **Die GUI wird nicht gestartet.** `scripts/package-app` ist erlaubt.
- Conventional Commits, Englisch, Footer:
  `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`
- Volle Suite grün vor jedem Commit. Ausgangsstand: **1881 Tests in 159
  Suiten** — neu messen, nie abschreiben.

---

### Task 1: Der Rand — ein Wert, zwei Leser

**Gemessener Ist-Zustand:** `SSHTerminalView` bekommt in `terminalPanel`
**gar keinen** Rand und sitzt bündig an der Kante. Der `.ended`-Textblock im
selben Panel benutzt `.padding(.vertical, 8).padding(.horizontal, 14)`. Die
in P1 gebaute `TerminalPanelHeader` benutzt `12/6`.

**Files:**
- Modify: `Sources/MacSCPAppKit/DesignTokens.swift`
- Modify: `Sources/MacSCPAppKit/ContentView+Detail.swift`
- Create: `Tests/macSCPAppKitTests/TerminalPanelInsetTests.swift`

- [ ] **Schritt 1: Nachmessen, nicht glauben**

Prüfe die drei Werte oben selbst am Code. Weicht einer ab, ist **der Plan**
falsch — melden, nicht anpassen.

- [ ] **Schritt 2: Den Wert benennen**

Ein Paar benannter Konstanten in `DesignTokens` (die Datei hält heute nur
Farben — der Doc-Kommentar muss also sagen, warum jetzt auch ein Maß darin
steht: weil zwei Views sich darauf einigen müssen).

- [ ] **Schritt 3: Den Test, der etwas wert ist**

Ein Test auf „die Zahl ist 14" prüft nur, dass jemand 14 getippt hat. Der
Test, der trägt, ist die **Kopplung**: Kopfzeile und Terminalfläche lesen
denselben Wert. Schreibe ihn so, dass er rot wird, wenn eine der beiden
Stellen wieder eine eigene Zahl bekommt.

Geht das nicht ohne View-Instanziierung: sag das, und pinne stattdessen
das, was geht — z. B. dass es genau **eine** Quelle gibt (Wächtertest über
den Quelltext, wie der Kürzel-Wächter aus P1).

- [ ] **Schritt 4: Anwenden**

Terminalfläche und Kopfzeile lesen die Konstanten. **Der `.ended`-Block
bleibt, wie er ist** — er hat die Werte schon; wenn du ihn umstellst, dann
nur auf dieselbe Konstante, ohne die Zahl zu ändern.

- [ ] **Schritt 5: Volle Suite, Commit**

```bash
swift test
git commit -m "feat(app): give the terminal the inset the rest of the panel already uses"
```

---

### Task 2: `PaneVisibility` (Core) — die Entscheidung

**Files:**
- Create: `Sources/macSCPCore/Presentation/PaneVisibility.swift`
- Create: `Tests/macSCPCoreTests/PaneVisibilityTests.swift`

**Interfaces:**
```swift
public struct PaneVisibility: Equatable, Sendable, Codable {
    public var showsFiles: Bool
    public var showsTerminal: Bool
}
public enum PaneToggle: Equatable, Sendable { case files, terminal }
public struct PaneToggleState: Equatable, Sendable {
    public let isOn: Bool
    public let isEnabled: Bool
}
```
plus eine Funktion, die aus `PaneVisibility` **und** der Frage, ob das
Backend eine Shell hat, für jeden der beiden Schalter einen
`PaneToggleState` liefert, und eine, die einen Klick anwendet.

- [ ] **Schritt 1: Die fehlschlagenden Tests**

```swift
/// Both halves visible is the ordinary state, and both toggles are live.
@Test func withBothVisibleEitherCanBeTurnedOff() { … }

/// The last visible half cannot be turned off — the window would be empty.
/// The toggle is disabled rather than silently doing nothing, so the user
/// can see why the click does not land.
@Test func theLastVisibleHalfIsLocked() { … }

/// A backend without a shell has no terminal to show. Files is then the
/// only half, and therefore locked — the same rule as above, reached by a
/// different road.
@Test func withoutAShellFilesIsTheOnlyHalfAndIsLocked() { … }

/// Turning a half back on unlocks the other one again — the lock is a
/// consequence of the state, never a latch that stays set.
@Test func turningTheOtherHalfBackOnUnlocksBoth() { … }

/// A stored state that says "no halves visible" cannot be trusted — a
/// hand-edited sessions.json could carry it, and it would render an empty
/// window. Decoding repairs it rather than propagating it.
@Test func aStoredStateWithNothingVisibleIsRepaired() { … }
```

Der letzte ist der wichtige: dieselbe Bauart wie die Zeilenumbruch-Regel
am `Snippet` — **die Reparatur gehört ins Modell**, nicht in die View, weil
eine von Hand bearbeitete Datei sonst daran vorbeikommt.

- [ ] **Schritt 2: Rot, implementieren, grün**

- [ ] **Schritt 3: Beide Proben, dann Commit**

Beantworte im Bericht: welcher Test wird rot, wenn `isEnabled` konstant
`true` ist? Und: welche Behauptung deiner Doc-Kommentare beobachtet kein
Test?

```bash
git commit -m "feat(core): decide pane visibility and which toggle is locked"
```

---

### Task 3: Die Toolbar und das Layout

**Files:**
- Modify: `Sources/MacSCPAppKit/ContentView+Lifecycle.swift` (Toolbar)
- Modify: `Sources/MacSCPAppKit/ContentView+Detail.swift` (`detail`)
- Modify: `Sources/MacSCPAppKit/SessionTab.swift` (Zustand am Tab)
- Modify: die vier Kataloge

**Gemessener Ist-Zustand:** In der Toolbar sitzen zwei Schalter — „Terminal"
(⌘T, deaktiviert bei `!activeTabSupportsShell`) und „Übertragungen". In
`detail` steht ein `VSplitView` mit einem `HSplitView` aus zwei
`BrowserPane` und darunter `if session.terminal.isVisible { terminalPanel(session) }`.

- [ ] **Schritt 1: Nachmessen**

- [ ] **Schritt 2: Der zweite Schalter**

„Dateien" neben „Terminal", beide lesen ihren `PaneToggleState` aus Task 2.
**Kein neues Tastenkürzel** — ⌘T bleibt beim Terminal, „Dateien" bekommt
keins, solange niemand eines verlangt.

- [ ] **Schritt 3: Das Layout**

Der `HSplitView` mit den zwei Panes wird an `showsFiles` gehängt, wie das
Terminal schon an seiner Sichtbarkeit hängt. **Die vorhandene
Terminal-Sichtbarkeit ist die Quelle für `showsTerminal`** — baue keinen
zweiten Zustand daneben, der damit auseinanderlaufen kann. Wenn sich das
nicht sauber zusammenführen lässt, ist das ein Befund: melden.

- [ ] **Schritt 4: Suite, Kataloge, Commit**

```bash
git commit -m "feat(app): switch both window halves from the toolbar"
```

---

### Task 4: Der Zustand überlebt die Sitzung

**Files:**
- Modify: `Sources/macSCPCore/Sessions/StoredSession.swift`
- Modify: den Session-Export/-Import-Pfad
- Modify/Create: die zugehörigen Tests

**Gemessener Ist-Zustand:** `StoredSession.init(from:)` benutzt für alle
optionalen Felder `decodeIfPresent` — ein neues optionales Feld ist damit
migrationsfrei. `groupID` ist der Präzedenzfall für ein Feld, das zur
Sitzung gehört, aber **keine Verbindungseigenschaft** ist. Die
Panes-Sichtbarkeit gehört in dieselbe Kategorie, **nicht** in den
Backend-Feldbeutel (`FieldValues`, keyed `"<namespace>.<fieldID>"`), der
Schema-Felder eines Protokolls trägt.

- [ ] **Schritt 1: Dem Präzedenzfall folgen, nicht raten**

Sieh nach, was der Export/Import mit `groupID` macht — ob es mitgeführt,
weggelassen oder umgeschrieben wird — und **mach es genauso**. Schreib in
den Bericht, was du vorgefunden hast. Falls `groupID` beim Export
absichtlich fällt (etwa weil Gruppen zielseitig neu aufgelöst werden), dann
gilt dieselbe Absicht hier, und das ist dann die Antwort — kein Grund, für
die Sichtbarkeit eine Extrawurst zu bauen.

- [ ] **Schritt 2: Das Feld**

Optional, `decodeIfPresent` mit einem Standard, der „beide sichtbar"
bedeutet — eine Datei ohne das Feld verhält sich exakt wie heute.

- [ ] **Schritt 3: Die Tests**

- Eine `sessions.json` **ohne** das Feld lädt und ergibt „beide sichtbar".
  Gegen eine wörtliche Alt-Datei, nicht gegen etwas neu Kodiertes.
- Ein Export-Roundtrip führt den Wert mit (oder lässt ihn bewusst fallen —
  je nachdem, was Schritt 1 ergeben hat; pinne, was gilt).
- Eine Datei, die „nichts sichtbar" behauptet, wird repariert (Task 2s
  Regel greift auch hier — prüfe, dass sie es tut, statt es anzunehmen).

- [ ] **Schritt 4: Suite, Commit**

```bash
git commit -m "feat(core): remember which window halves a saved session shows"
```

---

### Task 5: Phasenabschluss

**Files:**
- Create: `docs/superpowers/specs/2026-08-12-p2-abschluss.md`

- [ ] **Schritt 1: Messen**

```bash
swift test 2>&1 | tail -3
for f in $(git ls-files '*.strings'); do plutil -lint "$f"; done
MACSCP_VERSION="1.2.0-dev" MACSCP_BUILD="$(git rev-list --count HEAD)" ./scripts/package-app
```
Der Build läuft mehrere Minuten — **im Hintergrund starten und
weiterarbeiten**, danach prüfen (`lipo -archs` auf beide Binaries, beide
Ressourcen-Bundles, alle vier `.lproj`, `plutil -lint` auf die Info.plist).
**Die App wird nicht gestartet.**

- [ ] **Schritt 2: Bericht**

Er nennt die gemessenen Zahlen; was durch Tests gehalten wird und was nur
durch Review; was der Export mit dem neuen Feld tut und warum; und
**ausdrücklich**, dass die GUI nicht gestartet wurde — mit der Liste dessen,
was der Maintainer ansehen muss: der neue Rand, die zwei Schalter, der
gesperrte letzte Schalter, und ob eine wiedergeöffnete Sitzung tatsächlich
so aufgeht, wie sie zuletzt stand.

- [ ] **Schritt 3: Commit**

```bash
git commit -m "docs(app): record the terminal chrome phase"
```

---

## Selbstreview dieses Plans

**Spec-Abdeckung:** Rand 14/8 → Task 1. Zwei Schalter + Riegel → Tasks 2/3.
Ohne Shell kein Terminal-Schalter → Task 2 (Regel) und Task 3 (Anzeige).
Zustand pro gespeicherter Sitzung inkl. Export → Task 4.

**Drei Stellen, an denen dieser Plan bewusst nicht rät**, sondern messen
lässt: die drei Randwerte (Task 1, Schritt 1), ob sich die vorhandene
Terminal-Sichtbarkeit sauber als Quelle verwenden lässt (Task 3, Schritt 3),
und was der Export heute mit `groupID` macht (Task 4, Schritt 1). Alle drei
sind mit „melden statt anpassen" versehen.

**Nicht Teil davon:** Host-Tags, Sidebar-Filter, Import/Export der Snippets
(P3); der Massen-Runner; mehrzeilige Kommandos; Mehrfenster (v2).
