# P4 — Kommentar-Wahrheitsaudit (Pilot)

**Anlass:** In fünf Phasen hintereinander (P2, P3a, P3c, P3e, P3f, P3h) hat
die Gesamtprüfung Kommentare gefunden, die etwas behaupten, das der Code
nicht tut. Immer dieselbe Sorte: Aussagen über **Aufrufer**, über
**Aufrufstellen**, über **Einzigkeit**.

## Messung

38 % der Zeilen in `Sources/` sind Kommentar (16.183 von 42.880). 5.558
Kommentarzeilen nennen einen anderen Bezeichner in Backticks; 331 behaupten
etwas über Aufrufer oder Einzigkeit. Das Suchmuster war zu eng — in zwei der
drei Pilotdateien fand der Prüfer mehr, als es geschätzt hatte (39 statt 28,
42 statt 17). Die 331 sind eine Untergrenze.

## Pilot über drei Dateien

| Datei | Zuletzt umgebaut | Behauptungen | falsch |
|---|---|---|---|
| `SessionListViewModel` | M24, seither still | 34 | **0** |
| `ContentView` | diese Woche mehrfach | 42 | **8** |
| `ConnectionViewModel` | laufend, M22 → P3g | 39 | **9** |
| **Summe** | | **115** | **17 (15 %)** |

**Kommentare verrotten nicht mit dem Alter, sondern mit der Bewegung des
Codes, den sie beschreiben.** Die seit einem Meilenstein unveränderte Datei
war fehlerfrei, die beiden laufend umgebauten lagen bei rund einem Fünftel.

Alle 17 Falschstellen folgen demselben Mechanismus: eine Extraktion, eine
Umbenennung oder ein neuer Aufrufer verändert die Wahrheit über eine
*andere* Datei — und der Kommentar dort taucht in keinem Diff auf. Zwei
Belege:

- `buildJumpConfig()` sagte „only caller is `connect()`". Das wurde falsch,
  als P3c `resolveConfigWithoutDialing()` herauszog und einen zweiten
  Aufrufer schuf — in derselben Woche, durch dieselbe Hand.
- Die Umbenennung `connectStored` → `connect(in:stored:)` (`2153a47`) zog
  die Kommentare in ihrer Nähe mit, die zwei entfernteren derselben Datei
  nicht.

## Der eigentliche Befund: die Korrekturrunden

| Runde | Änderungen | davon falsch |
|---|---|---|
| Korrektur der 17 Befunde | 17 | 3 neu falsch + 3 angrenzende übersehen |
| Nachbesserung dieser 6 | 6 | 4 falsch |
| Dritte Runde über diese 4 | 4 | 1 falsch |
| Vierte Runde über diese 1 | 1 | 0 — bestätigt |

Eine Korrekturrunde produziert dieselbe Fehlerquote wie das Problem, das
sie behebt. Sie macht denselben Fehler wie der Entwickler, der Code
verschiebt: **sie prüft, was sie anfasst, nicht, was davon abhängt.**

Der Gegenleser hat das Muster über alle Runden isoliert:

> **Jeder einzelne Folgefehler saß in einer Zahl oder einer Aufzählung.
> Prosa ohne Kardinalität blieb fehlerfrei.**

Runde 1: drei Zähl-/Listenfehler. Runde 2: zwei Zählfehler plus eine falsch
adressierte Liste (der Absatz *neben* dem beanstandeten wurde geändert, die
falsche Aufrufer-Liste blieb stehen — mit Vollzugsmeldung). Runde 3: wieder
eine Zahl. Der letzte Fehler ist das Musterbeispiel: der Grep, der den
dritten Aufrufer auflistete, stand beim Schreiben von „two paths" bereits
auf dem Schirm.

Der Grund liegt nahe. „Drei Aufrufstellen" ist eine Behauptung über den
Rest des Projekts, die beim Schreiben plausibel klingt und nur durch
Nachzählen widerlegbar ist. Ein Satz über die Absicht einer Stelle lässt
sich dagegen aus der Stelle selbst beurteilen.

## Ergebnis

17 falsche Behauptungen korrigiert, über vier Runden mit unabhängigem
Gegenlesen nach jeder. Über den gesamten Durchgang wurden **null
Nicht-Kommentarzeilen** geändert (mechanisch geprüft). Suite unverändert
grün, 2139 Tests in 188 Suiten.

## Was NICHT gemacht wird

**Kein Rundumschlag über die restlichen ~216 Behauptungen** in den 94
kleineren Dateien. Bei 0 % Fehlern in der stillen Datei und dieser
Fehlerquote pro Korrekturrunde wäre der erwartete Schaden größer als der
Nutzen. Sie gehören geprüft, wenn die jeweilige Datei ohnehin umgebaut
wird — dann ist der Kontext da, in dem sich Wahrheit beurteilen lässt.

**Kein CI-Wächter gegen tote Namen**, jedenfalls nicht in der zuerst
angedachten Form. Eine Messung zeigte, dass die auffälligen Kandidaten
(`SSHKeysSettingsTab`, `TransferViewModel`) **absichtliche historische
Verweise** sind — „removed in M18/T6" ist wahr, nicht faul. Mechanisch ist
das nicht von einer vergessenen Umbenennung zu trennen; ein solcher Wächter
hätte eine hohe Falsch-Positiv-Rate und würde nach der dritten Ausnahme
abgeschaltet.
