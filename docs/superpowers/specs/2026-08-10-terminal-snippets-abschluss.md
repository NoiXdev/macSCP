# Terminal-Snippets — Abschlussbericht

**Status:** abgeschlossen 2026-08-10. HEAD vor diesem Bericht: `d1db769`.

Wiederverwendbare Kommandozeilen, die sich aus dem Terminal-Menü in das
SSH-Terminal-Panel einfügen — oder, ausdrücklich markiert, sofort ausführen —
lassen. `Snippet`, `SnippetStore` und `SnippetKeystrokes` liegen in Core und
sind vollständig geprüft; `SnippetsSheet` und die Menü-Verdrahtung sind
App-seitig und bleiben ungepinnt.

Der Meilenstein hat **zwei echte Befunde**, und beide sitzen nicht dort, wo
der Plan sie erwartet hätte: der Zeilenabschluss musste gemessen werden, und
das Auslösen wäre auf einem frisch verbundenen Tab **stumm ins Leere**
gelaufen. Beide stehen unten in eigenen Abschnitten.

Spec: `2026-08-10-terminal-snippets-design.md`.
Plan: `../plans/2026-08-10-terminal-snippets.md`.

## Commits

Basis des Meilensteins: `7a1777b` (der Plan-Commit selbst).

| Commit | Inhalt |
|---|---|
| `7a1777b` | Plan (= Basis) |
| `f7457d6` | T1 — `Snippet` + `SnippetStore` |
| `af9dba2` | T2 — `SnippetKeystrokes` und der **gemessene** Zeilenabschluss |
| `1ae8416` | T2 Fix-Runde — zwei überzogene Kommentar-Behauptungen |
| `7b4d92c` | T3 — `SnippetsSheet` |
| `b8152c0` | T4 — Einträge im Terminal-Menü + Shortcuts-Katalog |
| `d1db769` | T4 Fix-Runde — die Wartepolitik nach Core, `Divider()`, stiller Timeout entfernt |

**Unversendet:** `git rev-list --count origin/develop..develop` → **9** vor
diesem Bericht, **10** danach. **Release-Stau:**
`git rev-list --count origin/main..develop` → **419** (420 nach diesem
Commit); die Spec nannte beim Start 410, M29-P2 nannte 408.

Milestone-Diff (`git diff --shortstat -M 7a1777b..HEAD -- Sources Tests`):
**15 Dateien, +1060 / −2**. Die drei neuen Core-Dateien tragen +60
(`Snippet.swift`), +49 (`SnippetKeystrokes.swift`) und +46
(`SnippetStore.swift`), die neue App-Datei `SnippetsSheet.swift` +308; die
zwei neuen Testdateien +81 und +91.

## Verifikation zum Abschluss

Alles Folgende wurde **in dieser Sitzung ausgeführt**. Wo etwas aus einem
Task-Bericht übernommen ist, steht es ausdrücklich dabei.

| Lauf | Ergebnis |
|---|---|
| `swift build` | `Build complete! (5.34s)` |
| `swift test` | **1749 Tests in 143 Suiten, grün** (3,655 s) |
| `docker compose -f docker/test-server/compose.yml up -d` | Rig oben (sshd, sshd-2, minio, minio-init, webdav), gestartet aus dem **Haupt-Checkout** |
| `MACSCP_ITEST=1 swift test` | **1749 Tests in 143 Suiten, grün** (12,449 s) |
| `MACSCP_KEYCHAIN=1 swift test --filter Keychain` | **29 Tests in 11 Suiten, grün** (0,066 s) |
| `plutil -lint` über alle acht Kataloge (4× App, 4× Core) | jede Datei `OK` |
| `pgrep -fl swiftpm-testing-helper` | keine Treffer, keine Waisen |
| `git status --porcelain` | vor dem Bericht-Commit leer, auch nach der Mutationsprobe unten |
| `scripts/release` | **nicht ausgeführt** (bindende Vorgabe) |
| GUI | **nicht gestartet** (bindende Vorgabe) |

**Dass die gegatete Suite wirklich lief**, ist an der Laufzeit ablesbar
(3,655 s ungegatet gegen 12,449 s gegatet) und daran, dass die Ausgabe
namentlich die Suite `CitadelFileSystem against Docker SSH server` führt. Die
Testzahl ist in beiden Läufen identisch, weil die Integrationstests intern
über die Umgebungsvariable früh zurückkehren — dieselbe Erklärung wie seit
M24.

**Der seit M20 bekannte 0-%-CPU-Hänger trat in keinem der Läufe auf.** Eine
Beobachtung, kein Beweis seiner Abwesenheit.

### Testzahlen, vorher und nachher

Die **Vorher**-Zahl ist nicht fortgeschrieben, sondern gemessen: der
Basiscommit `7a1777b` wurde in einem eigenen Worktree ausgecheckt und dort
`swift test` gefahren (der Worktree danach entfernt). Der Wert bestätigt die
Zahl, die die Task-Briefe nannten — er ist hier aber die Messung, nicht
deren Übernahme.

| | Basis `7a1777b` | HEAD `d1db769` |
|---|---|---|
| Gesamt | **1735 Tests / 141 Suiten** | **1749 Tests / 143 Suiten** |

Also **+14 Tests, +2 Suiten**. Die Differenz ist restlos erklärt und
ausgezählt:

| Suite / Datei | neue `@Test` |
|---|---|
| `SnippetStoreTests` (neue Suite) | 6 |
| `SnippetKeystrokesTests` (neue Suite) | 4 |
| `TerminalPanelViewModelTests` (bestehende Suite) | 4 |
| **Summe** | **14** |

Kein bestehender Test hat seinen Status geändert.

## Die zehn Erfolgskriterien

Belege nennen Testnamen und Symbole, **keine Zeilennummern**.

| # | Kriterium | Ergebnis | Beleg |
|---|---|---|---|
| 1 | Ein eingefügtes Snippet endet **ohne** Zeilenabschluss | **erfüllt** | `anInsertingSnippetEndsWithoutATerminator` prüft die von `SnippetKeystrokes.bytes(for:)` erzeugten Bytes |
| 2 | Ein ausführendes Snippet endet mit **genau einem** Zeilenabschluss, dem der Eingabetaste | **erfüllt** | `anExecutingSnippetAppendsExactlyOneTerminator` (genau ein zusätzliches Byte) und `theTerminatorIsCarriageReturn` (es ist `0x0D`). Das Byte ist **gemessen** — eigener Abschnitt unten |
| 3 | Ein Kommando mit Zeilenumbruch wird abgelehnt | **erfüllt** | `aCommandWithALineBreakIsRefused` (Initialisierer, `\n` und `\r`) und `aHandEditedMultiLineCommandDoesNotDecode` (JSON-Literal, also ein von Hand bearbeiteter Store) |
| 4 | Der Store überlebt Schreiben und Lesen unverändert | **erfüllt** | `aSavedSnippetSurvivesTheRoundTrip`; dazu `savingTheSameIdTwiceReplaces` und `removingAnIdLeavesTheOthers` |
| 5 | Ein fehlender Store liefert eine leere Liste, keinen Fehler | **erfüllt** | `aMissingFileReadsAsAnEmptyList` |
| 6 | Ausführende Snippets stehen im Menü in einem eigenen Abschnitt | **Review-Punkt, kein Test** | siehe eigener Absatz unten |
| 7 | Ohne verbundene Sitzung sind die Einträge deaktiviert | **Review-Punkt, kein Test** | siehe eigener Absatz unten |
| 8 | Der Store enthält nie ein Secret | **erfüllt, als Zusage gelesen** | `Snippet`s Doc-Kommentar sagt es am Typ („Never holds credentials… this project keeps secrets exclusively in the Keychain"). Der Editor im Sheet trägt denselben Hinweis mit Begründung. Es gibt **keinen** Test, der die Abwesenheit eines Secrets erzwingen könnte — Snippets sind Freitext |
| 9 | Alle vier Kataloge tragen die neuen Schlüssel | **erfüllt** | **22** neue Schlüssel in `en`; die Schlüsselmengen-Differenz gegen `en` ist für `de`, `fr` und `pl` **leer** (ausgezählt aus dem Milestone-Diff). Der Wächter `LocalizableStringsTests` (`appLayerLanguagesMatchEnglishKeys`, `coreLayerLanguagesMatchEnglishKeys`) bleibt grün, ebenso `KeyboardShortcutsCatalogTests.everyLabelKeyResolves`; `plutil -lint` auf allen acht Katalogen `OK`. Die **Core**-Kataloge hat dieser Meilenstein nicht angefasst — sie wurden trotzdem mitgelintet |
| 10 | Der Shortcuts-Katalog nennt die neuen Kürzel | **erfüllt** | Neue Gruppe `settings.shortcuts.group.snippets` mit der Zeile `settings.shortcuts.label.insertSnippet` / „Insert snippet 1–3" / Glyph `⌃⌘1–3`; zusätzlich ist die Kürzel-Aufzählung im eigenen Doc-Kommentar des Katalogs (Fundstelle 1, die SwiftUI-Menüs) um `⌃⌘1–3` ergänzt — beide Stellen, die der Katalog selbst als Pflicht nennt |

### Kriterien 6 und 7: Review, nicht Test

**Beide sind ausdrücklich keine Tests, und dieser Bericht behauptet keine
Testabdeckung für sie.** Die Menü-Verdrahtung ist App-seitig, und dieses
Projekt hat kein View-Testwerkzeug — dieselbe Grenze, die M29 offengelegt
hat, und eine bewusste Entscheidung. Was tatsächlich vorliegt, ist ein
gelesener Code-Stand:

- **Kriterium 6:** `MacSCPApp.snippetMenuItems` teilt die Liste in
  `inserting` und `executing`. Zwischen beiden steht ein expliziter
  `Divider()`, darüber eine `Section` mit dem Titel
  `menu.snippets.runsImmediately`. Die Trennung ruht bewusst auf dem
  Divider: **wie `Section` seinen Titel in einem Menüleisten-Menü zeichnet,
  hat niemand gesehen.** Der Titel ist die Zugabe, der Divider der tragende
  Teil — so steht es auch im Doc-Kommentar der Funktion.
- **Kriterium 7:** Jeder Snippet-Eintrag trägt in `MacSCPApp.snippetButton`
  denselben Ausdruck wie die beiden vorbestehenden Einträge des Menüs,
  `!tabCommands.isActiveTabConnected || !tabCommands.activeTabSupportsShell`
  — zeichengleich übernommen, nicht neu abgeleitet. „Manage Snippets…" ist
  bewusst **nicht** deaktiviert; das folgt dem Sessions-Menü, dessen
  Verwaltungseinträge ebenfalls keinen `.disabled` tragen.

Gesehen hat das beides bislang nur ein Leser des Quelltexts. **Die
Sichtprüfung durch den Maintainer steht aus.**

## Befund 1: Der Zeilenabschluss ist gemessen, nicht angenommen

**Ergebnis: CR, `0x0D`. Nicht LF.**

Die Spec hat sich hier bewusst nicht festgelegt und nur verlangt, dass die
Antwort gemessen wird. Das war die richtige Vorsicht: **ein Plan, der `\n`
behauptet hätte, hätte ein als „sofort ausführend" markiertes Snippet
ausgeliefert, das still nichts tut** — der Text landet in der Eingabezeile
und bleibt dort stehen.

Die Kette, in Task 2 abgelaufen und **in dieser Sitzung an der gepinnten
Revision unabhängig noch einmal nachgezogen**:

1. `Package.swift` pinnt SwiftTerm auf eine feste Revision; der Checkout
   unter `.build/checkouts/SwiftTerm` meldet genau diese als `HEAD`. Gelesen
   wurde also der Code, gegen den dieses Paket baut.
2. Eine unmodifizierte Return-Taste fällt in `MacTerminalView.keyDown(with:)`
   durch alle Sonderzweige und wird von AppKit zum Kommando
   `insertNewline(_:)`.
3. `doCommand(by:)` beantwortet `#selector(insertNewline(_:))` mit
   `send(EscapeSequences.cmdRet)`.
4. `EscapeSequences.cmdRet` ist `[ 13 ]` — ein Byte, `0x0D`, kein LF und kein
   CR-LF-Paar.
5. Die Bytes erreichen `TerminalPanelViewModel.send(_:)` unverändert über
   `SSHTerminalView.Coordinator.send(source:data:)`.

Drei Gegenproben aus Task 2, die den Befund tragen:

- **LF ist deklariert, aber tot.** `EscapeSequences.cmdNewLine` (`[ 10 ]`)
  hat im gesamten Baum `Sources/SwiftTerm` genau **einen** Treffer: die
  Deklaration selbst. Nachgezählt in dieser Sitzung — unverändert einer.
- **LNM / `convertEol` fasst die Eingabe nicht an.** `Terminal.lineFeedMode`
  wird nur in der Ausgabe- und der Modus-Melde-Behandlung gelesen, an keiner
  Tastatur-Eingabestelle.
- **Der Kitty-Pfad bestätigt die Legacy-Kodierung.** Ohne
  report-all-keys landet eine unmodifizierte Return-Taste auf
  `legacySpecialKeySequence` → `[ControlCodes.CR]` = `0x0d`.

**Grenze des Befunds, ausdrücklich:** Das ist ein **statischer Quelltext-Lauf,
keine Laufzeitaufnahme** — die GUI wurde nicht gestartet, weder in Task 2 noch
hier. Es ist der stärkste Beleg, der ohne App-Start zu haben ist, und mehr
behauptet er nicht.

**Und er ist nicht modus-unabhängig.** Die erste Fassung des Kommentars
behauptete das; die Review hat es kassiert und `1ae8416` es korrigiert.
Verhandelt ein Programm die report-all-keys-Stufe des
Kitty-Tastaturprotokolls, kodiert eine echte Return-Taste als `ESC [ 13 u`;
in diesem Modus ist das bare CR eines Snippets **nicht** byte-gleich mit
einem Tastendruck. Der bewusst angenommene Geltungsbereich ist die
Legacy-Kodierung am Shell-Prompt — genau das, worauf ein Snippet zielt. Der
Doc-Kommentar von `SnippetKeystrokes` sagt das jetzt selbst, samt Zeiger auf
`theTerminatorIsCarriageReturn` als Ort der vollständigen Beweiskette.

## Befund 2: Das Auslösen wäre stumm ins Leere gelaufen

Gefunden in Task 4, beim Lesen von `TerminalPanelViewModel` — der Plan hatte
davon nichts.

`send(_:)` begann mit `guard let shell else { return }`. Das Panel startet
geschlossen (`isVisible = false`, `state = .closed`). Ein Snippet auf einem
frisch verbundenen Tab — **genau der Moment, in dem die Menüeinträge zum
ersten Mal freigeschaltet sind** — hätte das Panel geöffnet und seine Bytes
in denselben `guard` geschickt: verschluckt, ohne Spur. Die Spec sagt, ein
Eintrag, der ins Leere läuft, sei schlechter als ein grauer; hier wäre er ins
Leere gelaufen, ohne grau zu sein.

Die erste Fassung wartete in der View mit einem beschränkten Poll. Die Review
hielt dagegen: der Timeout war selbst stumm und reproduzierte damit exakt den
Defekt, den er beheben sollte, und die Politik saß untestbar im View-Code.
Die Fix-Runde hat sie nach Core gezogen — und dabei **ist sie kleiner
geworden als der Poll, den sie ersetzt**: `send(_:)` puffert, solange
`state == .opening`, und `flushPendingBytes()` spielt in demselben
synchronen Schritt zurück, der `.running` setzt. Damit gibt es keinen Timeout
mehr, der ablaufen könnte. In der View bleiben drei geradlinige Aufrufe:
Panel zeigen → `openIfNeeded()` → `send(...)`.

**Und sie hat einen vorbestehenden Fehler mitbehoben:** Tastendrücke, die
während `.opening` ins Panel getippt wurden, fielen durch denselben `guard`
— das Panel montiert `SSHTerminalView` auch für `.opening`. Sie werden jetzt
ebenfalls zugestellt. Das war nicht das Ziel, sondern ein Nebenertrag davon,
den Fehler an der Wurzel statt am Aufrufer zu beheben.

Vier neue Tests halten das (`sendDuringOpeningIsDeliveredOnceRunning`,
`bytesHeldWhileOpeningKeepTheirOrder`,
`bytesHeldWhileOpeningAreDroppedWhenTheOpenFails`,
`bytesHeldWhileOpeningAreBounded`). **Drei davon waren nachweislich rot** —
die Rot-Ausgabe steht im Task-4-Bericht und ist **in dieser Sitzung nicht
reproduziert**. Der vierte wird ehrlich als das benannt, was er ist: er
sichert die neue Fehlermöglichkeit des Fixes ab (ein alter Puffer, der in
eine spätere Shell zurückspielt) und ist ohne den Fix trivial grün.

### Nachgemessen: die vier Löschstellen und die zwei `replayBuffer`-Stellen

Der Task-4-Bericht schreibt, der Puffer werde an vier Stellen geleert, „jede
neben dem bestehenden `replayBuffer`-Reset, neben dem sie sitzt". **Der
zweite Halbsatz stimmt nicht, und dieser Bericht schreibt ihn nicht fort.**
Nachgezählt in `TerminalPanelViewModel`:

| | Stellen |
|---|---|
| `pendingBytes = []` als Lebenszyklus-Löschung | **vier** — `openIfNeeded()`, der `catch` des fehlgeschlagenen Öffnens, `finishShell`, `shutdown()` |
| `replayBuffer = []` | **zwei** — `openIfNeeded()` und `shutdown()` |

Nur **zwei** der vier Löschstellen haben also überhaupt einen
`replayBuffer`-Reset als Nachbarn; `catch` und `finishShell` haben keinen.
Die engere Aussage im Quelltext selbst — dass die **Deckelung** dem Vorbild
von `maxReplayBytes` folgt — ist dagegen richtig und bleibt stehen.

### Nachgemessen: eine der vier Löschungen ist toter Code

Die Löschung im `catch` des fehlgeschlagenen Öffnens ist **wirkungslos**, ihr
Kommentar stellt sie aber als tragend dar („Whatever was buffered was meant
for THIS attempt's shell — there is none…").

Zwei unabhängige Messungen:

1. **Erreichbarkeit.** Der einzige Leser des Puffers ist
   `flushPendingBytes()`, und der wird ausschließlich auf dem Erfolgspfad von
   `openIfNeeded()` erreicht — dem eine eigene Löschung unmittelbar
   vorausgeht. Nach dem `catch` kann also niemand mehr an die Bytes kommen,
   ob sie stehen bleiben oder nicht.
2. **Mutationsprobe.** Die Zeile samt Kommentar entfernt,
   `swift test --filter TerminalPanelViewModel`: **17 Tests in 1 Suite, alle
   grün** — kein Test hält sie, auch
   `bytesHeldWhileOpeningAreDroppedWhenTheOpenFails` nicht. Rücknahme belegt:
   `git status --porcelain` und `git diff --stat` beide leer.

Das ist keine Sicherheitslücke und kein Verhaltensfehler — die Bytes gehen
so oder so verloren, wie es sich gehört. Es ist eine **Kommentar-Unwahrheit**:
defensive Redundanz, die als Notwendigkeit auftritt. Nach derselben Logik
sind auch die Löschungen in `finishShell` und `shutdown()` defensiv statt
tragend. Als kleiner Nachtrag offen (unten).

## Was aus dem Ledger offen zurückbleibt

Alle folgenden Punkte sind während der Reviews bewusst zurückgestellt worden.

- **Leeres Trennband im Menü**, wenn es ausführende, aber **keine**
  einfügenden Snippets gibt: `snippetMenuItems` setzt dann den Divider für
  die nicht leere Gesamtliste und unmittelbar danach den Divider vor der
  `Section` — zwei Trenner ohne etwas dazwischen. Nachgelesen und bestätigt.
  Kosmetik, ungesehen, weil die GUI nicht lief.
- **`prefix(maxPendingBytes - count)` würde bei negativem Argument
  abstürzen.** Heute unerreichbar, weil der Anhang nie über die Deckelung
  hinausläuft; ein `max(0,)` würde nichts kosten.
- **`resize()` verwirft weiter während `.opening`**, während `send(_:)` das
  nicht mehr tut — dieselbe `guard let shell`-Stelle, ohne
  `.opening`-Zweig. Vorbestehende Asymmetrie; verschluckt vermutlich das
  erste `sizeChanged` eines frisch geöffneten Panels.
- **Zwei in demselben `.opening`-Fenster ausgelöste Snippets** hängen jetzt
  in **definierter** Reihenfolge aneinander statt in unspezifizierter — das
  Ergebnis ist trotzdem eine zusammengesetzte Eingabezeile. Von keinem Test
  gehalten, von niemandem als sinnvoll angefordert.
- **Der stille `try? await Task.sleep`** aus der ersten Fassung existiert
  nicht mehr: der Poll, in dem er lebte, ist mit der Fix-Runde ganz
  entfallen. Erledigt, nicht offen — hier genannt, damit die Ledger-Zeile
  nicht als offener Punkt weiterlebt.
- **Der tote `pendingBytes = []` im `catch`** samt irreführendem Kommentar
  (siehe oben).

## Was in diesem Bericht NICHT verifiziert ist

- **Die gesamte Oberfläche.** Die App wurde **nicht gestartet** — bindende
  Vorgabe. Damit hat **niemand gesehen**: die zwei Abschnitte im
  Terminal-Menü, wie `Section` ihren Titel „Runs Immediately" zeichnet (oder
  ob überhaupt), den grauen Zustand der Einträge ohne Verbindung, das
  `SnippetsSheet` mit Liste, Suchfeld, Editor und Zugangsdaten-Hinweis, und
  den Shortcuts-Tab mit der neuen Gruppe. Kriterien 6 und 7 sind
  Review-Punkte; die **Sichtprüfung durch den Maintainer steht aus.**
- **Die Verdrahtung Menü → Core.** Es gibt **keinen Test**, der
  `MacSCPApp.snippetMenuItems` → `TabCommands.runSnippet` →
  `ContentView.triggerSnippet(_:)` → `TerminalPanelViewModel.send(_:)`
  durchmisst. Die Kette ist gelesen, nicht ausgeführt. Kein
  View-Testwerkzeug im Projekt — bewusst, siehe M29.
- **Der Zeilenabschluss zur Laufzeit.** Statischer Quelltext-Lauf gegen die
  gepinnte SwiftTerm-Revision; kein einziges Byte wurde dabei über eine echte
  PTY geschickt. Ebenso ungeprüft: dass die Gegenseite auf CR so reagiert,
  wie ein POSIX-Terminal es üblicherweise tut.
- **Die Rot-Zustände.** Die Compile-Fehler aus T1/T2 und der Rot-Lauf der
  drei Puffer-Tests aus T4 sind aus den Task-Berichten **übernommen**, nicht
  in dieser Sitzung neu erzeugt. Neu erzeugt wurde in dieser Sitzung
  ausschließlich die Mutationsprobe zum toten `catch`-Zweig oben.
- **Die FR- und PL-Übersetzungen der 22 neuen Schlüssel** sind maschinell
  erzeugt und **nicht muttersprachlich geprüft**; der stehende Vorbehalt des
  Projekts gilt unverändert. Die deutsche Fassung ist handgeschrieben.
- **Die Whole-Branch-Review über `7a1777b..HEAD`** ist noch nicht gelaufen.
  Die vorangegangenen zwei Meilensteine haben dabei jeweils weitere falsche
  Behauptungen gefunden, die den jeweiligen Abschlussbericht überlebt hatten
  — es ist damit zu rechnen, dass auch dieser Bericht noch korrigiert wird.
- **`scripts/release`** — nicht ausgeführt.
- **Dass der Testsuite-Hänger nicht mehr auftritt** — er trat in keinem der
  Läufe auf, mehr ist damit nicht gesagt.

## Für die Release-Notes

**Ein Satz.** Häufig gebrauchte Befehle lassen sich als Snippets ablegen und
im Terminal einfügen.

## Was offen bleibt

- **Die Sichtprüfung der GUI** — der einzige Weg, Kriterien 6 und 7 von
  „gelesen" auf „gesehen" zu heben.
- **Die Whole-Branch-Review** über `7a1777b..HEAD`.
- Die sechs zurückgestellten Kleinigkeiten aus dem Abschnitt oben.
- Aus der Spec ausdrücklich ausgeschlossen und unverändert offen:
  Platzhalter, Export/Import von Snippets, Bindung an Hosts oder Gruppen,
  mehrzeilige Skripte — und **Agent-Forwarding** als eigener Meilenstein,
  im Backlog seit M10d.
- **M29-P3** — die Entkernung des Rests von `ContentView`.
- Unverändert vom Backlog: der veraltete Slot einer set-gebundenen Sitzung,
  die Editor-Reibung beim Bearbeiten eines Login-Sets, ein app-weiter
  Audit-Bereich, der 0-%-CPU-Testsuite-Hänger, der Pfad, über den die
  ausgelieferte App ihr Ressourcen-Bundle findet.
- **Der Release-Stau: 419 Commits vor `origin/main`** (M29-P2 nannte 408,
  M29-P1 397). Weiter gewachsen.
