# Backlog: Snippet-Editor — Variablen falten, Platzhalter vorschlagen

**Angelegt:** 2026-08-21, aus Maintainer-Sichtprüfung am gebauten Bundle.
Gesicherte Ideen, **kein Design**. Zwei Layout-Fehler aus derselben Sichtung
sind bereits behoben und stehen hier nur als Kontext.

## Bereits behoben (nicht Backlog)

- Der Variablen-Block war kein `FormRow` und stand darum am linken Rand,
  während Name, Kommando und Tags 120 pt eingerückt beginnen. Jetzt eine
  Zeile wie die anderen.
- Beide Hilfetexte hatten kein `fixedSize` und wurden bei 460 pt Sheet-Breite
  einzeilig abgeschnitten.

## 1. Variablen ein- und ausklappbar

Jede Variable soll für sich zusammenklappbar sein, und neben
„Variable hinzufügen" braucht es **Massenaktionen**: alle auf, alle zu.

Warum das drückt: eine Variablenzeile trägt heute Name, Art, Aufforderung,
Platzierung, Vorgabewert und das Merk-Kennzeichen — bei drei Variablen ist
das Formular länger als das Sheet. Der Editor ist auf 460 pt Breite fest,
also geht Platz nur nach unten.

Vor dem Entwurf zu entscheiden:

- **Was steht in der eingeklappten Zeile?** Sinnvoller Kandidat: Name,
  Art und Platzierung — genug, um die richtige wiederzufinden, ohne sie zu
  öffnen.
- **Was ist der Startzustand?** Eine neu hinzugefügte Variable muss offen
  sein, sonst tippt niemand hinein. Bestehende beim Öffnen des Editors
  vermutlich zu — das ist zu prüfen, nicht zu setzen.
- **Wird der Zustand gemerkt?** Wenn ja, gehört er in die Ansicht, nicht ins
  Modell — ein Faltzustand hat im `snippets.json` nichts verloren und darf
  erst recht nicht mit einem Export reisen.
- Eine Variable mit **Fehler** (ungültiger Name, doppelter Name) muss sich
  von selbst aufklappen oder im eingeklappten Zustand als fehlerhaft
  erkennbar sein. Sonst versteckt das Falten genau die Zeile, die Beachtung
  braucht.

## 2. Platzhalter im Kommandofeld vorschlagen

Gewünscht: der Editor erkennt beim Tippen die deklarierten Variablen und
schlägt sie vor — oder bietet einen Weg, sie einzufügen.

**Der Baustein ist schon da.** `SnippetCommandEditor` ist bereits ein
`NSTextView` (aus Teil 1, weil ein SwiftUI-`TextField` nicht während des
Tippens einfärben kann). Eine Vorschlagsliste an einem `NSTextView` ist ein
gelöstes Problem; an einem `TextField` wäre es keins gewesen.

Der natürliche Auslöser ist die öffnende Klammer: sobald `{{` getippt ist,
die deklarierten Namen anbieten. Das ist billig, weil die Liste im selben
Formular direkt darüber steht.

Vor dem Entwurf zu klären:

- **Vorschlagen, einfügen, oder beides?** Ein Menü am „+"-Knopf der
  Variablenzeile („in den Befehl einfügen") ist deutlich weniger Arbeit als
  eine Tipp-Vervollständigung und deckt den Fall ab, dass man den Namen
  nicht mehr weiß. Beides zusammen ist der Komfortfall.
- **Was passiert bei einer Variablen mit Platzierung „Umgebungsvariable"?**
  Die gehört gerade **nicht** als `{{NAME}}` in den Befehl — sie wird als
  Zuweisung vorangestellt. Eine Vervollständigung, die sie mit anbietet,
  führt zum genauen Gegenteil. Entweder nicht anbieten, oder als `$NAME`
  anbieten (siehe Fußangel unten).
- **Der umgekehrte Weg wäre wertvoller als der Komfort:** ein `{{NAME}}` im
  Befehl, das *nicht* deklariert ist, ist heute stumm — es bleibt als
  Literal stehen. Ein Hinweis darauf wäre der eigentliche Gewinn.

### Fußangel, die dabei sichtbar wird

Bei einer einzeiligen Zuweisung als Präfix expandiert die Shell `$NAME`,
**bevor** die Zuweisung greift — gemessen: `P=neu echo "$P"` gibt den alten
Wert aus. Wer also eine Umgebungsvariable per Vervollständigung als `$NAME`
in einen einzeiligen Befehl setzt, bekommt still das Falsche. Siehe
`2026-08-20-backlog-snippet-probelauf.md`, Abschnitt B2.

## Reihenfolge

1 zuerst — es ist das gemeldete Platzproblem und hängt an nichts. 2 danach,
und dort **zuerst der Einfüge-Weg** über das Variablen-Menü: er löst den
größten Teil des Bedarfs, ohne eine Vervollständigung samt ihrer Sonderfälle
zu bauen.
