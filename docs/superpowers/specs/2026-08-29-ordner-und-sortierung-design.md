# Verschachtelte Ordner und freie Sortierung — Entwurf

**Stand:** 2026-08-29. Umsetzung von **D1 + D2** aus
`docs/superpowers/specs/2026-08-20-backlog-sitzungen-tabs-seitenleiste.md`,
dort ausdrücklich als **ein** Vorgang geführt.

---

## Warum zusammen

`StoredGroup` trägt heute **nur `id` und `name`**. Weder Verschachtelung noch
Reihenfolge lassen sich ohne neue Felder ausdrücken. Getrennt gebaut ändert
sich das Speicherformat zweimal, und jede Änderung zieht
`SessionExportCodec` und den Import-Planer mit.

## Der gemessene Ausgangszustand

| | heute |
|---|---|
| `StoredGroup` | `id`, `name` — sonst nichts |
| Zuordnung Sitzung → Ordner | `StoredSession.groupID: UUID?` |
| Ordner auflösen | `SessionStore.dissolveGroup(id:)` — Ordner weg, seine Sitzungen auf `groupID = nil` |
| Reihenfolge | keine; die Anzeige sortiert selbst |
| Format | `sessions-v2.json`; die pre-M23-Datei `sessions.json` bleibt als Rückschritt-Momentaufnahme liegen |
| Export | `SessionExportCodec` mit eigenem `ExportedGroup` |

## Entscheidungen des Maintainers (2026-08-29)

### 1. Additiv in `sessions-v2.json`, kein neuer Dateiname

Neue **optionale** Felder in die bestehende Datei. Eine ältere Fassung liest
sie weiter, weil `JSONDecoder` unbekannte Schlüssel überspringt — und
**verliert Verschachtelung und Reihenfolge, sobald sie selbst schreibt.**

Das ist der Preis, und er wird hier benannt statt entdeckt: der Verlust ist
**Ordnung, nie eine Sitzung**. Namen, Hosts, Ordnerzugehörigkeit und
Zugangsdaten bleiben unberührt; nur wer wo einsortiert war, ist danach flach.

Der Unterschied zu M23, das genau deshalb den Dateinamen wechselte: dort
brach die ausgelieferte Fassung am fehlenden `host` **ab**. Ein
Datenverlust gegen ein kaputtes Lesen — das ist nicht derselbe Fall.

### 2. Die Reihenfolge ist eine Ganzzahl am Element

`StoredGroup` und `StoredSession` tragen je eine Position, beim Schreiben
durchnummeriert.

**Nicht die Array-Reihenfolge der Datei.** `SessionListViewModel.save` sucht
eine vorhandene Sitzung über den **Namen** und ändert sie an Ort und Stelle;
Import und Filter bauen die Liste ohnehin neu auf. Eine Reihenfolge, die in
der Array-Position steckt, hinge an einer Codepfad-Eigenschaft, die niemand
zugesichert hat und kein Test bemerkt, wenn sie kippt.

**Und keine eigene Reihenfolgeliste.** Eine Liste von Kennungen neben den
Elementen wäre eine zweite Wahrheit, die auseinanderläuft — dieselbe
Fehlerklasse, die dieses Projekt bei doppelten Namen bereits bezahlt hat.

### 3. Beliebig tief, über `parentID`

`StoredGroup.parentID: UUID?`. Keine künstliche Grenze.

Der Preis ist eine **Zyklenprüfung**: ein Ordner darf nicht sein eigener
Vorfahre werden. Die gehört als reiner Wert nach Core, prüfbar ohne
Oberfläche — und sie muss auch den Import abdecken, wo eine fremde Datei
einen Zyklus mitbringen kann.

## Der Entwurf

### Auflösen verallgemeinert, was es schon tut

`dissolveGroup` hebt heute die Sitzungen eines Ordners auf `groupID = nil` —
für einen Ordner der obersten Ebene ist das **eine Ebene hoch**.

Verschachtelt gilt dieselbe Regel wörtlich: Sitzungen *und* Unterordner
wandern zum **Elternteil** des aufgelösten Ordners. Keine neue Semantik, nur
dieselbe fortgeschrieben. Nichts wird mitgelöscht.

### Ziehen leitet sein Ziel aus Identitäten ab, nie aus einem Index

Das Reiter-Umordnen dieser Woche hat die Form bereits: `move(tabID:to:)` und
`move(tabID:onto:)`. Der Grund war kein Geschmack — der Index in der Ansicht
**war** die Fehlerklasse, und ihn zu entfernen hat sie geschlossen.

Hier trägt dieselbe Form beides:

| Geste | Wirkung |
|---|---|
| zwischen zwei Geschwister ziehen | umordnen |
| auf einen Ordner ziehen | hineinverschieben, ans Ende |

Beide Wege enden in **einer** Kernfunktion, die aus zwei Identitäten eine
neue Ordnung errechnet. Die Ansicht rechnet nichts.

### Einmaliges Sortieren pro Ordner

Ein Kontextmenü-Eintrag am Ordner, der seine unmittelbaren Unterelemente
**einmalig** nach Namen ordnet und die Positionen neu schreibt.

Ausdrücklich **kein Dauerzustand**: es gibt keine gespeicherte
Sortier-Einstellung pro Ordner, nur eine Aktion, die die freie Ordnung
überschreibt. Zum Aufräumen, nicht als Modus. Wirkt nur eine Ebene tief —
alles andere wäre eine Massenänderung hinter einem Menüpunkt.

### Export und Import ziehen mit

`SessionExportCodec` und der Import-Planer tragen `parentID` und die
Positionen. Beide müssen mit einer Datei umgehen, die sie **nicht** trägt —
eine ältere Ausfuhr — und mit einer, die einen **Zyklus** oder einen
**fehlenden Elternteil** mitbringt.

Die Regel für beide Schäden ist dieselbe und folgt der Hausregel „additiv,
nie zerstörend": ein Ordner, dessen Elternteil fehlt oder einen Zyklus
schlösse, landet auf der obersten Ebene. **Nichts wird verworfen**, und der
Import meldet, was er begradigt hat.

## Was kein Test dieses Projekts sehen kann

Prüfbar ist alles Entscheidbare: die Zyklenprüfung, das Verallgemeinern des
Auflösens, die Ordnungsberechnung aus zwei Identitäten, das einmalige
Sortieren, und dass Ausfuhr und Einfuhr die neuen Felder tragen und beschädigte
überstehen.

**Nicht prüfbar** bleibt, dass sich der Baum in der laufenden Seitenleiste
angenehm ziehen lässt. Das bleibt ein Blick des Maintainers.

## Was ausdrücklich nicht dazugehört

- **Keine gespeicherte Sortier-Einstellung pro Ordner.** Nur die einmalige
  Aktion.
- **Kein neuer Dateiname**, keine zweite Datei, kein Versionsschlüssel.
- **Keine Änderung an `SessionListViewModel.save`** und seinem Upsert über
  den Namen.
- **Kein Löschen von Sitzungen beim Auflösen eines Ordners** — heute nicht,
  verschachtelt erst recht nicht.
- Keine Suche im Baum (D3). Sie kommt nach diesem Vorgang, weil die
  Verschachtelung ihre Darstellung mitbestimmt.
