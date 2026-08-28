# Backlog: Wie weit lässt sich die Oberfläche prüfen?

**Angelegt:** 2026-08-21, aus einer Maintainer-Frage nach dem
Popover-Fehler. War eine Abwägung ohne Entscheidung; **seit dem 2026-08-28
entschieden** — siehe den letzten Abschnitt. Der Rest steht unverändert da,
damit die Abwägung nachlesbar bleibt statt neu geführt zu werden.

## Ausgangslage, gemessen

39 Testdateien in `Tests/macSCPAppKitTests`. **Zwei** bauen ein echtes
`NSMenu` (`SnippetMenuItemsTests`, `TerminalContextMenuTests`). **Keine**
zeichnet eine SwiftUI-Ansicht — kein ViewInspector, kein `XCUIApplication`,
kein `NSHostingView`.

Daraus folgt die heutige Grenze, und sie ist keine Nachlässigkeit, sondern
Bauweise: Entscheidungen wandern aus den Ansichten in schlichte Typen
(`SnippetSendPlan`, `SnippetListPlan`, `SnippetMenuModel`,
`SnippetCommandSurvey`), Quellscan-Wächter sichern die Aufrufstellen, und
was übrig bleibt, geht auf die Sichtprüfungsliste.

## Der Anlass

Der Fehler vom 2026-08-21: das Wert-Abfrage-**Sheet** wurde angefordert,
während das Snippet-**Popover** noch stand, und verfiel spurlos. Über das
Terminal-Icon taten Ausführen und Einfügen darum gar nichts, sobald ein
Snippet eine Variable deklarierte.

Bemerkenswert daran: der Kontextmenü-Weg **war** abgedeckt — ein `NSMenu`
lässt sich im Test bauen. Der Popover-Weg nicht. Die Grenze der Abdeckung
und die Stelle des Fehlers waren dieselbe Linie.

## Die drei Möglichkeiten

### A. Wächtertests auf Präsentationsreihenfolge ausweiten

Dieselbe Quelltext-Prüfung, die heute drei Aufrufstellen sichert, könnte
festhalten: *dismiss, dann nächste Runloop-Runde, dann auslösen.* Der
bestehende Wächter für `triggerSnippet` prüft bereits eine **Reihenfolge**
(Prüfung → Meldung → `return` → Abfrage), das Muster existiert also schon.

**Hätte den Fehler verhindert. Kostet keine Infrastruktur.** Schwäche: es
prüft Quelltext, nicht Verhalten — eine neue Auslösestelle in einer nicht
gescannten Datei bliebe unsichtbar.

### B. ViewInspector

Bibliothek, läuft unter `swift test`, prüft den SwiftUI-Baum und kann
Knopf-Aktionen auslösen. Fängt „ist der Knopf da, ruft er das Richtige".

**Hätte den Fehler *nicht* gefangen** — Präsentations-Timing bildet es nicht
ab. Kostet eine Abhängigkeit, die an SwiftUI-Interna hängt und bei
OS-Sprüngen bricht.

### C. XCUITest

Fährt die echte App und klickt wirklich. **Hätte den Fehler gefangen.**

Kostet ein Xcode-Projekt neben dem reinen SwiftPM-Aufbau und einen
CI-Runner mit GUI-Sitzung. Das ist ein eigenes Vorhaben, kein Zusatz — und
es berührt `scripts/package-app` und die Release-Kette.

## Zweiter belegter Fall (2026-08-21, Verbindungszustand Task 4)

Derselbe Riss, an anderer Stelle und diesmal **dreifach gemessen**. Die
Sonde soll jeden verbundenen Tab prüfen, nicht nur den sichtbaren. Die
Entscheidung darüber wurde in einen prüfbaren Typ gezogen
(`LivenessProbeCoverage.tabsToProbe(from:)`, ohne `activeTabID`-Parameter,
sodass die Einschränkung dort nicht einmal formulierbar ist). Trotzdem
bringt jede dieser drei Änderungen den Fehler zurück, und **alle drei
lassen die volle Suite grün**:

- ein `.filter { $0.id == activeTabID }` hinter dem Aufruf am Montageort,
- die Einschränkung im Runner statt an der Montage,
- ein Runner-Rumpf, der für nicht-aktive Tabs `EmptyView()` liefert.

Der Grund ist immer derselbe: ein Quelltext-Scan beweist, dass ein Aufruf
**existiert**, nicht dass er **wirkt**. Drei Wächter auf diesem Zweig sind
nacheinander an genau dieser Grenze gescheitert — erst ein Etikett statt
eines durchgereichten Werts, dann Anwesenheit statt Ort, dann Ort statt
Abdeckung.

**Entscheidung:** nicht weiterverfolgt. Ein vierter, klügerer Scan hätte
dieselbe Grenze. Was diese Klasse fängt, ist Möglichkeit **C** — und die ist
ein eigenes Vorhaben, kein Zusatz. Die Lücke steht als Kommentar an
`LivenessProbeMountGuardTests`, damit sie am Ort des Geschehens sichtbar ist
statt nur hier.

**Damit sind es zwei belegte Fälle statt einem** — die Zahl, an der die
Empfehlung unten hängt.

## Empfehlung

**A jetzt, C als eigenes Vorhaben erwägen, B nicht.** B kostet eine
Abhängigkeit und sieht ausgerechnet die Fehlerklasse nicht, die uns
getroffen hat.

Vor C wäre ehrlich zu fragen, wie viele Fehler dieser Art es bisher gab.
Gezählt am 2026-08-21: **vier**. Zwei verschluckte Präsentationen (der
Ablehnungs-Alert aus Snippets Teil 2, das Wert-Sheet aus dem Popover) und
zwei Fälle, in denen ein Wächter eine Schreibweise statt einer Eigenschaft
bezeugte (die Aufbaufrist, die Sonden-Abdeckung).

Vier ist keine Zahl mehr, die für A allein spricht. Sie spricht dafür, C
ernsthaft zu terminieren — aber als eigenes Vorhaben mit eigenem Entwurf,
nicht als Anhängsel an den nächsten Zweig.

## Entscheidung des Maintainers (2026-08-28): C vorerst gestrichen

**XCUITest wird nicht terminiert.** Nicht verworfen — gestrichen, bis ein
Anlass es zurückholt. Die Empfehlung oben bleibt stehen, damit die Abwägung
nachlesbar ist; sie ist ab hier keine offene Aufgabe mehr.

Der Grund ist nicht, dass die Fehlerklasse verschwunden wäre. Sie ist
gewachsen. C kostet ein Xcode-Projekt neben dem reinen SwiftPM-Aufbau, einen
CI-Runner mit GUI-Sitzung und fasst `scripts/package-app` samt Release-Kette
an — und der Release-Stau ist selbst ein offener Posten. Ein zweites
Bausystem in eine Lage einzuziehen, in der das erste noch nicht ausgeliefert
hat, verschiebt das Problem, statt es zu lösen.

**Die Zahl oben ist überholt, und zwar in die Richtung, die für C spricht.**
„Vier" ist vom 2026-08-21. Nachweisbar dazugekommen, ohne dass hier neu
durchgezählt wurde:

- der Reiter-Menü-Wächter, der fünf Korrekturrunden überstand, und der
  Prefill-Wächter, der still verstummte — beide gemessen am 2026-08-27 und
  in `CLAUDE.md` unter „Guards that name what they watch" festgehalten;
- die Umbenennung `replacedSession` → `nameConflict`, die einen Filter auf
  ein Symbol zeigen ließ, das es nicht mehr gab (2026-08-28);
- sechs Runden, sechs Schreibweisen am Verbindungspfad, siehe
  `2026-08-22-backlog-verbindungs-fähigkeit.md`.

**A ist damit nicht automatisch beauftragt.** Der Wächter, den A meint,
existiert inzwischen als `SnippetVariablePromptWiringGuardTests` — was er
über die Präsentationsreihenfolge festhält und was noch fehlt, ist beim
Angehen zu messen, nicht von hier aus zu behaupten. Wer A angeht, zählt
zuerst nach.

**Was C zurückholt:** ein Fehler dieser Klasse, der einen Nutzer erreicht —
nicht einer, den eine Prüfrunde vorher findet. Bis dahin gilt der Weg, den
dieses Projekt seit dem Eintrag tatsächlich gegangen ist und der in den
letzten Vorgängen mehrfach getragen hat: **nicht ein klügerer Scan, sondern
eine Fähigkeitsgrenze** — ein Typ, der den Verstoß nicht übersetzen lässt.
Das ist weder A noch C, und es war beim Anlegen dieses Eintrags noch nicht
sichtbar.
