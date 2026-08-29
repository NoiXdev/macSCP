# Suche im Sitzungsbaum — Entwurf

**Stand:** 2026-08-29. Umsetzung von **D3** aus
`docs/superpowers/specs/2026-08-20-backlog-sitzungen-tabs-seitenleiste.md`.
D3 hat ausdrücklich auf D1 gewartet, weil die Verschachtelung die
Darstellung mitbestimmt — und tatsächlich stellt sie die Frage anders, als
der Eintrag sie stellte.

---

## Der gemessene Ausgangszustand

**Die Seitenleiste hat keine Suche.** Kein `searchText`, kein Suchfeld.

Zwei Bausteine liegen aber schon da, und beide sind der Grund, warum dieser
Vorgang klein ist:

- **`SheetSearchField`** aus M18, benutzt in vier Verwaltungs-Sheets. Es
  bringt einen **Regex-Schalter** und eine Fehleranzeige für einen ungültigen
  Ausdruck mit.
- **`SidebarVisibility`**, seit D1+D2 baumweise: es filtert heute rein auf
  `StoredSession.tags` und hält einen Ordner am Leben, wenn **irgendetwas
  darunter** passt — von jedem Treffer aufwärts über
  `GroupTree.selfAndAncestors`.

Die zweite Hälfte ist die eigentliche Nachricht: **die Filterregel für einen
Baum existiert bereits und ist geprüft.** Eine Textsuche ist dieselbe Regel
mit einem zweiten Kriterium, kein zweiter Filterweg.

## Warum „filtern oder hervorheben" nicht mehr die Frage ist

Der Eintrag lässt beides offen. Nach D1+D2 ist Filtern nahezu geschenkt und
Hervorheben wäre neue Maschinerie — ein zweiter Begriff neben „sichtbar",
mit eigenen Zuständen.

Die Verschachtelung stellt dafür eine neue Frage, die der Eintrag nicht haben
konnte: **ein Treffer in einem zugeklappten Ordner ist gefiltert und trotzdem
unsichtbar.**

## Entscheidung des Maintainers (2026-08-29)

**Während der Suche wird aufgeklappt.** Steht etwas im Suchfeld, zeigt die
Seitenleiste den gefilterten Baum offen — sonst filtert man auf etwas, das
man nicht sieht.

**Der Zuklapp-Zustand des Nutzers bleibt unangetastet** und kehrt zurück,
sobald das Feld leer ist. Die Suche *überlagert* ihn, sie überschreibt ihn
nicht. Das ist die Bedingung, unter der diese Entscheidung tragbar ist: eine
Suche, die die Ordner des Nutzers dauerhaft aufklappt, hat seine Ordnung
verändert, ohne dass er das wollte.

## Der Entwurf

### Ein Kriterium mehr in derselben Regel

`SidebarVisibility.compute` bekommt den Suchbegriff zusätzlich zum
Tag-Filter. Beide gelten **zusammen**: wer nach einem Tag filtert und dann
tippt, sucht innerhalb des Gefilterten. Alles andere wäre überraschend, und
zwei Filter, die einander aufheben, sind schwer zu erklären.

Die Vorfahren-Regel bleibt unverändert und gilt für den neuen Fall genauso —
sie ist der Grund, warum ein Treffer in der Tiefe seinen Weg nach oben
behält.

### Wonach gesucht wird

**Name, Host, Benutzername und Tags** einer Sitzung. Das ist, was ein Nutzer
tippt, wenn er eine Verbindung sucht.

**Ordnernamen zählen nicht als Treffer.** Ein Ordner ist sichtbar, weil etwas
in ihm passt — nicht, weil er selbst so heißt. Sonst zeigte ein Treffer auf
dem Ordnernamen dessen gesamten Inhalt, und die Suche behauptete Treffer, die
keine sind.

### Das Aufklappen ist ein zweiter, kurzlebiger Zustand

„Aufgeklappt während der Suche" und „vom Nutzer zugeklappt" sind zwei
verschiedene Dinge, und der Entwurf hält sie getrennt: der gemerkte Zustand
wird gelesen, wenn das Suchfeld leer ist, und **ignoriert**, solange es das
nicht ist. Nichts wird beim Suchen geschrieben.

### Der Baustein wird benutzt, wie er ist

`SheetSearchField` samt Regex-Schalter und Fehleranzeige, wie in den vier
Sheets. Ein eigenes Suchfeld für die Seitenleiste wäre eine zweite Bauart
derselben Sache — und die Regex-Fähigkeit ist in einer Sitzungsliste eher
nützlicher als in einem Sheet.

Ein **ungültiger** Ausdruck zeigt seinen Fehler und **filtert nicht** — er
darf die Liste nicht leeren, denn eine leere Seitenleiste wegen eines halb
getippten Ausdrucks sieht aus wie ein Datenverlust.

## Was kein Test dieses Projekts sehen kann

Prüfbar ist alles Entscheidbare: wonach gesucht wird, dass Suche und
Tag-Filter zusammen gelten, dass Vorfahren erhalten bleiben, dass ein
ungültiger Ausdruck nichts filtert, und dass der gemerkte Zuklapp-Zustand
weder gelesen noch geschrieben wird, solange gesucht wird.

**Nicht prüfbar** bleibt, ob sich das Aufklappen und Zurückfallen beim Tippen
ruhig anfühlt. Maintainer-Blick.

## Was ausdrücklich nicht dazugehört

- **Kein Hervorheben** von Treffern im Text, keine zweite Darstellung der
  Seitenleiste, keine flache Trefferliste.
- **Kein Schreiben** am gemerkten Zuklapp-Zustand während der Suche.
- **Keine Suche über Ordnernamen.**
- **Kein eigenes Suchfeld** für die Seitenleiste.
- Keine Änderung an der Tag-Leiste (E1/E2) — dieselbe Seitenleiste, anderer
  Vorgang.
