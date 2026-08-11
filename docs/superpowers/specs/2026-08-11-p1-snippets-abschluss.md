# P1 — Abschlussbericht (Snippets erreichbar)

**Status:** abgeschlossen 2026-08-11. HEAD vor diesem Bericht: `df081be`.

Neun Tasks: vier am Core-Modell (Flag raus, Tags rein, Bytes, Vorschlagsliste,
`SnippetMenuModel`), fünf an der App (Verwaltungs-Sheet, Menüleiste,
Host-Kontextmenü, Terminal-Kopfzeile, Rechtsklick), dazu dieser Abschluss.
Spec: `2026-08-10-snippets-runde-2-design.md`, Abschnitt „P1". Plan:
`../plans/2026-08-11-p1-snippets-erreichbar.md`. Ledger:
`.superpowers/sdd/2026-08-11-p1-snippets-erreichbar/progress.md`.

## Commits

Basis des Plans: `7247685` (Planungs-Doc, letzter Commit vor Task 1).

| Commit | Inhalt |
|---|---|
| `7247685` | Plan (= Basis) |
| `e9b52ac` | Task 1 — Modell: `runsImmediately` raus, `tags` rein |
| `2cede3e` | Task 2 — `SnippetKeystrokes.bytes(for:execute:)` |
| `a7cc2b4` / `a346516` | Task 3 — Vorschlagsliste, Fixrunde (case-insensitive Exclude/Count unpinned) |
| `942ce69` / `82876b3` | Task 4 — `SnippetMenuModel`, Fixrunde (Sortierreihenfolge unpinned) |
| `18b0741` / `f63d124` | Task 5 — Verwaltungs-Sheet: Häkchen raus, Tag-Feld + Filter, Fixrunde (toter L10n-Schlüssel, Highlight-Clamp unpinned) |
| `f60ffc5` / `371c2bb` | Task 6 — Menüleiste auf das Modell, Fixrunde (Shortcut-Wächter für Execute) |
| `62c9cf6` | Task 7 — Kontextmenü am Host |
| `2d59a30` | Task 8 — Terminal-Kopfzeile mit Popover |
| `df081be` | Task 9 — Rechtsklick im Terminal |

**Unversendet:** `git rev-list --count origin/develop..develop` → **47** vor
diesem Bericht-Commit. **Release-Stau:**
`git rev-list --count origin/main..develop` → **457**.

## 1. Gemessene Zahlen

Nicht aus Plan oder Brief abgeschrieben. Die Vorher-Zahl wurde in dieser
Sitzung in einem eigenen `git worktree` auf dem Plan-Basiscommit (`7247685`)
neu gemessen und der Worktree danach entfernt; die Nachher-Zahl im
Hauptbaum auf `df081be`.

| | vorher (`7247685`, isolierter Worktree) | nachher (`df081be`, dieser Baum) |
|---|---|---|
| `swift test` | **1786 Tests / 150 Suiten, grün** | **1880 Tests / 159 Suiten, grün** |

Zuwachs: **+94 Tests, +9 Suiten**, verteilt über die neun Tasks (jeweils vor
und nach ihrer eigenen Fixrunde aus den Task-Berichten nachvollziehbar):
1786→1792 (T1, +6) →1795 (T2, +3) →1801 (T3, +6, neue Suite
`SnippetTagSuggestionsTests`) →1803 (T3-Fix, +2) →1811 (T4, +8, neue Suite
`SnippetMenuModelTests`) →1814 (T4-Fix, +3) →1837 (T5, +23, neue Suite
`SnippetTagFieldTests`) →1843 (T5-Fix, +6) →1853 (T6, +10, neue Suite
`SnippetMenuItemsTests`) →1859 (T6-Fix, +6, neue Suite
`SnippetMenuItemsKeyboardShortcutGuardTests`) →1865 (T7, +6, neue Suite
`SessionRowSnippetMenuPlanTests`) →1871 (T8, +6, neue Suite
`TerminalSnippetSearchTests`) →1880 (T9, +9, neue Suite
`TerminalContextMenuTests`). Kein bestehender Test hat in dieser Phase
seinen Status geändert.

**Katalog-Wächter, acht Kataloge.** Das Projekt hat keine `.xcstrings`-Dateien
(`git ls-files '*.xcstrings'` → leer) — Lokalisierung läuft über klassische
`Localizable.strings` je vier Sprachen (en/de/fr/pl) in zwei Ressourcen-
Verzeichnissen (`Sources/MacSCPAppKit/Resources`,
`Sources/macSCPCore/Resources`), macht acht Dateien. `plutil -lint` auf allen
acht: **`OK`**, ausnahmslos. `LocalizableStringsTests` (der bestehende
Wächter für Schlüsselmengen-Parität über die vier Sprachen je Layer) blieb
bei jedem Task grün — kein L10n-Schlüssel wurde in einer Sprache vergessen.

## 2. Der Dev-Build

```
MACSCP_VERSION="1.2.0-dev" MACSCP_BUILD="$(git rev-list --count HEAD)" ./scripts/package-app
```

| Lauf | Ergebnis |
|---|---|
| `swift build -c release --triple arm64-apple-macosx` + `--triple x86_64-apple-macosx` | `Build complete!` (zweimal, je Architektur) |
| `lipo -archs` auf `dist/macSCP.app/Contents/MacOS/macSCP` | `x86_64 arm64` |
| `lipo -archs` auf `dist/macSCP.app/Contents/MacOS/macscp-cli` | `x86_64 arm64` |
| Resource-Bundles | `macSCP_MacSCPAppKit.bundle`, `macSCP_macSCPCore.bundle` — beide vorhanden |
| `en/de/fr/pl.lproj`-Marker unter `Contents/Resources` | alle vier vorhanden |
| `plutil -lint dist/macSCP.app/Contents/Info.plist` | `OK` |
| `CFBundleShortVersionString` / `CFBundleVersion` | `1.2.0-dev` / `925` — `925` deckt sich mit `git rev-list --count HEAD` auf `df081be` |
| `scripts/release` | **nicht ausgeführt** (veröffentlicht) |
| GUI | **nicht gestartet** |

Der Build lief einmal, im Hintergrund, während die Testmessungen liefen; kein
Commit kam danach hinzu, der ihn veralten könnte.

## 3. Die Erfolgskriterien der Spec, einzeln

| # | Kriterium | Nachweis | Ergebnis |
|---|---|---|---|
| 1 | Eine `snippets.json` aus Runde 1 lädt; `runsImmediately` verschwindet, `tags` leer | **Test** | `aRoundOneStoreFileLoadsWithoutTags` (Task 1) |
| 2 | Einfügen hängt nie ein Zeilenende an, Ausführen genau eines (`0x0D`) | **Test** | `insertingNeverAppendsATerminator`, `executingAppendsExactlyOneCarriageReturn`, `theTwoCallsDifferByTheTerminatorAlone` (Task 2) |
| 3 | Tag getrimmt, leer abgelehnt, exakte Dubletten fallen weg, Groß/Klein bleibt | **Test** | `SnippetTests` (Task 1), inkl. dem Fall der von Hand bearbeiteten Datei |
| 4 | Vorschlagsliste findet `Docker` bei Eingabe `doc` | **Test** | `aLowercasePrefixFindsADifferentlyCasedTag` (Task 3) |
| 5 | `SnippetMenuModel` gruppiert nach Tags, Untagged zuletzt, liefert Deaktiviert-Grund | **Test** | `SnippetMenuModelTests`, 11 Tests nach Fixrunde (Task 4) |
| 6 | Unlesbarer Store sieht nicht wie leerer aus | **Test** | `SnippetsLoad` unverändert, bestehender Test bleibt grün |
| 7 | Alle vier Auslöseflächen zeigen dieselben Einträge | **Review — Nachweis im Code** | alle vier rendern `SnippetMenuItems` über dieselbe `SnippetMenuModel`; siehe Abschnitt 4 |
| 8 | Ohne verbundene Sitzung bzw. ohne Shell sind Einträge deaktiviert | **Review** | App-seitige Verdrahtung (`!isActiveTabConnected \|\| !activeTabSupportsShell` bzw. `BackendDescriptor…supportsShell`), Drawing selbst ungeprüft |
| 9 | P0 ändert kein Verhalten | **Test + Build je Schritt** | betrifft P0, nicht diese Phase — bereits im P0-Abschlussbericht behandelt |
| 10 | Alle vier Kataloge tragen die neuen Schlüssel | **Test + `plutil -lint`** | `LocalizableStringsTests` grün, acht Kataloge `OK` (Abschnitt 1) |
| 11 | Shortcuts-Katalog nennt die Kürzel korrekt | **Review** | `KeyboardShortcutsCatalog.swift`: Eintrag „Insert snippet 1–3" / `⌃⌘1–3`, kein Execute-Kürzel behauptet — siehe Abschnitt 4 |
| 12 | PV endet mit lauffähigem Beispieltest oder belegtem Nein | **Test** | betrifft PV, nicht diese Phase — bereits im PV/P0-Abschlussbericht behandelt |

Kriterien 7, 8 und 11 sind **Review-Punkte, keine Tests** — wie die Spec es
selbst vorschreibt. Die Unterscheidung wird hier nicht verwischt: „im Code
nachweisbar" (7) heißt, dass alle vier Flächen denselben Typ instanziieren,
nicht dass ein Test das Rendering prüft; „Review" (8, 11) heißt gelesen, nicht
ausgeführt.

## 4. Der Nachweis für Kriterium 7 — ein Modell, vier Flächen

`SnippetMenuModel.build(snippets:isConnected:supportsShell:)` (Core) ist die
einzige Stelle, die entscheidet: Gruppierung nach Tag, Untagged zuletzt,
Deaktiviert-Grund. Die Präzedenz bei gleichzeitigem `!isConnected` und
`!supportsShell`: `backendHasNoShell` gewinnt, dokumentiert und gepinnt in
`SnippetMenuModel.swift` — Shell-Losigkeit ist eine dauerhafte
Backend-Eigenschaft, „nicht verbunden" verspräche fälschlich, dass Verbinden
das Problem behebt.

Alle vier Flächen instanziieren `SnippetMenuItems` (App, `SnippetMenuItems.swift`)
über diese eine `SnippetMenuModel` — keine hat ihre eigene Kopie der
Menülogik:

| Fläche | Datei | Ruft |
|---|---|---|
| Menüleiste „Terminal" | `MacSCPApp.swift` | `SnippetMenuItems` direkt |
| Kontextmenü am Host | `SessionSidebar.swift` | `SnippetMenuItems` über `SessionRowSnippetMenuPlan` |
| Terminal-Kopfzeile/Popover | `ContentView+Detail.swift` | `SnippetMenuItems` mit `TerminalSnippetSearch`-gefilterter Liste |
| Rechtsklick im Terminal | `SSHTerminalView.swift` | `SnippetMenuItems` über `NSHostingMenu` |

Das ist der Nachweis im Code, keine Laufzeitmessung: eine Änderung an
`SnippetMenuItems` wirkt zwangsläufig auf alle vier Flächen gleichzeitig, weil
keine Fläche ihre Einträge selbst baut.

**Shortcuts-Katalog (Kriterium 11), Review.**
`KeyboardShortcutsCatalog.swift` führt die Gruppe „Snippets" mit einer Zeile:
Titel „Insert snippet 1–3", Kürzel `⌃⌘1–3`. Der Datei-Kopfkommentar nennt sich
selbst einen von Hand gepflegten Spiegel ohne zentrales Register und verlangt
ausdrücklich, ihn bei jeder Kürzeländerung mitzuführen. Kein Eintrag behauptet
ein Execute-Kürzel — im Gegenteil, der Kommentar in `MacSCPApp.swift`
begründet ausdrücklich, warum Execute nie eines bekommt: ein Tastendruck, der
sofort auf einem entfernten Host läuft, hat keinen guten Fehlerfall. Der
tatsächliche Katalogeintrag stimmt mit dem echten Verhalten überein — geprüft
durch Lesen, nicht durch einen Test (dafür gibt es einen anderen, engeren
Test: siehe Abschnitt 6, `SnippetMenuItemsKeyboardShortcutGuardTests` schützt
nur, dass Execute *im Code* kein `.keyboardShortcut` bekommt, nicht dass der
Katalogtext dazu stimmt).

## 5. Die zwei „zu messen statt anzunehmen"-Punkte der Spec

**Rechtsklick im Terminal (Task 9).** Die Spec verlangte, festzustellen, ob
SwiftTerms `TerminalView` den Rechtsklick bereits belegt, statt es aus dem
Fehlen von `rightMouseDown`-Overrides zu folgern. Gemessen, nicht gefolgert,
mit zwei unabhängigen, dauerhaft im Baum verbliebenen Tests
(`TerminalContextMenuTests.swift`):

- **Objective-C-Laufzeit, ohne Instanz:** `class_getMethodImplementation` für
  `rightMouseDown(with:)`, `menu(for:)` und den `menu`-Getter zeigt: die IMP,
  die `TerminalView` erbt, ist die von `NSView`, nicht überschrieben, und
  `NSView`s IMP unterscheidet sich wiederum echt von `NSResponder`s Default.
- **Echte Instanz:** ein frisches `TerminalView` hat `menu == nil`; nach
  `terminal.menu = someMenu` liefert `terminal.menu(for: event)` exakt dieses
  Objekt (Identität); keine der drei Subviews (`NSScroller`,
  `TerminalProgressBarView`, `CaretView`) fängt den Klick ab.

**Ergebnis: der Rechtsklick trägt.** Er verdrängt nichts — SwiftTerm sieht die
rechte Maustaste heute gar nicht (nur `mouseDown`/`mouseUp`/`mouseDragged`
sind überschrieben), Selektion ist linksklick-only, kein eingebautes Menü
existiert, kein Vorfahre trägt einen `.contextMenu`. Verdrahtet über
`NSHostingMenu` auf `SnippetMenuItems` — nicht neu gebaut. **Offen bleibt eine
Sichtprüfung:** dass AppKit das aufgebaute `NSMenu` tatsächlich auf dem
Bildschirm zeigt, wenn der Nutzer rechtsklickt, braucht ein echtes Fenster
und eine laufende Modal-Tracking-Loop — nicht im Prozess ohne Hänger-Risiko
zu prüfen, und die GUI wurde nicht gestartet.

**Terminal-Panel-Rand (Task 8).** In `ContentView+Detail.swift`, aktueller
Stand, gegengemessen für diesen Bericht:

- Höhe des Terminalstreifens: `.frame(minHeight: 120, idealHeight: 220)` am
  `terminalPanel(session)`-Aufruf in `detail`.
- Der einzige Innenabstand innerhalb von `terminalPanel` selbst:
  `.padding(.vertical, 8).padding(.horizontal, 14)` am Textblock des
  `.ended`-Zustands.

Beide Werte sind **bewusst unverändert** — der Rand ist P2, nicht P1. Die
neue Kopfzeile trägt eigenen, neuen Innenabstand
(`.padding(.horizontal, 12).padding(.vertical, 6)`), der nichts an der
bestehenden Fläche ändert, sondern hinzukommt.

## 6. Eine echte Verschiebung dessen, was prüfbar ist

Bis Task 9 war die ehrliche Position dieses Projekts: Views in
`MacSCPAppKit` sind ungetestet, `SnippetMenuItems`s Rumpf eingeschlossen —
Task 6 und 7 mussten das in ihren eigenen Berichten so festhalten
(„no view-testing tool in this project sees AppKit-backed menu content").

`NSHostingMenu` ändert das für **diesen einen Fall**. Ein `NSHostingMenu`
über `SnippetMenuItems` erzeugt ein echtes `NSMenu` im Testprozess, ohne
Fenster, ohne laufende `NSApplication` — und dieses `NSMenu` lässt sich
abfragen: `TerminalContextMenuTests` feuert die entstandenen `NSMenuItem`s
und prüft dabei die gerenderte Struktur der geteilten Komponente selbst, zum
ersten Mal in diesem Projekt — Untermenü je Tag, Insert-/Execute-Titel pro
Snippet mit den lokalisierten Texten, und das `execute`-Flag jedes Eintrags,
verifiziert dadurch, dass beide Aktionen tatsächlich gefeuert und die
übergebenen Werte (`false`/`true`) geprüft wurden. Die Mutationsprobe aus
Task 9 bestätigt, dass die Suite tatsächlich reagiert: mit entfernter
Divider-Logik und Leer-Guard gingen 6 von 9 Tests in 5 Fällen rot.

**Was das nicht ändert:** `NSHostingMenu` trägt nur, weil ein Menü letztlich
eine flache Liste von `NSMenuItem`s ist, die AppKit selbst aus der
SwiftUI-Beschreibung baut — die Technik überträgt sich nicht auf beliebiges
SwiftUI. Layoutfragen, `TextField`/`Toggle`/Tabellen-Inhalte, Popover-
Positionierung, tatsächliches Zeichnen: nichts davon wird durch diesen Fund
prüfbar. Der letzte Schritt bleibt ungeprüft, wie in Abschnitt 5 genannt:
dass AppKit das Menü wirklich auf den Bildschirm bringt, wenn die rechte
Maustaste tatsächlich gedrückt wird, ist eine Frage der Modal-Tracking-Loop,
nicht der Menüstruktur — dafür bräuchte es ein laufendes Fenster.

## 7. Die GUI wurde nicht gestartet

Ausdrücklich: kein `open`, kein Aufruf, der ein Fenster zeigt, in dieser
gesamten Phase. Alles, was oben steht, stützt sich auf `swift test`,
`swift build`, den Dev-Build und Quelltext-Lesen. Folgende Stellen sind reine
Sichtprüfungen, die beim Maintainer liegen:

1. **Das Tag-Token-Feld** (`SnippetTagField.swift`) — Chips mit
   Entfernen-Knopf, die Vorschlagsliste beim Tippen mit dem „*x* als neuen
   Tag anlegen"-Eintrag zuletzt, Return/Komma/Backspace-Verhalten, der
   Zeilenumbruch der Chips (`TagFlowLayout`).
2. **Die Filterzeile** im Verwaltungs-Sheet — „Alle", je ein Chip pro Tag mit
   Anzahl, „ohne Tag", einwertige Auswahl.
3. **Die Terminal-Kopfzeile und ihr Popover** — Host links, Snippet-Knopf
   rechts, das Popover mit Suchfeld und Gruppen, ob es sich optisch von der
   neuen Kopfzeile absetzt.
4. **Das Kontextmenü am Host** — das Untermenü „Snippet" in der Sidebar, der
   sichtbare Grund „Nur für den aktiven Tab verfügbar", wenn die Zeile nicht
   der aktive Tab ist.
5. **Der Rechtsklick im Terminal, der eine Ebene tiefer als alles andere
   liegt:** dass AppKit das aufgebaute `NSMenu` tatsächlich auf dem
   Bildschirm zeigt. Alles bis zu diesem Punkt ist gemessen (Abschnitt 5);
   dieser eine Schritt ist der einzige, der ein laufendes Fenster mit
   Modal-Tracking braucht und den niemand ohne GUI-Start feststellen konnte.

## 8. Was aus dem Ledger vorgetragen wird — offene Minderbefunde

Fünf Einträge, keiner in dieser Phase behoben, weil jeder außerhalb des
jeweiligen Task-Umfangs lag:

1. **Der Orphan-Key-Wächter aus Task 5 sieht nur literale Schlüssel in
   `Sources/MacSCPAppKit`.** Variable-Schlüssel-Aufrufstellen
   (`ConnectionFormView`, `SchemaFormView`, ~13 weitere Stellen) und Core’s
   eigener Katalog liegen außerhalb seines Blicks. Nützlich, aber nicht
   erschöpfend — diese Einschränkung darf nicht als Vollständigkeitsbeweis
   verkauft werden.
2. **`TagFlowLayout`s Zeilenumbruch-Platzierung ist ungetestet.** Reines
   SwiftUI, laut PV-Ergebnis grundsätzlich mit dem Pixel-Harness
   (`ViewTestabilitySpike`) pinnbar — kein Test wurde ergänzt. Eine echte
   Lücke, keine behauptete Unmöglichkeit.
3. **Der Shortcut-Wächter aus Task 6 hat zwei offengelegte blinde Flecken.**
   `SnippetMenuItemsKeyboardShortcutGuardTests` ist ein Quelltext-Scan von
   `SnippetMenuItems.swift`: eine Umbenennung von `insertButton`, die den
   Execute-Button einschließt, würde still bestehen bleiben, ebenso ein
   Modifikator, der aus einer anderen Datei injiziert würde. Bedrohungsmodell
   ist ein lokaler Hand-Edit an genau dieser Datei — dokumentiert in seinem
   eigenen Doc-Kommentar.
4. **`SnippetMenuItems` rendert einen führenden `Divider()` per Default,
   sobald es Gruppen hat.** In der Menüleiste sinnvoll (trennt von den
   bestehenden Terminal-Einträgen darüber); im Host-Kontextmenü-Untermenü
   (Task 7) ist er die erste Zeile — ein kosmetischer Artefakt, seit Task 9
   über den `leadingDivider`-Parameter grundsätzlich abschaltbar (genutzt vom
   Rechtsklick), aber in Task 7s Sidebar-Untermenü nicht abgeschaltet.
5. **Die offene Sichtprüfung aus Task 9** (Abschnitt 5/7): dass AppKit das
   Rechtsklick-Menü wirklich zeigt.

## 9. Was offen bleibt

- Die fünf Minderbefunde aus Abschnitt 8.
- **Die Sichtprüfungen durch den Maintainer** (Abschnitt 7) — noch nicht
  erfolgt, GUI in dieser Phase nicht gestartet.
- **Der Release-Stau:** 47 Commits vor `origin/develop`, 457 vor
  `origin/main` (Abschnitt „Commits") — weiter gewachsen.
- **P2 aus der Spec** — Terminal-Fassung: der jetzt gemessene Rand
  (Abschnitt 5) wird erst hier geändert, dazu ein eigener
  Terminal-Tab-Typ ohne SFTP-Panes und ein Umschalter, der die Dateipanes
  im normalen Tab ausblendet. Nicht Teil dieser Phase.
- **P3 aus der Spec** — Host-Tags am `StoredSession` mit Sidebar-Filter,
  Import/Export der Snippets über die Envelope-Maschinerie aus M19. Nicht
  Teil dieser Phase; P1 wurde bewusst zuerst gebaut, damit sich zeigt, wie
  Tags sich anfühlen, bevor sie ein zweites Mal an ein anderes Modell
  wandern.
- **Ausdrücklich nicht Teil des ursprünglichen Maintainer-Feedbacks, das
  diese Phase abdeckt:**
  - der **Massen-Runner** über gefilterte Hosts samt Ausgabe-Ansicht —
    eigenes Brainstorming, eigener Meilenstein, braucht eine eigene
    Auswahlmechanik (die P3s Host-Filter erst liefert).
  - **mehrzeilige Kommandos und Syntax-Hervorhebung** — ergeben laut Spec
    erst mit dem Massen-Runner einen ehrlichen Ort, solange „einfügen" der
    Normalfall bleibt.
  - **Host-Tags und Import/Export der Snippets** — P3, siehe oben.
  - **der Terminal-Rand und ein reines Terminal-Fenster** — P2, siehe oben.
- **Platzhalter** (`{{pfad}}`, aktuelles Verzeichnis), **Bindung von
  Snippets an Hosts/Gruppen/Protokolle**, **Agent-Forwarding**,
  **Mehrfenster** — von der Spec ausdrücklich ausgeschlossen, unverändert.

## Für die Release-Notes

**Ein Satz**, wie von der Spec vorgesehen: Snippets lassen sich mit Tags
ordnen und direkt am Host oder im Terminal einfügen oder ausführen.
