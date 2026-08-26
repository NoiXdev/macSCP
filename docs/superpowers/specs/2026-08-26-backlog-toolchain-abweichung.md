# Backlog: Toolchain-Abweichung zwischen Arbeitsplatz und CI

**Status:** offen
**Aufgenommen:** 2026-08-26, nach einem roten CI-Lauf auf `develop`

## Was passiert ist

Lauf `32938674467` ist am Build gescheitert, nicht an einem Test:

```
Sources/MacSCPAppKit/ContentView+Lifecycle.swift:233:45:
error: expression is 'async' but is not marked with 'await'
```

Die Zeile las `settingsStore.connectTimeoutSeconds`. `SettingsStore` ist
`@MainActor`; `ConnectionViewModel.Connector` ist ein nicht isolierter
`@Sendable`-Funktionstyp. Ob die Connector-Closure selbst als
Main-Actor-isoliert gilt, entscheidet damit die Closure-Isolationsinferenz
des Compilers — und genau die unterscheidet sich:

| | Swift | Ergebnis |
|---|---|---|
| Arbeitsplatz | 6.3.3 (macOS 26) | baut |
| CI (`macos-15`) | älter | Fehler |

Behoben in `750ccc6` mit einem expliziten `await MainActor.run { … }`, das
beide Compiler akzeptieren.

## Warum das ein Backlog-Eintrag ist und keine erledigte Sache

Der Fix beseitigt den einen Fundort. Er beseitigt nicht die Ursache: **ein
grüner lokaler Build ist kein Beleg über den CI-Build.** Die gesamte
Aussage „2648 Tests grün" vor dem Push bezog sich ausschließlich auf die
lokale Toolchain. Für alles, was von Nebenläufigkeits-Inferenz abhängt,
sagt sie nichts.

Das trifft dieselbe wiederkehrende Lektion wie die Shell-Klassifikation
weiter oben im Backlog: als Orakel wurde die *lokale* Umgebung befragt,
obwohl die Aussage über eine *andere* gelten sollte.

## Mögliche Wege (nicht entschieden)

1. **Zweiter CI-Job auf `macos-26`.** Billig, und es ist eine Messung
   statt einer Annahme: beide Inferenz-Regime werden tatsächlich gebaut.
   Deckt nur ab, verhindert nicht.
2. **Feature-Flags in `Package.swift` festnageln.** Vermutlich geht die
   Abweichung auf `NonisolatedNonsendingByDefault` (SE-0461) zurück, das
   der neuere Compiler voreingestellt hat. *Vermutlich* — nachgemessen ist
   das nicht, dazu fehlt hier die ältere Toolchain. Wenn es stimmt, bringt
   ein explizites Flag beide Compiler zur Deckung und behebt die Klasse,
   nicht den Fundort.
3. **Xcode in CI anheben**, sodass CI der Arbeitsplatzversion folgt.
   Verschiebt die Abweichung nur, sobald der Arbeitsplatz erneut vorauszieht.

Weg 2 ist der einzige, der die Klasse schließt — und der einzige, der vor
der Umsetzung eine Messung braucht.

## Nebenbefund

`ContentView+Lifecycle.swift` ist die einzige Fundstelle gewesen. Der
Compiler bricht die Datei allerdings beim ersten Fehler ab; ob hinter
dieser Zeile weitere Stellen derselben Klasse liegen, zeigt erst ein
grüner Lauf.
