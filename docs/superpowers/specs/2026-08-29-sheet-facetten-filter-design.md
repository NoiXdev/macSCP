# Facetten-Schnellfilter in den Verwaltungs-Sheets — Entwurf

**Stand:** 2026-08-29. Umsetzung von **Punkt 2** aus
`docs/superpowers/specs/2026-08-20-backlog-verwaltungs-sheets.md` — dem
letzten offenen Punkt dieses Eintrags.

---

## Der gemessene Ausgangszustand

`SheetSearchField` (M18) steht in mehreren Sheets und liefert über
`sheetSearchPredicate(text:isRegex:)` ein `FileSearch.FileSearchPredicate`
plus einen Fehlertext für einen ungültigen Ausdruck. Jedes Sheet filtert
seine Zeilen damit selbst (`filteredRows`).

**Einen Facetten-Filter gibt es nur im `AuditLogSheet`** — und das ist keines
der drei Sheets, um die es hier geht. Known-Hosts, SSH-Schlüssel und
Login-Sets haben die Suche, aber keine Facetten.

## Entscheidung des Maintainers (2026-08-29)

**Ein gemeinsames Steuerelement, dem die Facetten übergeben werden** — nicht
drei eigene.

Der Grund steht im Eintrag selbst: es teilt die Prädikat-Form der Suche,
damit Suche und Filter sich **verketten statt zu konkurrieren**. Drei Kopien
dieser Verkettung wären drei Stellen, an denen sie stimmen muss — und dieses
Projekt hat in dieser Woche mehrfach dafür bezahlt, dass dieselbe Regel an
mehreren Orten lag.

## Der Entwurf

### Die Facetten sind Daten, nicht Bauart

Das Steuerelement bekommt eine Liste von Facetten und die Funktion, die einer
Zeile ihren Facettenwert zuordnet. Was eine Facette *ist*, weiß nur das
jeweilige Sheet:

| Sheet | Facette |
|---|---|
| SSH-Schlüssel | Schlüsseltyp |
| Login-Sets | Backend-Art |
| Known Hosts | Algorithmus |

### Eine Auswahl, nicht mehrere

Ein Wert oder „Alle" — kein Mengenmodell mit Verknüpfung.

Das ist bewusst **anders als beim Tag-Filter der Seitenleiste**, und der
Unterschied ist nicht Inkonsequenz: Tags sind offen und beliebig viele,
weshalb dort eine Menge plus „alle/irgendeines" nötig war. Eine Facette ist
eine geschlossene, kleine Aufzählung, und die Werte schließen einander in der
Praxis aus — ein Schlüssel hat *einen* Typ. Ein Mengenmodell darüber wäre
Maschinerie ohne Fall.

**„Alle" ist die Abwesenheit einer Auswahl**, kein eigener Facettenwert.
Sonst müsste jede Zuordnungsfunktion einen Wert kennen, der nichts bedeutet.

### Verketten heißt: beides muss zutreffen

Eine Zeile überlebt, wenn die **Suche** sie trifft **und** die Facette passt.
Wer nach einem Typ filtert und dann tippt, sucht innerhalb des Gefilterten —
dieselbe Regel, die die Seitenleiste seit D3 befolgt.

Die Verkettung ist ein **prüfbarer Wert**, keine Zeile in drei
`filteredRows`-Bergen. Sie wird einmal geschrieben und dreimal gerufen.

### Die Facetten kommen von der Platte, nicht aus einer Liste

Welche Werte ein Sheet anbietet, wird aus seinen **Zeilen** abgeleitet, nicht
fest aufgezählt. Ein Schlüsseltyp, den niemand hat, gehört nicht in die
Auswahl — und ein neuer, den jemand anlegt, erscheint ohne dass jemand eine
Liste nachzieht.

Das ist die stehende Regel dieses Projekts („nur zeigen, was möglich ist")
und zugleich die, die es diese Woche zweimal gelernt hat: eine feste
Aufzählung veraltet still.

**Daraus folgt:** hat ein Sheet nur einen einzigen Facettenwert, ist die
Auswahl bedeutungslos und erscheint **nicht**. Ein Steuerelement, das sich
bedienen lässt und nichts ändert, ist schlechter als keines.

### Der Leerzustand nennt beide Verengungen

Ein Sheet, dessen Liste leer ist, muss sagen, **warum** — kein Treffer, oder
kein Eintrag dieser Art. Und die Möglichkeit, beides zusammen wegzuräumen,
gehört dazu.

`KnownHostsSheet` führt heute `isUnfiltered` als `searchText.isEmpty`. Das
wird mit der Facette falsch und ist in demselben Durchgang nachzuziehen —
sonst behauptet ein Sheet, ungefiltert zu sein, während eine Facette Zeilen
versteckt.

## Was kein Test dieses Projekts sehen kann

Prüfbar ist alles Entscheidbare: die Verkettung, dass die Facettenwerte aus
den Zeilen kommen, dass eine Auswahl mit nur einem Wert nicht erscheint, dass
ein ungültiger Ausdruck weiterhin nichts filtert, und was der Leerzustand
sagt.

**Nicht prüfbar** bleibt, ob das Steuerelement unter der Suche gut sitzt.
Maintainer-Blick.

## Was ausdrücklich nicht dazugehört

- **Keine Mehrfachauswahl** und keine Und/Oder-Verknüpfung.
- **Keine Facette über einen zusammengesetzten Untertitel** — Fingerabdruck,
  Schlüssellänge und Pfad stecken in einem String und stehen nicht als Felder
  zur Verfügung. Das ist der bewusst bezahlte Preis von Punkt 4 und bleibt es.
- **Kein Facetten-Filter im `AuditLogSheet`**, das seinen eigenen hat und ihn
  behält.
- **Keine Änderung an `SheetSearchField`** selbst.
