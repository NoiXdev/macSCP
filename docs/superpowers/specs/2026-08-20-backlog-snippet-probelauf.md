# Backlog: Snippet-Probelauf und der Ausstieg aus der Prüfung

**Angelegt:** 2026-08-20, aus Maintainer-Zuruf. Gesicherte Ideen, **kein Design**.
Zwei Wünsche, die zusammengehören — und meines Erachtens zu **einer** Sache
werden sollten.

## Ausgangslage

Nach acht Prüfrunden ist das Tor eine Erlaubnisliste: ein `{{PLATZHALTER}}`
wird nur aufgelöst, wenn `SnippetCommandSurvey` seine Stelle positiv als
oberstes, unquotiertes Argument erkennt und der Befehlsname nicht zu den
Namen gehört, bei denen eine Shell den Wert erneut als Code liest. Die
Haltung ist die Vereinigung über bash 3.2/4.4/5.x und zsh — **wenn irgendeine
plausible Shell den Wert aufhebt, wird abgelehnt.**

Bewusst in Kauf genommener Preis (Maintainer, 2026-08-20):

```
[ -f {{PATH}} ]          abgelehnt
printf '%s' {{X}}        abgelehnt
export FOO={{VALUE}}     abgelehnt
```

Das sind gewöhnliche Formen. Es ist absehbar, dass sie jemand vermisst — daher
die beiden Wünsche unten.

## A. Probelauf: zeigen, was tatsächlich gesendet würde

Vor dem Senden anzeigen, wie der fertige Befehl aussieht. Das ist mehr als
Bequemlichkeit: es macht eine eingeschleuste Konstruktion **sichtbar**, statt
sie zu einer Vertrauensfrage zu machen.

Was die Anzeige umfassen muss, damit sie die Wahrheit sagt:

- Den **aufgelösten Befehl** mit eingesetzten Werten, so wie er auf die
  Leitung geht — nicht die Vorlage.
- Das Ergebnis des **Sendeplans** (`SnippetSendPlan`), nicht nur den Text:
  einzeilig, geklammert eingefügt, zeilenweise ausgeführt, oder abgelehnt.
  Bei einem mehrzeiligen Snippet ohne Klammerungsmodus entscheidet das über
  etwas ganz anderes als der Wortlaut.
- **Syntaxfärbung.** `SnippetHighlighter` existiert bereits und ist von der
  Prüfung strukturell abgeschnitten — Anzeige ist genau seine Aufgabe. Ein
  eingeschleustes `$(…)` fällt gefärbt sofort auf.

**Auflage:** der eingesetzte Wert erscheint auf dem Bildschirm dessen, der ihn
getippt hat — das ist in Ordnung. Er darf von dort **nicht** ins Audit-Log,
in einen Export oder in eine Fehlermeldung wandern. Das Audit-Log führt die
Vorlage, und dabei bleibt es.

## B. Ausstieg pro Snippet (Maintainer-Präzisierung, 2026-08-20)

Nicht ein Schalter in den Einstellungen, sondern ein **Kennzeichen am
einzelnen Snippet**. Das ist die deutlich bessere Form: es wirkt nur dort, wo
jemand es bewusst gesetzt hat, statt für alles zu gelten, was danach noch
importiert wird.

**Eine Auflage, ohne die es das Gegenteil bewirkt:** das Kennzeichen ist
Daten und reist damit durch Export und Import. `SnippetImportPlanner` trägt
seit dieser Runde die Deklarationen mit — trüge er auch dieses Kennzeichen,
könnte ein geteiltes Snippet **mit bereits abgeschalteter Prüfung**
ankommen. Das ist genau die Lieferketten-Form, gegen die der ganze Zweig
gebaut ist.

> **Ein importiertes Snippet kommt immer mit eingeschalteter Prüfung an.**
> Das Kennzeichen wird beim Import verworfen, nicht übernommen; wer es
> will, setzt es selbst — nachdem er den Befehl gelesen hat.

## B2. Der andere Weg: Werte als Umgebung übergeben

Statt `{{PLATZHALTER}}` die Platzierung `.environment` benutzen. Der Wert
geht dann als Zuweisung mit und wird nie in den Befehlstext eingesetzt — die
Positionsprüfung stellt sich damit gar nicht.

**Das trägt, aber nicht überall.** Gemessen gegen `bash`:

| Form | Ergebnis |
|---|---|
| `P=neu ./skript.sh` — Programm liest selbst | Skript sieht `neu` |
| mehrzeilig, Zuweisung als eigene Zeile | `[neu]` |
| `P=neu echo "$P"` — Befehlstext nennt `$P` | **`alt`** bzw. leer |

Die dritte Zeile ist die Falle: bei einer **einzeiligen** Zuweisung als
Präfix expandiert die Shell `$P` **bevor** die Zuweisung greift. Wer als
Ausweg für ein abgelehntes `[ -f {{PATH}} ]` ein `P='…' [ -f "$P" ]`
schreibt, bekommt still den alten oder gar keinen Wert.

Der Code trifft die Unterscheidung bereits richtig: bei mehrzeiligem Rumpf
wird die Zuweisung eine **eigene Zeile** (sonst gölte sie nur für die erste),
und dort greift sie wie erwartet. Der Präfix-Fall bleibt.

**Folge für den Probelauf:** genau das ist ein Fall, den er sichtbar machen
soll. Der aufgelöste Text zeigt `P=neu echo "$P"`, und wer ihn liest, sieht
das Problem — heute merkt man es erst am falschen Ergebnis auf der
Gegenseite.

## Der Vorschlag: A **ist** der Ausstieg, nicht B

A liefert die Evidenz, die B voraussetzt. Statt eines Schalters, der die
Prüfung dauerhaft entfernt:

> Wird ein Snippet abgelehnt, zeigt der Probelauf den Befehl **so, wie er
> aufgelöst würde**, gefärbt, mit dem Grund der Ablehnung — und darunter
> „trotzdem senden".

Das ist dieselbe Freiheit, aber **pro Auslösung statt dauerhaft**, und mit dem
tatsächlichen Text vor Augen statt auf Zusicherung. Wer `[ -f {{PATH}} ]`
braucht, bekommt es; wer ein importiertes Snippet auslöst, sieht das `$(…)`,
bevor es läuft.

Zu entscheiden, wenn es an den Entwurf geht:

1. Reicht das, oder soll es den dauerhaften Schalter **zusätzlich** geben?
2. Ist der Probelauf ein eigener Knopf im Snippet-Editor („Testen"), der Weg
   beim Auslösen, oder beides?
3. Was passiert bei mehreren Platzhaltern und `remembersLastValue` — zeigt
   der Probelauf gemerkte Werte, oder verlangt er neue Eingabe?

## Reihenfolge

A zuerst und allein. Wenn A steht, lässt sich B ehrlich beantworten — dann
weiß man, ob der Schalter noch fehlt oder nur die Ablehnung ohne Ausweg das
Problem war.
