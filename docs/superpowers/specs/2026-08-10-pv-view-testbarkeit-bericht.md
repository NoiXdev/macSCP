# Sind SwiftUI-Views in diesem Paket testbar? (Spike, 2026-08-10)

Ergebnis eines Arbeitsgangs. **Kein Produktionscode wurde geändert**, keine
Abhängigkeit hinzugefügt, `Package.swift` unverändert. Alle Zahlen unten sind
gemessen, nicht geschätzt.

## Kurzantwort

**Ja — mit `ImageRenderer` und ohne jede neue Abhängigkeit.** Und zwar
*unterscheidend*: derselbe View mit **genau einer** geänderten Eingabe ergibt
zwei verschiedene Bitmaps, während die erste Eingabe danach wieder pixelgleich
zurückkommt.

**Aber nur mit Methode.** `ImageRenderer` liefert für denselben View in den
ersten Renderings eines Prozesses *andere* Pixel als danach. Wer das nicht
ausräumt, bekommt Unterschiede, die nichts mit den Eingaben zu tun haben.
Siehe „Fixrunde 1" am Ende.

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

Ja — aber erst, nachdem zwei Störgrößen ausgeräumt sind. Beide sind in der
Fix-Runde vom selben Tag gefunden worden und stehen unter „Fixrunde 1" am Ende
dieses Dokuments ausführlich; hier das bereinigte Ergebnis.

Verglichen werden zwei Renderings desselben `SheetSearchField`, bei denen
**genau eine** Eingabe abweicht (`errorText`); `text` und `isRegex` bleiben
fest. Jedes Rendering wird erst nach drei verworfenen Aufwärm-Renderings
genommen (Begründung: Abschnitt „Fixrunde 1").

| Render (eingeschwungen) | Größe | Fingerprint (FNV-1a über alle Pixel) |
|---|---|---|
| `errorText: nil` | 840×80 | `7dc27e7c7c85d45c` |
| `errorText: "Invalid regular expression"` | 840×80 | `b4adf3924f8fdfc4` |
| `errorText: nil` (A/B/A-Kontrolle) | 840×80 | `7dc27e7c7c85d45c` |

Gleiche Maße, verschiedene Pixel, und die Wiederholung der ersten Eingabe
kommt **byteweise identisch** zurück. Rot bewiesen: `!=` auf `==` gedreht ⇒
Test schlägt fehl.

Die zweite Einzelvariable ist ebenfalls gemessen: nur `isRegex` umgeschaltet,
`errorText` fest ⇒ **identische Pixel** (`7dc27e7c7c85d45c` in beiden Fällen).
Das Regex-Häkchen trägt also nichts zum Bild bei — womit klar ist, dass der
Unterschied oben allein vom Fehlertext kommt.

Ein zweiter, unabhängiger View (`PolishedButtonStyle`, `prominent` an/aus,
ebenfalls Einzelvariable mit A/B/A-Kontrolle) unterscheidet ebenfalls
(`6ea7c7548e08687b` vs. `542f5bbbfda8f78`). Der Befund hängt also nicht an
einem glücklichen View.

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
2. **Inhalt prüfbar — und unterscheidend?** Ja, bei genau einer variierten
   Eingabe: 840×80, `7dc27e7c7c85d45c` (ohne Fehlertext) vs.
   `b4adf3924f8fdfc4` (mit), A/B/A-Kontrolle kommt auf `7dc27e7c7c85d45c`
   zurück. Zwei Einschränkungen: Inhalte AppKit-gestützter Controls erscheinen
   nicht im Bitmap, und Renderings müssen eingeschwungen sein (Fixrunde 1).
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
| nachher | **1763** | **145** | 4,35 s gesamt, davon 0,33 s Spike |

Voller Lauf `swift test` grün, keine Störung anderer Tests durch die
hochgezogene `NSApplication`.

## Empfehlung

**View-Tests sind hier ohne Fremdcode machbar und lohnen sich für alles, was
aus SwiftUI-Primitiven besteht — sofern jeder Pixelvergleich genau eine
Eingabe variiert, eingeschwungen rendert und seine A/B/A-Kontrolle mitführt;
für Inhalte AppKit-gestützter Controls (`TextField`, `Toggle`, Tabellen)
bleibt das Herausziehen in prüfbare Nicht-View-Typen der einzige Weg, und
genau dort lagen die drei Fehler des letzten Meilensteins.**

`ViewTestabilitySpike.swift` bleibt im Baum: er ist der lauffähige
Beispieltest, kostet 0,33 s, und der nächste CI-Lauf beantwortet nebenbei die
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

## Fixrunde 1 — zwei Störgrößen im Schaufensterbeispiel

Das Review hielt fest: der Vorzeige-Vergleich änderte **zwei** Eingaben
gleichzeitig (`isRegex` *und* `errorText`), während Tabelle und Text ihn als
Einzelvariable verkauften. Berechtigt. Beim Ausräumen fiel eine zweite, größere
Störgröße auf, von der niemand wusste.

### Störgröße 1 — die zweite Variable

Behoben: der Vergleich hält `text` und `isRegex` fest und variiert nur
`errorText`. Zusätzlich ist die andere Hälfte jetzt eigenständig gemessen —
nur `isRegex` umgeschaltet, `errorText` fest ⇒ **pixelgleich**. Das
Regex-Häkchen erreicht das Bitmap also gar nicht (wie der `TextField`-Inhalt,
Abschnitt 2.4), es war im alten Vergleich tatsächlich kein Faktor. Nur stand
das eben nirgends, und genau das war der Vorwurf.

### Störgröße 2 — `ImageRenderer` schwingt sich ein

Beim Nachmessen der Fingerprints ergab **dieselbe Eingabe** in zwei
verschiedenen Tests zwei verschiedene Werte. Ein Wegwerf-Probe-Test, der
denselben View mehrfach hintereinander rendert, zeigt die Ursache:

```
DRIFT off #0: 71186a2f4b11fdad      PURE prominent #0: 540076827d8d1edd
DRIFT off #1: 71186a2f4b11fdad      PURE prominent #1: 540076827d8d1edd
DRIFT off #2: 7dc27e7c7c85d45c      PURE prominent #2: 6ea7c7548e08687b
DRIFT off #3: 7dc27e7c7c85d45c      PURE prominent #3: 6ea7c7548e08687b
DRIFT off #4: 7dc27e7c7c85d45c      PURE prominent #4: 6ea7c7548e08687b
DRIFT off #5: 7dc27e7c7c85d45c
```

Die ersten Renderings eines Views liefern einen anderen Wert als alle
folgenden; danach ist es stabil. Das betrifft **auch reine SwiftUI-Views**
(rechte Spalte, ohne jede `NSApplication`), hat also nichts mit AppKit-Controls
oder dem Fensterserver zu tun. Es ist reproduzierbar: über mehrere
`swift test`-Läufe kommen exakt dieselben Zahlen heraus.

**Damit war die alte Tabelle in doppelter Hinsicht falsch.** Ihre beiden Werte
(`71186a2f4b11fdad`, `7ef4c012bd35263d`) sind *unaufgewärmte* Renderings. Der
alte Vorzeige-Vergleich hätte auch dann einen Unterschied gemeldet, wenn beide
Eingaben identisch gewesen wären — er verglich nebenbei Rendering Nr. 2 mit
Rendering Nr. 3.

### Die Methode, die trägt

Drei Regeln, alle gemessen, nicht geraten:

1. **Genau eine Eingabe variieren.**
2. **Eingeschwungen rendern**: drei Renderings verwerfen, das vierte nehmen
   (`renderSettled`).
3. **A/B/A-Kontrolle**: nach dem zweiten Rendering die erste Eingabe erneut
   rendern und Gleichheit fordern.

Regel 3 ist das Sicherheitsnetz für Regel 2: sie macht eine zu kurze
Aufwärmphase **rot statt still**. Gegenprobe, Aufwärmphase auf 0 gesetzt:

```
✘ Expectation failed: (withoutError → Bitmap(840x80, …, fingerprint 71186a2f4b11fdad))
  == (withoutErrorAgain → Bitmap(840x80, …, fingerprint 7dc27e7c7c85d45c))
```

Genau der alte, unaufgewärmte Wert — die Kontrolle fängt den Fehler, den der
erste Anlauf gemacht hat.

### Folge für P0

Die Antwort auf die Ausgangsfrage bleibt **ja**; die Empfehlung oben ist um die
Methode ergänzt. Wer in P0 Pixelvergleiche schreibt, übernimmt die drei Regeln
— sonst produziert er Tests, die aus dem Renderer-Aufwärmen Bedeutung lesen.
Das ist ein Argument mehr dafür, Logik in Nicht-View-Typen herauszuziehen und
Pixelvergleiche sparsam einzusetzen.
