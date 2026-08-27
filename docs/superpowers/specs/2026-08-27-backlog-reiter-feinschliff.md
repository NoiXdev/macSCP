# Backlog: Feinschliff an den Reitern

**Status:** offen
**Aufgenommen:** 2026-08-27, Maintainer, nach der Prüfung des Tab-Kontextmenüs
und des Umordnens per Ziehen in der laufenden App.

Zwei Punkte. Sie sehen beide klein aus; einer ist es, der andere landet auf
einer Naht, die der Quelltext ausdrücklich offengelassen hat.

---

## A. Sichtbare Einfügemarke beim Ziehen

**Gewünscht:** beim Ziehen eines Reiters sehen, **wo** er landet.

Der Vorbehalt stand schon im Bericht der Umsetzung („keine Wurf-Rückmeldung am
Ziel, bewusst weggelassen, lohnt als eigener Bedienpunkt") — jetzt ist er
bestätigt: ohne Rückmeldung zieht man blind.

**Der gemessene Ausgangszustand:** `TabStripView` benutzt
`.draggable(tab.id.uuidString)` und `.dropDestination(for: String.self)`
**ohne** den `isTargeted:`-Zweig. SwiftUI liefert die Rückmeldung also
kostenlos mit, sie wird nur nicht abgefragt.

**Die Entscheidung, die vorher fällt — und sie ist nicht kosmetisch.** Der Wurf
zielt heute **auf einen Reiter**, nicht zwischen zwei. Das ist kein Zufall: die
Positionsrechnung wurde in der letzten Runde aus der Ansicht **entfernt**, weil
drei Wächter-Runden lang jede Arithmetik darauf eine neue Schreibweise fand,
mit der man sie verfälschen konnte. `TabsViewModel` leitet die Zielposition
seit `19a8420` selbst aus den beiden Identitäten ab.

Daraus folgen zwei Wege mit sehr verschiedenem Preis:

| Weg | Preis |
|---|---|
| **Zielreiter hervorheben** (`isTargeted`) | Entspricht der Semantik exakt: „hierauf lässt du los". Keine Geometrie, keine Position, kein Rückschritt. Billig. |
| **Einfügestrich zwischen zwei Reitern** | Verspricht eine Einfügestelle, die das Modell nicht kennt — und braucht dafür Wurfpunkt-Geometrie in der Ansicht, also genau das, was gerade strukturell beseitigt wurde. |

**Empfehlung:** der erste Weg. Wer den zweiten will, entscheidet damit auch,
die Positionsrechnung in die Ansicht zurückzuholen — das gehört benannt, nicht
nebenbei getan.

---

## B. Umschalten zwischen Terminal und Dateien

**Gewünscht:** bei einer Verbindung mit Terminal aus dem Reiter-Menü heraus
umschalten — Terminal einblenden bzw. Dateibrowser einblenden, **je nachdem,
was gerade aktiv ist**.

**Der gemessene Ausgangszustand:** Der Eintrag heißt „Terminal öffnen" und ist
**einseitig**. `openTerminalPane` blendet nur ein und kehrt sofort zurück,
wenn das Terminal schon sichtbar ist. Zurück zum Dateibrowser führt aus diesem
Menü kein Weg.

### Die Naht, auf der das landet

`PaneVisibility` trägt `showsFiles` und `showsTerminal` und hält als Invariante,
dass **nie beide Hälften gleichzeitig unsichtbar** sein können — der
Initialisierer repariert das auf „Dateien gewinnen". Sein eigener Doc-Kommentar
sagt aber:

> Dieser Typ entscheidet nur, WELCHE Hälften sichtbar sind. Er sagt nichts über
> `TerminalPanelViewModel.isVisible`, den bestehenden Terminal-Umschalter —
> **die beiden in Einklang zu bringen ist die Entscheidung einer späteren
> Aufgabe.**

Es gibt also **zwei Wahrheiten** über „ist das Terminal sichtbar", und dieser
Wunsch ist die erste Anforderung, die beide gleichzeitig lesen muss: um zu
entscheiden, ob der Eintrag „Terminal einblenden" oder „Dateien einblenden"
heißt, muss feststehen, welche der beiden gilt.

**Das ist der eigentliche Inhalt dieses Punktes.** Ein Menüeintrag, der die
falsche der beiden Quellen liest, zeigt gelegentlich die falsche Beschriftung —
und das ist schlimmer als ein fehlender Eintrag, weil man ihm dann nicht mehr
glaubt.

### Vor dem Angehen zu klären

1. **Welche Quelle gewinnt?** Erst zusammenführen, dann beschriften. Es gibt
   bereits `PaneVisibility.applyingClick(on:hasShell:)` — dort steckt schon ein
   Modell dafür, was ein Klick auf eine Hälfte bedeutet.
2. **Ein Eintrag oder zwei?** „Terminal einblenden" / „Dateien einblenden" als
   ein Eintrag mit wechselnder Beschriftung, oder zwei Einträge, von denen einer
   fehlt? Die bestehenden Menüeinträge dieses Reiters folgen der Regel
   *„erscheint nicht, wenn er nicht anwendbar ist"* statt auszugrauen.
3. **Beide gleichzeitig?** `PaneVisibility` erlaubt, dass beide Hälften sichtbar
   sind. Ein reiner Umschalter kann diesen Zustand nicht ausdrücken — er müsste
   ihn entweder verlassen oder anbieten.
4. **Was ist mit `terminalTarget`?** Die Werkzeugleiste und ⌘T folgen der
   Einstellung „eingebaut oder externes Terminal"; der Menüeintrag tut es nicht
   (offener Punkt I4 aus der Abschlussprüfung desselben Vorgangs). Wer diesen
   Punkt angeht, sollte I4 im selben Zug entscheiden — sonst haben drei Wege zum
   Terminal zwei verschiedene Bedeutungen.

---

## Zuschnitt

**A und B nicht zusammen bauen.** A ist eine Ansichtsänderung ohne Modellanteil
und in einem Zug erledigt. B ist zuerst eine Entscheidung über zwei
konkurrierende Zustandsquellen und erst danach ein Menüeintrag; es gehört mit
I4 zusammen, nicht mit A.
