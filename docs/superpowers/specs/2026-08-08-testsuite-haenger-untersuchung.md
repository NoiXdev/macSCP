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
