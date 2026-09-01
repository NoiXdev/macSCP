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
Versionsstand liegt weit hinter Apples 0.15.0.

### Gemessen am 2026-08-26

Die offene Frage — führt der Fork Apples Zweig nach oder geht er eigene Wege —
ist beantwortet. Beide Repositorien in ein leeres Arbeitsverzeichnis geholt
und die Historien verglichen:

| | |
|---|---|
| Gemeinsame Basis mit `apple/main` | `b0591e4c`, **2022-04-21** |
| Commits, die der Fork seit der Basis hinzufügt | 76 |
| **Commits, die Apple seit der Basis hat und hier nie ankommen** | **91** |
| Zweig des angehefteten Commits | `citadel2`, in keinem Apple-Zweig enthalten |
| Angehefteter Commit | `a05e6bbe`, 2026-04-02, Mac-Catalyst-Fix |

Der Fork führt Apple also **nicht** nach: er ist vor über vier Jahren
abgezweigt und seitdem eigene Wege gegangen. Die Nummerierung ist ebenfalls
eigen — Apple hat gar keinen Tag `0.3.6`. Was in Apples 91 Commits steckt,
ist damit noch nicht bewertet; dass es **nicht** hier ankommt, ist es.

### Was in Apples 91 Commits steckt (bewertet 2026-08-26)

Der Fork ist erkennbar ein **Funktions-Fork**, kein verdächtiger: RSA-Schlüssel
auf der Client-Seite, eigene Transport- und Schlüsselaustausch-Algorithmen,
Zertifikats-Authentifizierung, Plattformunterstützung (visionOS, Musl, Bionic,
Mac Catalyst). Nachvollziehbare Gründe, die Apples Mainline nicht übernommen
hat. Sein letzter Merge von `apple/main` ist vom **2022-05-06**; alles danach
fehlt.

Von Apples 91 Commits sind die meisten CI, Benchmarks und Swift-Versionssprünge.
Relevant bleibt dreierlei:

**1. Die Nebenläufigkeits-Übernahme — und sie kostet uns bereits etwas.**
Apple hat `Sendable` 2023 vollständig übernommen (#151) und 2025 strikte
Nebenläufigkeit nachgezogen (#196, #197, #200). Beim Fork kam nichts davon an:

| | Fork (ausgeliefert) | `apple/main` |
|---|---|---|
| `NIOSSHUserAuthenticationOffer` | `public struct … {` | `public struct …: Sendable {` |

Das ist **einer der sechs Fehler**, die eine Umstellung auf
`.swiftLanguageMode(.v6)` in `macSCPCore` heute auswirft. Wir würden also eine
Umgehung für etwas bauen, das drei Jahre lang stromaufwärts behoben ist und
uns nur nicht erreicht. (Der zweite Citadel-Fehler betrifft
`SSHAuthenticationMethod` — eine `public final class` von Citadel selbst,
nicht vom Fork.)

**2. Die Härtung von 2026 fehlt.** `Limit buffered state` (#244),
`Configurable max packet size` (#245) und `Limit client auth attempts` (#247)
sind Schranken gegen einen Gegenüber, der zu viel schickt. Für einen Client,
der sich mit fremden Servern verbindet, ist vor allem die erste einschlägig.

**3. Apples Absturz-Fix ist für uns gegenstandslos — aus einem Grund, der
selbst der Befund ist.** `Fix readVersion() crash on bare LF as first byte`
(#238, 2026-06) bewacht einen `advanced(by: -1)`-Zugriff. Diesen Code gibt es
im Fork nicht: `readVersion` ist dort **vollständig neu geschrieben** (Schleife
über Zeilen, Vorzeilen werden übersprungen bis eine mit `SSH-` beginnt, kein
Index-Rechnen). Der Absturz existiert bei uns also nicht.

Die Kehrseite: die Zeichenkettenzerlegung, die ein Client als **allererstes auf
unauthentifizierte Bytes eines fremden Servers** anwendet, ist beim Fork
Eigenbau und hat Apples Prüfung nie durchlaufen. Das ist keine Feststellung
eines Fehlers — nur die Feststellung, wo die Beweislast liegt.

### Ein Ausweichen ist nicht bloß Geschmackssache

Getestet, ob sich Apples Paket im Wurzelmanifest erzwingen lässt (`.package`
auf `apple/swift-nio-ssh` ab 0.15.0, danach zurückgenommen). Die Auflösung
scheitert:

```
error: Dependencies could not be resolved because root depends on
'citadel' 0.12.1..<1.0.0 and root depends on 'swift-nio-ssh' 0.15.0..<1.0.0.
```

Citadel schreibt in seinem eigenen Manifest den Bereich `"0.3.4" ..< "0.4.0"`
fest. **Ohne Citadel selbst zu ändern, führt kein Weg an dem Fork vorbei** —
ein Versions-Override im Wurzelpaket genügt nicht. Damit fällt der Weg
„einfach auf Apple umbiegen" weg; übrig bleiben: Citadel-Upstream ansprechen,
Citadel selbst forken, oder auf Sicht bleiben und die Lage dokumentieren.

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

---

## Gemessen 2026-08-31 — der Fork-Befund, und warum ein Citadel-Fork nichts löst

**Die Kette ist eine andere, als der Eintrag oben annimmt.** Citadel hängt
nicht an `swift-nio-ssh`, sondern an einem **nie gemergten Feature-Branch**
davon (`jo-rsa-private-keys`, vom Citadel-Autor selbst). `Wellz26` ist ein
Fork *dieses* Forks, der den PR weiterträgt — und Citadels eigenes
`Package.swift` verdrahtet ihn fest:

```
.package(url: "https://github.com/Wellz26/swift-nio-ssh.git", "0.3.4" ..< "0.4.0")
```

### Ein Citadel-Fork kann das nicht beheben

Gemessen gegen Apple 0.15.0: **52 distinkte Fehlerstellen** (277 rohe
`error:`-Zeilen) auf 7 von 37 Citadel-Dateien, **13 Root Causes** in **4
Familien**. **38 von 52** entfallen auf eine einzige: Apple exportiert fünf
öffentliche Protokolle, davon **einen** Algorithmus-Erweiterungspunkt
(`NIOSSHTransportProtection`). Die Maschinerie für Key Exchange und
Public-Key-Typen ist bei Apple `internal`.

Kein Rename, kein Signatur-Drift — zwei unabhängige Entwicklungen seit 2022.
`NIOSSHTransportProtection` ist **beidseitig** divergiert.

**Der Satz, der die Richtung entscheidet:**

> `grep "ssh-rsa|rsa-sha2"` über Apple 0.15.0 = **0 Treffer**

Apples swift-nio-ssh hat **kein RSA**. Citadels gesamter RSA-Support steht
auf den fork-eigenen Protokollen — also genau der Fläche, auf der PR #135
aufsetzt. Zurück zu Apple **entfernt** RSA, statt es zu reparieren.

### Kein billiger Zwischenschritt

Gemessen, nicht überlegt: Apple 0.4.1–0.8.0 scheitern schon an der Auflösung
(swift-crypto `<3.0.0` gegen Citadels `3.12.3+`). Der kleinstmögliche
auflösbare Sprung ist 0.9.1 — **54** Fehlerstellen, zwei *mehr* als 0.15.0,
und ohne einen einzigen Sicherheitsfix.

### Der Fork ist kein Spiegel

Fork-Punkt ist Apple **0.4.0** (2022-04-21), nicht 0.3.x — die Tags
`0.3.4`–`0.3.6` sind Fiktion, Apples höchster 0.3.x ist 0.3.3. Citadels
Range ist gegen Apples Repo unerfüllbar. **76 Commits** (54 non-merge), 58
Dateien, +1278/−354, **91 Apple-Commits** Distanz.

## Was daraus folgt: Sicherheit und Architektur sind trennbar

Das ist der Ausweg, den die Messung selbst gefunden hat.

**Die Architektur** — zurück auf Apples gepflegte Bibliothek — ist ein
echter Port (54 Commits rebasen) **und danach dauerhafte Pflege**, mit
demselben Single-Point-of-Failure, an dem der jetzige Zustand gescheitert
ist. Verschoben, nicht gelöst.

**Die Sicherheit** ist billig und getrennt davon zu haben. Von Apples drei
jüngeren Korrekturen betreffen macSCP als **Client** zwei:

| Fix | betrifft macSCP |
|---|---|
| **0.14.1** — überlange ECDSA-Signatur-mpints ablehnen (`31cdc3c`, +70/−2, ~11 Zeilen Produktivcode) | **ja**, macSCP parst Server-Signaturen |
| **0.14.0** — Absturz bei kaputten Versionsstrings | **ja**, ein bösartiger Server könnte den Client abstürzen lassen |
| 0.15.0 — Anmeldeversuche begrenzen | **nein**, Serverschutz |

**Ungemessen:** ob die beiden sauber aufsetzen. Der 0.14.1-Fix liegt in
`NIOSSHSignature.swift`, einer vom Fork veränderten Datei — Konfliktzone.
Das ist der erste Schritt, bevor irgendetwas zugesagt wird.

**Und der Preis, der genannt gehört:** ein Cherry-Pick heißt zwei eigene
Repos — swift-nio-ssh (für die Fixes) und Citadel (eine Zeile, um darauf zu
zeigen). Ob SwiftPM das auch ohne den Citadel-Fork über eine
Abhängigkeits-Übersteuerung kann, ist messbar und wäre billiger.

**Was das nicht behebt:** RSA aus der Datei. Das wartet auf Citadels #135.
Genau diese Trennung ist der Ertrag der Messung — vorher sah es aus wie ein
Problem, es sind zwei, und nur eines ist billig.
