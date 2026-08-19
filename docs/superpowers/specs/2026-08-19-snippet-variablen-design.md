# Snippet-Editor Teil 3 — deklarierte Variablen (Design)

**Stand:** 2026-08-19, freigegeben. Setzt auf Teil 1 (Einfärbung) und Teil 2
(mehrzeilig) auf, beide abgeschlossen und sichtgeprüft. Löst den Backlog-Eintrag
`2026-08-19-backlog-snippet-teil-3.md` ab, der ausdrücklich als gesicherte Idee
und nicht als Design geführt wurde.

## Ausgangslage

Ein Snippet ist heute ein fester Befehlstext. Wiederkehrende Abläufe — ein
Datenbank-Export, ein Log einsammeln — unterscheiden sich zwischen zwei Läufen
oft in genau einem Wert.

Der Kern des Auftrags, in den Worten des Maintainers: **man soll die Variablen
nicht im Text suchen müssen.** Die Alternative — den Befehl nach Platzhaltern
absuchen und daraus ein Formular bauen — macht den Befehlstext zur Quelle der
Wahrheit über etwas, das der Nutzer nirgends zusammenhängend sieht. Eine
Deklaration ist sichtbar, sortierbar und kommentierbar.

## Entscheidungen

Fünf, alle vom Maintainer:

1. **Beide Einsetzwege, pro Variable wählbar** — Platzhalter im Text oder
   vorangestellte Umgebungszuweisung.
2. **Kein Kennzeichen „erweitert"** — eine leere Deklarationsliste ist bereits
   die Aussage „keine Variablen".
3. **Das Protokoll bekommt die Vorlage, nicht die Werte.**
4. **Zwei Arten:** Freitext und Auswahl aus einer Liste, je mit optionalem
   Vorgabewert.
5. **Merken ist ein Häkchen an der Deklaration, standardmäßig aus.**

### Zu (1): eine bewusste Abweichung von der Empfehlung

Ich hatte zu **einem** Weg geraten und begründet, dass zwei Mechanismen zwei
Fehlerbilder und zwei Testmatrizen bedeuten. Der Maintainer hat sich für beide
entschieden; das ist notiert, nicht ausgeführt.

Die Gegenmaßnahme steht im Design: es gibt **eine** Deklaration mit einem
`placement`-Feld und **eine** Einsetzfunktion, die beide Fälle bedient. Die
Testmatrix läuft über die Platzierung, statt sich zu verdoppeln. Wo das
Verhalten sich unterscheidet — und es unterscheidet sich —, steht es an einer
Stelle.

### Zu (5): warum das Häkchen nötig wurde

Die ursprüngliche Wahl war eine dritte Variablen**art** „zuletzt benutzter
Wert". Das kollidierte mit Entscheidung (3): das Protokoll bekommt keine Werte,
damit ein versehentlich eingetipptes Passwort nicht in einer Datei landet — und
ein gemerkter Wert läge in derselben JSON-Ablage, nur in einer anderen Datei.

Nach dem Hinweis fiel die Entscheidung auf ein **Opt-in an der Deklaration**,
standardmäßig aus. Damit fällt die Wahl, bevor ein Wert existiert, und sie hat
dieselbe Form wie (3): sicher als Vorgabe, Bequemlichkeit als bewusste Wahl.

Nebenbei kollabierte damit die dritte Art zu einer Eigenschaft. Es bleiben zwei
Arten und zwei unabhängige Eigenschaften (Vorgabewert, Merken) — weniger
Maschinerie, als die Frage nahelegte.

## Modell

`Snippet` bekommt `variables: [SnippetVariable]` mit Vorgabe `[]`; alte Stores
lesen sich ohne Migration, weil ein fehlender Schlüssel als leere Liste
dekodiert (dasselbe Muster, mit dem `tags` eingeführt wurde).

Eine Deklaration trägt:

| Feld | Bedeutung |
|---|---|
| `name` | der Bezeichner, z. B. `DBNAME` |
| `prompt` | Beschriftung im Abfrage-Sheet |
| `kind` | `.freeText` oder `.selection([String])` |
| `placement` | `.placeholder` oder `.environment` |
| `defaultValue` | Vorbelegung, darf leer sein |
| `remembersLastValue` | Häkchen, Vorgabe `false` |

**Namensregel, für beide Platzierungen gleich:** `[A-Za-z_][A-Za-z0-9_]*`. Für
die Umgebung ist das Pflicht, weil daraus eine Shell-Zuweisung wird; für den
Platzhalter ist es nicht nötig, aber zwei Regeln für dasselbe Feld wären eine
Fehlerquelle ohne Gegenwert. Namen sind innerhalb eines Snippets eindeutig.

### Gemerkte Werte liegen nicht im Snippet

Sie kommen in eine eigene, kleine JSON-Ablage neben `snippets.json`,
adressiert über Snippet-ID und Variablenname — **im Klartext, nicht
verschlüsselt**, wie jede andere Nicht-Geheimnis-Ablage dieses Projekts. Genau
deshalb ist das Merken ein bewusstes Opt-in und keine Vorgabe. Zwei Gründe für
die eigene Ablage, beide zwingend:

- Ein Snippet, das sich beim Ausführen selbst ändert, ist kein
  Vorlagen-Datensatz mehr — jeder Lauf wäre eine Store-Schreibung am Snippet.
- **Der Export dürfte die Werte nicht mittragen.** Läge der letzte Wert im
  Snippet, wanderte er in jede exportierte Datei und in jede Weitergabe.

Deklarationen wandern mit dem Export, gemerkte Werte nie.

**Verwaiste Einträge.** Wird ein Snippet gelöscht, bleiben seine gemerkten
Werte sonst liegen. Das Löschen räumt sie mit — dieselbe Kopplung, die das
Löschen einer Sitzung mit ihrem Keychain-Eintrag hat. Ein Eintrag zu einer
Snippet-ID, die es nicht mehr gibt, wird beim Laden verworfen.

## Einsetzen

Eine reine Funktion in Core: Vorlage plus Werte rein, aufgelöster Befehl raus —
oder eine Abweisung.

### Platzhalter

`{{DBNAME}}` im Befehl wird durch den Wert ersetzt, gequotet über die
vorhandene `SSHCommandBuilder.posixSingleQuote`-Primitive (einfache
Anführungszeichen, eingebettetes `'` als `'\''`). Die Primitive existiert, wird
bereits mit einem Wert samt eingebettetem Anführungszeichen getestet und wird
für diese Verwendung sichtbar gemacht statt nachgebaut.

**Nur deklarierte Namen werden ersetzt.** Das ist nicht bloß eine
Sparsamkeitsregel, sondern die Auflösung einer echten Kollision:

```
kubectl get pods -o go-template='{{range .items}}{{.metadata.name}}{{end}}'
```

Doppelte geschweifte Klammern kommen in realen Befehlen vor. `range .items` ist
keine deklarierte Variable und bleibt wörtlich stehen. Es braucht deshalb weder
einen eigenen Dialekt noch eine Escape-Regel.

### Umgebung

`$DBNAME` im Befehl, und macSCP stellt die Zuweisung voran:

- **einzeilig:** `DBNAME='kunden db' mysqldump …` — die Zuweisung gilt nur für
  diesen einen Befehl.
- **mehrzeilig:** `DBNAME='kunden db'` als eigene erste Zeile, danach der
  Rumpf.

Die zweite Form hat einen **echten Seiteneffekt**: die Variable bleibt nach dem
Lauf in der Sitzung gesetzt. Das gehört sichtbar in den Hinweistext des
Editors, nicht in eine Fußnote — wer `$PATH` als Variablennamen wählt, soll
vorher wissen, was passiert.

Mehrere Zuweisungen stehen in Deklarationsreihenfolge.

## Zwei Abweisungen, beim Speichern

Beide sind reine, testbare Prüfungen und beide feuern im Editor, nicht beim
Ausführen — eine Überraschung auf einem fremden Host ist teurer als eine im
eigenen Formular.

1. **Platzhalter-Deklaration ohne Verwendung.** Eine Variable mit
   `placement == .placeholder`, deren `{{NAME}}` im Befehl nicht vorkommt,
   würde abgefragt und käme nirgends an.

   **Nur für Platzhalter.** Für die Umgebungsplatzierung darf es diese Prüfung
   nicht geben: dort ist der häufigste und beabsichtigte Fall gerade der, dass
   `$NAME` im Befehl **nicht** steht — `DBNAME='x' ./backup.sh` setzt die
   Variable für ein Skript, das sie selbst liest. Eine Prüfung auf `$NAME`
   würde genau die natürliche Verwendung abweisen. (Im Selbstreview dieser
   Spec stand die Prüfung zunächst für beide Platzierungen; das war falsch.)
2. **Platzhalter innerhalb von Anführungszeichen.** `echo "{{DBNAME}}"` ergäbe
   `echo "'wert'"` — die Quotes würden sichtbar. Die Erkennung, ob eine
   Position in einfachen oder doppelten Anführungszeichen liegt, ist dieselbe
   Zustandsmaschine, die `SnippetHighlighter` aus Teil 1 bereits durchläuft, um
   Zeichenketten einzufärben. Ob der Code geteilt oder nur die Regel geteilt
   wird, entscheidet die Umsetzung am Bestand.

## Das Protokoll ändert sich nicht

`SnippetAuditDetail.text(for:)` liest `snippet.command` — und das **ist** die
Vorlage. Entscheidung (3) kostet damit keine Zeile Code; sie beschreibt den
Zustand, der eintritt, wenn niemand etwas dagegen unternimmt.

Genau deshalb bekommt sie einen **Test**: eine Regel, die gratis ist, wird
beim nächsten Umbau gratis gebrochen. Der Test hält fest, dass der Wert einer
Variablen im Protokolltext nicht vorkommt.

## Ablauf beim Auslösen

Auslösen → hat das Snippet Deklarationen, erscheint ein Abfrage-Sheet mit einem
Feld je Variable, vorbelegt aus gemerktem Wert, sonst aus dem Vorgabewert →
**Abbrechen sendet nichts** → Bestätigen löst auf, merkt sich die angehakten
Werte, und ab da läuft der Weg aus Teil 2 unverändert weiter: der aufgelöste
Befehl geht in `SnippetSendPlanner`, der über den Bracketed-Paste-Modus
entscheidet.

Ein Snippet ohne Deklarationen nimmt den heutigen Weg ohne Sheet.

## Tests

**Das Einsetzen, vollständig:** beide Platzierungen, je einzeilig und
mehrzeilig; Werte mit Leerzeichen, einfachem Anführungszeichen, `$`,
Backslash und einer Zeichenkette, die selbst wie ein Platzhalter aussieht.

**Die Nicht-Ersetzung:** ein `{{…}}`, das keiner Deklaration entspricht, bleibt
unangetastet — mit dem `go-template`-Befehl oben als Testfall, wörtlich.

**Beide Abweisungen**, je mit einem Fall, der sie auslöst, und einem, der sie
nicht auslöst.

**Die Namensregel**, mit einem Namen, der als Shell-Zuweisung ungültig wäre.

**Das Protokoll**, siehe oben.

**Konstant-Rückgabe-Probe:** eine Einsetzfunktion, die den Befehl unverändert
zurückgibt, muss an mindestens der Hälfte dieser Fälle scheitern; eine, die
jeden Wert ungequotet einsetzt, muss an den Werten mit Sonderzeichen scheitern.

## Was ungeprüft bleibt

Das Abfrage-Sheet selbst und der Variablen-Abschnitt im Editor: kein Test
dieses Projekts zeichnet SwiftUI-Ansichten. **Sichtprüfung beim Maintainer**,
und das gehört so in den Abschlussbericht — Teil 1 und Teil 2 haben beide
gezeigt, dass in dieser Schicht weder die grüne Suite noch das Review reicht.

## Nicht in diesem Teil

- **Ein `type`-Marker am Snippet** (`shell`, perspektivisch `telnet`). Der
  Tokenizer aus Teil 1 nimmt die Sprache bereits als Parameter und speichert
  sie ausdrücklich nicht; dieser Marker wäre der Ort, an dem sie herkäme. Es
  gibt aber noch keine zweite Sitzungsart, für die er etwas entscheiden würde.
- **Variablen in Namen oder Tags** eines Snippets. Nur der Befehl.
- **Verkettete Variablen** (eine Variable, deren Vorgabewert eine andere
  einsetzt). Weder gefragt noch nötig.
