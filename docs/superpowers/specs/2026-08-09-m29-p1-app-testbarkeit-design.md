# M29-P1 — Das App-Target prüfbar machen: Fundament (Design)

**Stand:** 2026-08-09. Vorgänger: M28, dessen Whole-Branch-Review einen
**Critical** fand, den kein Test halten kann.

## Warum es diesen Meilenstein gibt

M28 schloss einen Pfad, auf dem ein WebDAV- oder S3-Passwort einen
SSH-Bastion-Host erreichte. Zur Absicherung wurde der neue `kind`-Wächter
probeweise **ganz entfernt** — die volle Suite blieb **grün**.

Der Grund ist strukturell, nicht nachlässig: `Tests/` enthält genau ein
Verzeichnis, `macSCPCoreTests`. `MacSCPApp` ist ein `executableTarget` ohne
Testtarget. Was dort liegt, kann kein Test erreichen. Dazu kommt, dass die
betroffene Logik `private func` **auf der `ContentView`-Struct** ist: selbst
mit Testtarget müsste man eine SwiftUI-View samt ihrer Umgebung
konstruieren, um sie zu befragen.

**Ein Testtarget allein hätte M28s Critical also nicht gefangen.** Beides
wird gebraucht: ein Ort, an dem App-Code prüfbar ist, **und** Logik, die
nicht in einer View wohnt.

## Zerlegung: warum P1 nur das Fundament ist

Der Gesamtwunsch — Testtarget, Entkernung von `ContentView` (3540 Zeilen, 65
Funktionen), Aufteilung in kleinere Views — hat die Größenordnung von M22
oder M23, die beide in Phasen liefen. Zerlegung, mit dem Maintainer am
2026-08-09 festgelegt:

| Phase | Inhalt |
|---|---|
| **P1 (dieser Meilenstein)** | Library-Split, dünnes `@main`-Target, zweites Testtarget, L10n-Härtung, Tests für die vorhandene Nicht-View-Logik. **Keine Verhaltensänderung.** |
| P2 | Der Submit-Pfad (Ziel-Set-, Jump-Set-, Jump-Sitzungs-Auflösung und ihre Reihenfolge) nach Core, als Entscheidungsfunktion mit Fehlerfall statt Text. Schließt M28s Lücke. |
| P3 | Restliche Nicht-View-Logik aus `ContentView`; die View in benannte Unter-Views zerlegt. |

**P1 zuerst**, weil P2 und P3 ihre Ergebnisse sonst nicht festnageln können.

### Eine Klarstellung, die den Zuschnitt geprägt hat

Kleine Unter-Views machen **nichts testbar**. Eine Unter-View ist wieder eine
View und hat ohne Rendering keine Zusicherungsfläche; dafür bräuchte es
XCUITest oder ViewInspector, beides in diesem Projekt bewusst nicht im
Einsatz. Das Aufteilen zahlt auf **Lesbarkeit** ein, die Entkernung auf
**Prüfbarkeit**. Beides lohnt, aber auf verschiedene Konten — deshalb sitzen
sie zusammen in P3 und nicht in P1.

## Zielaufbau

`MacSCPApp` wird zur Library **`MacSCPAppKit`**; alle heutigen Quellen und
Ressourcen ziehen unverändert mit, das Verzeichnis wird zu
`Sources/MacSCPAppKit/` umbenannt (statt den alten Pfad per `path:`
festzuhalten — ein Target, dessen Verzeichnis anders heißt als es selbst,
ist genau die Art stiller Abweichung, die dieser Meilenstein abschafft).

Daneben ein neues Executable-Target **`MacSCPMain`** unter
`Sources/MacSCPMain/` mit genau einer Datei:

```swift
import MacSCPAppKit

@main
struct Main {
    static func main() { MacSCPApp.main() }
}
```

Das `App`-Protokoll bringt `static func main()` mit, das Executable braucht
also keine eigene Szene. `MacSCPApp: App` bleibt als `public struct` im Kit.
Dazu ein zweites Testtarget **`macSCPAppKitTests`**.

**Das Produkt heißt weiter `macSCP`.** Damit bleibt der Binärname, und
`scripts/package-app` findet sein `$BIN` unverändert.

### Was der Umbau an Zugriffsebenen verlangt

Innerhalb eines Moduls ist `internal` sichtbar, die 36 App-Dateien brauchen
also **keine** Anpassung untereinander. `public` wird genau an einer Stelle
gebraucht: `MacSCPApp` selbst, damit das Executable es aufrufen kann. Wer
darüber hinaus `public` setzt, hat einen Fehler gemacht.

Das Testtarget nutzt `@testable import MacSCPAppKit` und sieht damit auch
`internal` — dieselbe Mechanik wie in `macSCPCoreTests`.

## Der Bundle-Name: die stille Falle

`L10n.bundle` sucht **einen fest verdrahteten Namen**, `macSCP_MacSCPApp.
bundle`, von SwiftPM aus `<Paket>_<Target>` gebildet. Nach der Umbenennung
heißt das Bundle `macSCP_MacSCPAppKit.bundle`. Findet die Suche nichts,
fällt sie auf `Bundle.main` zurück, und `NSLocalizedString` liefert den
`defaultValue` — **jeden App-String auf Englisch, ohne Absturz und ohne
roten Test.** In einem englischen Screenshot sähe alles korrekt aus.

Drei Stellen hängen am Namen, und sie verhalten sich unterschiedlich:

| Stelle | Verhalten bei falschem Namen |
|---|---|
| `scripts/package-app` | **laut** — `test -d` schlägt fehl |
| `scripts/release` | **laut** — `cp` bricht ab |
| `Sources/MacSCPApp/L10n.swift` | **still** — Fallback auf Englisch |

Der Maintainer hat sich am 2026-08-09 für Umbenennen **und** Härten
entschieden, nachdem die stille Klasse benannt war.

## Die L10n-Härtung — und warum sie mehr ist als Namenspflege

In einer Wegwerfsonde gegen die laufende Suite gemessen (2026-08-09,
Sonde danach gelöscht, `git status --porcelain` leer):

```
xctest bundleURL:  .build/arm64-apple-macosx/debug/macSCPPackageTests.xctest
parent:            .build/arm64-apple-macosx/debug
candidate exists:  true
localized:         "they store different credentials"
CoreL10n today:    core.login.mergeConflictingSecrets
```

Das Ressourcen-Bundle liegt **neben** dem Testbundle und lässt sich unter
`swift test` einwandfrei laden. Die heutige Suche findet es nicht, weil sie
`Bundle(for:).resourceURL` fragt — also **in** das `.xctest` hinein — statt
`Bundle(for:).bundleURL.deletingLastPathComponent()`, also **daneben**. Ein
einziger fehlender Kandidat.

**Beide Schichten bekommen diesen Kandidaten**, `L10n` wie `CoreL10n`. Damit
löst die Lokalisierung unter Tests erstmals echt auf, und darauf lässt sich
ein Wächter setzen: ein Test, der für einen bekannten Schlüssel den
**übersetzten Text** erwartet — nicht den Schlüssel, nicht den Fallback. Er
geht rot bei Umbenennung, bei fehlendem Schlüssel und wenn jemand den
Kandidaten wieder entfernt.

Damit schließt P1 den `CoreL10n`-Befund aus M28s Abschnitt 5, der bisher
eigener Backlog-Punkt war — samt seines falschen Doc-Kommentars, der genau
diese Eigenschaft schon behauptete.

### Der Nebeneffekt, der Arbeit macht

Dutzende bestehende `#expect(error == CoreL10n.string(…))` vergleichen heute
**Schlüssel mit Schlüssel** und können nicht scheitern. Nach dem Fix
vergleichen sie Text mit Text. **Einige davon werden rot** — nicht weil der
Fix falsch ist, sondern weil sie bisher nichts geprüft haben. Diese
Reparatur gehört zu P1 und ist ausdrücklich eingeplant.

Jeder so gefundene Fall wird im Abschlussbericht **einzeln benannt**: er ist
der Beleg, dass der Wächter greift.

## Was P1 an Tests mitbringt

Der Maintainer hat entschieden, die vorhandene Nicht-View-Logik gleich mit
festzunageln. **Nicht jede Datei verdient das**, und die Auslassungen werden
begründet statt verschwiegen — dieses Projekt hat zweimal notiert, dass ein
Test, dessen Zusicherung trivial erfüllt ist, kein Regressionsschutz ist.

| Datei | Zeilen | Tests? | Begründung |
|---|---|---|---|
| `EditorResolver` | 63 | **ja** | Endungs-/Regelauflösung, reine Funktion |
| `ExternalTerminalLauncher` | 160 | **ja** | Kommandobau; `LaunchError` ist bereits `Equatable` |
| `KeyboardShortcutsCatalog` | 71 | **ja** | Datenkatalog — Dubletten, Vollständigkeit, L10n-Schlüssel |
| `MenuBarStatusModel` | 30 | **ja** | Aggregation über Sitzungszustände |
| `SessionTab` | 153 | **ja** | `BrowserSession` + Tab-Zustand, ohne UI konstruierbar |
| `UpdateCheckModel` | 197 | **ja** | `UpdateAlertContent`-Ableitung, Versionsvergleich |
| `AppRelauncher` | 18 | **nein** | Startet einen Prozess; testbar wäre nur der Pfadbau, und der ist eine Zeile |
| `RemoteFilePromise` | 53 | **nein** | `NSFilePromiseProvider`-Unterklasse, von AppKit getrieben |
| `MenuBarController` | 219 | **nein** | `NSStatusItem`-Verdrahtung; braucht eine laufende App |
| `DesignTokens`, `PolishedButtonStyle` | 98 / 54 | **nein** | Konstanten und Stil — ein Test prüfte, dass eine Zahl dasteht |
| `L10n` | — | über den Wächter | siehe oben |
| `MacSCPApp` | 334 | **nein** | Einstiegspunkt und Szene |

**Korrektur zur Erkundung:** eine frühere Zählung führte 14 Dateien „ohne
View". `ImportConflictSheet` enthält sehr wohl eine (`private struct … :
View`) und fiel nur durch die Erkennung. Die belastbare Zahl testwürdiger
Dateien ist **sechs**.

## Was P1 ausdrücklich **nicht** ist

- **Keine Verhaltensänderung.** Die App tut danach exakt dasselbe. Jede
  beobachtete Abweichung ist ein Fehler, nicht ein Ergebnis.
- **Keine Entkernung von `ContentView`.** Das ist P2 und P3.
- **Keine View-Aufteilung.** P3.
- **Kein UI-Testing.** Weder XCUITest noch ViewInspector kommen ins Projekt;
  wenn P1 fertig ist, ist SwiftUI-Code weiterhin nicht per Test prüfbar, und
  das ist so gewollt.

## Risiken

- **Ressourcen-Bundling.** `.process("Resources")` zieht mit dem Kit um.
  Bricht das, sind Icons, Kataloge und der Shader betroffen. `package-app`
  prüft laut, aber erst am Ende.
- **Signierung und Verpackung.** `scripts/release` und `scripts/package-app`
  kennen den Bundle-Namen an drei Zeilen. **Nicht ausführen** — `release`
  veröffentlicht. Die Anpassung wird gelesen und gegen einen `package-app`-
  Lauf ohne Veröffentlichung geprüft.
- **Der stille Fallback.** Größtes Risiko des Meilensteins, und der Grund,
  warum der Wächter im selben Durchgang entsteht statt danach.
- **Rot werdende Bestandstests.** Erwartet, siehe oben. Ein Test, der nach
  dem Fix rot ist, wird **repariert, nicht zurückgedreht** — die Zusicherung
  war vorher wertlos.
- **CI.** Zwei Testtargets statt einem; die Laufzeit steigt. `timeout-minutes:
  20` bleibt.

## Erfolgskriterien

| # | Kriterium | Nachweis |
|---|---|---|
| 1 | Die App startet und verhält sich unverändert | `package-app`-Lauf, danach Sichtprüfung durch den Maintainer (die GUI startet **nicht** aus Reviews oder CI) |
| 2 | `MacSCPAppKit` ist eine Library, das Executable enthält nur den Einstieg | Die Executable-Quelle ist eine Datei mit `@main` und einem Aufruf |
| 3 | Genau ein Typ ist neu `public` | Review; mehr `public` heißt, der Split wurde falsch gezogen |
| 4 | `macSCPAppKitTests` existiert und läuft unter `swift test` | Testausgabe nennt beide Suiten-Mengen |
| 5 | Die Lokalisierung löst unter `swift test` echt auf | Ein Test erwartet den **übersetzten Text**, nicht den Schlüssel — für App- und Core-Schicht je einer |
| 6 | Der Wächter geht bei Umbenennung rot | Mutation: Bundle-Namen im Code verfälschen, Rot-Ausgabe wörtlich in den Bericht |
| 7 | Bestehende, bisher wirkungslose L10n-Zusicherungen sind repariert | Jeder rot gewordene Fall im Bericht **einzeln benannt** |
| 8 | Die sechs Nicht-View-Dateien haben Tests | Je Datei mindestens ein Test, der ohne die Logik rot würde |
| 9 | Die **sechs** ausgelassenen Dateien sind begründet, nicht vergessen | Dieser Abschnitt, im Bericht wiederholt: `AppRelauncher`, `RemoteFilePromise`, `MenuBarController`, `DesignTokens`, `PolishedButtonStyle`, `MacSCPApp` |
| 10 | Verpackung und Signierung funktionieren mit dem neuen Namen | `package-app`-Lauf grün, `release` **nur gelesen** |
| 11 | Kein Secret-Wert in Meldung, Log oder Testfehlertext | Review |

## Für die Release-Notes

**Keine Zeile.** P1 ändert nichts, was ein Nutzer sieht. Das ist die
Erfolgsbedingung, nicht ein Mangel.

## Offen, bewusst nicht Teil von P1

- P2 (Submit-Pfad nach Core) und P3 (Entkernung + View-Aufteilung).
- Der veraltete Slot einer set-gebundenen Sitzung.
- Die Editor-Reibung beim Bearbeiten eines Login-Sets.
- Der Ziel-Picker ohne `kind`-Wächter — heute nur durch einen
  Namensraum-Zufall harmlos.
- Ein app-weiter Audit-Bereich.
- Der Release-Stau: 385 Commits vor `origin/main`.
- Der 0-%-CPU-Testsuite-Hänger.
