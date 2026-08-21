# Backlog: Abhängigkeiten auf aktuelle Stände

**Angelegt:** 2026-08-20, aus Maintainer-Zuruf. Gemessen an `Package.swift`,
`Package.resolved` und den Tags der jeweiligen Projekte.

## Ist gegen Neuestes

| Paket | aufgelöst | neuestes | Anmerkung |
|---|---|---|---|
| Citadel | 0.12.1 | **0.12.1** | bereits aktuell |
| swift-argument-parser | 1.8.2 | 1.8.2 | aktuell |
| swift-nio | 2.101.2 | 2.101.3 | Patch |
| swift-crypto | 3.15.1 | **4.5.1** | durch `from: "3.0.0"` gedeckelt |
| SwiftTerm | Revision, 2026-07-01 | **v1.20.0**, 2026-08-18 | **98 Commits zurück** |
| swift-nio-ssh | **Fork `Wellz26` 0.3.6** | `apple` 0.15.0 | siehe unten |

**Zur Ausgangsvermutung:** Citadel steht *nicht* bei 0.15 — 0.12.1 ist dort
der neueste Stand, und darauf sitzen wir. Die 0.15 gehört zu
**swift-nio-ssh**, das eine Ebene tiefer liegt.

## Der eigentliche Befund: das SSH-Transportpaket ist ein Fremd-Fork

`swift-nio-ssh` kommt nicht von Apple, sondern von
`https://github.com/Wellz26/swift-nio-ssh.git`. Das ist **keine Entscheidung
von macSCP** — Citadel 0.12.1 schreibt es im eigenen `Package.swift` fest
(`"0.3.4" ..< "0.4.0"`), direkt unter einem auskommentierten lokalen Pfad des
Citadel-Autors.

Damit steht das Paket, das jede SSH-Verbindung dieser App aushandelt, in der
Vertrauenskette als **persönlicher Fork einer Apple-Bibliothek**, und der
Versionsstand liegt weit hinter Apples 0.15.0. Ob der Fork Apples 0.3.x-Zweig
nachführt oder eigene Wege geht, ist an den Tags allein **nicht ablesbar und
gehört gemessen**, bevor daraus eine Bewertung wird.

Das ist der Punkt, der eine Entscheidung braucht — nicht die Zahlen in der
Tabelle. Mögliche Wege: mit Citadel-Upstream klären, ob der Fork wegkann; den
Fork gegen Apples Stand diffen und beurteilen; oder auf Sicht bleiben und die
Lage dokumentieren. Alle drei sind vertretbar, keiner ist ein Nebenbei.

## Die übrigen, der Reihe nach

1. **swift-nio auf 2.101.3.** Patch, sollte folgenlos sein. Der billigste
   Schritt.
2. **SwiftTerm.** Heute an eine nackte Revision genagelt — keine Version, kein
   Semver, kein Bereich. Vor dem Anheben ist zu klären, **warum** dieser
   Commit gewählt wurde; ein Revisions-Pin bedeutet üblicherweise, dass
   damals ein bestimmter Fix gebraucht wurde. Steht das nicht fest, ist der
   Sprung auf v1.20.0 ein Blindflug über 98 Commits durch die Terminal-Anzeige.
3. **swift-crypto auf 4.x.** Ein Major-Sprung, den `from: "3.0.0"` heute
   blockt. Wiegt schwerer als die anderen, weil swift-crypto im
   Schlüssel-Handling sitzt (Erzeugung, Laden, Fingerabdrücke) — zwei
   Hauptversionen Rückstand ist dort etwas anderes als bei einer
   Anzeigebibliothek. `5.0` steht im Beta und bleibt außen vor.

## Zusammenhang, der die Reihenfolge bestimmt

Ein Abhängigkeitssprung zieht leicht einen **Toolchain-Sprung** nach sich, und
der trifft auf die offene Schuld aus
`2026-08-19-backlog-swift6-warnungen.md`: rund 1200 Warnungen tragen wörtlich
„this is an error in the Swift 6 language mode", während alle Targets auf
`.swiftLanguageMode(.v5)` stehen.

**Deshalb die Warnungen vor den großen Sprüngen** — sonst fällt beides
gleichzeitig an und man weiß bei einem roten Build nicht, welche der beiden
Änderungen ihn gebrochen hat.

## Reihenfolge

swift-nio (Patch) → Swift-6-Warnungen → SwiftTerm (nach Klärung des Pins) →
swift-crypto 4.x. Der Fork ist keine Stufe in dieser Leiter, sondern eine
eigene Entscheidung; er kann jederzeit davor oder danach angegangen werden.
