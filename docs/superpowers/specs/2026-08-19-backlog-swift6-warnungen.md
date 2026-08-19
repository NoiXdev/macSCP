# Backlog: die Swift-6-Warnungen im CI-Log

**Angelegt:** 2026-08-19, nachdem im GitHub-Actions-Log Fehlermeldungen aufzufallen
schienen. **Es sind keine Fehler.** Alle Läufe stehen auf `success`, null
`error:`. Gemessen am Lauf `32248172604` (CI, develop).

## Der Befund

**1472 Warnungen**, davon der ganz überwiegende Teil aus **unserem** Code, nicht
aus Abhängigkeiten:

| Ort | Anzahl | Vorherrschende Ursache |
|---|---|---|
| `Tests/macSCPCoreTests` | 661 | 528× ein Lock, in einem async-Kontext genommen |
| `Sources/macSCPCore` | 72 | nicht-Sendable Citadel-Typen (`SFTPFile`) in `@Sendable`-Closures |
| `Sources/MacSCPCLI` | 3 | dasselbe Muster |

Im Produktivcode sind nur drei Dateien betroffen: `RemoteFS/TransferEngine.swift`,
`SSH/CitadelFileSystem.swift` und `MacSCPCLI/MacSCPCLI.swift`.

## Warum das kein Rauschen ist

An rund 1200 dieser Warnungen steht wörtlich *„this is an error in the Swift 6
language mode"*. Alle Targets stehen auf `.swiftLanguageMode(.v5)`. Heute sind es
Warnungen; sobald jemand den Sprachmodus umstellt — freiwillig oder weil eine
Toolchain es erzwingt —, ist es ein Build-Stopp.

Das ist eine **terminierte Schuld**, kein Aufräumwunsch.

## Zwei getrennte Naturen

1. **Die 528 Lock-Warnungen in den Tests.** Ein Testhelfer nimmt ein Lock in
   einem async-Kontext. Vermutlich ein einziges Muster, an einer Stelle
   korrigierbar — die Zahl ist groß, weil dasselbe Muster in vielen Tests
   verwendet wird, nicht weil es viele verschiedene Probleme wären. **Vor dem
   Anfassen nachzählen, ob es wirklich ein Muster ist**; diese Vermutung ist
   nicht gemessen.
2. **Die Sendable-Warnungen in Core.** Citadels Typen wandern durch unsere
   Closures. Das ist echte Arbeit an drei Dateien und kein Suchen-Ersetzen —
   entweder `@preconcurrency import`, oder die Typen wirklich aus den Closures
   heraushalten. Das erste ist ein Zudecken, das zweite eine Umstrukturierung.

## Reihenfolge

Kein Anlass zur Eile, solange der Sprachmodus auf v5 steht. Sinnvoll ist es
**vor** dem nächsten Toolchain-Sprung, und die Tests zuerst: dort liegt die
Masse, und sie ist wahrscheinlich die billigere Hälfte.
