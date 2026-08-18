# P3d — Abschluss: die Snippet-Auswahl im Terminal wird flach

Abgeschlossen 2026-08-18. Drei inhaltliche Commits:

```
dd7941c feat(app): project the snippet model into a flat list
43acfbc feat(app): offer insert, run and cancel in one window
daf5c38 feat(app): flatten the terminal snippet picker
```

## Bedienbarkeit, keine Sicherheitskorrektur

Diese Phase behebt kein Loch. Die Popover-Auswahl hatte **nie** ein „ein
Klick führt aus": jede Zeile war schon vor diesem Umbau ein Untermenü mit
„Einfügen" und „Ausführen", genau deshalb so gebaut in Runde 2. Der
tatsächliche Maintainer-Befund war ausschließlich die Untermenüs selbst —
aufklappen, zur Seite fahren, treffen, im engen Popover unangenehm. Was sich
ändert, ist der Weg zur Aktion, nicht ob eine Aktion beiläufig auslösbar
wird.

## Wie sich Modell und Darstellung teilen

`SnippetMenuModel` bleibt die einzige Quelle für alle vier Auslöseflächen
(Popover, Rechtsklick im Terminal, Host-Kontextmenü, Menüzeile). Drei davon
sind echte Menüs und rendern weiterhin `SnippetMenuItems` — **byte-unverändert**
durch diese Phase, verifiziert per leerem Diff auf allen drei Dateien. Nur
das Popover bekommt eine zweite Projektion:
`SnippetListPlan.build(model:)` (`Sources/macSCPCore/Terminal/SnippetListPlan.swift`,
Task 1), reine Berechnung ohne SwiftUI-Bezug, deshalb in Core statt neben
`SnippetMenuPlan` in `MacSCPAppKit`.

## Jedes Snippet einmal statt zweimal

`SnippetMenuPlan` dupliziert ein Snippet mit zwei Tags bewusst — die zwei
Vorkommen liegen dort in zwei verschiedenen Untermenüs, von denen nie beide
gleichzeitig sichtbar sind. Eine flache, durchgehend sichtbare Liste hat
diese Untermenü-Grenze nicht: derselbe Name zweimal im selben Bereich sähe
wie ein Fehler aus, nicht wie Gruppierung, und würde die Pfeiltasten-
Navigation unterlaufen — genau der Grund, aus dem ein einfacher Klick nur
auswählt. `SnippetListPlan.build` zeigt deshalb jedes Snippet **höchstens
einmal**, unter dem ersten Abschnitt, der es sonst produziert hätte; ein
dadurch komplett leer gewordener Folgeabschnitt entfällt ganz.

## Das Aktionsfenster und seine Tastenkürzel

Doppelklick auf eine Zeile öffnet `SnippetActionSheet`
(`Sources/MacSCPAppKit/SnippetActionSheet.swift`, Task 2): Name, Befehl im
Klartext (`.textSelection(.enabled)`, monospaced), drei Aktionen.

- **Esc** bricht ab (`role: .cancel`).
- **Return** liegt auf **„Einfügen"** (`.keyboardShortcut(.defaultAction)`).
- **⌘Return** führt aus (`.keyboardShortcut(.return, modifiers: .command)`).

Begründung: Return löst in einem macOS-Dialog den Standardknopf aus. Läge
er auf „Ausführen", startete Doppelklick + Return einen Befehl auf einem
entfernten Rechner mit zwei Anschlägen — beiläufiger als der alte Weg über
das Untermenü, obwohl dieser Umbau das Gegenteil erreichen soll. Ein neuer,
gezielt kleiner Source-Text-Scan-Guard
(`SnippetActionSheetKeyboardShortcutGuardTests`) pinnt die Zuordnung; live
geprüft durch testweises Verschieben von `.defaultAction` auf Execute, das
beide zentralen Tests rot schlagen ließ.

## ⌃⌘n: nichts verloren

Der Task-4-Auftrag behauptete, das Popover verliere ⌃⌘n durch den Umbau.
Das ist widerlegt: `SnippetMenuItems.shortcutOrder` hat als Default `[]`,
und **nur** `MacSCPApp.swift` (die Menüzeile) übergibt die echte
Store-Reihenfolge. `SessionSidebar.swift` und die alte
`ContentView+Detail.swift` taten das nie — das Kürzel lebt exklusiv an der
Menüzeile, als global registrierter `NSMenuItem`, unabhängig davon ob ein
Popover offen ist. Die flache Liste hat ohnehin keine Buttons mehr, an die
ein `.keyboardShortcut` hängen könnte (Zeilen sind `Text` + Gesten). Nichts
ging verloren, weil vorher nichts da war.

## Die drei Wege im Popover (Task 3)

- **Rechtsklick auf die Zeile** → Ausführen, Einfügen, Vorschau — der
  schnelle Weg, eine Geste, kein Fenster. „Vorschau" pinnt die Zeile in
  dieselbe feste Befehlszeile, die auch beim Überfahren erscheint, statt
  ein zweites Fenster zu öffnen — kostet keine neue Datei, keinen neuen
  Fensterzustand.
- **Doppelklick** → `SnippetActionSheet` mit dem angeklickten Snippet.
- **Überfahren** → der Befehl steht in einer festen Zeile unten im Popover
  (immer vorhanden, mit Hinweistext ohne Hover/Pin, sonst springt die
  Popover-Höhe bei jedem Wechsel), gekürzt statt umgebrochen.
- **Ein einfacher Klick wählt nur aus**, löst nichts aus — Voraussetzung für
  Pfeiltasten-Bedienung. Die Geste dahinter (`TapGesture(...).exclusively(before:)`)
  ist ohne Rendering-Harness nicht testbar; ein neunter Source-Scan-Guard
  wurde bewusst nicht gebaut, weil die riskante Eigenschaft in einer
  mehrzeiligen, verschachtelten Gesten-Komposition steckt, die ein
  zeilenbasierter Scanner nicht zuverlässig anhand eines stabilen Musters
  fassen kann — er würde falsche Sicherheit liefern statt echten Schutz.

## GUI: nicht gestartet

Die App wurde in dieser Phase **nicht** gestartet. Für den Maintainer, zur
Verifikation von Hand — die vollständige Liste:

- Das Popover zeigt eine flache Liste ohne Untermenüs, Tag-Überschriften
  bleiben als Gruppierung erhalten.
- Rechtsklick auf eine Zeile öffnet ein Kontextmenü mit Ausführen, Einfügen,
  Vorschau.
- Doppelklick öffnet das Aktionsfenster mit Befehl im Klartext und den drei
  Knöpfen Einfügen/Ausführen/Abbrechen.
- Im Aktionsfenster: Esc bricht ab, Return fügt ein, ⌘Return führt aus.
- Überfahren einer Zeile zeigt den Befehl in der festen Zeile unten im
  Popover, nicht als Tooltip.
- Eine gesperrte Zeile (nicht verbunden / Backend ohne Shell) ist sichtbar
  deaktiviert.
- Menüzeile und Rechtsklick im Terminal zeigen weiterhin die alten
  Untermenüs mit Einfügen/Ausführen — unverändert.

## Messung

```
swift test    → 2097 Tests in 181 Suiten, alle grün
```

Startstand vor dieser Phase (Task-1-Beginn): 2076/178. Zuwachs über die drei
Tasks: 11 Tests (Task 1, `SnippetListPlan`) + 6 Tests (Task 2,
`SnippetActionSheetKeyboardShortcutGuardTests`) + 4 Tests (Task 3,
`SnippetPreviewLine`) = 21 neue Tests, deckungsgleich mit 2076 → 2097.

```
plutil -lint  → alle *.strings-Kataloge OK (alle vier Sprachen)
```

## Build-Verifikation (`scripts/package-app`, im Hintergrund gestartet)

```
lipo -archs dist/macSCP.app/Contents/MacOS/macSCP      → x86_64 arm64
lipo -archs dist/macSCP.app/Contents/MacOS/macscp-cli  → x86_64 arm64
Resources/*.bundle                                      → macSCP_MacSCPAppKit.bundle, macSCP_macSCPCore.bundle
Resources/*.lproj                                        → de, en, fr, pl (alle vier)
plutil -lint Info.plist                                  → OK
UTExportedTypeDeclarations                                → 3 (dev.noix.macscp.sessions, .logins, .snippets)
```

Die App wurde **nicht** gestartet; `scripts/release` wurde nicht ausgeführt.

## Brief-Fehler

Zwei eigene Brief-Fehler des Koordinators, beide von den jeweiligen Tasks
selbst am Code widerlegt:

- **Task 3:** der Brief behauptete, das Popover verliere ⌃⌘n durch den
  Umbau. Es hatte das Kürzel nie — siehe oben.
- **Task 3:** der Brief zitierte „sieben Source-Text-Scan-Wächter, ein
  achter nur mit Begründung" aus dem übergeordneten Plan. Task 2 hatte
  bereits einen achten gebaut; der Ausgangsstand für Task 3 war acht, nicht
  sieben. Der Plan-Text war vor Task 2 geschrieben und seither nicht
  nachgeführt worden.

Alle übrigen zitierten Fakten in den drei Task-Briefs (Startzahlen,
`SnippetMenuModel`/`SnippetMenuPlan`-Struktur, Duplizierungsregel der
Menü-Projektion) stimmten mit dem Code überein.

## Fix-Runde nach Abschluss

Zwei Nachbesserungen am bereits abgeschlossenen Phasenstand, vor der
Gesamt-Review der Branch.

**Fix 1 (Kontextmenü ungetestet).** Das per-Zeile-`.contextMenu` in
`snippetRow(_:)` (`Sources/MacSCPAppKit/ContentView+Detail.swift`) hatte
keinen Test, obwohl die Technik dafür im Projekt schon existiert:
`Tests/macSCPAppKitTests/TerminalContextMenuTests.swift` rendert eine
SwiftUI-Menü-Body per `NSHostingMenu` in ein echtes `NSMenu` und prüft
dessen Struktur — bislang nur für `SnippetMenuItems` genutzt. Der
Menü-Inhalt wurde aus der Closure herausgezogen in einen eigenen Typ,
`SnippetRowContextMenu` (`View`, drei Buttons: Execute/Insert gated auf
`!row.isDisabled`, Preview ungegated), damit `NSHostingMenu` ihn direkt
rendern kann, ohne Zeilen-Gesten oder das Popover drumherum. Drei neue
Tests in `TerminalContextMenuTests`: eine aktivierte Zeile bietet
Execute/Insert/Preview; eine deaktivierte Zeile bietet nur Preview; jeder
Menüpunkt erreicht seine eigene Closure. Mutation verifiziert: das
`!row.isDisabled`-Gate testweise entfernt (nur Execute/Insert/Preview ohne
Bedingung) ließ den deaktivierten-Zeile-Test rot schlagen (erwartet
`["Preview"]`, bekam `["Execute", "Insert", "Preview"]`); Gate
zurückgesetzt, wieder grün. Nebenbefund: `snippetPopover`'s eigener
Doku-Kommentar behauptete, „die Kontextmenü-Einträge" seien nicht
beobachtbar — das war seit dieser Fix-Runde nicht mehr wahr und wurde
korrigiert.

**Fix 2 (Stale-Hover-Zeile, MINOR).** `hoveredRow` wurde nicht geräumt,
wenn die Suche eine gerade gehoverte Zeile aus der Liste filtert —
`onHover`s `else`-Zweig feuert nur, wenn die Zeilen-View noch existiert,
und eine herausgefilterte Zeile bekommt diese Gelegenheit nie. Der lokale
`let sections = ...`-Block in `snippetPopover` wurde in eine private
Methode `filteredSections(text:isRegex:)` gezogen (gleiche Pipeline:
Suchprädikat → `TerminalSnippetSearch.matching` →
`SnippetMenuModel.build` → `SnippetListPlan.build`), damit eine zweite
Stelle — `clearHoveredRowIfFilteredOut()` — sie ohne Duplikation erneut
aufrufen kann. Zwei `.onChange`-Modifier (`searchText`, `searchIsRegex`)
rufen diese Methode; sie räumt `hoveredRow`, wenn dessen Zeile im neu
berechneten `sections` nicht mehr vorkommt. Bewusst KEIN zweites
State-Feld (z. B. ein „isStale"-Flag) — die Weisung war, am
Filterberechnungs-Ort selbst zu reparieren, nicht mit einem zweiten
State-Stück daneben.

**Zwei Proben vor dem Commit:**
- Würde ein neuer Test gegen eine Konstante grün bleiben? Nein für Fix 1:
  eine Attrappe, die immer alle drei Einträge zeigt, schlägt am
  Disabled-Test fehl; eine Attrappe, die immer nur Preview zeigt, schlägt
  am Enabled-Test fehl; No-Op-Closures schlagen am Wiring-Test fehl.
- Welche Behauptung im Doc-Kommentar beobachtet kein Test? Fix 2 komplett:
  das Räumen von `hoveredRow` bei Filterung ist SwiftUI-View-Zustand ohne
  Rendering-Harness — dieselbe, im Projekt bereits mehrfach dokumentierte
  Grenze wie bei `TerminalPanelHeader.body`, der Gesten-Aufteilung und der
  Zeilen-Selektionshervorhebung. `clearHoveredRowIfFilteredOut()`s
  Doc-Kommentar behauptet das Verhalten korrekt, aber ungeprüft.

**Messung:** Ausgangsstand 2097 Tests / 181 Suiten (selbst gemessen, deckt
sich mit dem Ledger). Nach Fix 1 (+3 Tests): 2100/181. Fix 2 fügt keine
Tests hinzu (Begründung oben). Endstand: **2100 Tests in 181 Suiten,
alle grün.**

Commits: siehe Ledger-Eintrag und Git-Log dieser Fix-Runde.
