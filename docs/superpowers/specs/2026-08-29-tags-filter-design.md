# Tags: abschaltbar und als Filter — Entwurf

**Stand:** 2026-08-29. Umsetzung von **E1 + E2** aus
`docs/superpowers/specs/2026-08-20-backlog-sitzungen-tabs-seitenleiste.md`,
dort ausdrücklich als zusammen zu entwerfen geführt, weil sie dieselbe Stelle
in der Seitenleiste berühren. Es sind die letzten beiden offenen Punkte des
Eintrags.

---

## Der gemessene Ausgangszustand

`SessionSidebar` hält `activeTag: String?` — **genau einen** Tag, als
Ansichtszustand — und reicht ihn an `SidebarVisibility.compute(activeTag:)`,
die im Quelltext als die *eine* Stelle bezeichnet ist, die filtert.

Daraus folgt beides: die Und/Oder-Frage konnte sich bisher nicht stellen, und
es gibt keine Einstellung, die die Leiste ausblendet.

Seit D3 filtert dieselbe Funktion zusätzlich auf einen Suchbegriff, und beide
Kriterien gelten zusammen.

## Entscheidungen des Maintainers (2026-08-29)

### E1: abschaltbar heißt — die Leiste verschwindet, Tags bleiben

Eine Einstellung blendet die **Filterleiste** aus. Tags bleiben zuweisbar und
in der Sitzungs-Bearbeitung sichtbar.

Wer sie nicht als Filter mag, verliert damit nichts, und vorhandene Tags
werden nicht unerreichbar — das wäre der Fall, an dem ein späteres
Wiedereinschalten überrascht.

**Ein aktiver Filter wird beim Abschalten aufgehoben.** Sonst filterte etwas
weiter, dessen Bedienelement nicht mehr da ist, und die Seitenleiste zeigte
weniger, als sie hat, ohne dass irgendetwas das erklärt. Das ist keine
Feinheit: eine unsichtbar filternde Liste ist von einer verlorenen Liste
nicht zu unterscheiden.

### E2: Schwelle 6, Verknüpfung wählbar

Ab **sechs** Tags klappt die Leiste zu einem Filter-Dialog zusammen. Die
Zahl gehört als benannte Konstante nach Core, nicht in die Ansicht.

Mehrere Tags lassen sich als **alle** (Schnittmenge) oder **irgendeines**
(Vereinigung) verknüpfen; der Nutzer wählt.

## Der Entwurf

### Ein Modell, zwei Darstellungen

**Der Filter ist immer eine Menge von Tags plus eine Verknüpfung.** Die
Leiste ist eine kompakte Darstellung davon, kein zweites Modell.

Das ist der Kern dieses Entwurfs. Ohne ihn gäbe es „einen Tag aus der Leiste"
und „mehrere aus dem Dialog" als zwei Zustände, die beim Überschreiten der
Schwelle ineinander übersetzt werden müssten — und jede solche Übersetzung
ist eine Stelle, an der eine Auswahl still verlorengeht.

`SidebarVisibility.compute` nimmt künftig den Filterwert statt eines
einzelnen Tags. Sie bleibt die eine Stelle, die filtert.

| Zustand | Darstellung |
|---|---|
| weniger als sechs Tags | Leiste; Tags einzeln an- und abwählbar |
| sechs oder mehr | ein Knopf, der den Dialog öffnet, mit der Zahl der gewählten Tags |
| Leiste abgeschaltet (E1) | nichts, und der Filter ist leer |

### Die Verknüpfung erscheint erst, wenn sie etwas bedeutet

Bei **null oder einem** gewählten Tag ist „alle" und „irgendeines" dasselbe.
Die Wahl wird deshalb erst gezeigt, wenn mindestens zwei Tags gewählt sind —
in der Leiste wie im Dialog.

Das ist die stehende Regel dieses Projekts, nur zeigen, was möglich ist,
angewandt auf einen Fall, in dem ein sichtbarer Schalter ohne Wirkung
besonders verwirrt: er stünde da, ließe sich umlegen und änderte nichts.

**Der gewählte Modus überlebt das Abwählen** und wird nicht auf einen
Vorgabewert zurückgesetzt, wenn die Auswahl unter zwei fällt. Sonst
verlöre man beim Entfernen eines Tags eine Einstellung, die man getroffen
hat.

### Was der Filter mit der Suche macht

Nichts Neues: beide gelten **zusammen**, wie seit D3. Wer nach Tags filtert
und dann tippt, sucht innerhalb des Gefilterten. Die Vorfahren-Regel aus
D1+D2 gilt für beide Kriterien unverändert.

### Der Leerzustand nennt beide Verengungen

Seit D3 sagt der Leerzustand „Keine Verbindung passt zum Filter" und sein
Knopf räumt Suche und Tag-Auswahl zusammen weg. Das bleibt so und deckt den
neuen Fall mit ab — ein Filter aus mehreren Tags ist derselbe Fall, nur
enger.

## Was kein Test dieses Projekts sehen kann

Prüfbar ist alles Entscheidbare: dass die Schwelle greift, dass „alle" und
„irgendeines" das Richtige tun, dass die Verknüpfung erst ab zwei Tags
erscheint und den Modus dabei nicht vergisst, dass das Abschalten den Filter
räumt, und dass Suche und Tag-Filter zusammen gelten.

**Nicht prüfbar** bleibt, ob die Schwelle bei sechs richtig sitzt. Das ist
eine Zahl aus dem Wort „Handvoll" und wird sich am Gebrauch zeigen — sie
steht deshalb als benannte Konstante an einer Stelle.

## Was ausdrücklich nicht dazugehört

- **Kein Verstecken der Tag-Zuweisung.** E1 blendet die Filterleiste aus,
  nicht die Tags.
- **Keine Änderung an `StoredSession.tags`** und nichts am Speicherformat.
- **Keine Tag-Verwaltung** (umbenennen, zusammenlegen, löschen über alle
  Sitzungen) — das wäre ein eigener Vorgang.
- **Keine Änderung an der Suche** aus D3 und keine an der Vorfahren-Regel aus
  D1+D2.
