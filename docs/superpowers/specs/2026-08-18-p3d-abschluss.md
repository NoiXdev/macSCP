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
