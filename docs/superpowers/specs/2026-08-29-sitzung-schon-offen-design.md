# „Sitzung ist schon offen" — Entwurf

**Stand:** 2026-08-29. Umsetzung von **C2** aus
`docs/superpowers/specs/2026-08-20-backlog-sitzungen-tabs-seitenleiste.md`.

---

## Der gemessene Ausgangszustand

**Es gibt heute keinerlei Erkennung.** Eine gespeicherte Sitzung ein zweites
Mal zu starten öffnet wortlos einen zweiten Reiter auf dieselbe Sitzung.

Zwei Dinge liegen dafür bereits im Baum, und beide sind der Grund, warum
dieser Vorgang klein ist:

- **`SessionTab.activeStoredSessionID`** — die Kennung der gespeicherten
  Sitzung, an der ein Reiter hängt. Ausschließlich bei einer *gespeicherten*
  Verbindung gesetzt, nie ad-hoc, und in `teardown` wieder geräumt. Das ist
  genau die Identität, die C2 braucht, und sie existiert schon.
- **`TabsViewModel.sidebarConnectTarget(activeTabIsConnected:makeTab:)`** —
  eine reine Entscheidungsfunktion in Core, die heute schon bestimmt, in
  welchem Reiter ein Start landet. Sie kennt nur ein `Bool` und ist deshalb
  blind für die Frage; die Naht ist da, sie sieht zu wenig.

`TabsViewModel.activate(_:)` gibt es ebenfalls — das Springen ist bereits
ausdrückbar.

## Entscheidungen des Maintainers (2026-08-29)

### 1. „Dieselbe" heißt: dieselbe gespeicherte Sitzung

Ein Reiter mit derselben `activeStoredSessionID` zählt als offen.

**Eine Ad-hoc-Verbindung zum selben Ziel löst nichts aus.** Das ist nicht
Bequemlichkeit, sondern richtig: eine getippte Verbindung kann andere
Zugangsdaten, einen anderen Schlüssel oder einen anderen Jump-Host tragen.
Sie sieht gleich aus und ist es nicht. Host und Port zu vergleichen hieße,
über eine Gleichheit zu raten, die das Programm nicht kennt.

### 2. Es wird jedes Mal gefragt

**Kein „nicht mehr fragen", kein gespeicherter Wert, keine Einstellung.**

Ein Merken lässt sich später billig nachrüsten, wenn sich das Fragen als
lästig erweist. Umgekehrt gilt das nicht: eine gespeicherte Antwort ohne
sichtbaren Weg zurück ist eine Falle, und dieses Projekt hat die schon
einmal bezahlt (Keep-alive: ein Wert, der „aus" und „Intervall" zugleich
trug).

## Der Entwurf

### Die Entscheidung ist ein Wert in Core

Nach dem Vorbild von `SessionNameCollision`: eine reine Funktion, die sagt,
**welcher Reiter** die Sitzung bereits hält — nicht, was zu tun ist.

`TabsViewModel` ist generisch über seinen `Tab`, kann also
`activeStoredSessionID` nicht selbst lesen. Die App reicht die Projektion
herein; die Regel bleibt in Core und damit prüfbar.

Die Funktion antwortet mit dem **ersten** Reiter in Reiter-Reihenfolge, der
die Sitzung hält. Mehrere sind möglich, sobald jemand einmal „trotzdem
öffnen" gewählt hat — dann ist die Reihenfolge die einzige Regel, die keine
Vorliebe erfindet.

### Was die Fläche anbietet

Zwei Wege, und **nur die, die etwas tun**:

| | Wirkung |
|---|---|
| **Zur bestehenden springen** | `activate(_:)` auf den gefundenen Reiter |
| **Trotzdem neu öffnen** | genau das heutige Verhalten, unverändert |

Abbrechen ist der dritte Ausgang und ist das Schließen der Abfrage.

**Hält der aktive Reiter die Sitzung selbst**, wird trotzdem gefragt.
Springen ist dann folgenlos — und das ist die richtige Wirkung dieser Wahl,
nicht ein Grund, die Frage zu unterdrücken. Die Alternative („noch einen
öffnen") ist in diesem Fall genauso sinnvoll wie in jedem anderen.

### Wo nicht gefragt wird

- **Beim Wiederverbinden am Ort.** `isReconnecting` betrifft denselben
  Reiter; da ist nichts doppelt.
- **Bei einer Ad-hoc-Verbindung**, aus Entscheidung 1.
- **Wenn kein Reiter die Sitzung hält** — dann bleibt es beim heutigen
  Verhalten, einschließlich der Regel, dass ein unverbundener aktiver Reiter
  wiederverwendet wird.

## Was kein Test dieses Projekts sehen kann

Prüfbar ist alles Entscheidbare: welcher Reiter als haltend gilt, dass eine
Ad-hoc-Verbindung nicht zählt, dass bei mehreren der erste gewinnt, und dass
beide Wege das Richtige auslösen.

**Nicht prüfbar** bleibt, dass die Abfrage im laufenden Fenster erscheint und
lesbar steht — wie bei jeder Fläche dieses Projekts.

## Was ausdrücklich nicht dazugehört

- **Kein Merken der Antwort**, keine neue Einstellung, kein neuer
  gespeicherter Wert.
- **Keine Änderung an `sidebarConnectTarget`s heutiger Regel** für den Fall,
  dass nichts doppelt ist.
- **Keine Ad-hoc-Gleichheit** über Host/Port/Benutzer.
- Kein Zusammenführen zweier Reiter, kein Schließen des einen beim Springen
  auf den anderen.
