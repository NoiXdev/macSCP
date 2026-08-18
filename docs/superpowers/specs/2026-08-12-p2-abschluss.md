# P2 — Abschlussbericht (Terminal-Fassung)

**Status:** abgeschlossen 2026-08-18. HEAD vor diesem Bericht:
`6c7d20b69578b72bbb6af75b71d45f976d6b3fcc`. Spec:
`2026-08-10-snippets-runde-2-design.md`, Abschnitt „P2". Plan:
`../plans/2026-08-12-p2-terminal-fassung.md`. Ledger:
`.superpowers/sdd/2026-08-12-p2-terminal-fassung/progress.md`.

## Korrektur am Abschluss-Brief

Der Brief zu dieser Task beschreibt „die Phase in fünf Commits
(`36cc3c0..HEAD`)" und zählt dabei alle vier Task-Inhalte auf (Rand-Vereinheit-
lichung, `PaneVisibility`-Modell, Toolbar-Schalter, Persistenz). Das ist
falsch: `git log 36cc3c0..HEAD` liefert genau **fünf** Commits, aber die
gehören ausschließlich zu Task 3 und Task 4 (die zwei Toolbar-Schalter +
Critical-Fix, dann die Persistenz + ihr Fix). Rand-Vereinheitlichung (Task 1)
und das `PaneVisibility`-Modell (Task 2) liegen **vor** `36cc3c0`, also
außerhalb dieses Bereichs. Die tatsächliche Phase — vom Plan-Commit bis
`HEAD` — sind **neun** Commits, nicht fünf:

```
$ git rev-list --count 55d9dad..HEAD
9
$ git log --oneline --reverse 55d9dad..HEAD
acda5ca feat(app): give the terminal the inset the rest of the panel already uses
0ac5537 fix(app): unify the terminal panel's inset on the spec's decided 14/8
82d2c16 feat(core): decide pane visibility and which toggle is locked
36cc3c0 fix(core): enforce PaneVisibility invariant at construction, not just decode
294a2a3 feat(app): switch both window halves from the toolbar
00a57f2 fix(app): make the pane render read the same repaired visibility
66e535c test(app): guard detail's render conditions against the raw booleans
4cf2600 feat(core): remember which window halves a saved session shows
6c7d20b fix(app): restore the pane-visibility fold and pin its wiring
```

Gemeldet statt still angepasst, wie von dieser Task verlangt. Alle übrigen
Befehle und Pfade im Brief (`swift test`, der `.strings`-Lint-Loop, der
`package-app`-Aufruf, die Prüfliste danach) stimmen mit der Realität überein
und wurden unverändert ausgeführt.

## Commits der Phase

| Commit | Task | Inhalt |
|---|---|---|
| `55d9dad` | — | Plan (= Basis, kein Phaseninhalt) |
| `acda5ca` / `0ac5537` | 1 | Terminal-Rand: erster Versuch 12/6 (eigene Interpretation), Fixrunde vereinheitlicht auf das spec-vorgegebene 14/8 |
| `82d2c16` / `36cc3c0` | 2 | `PaneVisibility` (Core): Entscheidung + gesperrter letzter Schalter; Fixrunde macht die Felder `let` — die Verletzung des Invarianten ist jetzt ein Compile-Fehler |
| `294a2a3` / `00a57f2` / `66e535c` | 3 | Toolbar-Schalter „Dateien"/„Terminal", Critical-Fix: eine reparierte `PaneVisibility` speist Toolbar UND Layout, Wächtertest gegen ein Zurückfallen auf die rohen Booleans |
| `4cf2600` / `6c7d20b` | 4 | Zustand pro `StoredSession`, Export/Import, Fixrunde: Wiederherstellung ruft dieselbe Fold-Methode statt sie nachzubauen, plus Wiring-Wächter |

## 1. Gemessene Zahlen

Selbst gemessen in dieser Sitzung, nicht aus einem Report übernommen.

```
$ swift test 2>&1 | tail -3
✔ Suite "TerminalPanelViewModel" passed after 5.053 seconds.
✔ Test run with 1935 tests in 164 suites passed after 5.057 seconds.
```

**1935 Tests / 164 Suiten, grün** — deckt sich mit der Zahl am Ende von
Task 4s Fixrunde (Task 4-Report); nichts ist zwischen Phasenende und diesem
Abschluss dazugekommen oder rot geworden.

**Acht `.strings`-Kataloge, `plutil -lint`:** alle acht (`en/de/fr/pl` ×
`MacSCPAppKit`/`macSCPCore`) → `OK`. Keine neuen L10n-Schlüssel in dieser
Phase (Task 4 fügt keine UI-Oberfläche hinzu; Task 3s zwei neuen Schlüssel
`browser.filesToggle`/`browser.filesToggleHelp` sind bereits in der
1935er-Zahl enthalten und wurden dort bereits gegen alle vier Sprachen
geprüft).

## 2. Der Dev-Build

```
MACSCP_VERSION="1.2.0-dev" MACSCP_BUILD="$(git rev-list --count HEAD)" ./scripts/package-app
```

Im Hintergrund gestartet, während die Testmessung und die spätere
`if false`-Probe (Abschnitt 3) im Vordergrund liefen — kein Commit kam
danach hinzu, der ihn veralten könnte.

| Prüfung | Ergebnis |
|---|---|
| Build | `Build complete!` (arm64 + x86_64, je einzeln) |
| `lipo -archs` auf `dist/macSCP.app/Contents/MacOS/macSCP` | `x86_64 arm64` |
| `lipo -archs` auf `dist/macSCP.app/Contents/MacOS/macscp-cli` | `x86_64 arm64` |
| Resource-Bundles | `macSCP_MacSCPAppKit.bundle`, `macSCP_macSCPCore.bundle` — beide vorhanden |
| `.lproj` unter `Contents/Resources` | `en`, `de`, `fr`, `pl` — alle vier vorhanden |
| `plutil -lint dist/macSCP.app/Contents/Info.plist` | `OK` |
| `CFBundleShortVersionString` / `CFBundleVersion` | `1.2.0-dev` / `940` — deckt sich mit `git rev-list --count HEAD` |
| `scripts/release` | **nicht ausgeführt** (veröffentlicht) |
| GUI | **nicht gestartet** — siehe Abschnitt 4 |

Diese Prüfungen sind absichtlich doppelt gemacht: `package-app` selbst bricht
unter `set -euo pipefail` ab, falls eine der Checks scheitert, aber diese
Task hat sie danach unabhängig noch einmal selbst ausgeführt, nicht nur dem
Skript-Exitcode vertraut.

## 3. Was durch Tests gehalten wird — und was nur durch Review

Diese Phase stützt sich auf **drei quelltext-lesende Wächter**, alle nach
demselben, in `SnippetMenuItemsKeyboardShortcutGuardTests` etablierten
Muster gebaut (kein Rendering-Testwerkzeug im Projekt, siehe P1-Abschluss):

1. **`TerminalPanelInsetTests`** (Task 1) — scannt die `.running`/`.opening`-
   und `TerminalPanelHeader`-Bereiche auf numerische Literale statt der
   geteilten `DesignTokens`-Konstanten.
2. **`PaneRenderConditionGuardTests`** (Task 3, Fixrunde 2) — scannt
   `detail`s Rumpf darauf, dass kein `if tab.showsFiles`/`if
   session.terminal.isVisible` mehr die rohen Booleans direkt liest, sondern
   beide Render-Bedingungen von derselben `effectivePaneVisibility`
   abgeleitet sind. Existiert, weil genau das der Critical-Fund der Runde
   war: die Methode war korrekt, aber nicht verdrahtet, und kein anderer
   Test hätte das gemerkt.
3. **`PaneVisibilityWiringGuardTests`** (Task 4, Fixrunde 1) — scannt, dass
   `connect(in:stored:)` `restorePaneVisibility(` aufruft und dass alle drei
   Umschalt-Stellen in `ContentView+Lifecycle.swift` von
   `persistActivePaneVisibility()` gefolgt sind.

**Jeder der drei hat dokumentierte blinde Flecken** — zeilenbasiert, nicht
kontrollflussbasiert. Für den dritten wurde der schärfste dieser Flecken in
dieser Sitzung nicht nur behauptet, sondern **nachgestellt**: der
`connectRestoresPaneVisibility`-Check prüft nur, ob die Zeichenkette
`restorePaneVisibility(` irgendwo im Funktionsrumpf vorkommt — nicht, ob der
Aufruf auf jedem Pfad erreichbar ist. Probe (Datei danach byte-identisch
wiederhergestellt, per `diff` bestätigt):

```
$ sed -i '' 's/restorePaneVisibility(for: tab, from: stored, descriptor: descriptor)/if false { restorePaneVisibility(for: tab, from: stored, descriptor: descriptor) }/' \
    Sources/MacSCPAppKit/ContentView.swift
$ swift test --filter "PaneVisibilityWiringGuardTests"
✔ Test connectRestoresPaneVisibility() passed after 0.003 seconds.
✔ Suite "Pane visibility wiring guard" passed after 0.003 seconds.
✔ Test run with 6 tests in 1 suite passed after 0.003 seconds.
```

Der Wächter bleibt grün, obwohl der Aufruf durch `if false` faktisch tot ist
— **verifiziert, nicht angenommen**, wie vom Brief verlangt. Das ist derselbe
blinde Fleck, den Task 4s eigener Report bereits benannt hatte
("a reachability/control-flow check" fehlt), aber dort nur gelesen, hier
tatsächlich reproduziert.

**Was jeweils NICHT durch einen Test gehalten wird, sondern nur durch
Lesen:**

- Dass die drei App-seitigen Aufrufstellen (`restorePaneVisibility`,
  `persistActivePaneVisibility` an den drei Umschalt-Stellen) tatsächlich
  zur Laufzeit das Richtige tun — das Projekt hat kein
  View-Instanziierungs-Werkzeug, `ContentView` wird im Testtarget nie gebaut.
- Dass das automatische Öffnen der Shell beim Wiederherstellen keinen
  zweiten Verbindungsaufbau, keine erneute TOFU-Prüfung und keinen
  Audit-Eintrag auslöst (Task 4s Begründung) — durch Code-Lesen verifiziert
  (Aufrufkette bis `CitadelShell.open` auf demselben Client nachverfolgt,
  `AuditEvent.Kind` ohne Shell-Fall geprüft), nicht durch einen Test, der
  tatsächlich verbindet.
- Externer-Terminal-Modus: der Terminal-Knopf umgeht die Pane-Sperre
  bewusst (gated nur auf `activeTabSupportsShell`), weil dieser Modus
  `isVisible` nie anfasst — gelesen, nicht gepinnt.

## 4. Was der Export mit dem neuen Feld tut, und warum

Die Frage stand ausdrücklich offen im Plan ("was macht der Export heute mit
`groupID`?", "melden statt anpassen"). Task 4s Antwort, aus dem Lesen des
bestehenden Codes und nicht aus einer erfundenen Regel:

`SessionListViewModel.exportPayload` trägt `groupID` **immer mit**, wenn der
Export-Scope Gruppen einschließt — es ist ein Top-Level-Feld auf
`ExportedSession`, außerhalb des Backend-Feldbeutels (`fields`), verliert
sich also nicht beim Roundtrip. Beim Import kopiert `SessionImportPlanner`
`groupID` aber **nicht wörtlich**: es ist eine Referenz in die
dateilokale Gruppenliste, die auf eine passende bestehende oder neu
angelegte Gruppe umgeschrieben wird — sonst würde ein Import entweder mit
einer unrelated lokalen Gruppe gleicher UUID kollidieren oder ins Leere
zeigen.

**`paneVisibility` folgt derselben Kategorie, nicht demselben Mechanismus.**
Es ist wie `groupID` ein Fakt über die Sitzung, kein Backend-Feld — lebt
also auch als Top-Level-Feld, nicht im Feldbeutel — und wird beim Export
**bedingungslos** mitgeschrieben (anders als `groupID`, das hinter
`includeGroups` hängt: dieses Flag betrifft speziell Gruppenzugehörigkeit,
`paneVisibility` ist keine). Es braucht aber KEINE Umschreibung beim Import,
weil es kein Verweis auf etwas anderes in der Datei ist, sondern ein reiner
Wert — Import kopiert es also wörtlich, mit Default-Fallback (`??
.bothVisible`) für Dateien ohne das Feld.

`ExportedSession.paneVisibility` ist dabei — wie `kind` in derselben Datei —
optional und dekodiert auf legalen Altdateien zu `nil`; der
`?? .bothVisible`-Default wird erst beim Import in `makePlanned` angewendet,
nicht schon beim Dekodieren. `StoredSession.paneVisibility` dagegen ist
nicht-optional mit dem Default direkt im eigenen `init(from:)`, exakt wie
`StoredSession.kind`. Beide folgen also dem Muster, das ihr jeweiliger Typ
für `kind` bereits etabliert hatte — nicht `groupID`s Muster, das hier nicht
passt.

## 5. Die GUI wurde nicht gestartet

Ausdrücklich, für den gesamten Verlauf dieser Phase (Tasks 1–5): kein
`open`, kein Fensteraufruf. Alles oben steht auf `swift test`, `swift
build`/`package-app` und Quelltext-Lesen. Folgendes muss der Maintainer
selbst ansehen:

1. **Der neue Rand** — 14 horizontal / 8 vertikal um die Terminalfläche
   (`.running`/`.opening`-Zustand), jetzt auf demselben Wert wie der
   `.ended`-Textblock und die Kopfzeile. Ob sich das optisch tatsächlich
   bündig anfühlt, ist eine Sichtprüfung; die drei Zahlen selbst sind nur
   quelltext-verifiziert (`TerminalPanelInsetTests`).
2. **Die zwei Toolbar-Schalter** „Dateien" und „Terminal" — ob sie
   tatsächlich beide Fensterhälften unabhängig ein-/ausblenden, ob ihr
   visueller Zustand (aktiv/inaktiv) zum tatsächlichen Panel-Zustand passt.
3. **Der gesperrte letzte Schalter** — ob er sich sichtbar deaktiviert
   zeigt (nicht nur wirkungslos reagiert), wenn er die letzte sichtbare
   Hälfte ist; ob das bei einer Sitzung ohne Shell (S3/WebDAV) korrekt den
   Terminal-Schalter grau zeigt und „Dateien" dadurch gesperrt ist.
4. **Vor allem: ob eine wiedergeöffnete Sitzung tatsächlich so aufgeht, wie
   sie zuletzt stand.** Das ist der Kern von Task 4 und in dieser Phase am
   wenigsten geprüft — die Persistenz- und Wiring-Logik ist durch Tests und
   die zwei Wächter aus Abschnitt 3 abgedeckt, aber **kein Laufzeit-Smoke-
   Test der Kette Umschalten → Trennen → Neuverbinden wurde in dieser oder
   einer vorherigen Sitzung durchgeführt.** Weder "Terminal aus, Dateien an,
   trennen, neu verbinden, Terminal bleibt aus" noch der umgekehrte Fall
   wurden je an einer laufenden App beobachtet.

## 6. Aus dem Ledger vorgetragen — offene Minderbefunde

Keiner in dieser Phase behoben, weil jeder außerhalb des jeweiligen
Task-Umfangs lag oder als bewusste, dokumentierte Entscheidung steht:

1. **`PaneRenderConditionGuardTests` ist zeilen-/literalbasiert** (Task 3):
   `if tab.showsFiles == true`, eine über mehrere Zeilen gesplittete
   Bedingung, eine Umbenennung von `visibility`/`tab`, oder eine dritte
   Render-Stelle außerhalb `detail` würden ihn nicht auffallen.
2. **Externer-Terminal-Modus umgeht die Pane-Sperre** (Task 3): bewusst, da
   dieser Modus `isVisible` nie anfasst.
3. **Wiederherstellen öffnet das eingebaute Panel auch bei
   `settingsStore.terminalTarget != .builtIn`** (Task 4): inkonsistent,
   aber keine Falle — das Panel bleibt schließbar.
4. **`PaneVisibilityWiringGuardTests`' Connect-Pfad-Check ist textuell, kein
   Kontrollfluss-Check** (Task 4) — in Abschnitt 3 dieser Sitzung
   nachgestellt, nicht nur übernommen.

## 7. Was offen bleibt

- Die vier Minderbefunde aus Abschnitt 6.
- **Die Sichtprüfungen aus Abschnitt 5** — insbesondere Punkt 4
  (Wiedereröffnen einer Sitzung), noch nicht erfolgt.
- **Release-Stau:** `git rev-list --count origin/develop..develop` → **62**;
  `git rev-list --count origin/main..develop` → **472**. Weiter gewachsen
  seit dem P1-Abschluss (damals 47/457).
- **P3 aus der Spec** — Host-Tags am `StoredSession`, Sidebar-Filter,
  Import/Export der Snippets über die Envelope-Maschinerie aus M19. Bisher
  nur Skizze, nicht Teil dieser Phase.
- **Mehrfenster** bleibt laut Projektregel v2 — ein eigenes Fenster für ein
  reines Terminal war deshalb von vornherein ausgeschlossen, siehe Spec.

## Für die Release-Notes

**Ein Satz:** Terminal und Dateiansicht lassen sich jetzt unabhängig
ein- und ausblenden, und die Wahl bleibt pro gespeicherter Sitzung erhalten.

---

## Nachtrag: Maintainer-Ruling zum Default (Re-Review der Fixrunde)

**Ein fehlendes `paneVisibility` bedeutet: nur Dateien, kein Terminal.**

Der urspruengliche Default `.bothVisible` war falsch, und zwar folgenreich:
`restorePaneVisibility` **oeffnet** bei gespeichertem sichtbarem Terminal
das Panel und startet eine Shell — jede bestehende gespeicherte Sitzung
haette also beim naechsten Verbinden ein Terminal bekommen. Der
Doc-Kommentar behauptete das Gegenteil („exactly how every session behaved
before this field existed") und war die einzige Aussage im Feld, die kein
Test beobachtet hat.

`PaneVisibility.filesOnly` ist ab `74d8c2b` die eine Schreibweise fuer
„nichts hinterlegt" (`StoredSession`-Default und -Decode, Import-Planner,
lenienter Decode). `bothVisible` bleibt als Wert bestehen, ist aber kein
Default mehr. Ein **explizit** gespeichertes `showsTerminal: true` stellt
das Terminal weiterhin her; fehlendes Feld und explizites
`{showsFiles: true, showsTerminal: false}` sind beim Connect gleichbedeutend
— beide Faelle sind nebeneinander gepinnt, damit daraus nicht „ein Terminal
wird nie wiederhergestellt" wird.

Ausserdem hat `restorePaneVisibility` erstmals echte Verhaltensabdeckung:
die Entscheidung liegt jetzt in `SessionTab.applyRestoredPaneVisibility(_:
hasShell:)`, in `ContentView` bleibt nur der `toggle()`-Aufruf. Suite nach
der Runde: **1958 Tests / 166 Suiten**.

