# Der 0-%-CPU-Hänger der Testsuite — Untersuchungsstand

**Stand:** 2026-08-08. **Nicht behoben.** Was hier steht, ist das, was gesichert
ist, damit die nächste Runde nicht bei null anfängt.

## Symptom

`swift test` bleibt gelegentlich stehen und terminiert nie. Der Prozess lebt,
verbraucht 0,0 % CPU, gibt nichts mehr aus. Seit M20 im Ledger, mehrfach
gesehen: zweimal hintereinander in M21 (>10 min und >7 min, dritter Lauf
derselben Arbeitskopie in 3,4 s grün), einmal während M21/T11, einmal isoliert
auf `ImportConflictBridgeTests/aSecondAskResolvesTheStrandedFirstContinuation`
über 14 Stunden.

## Sofortmaßnahme (umgesetzt)

`timeout-minutes: 20` auf dem CI-`test`-Job (`a75b0f5`). **Das ist das Netz,
nicht der Fix.** Ohne es verbraucht ein Hänger das Sechs-Stunden-Budget des
Runners und wird nie rot — er ist in der Lauf-Liste unsichtbar und teuer.
Grüne Läufe brauchen drei bis vier Minuten.

## Gesichert

**Der Hänger ist eine suspendierte Task, die nie fortgesetzt wird.**
Zwei lebende Exemplare wurden auf der Maschine des Maintainers gefunden —
Waisen aus einer Sitzung vom 2026-08-06, zum Zeitpunkt der Untersuchung seit
46 Stunden am Leben — und ausgewertet, bevor sie angefasst wurden:

- `sample` zeigt **drei Threads, alle im Leerlauf**: der Main-Thread in
  `swift_task_asyncMainDrainQueue` → `CFRunLoopRun` → `mach_msg2_trap`, ein
  CFNetwork-Runloop-Thread, ein leerer Workqueue-Thread. **Kein einziger
  swift-testing- oder macSCP-Frame** auf irgendeinem Stack außer `main`.
- `lldb`: `current_task = id:0, address = 0x0` — auf dem Main-Thread läuft
  keine Task.

Das ist kein Widerspruch, sondern der Fingerabdruck: **eine suspendierte Swift-
Task hat keinen Thread**, sie liegt auf dem Heap. Der Async-Main-Task des
Harness wird nie fertig, also verlässt der Drain-Loop nie den Prozess.

**Folgerung fürs Werkzeug:** der Stack kann prinzipiell nicht sagen, WELCHER
Test hängt. Nur die Ausgabe des Laufs kann es — swift-testing druckt jeden Test
beim Abschluss, die letzte Zeile nennt den Kandidaten. Wer einen Hänger
erwischt, muss deshalb **Log und `sample` sichern, bevor er den Prozess
killt.** Dafür gibt es `scripts/hang-hunt`.

## Widerlegt

**`aSecondAskResolvesTheStrandedFirstContinuation` kann so nicht verklemmen.**
Der Test spult 50 `Task.yield()` ab und wartet dann mit `await first.value` auf
eine Continuation, die eine zweite Task auflösen muss — das sah nach der
Ursache aus. Es ist keine: `ImportConflictBridgeTests` ist `@MainActor`, und
`await first.value` **gibt den MainActor frei**, sodass die zweite Task
garantiert laufen und die erste erlösen kann. Die 50 Yields sind Gürtel und
Hosenträger, nicht tragend.

Dass der einzige je isoliert beobachtete Hänger genau auf diesem Test stand,
bleibt damit unerklärt — aber nicht durch diesen Mechanismus.

## Nicht reproduzierbar (zwei Runden, 280 Läufe)

| Runde | Aufbau | Ergebnis |
|---|---|---|
| 1 | 40× volle Suite, sequenziell, ruhige Maschine, eigener Scratch-Path | 40/40 grün, 3,5–6,1 s |
| 2 | 4 gleichzeitige Arbeiter × 60× `--filter ImportConflictBridge`, eigene Scratch-Paths | 240/240 grün |

Runde 2 hatte gezielt die beiden Bedingungen, die jedem dokumentierten Fall
gemeinsam sind und Runde 1 fehlten: **Last** (alle Sichtungen fielen in
Sitzungen mit parallel bauenden Subagenten) und **Isolation** (der eine
zuordenbare Fall lief allein). Beides reicht nicht.

Die Häufigkeit liegt damit unter 1:280 unter diesen Bedingungen — oder sie
hängt an etwas, das keine der beiden Runden hatte.

## Nebenbefund: abgeschossene Läufe hinterlassen Waisen

Wird ein hängendes `swift test` gekillt, **überlebt sein
`swiftpm-testing-helper`-Kind**, wird zu `launchd` umgehängt und läuft weiter.
Die beiden ausgewerteten Exemplare lagen so 46 Stunden herum. Das verursacht
den Hänger nicht, macht ihn aber unsichtbar und leckt Prozesse und Speicher.

Nach einem händischen Kill also immer:

```
pgrep -fl swiftpm-testing-helper
```

## Nächster Schritt, wenn es wieder auftritt

Nicht versuchen, ihn zu provozieren — das hat 280 Läufe gekostet und nichts
gebracht. Stattdessen beim nächsten echten Auftreten **sofort** sichern:

```
sample <pid> 3 -mayDie -f /tmp/hang.txt   # vor dem Kill!
```

und die **letzte Zeile der Testausgabe** notieren. Das ist der eine Datenpunkt,
der noch fehlt: der Name des Tests. Mit ihm wird aus der Untersuchung eine
gezielte Frage statt einer Suche.

---

## Nachtrag 2026-08-29: ein zweiter Flatterer — gemessen, und die erste Erklärung war falsch

**Erledigt und aufgeklärt.** Der Eintrag steht, weil die Aufklärung mehr wert
ist als der Fehler.

`S3RedirectAuthorizationMeasurementTests` fiel gelegentlich, zweimal
unabhängig gesichtet. Die hier zuerst notierte Erklärung — knappe
Wartezeiten unter Last — **ist widerlegt.** 80 volle Läufe in vier Runden:

| Runde | Aufbau | S3-Suite rot |
|---|---|---|
| 1 | vier parallele Builds als Last | 3 / 20 |
| 2 | gleiche Last, instrumentiert | 3 / 20 |
| 3 | **ohne jede Last** | **7 / 20** |
| 4 | ohne Last, `URLCache.shared` je Fall geleert | **0 / 20** |

**Ohne Last war die Rate höher.** Last ist Zuschauer. Und die Wartezeit war
es auch nicht: bei jedem der 13 Fehlschläge verstrichen danach noch
**60 Sekunden ungenutzt** (`extra=60.01 s`), wo ein grüner Lauf dieselbe
Wartezeit in Mikrosekunden durchläuft. Es gibt keine Schranke, die das
abgedeckt hätte — eine größere hätte nur jeden roten Lauf verlängert.

### Die Ursache: `URLCache.shared`

`S3FileSystem` fährt über `URLSession.shared` und damit über
`URLCache.shared` — einen **persistenten Platten-Cache, den alle Prozesse
teilen**. Die 301- und 308-Antworten des Stubs sind cachebar und werden nach
`http://127.0.0.1:<ephemerer Port>/bucket?…` verschlüsselt. Ephemere Ports
kehren wieder: trifft ein Lauf einen Port, für den ein **früherer
`swift test`-Prozess** einen Eintrag hinterlassen hat, beantwortet die Platte
die signierte Anfrage, und der Stub sieht sie nie.

Belegt über zwei Prozesse: PROC1 setzt die Stubs, PROC2 — getrennt, ohne
eigenen Listener — findet `cachedEntry=true status=308` und folgt dem
Location, ohne die erste Origin je zu berühren. Gemessen wird gecacht bei
**301 und 308**, nicht bei 302/303/307.

Dass die Form meist harmlos aussah (zwei Issues), hat einen Grund: der zweite
Stub wird zuerst angelegt, also gilt immer `p1 == p2 + 1`, und der veraltete
Location zeigt auf den zweiten Stub des *laufenden* Falls.

**Die Sicherheitszusicherung ist nie gefallen.** Gefallen ist jedes Mal eine
**positive** Prüfung — „die erste Origin wurde nie erreicht" —, und sie fiel
zu Recht. Genau dafür steht sie neben der negativen.

### Was daraus folgt

- **Am Test:** der Cache-Schlüssel darf nicht wiederkehren. Ein je Lauf
  einzigartiger Bucket-Name genügt und ändert keine Zusicherung — besser als
  `removeAllCachedResponses()`, das den Cache des Entwicklers und fremder
  Suiten mit leert.
- **In der Produktion, und das ist der schwerere Teil:** siehe
  `2026-08-29-backlog-s3-teilt-die-url-session.md`.

### Eine Lehre über diesen Fall hinaus

Die erste Erklärung war plausibel, passte zu den Beobachtungen und war
falsch. Sie stammte aus einer **Korrelation** — beide Sichtungen traten
während eines Builds auf — und wurde erst widerlegt, als jemand ohne Last
maß und die Rate stieg. Eine Ursache, die man aus dem Zusammentreffen
erschließt, ist eine Hypothese, bis eine Runde sie gezielt auszuschließen
versucht hat.

