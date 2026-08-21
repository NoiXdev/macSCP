# Backlog: Verbindungszustand, Tabs, Seitenleiste, Tags

**Angelegt:** 2026-08-20, aus Maintainer-Zuruf. Elf Punkte, gesicherte Ideen,
**kein Design**. Der Ist-Zustand unten ist am Code gemessen, nicht vermutet.

---

## A. Verbindungszustand

### A1. Zeitüberschreitung sichtbar machen

Statt einer toten Ansicht: eine Fehlerdarstellung im Tab, verständlich
formuliert, mit **„Erneut verbinden"**. Im Tab-Reiter ein Warnsymbol, und ein
grünes Symbol, solange alles steht.

Was das voraussetzt: ein **Verbindungszustand am Tab**, den es heute nicht
gibt. `SessionTab` trägt Sitzung und Panes; „verbunden / gestört / getrennt"
ist kein Wert, den jemand ablesen könnte. Vor dem Entwurf zu klären: woran
merkt macSCP den Abriss überhaupt — am fehlgeschlagenen nächsten Aufruf, oder
aktiv (siehe A2)? Ohne A2 erfährt die App den Abriss erst, wenn der Nutzer
etwas tut, und das Warnsymbol käme immer zu spät.

### A2. Keep-alive

**Es gibt heute keins** — kein Treffer auf `keepalive` oder
`ServerAliveInterval` im ganzen Quellbaum. Regelmäßige Lebenszeichen, damit
Sitzung und Tunnel nicht wegbrechen, als Einstellung mit Intervall.

Vor dem Entwurf zu prüfen: auf welcher Ebene das geht. SSH kennt ein
Keep-alive auf Transportebene; ob Citadel/NIOSSH das anbietet oder ob es ein
harmloser Kanal-Verkehr sein muss, ist **Machbarkeit und gehört gemessen**,
bevor eine Einstellung dafür entworfen wird. Für Jump-Hosts gilt die Frage
doppelt.

**A2 vor A1.** A2 ist das, was den Abriss überhaupt bemerkt; A1 ist, wie er
aussieht.

---

## B. Tabs

### B1. Kontextmenü am Reiter

Schließen, bei Ad-hoc-Verbindungen **als Sitzung speichern**, nach links /
nach rechts schieben. `TabStripView.swift` hat heute **kein** `contextMenu`.

### B2. Reihenfolge per Ziehen

Ebenfalls nichts vorhanden — kein `onMove`, kein `draggable` in den
Tab-Dateien. B1s „nach links / nach rechts" und B2 sind dieselbe zugrunde
liegende Fähigkeit (Tabs umordnen), nur zwei Bedienwege. **Zusammen bauen**,
sonst entsteht die Umordnung zweimal.

---

## C. Sitzung starten

### C1. Einfachklick soll nicht verbinden

Gemessen: `SessionSidebar.swift` hängt am Zeilentipp `onSelect()`, und
`ContentView+Detail.swift` reicht das an `connectFromSidebar(stored)` weiter
— **ein Klick baut heute eine Verbindung auf.** Gewünscht: Auswahl beim
Einfachklick, Verbindung erst beim Doppelklick.

Erfreulich: das Kontextmenü derselben Zeile hat bereits einen Eintrag
**„Verbinden"**. Der Weg geht also nicht verloren, wenn der Tipp zur Auswahl
wird. Das ist der kleinste Punkt der ganzen Liste.

### C2. Sitzung ist schon offen

Beim Starten einer bereits offenen Sitzung fragen: **neu öffnen** oder **zur
bestehenden springen**. Zu entscheiden: merkt sich macSCP die Antwort
(„nicht mehr fragen"), und was zählt als „dieselbe" — dieselbe gespeicherte
Sitzung, oder auch dasselbe Ziel über eine Ad-hoc-Verbindung?

---

## D. Seitenleiste

### D1. Verschachtelte Ordner + D2. Freie Sortierung — **ein Vorgang**

`StoredGroup` trägt heute **nur `id` und `name`**. Kein Elternteil, keine
Reihenfolge. Beides — Verschachtelung *und* freie Sortierung — braucht neue
Felder im Sitzungs-Store.

**Deshalb gehören sie zusammen.** Getrennt gebaut ändert sich das
Speicherformat zweimal, und jede Änderung zieht `SessionExportCodec` und den
Import-Planer mit. Projektregel: Migrationen additiv, nie zerstörend.

Dazu gehört D2s zweiter Teil: ein Kontextmenü **pro Ordner**, das seine
Unterelemente einmalig sortiert (nach Name o. Ä.) — zum schnellen Aufräumen,
nicht als Dauerzustand.

### D3. Suche im Sitzungsbaum

In der Seitenleiste gibt es **keine Suche** (kein `searchText`,
kein `SheetSearchField`). Der Baustein existiert aber schon aus M18 und wird
in vier Verwaltungs-Sheets benutzt; hier wäre er wiederzuverwenden statt neu
zu bauen. Offen: filtert die Suche den Baum, oder hebt sie Treffer hervor —
bei verschachtelten Ordnern (D1) ist das ein Unterschied.

### D4. Breite verändern und merken

Gemessen: `ContentView+Detail.swift` klemmt die Seitenleiste auf
`minWidth: 170, idealWidth: 190, maxWidth: 260`. Die **Obergrenze 260** ist
der Grund, warum sie sich nicht nach rechts ziehen lässt, und persistiert
wird nichts. Zu tun: Klammer lösen und die Breite im `SettingsStore` ablegen.

---

## E. Tags

### E1. Tag-Suche abschaltbar

Über die Einstellungen ausblendbar, weil sie nicht jedem gefällt. Zu
entscheiden: verschwindet nur die Anzeige, oder auch die Zuweisung von Tags?

### E2. Filter-Beutel statt Leiste

Ab mehr als einer Handvoll Tags soll die Auswahl zu einem Filter zusammen-
klappen, den man in einem Dialog zusammenstellt. Vor dem Entwurf zu
entscheiden: **ab wie vielen** kippt die Darstellung, und ist der Filter eine
Und- oder eine Oder-Verknüpfung — heute setzt die Leiste eine einzelne
Auswahl (`selection = tag`), was die Frage bisher nicht stellte.

E1 und E2 berühren dieselbe Stelle in der Seitenleiste und sollten zusammen
entworfen werden.

---

## Reihenfolge

1. **C1** — kleinster Eingriff, größte tägliche Wirkung, Kontextmenü-Weg
   existiert bereits.
2. **D4** — eine Klammer und ein Store-Feld.
3. **A2 → A1** — erst bemerken, dann anzeigen.
4. **B1 + B2** — zusammen, eine Fähigkeit.
5. **C2** — unabhängig, jederzeit.
6. **D1 + D2** — zusammen, der teuerste Punkt: Formatmigration mit Export und
   Import im Schlepptau.
7. **D3** — nach D1, weil Verschachtelung die Suchdarstellung mitbestimmt.
8. **E1 + E2** — zusammen.
