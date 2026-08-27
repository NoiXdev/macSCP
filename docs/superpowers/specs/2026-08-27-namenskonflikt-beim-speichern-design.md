# Namenskonflikt beim Speichern — Entwurf

**Stand:** 2026-08-27. Umsetzung von **I5** aus der Abschlussprüfung des
Tab-Kontextmenüs.

---

## Der gemessene Ausgangszustand

`SessionListViewModel.save(name:…)` sucht eine vorhandene Sitzung **über den
Namen** und ändert sie an Ort und Stelle, statt eine neue anzulegen. Das ist
Absicht und im Quelltext begründet — es trägt Gruppe und Login-Set-Bindung
weiter, und der Kommentar hält sogar fest, dass ein Namenstreffer über
Protokollgrenzen hinweg die vorhandene Sitzung **konvertiert**.

**Dieses Upsert ist nicht das Problem und wird nicht angefasst.** Wo der Nutzer
den Namen tippt, ist es stimmig: wer einen vorhandenen Namen einträgt, meint
diese Sitzung.

Das Problem ist, dass der Name nicht immer getippt wird. `saveName` wird an
drei Stellen vorbefüllt:

| Stelle | Woher | Gefahr |
|---|---|---|
| Sitzung bearbeiten | `stored.name` | keine — das **ist** diese Sitzung |
| „Als Sitzung speichern" | `tab.displayTitle` | **ja**, seit heute |
| ssh-config-Import | `host.alias` | **ja, und schon länger** |

Und es gibt **nirgends** eine Namenskonflikt-Warnung für Sitzungen; das einzige
Vorbild im Projekt ist die Dublettenprüfung der Snippet-Variablen.

Zusammen heißt das: zwei Wege setzen einen Namen ein, den der Nutzer nie
getippt hat, und nichts sagt ihm, dass dieser Name bereits vergeben ist. Trifft
er, wird die fremde Sitzung samt Gruppe, Tags, Login-Set, Jump-Spezifikation
und Keychain-Geheimnis ersetzt.

## Entscheidung des Maintainers (2026-08-27)

**Warnen und den automatischen Namen entschärfen.** Beides, nicht eines davon.

### 1. Das Formular warnt

Trifft der eingetragene Name eine vorhandene Sitzung, sagt das Formular es —
sichtbar, bevor gespeichert wird, und benennt die Sitzung, die ersetzt würde.

**Es blockiert nicht.** Das Upsert bleibt erreichbar; wer eine vorhandene
Sitzung aktualisieren will, soll das weiterhin können. Die Warnung stellt
Sichtbarkeit her, nicht eine Hürde.

**Die bearbeitete Sitzung ist ausgenommen.** `ConnectionViewModel.mode` ist
`FormMode.edit(sessionID: UUID)` im Bearbeiten-Fall — trifft der Name genau
diese ID, ist das kein Konflikt, sondern der Normalfall. Ohne diese Ausnahme
würde jedes Bearbeiten einer gespeicherten Sitzung warnen, sie ersetze sich
selbst; eine Warnung, die immer erscheint, wird nach zwei Tagen nicht mehr
gelesen.

### 2. Ein vorbefüllter Name weicht aus

Setzt **macSCP selbst** einen Namen ein und der ist vergeben, wird nicht dieser
gesetzt, sondern der nächste freie. Betrifft ausschließlich die beiden Wege,
die einen Namen erfinden — „Als Sitzung speichern" und den ssh-config-Import.

**Was der Nutzer tippt, wird nie verändert.** Ein Vorschlag darf ausweichen,
eine Eingabe nicht: eine App, die getippten Text still umschreibt, ist
schlimmer als eine, die überschreibt, weil man ihr danach beim Tippen nicht
mehr zusehen mag.

Die Regel muss ein prüfbarer Wert in Core sein, kein Einzeiler an zwei
Aufrufstellen — sonst weichen die beiden Wege irgendwann verschieden aus.
Offen und beim Umsetzen zu entscheiden, mit Test je Fall:

- Wie der freie Name gebildet wird (ein angehängter Zähler ist das Naheliegende).
- Was passiert, wenn auch der belegt ist — also dass die Regel wirklich sucht
  statt einmal zu raten.
- Wie mit einem Namen umgegangen wird, der bereits auf einen Zähler endet.
- Ob Groß-/Kleinschreibung zählt. **Das ist die Frage mit der Falle:** `save`
  vergleicht mit `==`, also exakt. Weicht die Vorbefüllung nach anderen Regeln
  aus als `save` vergleicht, entsteht genau der Fall, den dieser Vorgang
  beseitigen soll — ein Name, der „frei" aussieht und trotzdem trifft, oder
  umgekehrt ein Ausweichen ohne Konflikt. **Die Ausweich-Regel muss denselben
  Vergleich benutzen wie `save`.**

## Was das nicht ist

- **Keine Änderung an `save`.** Das Upsert über den Namen bleibt.
- **Kein Blockieren.** Speichern auf einen vorhandenen Namen bleibt möglich.
- **Kein Umbenennen von Bestehendem.** Nur der Vorschlag weicht aus.
- **Keine Eindeutigkeitsregel im Store.** Zwei Sitzungen dürfen weiterhin
  denselben Namen tragen, wenn sie anders dorthin gelangt sind (Import,
  Bearbeiten) — dieser Vorgang macht das nur nicht mehr aus Versehen.

## Was kein Test dieses Projekts sehen kann

Prüfbar ist alles: die Ausweich-Regel ist ein Wert in Core, und ob die Warnung
bei einem gegebenen Zustand erscheinen soll, ebenfalls.

**Nicht prüfbar** ist, dass die Warnung im laufenden Formular tatsächlich
erscheint und lesbar steht. Das bleibt ein Blick des Maintainers.
