# Snippet-Probelauf und der Ausstieg pro Snippet — Entwurf

**Stand:** 2026-08-30. Umsetzung von
`docs/superpowers/specs/2026-08-20-backlog-snippet-probelauf.md`.

---

## Entscheidungen des Maintainers (2026-08-30)

1. **Beides**: der Probelauf *und* das Kennzeichen am einzelnen Snippet.
2. **Zwei Zugänge**: der Weg beim Auslösen einer Ablehnung, **und** ein
   „Testen"-Knopf im Editor.

Aus dem Zweck ergibt sich die dritte Antwort ohne Rückfrage: **gemerkte
Werte werden angezeigt.** Der Probelauf zeigt, was tatsächlich gesendet
würde; zeigte er etwas anderes als den eingesetzten Wert, wäre er in genau
der Rolle unehrlich, für die er gebaut wird.

## Der gemessene Ausgangszustand

| | |
|---|---|
| `SnippetSendPlan` | `.send([UInt8])` / `.refusedMultilineInsert` |
| Platzhalter-Ablehnung | zweiter, getrennter Mechanismus (`SnippetCommandSurvey`) |
| `SnippetHighlighter` | vorhanden, von der Prüfung strukturell abgeschnitten |
| `SnippetVariable.remembersLastValue` | vorhanden, mit `SnippetVariableMemoryStore` |
| **`SnippetExportPayload`** | trägt **`[Snippet]`** — denselben Typ wie der Store |

**Die letzte Zeile ist der Befund, der diesen Entwurf bestimmt.** Bei
Sitzungen sind `ExportedGroup` und `ExportedSession` eigene Typen; bei
Snippets ist der ausgeführte Typ der gespeicherte. Ein neues Feld an
`Snippet` reist damit **von selbst** durch Export und Import.

## Die Grenze, ohne die B das Gegenteil bewirkt

Der Eintrag formuliert die Auflage als Regel:

> **Ein importiertes Snippet kommt immer mit eingeschalteter Prüfung an.**

Als Aufräumregel im Import-Planer wäre das eine Zeile, die jemand beim
nächsten Umbau vergisst — und ihr Vergessen wäre unsichtbar, weil ein
Snippet mit abgeschalteter Prüfung genauso aussieht wie eines ohne.

**Deshalb bekommt der Export einen eigenen Typ**, nach dem Vorbild der
Sitzungen: `ExportedSnippet` trägt die Felder, die geteilt gehören, und das
Kennzeichen ist **keines davon**. Ein Import kann es dann nicht setzen —
nicht weil ein Test es verbietet, sondern weil es die Datei nicht ausdrücken
kann.

Das ist dieselbe Fähigkeitsgrenze, die diese Woche den Wählvorgang und den
unbegrenzten SFTP-Schluss geschlossen hat, und aus demselben Grund: eine
Regel, die der Compiler trägt, veraltet nicht still.

## Der Probelauf

### Was er zeigt

- Den **aufgelösten Befehl**, wie er auf die Leitung geht — nicht die
  Vorlage.
- Das Ergebnis des **Sendeplans**: einzeilig, geklammert eingefügt,
  zeilenweise ausgeführt, oder abgelehnt. Bei einem mehrzeiligen Snippet ohne
  Klammerungsmodus entscheidet das über etwas anderes als der Wortlaut.
- **Syntaxfärbung** über `SnippetHighlighter`. Ein eingeschleustes `$(…)`
  fällt gefärbt sofort auf.
- Bei einer Ablehnung: **den Grund**, und darunter „trotzdem senden".

### Was er ist

Ein **prüfbarer Wert** in Core, der aus Snippet, Werten und Sendeplan die
Anzeige beschreibt — nicht eine Ansicht, die selbst zusammensetzt. Beide
Zugänge zeigen damit dasselbe, statt zweimal ähnlich.

### Die Auflage, die er nicht verletzen darf

Der eingesetzte Wert erscheint auf dem Bildschirm dessen, der ihn getippt
hat — das ist in Ordnung. **Er darf von dort nicht ins Audit-Log, in einen
Export oder in eine Fehlermeldung wandern.** Das Audit-Log führt die
Vorlage, und dabei bleibt es.

Das ist keine Stilfrage: es ist dieselbe Zusage, die dieses Projekt für
Geheimnisse hält, angewandt auf einen Wert, der ein Geheimnis sein kann.

### Der Fall, den er sichtbar machen soll

Aus dem Eintrag, gemessen gegen `bash`: bei einer **einzeiligen** Zuweisung
als Präfix expandiert die Shell `$P` **bevor** die Zuweisung greift.

```
P=neu echo "$P"     →  alt
```

Wer als Ausweg für ein abgelehntes `[ -f {{PATH}} ]` ein `P='…' [ -f "$P" ]`
schreibt, bekommt still den alten oder gar keinen Wert. Der Probelauf zeigt
den aufgelösten Text, und wer ihn liest, sieht es — heute merkt man es erst
am falschen Ergebnis auf der Gegenseite.

## Das Kennzeichen am Snippet

Ein Feld an `Snippet`, das die Positionsprüfung für **dieses** Snippet
abschaltet. Es wirkt nur dort, wo jemand es bewusst gesetzt hat.

- **Es reist nicht.** Siehe oben — `ExportedSnippet` kennt es nicht.
- **Es ist sichtbar**, wo das Snippet bearbeitet wird, und benennt, was es
  abschaltet. „Prüfung aus" ohne Gegenstand wäre ein Schalter, dessen Wirkung
  man erst am Schaden lernt.
- **Es schaltet die Platzhalter-Positionsprüfung ab, sonst nichts.** Der
  Sendeplan und seine Ablehnung eines mehrzeiligen Einfügens bleiben
  unberührt — das ist eine andere Frage und keine, die jemand pro Snippet
  beantworten sollte.

## Der „Testen"-Knopf im Editor

Zeigt denselben Probelauf, ohne zu senden.

**Er braucht Werte für die Platzhalter**, und damit einen zweiten Ort, an dem
Platzhalterwerte entstehen. Der Entwurf legt fest: er benutzt **dieselbe
Abfrage** wie das Auslösen, mit denselben gemerkten Werten. Eine zweite
Abfrageform wäre eine zweite Wahrheit darüber, was ein Wert ist.

**Nichts wird gesendet und nichts gemerkt**, was der Probelauf im Editor
erfragt: eine Probe darf den nächsten echten Lauf nicht vorbelegen.

## Was kein Test dieses Projekts sehen kann

Prüfbar ist alles Entscheidbare: was die Anzeige beschreibt, dass beide
Zugänge dieselbe beschreiben, dass das Kennzeichen nur die Positionsprüfung
abschaltet, dass ein importiertes Snippet es nie trägt, und dass der
eingesetzte Wert in keinem Protokoll und keiner Fehlermeldung auftaucht.

**Nicht prüfbar** bleibt, ob die Färbung eine eingeschleuste Konstruktion für
einen Menschen tatsächlich auffällig macht. Das ist der Zweck der Anzeige und
der einzige Teil, den nur ein Blick beurteilt.

## Was ausdrücklich nicht dazugehört

- **Kein globaler Schalter** in den Einstellungen.
- **Keine Änderung an `SnippetCommandSurvey`** selbst — die Erlaubnisliste
  bleibt, wie acht Prüfrunden sie hinterlassen haben.
- **Keine Änderung an `SnippetSendPlan`s** Ablehnung eines mehrzeiligen
  Einfügens.
- **Kein Merken von Werten aus dem Editor-Probelauf.**
