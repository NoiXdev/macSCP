# Backlog: Wie weit lässt sich die Oberfläche prüfen?

**Angelegt:** 2026-08-21, aus einer Maintainer-Frage nach dem
Popover-Fehler. Abwägung, **keine Entscheidung** — festgehalten, damit sie
nicht bei jeder Gelegenheit neu diskutiert wird.

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

## Empfehlung

**A jetzt, C als eigenes Vorhaben erwägen, B nicht.** B kostet eine
Abhängigkeit und sieht ausgerechnet die Fehlerklasse nicht, die uns
getroffen hat.

Vor C wäre ehrlich zu fragen, wie viele Fehler dieser Art es bisher gab:
gezählt sind es zwei — der verschluckte Ablehnungs-Alert aus Teil 2 und das
verschluckte Sheet von heute. Beide in derselben Ecke, beide aus derselben
Ursache. Das spricht eher für A als für den Aufbau einer zweiten
Testinfrastruktur.
