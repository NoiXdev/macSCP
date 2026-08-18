# P3b — Abschluss: Snippets exportieren und importieren

Abgeschlossen 2026-08-18. Fünf inhaltliche Commits im Bereich `296cf74..HEAD`:

```
438c93b feat(core): give snippets an exchange format without a crypto path
8ad8a08 feat(core): plan a snippet import on the shared conflict arbiter
7b4857f feat(app): export the visible snippets to a file
4b2ecab fix(app): register the snippets export type in the packaged Info.plist
25a2ae6 feat(app): import snippets through the shared conflict sheet
```

**Eine Korrektur am Auftrag selbst:** Der Auftrag sprach von „der Phase in
sechs Commits" für denselben Bereich. Im Bereich liegt zusätzlich
`e1b1451` (`docs(app): note the P3d action window's keyboard shortcuts`) —
ein reiner Doku-Commit für eine andere, spätere Phase (P3d), der nur die
Spec-Datei berührt (`docs/superpowers/specs/2026-08-18-p3-ordnung-design.md`,
+14 Zeilen) und mit P3b inhaltlich nichts zu tun hat. Er landete zeitlich
zwischen Task 3 und Task 4 im selben Branch. Der `git diff --stat` über den
ganzen Bereich (ohne diese eine Spec-Datei) zeigt exakt die 13 Dateien, die
die vier Task-Reports beschreiben — keine unerklärten Änderungen.

Die Phase deckt genau das, was die Spec (`docs/superpowers/specs/
2026-08-18-p3-ordnung-design.md`, Abschnitt „P3b — Snippets exportieren und
importieren") verlangt hat: ein Austauschformat `macscp-snippets` über die
geteilte `ExportEnvelopeCodec`, immer mit `password: nil`; ein eigener
Planer auf dem geteilten `ImportConflictArbiter`, Duplikate am Namen wie bei
Login-Sets; Export- und Import-Oberfläche nach dem Muster der
Sitzungs-Sheets, mit Auswahl beim Export und dem geteilten Konflikt-Sheet
aus M19.

## Gemessene Zahlen

- **Suite:** `swift test` — **2055 Tests in 176 Suiten**, 0 Fehlschläge.
  Selbst gemessen (nicht aus einem Report übernommen), deckt sich mit dem
  in Task 4 gemeldeten Endstand. Entwicklung über die Phase: 2029 (nach
  Task 1) → 2042 (Task 2) → 2045 (Task 3) → 2055 (Task 4); Baseline vor der
  Phase 2024/175.
- **`.strings`:** `plutil -lint` auf alle acht Kataloge
  (`Sources/MacSCPAppKit/Resources/{en,de,fr,pl}.lproj/Localizable.strings`,
  `Sources/macSCPCore/Resources/{en,de,fr,pl}.lproj/Localizable.strings`) —
  alle acht `OK`.
- **Build:** `scripts/package-app` im Hintergrund gestartet
  (`MACSCP_VERSION=1.2.0-dev MACSCP_BUILD=978`, `978` = `git rev-list
  --count HEAD` zum Zeitpunkt des Laufs), erfolgreich durchgelaufen
  (`Build complete!`, `wrote dist/macSCP.app`). Geprüft:
  - `lipo -archs` auf `macSCP` und `macscp-cli`: beide `x86_64 arm64`.
  - Beide Ressourcen-Bundles vorhanden:
    `macSCP_MacSCPAppKit.bundle`, `macSCP_macSCPCore.bundle`.
  - Alle vier `.lproj` im Bundle: `en`, `de`, `fr`, `pl`.
  - `plutil -lint` auf `Contents/Info.plist`: `OK`.
  - **Alle drei `UTExportedTypeDeclarations`-Einträge vorhanden**
    (`dev.noix.macscp.sessions`, `dev.noix.macscp.logins`,
    `dev.noix.macscp.snippets`), gelesen aus dem tatsächlich gebauten
    `Info.plist`, nicht nur aus dem Skript — der dritte Eintrag ist der
    eigentliche Prüfpunkt dieser Phase, siehe unten.
  - Die App wurde **nicht gestartet** — Vorgabe des Auftrags.

## 1. Warum der Codec kein Passwort entgegennimmt, und wie das gepinnt ist

Die Begründung ist inhaltlich, nicht technisch: Ein Snippet enthält per
Konstruktion keine Zugangsdaten (`Snippet`s eigener Doc-Kommentar schließt
das aus, Secrets leben ausschließlich im Schlüsselbund). Eine
Verschlüsselung würde Sicherheit vortäuschen, die es nicht gibt — dieselbe
Begründung wie bei der ersten Runde der Snippet-Arbeit, unverändert.

Die öffentliche Schnittstelle von `SnippetExportCodec` (`encode(_:)`,
`probe(_:)`, `decode(_:)`) nimmt an keiner Stelle einen `password`-Parameter
— anders als ihre beiden Geschwister `SessionExportCodec` und
`LoginSetExportCodec`. Das schließt einen Aufrufer, der ein Passwort
hineinreichen will, bereits am Typsystem aus, zur Compile-Zeit, ohne
Zutun eines Tests.

Der verbleibende Rest-Fall ist intern: `encode`/`decode` könnten später so
verändert werden, dass sie etwas anderes als das buchstäbliche `nil` an
`ExportEnvelopeCodec` weiterreichen. Dagegen ist gepinnt — mit dem Feld auf
dem tatsächlich erzeugten Umschlag, nicht mit einem Quelltext-Wächter:
`ExportEnvelopeCodec.encode` schreibt `encrypted: false` **genau dann**,
wenn es `password: nil` empfangen hat (siehe `ExportEnvelopeCodec.swift`,
`encode<P>` — der `guard let password else { … encrypted: false … }`-Zweig).
`SnippetExportCodecTests.theWrittenFileIsPlainTextAndSaysSoInsteadOf
ClaimingEncryption` liest dieses Feld direkt von den erzeugten Bytes,
`.probeAcceptsOurFormatAndRejectsASessionExport` liest es ein zweites Mal
über `probe`s Rückgabewert auf demselben Output. Beide Tests werden rot, in
dem Moment, in dem der interne Aufruf aufhört, `nil` zu übergeben — das ist
eine direkte Beobachtung der gepinnten Tatsache, kein Proxy dafür.

Bewusst **kein** achter Quelltext-Wächter: Das Projekt hat zum Zeitpunkt
dieser Phase bereits sieben solcher Wächter (aus P3a und früheren Phasen),
und ein Reviewer hatte das Idiom kurz zuvor als an seiner sinnvollen Größe
angekommen bewertet. Ein Wächter hätte hier zudem ein Problem gelöst, das
die feste, passwortlose Signatur bereits strukturell löst — es gibt nichts,
wovor ein *Aufrufer* bewahrt werden müsste, weil kein Aufrufer ein Passwort
übergeben kann.

## 2. Was `probe` tatsächlich zurückgibt — und eine Korrektur

`probe` meldet das `encrypted`-Flag des Umschlags. **Es ist kein
Format-Prädikat.** Für dieses Format ist der Rückgabewert immer `false` —
`SnippetExportCodec` verschlüsselt nie —, unabhängig davon, ob die Datei
tatsächlich eine Snippet-Exportdatei ist oder nicht. Was eine Datei mit
falschem Format ablehnt, ist nicht `probe`s Rückgabewert, sondern
`ExportEnvelopeCodec`s eigene Formatprüfung, die **wirft**: Die private
Funktion `envelope(from:as:format:currentVersion:)` dekodiert zuerst nur
einen schlanken `EnvelopeHeader` (Format + Version) und prüft
`header.format == format`; passt das Format nicht, wirft sie
`SessionExportError.notAnExportFile`, bevor überhaupt ein `encrypted`-Wert
existiert. `probe` und `decode` rufen beide dieselbe `envelope(from:)`
zuerst auf — die Formatprüfung ist also identisch scharf für beide, aber sie
läuft **vor** und **unabhängig von** dem, was `probe` am Ende zurückgibt.

Diese Unterscheidung wurde in dieser Phase einmal falsch hingeschrieben:
Task 1s eigener Test-Entwurf (im Plan, nicht im Auftrag dieser
Abschluss-Aufgabe) behauptete `#expect(try SnippetExportCodec.probe(ours))`
— dass `probe` auf einer frisch von diesem Codec erzeugten Datei `true`
zurückgibt. Das ist falsch in beide Richtungen: erstens verschlüsselt
dieser Codec nie, also ist der korrekte Wert `false`, nicht `true`; zweitens
hätte selbst ein `true`-Ergebnis nichts über Formatzugehörigkeit ausgesagt,
weil `probe` gar kein Format-Prädikat ist. Der Implementierer hat das beim
Schreiben des Tests bemerkt, korrigiert (`== false`, analog zu
`LoginSetExportCodecTests.roundTripsUnencrypted`) und im eigenen Report
dokumentiert (`task-1-report.md`, Abschnitt 4). Für einen künftigen Leser:
Ein grüner `probe(_:) == false` auf der eigenen Ausgabe ist bei diesem
Codec das *erwartete*, nicht das überraschende Ergebnis — die Ablehnung
einer falschformatigen Datei zeigt sich als **Wurf**, nicht als `false`.

## 3. Was durch Tests gehalten wird, was nur durch Review

Dieses Projekt hat kein SwiftUI-Rendering-Werkzeug (projektweite,
dokumentierte Grenze, keine Besonderheit dieser Phase). Konkret für P3b:

**Getestet** (Core: `SnippetExportCodecTests` — 5, `SnippetImportPlanner
Tests` — 13; App: `SnippetsPresentationTests` — 17 neue über die Phase,
zusammen mit den bereits vorhandenen in einer Suite):

- Der Export-Roundtrip (Name/Command/Tags), dass die Datei Klartext ist und
  `encrypted: false` trägt, dass eine beschädigte Snippet-Nutzlast den
  ganzen Decode wirft statt still einen Eintrag zu verlieren, die
  Versionsprüfung.
- Der Planer: alle vier vom Login-Set-Präzedenzfall übernommenen
  Eigenschaften — Trimm-/Case-insensitive Namensschlüssel, wachsende
  `takenNames`-Menge, Ersetzung höchstens einmal pro vorhandener id
  (`replacedExistingIDs`), vollständiger Abbruch bei Cancellation — sind
  einzeln durch Tests gepinnt, nicht nur im Report behauptet; der Reviewer
  hat sie laut Ledger unabhängig nachverfolgt statt dem Report zu vertrauen.
- `snippetsCanExport`: aktiviert bei geladenem, nicht-leerem Store;
  deaktiviert bei leerem sichtbarem Ergebnis; deaktiviert bei
  `.unreadable`, auch wenn `visibleSnippets` (das Argument) nicht leer
  wäre — der Test, der beweist, dass die Funktion `isUnreadable` selbst
  prüft statt es nur aus Leere zu erraten.
- `applySnippetImportPlan`: frischer Import, Replace-statt-Duplikat
  (End-zu-Ende von Planer-Ausgabe bis Store-Zustand, vorher nur isoliert
  getestet), ein abgebrochener Lauf schreibt nichts, ein Schreibfehler wird
  gezählt statt zu crashen.
- `snippetImportResultText`/`snippetImportErrorText`: Textvarianten je
  nach Anzahl/Fehlerart.

**Nicht getestet** (unbeobachtbar ohne Rendering-Harness, nicht vergessen):

- Dass der Export-/Import-Button überhaupt erscheint, `.disabled`
  tatsächlich greift, und der `fileExporter`/`fileImporter` sich öffnet.
- Die Reihenfolge `probe` **vor** `decode` in
  `handleImportFileSelection` — die Typkorrektheit beider Aufrufe ist über
  die jeweiligen Codec-Tests belegt, die Verdrahtungsreihenfolge selbst
  nicht.
- Der neue dritte `kindText`-Fall (`.snippet`) in `ImportConflictSheet.swift`
  — genau wie seine beiden Vorgänger (`.loginSet`, `.session`), die **nie**
  unit-getestet waren. Kein neues Loch, dieselbe Lücke wie zuvor, jetzt um
  einen Fall größer.
- Das unterdrückte Ergebnis-Alert nach einem abgebrochenen Import — nur der
  Schreibpfad (`applySnippetImportPlan` schreibt bei `cancelled` nichts)
  ist gepinnt, nicht die UI-Reaktion (`guard !plan.cancelled else { return }`
  in `SnippetsSheet.applyImport`), dass deshalb kein Alert erscheint.
- Das Passwortlos-Design selbst hat außerhalb von Task 1 keinen neuen
  Prüfpunkt bekommen — Task 3/4 fügen keinen neuen Aufrufer von
  `SnippetExportCodec.encode`/`decode` hinzu, der ihn regressieren könnte,
  auf andere Weise als Task 1 es bereits prüft.

## 4. Die GUI wurde in dieser gesamten Phase nie gestartet

Jede Aussage über tatsächliches Rendering, Klickverhalten oder das reale
Aussehen des Speicher-/Öffnen-Panels ist in den Task-Reports als
unbeobachtete Behauptung geführt. Der Maintainer muss vor dem nächsten
Release von Hand ansehen:

1. **Export mit aktivem Filter** — Suchfeld und/oder Tag-Filter im
   Snippets-Sheet setzen, „Export…" klicken, und die geschriebene Datei
   öffnen: Sie darf nur die gerade sichtbaren Snippets enthalten, nicht
   alle im Store. `performExport` bekommt laut Quelltext exakt
   `visibleSnippets` übergeben — dass diese Verbindung im laufenden UI auch
   wirklich zustande kommt, ist ungeprüft.
2. **Import einer Datei mit Namenskonflikt** — eine zuvor exportierte
   Datei mit einem im aktuellen Store bereits vorhandenen Snippet-Namen
   importieren (gleicher Name, auch bei abweichender Groß-/Kleinschreibung
   oder Leerzeichen am Rand) und prüfen, dass das geteilte Konflikt-Sheet
   erscheint, den neuen dritten Fall korrekt beschriftet, und
   Ersetzen/Behalten-beide sich wie erwartet auswirken.
3. **Die Absage bei einer falschen Datei** — eine Sitzungs- oder
   Login-Set-Exportdatei (`.macscpsessions`/`.macscplogins`) über den
   Snippet-Import auswählen und bestätigen, dass sie zurückgewiesen wird
   (durch `ExportEnvelopeCodec`s Formatprüfung, die wirft, nicht durch
   `probe`s Rückgabewert — siehe Abschnitt 2) und eine verständliche
   Fehlermeldung erscheint, keine stille Fehlfunktion.
4. Zusätzlich, aus Task 3: „Export…" ist bei unlesbarem Store (z. B. eine
   von Hand beschädigte `snippets.json`) tatsächlich deaktiviert bzw.
   führt zu keiner Aktion, und die im Speicherpanel vorgeschlagene
   Endung/Dateiname stimmen.

## Die Packaging-Lektion

Der neue Dateityp wurde in Swift deklariert (`UTType.macscpSnippets` in
`SessionExportImportSheets.swift`, Task 3), bekam aber zunächst **keinen**
Eintrag in `scripts/package-app`s `UTExportedTypeDeclarations`-Array — anders
als seine beiden Geschwister `macscpSessions`/`macscpLogins`, die dort schon
standen. macOS hätte die Endung `.macscpsnippets` also außerhalb der
eigenen Panels der App gar nicht gekannt (Finder-Zuordnung, „Öffnen mit",
Spotlight). Der `UTType.macscpSnippets`-Doc-Kommentar behauptete zu diesem
Zeitpunkt bereits, der Eintrag existiere — eine falsche Aussage, keine
unbeobachtete.

Gefunden hat das die Koordinator-Review von Task 3, nicht ein Test: Weder
`swift test` noch `swift build` berühren `scripts/package-app`, und weil die
GUI in dieser Phase grundsätzlich nie gestartet wird, hätte auch kein
manueller Blick es zufällig aufgedeckt. Der Fix (`4b2ecab`) ergänzt den
dritten Eintrag Feld für Feld identisch zu den beiden bestehenden
(`UTTypeIdentifier dev.noix.macscp.snippets`, Beschreibung „macSCP
Snippets", `UTTypeConformsTo [public.json]`, Endung `macscpsnippets`) und
wurde durch einen Rebuild plus Lesen des tatsächlichen `Info.plist`
verifiziert, nicht nur durch erneutes Lesen des Skripts. Diese
Abschluss-Aufgabe hat den Befund unabhängig reproduziert (siehe „Gemessene
Zahlen" oben).

**Für ein künftiges Format:** Ein neuer Austauschtyp braucht beide Hälften
— die Swift-`UTType`-Deklaration **und** den passenden
`UTExportedTypeDeclarations`-Eintrag im Packaging-Skript — und dieses
Projekt hat aktuell keinen automatischen Prüfpunkt, der eine fehlende zweite
Hälfte meldet außer der Review selbst.

## Brief-Fehler dieser Phase (aus dem Ledger, `progress.md`)

Zehn Brief-Fehler insgesamt in diesem Meilenstein; fünf davon fielen in
P3b:

- Task 1 (sechster): Der Test-Entwurf im Plan behauptete
  `probe(ourFile)` sei wahr — siehe Abschnitt 2 oben.
- Task 2 (siebter): Der vierte Test-Entwurf sagte nicht, ob `existing` leer
  startet; bei leerem Store kollidiert von zwei gleichnamigen importierten
  Einträgen nur der zweite. Der Implementierer hat `existing` mit einem
  gleichnamigen Eintrag vorbelegt und das im Report begründet.
- Task 3 (achter): Der Plan verwies auf „das Sitzungs-Sheet" als Vorbild
  für den `fileExporter`-Aufruf; ein solches Sheet existiert nicht —
  Sitzungs-Export läuft über `ContentView`/`ContentView+Sheets.swift`.
  `LoginSetsSheet` war das tatsächlich passende Vorbild und wurde
  stattdessen befolgt.
- Task 4 (neunter): Der Plan beschrieb `snippets.import.result %lld` mit
  zwei Platzhaltern (analog zu Login-Sets); der Schlüssel nimmt nur einen.
  Wörtlich umgesetzt; für Replaced/Renamed wird stattdessen der bereits
  vorhandene generische Schlüssel `import.result.resolved %lld %lld`
  mitgenutzt.
- Task 4 (zehnter): Ein Doc-Kommentar an `SnippetExportDocument` behauptete,
  es gäbe noch keinen Import-Call-Site — nach Task 4 stimmte das nicht
  mehr und wurde korrigiert.

Zusätzlich, außerhalb der nummerierten Zählung: Der `UTType.macscpSnippets`-
Doc-Kommentar aus Task 3, der die (zu diesem Zeitpunkt fehlende)
Packaging-Eintragung als vorhanden behauptete — siehe „Packaging-Lektion"
oben. Diese Abschluss-Aufgabe selbst hat keinen neuen Fehler im
Task-5-Brief gefunden; seine Aussagen zu Format, Planer, Oberfläche und
Commit-Anzahl stimmten bis auf die oben genannte Sechs-vs-fünf-Korrektur.

## Bekannte, bewusst zurückgestellte Punkte

- Die sequenzielle Abarbeitung / „höchstens ein `arbiter.resolve` gleich-
  zeitig" im `SnippetImportPlanner`-Doc-Kommentar ist ungetestet — wörtlich
  von `LoginSetImportPlanner`s identischer, ebenfalls ungetesteter Aussage
  übernommen. Keine neue Lücke.
- Die beiden bereits vorhandenen `kindText`-Fälle in
  `ImportConflictSheet.swift` (`.loginSet`, `.session`) waren nie
  unit-getestet; der neue dritte Fall (`.snippet`) teilt diese Lücke, statt
  sie zu schließen.
