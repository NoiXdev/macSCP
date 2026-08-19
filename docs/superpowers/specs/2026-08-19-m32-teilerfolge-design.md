# M32 — Teilerfolge, die trotzdem löschen (Design)

Stand 2026-08-19. Aus dem geerbten Backlog, nach einer Messung neu
zugeschnitten.

## Die Messung, die den Schnitt bestimmt hat

Der Backlog führte fünf technische Punkte. Nachgemessen am Branch:

| Punkt | Stand |
|---|---|
| `applyMerge` liest mit `try?` und löscht trotzdem | **erledigt** in M28/T2 — der Lesevorgang wirft, mit ausführlicher Begründung im Code. Die Notiz war veraltet. |
| Jump-Bindung, dieselbe Bauart | **nicht gefunden** — die Bindestellen schreiben mit `try`, nicht `try?` |
| `applyMerge`-Rewire-Schleife | **echt**, siehe unten |
| Waisen aus der Schlüssel-Erzeugung | **erledigt** — der `catch` um `store.add` entfernt beide Dateien und wirft den ursprünglichen Fehler weiter. Beim ersten Schreiben dieser Spec falsch als offen geführt, weil nur die Reihenfolge der Aufrufe gelesen wurde, nicht ihr `catch`. |
| Testsuite-Hänger | nicht auf Zuruf lösbar (280 Läufe ohne Reproduktion); Werkzeug liegt bereit |

Ein Backlog-Eintrag ist derselbe Fall wie ein Kommentar: eine Behauptung mit
Verfallsdatum. **Drei von fünf waren abgelaufen** — der dritte fiel erst
beim Planschreiben auf, nachdem diese Spec ihn bereits als offen geführt
hatte. Die Lehre gilt also auch für diese Spec selbst: eine Reihenfolge von
Aufrufen zu lesen ist keine Messung, solange der `catch` daneben ungelesen
bleibt.

## Die eine echte Fundstelle

### `applyMerge` — kostet ein Zugangsdatum

```swift
for session in groupSessions {
    var updated = session
    updated.loginSetID = set.id
    try? store.upsert(updated)
    try? secrets.deletePassword(for: session.id)
}
```

Scheitert der Store-Write, behält die Sitzung `loginSetID == nil` — sie holt
ihr Geheimnis also weiter aus dem eigenen Slot — und genau dieser Slot wird
in derselben Iteration gelöscht. Die Sitzung steht danach ohne jedes
Zugangsdatum da.

Das ist als Verhalten dokumentiert, nicht als Befund: der Doc-Kommentar sagt
wörtlich „both are `try?`, so a store-write failure for one session does not
stop that session's secret from being deleted." Es war gesehen und
hingenommen.

## Die Regel

**Ein Schritt, der etwas wegnimmt, läuft nur, wenn der Schritt, der seinen
Ersatz schafft, nachweislich geglückt ist.**

- **`applyMerge`:** `try? store.upsert` wird zu `do/catch`. Scheitert der
  Write, wird der Slot dieser Sitzung **nicht** gelöscht; sie behält
  Geheimnis und Un-Bindung und bleibt damit funktionsfähig. Die Schleife
  läuft für die übrigen Mitglieder weiter — ein Fehlschlag bei einem
  Mitglied darf die anderen nicht mit sich reißen —, und am Ende sagt eine
  Meldung, dass Sitzungen nicht umgehängt wurden und ihr eigenes Passwort
  behalten haben. **Ohne Anzahl:** Plurale brauchen `.stringsdict`, das es
  nur in `MacSCPAppKit` gibt, während diese Meldung in Cores Katalog liegt —
  eine Zahl wäre hier Plural-Infrastruktur für einen Satz. Der Rückgabewert
  bleibt das erzeugte Set: es existiert, und die geglückten Mitglieder
  zeigen darauf.
Die Schlüssel-Erzeugung erfüllt diese Regel bereits und bleibt unberührt;
ihr `catch` ist das Muster, dem `applyMerge` folgt.

## Tests

**`applyMerge`.** Der Fehlschlag wird nicht simuliert, sondern **erzeugt**:
das Sitzungsverzeichnis wird schreibgeschützt gesetzt, sodass `upsert`
wirklich scheitert. Kein Test-Seam, den es nur für diesen Test gäbe — und
der Test beweist damit auch, dass ein unbeschreibbares Verzeichnis
tatsächlich zu einem Fehler führt, statt das anzunehmen.

- Bei fehlgeschlagenem Write behält die Sitzung ihr Geheimnis.
- **Positivkontrolle:** ohne Schreibschutz wird das Geheimnis sehr wohl
  gelöscht und die Sitzung zeigt aufs Set. Ohne diesen zweiten Test bliebe
  der erste auch dann grün, wenn `applyMerge` gar nichts mehr löscht.

## Was nicht dazugehört

- **Schaden 1 aus M30** — der eigene Slot einer Sitzung, die an ein Set
  gebunden **ist**. Andere Bauart: kein Fehlschlag beteiligt, sondern eine
  Aufräumfrage. Eigener Durchgang.
- **Der app-weite Audit-Bereich.** Nach M31 ist die Ad-hoc-Hälfte gelöst;
  der Rest ist eine bewusste Nicht-Entscheidung (M27), kein Defekt.
- **Der Testsuite-Hänger.** Bleibt entschärft und dokumentiert.
