# Swift-6-Sprachmodus — Umsetzungsplan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Die Warnungen abtragen, `macSCPCore` auf `.swiftLanguageMode(.v6)` bringen und den Stapel gegen Nachwachsen sperren.

**Architektur:** Kein Umbau der App. Der Eingriff ist eine Semantikumstellung des Compilers plus die Anpassungen, die sie erzwingt — überwiegend in Test-Doubles, die heute mit `NSLock` in `async`-Methoden arbeiten.

**Reihenfolge:** von den eigenen Sachen zu den fremden, und von `macSCPCore` nach oben. Jede Aufgabe endet mit einer grünen Suite.

---

## Der gemessene Ausgangszustand (2026-08-26)

Der Backlog-Eintrag sprach von „rund 1200 Warnungen". Das war eine Zeilenzahl.
Nachgezählt sind es **37 eindeutige Fundorte**; dieselben Stellen werden über
mehrere Kompilierdurchgänge im Schnitt siebzehnmal gedruckt.

| Datei | Fundorte | Art |
|---|---|---|
| `Tests/macSCPCoreTests/TerminalPanelViewModelTests.swift` | 14 | `lock`/`unlock` aus async-Kontext |
| `Tests/macSCPCoreTests/WebDAVFileSystemTests.swift` | 7 | dieselbe |
| `Tests/macSCPCoreTests/S3UploaderTests.swift` | 3 | dieselbe |
| `Tests/macSCPCoreTests/GitHubReleaseFetcherTests.swift` | 3 | Mutation einer eingefangenen `var` nebenläufig |
| `Tests/macSCPCoreTests/TagSuggestionRankingEquivalenceTests.swift` | 2 | `try` ohne werfenden Aufruf |
| `Tests/macSCPCoreTests/ConnectFailureSecrecyTests.swift` | 2 | `try` ohne werfenden Aufruf |
| `Tests/macSCPCoreTests/LoginSetExportImportTests.swift` | 2 | ungenutzter Wert |
| `Tests/macSCPCoreTests/AgentAuthTests.swift` | 1 | `syncShutdownGracefully` blockierend |
| `Sources/macSCPCore/SSH/CitadelFileSystem.swift` | 2 | nicht-`Sendable`-Fang; fehlendes `@preconcurrency` |
| `Sources/macSCPCore/RemoteFS/TransferEngine.swift` | 1 | nicht-`Sendable`-Fang |

**34 der 37 stehen in Tests, 3 in `Sources`.**

Getrennt davon gemessen, durch versuchsweises Umstellen und Zurücknehmen:
`macSCPCore` allein wirft unter `.v6` **sieben Fehler**. Warnungen und Fehler
sind fast disjunkt — der v5-Modus diagnostiziert die meisten dieser Fälle gar
nicht erst.

**Zur Zählung, weil sie beim ersten Versuch danebenlag:** ein `.v6`-Build zeigt
nur fünf. Der Compiler bricht nicht nur beim ersten fehlschlagenden *Target*
ab, sondern auch **innerhalb einer Datei beim ersten Fehler**. Die erste
Messung dieses Plans nannte deshalb sechs und war selbst eine Untergrenze. Die
vollständige Liste liefert `.v5` mit `-Xswiftc -strict-concurrency=complete`,
wo dieselben Prüfungen als Warnungen laufen und jede Datei zu Ende geprüft
wird. Die Fehlerliste steht bei Task 4+5.

Was der Build **nicht** erreicht, solange `macSCPCore` nicht baut:
`MacSCPAppKit`, `MacSCPCLI` und beide Testziele. Was dort auf uns wartet, ist
**unbekannt, nicht null** — ein Zwischenbefund aus Task 1 nennt 31 Fehlerorte
in anderen Testdateien, sobald nur `macSCPCoreTests` umgestellt wird. Das ist
Task 6, und deshalb hat Task 6 einen Anhaltepunkt statt eines Auftrags.

## Global Constraints

- Code, Kommentare, Bezeichner, Testnamen, Commit-Messages: **nur Englisch**;
  Katalogwerte sind Übersetzungen, Deutsch duzt.
- Conventional Commits; Footer `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- **Kein Test erreicht echten Keychain, Sitzungs-Store oder Konfiguration.**
- **Keine Zeilennummern, keine Ortsangaben in Kommentaren.** Jede Zahl und
  jede Aufzählung von Aufrufstellen wird in dem Durchgang gezählt, der sie
  schreibt.
- **Verhalten bleibt gleich.** Diese Arbeit ändert Nebenläufigkeits-Annotationen
  und Test-Doubles, nicht das, was die App tut. Ändert eine Aufgabe fachliches
  Verhalten, ist das ein Fehler in der Aufgabe, kein Fortschritt.
- **Eine Sperre still zu entschärfen ist kein Fix.** `@preconcurrency`,
  `nonisolated(unsafe)` und `@unchecked Sendable` unterdrücken die Diagnose,
  ohne das Datenrennen zu beseitigen. Jede solche Stelle braucht im Kommentar
  das Argument, **warum es an dieser Stelle kein Rennen gibt** — nicht bloß den
  Hinweis, dass der Compiler sonst meckert.
- **Lokal grün ist kein Beleg über CI.** Dieser Rechner hat Swift 6.3.3, CI eine
  ältere Toolchain, und die beiden urteilen bei Nebenläufigkeits-Inferenz
  unterschiedlich — das hat am 2026-08-26 einen roten Build gekostet
  (`docs/superpowers/specs/2026-08-26-backlog-toolchain-abweichung.md`).
  Für jede Aufgabe ab Task 4 gilt: **grün heißt grün auf CI**, und der
  Koordinator wartet den Lauf ab, bevor die nächste Aufgabe startet.
- Die App wird nicht gestartet, `scripts/release` wird nicht ausgeführt.

---

### Task 1: Die Sperren in den Test-Doubles

**Files:**
- Modify: `Tests/macSCPCoreTests/TerminalPanelViewModelTests.swift` (14),
  `Tests/macSCPCoreTests/WebDAVFileSystemTests.swift` (7),
  `Tests/macSCPCoreTests/S3UploaderTests.swift` (3)

**Der gemessene Ist-Zustand:** alle 24 sind dasselbe Muster — ein
`private let lock = NSLock()` in einem Test-Double, dessen `async`-Methoden
`lock()`/`unlock()` aufrufen. Beide Methoden sind `noasync`; im v6-Modus ist
das ein Fehler.

**Was den Weg schon kennt:** `Tests/macSCPCoreTests/S3FileSystemTests.swift`
verwendet für denselben Zweck einen `actor` — die Aufrufstellen lesen dort
`let requests = await transport.requests`.

- [ ] **Step 1: Die Ersetzung wählen, an EINER Datei, gemessen statt geraten.**
  Drei Kandidaten, jeder mit einem anderen Preis:

  | Weg | Preis |
  |---|---|
  | `NSLock.withLock { }` | kleinster Eingriff — **aber erst nachmessen, ob es die Diagnose überhaupt beendet** |
  | `Mutex` aus `Synchronization` | passt zum Mindestziel macOS 15, ist `Sendable` — neuer Import in den Tests |
  | `actor` | die eigentlich richtige Form; **ändert jede Aufrufstelle zu `await`** |

  Nimm `S3UploaderTests.swift` (3 Fundorte, kleinste Fläche), setze **alle
  drei** um, baue jedes Mal und schreib in den Bericht, welche die Warnung
  wirklich beendet und was sie an Aufrufstellen kostet. Erst dann entscheiden.

- [ ] **Step 2:** Die gewählte Form auf die anderen beiden Dateien anwenden.
- [ ] **Step 3:** Volle Suite grün, und `swift build --build-tests` zeigt für
  diese drei Dateien **null** Fundorte. Beides im Bericht mit der gezählten
  Zahl davor und danach.
- [ ] **Step 4: Commit** — `refactor(tests): take the locks out of async test doubles`

---

### Task 2: Die restlichen zehn Warnungen in den Tests

**Files:**
- Modify: `GitHubReleaseFetcherTests.swift` (3), `TagSuggestionRankingEquivalenceTests.swift` (2),
  `ConnectFailureSecrecyTests.swift` (2), `LoginSetExportImportTests.swift` (2),
  `AgentAuthTests.swift` (1)

**Vier verschiedene Arten, jede mit einer eigenen Frage:**

- [ ] **Step 1: Mutation einer eingefangenen `var` (3, `GitHubReleaseFetcherTests`).**
  Das ist die einzige der vier, die **ein echtes Datenrennen benennt**. Prüfen,
  ob der Test dabei tatsächlich nebenläufig schreibt. Wenn ja, ist es ein
  Testfehler, kein Annotationsproblem — dann so beheben, dass der Test danach
  noch dasselbe behauptet.
- [ ] **Step 2: `try` ohne werfenden Aufruf (4, in zwei Dateien).** Das `try`
  entfernen. **Vorher prüfen, ob der aufgerufene Ausdruck einmal geworfen hat**
  — ein verwaistes `try` ist oft der Rest einer Signatur, die sich geändert
  hat, und dann ist die Frage, ob der Test noch prüft, was er prüfen sollte.
- [ ] **Step 3: Ungenutzter Wert (2, `LoginSetExportImportTests`).** Warum ist
  er ungenutzt? Wenn ein Test einen Wert bindet und nie ansieht, fehlt
  möglicherweise eine Erwartung. Erst das klären, dann entweder eine Erwartung
  ergänzen oder die Bindung entfernen — im Bericht sagen, welches von beidem
  und warum.
- [ ] **Step 4: `syncShutdownGracefully` (1, `AgentAuthTests`).** Blockiert den
  aufrufenden Thread aus async-Kontext — dieselbe Klasse wie der Wettrennen-Fix
  in `LoopbackHTTPStub` vom selben Tag. Auf das asynchrone Gegenstück umstellen.
- [ ] **Step 5:** Volle Suite grün; gezählte Warnungen in `Tests/` sind **null**.
- [ ] **Step 6: Commit** — `refactor(tests): clear the last Swift 6 warnings`

---

### Task 3: Die drei in `Sources`

**Files:**
- Modify: `Sources/macSCPCore/RemoteFS/TransferEngine.swift`,
  `Sources/macSCPCore/SSH/CitadelFileSystem.swift`

- [ ] **Step 1: `TransferEngine` — `AsyncThrowingStream.Iterator` in einer
  `@Sendable`-Closure.** Ein Iterator ist zustandsbehaftet; ihn über eine
  Closure-Grenze zu reichen ist genau das, wovor die Diagnose warnt. Klären,
  ob der Iterator dort tatsächlich nur von einer Stelle bedient wird. Ist das
  so, gehört das Argument in den Kommentar; ist es nicht so, ist es ein Fehler
  in ausgeliefertem Code und der Befund wiegt schwerer als diese Aufgabe —
  **dann melden statt reparieren.**
- [ ] **Step 2: `CitadelFileSystem` — `SFTPFile` in einer `@Sendable`-Closure.**
  Gleiche Frage, gleiche Regel.
- [ ] **Step 3: `@preconcurrency import Citadel`.** Das ist eine Unterdrückung
  und keine Behebung. Sie ist hier trotzdem richtig, weil die Annotationen
  einem fremden Paket gehören — aber der Kommentar muss sagen, **was** dadurch
  ungeprüft bleibt, nicht bloß, dass der Compiler dann schweigt.
- [ ] **Step 4:** Volle Suite grün; gezählte Warnungen im ganzen Projekt: **null**.
- [ ] **Step 5: Commit** — `refactor(core): answer the last Sendable warnings`

---

### Task 4+5: `macSCPCore` auf `.v6` — alle sieben Fehler

> **Zusammengelegt am 2026-08-26**, nachdem die Erkundung beide Anhaltepunkte
> gezogen hat. Alle Fehler liegen in `macSCPCore`; das Target kompiliert erst,
> wenn alle weg sind. Getrennte Aufgaben könnten weder grün werden noch einen
> Commit tragen, dessen Nachricht stimmt.

**Files:**
- Modify: `Package.swift` (nur die Zeile für `macSCPCore`),
  `Sources/macSCPCore/Presentation/FileListFormatter.swift`,
  `Sources/macSCPCore/S3/S3ListParser.swift`,
  `Sources/macSCPCore/WebDAV/WebDAVSessionDelegate.swift`,
  `Sources/macSCPCore/SSH/AgentBackedPrivateKey.swift`,
  `Sources/macSCPCore/SSH/CitadelShell.swift`

**Korrigierte Messung.** Der Plan war gegen sechs Fehler geschrieben; es sind
**sieben**, und die Zusammensetzung ist eine andere. Der Grund für den
Zählfehler gehört zur Aufgabe, weil er jede weitere Zählung betrifft: **der
Compiler bricht auch innerhalb einer Datei beim ersten Fehler ab.** Ein
`.v6`-Build zeigt deshalb nur fünf. Die vollständige Liste liefert
`.v5` mit `-Xswiftc -strict-concurrency=complete`, wo dieselben Prüfungen als
Warnungen laufen und jede Datei zu Ende geprüft wird.

| Fehler | gehört |
|---|---|
| `FileListFormatter.byteFormatter` nicht `Sendable` | uns |
| `S3ListParser.dateFormatterWithFractionalSeconds` | uns |
| `S3ListParser.dateFormatter` | uns |
| `WebDAVSessionDelegate`: `Task {` im Server-Trust-Arm | uns |
| `AgentBackedPrivateKey`: `NIOSSHUserAuthenticationOffer` | **Fork** |
| `CitadelShell`: `let pump = Task {` fängt `SSHClient` | **Citadel** |
| `CitadelShell`: `pending?.resume(with:)` mit `TTYStdinWriter` | **Citadel** |

`SSHAuthenticationMethod` stand im ursprünglichen Plan und **existiert nicht
mehr** — Task 3s `@preconcurrency import Citadel` hat es miterledigt.

**Reihenfolge: fremd → eigen → Flip.** Die fremden zuerst, weil sie die
Fläche bestimmen; der Flip zuletzt in demselben Commit, damit es keinen
Zwischenstand gibt, in dem das Target nicht baut.

- [ ] **Step 1: Die drei fremden Typen.** `NIOSSHUserAuthenticationOffer`
  (Fork), `SSHClient` und `TTYStdinWriter` (Citadel). Umgehung wählen und im
  Kommentar **beides** festhalten: warum an dieser Stelle kein Rennen
  entsteht, und dass Apple den ersten Typ seit 2023 als `Sendable` führt, der
  Fork den Merge aber nie bekommen hat. Zeiger auf
  `docs/superpowers/specs/2026-08-20-backlog-abhaengigkeiten.md`.
- [ ] **Step 2: Die drei Formatierer.** „Pro Verwendung erzeugen" scheidet
  aus, gezählt statt angenommen: `sizeString` hängt am view-basierten
  Datenquellen-Callback einer `NSTableView` — pro sichtbarer Zeile **und**
  Spalte, bei jedem `reloadData` und beim Scrollen, also nicht durch die
  Dateizahl begrenzt. `parseDate` läuft im XMLParser-Delegaten pro
  `<LastModified>`, bis zu 1000 Objekte je `ListObjectsV2`-Seite. `Mutex`
  nach dem Muster von Task 1.
- [ ] **Step 3: `WebDAVSessionDelegate`.** Geklärt: `URLSession` ruft die
  Delegatenmethoden auf einer eigenen seriellen Queue (`delegateQueue: nil`),
  und den `completionHandler` ruft im Server-Trust-Arm genau eine Stelle genau
  einmal — die `Task` nach `decideCertificate`. **Weiterreichen an eine eigene
  Methode mit `sending`-Parameter, nicht die `Task` entfernen**: das würde den
  Zeitpunkt der Zertifikatsentscheidung verschieben, und das wäre eine
  Verhaltensänderung an sicherheitsrelevantem Code.
- [ ] **Step 4: Flip.** `.v5` → `.v6`, **nur** für `macSCPCore`.
- [ ] **Step 5: Die neuen Warnungen zählen.** Der Flip bringt gemessen **sechs
  neue Warn-Fundorte** mit (`HTTPTransport`, `TransferEngine` ×2,
  `CitadelFileSystem` ×2, `AgentBackedPrivateKey`), die es unter `.v5` nicht
  gibt. Sie im Bericht auflisten. Ob sie in dieser Aufgabe beseitigt werden
  oder in eine eigene gehören, entscheidet ihre Art — aber sie **still stehen
  zu lassen wäre der Rückfall in genau den Zustand**, den dieser Plan beendet.
- [ ] **Step 6:** Volle Suite grün **und CI grün**. Erwartet wird hier ein
  achter Fehler, der lokal nicht auftritt: dieses SDK führt `DateFormatter`
  als `Sendable`, `ByteCountFormatter` und `ISO8601DateFormatter` nicht — ob
  die ältere CI-Toolchain dieselben Annotationen hat, ist **nicht gemessen**.
- [ ] **Step 7: Commit** — `build(core): move macSCPCore to the Swift 6 language mode`

---

### Task 6: Messen, was die oberen Schichten kosten

**Files:** zunächst keine — dies ist eine Messung mit einem Entscheidungspunkt.

**Warum eigen:** Der Build bricht heute in `macSCPCore` ab. Was
`MacSCPAppKit`, `MacSCPCLI` und die beiden Testziele unter `.v6` auswerfen,
ist **unbekannt, nicht null**. `MacSCPAppKit` ist SwiftUI und voller
`@MainActor` — dort ist mit deutlich mehr zu rechnen als in Core.

- [ ] **Step 1:** Alle übrigen Targets auf `.v6`, bauen, Fehler zählen und
  nach Target **und Art** gruppieren.
- [ ] **Step 2: Entscheidungspunkt.** Liegt die Zahl in derselben Größenordnung
  wie in Core (einstellig bis niedrig zweistellig), in dieser Aufgabe beheben.
  Ist sie deutlich größer, **anhalten**, die Gruppierung berichten und einen
  eigenen Plan verlangen. Eine Aufgabe, die unbekannt groß ist, wird nicht
  dadurch klein, dass man sie anfängt.
- [ ] **Step 3:** Volle Suite grün **und CI grün**.
- [ ] **Step 4: Commit** — `build: move the remaining targets to the Swift 6 language mode`

---

### Task 7: Die Sperre gegen Nachwachsen

**Files:**
- Modify: `.github/workflows/ci.yml`

**Warum diese Aufgabe den Ausschlag gibt:** 37 Warnungen zu beheben kauft
nichts Dauerhaftes. Am 2026-08-26 sind an einem Vormittag sechs neue
entstanden und nur zufällig aufgefallen. Ohne Sperre wächst der Stapel
genauso schnell nach, wie er abgetragen wurde.

- [ ] **Step 1:** Entscheiden zwischen `-warnings-as-errors` und einer
  gezählten Schranke. Die Frage, an der es hängt: **Warnungen aus
  Abhängigkeiten**. Bauen die Pakete unter dieser Fahne noch? Das messen,
  nicht annehmen — heute stammen zwar alle Fundorte aus eigenem Code, aber die
  Fahne wirkt auch auf fremde Ziele.
- [ ] **Step 2:** Die Sperre einbauen und **beweisen, dass sie greift**: eine
  Warnung absichtlich einbauen, CI rot sehen, zurücknehmen. Ein Gate, das nie
  rot war, ist eine Behauptung.
- [ ] **Step 3: Commit** — `ci: fail the build on new compiler warnings`

---

## Was ausdrücklich nicht dazugehört

- **Keine Abhängigkeitssprünge.** Citadel steht bereits auf dem neuesten Tag
  (0.12.1); swift-nio, SwiftTerm und swift-crypto sind eigene Vorgänge mit
  eigenen Fragen — siehe den Abhängigkeits-Eintrag.
- **Kein Angehen des swift-nio-ssh-Forks.** Task 5 baut Umgehungen und
  dokumentiert die Lage; ob der Fork weggehört, ist eine Entscheidung des
  Maintainers und kein Nebenbei.
- **Kein Verhaltensumbau.** Wo eine Warnung ein echtes Rennen benennt, wird
  es behoben; wo sie eine Annotation verlangt, wird annotiert. Alles andere
  ist eine andere Aufgabe.
