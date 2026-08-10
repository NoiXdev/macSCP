# PV + P0 — Abschlussbericht (View-Testbarkeit und die Entkernung von `ContentView`)

**Status:** abgeschlossen 2026-08-11. HEAD vor diesem Bericht: `295a856`.

Zwölf Tasks: ein zeitbudgetierter Vorversuch zur View-Testbarkeit, fünf
Extraktionen, die Entscheidungslogik aus `ContentView` in geprüfte Typen
gehoben haben, fünf mechanische Dateiaufteilungen ohne Zustandsumzug, und
dieser Abschluss. Spec: `2026-08-10-snippets-runde-2-design.md` (Abschnitte
„PV" und „P0"). Plan: `../plans/2026-08-10-pv-p0-entkernung.md`.

## Commits

Basis des Plans: `01a8396`.

| Commit | Inhalt |
|---|---|
| `01a8396` | Plan (= Basis) |
| `1811a18` / `7de6986` / `ab9c186` | Task 1 — PV-Vorversuch, Bericht, Fixrunde (Zwei-Variablen-Konfundierung entfernt) |
| `7fa35a1` | Task 2 — `TabCloseWarning` |
| `d2457fa` | Task 3 — `SubmitRefusalText` |
| `9fcf3a0` / `bd9b034` | Task 4 — `SessionSecretPolicy`, Fixrunde (zwei fehlende Deckungstests) |
| `0196266` | Task 5 — `CrossSessionTargets` |
| `3d02ddd` | Task 6 — `ImportFeedbackText` |
| `7546320` | Task 7 — `ContentView+Detail.swift` |
| `90231c2` | Task 8 — `ContentView+Sheets.swift` |
| `3d3bfe6` | Task 9 — `ContentView+Lifecycle.swift` |
| `716509d` | Task 10 — `ContentView+Transfers.swift` |
| `7e019f1` | Task 11 — `ContentView+ExportImport.swift` |
| `295a856` | Task 12 — `tabIDs`' Doc-Kommentar korrigiert (siehe unten) |

**Unversendet:** `git rev-list --count origin/develop..develop` → **30** vor
diesem Bericht-Commit. **Release-Stau:**
`git rev-list --count origin/main..develop` → **440**.

## 1. Gemessene Zeilenzahlen und Testzahlen

Die Vorher-Zahlen sind nicht aus Plan oder Brief abgeschrieben, sondern in
dieser Sitzung in einem eigenen Worktree auf dem Plan-Basiscommit
(`01a8396^` = `d69c403`) neu gemessen und danach entfernt.

| | vorher (`d69c403`, isolierter Worktree) | nachher (`295a856`, dieser Baum) |
|---|---|---|
| `ContentView.swift` | **3464** Zeilen | **1360** Zeilen |
| Suite gesamt | **1756 Tests / 144 Suiten** | **1785 Tests / 150 Suiten** |

`ContentView.swift` schrumpft um **2104 Zeilen (61 %)**. Die Suite wächst um
**+29 Tests, +6 Suiten** — restlos erklärt: `ViewTestabilitySpike` (+7),
`TabCloseWarning` (+3), `SubmitRefusalText` (+3), `SessionSecretPolicy`
(+4, dann +2 in der Fixrunde = 6), `CrossSessionTargets` (+3),
`ImportFeedbackText` (+7). 7+3+3+6+3+7 = 29, sechs neue Suiten. Kein
bestehender Test hat seinen Status geändert.

**Wohin die 2104 Zeilen gingen** (alle Werte in diesem Baum neu gemessen):

| Datei | Zeilen | Sorte |
|---|---|---|
| `ContentView+Lifecycle.swift` | 671 | Aufteilen |
| `ContentView+Detail.swift` | 535 | Aufteilen |
| `ContentView+Sheets.swift` | 344 | Aufteilen |
| `ContentView+Transfers.swift` | 250 | Aufteilen |
| `ContentView+ExportImport.swift` | 149 | Aufteilen |
| `ImportFeedbackText.swift` | 106 | Herausziehen (App) |
| `SessionSecretPolicy.swift` (Core) | 75 | Herausziehen (Core) |
| `SubmitRefusalText.swift` | 47 | Herausziehen (App) |
| `TabCloseWarning.swift` | 33 | Herausziehen (App) |
| `CrossSessionTargets.swift` | 27 | Herausziehen (App) |

Fünf Aufteilen-Dateien, fünf Herausziehen-Dateien — genau die zehn, die der
Plan vorsah. Kein neuer L10n-Schlüssel: `git diff --stat 01a8396..HEAD --
Sources/MacSCPAppKit/Resources Sources/macSCPCore/Resources` ist leer,
gemessen, nicht angenommen.

Die vier anderen großen App-Dateien blieben unberührt, wie die Spec es
vorschreibt (`SettingsView.swift` 1306, `RemoteFileTableView.swift` 1050,
`LoginSetsSheet.swift` 1048, `ConnectionFormView.swift` 1001 — alle vier
in diesem Lauf gegengemessen, unverändert gegenüber dem Spec-Stand).

## 2. Welche Entscheidungslogik jetzt durch Tests gehalten wird

**Gehalten (fünf neue Typen, 22 Tests plus die A/B/A-Vorversuchstests):**

- `TabCloseWarning` — welche der zwei Warngründe beim Schließen eines Tabs
  genannt werden, in welcher Reihenfolge, und der Sonderfall „keiner der
  beiden".
- `SubmitRefusalText` — alle acht `SubmitRefusal`-Fälle auf Text, mit
  Vollständigkeits- und Kollisions-Zusicherung.
- `SessionSecretPolicy` (Core) — welcher Wert in den eigenen Secret-Slot
  einer Sitzung geschrieben wird, einschließlich des `catch → true`-Zweigs
  (ein Fehler beim Nachsehen persistiert nie ein zweites Mal) und der
  Trimm-Regel auf dem Schlüsselpfad.
- `CrossSessionTargets` — welche anderen Tabs als Transferziel angeboten
  werden (eigener Tab raus, Tab ohne Sitzung raus, ein verbundener Tab
  bleibt drin — die dritte Regel kam erst in der Fixrunde/Erweiterung des
  Tasks dazu).
- `ImportFeedbackText` — die drei Textabbildungen für Session-Import und
  -Export, mit Vollständigkeit über alle `SessionExportError`-Fälle.

**Nicht gehalten:**

- Die fünf Aufteilen-Dateien (`ContentView+Detail/Sheets/Lifecycle/
  Transfers/ExportImport.swift`) verschieben Code, fügen keinen Test hinzu.
  Was darin steht — Sheet-/Alert-Reihenfolge, Toolbar-Knopf-Gating,
  Fenster-Lebenszyklus einschließlich der Teardown-Reihenfolge
  `cancelAll → shutdown → disconnect`, Drag&Drop-Uploads — bleibt so
  ungeprüft, wie es vorher war. Der Nachweis dafür ist in dieser Phase
  ausschließlich Review (Diff-Prüfung, Byte-Vergleich einzelner Funktionen
  gegen den vorherigen Stand), keine Suite.
- Die Verdrahtung Knopf/Menü → die fünf neuen Typen (`requestClose` ruft
  `TabCloseWarning`, die Login-Formular-Ansicht ruft `SubmitRefusalText`
  usw.) ist eine `ContentView`-Zeile, gelesen, nicht ausgeführt — dieselbe
  Grenze wie in M29-P2 bei `SubmitRefusal` selbst.
- `requestExternalTerminal`/`performExternalOpen` in `ContentView`: reine
  Verdrahtung zu `ExternalTerminalLauncher` (seit M29-P1 bereits ein
  eigener geprüfter Typ), aber die Verdrahtung selbst ist ungeprüft.

## 3. Die Zusicherung „kein Verhalten geändert" — Grundlage und Grenze

**Diese Zusicherung stützt sich ausdrücklich auf Build und Suite, nicht auf
eine Sichtprüfung. Die GUI wurde in dieser gesamten Phase kein einziges Mal
gestartet** — kein `open`, kein Aufruf, der ein Fenster zeigt. Was in dieser
Sitzung tatsächlich lief:

| Lauf | Ergebnis |
|---|---|
| `swift build` | `Build complete!` |
| `swift test` | **1785 Tests in 150 Suiten, grün** (3,9–4,4 s je nach Lauf) |
| `MACSCP_VERSION="1.2.0-dev" MACSCP_BUILD="$(git rev-list --count HEAD)" ./scripts/package-app` | `wrote dist/macSCP.app` |
| `lipo -archs` auf `macSCP` und `macscp-cli` | beide `x86_64 arm64` |
| Resource-Bundles | `macSCP_MacSCPAppKit.bundle`, `macSCP_macSCPCore.bundle` vorhanden |
| `en/de/fr/pl.lproj`-Marker | alle vier vorhanden unter `Contents/Resources` |
| `plutil -lint dist/macSCP.app/Contents/Info.plist` | `OK` |
| `CFBundleVersion` / `CFBundleShortVersionString` | `907` / `1.2.0-dev` — `907` deckt sich mit `git rev-list --count HEAD` am damaligen `HEAD` (`7e019f1`) |
| `scripts/release` | **nicht ausgeführt** (veröffentlicht) |
| GUI | **nicht gestartet** |

Eine Einschränkung zum Build selbst: der Dev-Build wurde auf `7e019f1`
gefahren, bevor dieser Bericht den Commit `295a856` (die
`tabIDs`-Kommentarkorrektur, siehe Abschnitt 5) hinzufügte. Der Diff
zwischen beiden ist eine einzelne Kommentarzeile ohne Effekt auf erzeugten
Code — der Build bleibt für den committeten Code repräsentativ, wurde aber
nicht danach wiederholt.

Bau und Suite belegen, dass sich **kein automatisiert prüfbares Verhalten**
geändert hat. Sie belegen nicht, wie die App tatsächlich aussieht oder sich
bedient. **Die Sichtprüfung liegt beim Maintainer.** Konkret wollen diese
Stellen angesehen werden, weil sie in Teil B verschoben, aber nie gerendert
wurden:

1. **Die Reihenfolge der Sheets/Alerts in `ContentView+Sheets.swift`.**
   Mehrere `.sheet`-Modifikatoren an derselben View — Login-Sets,
   Server-Zertifikate, versteckte Importe, Snippets, Export/Import-Dialoge,
   Passwort-Hinweis, Fehler beim externen Terminal. Reihenfolge entscheidet,
   welches Sheet gewinnt, wenn mehrere Bedingungen gleichzeitig zutreffen.
2. **Der Tab-Close-Warndialog**, wenn beide Gründe zutreffen (aktive und
   eingehende Transfers) — jetzt aus `TabCloseWarning.message` gebaut.
3. **Die Ablehnungsmeldung im Login-Formular**, für mindestens einen der
   acht `SubmitRefusal`-Fälle — jetzt aus `SubmitRefusalText.message`.
4. **Die Ziel-Auswahl beim sitzungsübergreifenden Transfer** (`CrossSessionTargets`) — ob die Liste im UI so aussieht wie erwartet.
5. **Das Detailpanel-Layout** (`splitLayout`, `windowChrome`, `terminalPanel`
   in `ContentView+Detail.swift`) nach der reinen Dateiverschiebung.
6. **Fenster-Lebenszyklus**: Fenstergröße beim Start (`shrinkIfPristine`),
   Menüleisten-Verdrahtung, Schließen-Bestätigung — alles jetzt in
   `ContentView+Lifecycle.swift`.

## 4. Das PV-Ergebnis und seine Folgen für die Views

**Ja — SwiftUI-Views aus `MacSCPAppKit` lassen sich im Testtarget instanziieren,
mit `ImageRenderer` rendern und über einen Pixelvergleich unterscheiden, ohne
jede neue Abhängigkeit, verträglich mit Swift Testing, und für reine
SwiftUI-Views ohne laufende `NSApplication`.** Belegt mit einem lauffähigen
Beispiel (`Tests/macSCPAppKitTests/ViewTestabilitySpike.swift`, sieben Tests,
im Baum verblieben) und einer echten A/B/A-Kontrolle, nachdem die erste
Fassung eine Zwei-Variablen-Konfundierung und eine Aufwärm-Störgröße enthielt
(beide in der Fixrunde ausgeräumt, siehe Abschnitt 5).

**Die Einschränkung wiegt schwerer als das Ja:** `ImageRenderer` zeichnet
**kein** `NSViewRepresentable`. Inhalte AppKit-gestützter Controls —
`TextField`, `Toggle`, Tabellen — erreichen das gerenderte Bitmap nicht.
Gemessen, nicht vermutet: derselbe `SheetSearchField` mit `text: "a"` und mit
39 Zeichen rendert **identisch**. Genau diese Kontrolltypen dominieren die
Formulare und Listen dieser App. Die Technik trägt also für Layout- und
reine-SwiftUI-Views, aber nicht für den Inhalt, der in `ContentView` und den
Sheets am meisten Entscheidungslogik trägt.

**Folge für P0:** Diese Phase hat sich, wie die Spec es für den
Negativ-Fall vorschreibt, an die Alternative gehalten — so viel
Entscheidungslogik wie möglich nach Typen mit Tests, die Views bleiben
Zeichnen. Kein View-Test wurde für die fünf Aufteilen-Dateien geschrieben,
obwohl das PV-Ergebnis formal positiv ausfiel: der Koordinator hat diese
Wahl getroffen, weil die tragende Einschränkung — AppKit-Controls sind
unsichtbar — genau die Views ausschließt, an denen P0 arbeitet. Für P1
folgt daraus dieselbe Linie, die die Spec bereits vorwegnimmt:
`SnippetMenuModel` liegt in Core, nicht als Views mit Pixeltests.

**Offen aus PV:** ob die Technik in einer GUI-losen CI-Sitzung trägt, ist
lokal nicht mit Root geprüft worden (`launchctl bsexec 1` bräuchte
passwortloses `sudo`, nicht verfügbar). Der Spike bleibt im Baum; der
nächste CI-Lauf beantwortet es kostenlos mit.

## 5. Befunde im Plan selbst — und was sie gekostet haben

Über die Phase verteilt fanden mehrere Tasks echte Fehler in der eigenen
Prosa des Plans, nicht im bestehenden Produktionscode:

- **Falsche Isolations-Annotation (Task 2).** Der Plan-Codeblock für
  `TabCloseWarning` trug keine `@MainActor`-Markierung. `hasIncomingTransfers`
  liest `SessionTab`-Felder, `SessionTab` ist `@MainActor`; ohne Annotation
  kompiliert der Typ nicht. Kostet: eine gezielte Korrektur (nur die eine
  Funktion, nicht der ganze Typ, sonst hätte der Plan-eigene Test nicht mehr
  kompiliert) — kein Fixrunde nötig, im selben Task gefunden und behoben.
- **Zwei faktisch falsche Tests (Task 3, Task 6).** `noTwoRefusalsReadTheSame`
  und `noTwoExportErrorsReadTheSame` behaupteten Kollisionsfreiheit, die es
  nie gab: `SubmitRefusalText` bündelt drei Fälle absichtlich auf
  `loginSets.missingSet`, `ImportFeedbackText` zwei Paare absichtlich (mit
  Doc-Kommentaren, die das schon vor dieser Phase sagten). Beide Tests wurden
  durch eine Variante ersetzt, die dieselbe Kollisionsfreiheit gegen eine
  Allow-Liste dokumentierter Kollisionen prüft. Kostet: keine Fixrunde, aber
  in beiden Fällen ein Innehalten und eine begründete Abweichung im
  Task-Bericht statt eines stillen Umschreibens.
- **Ein falscher Typname (Task 4).** Die „Produces"-Signatur nannte
  `authChoice: AuthKind`; der echte Parameter ist
  `ConnectionViewModel.AuthChoice`, ein eigener, formularseitiger Typ, der
  nur zufällig dieselben Rohwerte wie `StoredSession.AuthKind` trägt.
  `AuthKind` allein löst in Core nicht auf. Kostet: keine Fixrunde — der
  Implementierer erkannte den Fehler beim Signaturabgleich vor dem Schreiben
  des Typs.
- **Tests, die gegen einen konstanten Rückgabewert grün liefen (Task 4,
  Fixrunde 1).** Die vier Brief-Tests deckten den Exemptions-Pfad
  (`aManagedKeyWithAStoredPassphraseIsExemptFromPersisting`) und den
  Catch-Zweig (`anUnreadableKeychainIsTreatedAsAlreadyStored`) nicht ab; eine
  Re-Review mutation-testete beide Konstanten live und zeigte, dass eine
  Policy, die immer `false` liefert, alle vier Ausgangstests weiterhin
  bestanden hätte. Kostet: eine volle Fixrunde — zwei neue Tests, eine
  Neufassung des Padded-Path-Tests (der vorher auch bei entfernter
  `.trimmingCharacters`-Zeile grün geblieben wäre), zwei Doc-Kommentar-
  Korrekturen.

**Das ist nicht kosmetisch.** Jeder dieser vier Funde hätte, unentdeckt, eine
Lücke genau an der Stelle hinterlassen, die diese Phase schließen sollte:
Entscheidungslogik, die aussieht wie geprüft, es aber an der entscheidenden
Stelle nicht ist. Gleichzeitig: **kein einziger davon lag im bestehenden
Produktionscode** — jede Korrektur betraf den Plan oder die vom Plan
mitgelieferten Testvorlagen, nie eine Zeile, die vor dieser Phase schon lief.
Das ist dieselbe Lektion, die M29-P2 schon zog („eine vom Plan mitgelieferte
Zusicherung ist eine Hypothese, kein Ergebnis"), hier viermal wiederholt statt
einmal.

**Zusätzlich in diesem Task behoben:** die von Task 7 auf „FIX IN THE FINAL
WAVE" vertagte `tabIDs`-Doc-Kommentar-Behauptung. Sie sagte „see the
`.onChange(of: tabIDs)` call above" — der Aufruf liegt seit Task 9 in einer
anderen Datei (`ContentView+Lifecycle.swift`), „above" war falsch. Commit
`295a856`, eine Zeile, keine Verhaltensänderung.

## 6. Was aus dem Ledger vorgetragen wird — offene Minderbefunde

Diese vier bleiben nach diesem Bericht offen; keiner wurde in dieser Phase
behoben, weil jeder außerhalb ihres Umfangs lag oder eine
Maintainer-Entscheidung braucht:

1. **`warmUpRenders = 3` (Task 1) ist ein empirisch gemessener Wert, kein
   bewiesenes Minimum.** Abgesichert durch die A/B/A-Kontrolle in jedem
   betroffenen Test — falls drei Renderings künftig nicht mehr reichen,
   wird der Test rot statt still falsch zu messen. Keine Handlung nötig,
   solange die Kontrolle grün bleibt; bei Flakiness dort zuerst nachsehen.
2. **`TabCloseWarningTests` prüft nur die Anzahl der Zeilen, nicht ihre
   Reihenfolge (Task 2).** Ein vertauschtes Zeilenpaar (aktive Transfers
   und eingehende Transfers in der Meldung getauscht) würde die drei
   Brief-Tests nicht rot machen. Der Code selbst hat eine feste, dokumentierte
   Reihenfolge; der Test kann sie derzeit nicht schützen. Ein Nachtrag wäre
   ein `#expect(text == "…\n…")` mit fixierter Reihenfolge für den
   Beide-Gründe-Fall.
3. **Drei `SubmitRefusal`-Fälle lesen sich identisch für den Nutzer
   (Task 3).** `.targetSetMissing`, `.jumpSetMissing` und
   `.jumpSessionLoginUnresolvable` teilen sich `loginSets.missingSet` — eine
   Vorentscheidung von M29-P2, nicht dieser Phase. Ob das für den Nutzer
   ausreicht oder die drei eigene Texte verdienen, ist eine
   Maintainer-Entscheidung; Textänderungen lagen außerhalb des Umfangs
   dieser Phase.
4. **`LoginSetsSheet.swift` führt eine eigene, parallele Textabbildung
   (Task 6).** Die Datei hat ihre eigenen `readErrorMessage`/
   `importErrorText`/`importResultText` für das Login-Set-Importformat —
   mit **anderen** L10n-Schlüsseln und einer **anderen** Kollisionsgruppierung
   als `ImportFeedbackText`. Zwei Codestellen beantworten dieselbe Frage
   („wie beschreibe ich einen Import-Fehler") mit unterschiedlicher Antwort
   — exakt die Drift-Klasse, die dieses Projekt schon einmal bezahlt hat
   (Spec-Begründung für `SnippetMenuModel` in P1 nennt das Muster
   ausdrücklich). Keine Vereinheitlichung in dieser Phase — die beiden
   Formate (Session-Export/-Import vs. Login-Set-Import) sind heute
   tatsächlich verschieden, eine Zusammenlegung wäre eine eigene
   Entscheidung.

**Geschlossen in diesem Bericht:** die `tabIDs`-Doc-Kommentar-Behauptung aus
Task 7 (siehe Abschnitt 5) — als einziger der fünf Ledger-Einträge war sie
explizit auf diesen Abschluss vertagt.

## 7. Was offen bleibt

- Die vier Minderbefunde aus Abschnitt 6 — unverändert, keiner davon von
  dieser Phase verursacht.
- **Die Sichtprüfung durch den Maintainer** (Abschnitt 3) — noch nicht
  erfolgt, da die GUI in dieser Phase nicht gestartet wurde.
- **Die GUI-lose-CI-Frage aus PV** — lokal nicht auflösbar, beantwortet sich
  mit dem nächsten CI-Lauf, da `ViewTestabilitySpike.swift` im Baum bleibt.
- **View-Tests für die fünf Aufteilen-Dateien** — bewusst nicht Teil dieser
  Phase (Abschnitt 4); eine künftige Entscheidung, ob sich das angesichts der
  AppKit-Einschränkung überhaupt lohnt.
- **P1–P3** aus der Spec — Snippets erreichbar machen, Terminal-Fassung,
  Host-Tags/Import-Export — keiner davon Gegenstand dieser Phase.
- **Der Release-Stau:** 30 Commits vor `origin/develop`, 440 vor
  `origin/main` (Abschnitt „Commits" oben) — weiter gewachsen, unverändert
  vom Backlog.

## Für die Release-Notes

Keine — diese Phase ist reines internes Refactoring ohne
Nutzer-sichtbare Änderung.
