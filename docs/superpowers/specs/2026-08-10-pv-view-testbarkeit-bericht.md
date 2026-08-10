# Sind SwiftUI-Views in diesem Paket testbar? (Spike, 2026-08-10)

Ergebnis eines Arbeitsgangs. **Kein Produktionscode wurde geändert**, keine
Abhängigkeit hinzugefügt, `Package.swift` unverändert. Alle Zahlen unten sind
gemessen, nicht geschätzt.

## Kurzantwort

**Ja — mit `ImageRenderer` und ohne jede neue Abhängigkeit.** Und zwar
*unterscheidend*: derselbe View mit zwei verschiedenen Eingaben ergibt zwei
verschiedene Bitmaps, während dieselbe Eingabe zweimal pixelgleich rendert.

Empfehlungssatz steht am Ende.

## Schritt 1 — Ausgangslage

`Tests/macSCPAppKitTests/` enthielt neun Dateien, alle über **Nicht-View-Typen**:
`SessionTabTests`, `MenuBarStatusModelTests`, `UpdateAlertContentTests`,
`EditorResolverTests`, `ExternalTerminalLauncherTests`,
`KeyboardShortcutsCatalogTests`, `L10nTests`, `SnippetsPresentationTests`,
`TargetReachabilityTests`.

Gemessen mit `swift test --filter macSCPAppKitTests`:

```
Test run with 39 tests in 9 suites passed after 0.010 seconds.
```

Kein einziger dieser Tests fasst einen `View` an. Das ist die Lücke, um die es
geht.

## Schritt 2 — Der billigste Versuch: geht es ohne neue Abhängigkeit?

Neue Datei `Tests/macSCPAppKitTests/ViewTestabilitySpike.swift`, sieben Tests.

### 2.1 Instanziieren

`SheetSearchField` ist `internal`; das Testtarget nutzt ohnehin schon
`@testable import MacSCPAppKit`, also ist der Typ direkt sichtbar. Die
`@Binding`-Parameter werden mit `.constant(…)` befüllt. Compiliert und läuft.
Die gespeicherten Eigenschaften (`text`, `isRegex`, `errorText`) sind aus dem
Test lesbar — man kann also schon *ohne* Rendern behaupten, was in den View
hineingegangen ist.

### 2.2 `ImageRenderer` liefert ein Bild

`ImageRenderer(content:).cgImage` bei `scale = 2` und einem festen
`.frame(width: 420, height: 40)` ergibt reproduzierbar ein **840×80**-Bild,
268 800 Bytes RGBA. Nicht komplett transparent — es wurde tatsächlich gezeichnet.

Die Pixel werden über einen expliziten `CGContext` zurückgelesen, nicht über
einen PNG-Encoder; der Vergleich sieht damit Pixel und keine Container-Metadaten.

### 2.3 Der eigentliche Test: unterscheidet es?

Ja. Zwei Renderings desselben `SheetSearchField`, einmal ohne und einmal mit
`errorText` (plus umgeschaltetem Regex-Häkchen):

| Render | Größe | Fingerprint (FNV-1a über alle Pixel) |
|---|---|---|
| ohne Fehlertext | 840×80 | `71186a2f4b11fdad` |
| mit Fehlertext  | 840×80 | `7ef4c012bd35263d` |

Gleiche Maße, verschiedene Pixel. Gegenprobe (**Positivkontrolle**): dieselbe
Eingabe zweimal gerendert ergibt **byteweise identische** Bitmaps — das
Ergebnis oben ist also keine Renderer-Unruhe. Zusätzlich rot bewiesen: die
Zusicherung `!=` auf `==` gedreht ⇒ Test schlägt fehl. Die Behauptung trägt
also Last.

Ein zweiter, unabhängiger View (`PolishedButtonStyle`, `prominent` an/aus)
unterscheidet ebenfalls. Der Befund hängt also nicht an einem glücklichen View.

### 2.4 Die gemessene Grenze — AppKit-gestützte Controls rendern nicht mit

`SheetSearchField` mit `text: "a"` und mit
`text: "a very much longer needle to search for"` ergibt **dieselben Pixel**.
`TextField` ist AppKit-gestützt, und `ImageRenderer` zeichnet
`NSViewRepresentable`-Inhalte nicht. Das ist keine Vermutung, sondern
gemessen, und der Spike hält es als Test fest (`textFieldContentDoesNotReach…`);
kippt das Verhalten in einer künftigen macOS-Version, wird der Test rot und der
Kommentar korrigiert sich.

**Konsequenz für die Planung:** Pixelvergleiche taugen für alles, was aus
SwiftUI-Primitiven besteht (Text, Formen, Farben, Layout, `ButtonStyle`,
Sichtbarkeit von Zweigen). Für Inhalte in `TextField`, `Toggle`, `NSTableView`
& Co. taugen sie **nicht**. Für diese ist die Zusicherung über den
Eingabezustand (2.1) bzw. über den herausgezogenen Nicht-View-Typ der
richtige Ort — also genau das, was P0 ohnehin vorhat.

## Schritt 3 — Verträgt es sich mit Swift Testing?

Ja, ohne Einschränkung. Alles ist `@Test`/`#expect`/`#require`, kein
`XCTestCase`. `ImageRenderer` ist `@MainActor`, also trägt die Suite
`@MainActor` — das ist die einzige Anpassung. Die Suite ist zusätzlich
`.serialized`, weil eine der Messungen prozessweiten Zustand betrifft (`NSApp`).

```
✔ Test run with 7 tests in 1 suite passed after 0.191 seconds.
```

Eine praktische Warnung: ein fehlgeschlagener `#expect` auf einem rohen
`[UInt8]` schreibt hunderttausende Bytes ins Testprotokoll (beim Rot-Beweis
wurden es 1,9 MB). Der Spike kapselt die Pixel deshalb in einen `Bitmap`-Typ,
der vollständig vergleicht, aber nur einen kurzen Fingerprint *druckt*. Wer
Pixelvergleiche in P0 aufnimmt, muss das mitnehmen.

## Schritt 4 — Läuft es ohne GUI-Sitzung?

Teilweise beantwortet; die offene Hälfte ist benannt.

Gemessen, mit isolierten Einzelläufen (jeweils frischer Testprozess):

- In einem sauberen Testprozess ist `NSApp` **nil** — der Testrunner selbst
  legt keine `NSApplication` an.
- Rendern eines **reinen SwiftUI-Views** (Button + `PolishedButtonStyle`,
  ebenso ein blankes `Text`): Bild kommt heraus, `NSApp` bleibt **nil**.
- Rendern von `SheetSearchField` (enthält `TextField`/`Toggle`): Bild kommt
  heraus, danach ist `NSApp` **nicht mehr nil** — die AppKit-gestützten
  Controls ziehen die geteilte `NSApplication` hoch.

Kein Fenster, kein Runloop, kein Event nötig; kein Absturz, keine Ausnahme über
einen fehlenden Fensterserver, keine Verzögerung. Der komplette Spike läuft in
0,19 s.

**Was ich nicht messen konnte:** ob `NSApplication.shared` in einer Sitzung
*ohne* Fensterserver trägt. Der lokale Rechner läuft in einer angemeldeten
GUI-Sitzung; ein bootstrap-Namespace ohne Fensterserver (`launchctl bsexec 1`)
verlangt root, und passwortloses `sudo` steht hier nicht zur Verfügung. Das ist
die einzige verbleibende Unsicherheit.

Sie ist aber billig aufzulösen und **braucht keinen eigenen Task**: CI führt
bereits `swift test` auf `macos-15` aus (`.github/workflows/ci.yml`). Bleibt
`ViewTestabilitySpike.swift` im Baum, ist der nächste CI-Lauf die Messung. Wer
das Risiko ganz vermeiden will, hält sich an reine SwiftUI-Views — die brauchen
`NSApp` nachweislich nicht.

## Schritt 5 — Abhängigkeit prüfen

**Übersprungen, weil Schritt 2 getragen hat.** Es wurde keine Bibliothek
evaluiert und nichts zu `Package.swift` hinzugefügt. Kosten an Abhängigkeiten:
**null** — `SwiftUI`, `AppKit` und `CoreGraphics` sind Systemframeworks, die das
Testtarget über `MacSCPAppKit` ohnehin schon lädt.

## Die fünf Fragen, kurz

1. **Instanziieren?** Ja. `@testable import` genügt, `@Binding` über
   `.constant(…)`.
2. **Inhalt prüfbar — und unterscheidend?** Ja. 840×80,
   `71186a2f4b11fdad` vs. `7ef4c012bd35263d` bei gleicher Größe; identische
   Eingabe rendert byteweise gleich. Einschränkung: Inhalte AppKit-gestützter
   Controls erscheinen nicht im Bitmap.
3. **Swift Testing?** Ja, `@Test`/`#expect`, Suite `@MainActor` und
   `.serialized`.
4. **Ohne GUI-Sitzung?** Reine SwiftUI-Views: ja, ohne `NSApplication`.
   Views mit `TextField`/`Toggle`: laufen lokal, ziehen dabei aber `NSApp`
   hoch — für eine fensterserverlose Sitzung unbewiesen (siehe Schritt 4).
5. **Abhängigkeiten?** Keine.

## Wirkung auf die Suite

| | Tests | Suites | Dauer |
|---|---|---|---|
| vorher | 1756 | 144 | — |
| nachher | **1763** | **145** | 3,88 s gesamt, davon 0,19 s Spike |

Voller Lauf `swift test` grün, keine Störung anderer Tests durch die
hochgezogene `NSApplication`.

## Empfehlung

**View-Tests sind hier ohne Fremdcode machbar und lohnen sich für alles, was
aus SwiftUI-Primitiven besteht — für Inhalte AppKit-gestützter Controls
(`TextField`, `Toggle`, Tabellen) bleibt das Herausziehen in prüfbare
Nicht-View-Typen der einzige Weg, und genau dort lagen die drei Fehler des
letzten Meilensteins.**

`ViewTestabilitySpike.swift` bleibt im Baum: er ist der lauffähige
Beispieltest, kostet 0,19 s, und der nächste CI-Lauf beantwortet nebenbei die
offene Fensterserver-Frage.

## Anmerkungen zum Auftrag

Die Prosa des Briefs deckte sich mit dem Code; ein Punkt weicht ab:

- Der Brief nennt nur `Tests/…/ViewTestabilitySpike.swift`, `Package.swift` und
  den Bericht als berührte Dateien. `Package.swift` blieb unberührt, weil
  Schritt 5 entfiel — das Testtarget braucht keine Deklarationsänderung, um
  `SwiftUI`/`AppKit` zu sehen.
- Der Brief empfiehlt, mit „`NSImage` mit einer Größe größer null" zu prüfen.
  Das wäre genau die Prüfung, vor der er selbst warnt: `NSImage` mit Größe > 0
  bekäme man auch von einem leeren Bild. Der Spike prüft stattdessen die
  zurückgelesenen Pixel.
