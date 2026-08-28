# Die App soll nicht selbst „ja" sagen können — Entwurf

**Stand:** 2026-08-28. Umsetzung von
`docs/superpowers/specs/2026-08-22-backlog-verbindungs-fähigkeit.md`, dem
Eintrag, den der Backlog selbst als den wichtigsten führt: nach sechs Runden,
in denen jeweils eine neue Schreibweise einen Quelltext-Wächter geschlagen hat.

---

## Was das Messen verschoben hat

Der Eintrag beschreibt das Ziel als „die App-Schicht kann eine Verbindung nicht
herstellen, außer über einen Typ, den nur der gemeinsame Pfad ausgibt". Beim
Nachmessen zeigt sich, dass das die **zweitwichtigere** Hälfte ist.

**Die Gefahr ist nicht der zweite Wählpfad, sondern der frei erfundene
Entscheider.** TOFU ist bereits sicher: der harte Stopp bei einem
Fingerabdruck-Konflikt sitzt **im Backend**, nicht an der Aufrufstelle. Was ein
Umgehungsaufruf tatsächlich umgeht, ist die Frage an den Nutzer — er beantwortet
sie selbst:

```swift
async let dialed = BackendDescriptor.descriptor(for: kind).connect(
    config, { _ in true }, { _ in true }, 30)
```

Das war Runde 6. Möglich ist es, weil beide Entscheider **nackte Funktionstypen**
sind:

```swift
public typealias HostKeyDecider = @Sendable (HostKeyCandidate) async -> Bool
```

## Der gemessene Ausgangszustand

| | |
|---|---|
| Echte Aufrufer von `descriptor(…).connect(` außerhalb Core | **zwei**: `ContentView+Lifecycle` (App) und `SessionConnecting` (CLI) |
| Tests, die darüber wählen | **keiner** — jeder Treffer in `Tests/` ist Probenmaterial in einem Wächter |
| Core-Testdateien mit `@testable import macSCPCore` | **170** — sie behalten Zugriff auf Internes |
| App-Testdateien | importieren `Foundation`/`Testing`; sie lesen Quelltext, sie rufen nicht |
| TOFU-Konflikt | harter Stopp **im Backend**, unabhängig vom Entscheider |

`internal` auf dem Wählvorgang sperrt damit genau die zwei Ziele aus, die
ausgesperrt gehören, und kostet die Testsuite nichts.

## Der Entwurf

### 1. Ein Entscheider ist ein Typ, keine Closure

`HostKeyDecider` und der Zertifikats-Entscheider werden Typen mit
**nicht-öffentlichem Initialisierer** und öffentlichen Fabriken in Core:

| Fabrik | Bedeutung | Nutzer |
|---|---|---|
| `.asking(_:)` | **zeigt** dem Nutzer den Kandidaten und gibt dessen Antwort zurück | App |
| `.refusingUnknown` | lehnt jeden unbekannten Schlüssel ab, ohne zu fragen | CLI ohne Interaktion |
| `.following(_:)` | die bestehende `HostKeyPolicy` der CLI | CLI |

Damit ist `{ _ in true }` an einer Aufrufstelle **kein Entscheider mehr** — es
kompiliert nicht. Runde 6 wäre nicht abzufangen gewesen, sondern nicht
formulierbar.

**Die ehrliche Grenze dieser Maßnahme, gleich hier statt im Kleingedruckten:**
`.asking` nimmt weiterhin etwas entgegen, das antwortet. Wer
`.asking { _ in true }` schreibt, hat wieder einen Ja-sager. Der Unterschied ist
nicht Unmöglichkeit, sondern **Sichtbarkeit**: die Umgehung trägt jetzt einen
Namen, steht an einer Fabrik, die „fragen" heißt, und ist damit genau das, was
ein Wächter noch bewachen kann — im Gegensatz zu einer anonymen Closure in einem
Argument, die sich in sechs Schreibweisen verstecken ließ.

### 2. Wählen ist keine Fähigkeit der App-Schicht

`BackendDescriptor.connect` wird **`internal`**. Ein einziger öffentlicher
Einstiegspunkt in Core gibt Verbindungen aus; App und CLI rufen ihn.

Das ist die Fähigkeitsgrenze aus dem Eintrag im Wortsinn: „am Pfad vorbei" ist
danach kein Verstoß, den ein Test finden müsste, sondern etwas, das der Compiler
nicht übersetzt. Und weil Core-Tests `@testable` importieren, verlieren sie
nichts.

**Warum beides und nicht nur eines:** ohne den Entscheider-Typ verschiebt der
Einstiegspunkt das Problem nur eine Ebene höher — er nähme weiterhin eine
Closure entgegen. Ohne die Aussperrung bliebe der rohe Wählvorgang erreichbar
und mit ihm jede künftige Schreibweise, ihn zu erreichen. Zusammen decken sie
verschiedene Hälften ab: der Typ verhindert den **Ja-sager**, die Aussperrung
den **zweiten Pfad**.

### 3. Der Wächter schrumpft auf das, was Typen nicht ausdrücken

Was er heute prüft, wird überflüssig, sobald es nicht mehr kompiliert. **Jede
Prüfung, die eine strukturelle Garantie doppelt, wird gelöscht**, nicht „für
alle Fälle" behalten — ein Wächter neben einer Garantie lässt den nächsten Leser
der Suite mehr vertrauen, als sie verdient.

Übrig bleibt, was ein Typ nicht sagen kann:

- dass die App ihre `.asking`-Fabrik an die **echte** Abfrage hängt und nicht an
  einen Ja-sager,
- dass der Zertifikatsweg dasselbe tut.

Diese Reste gehören ausdrücklich benannt — mit dem, was sie **nicht** sehen.

## Was kein Test dieses Projekts sehen kann

Prüfbar ist alles Entscheidbare, und der größere Teil wird zur Compile-Frage.

**Nicht prüfbar** bleibt, dass die Abfrage im laufenden Fenster tatsächlich
erscheint und der Nutzer wirklich gefragt wird. Das war schon vorher so und
ändert sich nicht.

---

## Was ausdrücklich nicht dazugehört

- **Keine Änderung an TOFU selbst.** Der harte Stopp bleibt, wo er ist.
- **Keine Änderung daran, was die CLI entscheidet** — sie lehnt unbekannte
  Zertifikate weiterhin ab und folgt weiter ihrer `HostKeyPolicy`.
- Keine neue Einstellung, kein neues Verhalten für den Nutzer. Diese Arbeit ist
  von außen unsichtbar; sie verändert, was sich schreiben lässt.
